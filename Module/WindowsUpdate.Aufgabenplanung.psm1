function Set-WindowsUpdateScheduledCheckTask {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][object]$Configuration,
        [scriptblock]$WriteLog
    )

    $taskName = 'Check-ServersUpdates'
    $taskPath = '\'
    $ownershipMarker = 'WindowsUpdateAdm: Scheduled Check-ServersUpdates task managed by Verteilung_WindowsUpdateAdmConfig.'
    $checkScript = Join-Path $ScriptRoot 'Check-ServersUpdates.ps1'
    if (-not (Test-Path -LiteralPath $checkScript -PathType Leaf)) {
        throw "Check-Skript für die Aufgabenplanung fehlt: $checkScript"
    }

    $existingTask = Get-ScheduledTask -TaskName $taskName -TaskPath $taskPath -ErrorAction SilentlyContinue
    if (-not [bool]$Configuration.Enabled) {
        if ($existingTask -and [string]$existingTask.Description -like "$ownershipMarker*") {
            Unregister-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Confirm:$false -ErrorAction Stop
            if ($WriteLog) { & $WriteLog 'Verwaltete Check-Aufgabe wegen ScheduledCheck.Enabled=false entfernt.' }
            return [pscustomobject]@{ State = 'Removed'; TaskName = $taskName }
        }
        if ($existingTask) {
            if ($WriteLog) { & $WriteLog 'Geplanter Check ist deaktiviert; vorhandene, nicht von der Verteilung verwaltete Aufgabe blieb unverändert.' }
            return [pscustomobject]@{ State = 'Unchanged'; TaskName = $taskName }
        }
        if ($WriteLog) { & $WriteLog 'Geplanter Check ist deaktiviert; es wurde keine Aufgabe angelegt.' }
        return [pscustomobject]@{ State = 'Disabled'; TaskName = $taskName }
    }

    $frequency = [string]$Configuration.Frequency
    if ($frequency -notin @('Daily', 'Weekly')) {
        throw "ScheduledCheck.Frequency muss 'Daily' oder 'Weekly' sein; erhalten: '$frequency'."
    }
    $interval = 1
    if ($null -ne $Configuration.PSObject.Properties['Interval']) {
        $interval = [int]$Configuration.Interval
    }
    $maxInterval = if ($frequency -eq 'Weekly') { 52 } else { 365 }
    if ($interval -lt 1 -or $interval -gt $maxInterval) {
        throw "ScheduledCheck.Interval muss bei $frequency zwischen 1 und $maxInterval liegen."
    }
    $timeText = [string]$Configuration.Time
    if ($timeText -notmatch '^(?:[01]\d|2[0-3]):[0-5]\d$') {
        throw "ScheduledCheck.Time muss im Format HH:mm angegeben werden; erhalten: '$timeText'."
    }
    $runAt = [datetime]::Today.Add([TimeSpan]::ParseExact($timeText, 'hh\:mm', [Globalization.CultureInfo]::InvariantCulture))
    $trigger = if ($frequency -eq 'Daily') {
        New-ScheduledTaskTrigger -Daily -DaysInterval $interval -At $runAt
    }
    else {
        $configuredDays = @($Configuration.DaysOfWeek | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($configuredDays.Count -eq 0) { throw 'ScheduledCheck.DaysOfWeek muss für eine wöchentliche Aufgabe mindestens einen Wochentag enthalten.' }
        $days = @(
            foreach ($day in $configuredDays) {
                $dayName = [enum]::GetNames([System.DayOfWeek]) |
                    Where-Object { [string]::Equals($_, [string]$day, [StringComparison]::OrdinalIgnoreCase) } |
                    Select-Object -First 1
                if (-not $dayName) {
                    throw "Unbekannter Wochentag '$day' in ScheduledCheck.DaysOfWeek. Zulässig: $([enum]::GetNames([System.DayOfWeek]) -join ', ')."
                }
                [System.DayOfWeek]([System.Enum]::Parse([System.DayOfWeek], $dayName, $false))
            }
        ) | Select-Object -Unique
        New-ScheduledTaskTrigger -Weekly -WeeksInterval $interval -DaysOfWeek $days -At $runAt
    }

    if ($existingTask) {
        $taskAction = @($existingTask.Actions | Where-Object { $_.CimClass.CimClassName -eq 'MSFT_TaskExecAction' }) | Select-Object -First 1
        $actionPath = if ($taskAction) { ([string]$taskAction.Execute).Trim('"') } else { '' }
        $actionArguments = if ($taskAction) { [string]$taskAction.Arguments } else { '' }
        $actionMatches = $actionArguments.IndexOf($checkScript, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $runsAsSystem = ([string]$existingTask.Principal.UserId -match '^(?:SYSTEM|NT AUTHORITY\\SYSTEM|S-1-5-18)$') -and
            [string]$existingTask.Principal.LogonType -eq 'ServiceAccount'
        if (-not $actionMatches -or -not $runsAsSystem) {
            throw "Die Aufgabe '$taskPath$taskName' ist bereits vorhanden, startet aber nicht dieses Check-Skript als SYSTEM. Sie wurde nicht verändert."
        }
    }

    $powerShellExecutable = $null
    $candidatePaths = @(
        (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
        (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe')
    )
    foreach ($candidatePath in $candidatePaths) {
        if (Test-Path -LiteralPath $candidatePath -PathType Leaf) {
            $powerShellExecutable = $candidatePath
            break
        }
    }
    if (-not $powerShellExecutable) {
        $powerShellExecutable = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    }
    if (-not (Test-Path -LiteralPath $powerShellExecutable -PathType Leaf)) {
        throw 'Weder PowerShell 7 noch Windows PowerShell 5.1 wurde für die Check-Aufgabe gefunden.'
    }

    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $checkScript
    $action = New-ScheduledTaskAction -Execute $powerShellExecutable -Argument $arguments -WorkingDirectory $ScriptRoot
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $startWhenAvailable = [bool]$Configuration.StartWhenAvailable
    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 72) -MultipleInstances IgnoreNew -StartWhenAvailable:$startWhenAvailable
    Register-ScheduledTask -TaskName $taskName -TaskPath $taskPath -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings -Description $ownershipMarker -Force -ErrorAction Stop | Out-Null

    $scheduleDescription = if ($frequency -eq 'Weekly') {
        "alle $interval Woche(n), $(@($days | ForEach-Object { [string]$_ }) -join ', ') um $timeText"
    } else {
        "alle $interval Tag(e) um $timeText"
    }
    if ($WriteLog) { & $WriteLog "Geplante Check-Aufgabe '$taskName' als SYSTEM eingerichtet: $scheduleDescription; Interpreter=$powerShellExecutable; Nachholen verpasster Läufe=$startWhenAvailable." }
    return [pscustomobject]@{ State = 'Registered'; TaskName = $taskName; Executable = $powerShellExecutable; Schedule = $scheduleDescription }
}
