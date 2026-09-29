#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Verteilung_WindowsUpdateAdmConfig.ps1
    Verteilt New-WindowsUpdateAdmConfig.ps1 auf alle Windows-Server im AD

.DESCRIPTION
    - Überträgt das Setup per WinRM
    - Verwendet Kerberos für AD-Geräte und Client-Zertifikate für Nicht-AD-Geräte
    - Protokolliert Erfolg/Fehler pro Server
    - Raeumt temporaere Dateien auf
    - Liest Ziele über default_settings.json, settings.json und optional
      Verteilung_WindowsUpdateAdmConfig.settings.json

.NOTES
    FileName: Verteilung_WindowsUpdateAdmConfig.ps1
    Requires: ActiveDirectory-Modul (optional für AD-Ermittlung)
              Administrator-Rechte
#>

[CmdletBinding()]
param(
    # Beschränkt die Verteilung auf genau ein Windows-Ziel. Linux und Home
    # Assistant werden in diesem Modus bewusst nicht zusätzlich eingerichtet.
    [string]$TargetComputer,
    # Bereinigt ausschließlich alte, eindeutig markierte Temp-Ablagen auf den
    # Remote-Zielen und überspringt die erneute WindowsUpdateAdm-Einrichtung.
    [switch]$CleanupLegacyTempOnly
)
# GitHub-Update beim Start: Die eingebundene Routine lädt nur benötigte Skriptdateien.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $scriptUpdateTemporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $scriptUpdateTemporaryPath -ErrorAction Stop
        Move-Item -LiteralPath $scriptUpdateTemporaryPath -Destination $scriptUpdatePath -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath ($scriptUpdatePath + '.download') -Force -ErrorAction SilentlyContinue
        Write-Warning 'GitHub-Updater nicht erreichbar; vorhandene Skriptversion wird ausgeführt.'
    }
}
$scriptUpdateLoaded = $false
if (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf) {
    try {
        . $scriptUpdatePath
        $scriptUpdateLoaded = [bool](Get-Command -Name 'Invoke-ServerUpdateScripts' -CommandType Function -ErrorAction SilentlyContinue)
    }
    catch {
        Write-Warning "GitHub-Updater konnte nicht geladen werden; vorhandene Skriptversion wird ausgeführt. Ursache: $($_.Exception.Message)"
    }
}
if ($scriptUpdateLoaded) {
    Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RemainingArguments $args
}



Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

# Konfiguration
$PSSCfgSkriptFile = "New-WindowsUpdateAdmConfig.ps1"
$CommonModuleFile = 'WindowsUpdate.Common.psm1'
$ScriptName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$script:DeployLogEnabled = $true
$script:DeployLogFile = $null
$script:DeployLogDirectory = Join-Path $PSScriptRoot 'Logs'
$script:DeployKeepLogFiles = 5

function Write-DeployLog {
    param(
        [AllowEmptyString()][string]$Message,
        [ValidateSet('Info', 'Success', 'Warning', 'Error')][string]$Level = 'Info',
        [switch]$LogOnly,
        [switch]$ConsoleOnly
    )

    if (-not $ConsoleOnly -and $script:DeployLogEnabled -and $script:DeployLogFile) {
        "$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') [$Level] $Message" | Add-Content -LiteralPath $script:DeployLogFile -Encoding UTF8
    }
    if ($LogOnly) { return }

    $show = [string]::IsNullOrWhiteSpace($Message) -or $Level -in @('Warning', 'Error') -or
        $Message -match '(?i)^\s*(WARNUNG|WARNING|FEHLER|ERROR|WindowsUpdateAdm-Verteilung|Ziele:|Eingeschränkter Lauf:|\[[^]]+\] (Deployment gestartet|Verbinde|Übertrage|Führe Setup|Warte|Teste|Erfolg|FEHLER|Verbindung vorbereitet|WindowsUpdateAdm-Endpunkt|Linux-Hosts|Home Assistant)|\[(Linux|Home Assistant)\]|Ergebnis:|Windows-Ziele:|Erfolgreich:|Fehler:|Linux-Hosts:|Home-Assistant-Instanzen:|Gesamt Systeme:|Gesamt:|Logdatei:|\s{2,}[^:]+: (SSH-Schlüssel|Verbindung/Einrichtung)|\s{2,}[^:]+: \d+ (Paketupdates|Updates? verfügbar)|\s{2,}(Linux-Paket|Core|Supervisor|OS|Add-on))'
    if (-not $show) { return }

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   {
            if ($Message -match '(?i)^\s*(WARNUNG|WARNING)') { 'Yellow' }
            elseif ($Message -match '(?i)^\s*(FEHLER|ERROR)') { 'Red' }
            elseif ($Message -match '(?i)^\s*(WindowsUpdateAdm-Verteilung|Ziele:|Eingeschränkter Lauf:|\[[^]]+\] (Deployment gestartet|Verbinde|Übertrage|Führe Setup|Warte|Teste|Linux-Hosts|Home Assistant)|Ergebnis:|Windows-Ziele:|Erfolgreich:|Fehler:|Linux-Hosts:|Home-Assistant-Instanzen:|Gesamt Systeme:|Gesamt:)') { 'Cyan' }
            else { 'Gray' }
        }
    }
    Write-WindowsUpdateConsoleLine -Message $Message -ForegroundColor $color -AlreadyFiltered
}

$Settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $ScriptName
$UpdateSettings = $Settings.UpdateSettings
$script:DeployLogEnabled = if ($UpdateSettings.PSObject.Properties['WriteLogFile']) { [bool]$UpdateSettings.WriteLogFile } else { $true }
$script:DeployKeepLogFiles = if ($UpdateSettings.PSObject.Properties['KeepLogFiles'] -and [int]$UpdateSettings.KeepLogFiles -ge 0) { [int]$UpdateSettings.KeepLogFiles } else { 5 }
if ($script:DeployLogEnabled) {
    # Das Logverzeichnis wird nur angelegt, wenn Protokollierung aktiviert ist.
    if (-not (Test-Path -LiteralPath $script:DeployLogDirectory -PathType Container)) {
        New-Item -ItemType Directory -Path $script:DeployLogDirectory -Force | Out-Null
    }
    $script:DeployLogFile = Join-Path $script:DeployLogDirectory ("{0}_{1}.log" -f $ScriptName, (Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'))
    "Protokolldatei vom $(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') / $ScriptName" | Set-Content -LiteralPath $script:DeployLogFile -Encoding UTF8
}
$TargetComputers = $UpdateSettings.TargetComputers
if ([string]::IsNullOrWhiteSpace($TargetComputers)) {
    $TargetComputers = "Server"
}

# Header
Write-DeployLog 'WindowsUpdateAdm-Verteilung'

# Voraussetzungen pruefen
foreach ($requiredSetupFile in @($PSSCfgSkriptFile, $CommonModuleFile)) {
    if (-not (Test-Path -LiteralPath (Join-Path $PSScriptRoot $requiredSetupFile) -PathType Leaf)) {
        Write-DeployLog "FEHLER: Für das Setup benötigte Datei nicht gefunden: $(Join-Path $PSScriptRoot $requiredSetupFile)" -Level Error
        exit 1
    }
}

# Die zentrale Zielermittlung liefert exakt dieselbe Zielmenge wie Check,
# Download und Installation. Für die Verteilung wird nur der Verbindungstyp
# aus den Markierungen abgeleitet.
$Serverlist = Get-WindowsUpdateTargets -UpdateSettings $UpdateSettings -TargetComputers $TargetComputers -WriteLog {
    param($message)
    Write-DeployLog $message
} | ForEach-Object {
    [PSCustomObject]@{
        Name       = $_.Name
        DeployType = if ($_.IsHypervisor) { 'Hypervisor' } elseif ($_.IsAdditional) { 'Additional' } else { 'AD' }
    }
}
if (-not [string]::IsNullOrWhiteSpace($TargetComputer)) {
    $Serverlist = @($Serverlist | Where-Object { $_.Name -ieq $TargetComputer })
    if ($Serverlist.Count -eq 0) {
        throw "Das Ziel '$TargetComputer' wurde nicht in der ermittelten Windows-Zielliste gefunden."
    }
    Write-DeployLog "Eingeschränkter Lauf: $($Serverlist[0].Name)" -Level Warning
}
$linuxSettings = if ($Settings.PSObject.Properties['LinuxSettings']) { $Settings.LinuxSettings } else { $null }
$haSettings = if ($Settings.PSObject.Properties['HomeAssistantSettings']) { $Settings.HomeAssistantSettings } else { $null }
$linuxHostEntries = @()
if ($null -ne $linuxSettings -and $linuxSettings.PSObject.Properties['Hosts']) {
    $linuxHostEntries = @(
      foreach ($entry in @($linuxSettings.Hosts)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($entry)) { $entry }
            continue
        }
        $hostValue = if ($entry.PSObject.Properties['Host']) { [string]$entry.Host } elseif ($entry.PSObject.Properties['Name']) { [string]$entry.Name } else { '' }
        $userValue = if ($entry.PSObject.Properties['User']) { [string]$entry.User } else { '' }
        if (-not [string]::IsNullOrWhiteSpace($hostValue) -or -not [string]::IsNullOrWhiteSpace($userValue)) { $entry }
      }
    )
}
$linuxConfigured = $linuxHostEntries.Count -gt 0
$haConfigured = $null -ne $haSettings -and $haSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$haSettings.Host)
$includeOptionalSystems = [string]::IsNullOrWhiteSpace($TargetComputer) -and -not $CleanupLegacyTempOnly
$LinuxSystemCount = if ($includeOptionalSystems -and $linuxConfigured) { $linuxHostEntries.Count } else { 0 }
$HASystemCount = if ($includeOptionalSystems -and $haConfigured) { 1 } else { 0 }
$configuredSystemCount = $Serverlist.Count + $LinuxSystemCount + $HASystemCount
if ($includeOptionalSystems) {
    Write-DeployLog "Ziele: Windows $($Serverlist.Count), Linux $LinuxSystemCount, Home Assistant $HASystemCount; Gesamt $configuredSystemCount"
} else {
    Write-DeployLog "Ziele: Windows $($Serverlist.Count) (Linux und Home Assistant übersprungen)"
}

# Das Client-Zertifikat wird nur benötigt, wenn mindestens ein Nicht-AD-Gerät
# eingerichtet wird. Es wird bei Bedarf automatisch im Skriptordner erstellt.
$nonAdTargets = @($Serverlist | Where-Object { $_.DeployType -and $_.DeployType -ne 'AD' })
if ($nonAdTargets.Count -gt 0) {
    $clientCertificate = Join-Path $PSScriptRoot 'WinRM-ClientCert.cer'
    $certificateSetup = Join-Path $PSScriptRoot 'Setup-ClientCertificate.ps1'
    if (-not (Test-Path $certificateSetup)) {
        throw "Das Zertifikat-Setup-Skript wurde nicht gefunden: $certificateSetup"
    }
    if (-not (Test-Path $clientCertificate)) {
        Write-DeployLog 'Client-Zertifikat fehlt; richte es ein.'
    } else {
        Write-DeployLog 'Client-Zertifikat vorhanden; synchronisiere Konfigurationen.'
    }
    $certificateSetupOutput = @(& $certificateSetup -NonInteractive *>&1)
    foreach ($entry in $certificateSetupOutput) { Write-DeployLog ([string]$entry) -LogOnly }
    if (-not (Test-Path $clientCertificate)) {
        throw "Das automatische Erstellen des Client-Zertifikats ist fehlgeschlagen."
    }
}

# Ergebnis-Tracking
$Results      = @()
$SuccessCount = 0
$FailCount    = 0
$LinuxConnectionErrors = 0
$HAConnectionErrors = 0
$script:BootstrapCredential = $null

function Add-TrustedWinRMServerCertificate {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Servername
    )

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

# Die Ersteinrichtung darf nicht vom administrativen SMB-Share (C$) abhängen.
# AD-Geräte verbinden sich per Kerberos. Nicht-AD-Geräte verwenden einmalig
# interaktiv abgefragte lokale Administrator-Anmeldedaten; danach übernimmt die
# im Setup eingerichtete Client-Zertifikat-Authentifizierung.
function Invoke-WinRMDeployment {
    param(
        [string]$Servername,
        [string]$PSSCfgSkriptFile,
        [string]$RootDirectory,
        [string]$DeployType,
        [switch]$CleanupLegacyTempOnly
    )

    $session = $null
    $remoteTemp = $null
    $usedCertificate = $false
    $bootstrapCredential = $null
    try {
        if ($DeployType -ne 'AD') {
            # Lokale Konten auf Nicht-AD-Zielen dürfen nicht als
            # "Server\Benutzer" an Kerberos übergeben werden. Negotiate
            # erlaubt den NTLM-Fallback; TrustedHosts ist nur für den
            # einmaligen HTTP-Fallback relevant.
            Add-WindowsUpdateTrustedHost -ComputerName $Servername -WriteLog { param($message) Write-DeployLog $message }
            # Bei Wiederholungen zuerst das bereits eingerichtete Client-Zertifikat testen.
            # Nur bei einer echten Ersteinrichtung werden Zugangsdaten benötigt.
            $clientCert = Get-ChildItem 'Cert:\CurrentUser\My' |
                Where-Object { $_.Subject -eq "CN=WinRM-UpdateClient-$env:COMPUTERNAME" -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending |
                Select-Object -First 1
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
                    try {
                        $session = New-PSSession -ComputerName $Servername -UseSSL `
                            -CertificateThumbprint $clientCert.Thumbprint `
                            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
                            -ErrorAction Stop
                        $usedCertificate = $true
                        Write-DeployLog "Vorhandenes Client-Zertifikat für die Vertrauensmigration auf $Servername verwendet." -LogOnly
                    }
                    catch {
                        Write-DeployLog "Client-Zertifikat für $Servername nicht verfügbar; verwende Einrichtungsdaten." -LogOnly
                    }
                }
            }

            if (-not $session) {
                if ($null -eq $script:BootstrapCredential) {
                    Write-DeployLog "Einmalige Anmeldedaten für $Servername werden benötigt." -Level Warning
                    $script:BootstrapCredential = Get-Credential -Message "Einmalige WinRM-Einrichtung für Nicht-AD-Geräte (z. B. .\Administrator)"
                }
                $bootstrapCredential = $script:BootstrapCredential
                Write-DeployLog "[$Servername] Verbinde per WinRM ($DeployType)."
                try {
                    $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -UseSSL `
                        -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                }
                catch {
                    # Vor der Einrichtung existiert bei manchen Geräten noch kein
                    # HTTPS-Listener. HTTP ist ausschließlich der einmalige Fallback.
                    Write-DeployLog "[$Servername] WinRM/HTTPS nicht verfügbar; HTTP-Fallback."
                    try {
                        $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -ErrorAction Stop
                    }
                    catch {
                        # Ein lokales Administratorkonto kann je Nicht-AD-Gerät
                        # unterschiedlich heißen. Werden zwischengespeicherte
                        # Daten abgelehnt, fragen wir genau für dieses Ziel neu.
                        Write-DeployLog "Einrichtungsdaten für $Servername wurden abgelehnt." -Level Warning
                        $bootstrapCredential = Get-Credential -Message "Lokale Administrator-Anmeldedaten für $Servername (z. B. .\Administrator)"
                        try {
                            $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -UseSSL `
                                -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                        }
                        catch {
                            Write-DeployLog "WinRM/HTTPS auf $Servername nicht verfügbar; einmaliger HTTP-Fallback." -LogOnly
                            $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -ErrorAction Stop
                        }
                        $script:BootstrapCredential = $bootstrapCredential
                    }
                }
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
        Copy-Item -Path (Join-Path $RootDirectory $PSSCfgSkriptFile) `
                  -Destination (Join-Path $remoteTemp $PSSCfgSkriptFile) `
                  -ToSession $session -Force -ErrorAction Stop
        Copy-Item -Path (Join-Path $RootDirectory $CommonModuleFile) `
                  -Destination (Join-Path $remoteTemp $CommonModuleFile) `
                  -ToSession $session -Force -ErrorAction Stop

        # AD-Geräte erhalten weder Client-Zertifikat noch Zertifikats-Mapping.
        if ($DeployType -ne 'AD') {
            $certSource = Join-Path $RootDirectory 'WinRM-ClientCert.cer'
            if (-not (Test-Path $certSource)) {
                throw "Client-Zertifikat fehlt: $certSource. Zuerst Setup-ClientCertificate.ps1 ausführen."
            }
            Copy-Item -Path $certSource -Destination (Join-Path $remoteTemp 'WinRM-ClientCert.cer') `
                      -ToSession $session -Force -ErrorAction Stop
        }

        $setupParameters = @{}
        if ($DeployType -eq 'Hypervisor' -and -not $usedCertificate) {
            $setupParameters.CertificateMappingCredential = $bootstrapCredential
        } elseif ($DeployType -eq 'Additional' -and -not $usedCertificate) {
            $setupParameters.CertificateMappingCredential = $bootstrapCredential
        } elseif ($DeployType -ne 'AD' -and $usedCertificate) {
            $setupParameters.PreserveExistingCertificateMapping = $true
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
            Add-TrustedWinRMServerCertificate -Session $session -Servername $Servername
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
            return [PSCustomObject]@{
                Status = 'Success'
                Message = 'WindowsUpdateAdm eingerichtet; Windows Update erfolgt auf Server 2016/2019 per Client-Zertifikat und SYSTEM-Aufgabe'
            }
        }

        Write-DeployLog "[$Servername] Warte auf WinRM-Neustart."
        Start-Sleep -Seconds 30

        $testParams = @{
            ComputerName      = $Servername
            ConfigurationName = 'WindowsUpdateAdm'
            ScriptBlock       = { Get-Command Get-WindowsUpdate -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Name }
            ErrorAction       = 'Stop'
        }
        if ($DeployType -ne 'AD') {
            $clientCert = Get-ChildItem 'Cert:\CurrentUser\My' |
                Where-Object { $_.Subject -eq "CN=WinRM-UpdateClient-$env:COMPUTERNAME" -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending |
                Select-Object -First 1
            if (-not $clientCert) {
                throw 'Lokales Client-Zertifikat für den Verbindungstest wurde nicht gefunden.'
            }
            $testParams.UseSSL               = $true
            $testParams.CertificateThumbprint = $clientCert.Thumbprint
        }

        Write-DeployLog "[$Servername] Teste WindowsUpdateAdm-Endpunkt."
        $endpointCommand = Invoke-WindowsUpdateWithRetry -OperationName "WindowsUpdateAdm-Endpunkt auf $Servername" -RetryCount 5 -RetryDelaySeconds 30 -WriteLog {
            param($message)
            if ($message -like 'Wiederhole *') {
                Write-DeployLog "WindowsUpdateAdm-Endpunkt auf $Servername noch nicht bereit; erneuter Versuch folgt." -LogOnly
            }
        } -ScriptBlock {
            $command = Invoke-Command @testParams
            if ($command -ne 'Get-WindowsUpdate') {
                throw "WindowsUpdateAdm-Endpunkt lieferte unerwartetes Ergebnis: $command"
            }
            return $command
        }
        Write-DeployLog "[$Servername] WindowsUpdateAdm-Endpunkt erfolgreich getestet." -Level Success

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
                                            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                                    }
                                } elseif ($bootstrapCredential) {
                                    try {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential `
                                            -Authentication Negotiate -UseSSL `
                                            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
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

# Hilfsfunktion: einzelnen Server verarbeiten
function Invoke-ServerDeployment {
    param(
        [string]$Servername,
        [string]$PSSCfgSkriptFile,
        [string]$RootDirectory,
        [string]$DeployType = "AD",
        [switch]$CleanupLegacyTempOnly
    )

    $result = [PSCustomObject]@{
        Status  = "Pending"
        Message = ""
    }

    # Remote ausschließlich per WinRM verteilen: kein C$ erforderlich.
    if ($Servername -ne $env:COMPUTERNAME) {
        try {
            return Invoke-WinRMDeployment `
                -Servername $Servername `
                -PSSCfgSkriptFile $PSSCfgSkriptFile `
                -RootDirectory $RootDirectory `
                -DeployType $DeployType `
                -CleanupLegacyTempOnly:$CleanupLegacyTempOnly
        }
        catch {
            $result.Status  = 'Failed'
            $errorText = $_.Exception.Message
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
        # Ausführliche Setup-Ausgaben abfangen und nur ins Log schreiben;
        # auf der Konsole erscheint anschließend ausschließlich das Ergebnis.
        $localSetupOutput = @(& (Join-Path $RootDirectory $PSSCfgSkriptFile) @localParameters *>&1)
        foreach ($entry in $localSetupOutput) {
            $entryText = if ($entry -is [System.Management.Automation.InformationRecord]) { [string]$entry.MessageData } else { [string]$entry }
            Write-DeployLog $entryText -LogOnly
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
        return $result
    }

}

# Server verarbeiten
ForEach ($Server in $Serverlist) {
    $Servername = $Server.Name
    if ([String]::IsNullOrWhiteSpace($Servername)) {
        $Servername = $Server
    }
    if ([String]::IsNullOrWhiteSpace($Servername)) {
        continue
    }

    $deployTypeLabel = if ($Server.DeployType) { $Server.DeployType } else { "AD" }
    Write-DeployLog ''
    Write-DeployLog "[$Servername] Deployment gestartet ($deployTypeLabel)"

    $deployResult = Invoke-ServerDeployment `
        -Servername                $Servername `
        -PSSCfgSkriptFile          $PSSCfgSkriptFile `
        -RootDirectory             $PSScriptRoot `
        -DeployType                $deployTypeLabel `
        -CleanupLegacyTempOnly:$CleanupLegacyTempOnly

    $ServerResult = [PSCustomObject]@{
        ServerName = $Servername
        Status     = $deployResult.Status
        Message    = $deployResult.Message
        Timestamp  = Get-Date
    }

    if ($deployResult.Status -eq "Success") {
        $SuccessCount++
    }
    elseif ($deployResult.Status -eq "Failed") {
        $FailCount++
    }

    $Results += $ServerResult
    $fullResultMessage = "[$Servername] $($deployResult.Status): $($deployResult.Message)"
    Write-DeployLog $fullResultMessage -LogOnly
    if ($deployResult.Status -eq 'Success') {
        Write-DeployLog "[$Servername] Erfolg – $($deployResult.Message)" -Level Success -ConsoleOnly
    } elseif ($deployResult.Status -eq 'Failed') {
        Write-DeployLog "[$Servername] FEHLER – Einrichtung fehlgeschlagen; Details im Log." -Level Error -ConsoleOnly
    } else {
        Write-DeployLog "[$Servername] Übersprungen – $($deployResult.Message)" -Level Warning -ConsoleOnly
    }
}

# Beim regulären Gesamtlauf werden SSH-Schlüssel, Schlüssel-Login und die
# begrenzten sudo-/HA-Voraussetzungen vorbereitet. Die beiden Skripte behalten
# dieselbe Ersteinrichtung zusätzlich für Check, Download und Installation.
if ([string]::IsNullOrWhiteSpace($TargetComputer) -and -not $CleanupLegacyTempOnly) {
    $hostPowerShell = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $hostPowerShell)) { $hostPowerShell = (Get-Process -Id $PID).Path }
    $connectionSetups = @()
    if ($linuxConfigured) { $connectionSetups += [PSCustomObject]@{ Name = 'Linux'; Script = 'Install-Linux Updates.ps1' } }
    if ($haConfigured) { $connectionSetups += [PSCustomObject]@{ Name = 'Home Assistant'; Script = 'Install-HomeAssistant Updates.ps1' } }
    foreach ($connectionSetup in $connectionSetups) {
        $connectionScript = Join-Path $PSScriptRoot $connectionSetup.Script
        $statsFileName = if ($connectionSetup.Name -eq 'Linux') { 'linux_update_check_stats.json' } else { 'ha_update_check_stats.json' }
        $statsPath = Join-Path $PSScriptRoot $statsFileName
        Remove-Item -LiteralPath $statsPath -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $connectionScript)) {
            if ($connectionSetup.Name -eq 'Linux') { $LinuxConnectionErrors = [Math]::Max(1, $LinuxSystemCount) } else { $HAConnectionErrors = 1 }
            Write-DeployLog "$($connectionSetup.Name)-Einrichtung übersprungen: Skript nicht gefunden." -Level Warning
            continue
        }
        Write-DeployLog "[$($connectionSetup.Name)] Verbindungseinrichtung gestartet."
        try {
            $connectionOutput = @(& $hostPowerShell -NoProfile -ExecutionPolicy Bypass -File $connectionScript -ConnectionOnly *>&1)
            $connectionExitCode = $LASTEXITCODE
            foreach ($entry in $connectionOutput) { Write-DeployLog ([string]$entry) -LogOnly }
            if (-not (Test-Path -LiteralPath $statsPath -PathType Leaf)) {
                throw "Das Einrichtungsskript lieferte keine Statusdatei (Exit-Code $connectionExitCode)."
            }
            $connectionStats = Get-Content -LiteralPath $statsPath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
            if ($connectionSetup.Name -eq 'Linux') {
                $linuxHosts = @($connectionStats.HostStatus)
                $LinuxSystemCount = [int]$connectionStats.TotalHosts
                $LinuxConnectionErrors = [int]$connectionStats.FailedHosts
                $linuxLevel = if ($LinuxConnectionErrors -gt 0) { 'Warning' } else { 'Success' }
                $linuxConnectedCount = [Math]::Max(0, $LinuxSystemCount - $LinuxConnectionErrors)
                Write-DeployLog "[Linux] Hosts geprüft: $LinuxSystemCount; SSH-Schlüssel/Verbindung erfolgreich: $linuxConnectedCount; Fehler: $LinuxConnectionErrors" -Level $linuxLevel
                foreach ($hostResult in $linuxHosts) {
                    if ($hostResult.Status -eq 'Fehler') {
                        Write-DeployLog "  $($hostResult.Host): Verbindung/Einrichtung fehlgeschlagen; Details im Log." -Level Warning
                    } else {
                        Write-DeployLog "  $($hostResult.Host): SSH-Schlüssel und Verbindung funktionieren."
                    }
                }
            }
            else {
                if (-not $connectionStats.Success) {
                    $HAConnectionErrors = 1
                    Write-DeployLog '[Home Assistant] Verbindung/Einrichtung fehlgeschlagen; Details im Log.' -Level Warning
                } else {
                    Write-DeployLog "[Home Assistant] SSH-Verbindung zu $($connectionStats.Host) funktioniert." -Level Success
                }
            }
            if ($connectionExitCode -ne 0) {
                if ($connectionSetup.Name -eq 'Linux' -and $LinuxConnectionErrors -eq 0) { $LinuxConnectionErrors++ }
                if ($connectionSetup.Name -eq 'Home Assistant' -and $HAConnectionErrors -eq 0) { $HAConnectionErrors++ }
                Write-DeployLog "$($connectionSetup.Name)-Prüfung endete mit Exit-Code $connectionExitCode; Details im Log." -Level Warning
            }
        }
        catch {
            if ($connectionSetup.Name -eq 'Linux') { $LinuxConnectionErrors = [Math]::Max(1, $LinuxSystemCount) } else { $HAConnectionErrors = 1 }
            Write-DeployLog "$($connectionSetup.Name)-Einrichtung nicht abgeschlossen; Details im Log." -Level Warning
            Write-DeployLog "$($connectionSetup.Name)-Einrichtungsfehler: $($_.Exception.Message)" -LogOnly
        }
        finally {
            Remove-Item -LiteralPath $statsPath -Force -ErrorAction SilentlyContinue
        }
    }
}

# Zusammenfassung
Write-DeployLog ''
Write-DeployLog 'Ergebnis:'
Write-DeployLog "Windows-Ziele: $($Results.Count)"
Write-DeployLog "Erfolgreich: $SuccessCount" -Level Success
Write-DeployLog "Fehler: $FailCount" -Level $(if ($FailCount -eq 0) { 'Success' } else { 'Error' })
if ($LinuxSystemCount -gt 0 -or $LinuxConnectionErrors -gt 0) {
    $linuxConnectedCount = [Math]::Max(0, $LinuxSystemCount - $LinuxConnectionErrors)
    Write-DeployLog "Linux-Hosts: $LinuxSystemCount; SSH-Schlüssel/Verbindung: $linuxConnectedCount erfolgreich; Fehler: $LinuxConnectionErrors"
}
if ($HASystemCount -gt 0 -or $HAConnectionErrors -gt 0) {
    $haConnectedCount = [Math]::Max(0, $HASystemCount - $HAConnectionErrors)
    Write-DeployLog "Home-Assistant-Instanzen: $HASystemCount; Verbindung: $haConnectedCount erfolgreich; Fehler: $HAConnectionErrors"
}
$totalSystems = $Results.Count + $LinuxSystemCount + $HASystemCount
Write-DeployLog "Gesamt Systeme: $totalSystems"

# Fehlerhafte Server anzeigen
if ($script:DeployLogEnabled) { Write-DeployLog "Logdatei: $script:DeployLogFile" }
if ($script:DeployLogEnabled) {
    $null = Invoke-WindowsUpdateRetentionWithLog -Directory $script:DeployLogDirectory -Filter ("{0}_*.log" -f $ScriptName) -KeepFiles $script:DeployKeepLogFiles -Description 'Verteilungs-Logs' -WriteLog { param($message) Write-DeployLog $message }
}
