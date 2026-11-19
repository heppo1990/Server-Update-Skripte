function Get-WindowsUpdateParallelTargetLimit {
    param([Parameter(Mandatory)][object]$Configuration)
    if ($Configuration.PSObject.Properties['ParallelTargets']) {
        return [Math]::Max(1,[Math]::Min(16,[int]$Configuration.ParallelTargets))
    }
    return 3
}

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
    # Die Plattformplanung übergibt genau eine VM-/Physisch-Phase.
    # Auch der Verwaltungsserver bleibt in seiner Phase; nur sein Neustart wartet.
    $batches = @(,@($Targets))
    try {
        $contextPath = Join-Path $root 'context.xml'
        $Context | Export-Clixml -LiteralPath $contextPath -Depth 12
        $bootstrapPath = Join-Path $root 'Start-TargetWorker.ps1'
        $bootstrap = @'
param([Parameter(Mandatory)][string]$ConfigPath)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$PSModuleAutoLoadingPreference = 'All'
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
# Ein von PS7 geerbter Modulpfad ist kein vollständiger PS5-Modulpfad.
$documents = [Environment]::GetFolderPath('MyDocuments')
if ([string]::IsNullOrWhiteSpace($documents)) { $documents = Join-Path $env:USERPROFILE 'Documents' }
$nativeRoots = @(
    (Join-Path $documents 'WindowsPowerShell\Modules'),
    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
    (Join-Path $PSHOME 'Modules')
)
if (${env:ProgramFiles(x86)}) { $nativeRoots += Join-Path ${env:ProgramFiles(x86)} 'WindowsPowerShell\Modules' }
$coreRoots = @((Join-Path $documents 'PowerShell\Modules'),(Join-Path $env:ProgramFiles 'PowerShell\Modules'))
$customRoots = @($env:PSModulePath -split ';' | Where-Object { $_ -and $coreRoots -notcontains $_.TrimEnd('\','/') -and $_ -notmatch '(?i)[\\/]PowerShell[\\/]7(?:[.\-][^\\/]*)?[\\/]Modules(?:[\\/]|$)' })
$env:PSModulePath = (@($nativeRoots + $customRoots) | Where-Object { Test-Path -LiteralPath $_ -PathType Container } | Select-Object -Unique) -join ';'
try {
    $configuration = Import-Clixml -LiteralPath $ConfigPath
    $parameters = $configuration.Parameters
    $global:LASTEXITCODE = 0
    # -File und Textausgabe vermeiden CLIXML für Write-Host/Information/Error.
    & $configuration.ScriptPath @parameters *>&1 | ForEach-Object {
        if ($_ -is [Management.Automation.ErrorRecord]) { [Console]::Error.WriteLine(($_ | Out-String -Width 400)) }
        else { [Console]::WriteLine([string]$_) }
    }
    exit $global:LASTEXITCODE
} catch {
    [Console]::Error.WriteLine(($_ | Out-String -Width 400))
    exit 1
}
'@
        [IO.File]::WriteAllText($bootstrapPath,$bootstrap,[Text.UTF8Encoding]::new($true))
        foreach ($batch in $batches) {
            $queue = [Collections.Generic.Queue[object]]::new()
            foreach ($target in $batch) { $queue.Enqueue($target) }
            while ($queue.Count -gt 0 -or $pending.Count -gt 0) {
                while ($queue.Count -gt 0 -and $pending.Count -lt $ThrottleLimit) {
                    $target = $queue.Dequeue()
                    $id = [guid]::NewGuid().ToString('N')
                    $resultPath = Join-Path $root ($id+'.result.xml')
                    $configuration = @{ScriptPath=$ScriptPath;Parameters=@{ParallelTarget=[string]$target.Name;ParallelResultPath=$resultPath;ParallelContextPath=$contextPath;ParallelLogPath=(Join-Path $root ($id+'.worker.log'))}}
                    $configPath = Join-Path $root ($id+'.config.xml')
                    $configuration | Export-Clixml -LiteralPath $configPath -Depth 8
                    $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -ConfigPath "{1}"' -f $bootstrapPath,$configPath
                    $stdout = Join-Path $root ($id+'.stdout'); $stderr = Join-Path $root ($id+'.stderr')
                    $process = Start-Process -FilePath (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe') -ArgumentList $arguments -WindowStyle Hidden -PassThru -RedirectStandardOutput $stdout -RedirectStandardError $stderr
                    # Prozesshandle vor dem Ende öffnen, damit ExitCode unter PS5 erhalten bleibt.
                    $null = $process.Handle
                    $pending.Add([pscustomobject]@{Target=[string]$target.Name;Process=$process;Result=$resultPath;LogFile=$configuration.Parameters.ParallelLogPath;Stdout=$stdout;Stderr=$stderr;Started=[datetime]::UtcNow})
                    if ($WriteLog) { & $WriteLog "[$($target.Name)] Zielablauf gestartet (maximal $ThrottleLimit gleichzeitig)." $true }
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
                                if ($targetOutputStarted -and -not [string]::IsNullOrWhiteSpace($line)) { & $WriteLog $line ($outputFile -eq $item.Stderr) }
                            }
                        }
                    }
                    if ($WriteLog -and (Test-Path -LiteralPath $item.LogFile -PathType Leaf)) {
                        foreach ($line in @(Get-Content -LiteralPath $item.LogFile -Encoding UTF8)) { & $WriteLog "[$($item.Target)] $line" $true }
                    }
                    if ($item.Process.ExitCode -ne 0 -or -not (Test-Path -LiteralPath $item.Result)) {
                        $failure = "FEHLER: Zielablauf auf $($item.Target) fehlgeschlagen (Exitcode $($item.Process.ExitCode)); kein vollständiges Ergebnis. Kein automatischer Wiederholungsversuch."
                        if ($WriteLog) { & $WriteLog $failure }
                        $answers.Add([pscustomobject]@{Target=$item.Target;Html=('<div class="error-box">'+[Net.WebUtility]::HtmlEncode($failure)+'</div>');Data=@{ErrorCount=1;ManualActions=@([pscustomobject]@{Server=$item.Target;Manager='Zielablauf';Packages=@();Text=$failure})}})
                        $item.Process.Dispose(); [void]$pending.Remove($item)
                        continue
                    }
                    $answer = Import-Clixml -LiteralPath $item.Result
                    if ($answer.Target -ne $item.Target) { throw 'Worker-Ergebnis gehört zu einem anderen Ziel.' }
                    $answers.Add($answer)
                    if ($WriteLog) { & $WriteLog "[$($item.Target)] Zielablauf abgeschlossen." $true }
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
