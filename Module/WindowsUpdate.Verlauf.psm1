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
        return $Value
    }

    # PSWindowsUpdate liefert bereits lokale Uhrzeiten. Diese werden als
    # zeitzonenloser Text übertragen und dürfen nicht nochmals verschoben werden.
    if ([string]$Value -match '^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?$') {
        return [datetime]::Parse([string]$Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None)
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
        if (line ~ /^Start-Date:/) {
          date=line
          sub(/^Start-Date:[[:space:]]*/, "", date)
          gsub(/[[:space:]]+/, " ", date)
          date=substr(date, 1, 16)
        }
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

function New-WindowsUpdateHistoryHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][ValidateRange(1,3650)][int]$Days,
        [Parameter(Mandatory)][ValidateRange(1,1000)][int]$MaxEventsPerTarget
    )

    $results = @($Results)
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
    return $html
}
