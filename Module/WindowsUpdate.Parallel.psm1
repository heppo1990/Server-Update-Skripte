# Vollständige Windows-Zielabläufe in getrennten PS5-Prozessen. Nur der
# Elternlauf schreibt Gesamtbericht/Mail und plant physische Neustarts.
function Invoke-WindowsUpdateTargetBatch {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$ScriptPath, [Parameter(Mandatory)][object[]]$Targets,
        [ValidateRange(1,16)][int]$ThrottleLimit = 3, [hashtable]$Context = @{}, [scriptblock]$WriteLog,
        [ValidateRange(60,259200)][int]$TimeoutSeconds = 259200)
    $root = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdateBatch-'+[guid]::NewGuid().ToString('N'))
    [void][IO.Directory]::CreateDirectory($root)
    $pending = [Collections.Generic.List[object]]::new()
    $answers = [Collections.Generic.List[object]]::new()
    # Der Verwaltungsserver läuft zuletzt, damit dessen Updates die übrigen
    # Worker nicht unterbrechen. Seine Neustartanforderung bleibt im Elternlauf.
    $localNames = @($env:COMPUTERNAME,[Net.Dns]::GetHostName())
    if ($env:USERDNSDOMAIN) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    $batches = @(@($Targets | Where-Object { $localNames -notcontains $_.Name }), @($Targets | Where-Object { $localNames -contains $_.Name }))
    try {
        $contextPath = Join-Path $root 'context.xml'
        $Context | Export-Clixml -LiteralPath $contextPath -Depth 12
        foreach ($batch in $batches) {
            $queue = [Collections.Generic.Queue[object]]::new()
            foreach ($target in $batch) { $queue.Enqueue($target) }
            while ($queue.Count -gt 0 -or $pending.Count -gt 0) {
                while ($queue.Count -gt 0 -and $pending.Count -lt $ThrottleLimit) {
                    $target = $queue.Dequeue()
                    $id = [guid]::NewGuid().ToString('N')
                    $resultPath = Join-Path $root ($id+'.result.xml')
                    $configuration = @{ScriptPath=$ScriptPath;Parameters=@{ParallelTarget=[string]$target.Name;ParallelResultPath=$resultPath;ParallelContextPath=$contextPath}}
                    $configPath = Join-Path $root ($id+'.config.xml')
                    $configuration | Export-Clixml -LiteralPath $configPath -Depth 8
                    $command = '$ProgressPreference=''SilentlyContinue''; [Console]::OutputEncoding=[Text.UTF8Encoding]::new($false); $c=Import-Clixml -LiteralPath ''' + $configPath.Replace("'","''") + '''; $p=$c.Parameters; & $c.ScriptPath @p'
                    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -OutputFormat Text -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
                    $stdout = Join-Path $root ($id+'.stdout'); $stderr = Join-Path $root ($id+'.stderr')
                    $process = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                    # Prozesshandle vor dem Ende öffnen, damit ExitCode unter PS5 erhalten bleibt.
                    $null = $process.Handle
                    $pending.Add([pscustomobject]@{Target=[string]$target.Name;Process=$process;Result=$resultPath;Stdout=$stdout;Stderr=$stderr;Started=[datetime]::UtcNow})
                    if ($WriteLog) { & $WriteLog "[$($target.Name)] Zielablauf gestartet (maximal $ThrottleLimit gleichzeitig)." }
                }
                foreach ($item in @($pending.ToArray())) {
                    if (-not $item.Process.HasExited) {
                        if (([datetime]::UtcNow-$item.Started).TotalSeconds -gt $TimeoutSeconds) { $item.Process.Kill(); throw "Zielablauf '$($item.Target)' überschritt das Zeitlimit; nicht automatisch erneut starten." }
                        continue
                    }
                    $item.Process.WaitForExit()
                    foreach ($outputFile in @($item.Stdout,$item.Stderr)) {
                        if ($WriteLog -and (Test-Path -LiteralPath $outputFile)) {
                            $targetOutputStarted = $outputFile -eq $item.Stderr
                            foreach ($line in @(Get-Content -LiteralPath $outputFile -Encoding UTF8)) {
                                if ($line -match 'Starte Update-(Check|Download|Installation)') { $targetOutputStarted = $true }
                                if ($targetOutputStarted -and -not [string]::IsNullOrWhiteSpace($line)) { & $WriteLog "[$($item.Target)] $line" }
                            }
                        }
                    }
                    if ($item.Process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $item.Result)) {
                        $failure = "Zielablauf '$($item.Target)' lieferte kein vollständiges Ergebnis (Exitcode $($item.Process.ExitCode)). Kein automatischer Wiederholungsversuch."
                        if ($WriteLog) { & $WriteLog $failure }
                        $answers.Add([pscustomobject]@{Target=$item.Target;Html=('<div class="error-box">'+[Net.WebUtility]::HtmlEncode($failure)+'</div>');Data=@{ErrorCount=1;ManualActions=@([pscustomobject]@{Server=$item.Target;Manager='Zielablauf';Packages=@();Text=$failure})}})
                        $item.Process.Dispose(); [void]$pending.Remove($item)
                        continue
                    }
                    $answer = Import-Clixml -LiteralPath $item.Result
                    if ($answer.Target -ne $item.Target) { throw 'Worker-Ergebnis gehört zu einem anderen Ziel.' }
                    if ($WriteLog -and $answer.PSObject.Properties['LogFile'] -and $answer.LogFile -and (Test-Path -LiteralPath $answer.LogFile -PathType Leaf)) {
                        foreach ($line in @(Get-Content -LiteralPath $answer.LogFile -Encoding UTF8)) { & $WriteLog "[$($item.Target)] $line" $true }
                    }
                    $answers.Add($answer)
                    if ($WriteLog) { & $WriteLog "[$($item.Target)] Zielablauf abgeschlossen." }
                    $item.Process.Dispose(); [void]$pending.Remove($item)
                }
                if ($pending.Count) { Start-Sleep -Milliseconds 250 }
            }
        }
        return $answers.ToArray()
    } finally {
        foreach ($item in $pending) { try { if (-not $item.Process.HasExited) { $item.Process.Kill() } } finally { $item.Process.Dispose() } }
        $resolved = [IO.Path]::GetFullPath($root)
        if ($resolved.StartsWith([IO.Path]::GetTempPath(),[StringComparison]::OrdinalIgnoreCase) -and (Split-Path -Leaf $resolved) -like 'WindowsUpdateBatch-*') { Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue }
    }
}