[CmdletBinding()]
param(
    [ValidateRange(1, 3650)][int]$Days = 90,
    [ValidateRange(1, 1000)][int]$MaxEventsPerTarget = 100
)

# Die gemeinsamen Skripte werden beim Start aktualisiert.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $temporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $temporaryPath -ErrorAction Stop
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

Import-Module (Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

function Write-HistoryLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [switch]$LogOnly)
    Write-WindowsUpdateLog -Message $Message -LogFile $script:logPath -ScriptName $script:scriptName `
        -RunTimestamp $script:timeStamp -WriteLogFile $script:writeLogFile -LogOnly:$LogOnly
}

function Add-HistoryEvent {
    param([Parameter(Mandatory)]$TargetResult, [Parameter(Mandatory)]$Event)
    $TargetResult.Events += [pscustomobject]@{
        Date = $Event.Date
        Result = [string]$Event.Result
        Title = [string]$Event.Title
        Details = [string]$Event.Details
    }
}

function Invoke-HistoryRemoteCommand {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [string]$ConfigurationName,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateRange(10, 3600)][int]$TimeoutSeconds = 180
    )
    $invokeParams = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo -ConfigurationName $ConfigurationName -OpenTimeoutSeconds 30 -OperationTimeoutSeconds $TimeoutSeconds
    $invokeParams.ScriptBlock = $ScriptBlock
    $invokeParams.AsJob = $true
    if ($ArgumentList.Count -gt 0) { $invokeParams.ArgumentList = $ArgumentList }
    $job = $null
    try {
        $job = Invoke-Command @invokeParams
        if (-not (Wait-Job -Job $job -Timeout $TimeoutSeconds)) {
            Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null
            throw [TimeoutException]::new("WinRM-Abfrage überschritt $TimeoutSeconds Sekunden.")
        }
        if ($job.State -ne 'Completed') {
            $reason = @($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message } | Where-Object { $_ }) -join '; '
            if (-not $reason) { $reason = "Remoting-Aufgabe endete mit Status '$($job.State)'" }
            throw $reason
        }
        return @(Receive-Job -Job $job -ErrorAction Stop)
    }
    finally {
        if ($job) {
            if ($job.State -in @('Running', 'NotStarted')) { Stop-Job -Job $job -ErrorAction SilentlyContinue | Out-Null }
            Remove-Job -Job $job -Force -ErrorAction SilentlyContinue
        }
    }
}

function Get-LinuxHistoryLines {
    param(
        [Parameter(Mandatory)]$HostEntry,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][string]$SshPath,
        [Parameter(Mandatory)][datetime]$SinceDate,
        [ValidateRange(1, 1000)][int]$Limit = 100,
        [int]$ConnectTimeoutSeconds = 15
    )
    $hostName = if ($HostEntry.PSObject.Properties['Host']) { [string]$HostEntry.Host } else { [string]$HostEntry.Name }
    $userName = [string]$HostEntry.User
    if ([string]::IsNullOrWhiteSpace($hostName) -or [string]::IsNullOrWhiteSpace($userName)) { throw 'Linux-Ziel benötigt Host/Name und User.' }

    # Nur lesender Abruf der Paketmanager-Protokolle; keine sudo- oder Updatebefehle.
    # Die ISO-Datumsgrenze erlaubt einen stabilen lexikografischen Vergleich in awk.
    $cutoff = $SinceDate.ToString('yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    $remoteCommand = @'
if [ -d /var/log/apt ] && ls /var/log/apt/history.log* >/dev/null 2>&1; then
  readable=0
  for f in /var/log/apt/history.log*; do [ -r "$f" ] && readable=1; done
  if [ "$readable" -eq 0 ]; then echo '__HISTORY_PERMISSION__ Paketmanager-Protokolle sind für den SSH-Benutzer nicht lesbar.'; exit 0; fi
  for f in /var/log/apt/history.log*; do
    [ -r "$f" ] || continue
    case "$f" in *.gz) zcat -f "$f" 2>/dev/null ;; *) cat "$f" ;; esac
  done | awk -v cutoff='__CUTOFF__' -v limit=__LIMIT__ '
    BEGIN { RS=""; FS="\n" }
    {
      date=""; action=""; packages=""
      for (i=1; i<=NF; i++) {
        line=$i
        if (line ~ /^Start-Date:/) { date=line; sub(/^Start-Date:[[:space:]]*/, "", date); date=substr(date, 1, 10) }
        else if (line ~ /^(Install|Upgrade|Remove|Purge):/) {
          if (action == "") { action=line; sub(/:.*/, "", action) }
          payload=line; sub(/^[^:]*:[[:space:]]*/, "", payload)
          if (packages != "") packages=packages "; "
          packages=packages payload
        }
      }
      if (date != "" && date >= cutoff && packages != "") print date "\t" action ": " packages
    }
  ' | sort -r | head -n __LIMIT__
elif command -v dnf >/dev/null 2>&1; then
  echo '__PKGMGR_DNF__'
  dnf -q history list 2>&1 | awk -F'|' -v cutoff='__CUTOFF__' '
    NR>2 && $1 ~ /[0-9]/ {
      for(i=1;i<=5;i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      date=$3; if (substr(date,1,10) >= cutoff) print date "\t" $1 " | " $4 " | " $5
    }' | sort -r | head -n __LIMIT__
elif command -v yum >/dev/null 2>&1; then
  echo '__PKGMGR_YUM__'
  yum -q history list 2>&1 | awk -F'|' -v cutoff='__CUTOFF__' '
    NR>2 && $1 ~ /[0-9]/ {
      for(i=1;i<=5;i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
      date=$3; if (substr(date,1,10) >= cutoff) print date "\t" $1 " | " $4 " | " $5
    }' | sort -r | head -n __LIMIT__
else
  echo '__HISTORY_UNAVAILABLE__ Paketmanager-/Verlaufsquelle nicht unterstützt.'
fi
'@
    $remoteCommand = $remoteCommand.Replace('__CUTOFF__', $cutoff).Replace('__LIMIT__', [string]$Limit)
    $sshArguments = Get-WindowsUpdateSshArguments -KeyPath $KeyPath -ConnectTimeoutSeconds $ConnectTimeoutSeconds -BatchMode
    $sshArguments += @("${userName}@${hostName}", $remoteCommand)
    $lines = @(& $SshPath @sshArguments 2>&1 | ForEach-Object { [string]$_ })
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "SSH-Abfrage auf $hostName endete mit Exitcode ${exitCode}: $($lines -join ' ')" }
    return [pscustomobject]@{ Host = $hostName; Lines = $lines }
}

function ConvertTo-HtmlSafe {
    param([AllowEmptyString()][string]$Value)
    return [Net.WebUtility]::HtmlEncode($Value)
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
                param($SinceDate, $Limit)
                # Die JEA-Rolle stellt Get-WUHistory, Where-Object und
                # Select-Object bereit, aber nicht Sort-Object. Sortierung
                # erfolgt deshalb erst nach der Rückgabe auf dem Client.
                $history = @(Get-WUHistory -ErrorAction Stop | Where-Object { $_.Date -ge $SinceDate } | Select-Object -First $Limit)
                foreach ($item in $history) {
                    [pscustomobject]@{
                        Date = [datetime]$item.Date
                        Result = [string]$item.Result
                        Title = [string]$item.Title
                        Details = if ($item.PSObject.Properties['KB']) { [string]$item.KB } else { '' }
                    }
                }
            }
            $nativeWuaHistory = {
                param($SinceDate, $Limit)
                $updateSession = New-Object -ComObject 'Microsoft.Update.Session' -ErrorAction Stop
                $entries = $updateSession.QueryHistory('', 0, 1000)
                $count = 0
                foreach ($entry in $entries) {
                    if ([datetime]$entry.Date -lt $SinceDate) { continue }
                    $resultName = switch ([int]$entry.ResultCode) {
                        2 { 'Succeeded' }
                        3 { 'Succeeded With Errors' }
                        4 { 'Failed' }
                        5 { 'Aborted' }
                        default { 'Unknown' }
                    }
                    $kb = if ([string]$entry.Title -match '(?i)KB\d+') { $matches[0].ToUpperInvariant() } else { '' }
                    [pscustomobject]@{
                        Date = [datetime]$entry.Date
                        Result = $resultName
                        Title = [string]$entry.Title
                        Details = $kb
                    }
                    $count++
                    if ($count -ge $Limit) { break }
                }
            }
            try {
                $historyRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ConfigurationName 'WindowsUpdateAdm' -ScriptBlock $remoteHistory -ArgumentList @($since, $MaxEventsPerTarget))
            }
            catch {
                Write-HistoryLog "WindowsUpdateAdm-Verlauf auf $name nicht abrufbar; versuche Standard-WinRM. Ursache und Ergebnis stehen im Protokoll." -LogOnly
                Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Windows-Updateverlauf via JEA' -Target $name -ErrorRecord $_ -Context @('Fallback=Standard-WinRM')
                try {
                    $historyRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ScriptBlock $remoteHistory -ArgumentList @($since, $MaxEventsPerTarget))
                }
                catch {
                    Write-HistoryLog "PSWindowsUpdate-Verlauf über Standard-WinRM auf $name fehlgeschlagen; versuche Windows Update API. Details stehen im Protokoll." -LogOnly
                    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-HistoryLog $message -LogOnly } -Operation 'Windows-Updateverlauf via PSWindowsUpdate' -Target $name -ErrorRecord $_ -Context @('Fallback=Windows Update Agent COM API')
                    $historyRows = @(Invoke-HistoryRemoteCommand -ComputerName $name -AuthInfo $authInfo -ScriptBlock $nativeWuaHistory -ArgumentList @($since, $MaxEventsPerTarget))
                }
            }
            foreach ($event in @($historyRows | Sort-Object Date -Descending)) { Add-HistoryEvent -TargetResult $record -Event $event }
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
                } elseif (@($history.Lines | Where-Object { $_ -match '^__PKGMGR_(DNF|YUM)__' -or $_ -match '^\d{4}-\d{2}-\d{2}\t' }).Count -gt 0) {
                    $record.State = 'Erfolg'
                    $historyLines = @($history.Lines | Where-Object { $_ -notmatch '^__PKGMGR_(DNF|YUM)__' -and $_ -match '^\d{4}-\d{2}-\d{2}\t' } | Select-Object -First $MaxEventsPerTarget)
                    foreach ($line in $historyLines) {
                        $parts = $line -split "`t", 2
                        $eventDate = [datetime]::ParseExact($parts[0], 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
                        Add-HistoryEvent -TargetResult $record -Event ([pscustomobject]@{ Date = $eventDate; Result = 'Abgeschlossen'; Title = $parts[1].Trim(); Details = 'Paketmanager-Verlauf' })
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
        $rows = foreach ($record in $results) {
            if ($record.Events.Count -eq 0) {
                '<tr><td>{0}</td><td>{1}</td><td colspan="2">{2}</td><td colspan="2">{3}</td></tr>' -f (ConvertTo-HtmlSafe $record.Target), (ConvertTo-HtmlSafe $record.Type), (ConvertTo-HtmlSafe $record.State), (ConvertTo-HtmlSafe $record.Message)
            } else {
                foreach ($event in $record.Events) {
                    $dateText = if ($event.Date) { ([datetime]$event.Date).ToString('dd.MM.yyyy HH:mm') } else { '—' }
                    '<tr><td>{0}</td><td>{1}</td><td>{2}</td><td>{3}</td><td>{4}</td><td>{5}</td></tr>' -f (ConvertTo-HtmlSafe $record.Target), (ConvertTo-HtmlSafe $record.Type), (ConvertTo-HtmlSafe $dateText), (ConvertTo-HtmlSafe $event.Result), (ConvertTo-HtmlSafe $event.Title), (ConvertTo-HtmlSafe $event.Details)
                }
            }
        }
        $html = @"
<!doctype html><html><head><meta charset="utf-8"><style>
body{font-family:Arial,sans-serif;color:#222}h1{color:#1565c0}table{border-collapse:collapse;width:100%;table-layout:fixed}th,td{border:1px solid #ccc;padding:7px;text-align:left;vertical-align:top;overflow-wrap:anywhere}th{background:#eaf2f8}tr:nth-child(even){background:#f7f7f7}.summary{margin:12px 0;padding:10px;background:#f1f5f9}
</style></head><body><h1>Updateverlauf</h1><p>Windows und Linux: letzte $Days Tage · maximal $MaxEventsPerTarget Paketvorgänge je Linux-Ziel · Erstellt: $(Get-Date -Format 'dd.MM.yyyy HH:mm')</p>
<table><thead><tr><th style="width:11%">Ziel</th><th style="width:12%">System</th><th style="width:14%">Zeit/Status</th><th style="width:14%">Ergebnis</th><th style="width:35%">Update / Meldung</th><th style="width:14%">Details</th></tr></thead><tbody>$($rows -join "`n")</tbody></table>
<p>„Leer“ bedeutet, dass die Abfrage erfolgreich war und im Zeitraum keine Verlaufseinträge lieferte. „Nicht verfügbar“ bedeutet, dass keine verlässliche Quelle vorliegt.</p></body></html>
"@
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
