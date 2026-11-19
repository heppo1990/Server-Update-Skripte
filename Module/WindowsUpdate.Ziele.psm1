# Fachmodul: WindowsUpdate.Ziele
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Get-WindowsUpdateSshArguments {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [ValidateRange(1, 300)][int]$ConnectTimeoutSeconds = 15,
        [ValidateRange(1, 65535)][int]$Port = 22,
        [switch]$BatchMode,
        [switch]$AcceptNewHostKey
    )

    $arguments = @('-i', $KeyPath, '-p', $Port, '-o', "ConnectTimeout=$ConnectTimeoutSeconds", '-o', 'ConnectionAttempts=2', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4')
    if ($BatchMode) { $arguments += @('-o', 'BatchMode=yes') }
    if ($AcceptNewHostKey) { $arguments += @('-o', 'StrictHostKeyChecking=accept-new') }
    return $arguments
}

# Ausschließlich lesende SSH-Abfrage, einschließlich einer Laufzeitgrenze für
# den Befehl selbst (ConnectTimeout allein begrenzt nur den Verbindungsaufbau).
function Invoke-WindowsUpdateInventorySsh {
    param([Parameter(Mandatory)]$Settings, [Parameter(Mandatory)][string]$HostName,
        [Parameter(Mandatory)][string]$UserName, [Parameter(Mandatory)][string]$Command)
    if ($HostName -match '^[\-]' -or $UserName -notmatch '^[A-Za-z0-9_.-]+$') { throw 'Ungültiges SSH-Ziel.' }
    $ssh = if ($Settings.PSObject.Properties['SSHPath'] -and $Settings.SSHPath) { [string]$Settings.SSHPath } else { (Get-Command ssh.exe -ErrorAction Stop).Source }
    $key = if ($Settings.PSObject.Properties['KeyPath'] -and $Settings.KeyPath) { [string]$Settings.KeyPath } else { Join-Path $env:USERPROFILE '.ssh\id_rsa_linux' }
    $port = if ($Settings.PSObject.Properties['Port'] -and [int]$Settings.Port -gt 0) { [int]$Settings.Port } else { 22 }
    $arguments = @(Get-WindowsUpdateSshArguments -KeyPath $key -Port $port -ConnectTimeoutSeconds 5 -BatchMode)
    # Keine Passwort-/Hostkey-Prompts bei der Bestandsaufnahme.
    $arguments += @('-o','StrictHostKeyChecking=yes','-o','ConnectionAttempts=1',"${UserName}@${HostName}",$Command)
    $quoted = @($arguments | ForEach-Object { '"' + ([string]$_ -replace '(\\*)"','$1$1\"' -replace '(\\+)$','$1$1') + '"' })
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $ssh; $start.Arguments = $quoted -join ' '
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = New-Object Diagnostics.Process
    $process.StartInfo = $start
    try {
        [void]$process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(20000)) { $process.Kill(); $process.WaitForExit(); throw 'SSH-Bauartabfrage nach 20 Sekunden abgebrochen.' }
        $output = $stdout.GetAwaiter().GetResult(); $errorText = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -ne 0) { throw "SSH-Bauartabfrage fehlgeschlagen: $errorText" }
        return $output.Trim()
    } finally { $process.Dispose() }
}

function Get-WindowsUpdateExecutionPhases {
    [CmdletBinding()]
    param([AllowEmptyCollection()][object[]]$WindowsTargets = @(), [Parameter(Mandatory)]$UpdateSettings,
        $LinuxSettings, $HomeAssistantSettings, [scriptblock]$WriteLog)
    $virtual = [Collections.Generic.List[object]]::new()
    $physical = [Collections.Generic.List[object]]::new()
    $skipped = [Collections.Generic.List[object]]::new()
    $targets = @($WindowsTargets | ForEach-Object { [pscustomobject]@{Platform='Windows';Name=$_.Name;Target=$_} })
    if ($LinuxSettings -and $LinuxSettings.PSObject.Properties['Hosts']) {
        foreach ($entry in @($LinuxSettings.Hosts)) {
            if (-not $entry) { continue }
            $name = if ($entry -is [string]) { $entry } elseif ($entry.PSObject.Properties['Host']) { [string]$entry.Host } elseif ($entry.PSObject.Properties['Name']) { [string]$entry.Name } else { '' }
            if ($name) { $targets += [pscustomobject]@{Platform='Linux';Name=$name;Target=$entry} }
        }
    }
    if ($HomeAssistantSettings -and $HomeAssistantSettings.PSObject.Properties['Host'] -and $HomeAssistantSettings.Host) {
        $targets += [pscustomobject]@{Platform='HomeAssistant';Name=[string]$HomeAssistantSettings.Host;Target=$HomeAssistantSettings}
    }
    $localNames = @($env:COMPUTERNAME,[Net.Dns]::GetHostName())
    if ($env:USERDNSDOMAIN) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    foreach ($entry in $targets) {
        $timer = [Diagnostics.Stopwatch]::StartNew()
        $unreachable = $false
        try {
            if ($entry.Platform -eq 'Windows') {
                $probe = {
                    $cs = Get-CimInstance Win32_ComputerSystem -ErrorAction Stop
                    $bios = Get-CimInstance Win32_BIOS -ErrorAction Stop
                    if ([string]::IsNullOrWhiteSpace([string]$cs.Model)) { throw 'Hardwaremodell fehlt.' }
                    [pscustomobject]@{IsVirtual=(($cs.Manufacturer+' '+$cs.Model+' '+$bios.Manufacturer) -match 'VMware|VirtualBox|Virtual Machine|KVM|QEMU|Xen|Bochs|Parallels|bhyve|HVM domU')}
                }
                if ($localNames -contains $entry.Name) { $state = & $probe }
                else {
                    $ports = Test-WindowsUpdateWinRmPorts -ComputerName $entry.Name -TimeoutMilliseconds 1500 -Attempts 3
                    $auth = $null
                    if ($entry.Target.IsAdditional -or $entry.Target.IsHypervisor) {
                        $auth = Get-WindowsUpdateClientCertificateAuthInfo -UpdateSettings $UpdateSettings -TargetComputer $entry.Name
                        if ($null -eq $auth) { throw 'Clientzertifikat fehlt; keine andere Anmeldung versuchen.' }
                    }
                    # Der feste JEA-Status funktioniert auch mit URI-beschränktem Zertifikat.
                    $state = $null
                    $statusFailure = ''
                    try {
                        # Ein Porttest allein darf keinen funktionierenden
                        # Zertifikats-/Kerberos-Endpunkt aus der Zielliste entfernen.
                        $statusTimeout = if ($ports.Reachable) { 15 } else { 5 }
                        $status = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $entry.Name -AuthInfo $auth -ConfigurationName WindowsUpdateAdm -ScriptBlock { Get-WindowsUpdateAdmDeploymentStatus } -TimeoutSeconds $statusTimeout -OperationName 'Bauart über JEA ermitteln')
                        if ($status.Count -gt 0 -and $status[-1].PSObject.Properties['IsVirtual'] -and $status[-1].IsVirtual -is [bool]) { $state = $status[-1] }
                    } catch { $statusFailure = $_.Exception.Message }
                    if (-not $ports.Reachable -and $null -ne $state -and $WriteLog) {
                        & $WriteLog "Bauartabfrage $($entry.Name): Portvorprüfung negativ, tatsächliche JEA-Verbindung erfolgreich; Ziel wird verarbeitet." $true
                    }
                    if (-not $ports.Reachable -and $null -eq $state) {
                        $unreachable = $true
                        throw "WinRM nach drei Portprüfungen und zusätzlichem JEA-Verbindungsversuch nicht erreichbar. $statusFailure"
                    }
                    if ($null -eq $state) {
                        $result = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $entry.Name -AuthInfo $auth -ScriptBlock $probe -TimeoutSeconds 15 -OperationName 'Bauart ermitteln')
                        if ($result.Count -eq 0) { throw 'Bauart fehlt; aktuelle Verteilung ausführen.' }
                        $state = $result[-1]
                    }
                }
                if (-not $state.PSObject.Properties['IsVirtual'] -or $state.IsVirtual -isnot [bool]) { throw 'Ungültige Bauartantwort; aktuelle Verteilung ausführen.' }
                $isVirtual = [bool]$state.IsVirtual
            } elseif ($entry.Platform -eq 'Linux') {
                if (-not $entry.Target.PSObject.Properties['User'] -or -not $entry.Target.User) { throw 'SSH-Benutzer fehlt.' }
                $answer = Invoke-WindowsUpdateInventorySsh -Settings $LinuxSettings -HostName $entry.Name -UserName $entry.Target.User -Command 'systemd-detect-virt --vm; result=$?; if [ "$result" -eq 1 ]; then exit 0; fi; exit "$result"'
                if ($answer -notmatch '^[a-zA-Z0-9_-]+$') { throw 'Ungültige Virtualisierungsantwort.' }
                $isVirtual = $answer -ne 'none'
            } else {
                # Supervisor fragt den Host ab, nicht den SSH-Addon-Container.
                $answer = Invoke-WindowsUpdateInventorySsh -Settings $HomeAssistantSettings -HostName $entry.Name -UserName $HomeAssistantSettings.User -Command 'ha host info --raw-json'
                $info = $answer | ConvertFrom-Json -ErrorAction Stop
                if ($info.PSObject.Properties['data']) { $info = $info.data }
                if (-not $info.PSObject.Properties['virtualization']) { throw 'Home-Assistant-Host meldet keine Virtualisierung.' }
                $isVirtual = -not [string]::IsNullOrWhiteSpace([string]$info.virtualization) -and [string]$info.virtualization -ne 'none'
            }
            if ($isVirtual) { $virtual.Add($entry) } else { $physical.Add($entry) }
            if ($WriteLog) { & $WriteLog ("Bauart {0}: {1}; Dauer {2:N1}s." -f $entry.Name,$(if ($isVirtual) {'VM'} else {'physisch'}),$timer.Elapsed.TotalSeconds) $true }
        } catch {
            $skipped.Add([pscustomobject]@{Platform=$entry.Platform;Name=$entry.Name;Unreachable=$unreachable;Reason=$_.Exception.Message})
            if ($WriteLog) { & $WriteLog "WARNUNG: Bauart auf $($entry.Name) nicht ermittelbar; Ziel übersprungen. Details im Log." $false; & $WriteLog "Bauartabfrage $($entry.Name): $($_.Exception.Message); Dauer $($timer.Elapsed.TotalSeconds)s." $true }
        }
    }
    # Zuerst sämtliche Windows-Ziele, danach Linux und zuletzt Home Assistant.
    # Die Bauart bleibt auch für die spätere Neustartplanung ausdrücklich erhalten.
    $phases = @(
        foreach ($platform in @('Windows','Linux','HomeAssistant')) {
            [pscustomobject]@{Name="$platform-VMs";IsVirtual=$true;Targets=@($virtual.ToArray() | Where-Object Platform -eq $platform)}
            [pscustomobject]@{Name="$platform physisch";IsVirtual=$false;Targets=@($physical.ToArray() | Where-Object Platform -eq $platform)}
        }
    )
    [pscustomobject]@{Phases=$phases;Skipped=@($skipped.ToArray())}
}

function Get-WindowsUpdateTargets {
    param(
        [Parameter(Mandatory)]$UpdateSettings,
        [Parameter(Mandatory)][string]$TargetComputers,
        [int]$PowerShellMajor = $PSVersionTable.PSVersion.Major,
        [ValidateRange(0, 100000)][int]$LinuxTargetCount = 0,
        [ValidateRange(0, 100000)][int]$HomeAssistantTargetCount = 0,
        [switch]$IncludeAdditionalTargetCounts,
        [switch]$ADTargetsOnly,
        [switch]$StrictAdditionalTargetClassification,
        [scriptblock]$WriteLog
    )

    $adComputers = @()
    $localComputer = [PSCustomObject]@{ Name = $env:COMPUTERNAME }
    $isDomainJoined = $false

    try {
        $isDomainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    }
    catch {
        Write-CommonLog $WriteLog 'WARNUNG: Domänenstatus konnte nicht ermittelt werden; lokales Ziel wird verwendet. Details im Log.'
        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'Domänenstatus ermitteln' -ErrorRecord $_ -Context @('Fallback=lokales Ziel')
    }

    if ($isDomainJoined) {
        try {
            if ($PowerShellMajor -ge 7) {
                Write-CommonLog $WriteLog "PowerShell $PowerShellMajor erkannt - Verwende Windows PowerShell Compatibility für ActiveDirectory"
                Import-Module ActiveDirectory -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
                Write-CommonLog $WriteLog 'ActiveDirectory-Modul erfolgreich über Windows PowerShell Compatibility geladen'
            }
            else {
                Import-Module ActiveDirectory -ErrorAction Stop
            }

            switch ($TargetComputers) {
                'All' {
                    Write-CommonLog $WriteLog 'Ziel: Alle Windows-Computer (Server + Clients)'
                    $adComputers = @(Get-ADComputer -Filter {(OperatingSystem -like '*Windows*') -and (Enabled -eq $true)} -Properties Name,OperatingSystem | Sort-Object Name)
                }
                default {
                    Write-CommonLog $WriteLog 'Ziel: Nur Windows Server'
                    $adComputers = @(Get-ADComputer -Filter {(OperatingSystem -like '*Windows*Server*') -and (Enabled -eq $true)} -Properties Name,OperatingSystem | Sort-Object Name)
                }
            }
        }
        catch {
            Write-CommonLog $WriteLog 'WARNUNG: ActiveDirectory-Abfrage fehlgeschlagen; nur das lokale Ziel wird verarbeitet. Details im Log.'
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'ActiveDirectory-Zielliste' -ErrorRecord $_ -Context @('Fallback=lokales Ziel')
            $adComputers = @($localComputer)
        }
    }
    else {
        $adComputers = @($localComputer)
        Write-CommonLog $WriteLog 'Computer ist nicht in einer Domäne. Verarbeite nur lokalen Rechner.'
    }

    $targets = @()
    $knownNames = @()
    foreach ($computer in $adComputers) {
        if (($null -ne $computer.Name) -and (-not ($knownNames -contains ([string]$computer.Name)))) {
            $knownNames += [string]$computer.Name
            $targetObject = New-Object PSObject
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name Name -Value ([string]$computer.Name)
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name IsAdditional -Value $false
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name IsHypervisor -Value $false
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name ClassificationError -Value $null
            $targets += $targetObject
        }
    }

    $adAvailable = $null -ne (Get-Command Get-ADComputer -ErrorAction SilentlyContinue)
    foreach ($groupName in @('AdditionalComputers', 'HypervisorComputers')) {
        $isHypervisorGroup = $groupName -eq 'HypervisorComputers'
        $names = @($UpdateSettings.$groupName)
        $names = @($names | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($names.Count -eq 0) { continue }
        foreach ($configuredName in $names) {
            $computerName = ([string]$configuredName).Trim()
            $isInAd = $false
            $classificationError = $null
            if ($adAvailable) {
                try {
                    $null = Get-ADComputer -Identity $computerName -ErrorAction Stop
                    $isInAd = $true
                }
                catch {
                    $adLookupError = $_
                    $errorTypeNames = @()
                    $currentException = $adLookupError.Exception
                    while ($null -ne $currentException) {
                        $errorTypeNames += $currentException.GetType().FullName
                        $currentException = $currentException.InnerException
                    }

                    # PowerShell 7 kann AD-Fehler aus der Windows PowerShell-
                    # Compatibility-Session als RemoteException verpacken.
                    # Den AD-Ausnahmetyp daher anhand der Fehlerdaten erkennen,
                    # statt ihn als Catch-Typ lokal vorauszusetzen.
                    $isIdentityNotFound =
                        ($adLookupError.FullyQualifiedErrorId -match '(?i)ADIdentityNotFoundException|IdentityNotFound') -or
                        ($errorTypeNames -contains 'Microsoft.ActiveDirectory.Management.ADIdentityNotFoundException') -or
                        ($adLookupError.CategoryInfo.Category -eq [System.Management.Automation.ErrorCategory]::ObjectNotFound)

                    if ($isIdentityNotFound) {
                        # Nur ein eindeutiges "nicht gefunden" bedeutet, dass
                        # das Ziel außerhalb der Verwaltungs-AD liegt.
                        $isInAd = $false
                    }
                    elseif ($StrictAdditionalTargetClassification) {
                        $classificationError = $adLookupError.Exception.Message
                        Write-CommonLog $WriteLog "WARNUNG: AD-Zugehörigkeit von '$computerName' konnte nicht geprüft werden; Ziel wird nicht als extern eingestuft. Details im Log."
                        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'Zusatzcomputer-AD-Zugehörigkeit' -Target $computerName -ErrorRecord $adLookupError -Context @('Ziel=unbekannt; keine externe Authentifizierung versuchen')
                    }
                    else {
                        $isInAd = $false
                    }
                }
            }
            elseif ($StrictAdditionalTargetClassification -and $isDomainJoined) {
                $classificationError = 'ActiveDirectory-Modul oder AD-Abfrage ist nicht verfügbar.'
                Write-CommonLog $WriteLog "WARNUNG: AD-Zugehörigkeit von '$computerName' konnte nicht geprüft werden; Ziel wird nicht als extern eingestuft."
                Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'Zusatzcomputer-AD-Zugehörigkeit' -Target $computerName -DiagnosticText $classificationError -Context @('Ziel=unbekannt; keine externe Authentifizierung versuchen')
            }
            if ($knownNames -notcontains $computerName) {
                $knownNames += $computerName
                if ($classificationError) {
                    $targets += [PSCustomObject]@{
                        Name = $computerName
                        IsAdditional = $false
                        IsHypervisor = $false
                        ClassificationError = $classificationError
                    }
                }
                else {
                    $targets += [PSCustomObject]@{
                        Name = $computerName
                        IsAdditional = ((-not $isInAd) -and (-not $isHypervisorGroup))
                        IsHypervisor = ((-not $isInAd) -and $isHypervisorGroup)
                        ClassificationError = $null
                    }
                }
            }
        }
    }

    if ($ADTargetsOnly) {
        $beforeFilterCount = $targets.Count
        $targets = @($targets | Where-Object {
            -not $_.IsAdditional -and -not $_.IsHypervisor -and -not $_.ClassificationError
        })
        $excludedTargetCount = $beforeFilterCount - $targets.Count
        Write-CommonLog $WriteLog "AD-Aufgabenlauf: $($targets.Count) AD-Ziel(e) aufgenommen; $excludedTargetCount Nicht-AD-/unbestätigte Windows-Ziel(e) ausgeschlossen."
    }

    if ($IncludeAdditionalTargetCounts) {
        $targetParts = @()
        if ($targets.Count -gt 0) { $targetParts += "Windows: $($targets.Count)" }
        if ($LinuxTargetCount -gt 0) { $targetParts += "Linux: $LinuxTargetCount" }
        if ($HomeAssistantTargetCount -gt 0) { $targetParts += "Home Assistant: $HomeAssistantTargetCount" }
        $totalTargetCount = $targets.Count + $LinuxTargetCount + $HomeAssistantTargetCount
        $targetBreakdown = $targetParts -join ', '
        $targetMessage = "Gesamtliste nach Zusammenführung: Gesamt $totalTargetCount"
        if ($targetBreakdown) { $targetMessage += " ($targetBreakdown)" }
        Write-CommonLog $WriteLog $targetMessage
    }
    else {
        Write-CommonLog $WriteLog "Gesamtliste nach Zusammenführung: $($targets.Count) Gerät(e)"
    }

    return @($targets)
}

function Get-WindowsUpdateTargetOperatingSystem {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 60,
        [scriptblock]$WriteLog
    )

    $localNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    $probe = {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        [pscustomobject]@{ Caption = [string]$os.Caption; Version = [string]$os.Version; BuildNumber = [int]$os.BuildNumber; ProductType = [int]$os.ProductType; InstallationType = [string](Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType -ErrorAction SilentlyContinue).InstallationType }
    }

    if ($localNames -contains $ComputerName) {
        return & $probe
    }

    $result = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $AuthInfo `
        -ScriptBlock $probe -TimeoutSeconds $TimeoutSeconds -OperationName "Windows-Version auf $ComputerName ermitteln" -WriteLog $WriteLog)
    if ($result.Count -eq 0) { throw "Windows-Version auf '$ComputerName' lieferte keine Daten." }
    return $result[-1]
}
