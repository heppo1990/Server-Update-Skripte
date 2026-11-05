function Get-WindowsUpdateDeploymentBootstrapCredential {
    param([Parameter(Mandatory)][string]$Servername)
    $message = "Einmalige WinRM-Einrichtung für $Servername. Bitte den tatsächlichen lokalen Administratorkontonamen eingeben, z. B. $Servername\Konto oder .\Konto."
    Get-Credential -Message $message
}

function Get-WindowsUpdateDeploymentClientCertificate {
    param(
        [Parameter(Mandatory)][object]$UpdateSettings,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $configuredThumbprint = if ($UpdateSettings.PSObject.Properties['ClientCertThumbprint']) {
        [string]$UpdateSettings.ClientCertThumbprint
    } else { '' }
    $certificates = @(Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue)
    if (-not [string]::IsNullOrWhiteSpace($configuredThumbprint)) {
        $certificate = $certificates | Where-Object Thumbprint -eq $configuredThumbprint | Select-Object -First 1
    } else {
        $certificate = $certificates |
            Where-Object Subject -eq "CN=WinRM-UpdateClient-$ComputerName" |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
    }
    if ($certificate -and $certificate.NotAfter -gt (Get-Date) -and $certificate.HasPrivateKey) { return $certificate }
    return $null
}

function ConvertFrom-WindowsUpdateAdmDeploymentStatus {
    param([Parameter(Mandatory)][object]$Status)

    $winGetProperty = $Status.PSObject.Properties['WinGetUpdateOnly']
    $chocolateyProperty = $Status.PSObject.Properties['ChocolateyUpdateOnly']
    $maintenanceProperty = $Status.PSObject.Properties['WinGetMaintenanceOnly']
    $chocolateyMaintenanceProperty = $Status.PSObject.Properties['ChocolateyMaintenanceOnly']
    [PSCustomObject]@{
        DeploymentVersion = [string]$Status.Version
        WinGetUpdateOnly = [bool]$(if ($winGetProperty) { $winGetProperty.Value } else { $false })
        ChocolateyUpdateOnly = [bool]$(if ($chocolateyProperty) { $chocolateyProperty.Value } else { $false })
        WinGetMaintenanceOnly = [bool]$(if ($maintenanceProperty) { $maintenanceProperty.Value -and $Status.PSObject.Properties['MaintenanceRevision'] -and $Status.MaintenanceRevision -eq '6' } else { $false })
        ChocolateyMaintenanceOnly = [bool]$(if ($chocolateyMaintenanceProperty) { $chocolateyMaintenanceProperty.Value } else { $false })
    }
}

function Test-WindowsUpdateDeploymentConfiguration {
    param(
        [Parameter(Mandatory)][string]$Servername,
        [Parameter(Mandatory)][string]$DeployType,
        [Parameter(Mandatory)][string]$ExpectedDeploymentVersion,
        [bool]$ExpectedWinGetUpdateOnly = $false,
        [bool]$ExpectedChocolateyUpdateOnly = $true,
        [bool]$ExpectedWinGetMaintenanceOnly = $true,
        [bool]$ExpectedChocolateyMaintenanceOnly = $true,
        [Parameter(Mandatory)][object]$UpdateSettings,
        [string]$ManagementComputerName = $env:COMPUTERNAME
    )

    $certificate = $null
    if ($DeployType -ne 'AD') {
        $certificate = Get-WindowsUpdateDeploymentClientCertificate -UpdateSettings $UpdateSettings -ComputerName $ManagementComputerName
        if (-not $certificate) {
            return [PSCustomObject]@{ IsCurrent = $false; Reason = 'Das konfigurierte Clientzertifikat fehlt, ist abgelaufen oder besitzt keinen privaten Schlüssel.'; Version = '' }
        }
    }

    $endpointParameters = @{
        ComputerName = $Servername
        ConfigurationName = 'WindowsUpdateAdm'
        SessionOption = (New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000)
        ErrorAction = 'Stop'
        ScriptBlock = { Get-WindowsUpdateAdmDeploymentStatus -ErrorAction Stop }
    }
    if ($certificate) {
        $endpointParameters.UseSSL = $true
        $endpointParameters.CertificateThumbprint = $certificate.Thumbprint
    }

    try {
        $rawStatus = Invoke-Command @endpointParameters
        if (($rawStatus.PSObject.Properties['TargetBuild'] -and [int]$rawStatus.TargetBuild -lt 17763) -or
            ($rawStatus.PSObject.Properties['ServerCore'] -and [bool]$rawStatus.ServerCore)) {
            $ExpectedWinGetUpdateOnly = $false
            $ExpectedWinGetMaintenanceOnly = $false
        }
        $status = ConvertFrom-WindowsUpdateAdmDeploymentStatus -Status $rawStatus
        if ((Test-WindowsUpdateAdmVersion -Actual $status.DeploymentVersion -Expected $ExpectedDeploymentVersion) -and
            $status.ChocolateyUpdateOnly -eq $ExpectedChocolateyUpdateOnly -and
            $status.WinGetMaintenanceOnly -eq $ExpectedWinGetMaintenanceOnly -and
            $status.ChocolateyMaintenanceOnly -eq $ExpectedChocolateyMaintenanceOnly -and
            ($status.WinGetUpdateOnly -eq $ExpectedWinGetUpdateOnly)) {
            return [PSCustomObject]@{ IsCurrent = $true; Reason = ''; Version = [string]$status.DeploymentVersion }
        }
        $reason = "Konfigurationsversion $($status.DeploymentVersion) oder eingeschränkte Paketmanager-Funktionen weichen vom Sollstand ab (WinGet-Update-only=$($status.WinGetUpdateOnly), WinGet-Wartung=$($status.WinGetMaintenanceOnly), Chocolatey-Update-only=$($status.ChocolateyUpdateOnly), Chocolatey-Wartung=$($status.ChocolateyMaintenanceOnly))."
    }
    catch { $reason = $_.Exception.Message }

    if ($certificate -and $reason -and $DeployType -ne 'AD') {
        try {
            $legacyStatus = Invoke-Command -ComputerName $Servername -UseSSL `
                -CertificateThumbprint $certificate.Thumbprint `
                -SessionOption (New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000) `
                -ErrorAction Stop -ScriptBlock {
                    $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber
                    $modulePath = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\JEA_Updates.psm1'
                    $moduleText = if (Test-Path -LiteralPath $modulePath -PathType Leaf) { Get-Content -LiteralPath $modulePath -Raw -ErrorAction Stop } else { '' }
                    $versionMatch = [regex]::Match($moduleText, "function\s+Get-WindowsUpdateAdmDeploymentStatus[\s\S]*?Version\s*=\s*'(?<Version>[^']+)'", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    [PSCustomObject]@{
                        MaintenanceCurrent = $moduleText -match "MaintenanceRevision\s*=\s*'6'"
                        Build = $build
                        ServerCore = ((Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType -ErrorAction SilentlyContinue).InstallationType -eq 'Server Core')
                        HasStatusFunction = $versionMatch.Success
                        DeploymentVersion = if ($versionMatch.Success) { [string]$versionMatch.Groups['Version'].Value } else { '' }
                        WinGetUpdateOnly = $moduleText -match '(?i)WinGetUpdateOnly\s*=\s*\$true'
                        ChocolateyUpdateOnly = $moduleText -match '(?i)ChocolateyUpdateOnly\s*=\s*\$true'
                        WinGetMaintenanceOnly = $moduleText -match '(?i)WinGetMaintenanceOnly\s*=\s*\$true'
                        ChocolateyMaintenanceOnly = $moduleText -match '(?i)ChocolateyMaintenanceOnly\s*=\s*\$true'
                    }
                }
            if ($legacyStatus.ServerCore) {
                $ExpectedWinGetUpdateOnly = $false
                $ExpectedWinGetMaintenanceOnly = $false
            }
            if ([int]$legacyStatus.Build -le 17763) {
                if ($legacyStatus.MaintenanceCurrent -and $legacyStatus.HasStatusFunction -and (Test-WindowsUpdateAdmVersion -Actual $legacyStatus.DeploymentVersion -Expected $ExpectedDeploymentVersion) -and
                    $legacyStatus.ChocolateyUpdateOnly -eq $ExpectedChocolateyUpdateOnly -and
                    $legacyStatus.WinGetMaintenanceOnly -eq $ExpectedWinGetMaintenanceOnly -and
                    $legacyStatus.ChocolateyMaintenanceOnly -eq $ExpectedChocolateyMaintenanceOnly -and
                    (-not $ExpectedWinGetUpdateOnly -or $legacyStatus.WinGetUpdateOnly)) {
                    return [PSCustomObject]@{ IsCurrent = $true; Reason = ''; Version = [string]$legacyStatus.DeploymentVersion }
                }
                $reason = "Server-Build $($legacyStatus.Build): Modulversion '$($legacyStatus.DeploymentVersion)' gefunden; erwartet wird $ExpectedDeploymentVersion."
            }
        }
        catch { $reason += " Zertifikatsprüfung am normalen WinRM-Endpunkt ebenfalls fehlgeschlagen: $($_.Exception.Message)" }
    }

    [PSCustomObject]@{ IsCurrent = $false; Reason = $reason; Version = '' }
}

function Wait-WindowsUpdateDeploymentFinalization {
    param(
        [Parameter(Mandatory)][string]$Servername,
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$ClientCertificate,
        [string]$SetupLogPath,
        [ValidateRange(30, 900)][int]$TimeoutSeconds = 300
    )

    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    $lastConnectionError = $null
    do {
        $state = $null
        try {
            $state = Invoke-Command -ComputerName $Servername -UseSSL `
                -CertificateThumbprint $ClientCertificate.Thumbprint `
                -ArgumentList $SetupLogPath -ErrorAction Stop -ScriptBlock {
                    param($logPath)
                    if ([string]::IsNullOrWhiteSpace([string]$logPath) -or -not (Test-Path -LiteralPath $logPath -PathType Leaf)) {
                        $logPath = Get-ChildItem -LiteralPath (Join-Path $env:ProgramData 'WindowsUpdateAdm\Logs') `
                            -Filter ("Setup_{0}_*.log" -f $env:COMPUTERNAME) -File -ErrorAction SilentlyContinue |
                            Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
                    }
                    $content = if ($logPath -and (Test-Path -LiteralPath $logPath -PathType Leaf)) {
                        Get-Content -LiteralPath $logPath -Raw -ErrorAction SilentlyContinue
                    } else { '' }
                    $failure = [regex]::Match([string]$content, '(?im)^.*(?:\[ERROR\].*(?:FEHLER beim Setup|Setup fehlgeschlagen)|Setup fehlgeschlagen; vollständige Diagnose).*$')
                    $task = Get-ScheduledTask -TaskName 'WindowsUpdateAdm-Finalize' -ErrorAction SilentlyContinue
                    [pscustomobject]@{
                        Complete = [string]$content -match '(?i)Lokales Setup abgeschlossen; zentrale Endpunktprüfung folgt'
                        Failure = if ($failure.Success) { $failure.Value.Trim() } else { '' }
                        TaskState = if ($task) { [string]$task.State } else { 'Nicht vorhanden' }
                        LogPath = [string]$logPath
                    }
                }
            $lastConnectionError = $null
        }
        catch {
            $lastConnectionError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        }
        if ($state -and $state.Complete) { return $state }
        if ($state -and -not [string]::IsNullOrWhiteSpace([string]$state.Failure)) {
            throw "SYSTEM-Finalisierung auf $Servername fehlgeschlagen: $($state.Failure)"
        }

        if ((Get-Date) -ge $deadline) {
            $detail = if ($lastConnectionError) { " Letzter Verbindungsfehler: $lastConnectionError" } else { '' }
            throw "SYSTEM-Finalisierung auf $Servername wurde innerhalb von $TimeoutSeconds Sekunden nicht abgeschlossen.$detail"
        }
        Start-Sleep -Seconds 5
    } while ($true)
}



# Verteilungsablauf: WinRM-Verbindung, Komponentenübertragung und Ergebnisbewertung.
function Add-WindowsUpdateTrustedWinRMServerCertificate {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Servername,
        [Parameter(Mandatory)][scriptblock]$WriteLog
    )

    $writeLogCallback = $WriteLog
    function Write-DeployLog {
        param([AllowEmptyString()][string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info', [switch]$LogOnly, [switch]$ConsoleOnly)
        & $writeLogCallback -Message $Message -Level $Level -LogOnly:$LogOnly -ConsoleOnly:$ConsoleOnly
    }
    $serverCertificate = Invoke-Command -Session $Session -ScriptBlock {
        $listener = Get-ChildItem WSMan:\localhost\Listener |
            Where-Object { (Get-Item "$($_.PSPath)\Transport" -ErrorAction Stop).Value -eq 'HTTPS' } |
            Select-Object -First 1
        if (-not $listener) { throw 'Kein WinRM-HTTPS-Listener vorhanden.' }
        $thumbprint = (Get-Item "$($listener.PSPath)\CertificateThumbprint" -ErrorAction Stop).Value
        $certificate = Get-Item "Cert:\LocalMachine\My\$thumbprint" -ErrorAction Stop
        [PSCustomObject]@{
            Thumbprint = $certificate.Thumbprint
            Subject    = $certificate.Subject
            RawData    = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        }
    } -ErrorAction Stop

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$serverCertificate.RawData)
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $known = $store.Certificates | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } | Select-Object -First 1
        if (-not $known) {
            $store.Add($certificate)
            Write-DeployLog "WinRM-Serverzertifikat für $Servername als vertrauenswürdig hinterlegt." -Level Success
        } else {
            Write-DeployLog "WinRM-Serverzertifikat für $Servername ist bereits vertrauenswürdig." -LogOnly
        }
    }
    finally {
        $store.Close()
        $certificate.Dispose()
    }
}

function Invoke-WindowsUpdateWinRMDeployment {
    param(
        [string]$Servername,
        [string]$PSSCfgSkriptFile,
        [string]$CommonModuleFile = 'WindowsUpdate.Common.psm1',
        [string]$RootDirectory,
        [string]$OfflineModulePayloadRoot,
        [string]$DeployType,
        [switch]$CleanupLegacyTempOnly,
        [Parameter(Mandatory)][string]$ExpectedDeploymentVersion,
        [bool]$ExpectedWinGetUpdateOnly = $false,
        [bool]$ExpectedChocolateyUpdateOnly = $true,
        [bool]$ExpectedWinGetMaintenanceOnly = $true,
        [bool]$ExpectedChocolateyMaintenanceOnly = $true,
        [Parameter(Mandatory)][object]$UpdateSettings,
        [Parameter(Mandatory)][bool]$EnableWingetUpdates,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedModuleVersions,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BootstrapCredentials,
        [string[]]$ManagementServerAddresses = @(),
        [Parameter(Mandatory)][scriptblock]$WriteLog
    )

    $writeLogCallback = $WriteLog
    function Write-DeployLog {
        param([AllowEmptyString()][string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info', [switch]$LogOnly, [switch]$ConsoleOnly)
        & $writeLogCallback -Message $Message -Level $Level -LogOnly:$LogOnly -ConsoleOnly:$ConsoleOnly
    }
    $session = $null
    $remoteTemp = $null
    $targetModulePayloadRoot = $null
    $usedCertificate = $false
    $bootstrapCredential = $null
    try {
        if (-not $CleanupLegacyTempOnly) {
            Write-DeployLog "[$Servername] Prüfe vorhandene WindowsUpdateAdm-Version und Verbindung."
            $preflight = Test-WindowsUpdateDeploymentConfiguration -Servername $Servername -DeployType $DeployType -ExpectedDeploymentVersion $ExpectedDeploymentVersion -ExpectedWinGetUpdateOnly $ExpectedWinGetUpdateOnly -ExpectedChocolateyUpdateOnly $ExpectedChocolateyUpdateOnly -ExpectedWinGetMaintenanceOnly $ExpectedWinGetMaintenanceOnly -ExpectedChocolateyMaintenanceOnly $ExpectedChocolateyMaintenanceOnly -UpdateSettings $UpdateSettings -ManagementComputerName $env:COMPUTERNAME
            if ($preflight.IsCurrent) {
                $preflightCertificate = if ($DeployType -ne 'AD') { Get-WindowsUpdateDeploymentClientCertificate -UpdateSettings $UpdateSettings -ComputerName $env:COMPUTERNAME } else { $null }
                $authLabel = if ($DeployType -eq 'AD') { 'Kerberos' } else { "Clientzertifikat $($preflightCertificate.Thumbprint)" }
                Write-DeployLog "[$Servername] WindowsUpdateAdm-Endpunkt und Statusfunktion (Version $($preflight.Version)) erfolgreich getestet." -Level Success
                Write-DeployLog "[$Servername] Konfiguration aktuell; Verbindung per $authLabel erfolgreich. Einrichtung wird übersprungen." -LogOnly
                return [PSCustomObject]@{
                    Status = 'Success'
                    Message = "WindowsUpdateAdm Version $($preflight.Version) aktuell; Verbindung erfolgreich, keine Einrichtung erforderlich"
                }
            }
            Write-DeployLog "[$Servername] Vorabprüfung nicht erfolgreich; Einrichtung wird ausgeführt. $($preflight.Reason)" -LogOnly
        }

        if ($DeployType -ne 'AD') {
            # Lokale Konten auf Nicht-AD-Zielen dürfen nicht als
            # "Server\Benutzer" an Kerberos übergeben werden. Negotiate
            # erlaubt den NTLM-Fallback; TrustedHosts ist nur für den
            # einmaligen HTTP-Fallback relevant.
            Add-WindowsUpdateTrustedHost -ComputerName $Servername -WriteLog { param($message) Write-DeployLog $message }
            # Bei Wiederholungen zuerst das bereits eingerichtete Client-Zertifikat testen.
            # Nur bei einer echten Ersteinrichtung werden Zugangsdaten benötigt.
            $clientCert = Get-WindowsUpdateDeploymentClientCertificate -UpdateSettings $UpdateSettings -ComputerName $env:COMPUTERNAME
            if ($clientCert) {
                try {
                    Write-DeployLog "Prüfe Client-Zertifikatsverbindung zu $Servername." -LogOnly
                    $session = New-PSSession -ComputerName $Servername -UseSSL `
                        -CertificateThumbprint $clientCert.Thumbprint `
                        -ErrorAction Stop
                    $usedCertificate = $true
                    Write-DeployLog "Client-Zertifikatsverbindung zu $Servername erfolgreich." -LogOnly
                }
                catch {
                    Write-DeployLog "Vertrauenskette für $Servername wird einmalig eingerichtet." -LogOnly
                    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'WinRM-Zertifikatsverbindung' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Zertifikat einmalig mit Vertrauensmigration erneut versuchen')
                    try {
                        $session = New-PSSession -ComputerName $Servername -UseSSL `
                            -CertificateThumbprint $clientCert.Thumbprint `
                            -SessionOption (New-PSSessionOption -SkipCACheck) `
                            -ErrorAction Stop
                        $usedCertificate = $true
                        Write-DeployLog "Vorhandenes Client-Zertifikat für die Vertrauensmigration auf $Servername verwendet." -LogOnly
                    }
                    catch {
                        Write-DeployLog "Client-Zertifikat für $Servername nicht verfügbar; verwende Einrichtungsdaten." -LogOnly
                        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'WinRM-Zertifikatsverbindung mit Vertrauensmigration' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Einrichtungsdaten')
                    }
                }
            }

            if (-not $session) {
                if ($BootstrapCredentials.ContainsKey($Servername)) {
                    $bootstrapCredential = $BootstrapCredentials[$Servername]
                    Write-DeployLog "Verwende für $Servername gespeicherte Zugangsdaten für '$($bootstrapCredential.UserName)'." -LogOnly
                } else {
                    Write-DeployLog "Einmalige Anmeldedaten für $Servername werden benötigt." -Level Warning
                    $bootstrapCredential = Get-WindowsUpdateDeploymentBootstrapCredential -Servername $Servername
                }
                if (-not $bootstrapCredential) {
                    throw "Die Zugangsdaten für $Servername wurden nicht eingegeben."
                }
                Write-DeployLog "WinRM-Anmeldung für $Servername mit Benutzer '$($bootstrapCredential.UserName)'." -LogOnly
                Write-DeployLog "[$Servername] Verbinde per WinRM ($DeployType)."
                try {
                    $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -UseSSL `
                        -SessionOption (New-PSSessionOption -SkipCACheck) -ErrorAction Stop
                }
                catch {
                    # Vor der Einrichtung existiert bei manchen Geräten noch kein
                    # HTTPS-Listener. HTTP ist ausschließlich der einmalige Fallback.
                    Write-DeployLog "[$Servername] WinRM/HTTPS nicht verfügbar; HTTP-Fallback."
                    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'WinRM-HTTPS-Verbindung' -Target $Servername -ErrorRecord $_ -Context @('Fallback=HTTP für einmalige Ersteinrichtung')
                    try {
                        $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -ErrorAction Stop
                    }
                    catch {
                        # Zugangsdaten können je Nicht-AD-Gerät abweichen. Bei
                        # Ablehnung genau dieses Ziel neu abfragen und den
                        # Benutzernamen im Log (ohne Kennwort) nachvollziehbar machen.
                        Write-DeployLog "Einrichtungsdaten für $Servername wurden abgelehnt." -Level Warning
                        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'WinRM-HTTP-Anmeldung' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Anmeldedaten erneut abfragen')
                        $bootstrapCredential = Get-WindowsUpdateDeploymentBootstrapCredential -Servername $Servername
                        if (-not $bootstrapCredential) {
                            throw "Die erneuten Zugangsdaten für $Servername wurden nicht eingegeben."
                        }
                        Write-DeployLog "Erneuter WinRM-Anmeldeversuch für $Servername mit Benutzer '$($bootstrapCredential.UserName)'." -LogOnly
                        try {
                            $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -UseSSL `
                                -SessionOption (New-PSSessionOption -SkipCACheck) -ErrorAction Stop
                        }
                        catch {
                            Write-DeployLog "WinRM/HTTPS auf $Servername nicht verfügbar; einmaliger HTTP-Fallback." -LogOnly
                            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'WinRM-HTTPS-Wiederholungsverbindung' -Target $Servername -ErrorRecord $_ -Context @('Fallback=HTTP für einmalige Ersteinrichtung')
                            $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -ErrorAction Stop
                        }
                    }
                }
                $BootstrapCredentials[$Servername] = $bootstrapCredential
            }
        } else {
            Write-DeployLog "[$Servername] Verbinde per WinRM ($DeployType)."
            $session = New-PSSession -ComputerName $Servername -ErrorAction Stop
        }

        # Alte Ablagerungen der früheren benutzerspezifischen TEMP-Ablage bereinigen.
        # Profilverzeichnisse werden nur dann entfernt, wenn sie unregistriert und
        # nach dem Löschen der eindeutig benannten Setup-Reste vollständig leer sind.
        $removedLegacyPaths = Invoke-Command -Session $session -ScriptBlock {
            $removed = [System.Collections.Generic.List[string]]::new()
            # Verbliebene markierte Setup-Ordner werden beim nächsten Lauf
            # nach 30 Minuten entfernt; die Schonfrist schützt parallele Setups.
            $cutoff = (Get-Date).AddMinutes(-30)
            $windowsTemp = Join-Path $env:WINDIR 'Temp'
            $usersRoot = Join-Path $env:SystemDrive 'Users'
            $registeredProfiles = @{}

            try {
                Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop | ForEach-Object {
                    $profilePath = (Get-ItemProperty -LiteralPath $_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
                    if ($profilePath) {
                        $normalizedProfile = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$profilePath)).TrimEnd('\')
                        $registeredProfiles[$normalizedProfile] = $true
                    }
                }
            }
            catch {
                # Ohne sichere Profilliste keine Benutzerordner entfernen.
                $registeredProfiles['__PROFILE_LOOKUP_FAILED__'] = $true
            }

            $legacyTemps = [System.Collections.Generic.List[string]]::new()
            $legacyTemps.Add($windowsTemp)
            $userDirectories = @()
            if (Test-Path -LiteralPath $usersRoot -PathType Container) {
                $userDirectories = @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue)
                foreach ($userDirectory in $userDirectories) {
                    $legacyTemps.Add((Join-Path $userDirectory.FullName 'AppData\Local\Temp'))
                }
            }

            foreach ($tempDirectory in @($legacyTemps | Select-Object -Unique)) {
                if (-not (Test-Path -LiteralPath $tempDirectory -PathType Container)) { continue }
                try {
                    $tempItem = Get-Item -LiteralPath $tempDirectory -Force -ErrorAction Stop
                    if ($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    foreach ($staleSetup in @(Get-ChildItem -LiteralPath $tempDirectory -Directory -Filter 'WindowsUpdateAdmSetup_*' -Force -ErrorAction SilentlyContinue)) {
                        if ($staleSetup.LastWriteTime -gt $cutoff -or ($staleSetup.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                        Remove-Item -LiteralPath $staleSetup.FullName -Recurse -Force -ErrorAction Stop
                        $removed.Add($staleSetup.FullName)
                    }
                }
                catch {
                    # Eine einzelne gesperrte Alt-Ablage verhindert keine neue Verteilung.
                }
            }

            foreach ($userDirectory in $userDirectories) {
                try {
                    if ($userDirectory.Name -in @('Default', 'Default User', 'Public', 'All Users')) { continue }
                    if ($userDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $profileTempPath = Join-Path $userDirectory.FullName 'AppData\Local\Temp'
                    if (-not (Test-Path -LiteralPath $profileTempPath -PathType Container)) { continue }
                    $normalizedUserPath = [IO.Path]::GetFullPath($userDirectory.FullName).TrimEnd('\')
                    if ($registeredProfiles.ContainsKey($normalizedUserPath) -or $registeredProfiles.ContainsKey('__PROFILE_LOOKUP_FAILED__')) { continue }

                    foreach ($emptyPath in @(
                        $profileTempPath,
                        (Join-Path $userDirectory.FullName 'AppData\Local'),
                        (Join-Path $userDirectory.FullName 'AppData'),
                        $userDirectory.FullName
                    )) {
                        if (-not (Test-Path -LiteralPath $emptyPath -PathType Container)) { continue }
                        $item = Get-Item -LiteralPath $emptyPath -Force -ErrorAction Stop
                        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { break }
                        if ([IO.Directory]::GetFileSystemEntries($emptyPath).Count -ne 0) { break }
                        Remove-Item -LiteralPath $emptyPath -Force -ErrorAction Stop
                        $removed.Add($emptyPath)
                    }
                }
                catch {
                    # Bei Unsicherheit bleibt der betreffende Ordner unangetastet.
                }
            }

            return @($removed)
        } -ErrorAction Stop
        foreach ($removedPath in @($removedLegacyPaths)) { Write-DeployLog "Veraltete Temp-Ablage bereinigt: $removedPath" -LogOnly }
        if ($CleanupLegacyTempOnly) {
            return [PSCustomObject]@{
                Status = 'Success'
                Message = 'Temp-Altlasten geprüft; WindowsUpdateAdm-Setup wurde auf Wunsch nicht erneut ausgeführt.'
            }
        }

        $targetOsForWinGet = Invoke-Command -Session $session -ErrorAction Stop -ScriptBlock {
            Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop | Select-Object BuildNumber, ProductType, @{ Name = 'InstallationType'; Expression = { (Get-ItemProperty -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -Name InstallationType -ErrorAction SilentlyContinue).InstallationType } }
        }
        if ($targetOsForWinGet.InstallationType -eq 'Server Core' -or
            ([int]$targetOsForWinGet.ProductType -gt 1 -and [int]$targetOsForWinGet.BuildNumber -lt 17763)) {
            $EnableWingetUpdates = $false
            $ExpectedWinGetUpdateOnly = $false
            $ExpectedWinGetMaintenanceOnly = $false
            $skipReason = if ($targetOsForWinGet.InstallationType -eq 'Server Core') { 'Server Core' } else { 'Windows Server älter als 2019' }
            Write-DeployLog "[$Servername] WinGet-Bereitstellung ausgelassen: $skipReason."
        }

        # Nur veraltete oder fehlende Komponenten werden als Offlinepaket erstellt.
        $targetModuleStatus = Invoke-Command -Session $session -ArgumentList ([bool]$EnableWingetUpdates) -ScriptBlock {
            param($includeWinGet)
            function Get-HighestInstalledModuleVersion {
                param([string]$Name)
                $roots = @(
                    (Join-Path $env:ProgramFiles "WindowsPowerShell\Modules\$Name"),
                    (Join-Path $env:ProgramFiles "PowerShell\Modules\$Name")
                )
                $versions = foreach ($root in $roots) {
                    if (Test-Path -LiteralPath $root -PathType Container) {
                        Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                            Where-Object Name -Match '^\d+(\.\d+){1,3}$' |
                            ForEach-Object { try { [version]$_.Name } catch { } }
                    }
                }
                @($versions | Sort-Object -Descending | Select-Object -First 1)[0]
            }
            $nugetRoot = Join-Path $env:ProgramFiles 'PackageManagement\ProviderAssemblies\nuget'
            $nugetVersions = @()
            if (Test-Path -LiteralPath $nugetRoot -PathType Container) {
                $nugetVersions = @(Get-ChildItem -LiteralPath $nugetRoot -Directory -ErrorAction SilentlyContinue |
                    Where-Object Name -Match '^\d+(\.\d+){1,3}$' |
                    ForEach-Object { try { [version]$_.Name } catch { } })
            }
            [pscustomobject]@{
                PSWindowsUpdate = Get-HighestInstalledModuleVersion 'PSWindowsUpdate'
                WinGetClient = if ($includeWinGet) { Get-HighestInstalledModuleVersion 'Microsoft.WinGet.Client' } else { $null }
                NuGet = @($nugetVersions | Sort-Object -Descending | Select-Object -First 1)[0]
            }
        } -ErrorAction Stop

        $modulesToStage = [System.Collections.Generic.List[string]]::new()
        foreach ($moduleName in @('PSWindowsUpdate', $(if ($EnableWingetUpdates) { 'Microsoft.WinGet.Client' }))) {
            if ([string]::IsNullOrWhiteSpace($moduleName)) { continue }
            $expected = $ExpectedModuleVersions[$moduleName]
            $statusProperty = if ($moduleName -eq 'Microsoft.WinGet.Client') { 'WinGetClient' } else { 'PSWindowsUpdate' }
            $installed = $targetModuleStatus.PSObject.Properties[$statusProperty].Value
            if (-not $expected -or -not $installed -or ([version]$installed -lt [version]$expected)) {
                $modulesToStage.Add($moduleName)
            }
        }
        $nugetMinimum = [version]'2.8.5.201'
        $nugetExpected = if ($ExpectedModuleVersions.Contains('NuGet')) { [version]$ExpectedModuleVersions['NuGet'] } else { $null }
        $nugetInstalled = if ($targetModuleStatus.NuGet) { [version]$targetModuleStatus.NuGet } else { $null }
        $nugetNeeded = if ($nugetExpected) {
            -not $nugetInstalled -or $nugetInstalled -lt $nugetExpected
        } else {
            -not $nugetInstalled -or $nugetInstalled -lt $nugetMinimum
        }
        $modulesVerifiedCurrent = ($modulesToStage.Count -eq 0 -and -not $nugetNeeded)
        $moduleStateText = foreach ($moduleName in @('PSWindowsUpdate', $(if ($EnableWingetUpdates) { 'Microsoft.WinGet.Client' }))) {
            if (-not [string]::IsNullOrWhiteSpace($moduleName)) {
                $statusProperty = if ($moduleName -eq 'Microsoft.WinGet.Client') { 'WinGetClient' } else { 'PSWindowsUpdate' }
                $installed = $targetModuleStatus.PSObject.Properties[$statusProperty].Value
                '{0} {1}/{2}' -f $moduleName, $installed, $ExpectedModuleVersions[$moduleName]
            }
        }
        $nugetExpectedText = if ($nugetExpected) { [string]$nugetExpected } else { "Onlineversion nicht ermittelbar; Mindestversion $nugetMinimum" }
        $moduleStateText += 'NuGet {0}/{1}' -f $targetModuleStatus.NuGet, $nugetExpectedText
        Write-DeployLog "[$Servername] Versionsprüfung: $($moduleStateText -join '; ')." -LogOnly
        if ($modulesVerifiedCurrent) {
            Write-DeployLog "[$Servername] PSWindowsUpdate, NuGet und optionale WinGet-Module sind aktuell; keine Offlinepakete werden übertragen." -LogOnly
        } else {
            $targetModulePayloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-Zielpakete-{0}' -f [guid]::NewGuid().ToString('N'))
            New-Item -ItemType Directory -Path $targetModulePayloadRoot -Force -ErrorAction Stop | Out-Null
            if ($modulesToStage.Count -gt 0) {
                $modulePayload = New-WindowsUpdateModulePayload -ModuleName @($modulesToStage) -OfflineModulePath $RootDirectory -WriteLog {
                    param($message, $level)
                    $deployLevel = switch ($level) { 'WARN' { 'Warning' } 'ERROR' { 'Error' } 'SUCCESS' { 'Success' } default { 'Info' } }
                    Write-DeployLog "[$Servername] $message" -Level $deployLevel -LogOnly
                }
                foreach ($moduleDirectory in @(Get-ChildItem -LiteralPath $modulePayload.Root -Directory -ErrorAction Stop)) {
                    Copy-Item -LiteralPath $moduleDirectory.FullName -Destination $targetModulePayloadRoot -Recurse -Force -ErrorAction Stop
                }
                Remove-Item -LiteralPath $modulePayload.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
            if ($nugetNeeded) {
                $null = New-WindowsUpdateNuGetProviderPayload -DestinationPath $targetModulePayloadRoot -WriteLog {
                    param($message, $level)
                    $deployLevel = switch ($level) { 'WARN' { 'Warning' } 'ERROR' { 'Error' } 'SUCCESS' { 'Success' } default { 'Info' } }
                    Write-DeployLog "[$Servername] $message" -Level $deployLevel -LogOnly
                }
            }
            $stagedNames = @($modulesToStage)
            if ($nugetNeeded) { $stagedNames += 'NuGet' }
            Write-DeployLog "[$Servername] Übertrage nur fehlende/veraltete Komponenten: $($stagedNames -join ', ')." -LogOnly
        }

        $remoteTemp = Invoke-Command -Session $session -ScriptBlock {
            param($folderName)
            # Nicht den benutzerspezifischen TEMP-Pfad verwenden: WinRM kann
            # dort einen nicht existierenden Profilpfad liefern. Der Ordner
            # bleibt deshalb im maschinenweiten Windows-Temp-Verzeichnis.
            Join-Path (Join-Path $env:WINDIR 'Temp') $folderName
        } -ArgumentList "WindowsUpdateAdmSetup_$([guid]::NewGuid().ToString('N'))" -ErrorAction Stop

        Invoke-Command -Session $session -ScriptBlock {
            param($path)
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        } -ArgumentList $remoteTemp -ErrorAction Stop

        Write-DeployLog "[$Servername] Übertrage Setup."
        if ($EnableWingetUpdates) {
            Write-DeployLog "[$Servername] Prüfe zentralen WinGet-Downloadcache auf dem Verwaltungsserver."
            $cachedArtifacts = @(Get-WindowsUpdateWinGetCachedArtifacts -WriteLog { param($line) Write-DeployLog $line })
            foreach ($artifact in $cachedArtifacts) {
                $key = Split-Path -Leaf $artifact.Folder
                $alreadyPresent = Invoke-Command -Session $session -ArgumentList $key,$artifact.Bytes,$artifact.Sha256 -ErrorAction Stop -ScriptBlock {
                    param($key,$bytes,$hash)
                    if ($key -notmatch '^[a-f0-9]{64}$') { throw 'Ungültiger Cachebezeichner.' }
                    $path = Join-Path (Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm\DownloadCache') $key) 'payload.bin'
                    $manifest = Join-Path (Split-Path -Parent $path) 'payload.json'
                    if (-not (Test-Path -LiteralPath $path) -or -not (Test-Path -LiteralPath $manifest)) { return $false }
                    try {
                        $saved = [IO.File]::ReadAllText($manifest) | ConvertFrom-Json
                        return ((Get-Item -LiteralPath $path).Length -eq $bytes -and $saved.Bytes -eq $bytes -and $saved.Sha256 -eq $hash -and (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -eq $hash)
                    } catch { return $false }
                }
                if ($alreadyPresent) { Write-DeployLog "[$Servername] Cachedatei $($artifact.Name) bereits vollständig vorhanden."; continue }
                $stage = Invoke-Command -Session $session -ArgumentList $remoteTemp,$key -ErrorAction Stop -ScriptBlock {
                    param($root,$key)
                    $folder = Join-Path $root $key
                    New-Item -ItemType Directory -Path $folder -Force | Out-Null
                    $folder
                }
                foreach ($name in @('payload.bin','payload.json')) {
                    Copy-Item -LiteralPath (Join-Path $artifact.Folder $name) -Destination (Join-Path $stage $name) -ToSession $session -Force -ErrorAction Stop
                }
                Invoke-Command -Session $session -ArgumentList $stage,$key,$artifact.Bytes,$artifact.Sha256 -ErrorAction Stop -ScriptBlock {
                    param($stage,$key,$bytes,$hash)
                    if ($key -notmatch '^[a-f0-9]{64}$') { throw 'Ungültiger Cachebezeichner.' }
                    $source = Join-Path $stage 'payload.bin'
                    if ((Get-Item -LiteralPath $source).Length -ne $bytes -or (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash -ne $hash) { throw 'Übertragene WinGet-Cachedatei ist unvollständig oder beschädigt.' }
                    $destination = Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm\DownloadCache') $key
                    New-Item -ItemType Directory -Path $destination -Force | Out-Null
                    Move-Item -LiteralPath $source -Destination (Join-Path $destination 'payload.bin') -Force
                    Copy-Item -LiteralPath (Join-Path $stage 'payload.json') -Destination (Join-Path $destination 'payload.json') -Force
                } | Out-Null
                Write-DeployLog "[$Servername] Cachedatei $($artifact.Name) übertragen und SHA256 geprüft."
            }
        }
        Copy-Item -Path (Join-Path (Join-Path $RootDirectory 'Komponenten') $PSSCfgSkriptFile) `
                  -Destination (Join-Path $remoteTemp $PSSCfgSkriptFile) `
                  -ToSession $session -Force -ErrorAction Stop
        Copy-Item -Path (Join-Path (Join-Path $RootDirectory 'Module') $CommonModuleFile) `
                  -Destination (Join-Path $remoteTemp $CommonModuleFile) `
                  -ToSession $session -Force -ErrorAction Stop
        foreach ($componentModule in @(Get-ChildItem -LiteralPath (Join-Path $RootDirectory 'Module') -Filter 'WindowsUpdate.*.psm1' -File -ErrorAction Stop |
                Where-Object Name -ne $CommonModuleFile)) {
            Copy-Item -LiteralPath $componentModule.FullName -Destination (Join-Path $remoteTemp $componentModule.Name) `
                      -ToSession $session -Force -ErrorAction Stop
        }
        foreach ($maintenanceFile in @('WindowsUpdate.WinGetMaintenance.ps1', 'WindowsUpdate.WinGetMaintenanceBridge.ps1')) {
            Copy-Item -LiteralPath (Join-Path (Join-Path $RootDirectory 'Module') $maintenanceFile) -Destination (Join-Path $remoteTemp $maintenanceFile) -ToSession $session -Force -ErrorAction Stop
        }
        if ($targetModulePayloadRoot -and (Test-Path -LiteralPath $targetModulePayloadRoot -PathType Container)) {
            foreach ($moduleDirectory in @(Get-ChildItem -LiteralPath $targetModulePayloadRoot -Directory -ErrorAction Stop)) {
                Copy-Item -LiteralPath $moduleDirectory.FullName -Destination $remoteTemp `
                          -ToSession $session -Recurse -Force -ErrorAction Stop
            }
        }

        # AD-Geräte erhalten weder Client-Zertifikat noch Zertifikats-Mapping.
        if ($DeployType -ne 'AD') {
            $certSource = Join-Path (Join-Path $RootDirectory 'Komponenten') 'WinRM-ClientCert.cer'
            if (-not (Test-Path $certSource)) {
                throw "Client-Zertifikat fehlt: $certSource. Zuerst Setup-ClientCertificate.ps1 ausführen."
            }
            Copy-Item -Path $certSource -Destination (Join-Path $remoteTemp 'WinRM-ClientCert.cer') `
                      -ToSession $session -Force -ErrorAction Stop
        }

        $setupParameters = @{}
        $setupParameters.DeploymentVersion = $ExpectedDeploymentVersion
        if ($EnableWingetUpdates) { $setupParameters.InstallWinGetClientModule = $true }
        if (-not $modulesVerifiedCurrent -and $targetModulePayloadRoot) {
            $setupParameters.OfflineModuleRoot = $remoteTemp
        }
        if ($modulesVerifiedCurrent) { $setupParameters.ModulesVerifiedCurrent = $true }
        if ($DeployType -ne 'AD') { $setupParameters.EnableClientCertificateRemoting = $true }
        if ($DeployType -eq 'Hypervisor' -and -not $usedCertificate) {
            $setupParameters.CertificateMappingCredential = $bootstrapCredential
        } elseif ($DeployType -eq 'Additional' -and -not $usedCertificate) {
            $setupParameters.CertificateMappingCredential = $bootstrapCredential
        } elseif ($DeployType -ne 'AD' -and $usedCertificate) {
            $setupParameters.PreserveExistingCertificateMapping = $true
        }
        if ($DeployType -eq 'AD') {
            # Ein Check-Task unter LocalSystem meldet sich an AD-Zielen mit
            # dem Computerkonto des Verwaltungsservers an. JEA erhält dafür
            # eine separate, auf Get-WindowsUpdate beschränkte Rolle.
            try {
                $managerComputer = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
                if (-not $managerComputer.PartOfDomain) {
                    throw 'Der Verwaltungsserver ist keiner AD-Domäne beigetreten.'
                }
                $managerDomain = Get-ADDomain -Identity ([string]$managerComputer.Domain) -ErrorAction Stop
                if ([string]::IsNullOrWhiteSpace([string]$managerDomain.NetBIOSName)) {
                    throw "NetBIOS-Domänenname für '$($managerComputer.Domain)' konnte nicht ermittelt werden."
                }
                $managerAdComputer = Get-ADComputer -Identity $env:COMPUTERNAME -Server $managerDomain.DNSRoot -Properties SID -ErrorAction Stop
                if (-not $managerAdComputer.SID) {
                    throw "AD hat keine SID für das Verwaltungsserver-Computerkonto '$env:COMPUTERNAME' geliefert."
                }
                $managerSidValue = if ($managerAdComputer.SID -is [System.Security.Principal.SecurityIdentifier]) {
                    $managerAdComputer.SID.Value
                } else {
                    [string]$managerAdComputer.SID
                }
                if ([string]::IsNullOrWhiteSpace($managerSidValue)) {
                    throw "AD hat eine leere SID für das Verwaltungsserver-Computerkonto '$env:COMPUTERNAME' geliefert."
                }
                $setupParameters.ManagementComputerAccount = '{0}\{1}$' -f $managerDomain.NetBIOSName, $env:COMPUTERNAME
                $setupParameters.ManagementComputerSid = $managerSidValue
                Write-DeployLog "[$Servername] JEA-Zugriff für SYSTEM-Check wird auf das Verwaltungsserver-Computerkonto $($setupParameters.ManagementComputerAccount) beschränkt." -LogOnly
                Write-DeployLog "[$Servername] Verwaltungsserver-SID für die JEA-ACL wurde zentral aus AD ermittelt: $($setupParameters.ManagementComputerSid)." -LogOnly
            }
            catch {
                throw "Computerkonto des Verwaltungsservers für den geplanten SYSTEM-Check konnte nicht ermittelt werden: $($_.Exception.Message)"
            }
        }
        if (@($ManagementServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            $setupParameters.ManagementServerAddresses = @($ManagementServerAddresses)
        }

        Write-DeployLog "[$Servername] Führe Setup aus ($DeployType)."
        $remoteSetupOutput = @(Invoke-Command -Session $session -ScriptBlock {
            param($path, $scriptName, $parameters)
            # Die zentrale Richtlinie des Zielsystems bleibt unverändert:
            # Bypass gilt nur für diesen kurzlebigen WinRM-Prozess, damit das
            # vertrauenswürdige Setup aus dem temporären Ablageordner starten kann.
            Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force -ErrorAction Stop
            # Sämtliche Setup-Ausgaben als Daten zurückgeben. Sonst werden
            # Write-Host- und Warnungszeilen trotz LogOnly live in die Konsole
            # des Verwaltungsrechners durchgereicht.
            & (Join-Path $path $scriptName) @parameters *>&1
        } -ArgumentList $remoteTemp, $PSSCfgSkriptFile, $setupParameters -ErrorAction Stop *>&1)
        foreach ($entry in $remoteSetupOutput) {
            $entryText = if ($entry -is [System.Management.Automation.InformationRecord]) { [string]$entry.MessageData } else { [string]$entry }
            Write-DeployLog $entryText -LogOnly
        }
        $setupErrors = @($remoteSetupOutput | Where-Object {
            $_ -is [System.Management.Automation.ErrorRecord] -or
            ([string]$_ -match '(?i)\[ERROR\]|FEHLER beim Setup')
        })
        if ($setupErrors.Count -gt 0) {
            $setupErrorText = if ($setupErrors[0] -is [System.Management.Automation.ErrorRecord]) { $setupErrors[0].Exception.Message } else { [string]$setupErrors[0] }
            throw "Setup auf $Servername meldete einen Fehler: $setupErrorText"
        }

        if ($DeployType -ne 'AD') {
            Add-WindowsUpdateTrustedWinRMServerCertificate -Session $session -Servername $Servername -WriteLog $WriteLog
        }

        # Das Remote-Setup plant den WinRM-Neustart absichtlich verzögert,
        # damit diese erste Sitzung sauber enden kann. Auf Nicht-AD Server
        # 2016/2019 wird Windows Update später bewusst via SYSTEM-Aufgabe
        # ausgeführt; ein funktionierender JEA-Endpunkt ist dort keine
        # Voraussetzung für eine erfolgreiche Einrichtung.
        $requiresJeaEndpointTest = $DeployType -eq 'AD'
        if ($DeployType -ne 'AD') {
            try {
                $versionProbe = Invoke-Command -Session $session -ScriptBlock {
                    [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber
                } -ErrorAction Stop
                if ([int]$versionProbe -gt 17763) { $requiresJeaEndpointTest = $true }
                else {
                    Write-DeployLog "[$Servername] Windows Server 2016/2019: JEA-Test entfällt."
                }
            }
            catch {
                # Kann die Version nicht bestimmt werden, wird der etablierte
                # Endpunkttest beibehalten statt eine unvollständige Einrichtung
                # als erfolgreich zu melden.
                $requiresJeaEndpointTest = $true
            }
        }

        if (-not $requiresJeaEndpointTest) {
            $clientCert = Get-WindowsUpdateDeploymentClientCertificate -UpdateSettings $UpdateSettings -ComputerName $env:COMPUTERNAME
            if (-not $clientCert) { throw 'Lokales Client-Zertifikat für die Finalisierungsprüfung wurde nicht gefunden.' }
            $setupLogPath = $null
            foreach ($setupEntry in $remoteSetupOutput) {
                $setupEntryText = if ($setupEntry -is [System.Management.Automation.InformationRecord]) { [string]$setupEntry.MessageData } else { [string]$setupEntry }
                if ($setupEntryText -match '(?i)Protokoll:\s*(?<Path>[A-Z]:\\[^\r\n]*Setup_[^\\\r\n]+\.log)') {
                    $setupLogPath = $Matches.Path.Trim()
                }
            }
            Write-DeployLog "[$Servername] Warte auf Abschluss der lokalen SYSTEM-Finalisierung vor der Zertifikatsprüfung." -LogOnly
            $finalization = Wait-WindowsUpdateDeploymentFinalization -Servername $Servername `
                -ClientCertificate $clientCert -SetupLogPath $setupLogPath -TimeoutSeconds 300

            $certificateStatus = Test-WindowsUpdateDeploymentConfiguration `
                -Servername $Servername `
                -DeployType $DeployType `
                -ExpectedDeploymentVersion $ExpectedDeploymentVersion `
                -ExpectedWinGetUpdateOnly $ExpectedWinGetUpdateOnly `
                -ExpectedChocolateyUpdateOnly $ExpectedChocolateyUpdateOnly `
                -ExpectedWinGetMaintenanceOnly $ExpectedWinGetMaintenanceOnly `
                -ExpectedChocolateyMaintenanceOnly $ExpectedChocolateyMaintenanceOnly `
                -UpdateSettings $UpdateSettings `
                -ManagementComputerName $env:COMPUTERNAME
            if (-not $certificateStatus.IsCurrent) {
                throw "WindowsUpdateAdm-Statusfunktion konnte per Clientzertifikat nicht bestätigt werden. $($certificateStatus.Reason)"
            }
            Write-DeployLog "[$Servername] WindowsUpdateAdm-Endpunkt und Statusfunktion (Version $($certificateStatus.Version)) erfolgreich getestet." -Level Success
            return [PSCustomObject]@{
                Status = 'Success'
                Message = "WindowsUpdateAdm eingerichtet; Statusfunktion (Version $($certificateStatus.Version)) per Clientzertifikat erfolgreich getestet; Windows Update erfolgt per SYSTEM-Aufgabe"
            }
        }

        Write-DeployLog "[$Servername] Warte auf WinRM-Neustart."
        Start-Sleep -Seconds 30

        $testParams = @{
            ComputerName      = $Servername
            ConfigurationName = 'WindowsUpdateAdm'
            ScriptBlock       = { Get-WindowsUpdateAdmDeploymentStatus -ErrorAction Stop }
            ErrorAction       = 'Stop'
        }
        if ($DeployType -ne 'AD') {
            $clientCert = Get-WindowsUpdateDeploymentClientCertificate -UpdateSettings $UpdateSettings -ComputerName $env:COMPUTERNAME
            if (-not $clientCert) {
                throw 'Lokales Client-Zertifikat für den Verbindungstest wurde nicht gefunden.'
            }
            $testParams.UseSSL               = $true
            $testParams.CertificateThumbprint = $clientCert.Thumbprint
        }

        Write-DeployLog "[$Servername] Teste WindowsUpdateAdm-Endpunkt."
        # GetNewClosure erfasst lokale Variablen zuverlässig. Die zentrale
        # Version liegt auf Skriptebene; zuerst in eine Funktionsvariable
        # kopieren, damit die Endpunktprüfung nicht mit leerem Sollwert läuft.
        $expectedVersionForValidation = ((@([string]$ExpectedDeploymentVersion -split '\.') + @('0','0','0'))[0..2] -join '.')
        $validationRequirements = @{
            ChocolateyUpdateOnly = [bool]$ExpectedChocolateyUpdateOnly
            WinGetMaintenanceOnly = [bool]$ExpectedWinGetMaintenanceOnly
            ChocolateyMaintenanceOnly = [bool]$ExpectedChocolateyMaintenanceOnly
            WinGetUpdateOnly = [bool]$ExpectedWinGetUpdateOnly
        }
        $validateEndpoint = {
            $deploymentStatus = Invoke-Command @testParams
            $winGetProperty = $deploymentStatus.PSObject.Properties['WinGetUpdateOnly']
            $chocolateyProperty = $deploymentStatus.PSObject.Properties['ChocolateyUpdateOnly']
            $maintenanceProperty = $deploymentStatus.PSObject.Properties['WinGetMaintenanceOnly']
            $chocolateyMaintenanceProperty = $deploymentStatus.PSObject.Properties['ChocolateyMaintenanceOnly']
            $status = [PSCustomObject]@{
                DeploymentVersion = ((@([string]$deploymentStatus.Version -split '\.') + @('0','0','0'))[0..2] -join '.')
                WinGetUpdateOnly = [bool]$(if ($winGetProperty) { $winGetProperty.Value } else { $false })
                ChocolateyUpdateOnly = [bool]$(if ($chocolateyProperty) { $chocolateyProperty.Value } else { $false })
                WinGetMaintenanceOnly = [bool]$(if ($maintenanceProperty) { $maintenanceProperty.Value -and $deploymentStatus.PSObject.Properties['MaintenanceRevision'] -and $deploymentStatus.MaintenanceRevision -eq '6' } else { $false })
                ChocolateyMaintenanceOnly = [bool]$(if ($chocolateyMaintenanceProperty) { $chocolateyMaintenanceProperty.Value } else { $false })
            }
            if ($status.DeploymentVersion -ne $expectedVersionForValidation -or
                $status.ChocolateyUpdateOnly -ne $validationRequirements.ChocolateyUpdateOnly -or
                $status.WinGetMaintenanceOnly -ne $validationRequirements.WinGetMaintenanceOnly -or
                $status.ChocolateyMaintenanceOnly -ne $validationRequirements.ChocolateyMaintenanceOnly -or
                ($validationRequirements.WinGetUpdateOnly -and -not $status.WinGetUpdateOnly)) {
                throw "WindowsUpdateAdm-Statusfunktion auf $Servername entspricht nicht dem Sollstand (Ist: WinGet=$($status.WinGetUpdateOnly), Choco=$($status.ChocolateyUpdateOnly), WinGet-Wartung=$($status.WinGetMaintenanceOnly), Choco-Wartung=$($status.ChocolateyMaintenanceOnly); Soll: $($validationRequirements | Out-String); Version gefunden: '$($status.DeploymentVersion)', erwartet: '$expectedVersionForValidation')."
            }
            return $status
        }.GetNewClosure()
        $endpointStatus = Invoke-WindowsUpdateWithRetry -OperationName "WindowsUpdateAdm-Endpunkt auf $Servername" -RetryCount 5 -RetryDelaySeconds 30 -WriteLog {
            param($message)
            if ($message -like 'Wiederhole *') {
                Write-DeployLog "WindowsUpdateAdm-Endpunkt auf $Servername noch nicht bereit; erneuter Versuch folgt." -LogOnly
            }
        } -ScriptBlock $validateEndpoint
        Write-DeployLog "[$Servername] WindowsUpdateAdm-Endpunkt und Statusfunktion (Version $ExpectedDeploymentVersion) erfolgreich getestet." -Level Success

        return [PSCustomObject]@{
            Status = 'Success'
            Message = if ($DeployType -eq 'AD') {
                'WindowsUpdateAdm per Kerberos konfiguriert'
            } else {
                'WindowsUpdateAdm eingerichtet; weitere Verbindungen erfolgen per Client-Zertifikat'
            }
        }
    }
    finally {
        if ($targetModulePayloadRoot -and (Test-Path -LiteralPath $targetModulePayloadRoot)) {
            Remove-Item -LiteralPath $targetModulePayloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        if ($session) {
            if ($remoteTemp) {
                try {
                    # Das Setup kann WinRM neu starten. Dadurch wird die zuvor
                    # verwendete Sitzung Broken, selbst wenn der Endpunkttest
                    # über eine neue Verbindung bereits erfolgreich war.
                    $cleanupSession = $session
                    try {
                        $remoteTempRemoved = Invoke-Command -Session $cleanupSession -ScriptBlock {
                            param($path)
                            if (Test-Path -LiteralPath $path) {
                                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                            }
                            return (-not (Test-Path -LiteralPath $path))
                        } -ArgumentList $remoteTemp -ErrorAction Stop
                    }
                    catch {
                        $initialCleanupError = $_
                        if ($cleanupSession.State -eq 'Opened') {
                            Remove-PSSession -Session $cleanupSession -ErrorAction SilentlyContinue
                        }
                        $cleanupSession = $null

                        # Bei einer abgebrochenen Sitzung für die Bereinigung
                        # eine frische WinRM-Verbindung mit denselben
                        # Anmeldedaten bzw. demselben Client-Zertifikat öffnen.
                        for ($attempt = 1; $attempt -le 5 -and -not $cleanupSession; $attempt++) {
                            try {
                                if ($DeployType -eq 'AD') {
                                    $cleanupSession = New-PSSession -ComputerName $Servername -ErrorAction Stop
                                } elseif ($usedCertificate -and $clientCert) {
                                    try {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -UseSSL `
                                            -CertificateThumbprint $clientCert.Thumbprint -ErrorAction Stop
                                    } catch {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -UseSSL `
                                            -CertificateThumbprint $clientCert.Thumbprint `
                                            -SessionOption (New-PSSessionOption -SkipCACheck) -ErrorAction Stop
                                    }
                                } elseif ($bootstrapCredential) {
                                    try {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential `
                                            -Authentication Negotiate -UseSSL `
                                            -SessionOption (New-PSSessionOption -SkipCACheck) -ErrorAction Stop
                                    } catch {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential `
                                            -Authentication Negotiate -ErrorAction Stop
                                    }
                                } else {
                                    throw 'Für die erneute WinRM-Verbindung stehen keine Anmeldedaten zur Verfügung.'
                                }
                            } catch {
                                if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
                            }
                        }

                        if (-not $cleanupSession) { throw $initialCleanupError }
                        $remoteTempRemoved = Invoke-Command -Session $cleanupSession -ScriptBlock {
                            param($path)
                            if (Test-Path -LiteralPath $path) {
                                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                            }
                            return (-not (Test-Path -LiteralPath $path))
                        } -ArgumentList $remoteTemp -ErrorAction Stop
                    }
                    if (-not $remoteTempRemoved) {
                        Write-DeployLog "Temporärer Setup-Ordner auf $Servername konnte nicht bestätigt entfernt werden: $remoteTemp" -Level Warning
                    }
                }
                catch {
                    Write-DeployLog "Temporärer Setup-Ordner auf $Servername konnte nicht entfernt werden: $remoteTemp. Ursache: $($_.Exception.Message)" -Level Warning
                }
                finally {
                    if ($cleanupSession -and $cleanupSession -ne $session) {
                        Remove-PSSession -Session $cleanupSession -ErrorAction SilentlyContinue
                    }
                }
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

function Invoke-WindowsUpdateServerDeployment {
    param(
        [string]$Servername,
        [string]$PSSCfgSkriptFile,
        [string]$CommonModuleFile = 'WindowsUpdate.Common.psm1',
        [string]$RootDirectory,
        [string]$OfflineModulePayloadRoot,
        [string]$DeployType = "AD",
        [switch]$CleanupLegacyTempOnly,
        [Parameter(Mandatory)][string]$ExpectedDeploymentVersion,
        [bool]$ExpectedWinGetUpdateOnly = $false,
        [bool]$ExpectedChocolateyUpdateOnly = $true,
        [bool]$ExpectedWinGetMaintenanceOnly = $true,
        [bool]$ExpectedChocolateyMaintenanceOnly = $true,
        [Parameter(Mandatory)][object]$UpdateSettings,
        [Parameter(Mandatory)][bool]$EnableWingetUpdates,
        [Parameter(Mandatory)][System.Collections.IDictionary]$ExpectedModuleVersions,
        [Parameter(Mandatory)][System.Collections.IDictionary]$BootstrapCredentials,
        [string[]]$ManagementServerAddresses = @(),
        [Parameter(Mandatory)][scriptblock]$WriteLog
    )

    $writeLogCallback = $WriteLog
    function Write-DeployLog {
        param([AllowEmptyString()][string]$Message, [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info', [switch]$LogOnly, [switch]$ConsoleOnly)
        & $writeLogCallback -Message $Message -Level $Level -LogOnly:$LogOnly -ConsoleOnly:$ConsoleOnly
    }
    $result = [PSCustomObject]@{
        Status  = "Pending"
        Message = ""
    }

    # Auch das Verwaltungsgerät nach Möglichkeit über Loopback-WinRM behandeln.
    # Nur wenn WinRM auf dem lokalen Gerät noch nicht eingerichtet ist, bleibt
    # der direkte Aufruf als notwendiger Bootstrap erhalten.
    $useWinRMSetup = $Servername -ne $env:COMPUTERNAME
    if (-not $useWinRMSetup -and $DeployType -eq 'AD') {
        try {
            Test-WSMan -ComputerName $Servername -ErrorAction Stop | Out-Null
            $useWinRMSetup = $true
            Write-DeployLog "[$Servername] Loopback-WinRM verfügbar; Setup wird remote ausgeführt."
        }
        catch {
            Write-DeployLog "[$Servername] WinRM ist noch nicht verfügbar; direkter Ersteinrichtungs-Bootstrap wird verwendet." -LogOnly
        }
    }

    # Remote ausschließlich per WinRM verteilen: kein C$ erforderlich.
    if ($useWinRMSetup) {
        try {
            return Invoke-WindowsUpdateWinRMDeployment `
                -Servername $Servername `
                -PSSCfgSkriptFile $PSSCfgSkriptFile `
                -CommonModuleFile $CommonModuleFile `
                -RootDirectory $RootDirectory `
                -OfflineModulePayloadRoot $OfflineModulePayloadRoot `
                -DeployType $DeployType `
                -CleanupLegacyTempOnly:$CleanupLegacyTempOnly `
                -ExpectedDeploymentVersion $ExpectedDeploymentVersion `
                -ExpectedWinGetUpdateOnly $ExpectedWinGetUpdateOnly `
                -ExpectedChocolateyUpdateOnly $ExpectedChocolateyUpdateOnly `
                -ExpectedWinGetMaintenanceOnly $ExpectedWinGetMaintenanceOnly `
                -ExpectedChocolateyMaintenanceOnly $ExpectedChocolateyMaintenanceOnly `
                -UpdateSettings $UpdateSettings `
                -EnableWingetUpdates $EnableWingetUpdates `
                -ExpectedModuleVersions $ExpectedModuleVersions `
                -BootstrapCredentials $BootstrapCredentials `
                -ManagementServerAddresses $ManagementServerAddresses `
                -WriteLog $WriteLog
        }
        catch {
            $result.Status  = 'Failed'
            $errorText = $_.Exception.Message
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'WinRM-Bereitstellung' -Target $Servername -ErrorRecord $_ -Context @('Retries=5; credentials omitted')
            if ($errorText -match 'Interner Fehler') {
                $result.Message = 'Zertifikatsanmeldung zum JEA-Endpunkt nach 5 Versuchen abgelehnt.'
            } elseif ($errorText -match 'Access is denied|Zugriff verweigert|Unauthorized|Anmeldeinformationen|Credential') {
                $result.Message = "WinRM-Anmeldung für $Servername abgelehnt: $errorText"
            } else {
                $result.Message = "WinRM/JEA-Endpunkt nach 5 Versuchen nicht erreichbar: $errorText"
            }
            return $result
        }
    }

    if ($CleanupLegacyTempOnly) {
        $result.Status = 'Skipped'
        $result.Message = 'Lokales Ziel im Bereinigungslauf übersprungen; nur Remote-Ziele werden bereinigt.'
        return $result
    }

    # Lokales Setup direkt aus dem gemeinsamen Skriptordner ausführen.
    try {
        Write-DeployLog "[$Servername] Führe lokales Setup aus."
        $localParameters = @{}
        if ($EnableWingetUpdates) { $localParameters.InstallWinGetClientModule = $true }
        if (@($ManagementServerAddresses | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }).Count -gt 0) {
            $localParameters.ManagementServerAddresses = @($ManagementServerAddresses)
        }
        if ($OfflineModulePayloadRoot -and (Test-Path -LiteralPath $OfflineModulePayloadRoot -PathType Container)) {
            $localParameters.OfflineModuleRoot = $OfflineModulePayloadRoot
        }
        # Alle Details protokollieren; wichtige Setup-Phasen live anzeigen,
        # damit längere lokale Einrichtungsschritte erkennbar bleiben.
        & (Join-Path (Join-Path $RootDirectory 'Komponenten') $PSSCfgSkriptFile) @localParameters *>&1 | ForEach-Object {
            $entry = $_
            $entryText = if ($entry -is [System.Management.Automation.InformationRecord]) { [string]$entry.MessageData } else { [string]$entry }
            Write-DeployLog $entryText -LogOnly
            if ($entryText -match '^\[[^]]+\]\s+\[(?<Level>INFO|UPDATE|WARN|SUCCESS|ERROR)\]\s+(?<Status>.*)$') {
                $setupStatus = $Matches.Status
                $showSetupStatus = $setupStatus -match '^(=== (NuGet Provider Check|PSWindowsUpdate Installation/Update|Dual PowerShell Support \(PS5 \+ PS7\)|PS-Remoting Konfiguration|JEA Role Capability Setup|WinRM Endpunkt Registrierung|Finaler Verbindungstest) ===|NuGet (ist aktuell|erfolgreich aktualisiert|Provider installiert|vom lokalen Server installiert)|PSWindowsUpdate (ist aktuell|erfolgreich aktualisiert|erfolgreich installiert|bereit;)|PowerShell-7-Remoting aktiviert|WinRM neu gestartet|Configuration über Windows PowerShell 5\.1 registriert|Loopback-Verbindungstest erfolgreich|Setup erfolgreich abgeschlossen!|Lokales Setup abgeschlossen; zentrale Endpunktprüfung folgt)'
                if ($setupStatus -match '^NuGet-Online-Installation fehlgeschlagen:') {
                    $nugetFailureText = $setupStatus
                    if ($nugetFailureText.Length -gt 280) { $nugetFailureText = $nugetFailureText.Substring(0, 277) + '...' }
                    Write-Host "[$Servername] $nugetFailureText" -ForegroundColor Yellow
                }
                if ($showSetupStatus) {
                    $setupLevel = if ($setupStatus -match '^(NuGet (ist aktuell|erfolgreich aktualisiert|Provider installiert|vom lokalen Server installiert)|PSWindowsUpdate (ist aktuell|erfolgreich aktualisiert|erfolgreich installiert|bereit;)|Loopback-Verbindungstest erfolgreich|Setup erfolgreich abgeschlossen!)') { 'Success' } else { 'Info' }
                    Write-DeployLog "[$Servername] Setup: $setupStatus" -Level $setupLevel -ConsoleOnly
                }
            }
        }
        if ($LASTEXITCODE -ne 0) {
            throw "Lokales Setup auf $Servername wurde mit Exit-Code $LASTEXITCODE beendet."
        }
        $result.Status = 'Success'
        $result.Message = 'WindowsUpdateAdm lokal konfiguriert'
        return $result
    }
    catch {
        $result.Status  = 'Failed'
        $result.Message = $_.Exception.Message
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation 'Lokales Setup' -Target $Servername -ErrorRecord $_
        return $result
    }

}

Export-ModuleMember -Function Get-WindowsUpdateDeploymentBootstrapCredential, Get-WindowsUpdateDeploymentClientCertificate, Test-WindowsUpdateDeploymentConfiguration, Add-WindowsUpdateTrustedWinRMServerCertificate, Invoke-WindowsUpdateWinRMDeployment, Invoke-WindowsUpdateServerDeployment
