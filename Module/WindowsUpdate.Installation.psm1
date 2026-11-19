function Get-NextScheduledTime {
  param([Parameter(Mandatory)][string]$Time)
  if ([string]::IsNullOrWhiteSpace($Time)) { return $null }
  $parsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($Time, [ref]$parsed)) {
    throw "Ungültige Uhrzeit '$Time'. Erwartet wird z. B. 19:00."
  }
  $when = (Get-Date).Date.Add($parsed.TimeOfDay)
  if ($when -le (Get-Date)) { $when = $when.AddDays(1) }
  return $when
}

function Get-NextRebootTimeInWindow {
  param(
    [Parameter(Mandatory)][string]$StartTime,
    [string]$LatestTime,
    [int]$DelayMinutes = 0,
    [datetime]$NotBefore = [datetime]::MinValue,
    [switch]$PreferImmediate
  )
  if ($PreferImmediate) {
    # VMRebootImmediately übersteuert Startzeit und Wartungsfenster. Die
    # Sicherheitsminute und der konfigurierte Abstand zwischen VMs bleiben.
    $immediateAt = (Get-Date).AddMinutes(1 + $DelayMinutes)
    if ($NotBefore -gt $immediateAt) { return $NotBefore }
    return $immediateAt
  }
  $start = Get-NextScheduledTime $StartTime
  if ([string]::IsNullOrWhiteSpace($LatestTime)) {
    $scheduled = $start.AddMinutes($DelayMinutes)
    if ($scheduled -lt $NotBefore) { $scheduled = $NotBefore }
    return $scheduled
  }

  $latestParsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($LatestTime, [ref]$latestParsed)) {
    throw "Ungültige späteste Neustartzeit '$LatestTime'. Erwartet wird z. B. 23:00."
  }
  $latest = $start.Date.Add($latestParsed.TimeOfDay)
  if ($latest -lt $start) { $latest = $latest.AddDays(1) }
  $scheduled = $start.AddMinutes($DelayMinutes)
  if ($scheduled -lt $NotBefore) { $scheduled = $NotBefore }
  while ($scheduled -gt $latest) {
    $start = $start.AddDays(1)
    $latest = $latest.AddDays(1)
    $scheduled = $start.AddMinutes($DelayMinutes)
    if ($start.AddMinutes($DelayMinutes) -gt $latest) {
      throw "Der Neustartversatz von $DelayMinutes Minute(n) liegt außerhalb des konfigurierten Wartungsfensters."
    }
    if ($scheduled -lt $NotBefore) { $scheduled = $NotBefore }
  }
  return $scheduled
}

function Test-ServerIsVirtual {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Servername,
        [Parameter(Mandatory)][string]$ComputerFQDN,
        [Parameter(Mandatory)][scriptblock]$WriteLog,
        $AuthInfo = $null
    )

    $logCallback = $WriteLog
    $writeLogForRemoting = { param($message) & $logCallback -Message $message }.GetNewClosure()
    $sb = {
        $cs = Get-CimInstance Win32_ComputerSystem
        $bios = Get-CimInstance Win32_BIOS
        ($cs.Manufacturer + ' ' + $cs.Model + ' ' + $bios.Manufacturer) -match 'VMware|VirtualBox|Virtual Machine|KVM|QEMU|Xen|Bochs'
    }
    $isLocal = $Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ComputerFQDN -or $Servername -ieq "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
    # Inventardaten gehören zur vorhandenen administrativen Verwaltungsverbindung,
    # nicht zur eingeschränkten WindowsUpdateAdm-Rolle.
    if ($isLocal) { return [bool](& $sb) }
    $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
    $params.ScriptBlock = $sb
    return [bool](Invoke-Command @params)
}

function Test-WindowsUpdateRebootRequired {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Servername,
        [Parameter(Mandatory)][string]$ComputerFQDN,
        [Parameter(Mandatory)][scriptblock]$WriteLog,
        $AuthInfo = $null
    )

    $logCallback = $WriteLog
    $writeLogForRemoting = { param($message) & $logCallback -Message $message }.GetNewClosure()
    $sb = {
        $status = Get-WURebootStatus -Silent -ErrorAction Stop
        if ($status -is [bool]) { return $status }
        if ($null -ne $status -and $null -ne $status.PSObject.Properties['RebootRequired']) {
            return [bool]$status.RebootRequired
        }
        return $false
    }
    $isLocal = $Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ComputerFQDN -or $Servername -ieq "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
    $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog $writeLogForRemoting
    if ($isLocal -and -not $jeaSupported) {
        throw "WindowsUpdateAdm/JEA ist auf dem Verwaltungsserver $Servername nicht verfügbar; der Neustartstatus wird nicht direkt lokal abgefragt."
    }
    if (-not $jeaSupported -and $AuthInfo) {
        $systemResult = @(Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode RebootStatus -WriteLog $writeLogForRemoting)
        return [bool]($systemResult | Select-Object -First 1 -ExpandProperty RebootRequired)
    }
    $configurationName = if ($jeaSupported) { 'WindowsUpdateAdm' } else { $null }
    $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo -ConfigurationName $configurationName
    $params.ScriptBlock = $sb
    return [bool](Invoke-Command @params)
}



function Register-WindowsUpdateRebootTask {
  param(
    [Parameter(Mandatory)][string]$Servername,
    [string]$RebootTime,
    [string]$LatestRebootTime,
    [int]$DelayMinutes = 0,
    [datetime]$NotBefore = [datetime]::MinValue,
    [switch]$Immediately,
    [Parameter(Mandatory)][scriptblock]$WriteLog,
    $AuthInfo = $null
  )
  $logCallback = $WriteLog
  $taskLogCallback = { param($message, $logOnly) & $logCallback -Message $message -LogOnly:$logOnly }.GetNewClosure()
  if (-not $Immediately -and [string]::IsNullOrWhiteSpace($RebootTime)) { return }
  # Eine Minute Abstand verhindert, dass die Verbindung des Installationslaufs abgeschnitten wird.
  if ($Immediately -and -not [string]::IsNullOrWhiteSpace($RebootTime) -and -not [string]::IsNullOrWhiteSpace($LatestRebootTime)) {
    $at = Get-NextRebootTimeInWindow -StartTime $RebootTime -LatestTime $LatestRebootTime -DelayMinutes $DelayMinutes -NotBefore $NotBefore -PreferImmediate
  } elseif ($Immediately) {
    $at = (Get-Date).AddMinutes(1 + $DelayMinutes)
    if ($NotBefore -gt $at) { $at = $NotBefore }
  } else {
    $at = Get-NextRebootTimeInWindow -StartTime $RebootTime -LatestTime $LatestRebootTime -DelayMinutes $DelayMinutes -NotBefore $NotBefore
  }
  $taskName = 'WindowsUpdateAdm-Reboot'
  $registeredAt = [DateTime]::UtcNow.ToFileTimeUtc()
  $script = @"
`$taskName = '$taskName'
try {
  `$registeredAt = [DateTime]::FromFileTimeUtc($registeredAt)
  `$lastBoot = ([DateTime](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime()
  # Neustart wird erst nach dem Entfernen der Aufgabe angefordert.
  # Der Aufrufer legt diese Aufgabe nur nach tatsächlich installierten Windows-Updates an.
  # Ein manueller Neustart zwischenzeitlich wird am Bootzeitpunkt erkannt und nicht wiederholt.
  if (`$lastBoot -le `$registeredAt) {
    & (Join-Path `$env:WINDIR 'System32\schtasks.exe') /Delete /TN `$taskName /F *> `$null
    shutdown.exe /r /t 15 /f | Out-Null
  }
} finally { & (Join-Path `$env:WINDIR 'System32\schtasks.exe') /Delete /TN `$taskName /F *> `$null }
"@
  Register-OneTimeRemoteTask -Servername $Servername -TaskName $taskName -At $at -Script $script -AuthInfo $AuthInfo -WriteLog $taskLogCallback
  $rebootMode = if ($Immediately) { 'sofort nach Abschluss' } else { $at.ToString('dd.MM.yyyy HH:mm') }
  & $logCallback -Message "Neustart auf $Servername geplant: $rebootMode"
}

Export-ModuleMember -Function Get-NextScheduledTime, Get-NextRebootTimeInWindow, Test-ServerIsVirtual, Test-WindowsUpdateRebootRequired, Register-WindowsUpdateRebootTask

function New-WindowsUpdateVMRebootSlot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Target, [Parameter(Mandatory)][datetime]$Earliest,
        [string]$StartTime = '', [string]$LatestTime = '', [int]$IntervalMinutes = 5,
        [switch]$Immediately,
        [string]$StatePath = (Join-Path $env:ProgramData 'WindowsUpdateAdm\VM-Reboot-Slots.json'))
    $ErrorActionPreference = 'Stop'
    $interval = [Math]::Max(1,$IntervalMinutes)
    $directory = Split-Path -Parent $StatePath
    [void][IO.Directory]::CreateDirectory($directory)
    $lock = $null; $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        while (-not $lock) {
            try { $lock = [IO.File]::Open(($StatePath+'.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            catch [IO.IOException] { if ($timer.Elapsed.TotalSeconds -ge 15) { throw 'VM-Neustartplanung ist belegt; kein unkoordinierter Neustart wird angelegt.' }; Start-Sleep -Milliseconds 100 }
        }
        $slots = @()
        if (Test-Path -LiteralPath $StatePath) {
            $storedSlots = Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
            foreach ($storedSlot in $storedSlots) {
                if ([datetime]$storedSlot.At -gt (Get-Date).AddDays(-1) -and $storedSlot.Target -ine $Target) { $slots += $storedSlot }
            }
        }
        $candidate = $Earliest
        if ($candidate -lt (Get-Date).AddMinutes(1)) { $candidate = (Get-Date).AddMinutes(1) }
        do {
            $conflicts = @($slots | Where-Object { [math]::Abs(([datetime]$_.At - $candidate).TotalMinutes) -lt [Math]::Max($interval,[int]$_.IntervalMinutes) })
            if ($conflicts.Count -eq 0) { break }
            $candidate = (@($conflicts | ForEach-Object { ([datetime]$_.At).AddMinutes([Math]::Max($interval,[int]$_.IntervalMinutes)) }) | Sort-Object -Descending | Select-Object -First 1)
            if (-not $Immediately -and $StartTime) { $candidate = Get-NextRebootTimeInWindow -StartTime $StartTime -LatestTime $LatestTime -NotBefore $candidate }
        } while ($true)
        if ($slots.Count -ge 4096) { throw 'Zu viele VM-Neustartreservierungen; Planung manuell prüfen.' }
        $slots += [pscustomobject]@{Target=$Target;At=$candidate.ToString('o');IntervalMinutes=$interval}
        $temporary = $StatePath+'.tmp'
        ConvertTo-Json -InputObject @($slots) -Depth 4 | Set-Content -LiteralPath $temporary -Encoding UTF8
        if (Test-Path -LiteralPath $StatePath) { [IO.File]::Replace($temporary,$StatePath,[Management.Automation.Language.NullString]::Value) } else { [IO.File]::Move($temporary,$StatePath) }
        return $candidate
    } finally { if ($lock) { $lock.Dispose() } }
}