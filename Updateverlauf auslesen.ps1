[CmdletBinding()]
param(
    [ValidateRange(1, 3650)][int]$Days = 90,
    [ValidateRange(1, 1000)][int]$MaxEventsPerTarget = 100
)

# Ältere Windows-/PowerShell-Versionen verwenden sonst oft TLS 1.0 als Standard.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# Die gemeinsamen Skripte werden beim Start aktualisiert.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Komponenten\Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $temporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Komponenten/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $temporaryPath -ErrorAction Stop
        Move-Item -LiteralPath $temporaryPath -Destination $scriptUpdatePath -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath ($scriptUpdatePath + '.download') -Force -ErrorAction SilentlyContinue
        Write-Warning 'GitHub-Updater nicht erreichbar; vorhandene Skriptversion wird ausgeführt.'
    }
}
$updaterLoaded = $false
if (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf) {
    try {
        . $scriptUpdatePath
        $updaterLoaded = [bool](Get-Command -Name Invoke-ServerUpdateScripts -CommandType Function -ErrorAction SilentlyContinue)
    }
    catch { Write-Warning "GitHub-Updater konnte nicht geladen werden; vorhandene Skriptversion wird ausgeführt. Ursache: $($_.Exception.Message)" }
}
if ($updaterLoaded) { Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RemainingArguments $args }

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$timeStamp = Get-Date -Format 'yyyy-MM-dd_HH-mm'
$logDirectory = Join-Path $PSScriptRoot 'Logs'
$logPath = Join-Path $logDirectory ("{0}_{1}.log" -f $scriptName, $timeStamp)
$writeLogFile = $true
$settings = $null
$updateSettings = $null

Import-Module (Join-Path $PSScriptRoot 'Module\WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

function Write-HistoryLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [switch]$LogOnly)
    Write-WindowsUpdateLog -Message $Message -LogFile $script:logPath -ScriptName $script:scriptName `
        -RunTimestamp $script:timeStamp -WriteLogFile $script:writeLogFile -LogOnly:$LogOnly
}

try {
    $settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $scriptName -WriteLog { param($message) Write-HistoryLog $message -LogOnly }
    $updateSettings = $settings.UpdateSettings
    $script:writeLogFile = $updateSettings.PSObject.Properties['WriteLogFile'] -and [bool]$updateSettings.WriteLogFile
    $mailSettings = $settings.MailSettings
    $keepLogs = if ($updateSettings.PSObject.Properties['KeepLogFiles']) { [Math]::Max(1, [int]$updateSettings.KeepLogFiles) } else { 5 }
    if ($script:writeLogFile) {
        New-Item -Path $logDirectory -ItemType Directory -Force | Out-Null
        $null = New-Item -Path $logPath -ItemType File -Force
        $cleanup = Invoke-WindowsUpdateRetentionWithLog -Directory $logDirectory -Filter ("{0}_*.log" -f $scriptName) -KeepFiles $keepLogs -Description 'Updateverlaufs-Protokolle' -WriteLog { param($message) Write-HistoryLog $message -LogOnly }
    }

    Write-HistoryLog "Updateverlauf startet: Zeitraum $Days Tage, maximal $MaxEventsPerTarget Einträge je Ziel."
    $targetSetting = if ([string]::IsNullOrWhiteSpace([string]$updateSettings.TargetComputers)) { 'Server' } else { [string]$updateSettings.TargetComputers }
    $linuxSettings = if ($settings.PSObject.Properties['LinuxSettings']) { $settings.LinuxSettings } else { $null }
    $haSettings = if ($settings.PSObject.Properties['HomeAssistantSettings']) { $settings.HomeAssistantSettings } else { $null }
    $linuxHosts = @()
    if ($linuxSettings -and $linuxSettings.PSObject.Properties['Hosts']) {
        $linuxHosts = @($linuxSettings.Hosts | Where-Object {
            $_ -and (($_.PSObject.Properties['Host'] -and $_.Host) -or ($_.PSObject.Properties['Name'] -and $_.Name))
        })
    }
    $haConfigured = $haSettings -and $haSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$haSettings.Host)
    $windowsTargets = @(Get-WindowsUpdateTargets -UpdateSettings $updateSettings -TargetComputers $targetSetting -PowerShellMajor $PSVersionTable.PSVersion.Major -WriteLog { param($message) Write-HistoryLog $message -LogOnly })
    $results = [System.Collections.Generic.List[object]]::new()
    $since = (Get-Date).AddDays(-$Days)

    foreach ($target in $windowsTargets) {
        $name = [string]$target.Name
        $record = [pscustomobject]@{ Target = $name; Type = 'Windows'; State = 'Fehler'; Message = ''; Events = @() }
        try {
            $authInfo = $null
            if ($target.IsAdditional -or $target.IsHypervisor) {
                $remoting = Initialize-WindowsUpdateRemoting -UpdateSettings $updateSettings -TargetComputer $name -IsNonAdTarget $true -WriteLog { param($message) Write-HistoryLog $message -LogOnly }
                $authInfo = $remoting.AuthInfo
            }
            $remoteHistory = {
                param($Limit)
                # Die JEA-Rolle stellt Get-WUHistory, Where-Object und
                # Select-Object bereit, aber nicht Sort-Object. Sortierung
                # und Zeitraumfilter erfolgen erst nach der Rückgabe auf dem Client.
                $history = @(Get-WUHistory -ErrorAction Stop | Select-Object -First $Limit)
                foreach ($item in $history) {
                    $historyDate = [datetime]$item.Date
                    $historyDateKind = $historyDate.Kind.ToString()
                    if ($historyDate.Kind -eq [DateTimeKind]::Utc) { $historyDate = $historyDate.ToLocalTime() }
                    elseif ($historyDate.Kind -eq [DateTimeKind]::Unspecified) {
                        # PSWindowsUpdate/JEA liefert WUA-Zeitwerte teils ohne Kind,
                        # obwohl sie UTC darstellen. Mit der Zielzeitzone lokalisieren.
                        $historyDate = [datetime]::SpecifyKind($historyDate, [DateTimeKind]::Utc).ToLocalTime()
                    }
                    [pscustomobject]@{
                        # UTC-Werte im Zielkontext in lokale Zeit umwandeln.
                        # Zeittext ohne Zeitzone verhindert eine weitere WinRM-Umdeutung.
                        Date = $historyDate.ToString('yyyy-MM-ddTHH:mm:ss.fffffff', [Globalization.CultureInfo]::InvariantCulture)
                        DateKind = $historyDateKind
                        TimeZoneOffset = [datetime]::Now.ToString('zzz')
                        Result = [string]$item.Result
                        Title = [string]$item.Title
                        Details = if ($item.PSObject.Properties['KB']) { [string]$item.KB } else { '' }
                    }
                }
            }
            $nativeWuaHistory = {
                param($Limit)
                $updateSession = New-Object -ComObject 'Microsoft.Update.Session' -ErrorAction Stop
                $entries = $updateSession.QueryHistory('', 0, 1000)
                $count = 0
                foreach ($entry in $entries) {
                    $resultName = switch ([int]$entry.ResultCode) {
                        2 { 'Succeeded' }
                        3 { 'Succeeded With Errors' }
                        4 { 'Failed' }
                        5 { 'Aborted' }
                        default { 'Unknown' }
                    }
                    $kb = if ([string]$entry.Title -match '(?i)KB\d+') { $matches[0].ToUpperInvariant() } else { '' }
                    [pscustomobject]@{
                        # Die COM-API liefert UTC; diese Zeit wird lokal umgerechnet.
                        Date = ([datetime]::SpecifyKind([datetime]$entry.Date, [DateTimeKind]::Utc)).ToString('o', [Globalization.CultureInfo]::InvariantCulture)
                        Result = $resultName
                        Title = [string]$entry.Title
                        Details = $kb
                    }
                    $count++
                    if ($count -ge $Limit) { break }
                }
            }
            try {
                $historyRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ConfigurationName 'WindowsUpdateAdm' -ScriptBlock $remoteHistory -ArgumentList @(1000))
            }
            catch {
                Write-HistoryLog "WindowsUpdateAdm-Verlauf auf $name nicht abrufbar; versuche Standard-WinRM. Ursache und Ergebnis stehen im Protokoll." -LogOnly
                Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Windows-Updateverlauf via JEA' -Target $name -ErrorRecord $_ -Context @('Fallback=Standard-WinRM')
                try {
                    $historyRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ScriptBlock $remoteHistory -ArgumentList @(1000))
                }
                catch {
                    Write-HistoryLog "PSWindowsUpdate-Verlauf über Standard-WinRM auf $name fehlgeschlagen; versuche Windows Update API. Details stehen im Protokoll." -LogOnly
                    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Windows-Updateverlauf via PSWindowsUpdate' -Target $name -ErrorRecord $_ -Context @('Fallback=Windows Update Agent COM API')
                    $historyRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ScriptBlock $nativeWuaHistory -ArgumentList @(1000))
                }
            }
            Write-HistoryLog "Windows-Verlauf auf ${name}: JEA/PSWindowsUpdate lieferte $(@($historyRows).Count) Rohereignis(se)." -LogOnly
            $dateKinds = @($historyRows | ForEach-Object { if ($_.PSObject.Properties['DateKind']) { [string]$_.PSObject.Properties['DateKind'].Value } } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            $timeZoneOffsets = @($historyRows | ForEach-Object { if ($_.PSObject.Properties['TimeZoneOffset']) { [string]$_.PSObject.Properties['TimeZoneOffset'].Value } } | Where-Object { $_ } | Sort-Object -Unique) -join ', '
            if ($dateKinds -or $timeZoneOffsets) { Write-HistoryLog "PSWindowsUpdate-Zeitbasis auf ${name}: DateKind=$dateKinds; UTC-Abweichung=$timeZoneOffsets." -LogOnly }
            $normalizedRows = foreach ($row in $historyRows) {
                $localDate = ConvertFrom-HistoryDate -Value $row.Date
                if ($localDate -ge $since) {
                    [pscustomobject]@{ Date = $localDate; Result = [string]$row.Result; Title = [string]$row.Title; Details = [string]$row.Details }
                }
            }
            $historyRows = @($normalizedRows | Sort-Object Date -Descending | Select-Object -First $MaxEventsPerTarget)
            Write-HistoryLog "Windows-Verlauf auf ${name}: $(@($historyRows).Count) Ereignis(se) nach Zeitraumfilter." -LogOnly
            if ($historyRows.Count -eq 0) {
                Write-HistoryLog "Windows-Verlauf über JEA/PSWindowsUpdate auf $name war leer; prüfe Windows Update Agent COM-API über Standard-WinRM." -LogOnly
                try {
                    $nativeRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ScriptBlock $nativeWuaHistory -ArgumentList @(1000))
                    Write-HistoryLog "Windows Update Agent COM-API auf $name lieferte $($nativeRows.Count) Rohereignis(se)." -LogOnly
                    $nativeNormalizedRows = foreach ($row in $nativeRows) {
                        $localDate = ConvertFrom-HistoryDate -Value $row.Date
                        if ($localDate -ge $since) {
                            [pscustomobject]@{ Date = $localDate; Result = [string]$row.Result; Title = [string]$row.Title; Details = [string]$row.Details }
                        }
                    }
                    $historyRows = @($nativeNormalizedRows | Sort-Object Date -Descending | Select-Object -First $MaxEventsPerTarget)
                    Write-HistoryLog "Windows Update Agent COM-API auf $name lieferte $($historyRows.Count) Ereignis(se) nach Zeitraumfilter." -LogOnly
                }
                catch {
                    Write-HistoryLog "Windows Update Agent COM-API über Standard-WinRM auf $name fehlgeschlagen; Details im Protokoll." -LogOnly
                    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Windows-Updateverlauf via Windows Update Agent COM API' -Target $name -ErrorRecord $_
                    throw
                }
            }
            foreach ($event in $historyRows) { Add-HistoryEvent -TargetResult $record -Event $event }
            $record.State = if ($record.Events.Count -gt 0) { 'Erfolg' } else { 'Leer' }
            $record.Message = if ($record.Events.Count -gt 0) { "$($record.Events.Count) Ereignis(se)" } else { 'Kein Updateverlauf im Zeitraum.' }
        }
        catch {
            $record.State = 'Fehler'; $record.Message = 'Abfrage fehlgeschlagen; Details im Protokoll.'
            Write-HistoryLog "Windows-Verlauf auf $name fehlgeschlagen; Details im Protokoll." -LogOnly
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Windows-Updateverlauf' -Target $name -ErrorRecord $_
        }
        $results.Add($record)
    }

    if ($linuxHosts.Count -gt 0) {
        $linuxKey = if ($linuxSettings.PSObject.Properties['KeyPath'] -and $linuxSettings.KeyPath) { [string]$linuxSettings.KeyPath } else { Join-Path $env:USERPROFILE '.ssh\id_rsa_linux' }
        $sshCommand = Get-Command -Name 'ssh.exe', 'ssh' -ErrorAction SilentlyContinue | Select-Object -First 1
        $sshPath = if ($linuxSettings.PSObject.Properties['SSHPath'] -and $linuxSettings.SSHPath) { [string]$linuxSettings.SSHPath } elseif ($sshCommand) { $sshCommand.Path } else { Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' }
        $connectTimeout = if ($linuxSettings.PSObject.Properties['ConnectTimeoutSeconds'] -and [int]$linuxSettings.ConnectTimeoutSeconds -gt 0) { [int]$linuxSettings.ConnectTimeoutSeconds } else { 15 }
        foreach ($hostEntry in $linuxHosts) {
            $name = if ($hostEntry.PSObject.Properties['Host']) { [string]$hostEntry.Host } else { [string]$hostEntry.Name }
            $record = [pscustomobject]@{ Target = $name; Type = 'Linux'; State = 'Fehler'; Message = ''; Events = @() }
            try {
                if (-not (Test-Path -LiteralPath $linuxKey -PathType Leaf)) { throw "SSH-Schlüssel fehlt: $linuxKey" }
                $history = Get-LinuxHistoryLines -HostEntry $hostEntry -KeyPath $linuxKey -SshPath $sshPath -SinceDate $since -Limit $MaxEventsPerTarget -ConnectTimeoutSeconds $connectTimeout
                if (@($history.Lines | Where-Object { $_ -like '__HISTORY_UNAVAILABLE__*' -or $_ -like '__HISTORY_PERMISSION__*' }).Count -gt 0) {
                    $record.State = 'Nicht verfügbar'; $record.Message = ($history.Lines | Where-Object { $_ -like '__HISTORY_UNAVAILABLE__*' -or $_ -like '__HISTORY_PERMISSION__*' } | Select-Object -First 1) -replace '^__HISTORY_(UNAVAILABLE|PERMISSION)__\s*', ''
                } elseif (@($history.Lines | Where-Object { $_ -match '^__PKGMGR_(DNF|YUM)__' -or $_ -match '^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?\t' }).Count -gt 0) {
                    $record.State = 'Erfolg'
                    $historyLines = @($history.Lines | Where-Object { $_ -notmatch '^__PKGMGR_(DNF|YUM)__' -and $_ -match '^\d{4}-\d{2}-\d{2}(?: \d{2}:\d{2})?\t' } | Select-Object -First $MaxEventsPerTarget)
                    foreach ($line in $historyLines) {
                        $parts = $line -split "`t", 4
                        $eventDate = [datetime]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
                        $actionLabel = switch -Regex ($parts[2]) {
                            '^(Install|Installed)$' { 'Installation' }
                            '^(Upgrade|Upgraded)$' { 'Aktualisierung' }
                            '^(Remove|Erase|Removed)$' { 'Entfernung' }
                            '^(Purge|Purged)$' { 'Bereinigung' }
                            default { [string]$parts[2] }
                        }
                        $eventResult = '{0} · {1}' -f $parts[1], $actionLabel
                        Add-HistoryEvent -TargetResult $record -Event ([pscustomobject]@{ Date = $eventDate; Result = $eventResult; Title = $parts[3].Trim(); Details = '' })
                    }
                    if ($record.Events.Count -eq 0) { $record.State = 'Leer'; $record.Message = 'Paketmanager meldet keinen Verlauf.' }
                    else { $record.Message = "$($record.Events.Count) Paketvorgang/-vorgänge im Zeitraum" }
                } elseif (@($history.Lines | Where-Object { $_ -match 'No transactions|No history|__NO_HISTORY__' }).Count -gt 0 -or @($history.Lines).Count -eq 0) {
                    $record.State = 'Leer'; $record.Message = 'Paketmanager meldet keinen Verlauf.'
                } else {
                    $record.State = 'Nicht verfügbar'; $record.Message = 'Verlaufsformat des Paketmanagers konnte nicht sicher ausgewertet werden.'
                    Write-HistoryLog "Linux-Verlauf auf $name lieferte ein nicht eindeutig auswertbares Format; Details im Protokoll." -LogOnly
                    Write-HistoryLog ((@($history.Lines) -join [Environment]::NewLine)) -LogOnly
                }
            }
            catch {
                $record.State = 'Fehler'; $record.Message = 'Abfrage fehlgeschlagen; Details im Protokoll.'
                Write-HistoryLog "Linux-Verlauf auf $name fehlgeschlagen; Details im Protokoll." -LogOnly
                Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Linux-Updateverlauf' -Target $name -ErrorRecord $_
            }
            $results.Add($record)
        }
    }

    if ($haConfigured) {
        $haName = [string]$haSettings.Host
        $results.Add([pscustomobject]@{ Target = $haName; Type = 'Home Assistant'; State = 'Nicht verfügbar'; Message = 'Home Assistant stellt in der konfigurierten Schnittstelle keine verlässliche Updatehistorie bereit.'; Events = @() })
        Write-HistoryLog "Home-Assistant-Verlauf auf $haName nicht verfügbar: Es gibt keine verlässliche Updatehistorienquelle in der bestehenden CLI/API-Integration." -LogOnly
    }

    Write-HistoryLog "Verarbeitung abgeschlossen: $($results.Count) Ziel(e)."
    foreach ($record in $results) {
        $summary = "[$($record.Type)] $($record.Target): $($record.State) – $($record.Message)"
        $color = switch ($record.State) { 'Erfolg' { 'Green' } 'Leer' { 'DarkGray' } 'Nicht verfügbar' { 'Yellow' } default { 'Red' } }
        Write-Host $summary -ForegroundColor $color
        Write-HistoryLog $summary -LogOnly
        foreach ($event in $record.Events) {
            $dateText = if ($event.Date) { ([datetime]$event.Date).ToString('dd.MM.yyyy HH:mm') } else { 'Datum nicht ermittelt' }
            Write-HistoryLog ("  {0} | {1} | {2} {3}" -f $dateText, $event.Result, $event.Title, $event.Details) -LogOnly
        }
    }

    if ($mailSettings -and $mailSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$mailSettings.Host)) {
        $company = if ($mailSettings.PSObject.Properties['CompanyName']) { [string]$mailSettings.CompanyName } else { 'Server' }
        $subject = "$company - Updateverlauf der letzten $Days Tage"
        $html = New-WindowsUpdateHistoryHtml -Results @($results) -Days $Days -MaxEventsPerTarget $MaxEventsPerTarget
        $sent = Send-WindowsUpdateHtmlMail -MailSettings $mailSettings -Subject $subject -HtmlBody $html -WriteLog { param($message) Write-HistoryLog $message -LogOnly }
        if (-not $sent) { Write-Host 'E-Mailversand fehlgeschlagen; Details stehen im Protokoll.' -ForegroundColor Red }
    } else {
        Write-Host 'Mailversand übersprungen: MailSettings sind nicht vollständig konfiguriert.' -ForegroundColor Yellow
        Write-HistoryLog 'Mailversand übersprungen: MailSettings.Host fehlt.' -LogOnly
    }
}
catch {
    Write-Host 'Updateverlauf konnte nicht vollständig erstellt werden; Details stehen im Protokoll.' -ForegroundColor Red
    if ($script:writeLogFile) {
        Write-HistoryLog 'Updateverlauf fehlgeschlagen; Details stehen im Protokoll.' -LogOnly
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Updateverlauf erstellen' -ErrorRecord $_
    } else {
        Write-Error $_
    }
    exit 1
}
