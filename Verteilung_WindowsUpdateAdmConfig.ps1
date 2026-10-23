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
# Ältere Windows-/PowerShell-Versionen verwenden sonst oft TLS 1.0 als Standard.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# GitHub-Update beim Start: Die eingebundene Routine lädt nur benötigte Skriptdateien.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Komponenten\Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $scriptUpdateTemporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Komponenten/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $scriptUpdateTemporaryPath -ErrorAction Stop
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

Import-Module (Join-Path $PSScriptRoot 'Module\WindowsUpdate.Common.psm1') -Force -ErrorAction Stop
$expectedDeploymentVersion = Get-WindowsUpdateAdmDeploymentVersion

# Konfiguration
$PSSCfgSkriptFile = "New-WindowsUpdateAdmConfig.ps1"
$CommonModuleFile = 'WindowsUpdate.Common.psm1'
$PSSCfgSkriptPath = Join-Path $PSScriptRoot 'Komponenten'
$CommonModulePath = Join-Path $PSScriptRoot 'Module'
$CommonModuleComponents = @(Get-ChildItem -LiteralPath $CommonModulePath -Filter 'WindowsUpdate.*.psm1' -File -ErrorAction SilentlyContinue |
    Where-Object Name -ne $CommonModuleFile)
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
    if ($Message -match '^\[DIAG\]') { $LogOnly = $true }
    if ($LogOnly) { return }

    $show = [string]::IsNullOrWhiteSpace($Message) -or $Level -in @('Warning', 'Error') -or
        $Message -match '(?i)^\s*(WARNUNG|WARNING|FEHLER|ERROR|WindowsUpdateAdm-Verteilung|Ziele:|Eingeschränkter Lauf:|\[[^]]+\] (Deployment gestartet|Verbinde|Übertrage|Führe (lokales )?Setup|Warte|Teste|Erfolg|FEHLER|Verbindung vorbereitet|WindowsUpdateAdm-Endpunkt|Linux-Hosts|Home Assistant|Setup:)|\[(Linux|Home Assistant)\]|Ergebnis:|Windows-Ziele:|Erfolgreich:|Fehler:|Linux-Hosts:|SSH-Schlüssel/Verbindung:|Home-Assistant-Instanzen:|Verbindung:|Gesamt Systeme:|Gesamt:|Logdatei:|\s{2,}[^:]+: (SSH-Schlüssel|Verbindung/Einrichtung)|\s{2,}[^:]+: \d+ (Paketupdates|Updates? verfügbar)|\s{2,}(Linux-Paket|Core|Supervisor|OS|Add-on))'
    if (-not $show) { return }

    $color = switch ($Level) {
        'Success' { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
        default   {
            if ($Message -match '(?i)^\s*(WARNUNG|WARNING)') { 'Yellow' }
            elseif ($Message -match '(?i)^\s*(FEHLER|ERROR)') { 'Red' }
            elseif ($Message -match '(?i)^\s*(WindowsUpdateAdm-Verteilung|Ziele:|Eingeschränkter Lauf:|\[[^]]+\] (Deployment gestartet|Verbinde|Übertrage|Führe (lokales )?Setup|Warte|Teste|Linux-Hosts|Home Assistant|Setup:)|Ergebnis:|Windows-Ziele:|Erfolgreich:|Fehler:|Linux-Hosts:|SSH-Schlüssel/Verbindung:|Home-Assistant-Instanzen:|Verbindung:|Gesamt Systeme:|Gesamt:)') { 'Cyan' }
            else { 'Gray' }
        }
    }
    Write-WindowsUpdateConsoleLine -Message $Message -ForegroundColor $color -AlreadyFiltered
}

$Settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $ScriptName
$UpdateSettings = $Settings.UpdateSettings
$enableWingetUpdates = if ($UpdateSettings.PSObject.Properties['EnableWingetUpdates']) { [bool]$UpdateSettings.EnableWingetUpdates } else { $true }
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
foreach ($requiredSetupFile in @((Join-Path $PSSCfgSkriptPath $PSSCfgSkriptFile), (Join-Path $CommonModulePath $CommonModuleFile)) + @($CommonModuleComponents.FullName)) {
    if (-not (Test-Path -LiteralPath $requiredSetupFile -PathType Leaf)) {
        Write-DeployLog "FEHLER: Für das Setup benötigte Datei nicht gefunden: $requiredSetupFile" -Level Error
        exit 1
    }
}

# Die zentrale Zielermittlung liefert exakt dieselbe Zielmenge wie Check,
# Download und Installation. Für die Verteilung wird nur der Verbindungstyp
# aus den Markierungen abgeleitet.
$Serverlist = Get-WindowsUpdateTargets -UpdateSettings $UpdateSettings -TargetComputers $TargetComputers -StrictAdditionalTargetClassification -WriteLog {
    param($message)
    Write-DeployLog $message
} | ForEach-Object {
    [PSCustomObject]@{
        Name       = $_.Name
        DeployType = if ($_.IsHypervisor) { 'Hypervisor' } elseif ($_.IsAdditional) { 'Additional' } else { 'AD' }
        ClassificationError = $_.ClassificationError
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
    $targetCounts = @()
    if ($Serverlist.Count -gt 0) { $targetCounts += "Windows $($Serverlist.Count)" }
    if ($LinuxSystemCount -gt 0) { $targetCounts += "Linux $LinuxSystemCount" }
    if ($HASystemCount -gt 0) { $targetCounts += "Home Assistant $HASystemCount" }
    $targetSummary = if ($targetCounts.Count -gt 0) { $targetCounts -join ', ' } else { 'keine' }
    Write-DeployLog "Ziele: $targetSummary; Gesamt $configuredSystemCount"
} else {
    $targetSummary = if ($Serverlist.Count -gt 0) { "Windows $($Serverlist.Count)" } else { 'keine' }
    Write-DeployLog "Ziele: $targetSummary; Gesamt $($Serverlist.Count)"
}

# Das Client-Zertifikat wird nur benötigt, wenn mindestens ein Nicht-AD-Gerät
# eingerichtet wird. Der öffentliche Schlüssel liegt unter Komponenten.
$nonAdTargets = @($Serverlist | Where-Object { $_.DeployType -and $_.DeployType -ne 'AD' })
if ($nonAdTargets.Count -gt 0) {
    $clientCertificate = Join-Path (Join-Path $PSScriptRoot 'Komponenten') 'WinRM-ClientCert.cer'
    $certificateSetup = Join-Path $PSScriptRoot 'Komponenten\Setup-ClientCertificate.ps1'
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
    # Setup-ClientCertificate kann den Thumbprint in settings.json aktualisieren.
    # Der Vorabcheck muss denselben aktuellen Zertifikatwert wie spätere Läufe nutzen.
    $Settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $ScriptName
    $UpdateSettings = $Settings.UpdateSettings
}

# Zielserver erhalten zunächst nur eine Versionsprüfung. Pakete werden erst
# zentral bereitgestellt, wenn ein Ziel ein fehlendes oder veraltetes benötigt.
$script:OfflineModulePayloadRoot = $null
$script:ExpectedModuleVersions = @{}
if ($Serverlist.Count -gt 0 -and -not $CleanupLegacyTempOnly) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $ProgressPreference = 'SilentlyContinue'
    foreach ($moduleName in @('PSWindowsUpdate', $(if ($enableWingetUpdates) { 'Microsoft.WinGet.Client' }))) {
        if ([string]::IsNullOrWhiteSpace($moduleName)) { continue }
        try {
            $galleryModule = Find-Module -Name $moduleName -Repository PSGallery -ErrorAction Stop -WarningAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($galleryModule) { $script:ExpectedModuleVersions[$moduleName] = [version]$galleryModule.Version }
        } catch {
            Write-DeployLog "Aktuelle PSGallery-Version von $moduleName nicht ermittelbar; Zielprüfung verwendet eine sichere Bereitstellung." -Level Warning -LogOnly
        }
    }
}

# Ergebnis-Tracking
$Results      = @()
$SuccessCount = 0
$FailCount    = 0
$LinuxConnectionErrors = 0
$HAConnectionErrors = 0
$script:BootstrapCredentials = @{}



# Die Ersteinrichtung darf nicht vom administrativen SMB-Share (C$) abhängen.
# AD-Geräte verbinden sich per Kerberos. Nicht-AD-Geräte verwenden einmalig
# interaktiv abgefragte lokale Administrator-Anmeldedaten; danach übernimmt die
# im Setup eingerichtete Client-Zertifikat-Authentifizierung.


# Hilfsfunktion: einzelnen Server verarbeiten


# Server verarbeiten
try {
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

    if ($Server.ClassificationError) {
        $deployResult = [PSCustomObject]@{
            Status = 'Failed'
            Message = 'AD-Zugehörigkeit konnte nicht zuverlässig geprüft werden; Ziel wurde aus Sicherheitsgründen nicht eingerichtet.'
        }
        Write-DeployLog "[$Servername] Zielklassifizierung fehlgeschlagen; Einrichtung wird übersprungen." -Level Error
        Write-DeployLog "[$Servername] Klassifizierungsfehler: $($Server.ClassificationError)" -LogOnly
    }
    else {
        $deployResult = Invoke-WindowsUpdateServerDeployment `
            -Servername                $Servername `
            -PSSCfgSkriptFile          $PSSCfgSkriptFile `
            -CommonModuleFile         $CommonModuleFile `
            -RootDirectory             $PSScriptRoot `
            -OfflineModulePayloadRoot $script:OfflineModulePayloadRoot `
            -DeployType                $deployTypeLabel `
            -CleanupLegacyTempOnly:$CleanupLegacyTempOnly `
            -ExpectedDeploymentVersion $expectedDeploymentVersion `
            -UpdateSettings $UpdateSettings `
            -EnableWingetUpdates $enableWingetUpdates `
            -ExpectedModuleVersions $script:ExpectedModuleVersions `
            -BootstrapCredentials $script:BootstrapCredentials `
            -WriteLog { param($Message, $Level = 'Info', [switch]$LogOnly, [switch]$ConsoleOnly) Write-DeployLog -Message $Message -Level $Level -LogOnly:$LogOnly -ConsoleOnly:$ConsoleOnly }
    }

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
}
finally {
    if ($script:OfflineModulePayloadRoot -and (Test-Path -LiteralPath $script:OfflineModulePayloadRoot)) {
        try {
            Remove-Item -LiteralPath $script:OfflineModulePayloadRoot -Recurse -Force -ErrorAction Stop
            Write-DeployLog 'Temporäre Offline-Modulpakete auf dem Verwaltungsserver bereinigt.' -LogOnly
        } catch {
            Write-DeployLog "Temporäre Offline-Modulpakete konnten nicht entfernt werden: $($_.Exception.Message)" -Level Warning
        }
    }
}

# Beim regulären Gesamtlauf werden SSH-Schlüssel, Schlüssel-Login und die
# begrenzten sudo-/HA-Voraussetzungen vorbereitet. Die beiden Skripte behalten
# dieselbe Ersteinrichtung zusätzlich für Check, Download und Installation.
if ([string]::IsNullOrWhiteSpace($TargetComputer) -and -not $CleanupLegacyTempOnly) {
    Write-DeployLog ''
    $hostPowerShell = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $hostPowerShell)) { $hostPowerShell = (Get-Process -Id $PID).Path }
    $connectionSetups = @()
    if ($linuxConfigured) { $connectionSetups += [PSCustomObject]@{ Name = 'Linux'; Script = 'Install-Linux Updates.ps1' } }
    if ($haConfigured) { $connectionSetups += [PSCustomObject]@{ Name = 'Home Assistant'; Script = 'Install-HomeAssistant Updates.ps1' } }
    foreach ($connectionSetup in $connectionSetups) {
        $connectionScript = Join-Path (Join-Path $PSScriptRoot 'Komponenten') $connectionSetup.Script
        $statsFileName = if ($connectionSetup.Name -eq 'Linux') { 'linux_update_check_stats.json' } else { 'ha_update_check_stats.json' }
        $statsPath = Join-Path (Join-Path $PSScriptRoot 'Logs') $statsFileName
        Remove-Item -LiteralPath $statsPath -Force -ErrorAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $connectionScript)) {
            if ($connectionSetup.Name -eq 'Linux') { $LinuxConnectionErrors = [Math]::Max(1, $LinuxSystemCount) } else { $HAConnectionErrors = 1 }
            Write-DeployLog "$($connectionSetup.Name)-Einrichtung übersprungen: Skript nicht gefunden." -Level Warning
            continue
        }
        Write-DeployLog "[$($connectionSetup.Name)] Verbindungseinrichtung gestartet."
        Write-DeployLog ''
        try {
            # Ausgabe nicht abfangen: SSH-Anmeldeprompts kommen über stderr.
            # -Quiet hält normale Statusmeldungen aus der Konsole fern.
            & $hostPowerShell -NoProfile -ExecutionPolicy Bypass -File $connectionScript -ConnectionOnly -Quiet
            $connectionExitCode = $LASTEXITCODE
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
                Write-DeployLog "[Linux] Hosts geprüft: $LinuxSystemCount" -Level $linuxLevel
                Write-DeployLog ''
                foreach ($hostResult in $linuxHosts) {
                    if ($hostResult.Status -eq 'Fehler') {
                        Write-DeployLog "  $($hostResult.Host): Verbindung/Einrichtung fehlgeschlagen; Details im Log." -Level Warning
                    } else {
                        Write-DeployLog "  $($hostResult.Host): SSH-Schlüssel und Verbindung funktionieren."
                    }
                }
                Write-DeployLog ''
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
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } -Operation "$($connectionSetup.Name)-Verbindungseinrichtung" -Target ([string]$connectionSetup.Host) -ErrorRecord $_
        }
        finally {
            Remove-Item -LiteralPath $statsPath -Force -ErrorAction SilentlyContinue
        }
        if ($connectionSetup.Name -eq 'Home Assistant') { Write-DeployLog '' }
    }
}

# Die automatische Check-Aufgabe betrifft den Verwaltungsserver selbst und
# wird unabhängig vom gerade bearbeiteten Windows-Ziel konfiguriert. Ein reiner
# Temp-Cleanup-Lauf verändert keine geplanten Aufgaben.
if (-not $CleanupLegacyTempOnly) {
    $scheduledCheckConfiguration = if ($UpdateSettings.PSObject.Properties['ScheduledCheck']) {
        $UpdateSettings.ScheduledCheck
    } else {
        [PSCustomObject]@{ Enabled = $false }
    }
    try {
        $scheduledCheckResult = Set-WindowsUpdateScheduledCheckTask -ScriptRoot $PSScriptRoot `
            -Configuration $scheduledCheckConfiguration -WriteLog { param($message) Write-DeployLog $message }
        if ($scheduledCheckResult.State -eq 'Registered') {
            Write-DeployLog "Geplante Update-Prüfung: $($scheduledCheckResult.Schedule)" -Level Success
        }
    }
    catch {
        Write-DeployLog 'Geplante Check-Aufgabe konnte nicht eingerichtet werden; Details im Verteilungslog.' -Level Warning
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeployLog $message } `
            -Operation 'Geplante Check-Aufgabe' -Target $env:COMPUTERNAME -ErrorRecord $_
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
    Write-DeployLog ''
    Write-DeployLog "Linux-Hosts: $LinuxSystemCount"
    Write-DeployLog "SSH-Schlüssel/Verbindung: $linuxConnectedCount erfolgreich" -Level $(if ($LinuxConnectionErrors -eq 0) { 'Success' } else { 'Warning' })
    Write-DeployLog "Fehler: $LinuxConnectionErrors" -Level $(if ($LinuxConnectionErrors -eq 0) { 'Success' } else { 'Error' })
}
if ($HASystemCount -gt 0 -or $HAConnectionErrors -gt 0) {
    $haConnectedCount = [Math]::Max(0, $HASystemCount - $HAConnectionErrors)
    Write-DeployLog ''
    Write-DeployLog "Home-Assistant-Instanzen: $HASystemCount"
    Write-DeployLog "Verbindung: $haConnectedCount erfolgreich" -Level $(if ($HAConnectionErrors -eq 0) { 'Success' } else { 'Warning' })
    Write-DeployLog "Fehler: $HAConnectionErrors" -Level $(if ($HAConnectionErrors -eq 0) { 'Success' } else { 'Error' })
}
$totalSystems = $Results.Count + $LinuxSystemCount + $HASystemCount
Write-DeployLog ''
Write-DeployLog "Gesamt Systeme: $totalSystems"

# Fehlerhafte Server anzeigen
Write-DeployLog ''
if ($script:DeployLogEnabled) { Write-DeployLog "Logdatei: $script:DeployLogFile" }
if ($script:DeployLogEnabled) {
    $null = Invoke-WindowsUpdateRetentionWithLog -Directory $script:DeployLogDirectory -Filter ("{0}_*.log" -f $ScriptName) -KeepFiles $script:DeployKeepLogFiles -Description 'Verteilungs-Logs' -WriteLog { param($message) Write-DeployLog $message }
}
