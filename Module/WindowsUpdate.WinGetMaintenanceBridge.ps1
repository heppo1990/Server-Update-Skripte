param([Parameter(Mandatory)][ValidateSet('SourceList','SourceUpdate','SourceReset','ClientRepair')][string]$Action)
$ErrorActionPreference = 'Stop'
$worker = Join-Path $PSScriptRoot 'WinGetMaintenance.ps1'
$staging = Join-Path $PSScriptRoot ('WinGetMaintenance-' + [guid]::NewGuid().ToString('N') + '.tmp')
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    # Feste vertrauenswürdige Quelle. Der JEA-Aufrufer kann keinen Code oder Pfad übergeben.
    $response = Invoke-RestMethod -Uri 'https://api.github.com/repos/heppo1990/Server-Update-Skripte/contents/Module/WindowsUpdate.WinGetMaintenance.ps1?ref=main' -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
    if ($response.type -ne 'file' -or $response.encoding -ne 'base64' -or $response.path -ne 'Module/WindowsUpdate.WinGetMaintenance.ps1') { throw 'Unerwartete GitHub-Antwort.' }
    $bytes = [Convert]::FromBase64String($response.content)
    if ($bytes.Length -eq 0 -or $bytes.Length -gt 1048576) { throw 'Ungültige Größe des Wartungsworkers.' }
    $sha = [Security.Cryptography.SHA1]::Create()
    try {
        $prefix = [Text.Encoding]::UTF8.GetBytes(('blob ' + $bytes.Length + [char]0))
        $blob = New-Object byte[] ($prefix.Length + $bytes.Length)
        [Array]::Copy($prefix, 0, $blob, 0, $prefix.Length)
        [Array]::Copy($bytes, 0, $blob, $prefix.Length, $bytes.Length)
        $hash = [BitConverter]::ToString($sha.ComputeHash($blob)).Replace('-','')
    } finally { $sha.Dispose() }
    if ($hash -ine [string]$response.sha) { throw 'GitHub-Blob-Prüfsumme stimmt nicht.' }
    $tokens = $null; $errors = $null
    [Management.Automation.Language.Parser]::ParseInput([Text.Encoding]::UTF8.GetString($bytes), [ref]$tokens, [ref]$errors) | Out-Null
    if ($errors.Count -gt 0) { throw 'Neuer Wartungsworker enthält Syntaxfehler.' }
    [IO.File]::WriteAllBytes($staging, $bytes)
    if (Test-Path -LiteralPath $worker) {
        if ((Get-FileHash -LiteralPath $worker -Algorithm SHA256).Hash -ne (Get-FileHash -LiteralPath $staging -Algorithm SHA256).Hash) {
            [IO.File]::Replace($staging, $worker, [System.Management.Automation.Language.NullString]::Value)
        }
    } else { [IO.File]::Move($staging, $worker) }
} catch {
    if (-not (Test-Path -LiteralPath $worker -PathType Leaf)) { throw }
    Write-Output "Online-Wartungsupdate nicht verfügbar; vorhandener Worker wird verwendet: $($_.Exception.Message)"
} finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
& (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $worker -Action $Action
exit $LASTEXITCODE
