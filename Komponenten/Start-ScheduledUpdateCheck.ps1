# Die Aufgabe startet diesen Helfer immer mit Windows PowerShell 5.1.
$ErrorActionPreference = 'Stop'
$scriptRoot = Split-Path -Parent $PSScriptRoot
$checkScript = Join-Path $scriptRoot 'Check-ServersUpdates.ps1'
if (-not (Test-Path -LiteralPath $checkScript -PathType Leaf)) { throw "Check-Skript fehlt: $checkScript" }

function Write-LauncherLog {
    param([string]$Message)
    $line = '[{0}] {1}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    Write-Output $line
    try {
        $logRoot = Join-Path $scriptRoot 'Logs'
        [void][IO.Directory]::CreateDirectory($logRoot)
        $logPath = Join-Path $logRoot 'ScheduledCheck-Launcher.log'
        if ((Test-Path -LiteralPath $logPath) -and (Get-Item -LiteralPath $logPath).Length -gt 1MB) {
            Move-Item -LiteralPath $logPath -Destination "$logPath.bak" -Force
        }
        Add-Content -LiteralPath $logPath -Value $line -Encoding UTF8
    } catch { Write-Warning "Startprotokoll konnte nicht geschrieben werden: $($_.Exception.Message)" }
}

$candidates = @(
    (Join-Path $env:ProgramFiles 'PowerShell\7\pwsh.exe'),
    (Join-Path $env:ProgramFiles 'PowerShell\7-preview\pwsh.exe'),
    (Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe')
)
foreach ($executable in $candidates) {
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { continue }
    $probe = $null
    try {
        $info = New-Object Diagnostics.ProcessStartInfo
        $info.FileName = $executable
        $info.Arguments = '-NoLogo -NoProfile -NonInteractive -Command "exit 0"'
        $info.UseShellExecute = $false
        $info.CreateNoWindow = $true
        $probe = [Diagnostics.Process]::Start($info)
        if (-not $probe.WaitForExit(15000)) {
            $probe.Kill()
            throw 'Interpreter-Starttest nach 15 Sekunden abgebrochen.'
        }
        if ($probe.ExitCode -ne 0) { throw "Interpreter-Starttest: Exitcode $($probe.ExitCode)." }
        $info.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $checkScript
        $info.WorkingDirectory = $scriptRoot
        $child = [Diagnostics.Process]::Start($info)
    } catch {
        Write-LauncherLog "Interpreter nicht startbar: $executable; $($_.Exception.Message) Nächsten Interpreter prüfen."
        continue
    } finally {
        if ($probe) { $probe.Dispose() }
    }
    # Sobald der Check gestartet wurde, niemals denselben Lauf nochmals ausführen.
    Write-LauncherLog "Check gestartet mit $executable"
    try {
        $child.WaitForExit()
        $result = $child.ExitCode
    } finally { $child.Dispose() }
    Write-LauncherLog "Check beendet; Exitcode $result."
    exit $result
}
throw 'Kein startbarer PowerShell-Interpreter für die Check-Aufgabe gefunden.'
