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
    while ($scheduled -lt $NotBefore) { $scheduled = $scheduled.AddDays(1) }
    return $scheduled
  }

  $latestParsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($LatestTime, [ref]$latestParsed)) {
    throw "Ungültige späteste Neustartzeit '$LatestTime'. Erwartet wird z. B. 23:00."
  }
  $latest = $start.Date.Add($latestParsed.TimeOfDay)
  if ($latest -lt $start) { $latest = $latest.AddDays(1) }
  $scheduled = $start.AddMinutes($DelayMinutes)
  while ($scheduled -gt $latest -or $scheduled -lt $NotBefore) {
    $start = $start.AddDays(1)
    $latest = $latest.AddDays(1)
    $scheduled = $start.AddMinutes($DelayMinutes)
    if ($scheduled -gt $latest) {
      throw "Der Neustartversatz von $DelayMinutes Minute(n) liegt außerhalb des konfigurierten Wartungsfensters."
    }
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
    $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog $writeLogForRemoting
    if ($isLocal -and -not $jeaSupported) {
        throw "WindowsUpdateAdm/JEA ist auf dem Verwaltungsserver $Servername nicht verfügbar; der Virtualisierungsstatus wird nicht direkt lokal abgefragt."
    }
    $configurationName = if ($jeaSupported) { 'WindowsUpdateAdm' } else { $null }
    $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo -ConfigurationName $configurationName
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
