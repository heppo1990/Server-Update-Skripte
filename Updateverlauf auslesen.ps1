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

function ConvertFrom-HistoryDate {
    param([Parameter(Mandatory)]$Value)
    if ($Value -is [datetime]) {
        if ($Value.Kind -eq [DateTimeKind]::Utc) { return $Value.ToLocalTime() }
        if ($Value.Kind -eq [DateTimeKind]::Unspecified) {
            return ([datetime]::SpecifyKind($Value, [DateTimeKind]::Utc)).ToLocalTime()
        }
        return $Value
    }

    $dateOffset = [datetimeoffset]::MinValue
    if ([datetimeoffset]::TryParse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref]$dateOffset)) {
        return $dateOffset.LocalDateTime
    }
    return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal)
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
      date=""; endDate=0; hasError=0; install=""; upgrade=""; remove=""; purge=""
      for (i=1; i<=NF; i++) {
        line=$i
        if (line ~ /^Start-Date:/) { date=line; sub(/^Start-Date:[[:space:]]*/, "", date); date=substr(date, 1, 16) }
        else if (line ~ /^End-Date:/) { endDate=1 }
        else if (line ~ /^Error:/) { hasError=1 }
        else if (line ~ /^(Install|Upgrade|Remove|Purge):/) {
          action=line; sub(/:.*/, "", action)
          payload=line; sub(/^[^:]*:[[:space:]]*/, "", payload)
          if (action == "Install") install=(install == "" ? payload : install "; " payload)
          else if (action == "Upgrade") upgrade=(upgrade == "" ? payload : upgrade "; " payload)
          else if (action == "Remove") remove=(remove == "" ? payload : remove "; " payload)
          else if (action == "Purge") purge=(purge == "" ? payload : purge "; " payload)
        }
      }
      if (date != "" && substr(date,1,10) >= cutoff) {
        status=(endDate && !hasError ? "Erfolgreich" : "Fehlgeschlagen")
        if (install != "") print date "\t" status "\tInstall" "\t" install
        if (upgrade != "") print date "\t" status "\tUpgrade" "\t" upgrade
        if (remove != "") print date "\t" status "\tRemove" "\t" remove
        if (purge != "") print date "\t" status "\tPurge" "\t" purge
      }
    }
  ' | sort -r | head -n __LIMIT__
elif command -v dnf >/dev/null 2>&1; then
  echo '__PKGMGR_DNF__'
  emit_history() {
    manager=$1
    "$manager" -q history list 2>&1 | awk -F'|' -v cutoff='__CUTOFF__' '
      NR>2 && $1 ~ /[0-9]/ {
        for(i=1;i<=5;i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        id=$1; gsub(/[^0-9]/, "", id); date=$3
        if (substr(date,1,10) >= cutoff) print id "\t" date "\t" $4 "\t" $5
      }' | while IFS="$(printf '\t')" read -r id date action altered; do
        rc=$("$manager" -q history info "$id" 2>/dev/null | awk -F: 'tolower($1) ~ /return-code/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
        case "$rc" in *Success*) state="Erfolgreich" ;; *Error*|*Fail*|*Abort*) state="Fehlgeschlagen" ;; *) state="Status unbekannt" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$date" "$state" "$action" "$altered"
      done | sort -r | head -n __LIMIT__
  }
  emit_history dnf
elif command -v yum >/dev/null 2>&1; then
  echo '__PKGMGR_YUM__'
  emit_history() {
    manager=$1
    "$manager" -q history list 2>&1 | awk -F'|' -v cutoff='__CUTOFF__' '
      NR>2 && $1 ~ /[0-9]/ {
        for(i=1;i<=5;i++) gsub(/^[[:space:]]+|[[:space:]]+$/, "", $i)
        id=$1; gsub(/[^0-9]/, "", id); date=$3
        if (substr(date,1,10) >= cutoff) print id "\t" date "\t" $4 "\t" $5
      }' | while IFS="$(printf '\t')" read -r id date action altered; do
        rc=$("$manager" -q history info "$id" 2>/dev/null | awk -F: 'tolower($1) ~ /return-code/ {gsub(/^[[:space:]]+|[[:space:]]+$/, "", $2); print $2; exit}')
        case "$rc" in *Success*) state="Erfolgreich" ;; *Error*|*Fail*|*Abort*) state="Fehlgeschlagen" ;; *) state="Status unbekannt" ;; esac
        printf '%s\t%s\t%s\t%s\n' "$date" "$state" "$action" "$altered"
      done | sort -r | head -n __LIMIT__
  }
  emit_history yum
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
                param($Limit)
                # Die JEA-Rolle stellt Get-WUHistory, Where-Object und
                # Select-Object bereit, aber nicht Sort-Object. Sortierung
                # und Zeitraumfilter erfolgen erst nach der Rückgabe auf dem Client.
                $history = @(Get-WUHistory -ErrorAction Stop | Select-Object -First $Limit)
                foreach ($item in $history) {
                    [pscustomobject]@{
                        # Als UTC-Text übertragen, damit WinRM den Zeitwert
                        # nicht beim Serialisieren verschiebt.
                        Date = ([datetime]$item.Date).ToUniversalTime().ToString('o', [Globalization.CultureInfo]::InvariantCulture)
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
                        # UTC als Text übertragen; die Umrechnung erfolgt lokal.
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
        $eventCount = [int](($results | ForEach-Object { $_.Events.Count } | Measure-Object -Sum).Sum)
        $targetSections = foreach ($record in $results) {
            $badgeStyle = switch ($record.State) {
                'Erfolg' { 'background:#e6f4ea;color:#176b35;' }
                'Leer' { 'background:#edf1f5;color:#4b5563;' }
                'Nicht verfügbar' { 'background:#fff3cd;color:#765600;' }
                default { 'background:#fde8e7;color:#a12622;' }
            }
            $safeTarget = ConvertTo-HtmlSafe $record.Target
            $safeType = ConvertTo-HtmlSafe $record.Type
            $safeState = ConvertTo-HtmlSafe $record.State
            $sectionContent = if ($record.Events.Count -eq 0) {
                '<tr><td style="padding:12px 16px;color:#596579;font-size:14px;">{0}</td></tr>' -f (ConvertTo-HtmlSafe $record.Message)
            } else {
                foreach ($event in $record.Events) {
                    $dateText = if ($event.Date) { ([datetime]$event.Date).ToString('dd.MM.yyyy HH:mm') } else { '—' }
                    $resultLabel = switch ([string]$event.Result) {
                        'Succeeded' { 'Erfolgreich' }
                        'Succeeded With Errors' { 'Erfolgreich mit Fehlern' }
                        'Failed' { 'Fehlgeschlagen' }
                        'Aborted' { 'Abgebrochen' }
                        'InProgress' { 'In Bearbeitung' }
                        default { [string]$event.Result }
                    }
                    $resultStyle = if ($resultLabel -match '^Erfolgreich mit Fehlern') { 'color:#765600;' }
                        elseif ($resultLabel -match '^Erfolgreich') { 'color:#176b35;' }
                        elseif ($resultLabel -match '^(Fehlgeschlagen|Abgebrochen)') { 'color:#a12622;' }
                        elseif ($resultLabel -match '^(Status unbekannt|In Bearbeitung)') { 'color:#765600;' }
                        else { 'color:#394454;' }
                    '<tr><td width="132" style="width:132px;padding:9px 12px;border-top:1px solid #e6eaf0;color:#596579;font-size:13px;white-space:nowrap;vertical-align:top;">{0}</td><td width="145" style="width:145px;padding:9px 12px;border-top:1px solid #e6eaf0;font-size:13px;font-weight:bold;vertical-align:top;{1}">{2}</td><td style="padding:9px 12px;border-top:1px solid #e6eaf0;color:#202938;font-size:14px;line-height:1.45;overflow-wrap:anywhere;">{3}</td></tr>' -f (ConvertTo-HtmlSafe $dateText), $resultStyle, (ConvertTo-HtmlSafe $resultLabel), (ConvertTo-HtmlSafe $event.Title)
                }
            }
            $eventLabel = if ($record.Events.Count -gt 0) { "$($record.Events.Count) Einträge" } else { $safeState }
            @"
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="width:100%;margin:0 0 14px 0;border:1px solid #dce3ec;border-collapse:separate;border-spacing:0;background:#ffffff;">
<tr><td colspan="3" style="padding:12px 16px;background:#f3f6fa;border-bottom:1px solid #dce3ec;">
<span style="font-size:16px;font-weight:bold;color:#19283d;">$safeTarget</span>
<span style="margin-left:8px;color:#69778a;font-size:12px;">$safeType</span>
<span style="float:right;padding:4px 9px;border-radius:12px;font-size:12px;font-weight:bold;$badgeStyle">$eventLabel</span>
</td></tr>
$(if ($record.Events.Count -gt 0) { '<tr><th align="left" width="132" style="padding:7px 12px;background:#fafbfd;color:#667085;font-size:11px;text-transform:uppercase;">Datum</th><th align="left" width="145" style="padding:7px 12px;background:#fafbfd;color:#667085;font-size:11px;text-transform:uppercase;">Ergebnis</th><th align="left" style="padding:7px 12px;background:#fafbfd;color:#667085;font-size:11px;text-transform:uppercase;">Update</th></tr>' })
$($sectionContent -join "`n")
</table>
"@
        }
        $safeCreated = ConvertTo-HtmlSafe (Get-Date -Format 'dd.MM.yyyy HH:mm')
        $html = @"
<!doctype html><html><head><meta charset="utf-8"></head><body style="margin:0;padding:20px;background:#f4f6f9;font-family:Arial,Helvetica,sans-serif;color:#202938;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" style="max-width:1000px;margin:0 auto;border-collapse:collapse;">
<tr><td style="padding:22px 24px;background:#17365d;color:#ffffff;">
<div style="font-size:22px;font-weight:bold;">Updateverlauf</div>
<div style="padding-top:6px;font-size:13px;color:#dce7f5;">Letzte $Days Tage · erstellt am $safeCreated</div>
</td></tr>
<tr><td style="padding:14px 0 10px 0;">
<table role="presentation" cellpadding="0" cellspacing="0" style="border-collapse:collapse;"><tr>
<td style="padding:10px 16px;background:#ffffff;border:1px solid #dce3ec;"><div style="font-size:20px;font-weight:bold;color:#17365d;">$($results.Count)</div><div style="font-size:11px;color:#667085;">Ziele</div></td>
<td width="10"></td>
<td style="padding:10px 16px;background:#ffffff;border:1px solid #dce3ec;"><div style="font-size:20px;font-weight:bold;color:#17365d;">$eventCount</div><div style="font-size:11px;color:#667085;">Verlaufseinträge</div></td>
</tr></table>
</td></tr>
<tr><td style="padding:4px 0 0 0;">$($targetSections -join "`n")</td></tr>
<tr><td style="padding:8px 2px 0 2px;color:#69778a;font-size:12px;line-height:1.5;">„Leer“ bedeutet: Die Abfrage war erfolgreich, es gab aber keine Verlaufseinträge im Zeitraum. „Nicht verfügbar“ bedeutet: Für dieses Ziel gibt es keine verlässliche Verlaufquelle. Linux: höchstens $MaxEventsPerTarget Paketvorgänge je Ziel.</td></tr>
</table></body></html>
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
