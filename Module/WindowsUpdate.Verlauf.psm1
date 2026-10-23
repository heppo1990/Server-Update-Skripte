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
