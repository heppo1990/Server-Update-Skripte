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
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 30,
        [scriptblock]$WriteLog
    )

    $localNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    $probe = {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        [pscustomobject]@{ Caption = [string]$os.Caption; Version = [string]$os.Version; BuildNumber = [int]$os.BuildNumber; ProductType = [int]$os.ProductType }
    }

    if ($localNames -contains $ComputerName) {
        return & $probe
    }

    $result = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $AuthInfo `
        -ScriptBlock $probe -TimeoutSeconds $TimeoutSeconds -OperationName "Windows-Version auf $ComputerName ermitteln" -WriteLog $WriteLog)
    if ($result.Count -eq 0) { throw "Windows-Version auf '$ComputerName' lieferte keine Daten." }
    return $result[-1]
}
