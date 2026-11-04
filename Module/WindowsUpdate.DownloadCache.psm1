# Gemeinsamer PS5-kompatibler Downloadcache. Keine Versionswerte fest hinterlegen.
function Invoke-WindowsUpdateCachedDownload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri]$Uri,
        [string]$CacheRoot = (Join-Path $env:ProgramData 'WindowsUpdateAdm\DownloadCache'),
        [string]$DestinationPath,
        [long]$ExpectedBytes = 0,
        [string]$ExpectedSha256 = '',
        [ValidateRange(1,3600)][int]$IdleTimeoutSeconds = 120,
        [ValidateRange(1,86400)][int]$MaximumSeconds = 3600,
        [long]$MaximumBytes = 1073741824,
        [switch]$AllowHttpForTest,
        [scriptblock]$WriteLog
    )
    $ErrorActionPreference = 'Stop'
    if ($Uri.Scheme -ne 'https' -and -not ($AllowHttpForTest -and $Uri.IsLoopback -and $Uri.Scheme -eq 'http')) { throw 'Download erfordert HTTPS.' }
    if ($ExpectedBytes -lt 0 -or $MaximumBytes -lt 1 -or $ExpectedBytes -gt $MaximumBytes) { throw 'Ungültige erwartete Downloadgröße.' }
    if ($ExpectedSha256 -and $ExpectedSha256 -notmatch '^[a-fA-F0-9]{64}$') { throw 'Ungültige SHA256-Prüfsumme.' }
    $emit = {
        param($message)
        $line = '[{0:yyyy-MM-dd HH:mm:ss}] {1}' -f (Get-Date),$message
        $progressPath = Join-Path $folder 'progress.log'
        if ((Test-Path -LiteralPath $progressPath) -and (Get-Item -LiteralPath $progressPath).Length -gt 1048576) { Move-Item -LiteralPath $progressPath -Destination ($progressPath + '.1') -Force }
        Add-Content -LiteralPath $progressPath -Value $line -Encoding UTF8
        if ($WriteLog) { & $WriteLog $line | Out-Null } else { Write-Verbose $line }
    }
    New-Item -ItemType Directory -Path $CacheRoot -Force | Out-Null
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Uri.AbsoluteUri))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $folder = Join-Path $CacheRoot $key
    New-Item -ItemType Directory -Path $folder -Force | Out-Null
    $file = Join-Path $folder 'payload.bin'
    $metadata = Join-Path $folder 'payload.json'
    $partial = Join-Path $folder 'payload.part'
    $lock = $null; $client = $null; $response = $null; $inputStream = $null; $outputStream = $null
    $timer = [Diagnostics.Stopwatch]::StartNew()
    try {
        # FileShare.None verhindert parallele Downloads desselben Artefakts.
        while (-not $lock) {
            try { $lock = [IO.File]::Open((Join-Path $folder 'download.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
            catch [IO.IOException] {
                if ($timer.Elapsed.TotalSeconds -ge $IdleTimeoutSeconds) { throw 'Downloadcache ist durch einen anderen Lauf belegt.' }
                Start-Sleep -Milliseconds 250
            }
        }
        if ((Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath $metadata)) {
            try {
                $saved = [IO.File]::ReadAllText($metadata) | ConvertFrom-Json
                $length = (Get-Item -LiteralPath $file).Length
                $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash
                if ($length -gt 0 -and $length -eq [long]$saved.Bytes -and $length -le $MaximumBytes -and
                    ($ExpectedBytes -eq 0 -or $length -eq $ExpectedBytes) -and $hash -eq [string]$saved.Sha256 -and
                    (-not $ExpectedSha256 -or $hash -eq $ExpectedSha256)) {
                    & $emit "Downloadcache gültig: $length Bytes; kein Download."
                    if ($DestinationPath) { Copy-Item -LiteralPath $file -Destination $DestinationPath -Force }
                    return [pscustomobject]@{Path=$file;Bytes=$length;Sha256=$hash;Cached=$true;Seconds=$timer.Elapsed.TotalSeconds}
                }
            } catch { & $emit 'Cacheprüfung fehlgeschlagen; Datei wird erneut beschafft.' }
        }
        Add-Type -AssemblyName System.Net.Http
        $handler = [Net.Http.HttpClientHandler]::new()
        $handler.AutomaticDecompression = [Net.DecompressionMethods]::None
        $client = [Net.Http.HttpClient]::new($handler)
        $client.Timeout = [Threading.Timeout]::InfiniteTimeSpan
        $client.DefaultRequestHeaders.UserAgent.ParseAdd('Server-Update-Skripte')
        & $emit 'Download beginnt; HTTP-Kopfzeilen werden angefordert.'
        $request = $client.GetAsync($Uri,[Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        while (-not $request.Wait(250)) {
            if ($timer.Elapsed.TotalSeconds -ge [Math]::Min($IdleTimeoutSeconds,$MaximumSeconds)) { $client.CancelPendingRequests(); throw 'Zeitlimit beim Verbindungsaufbau.' }
        }
        $response = $request.GetAwaiter().GetResult()
        [void]$response.EnsureSuccessStatusCode()
        $finalUri = $response.RequestMessage.RequestUri
        if ($finalUri.Scheme -ne 'https' -and -not ($AllowHttpForTest -and $finalUri.IsLoopback -and $finalUri.Scheme -eq 'http')) { throw 'Downloadweiterleitung auf unverschlüsselte Verbindung abgelehnt.' }
        $httpBytes = if ($null -ne $response.Content.Headers.ContentLength) { [long]$response.Content.Headers.ContentLength } else { 0 }
        if ($httpBytes -gt $MaximumBytes -or ($ExpectedBytes -gt 0 -and $httpBytes -gt 0 -and $httpBytes -ne $ExpectedBytes)) { throw 'HTTP-Dateigröße stimmt nicht mit der erlaubten Größe überein.' }
        $total = if ($ExpectedBytes -gt 0) { $ExpectedBytes } else { $httpBytes }
        & $emit "HTTP-Antwort empfangen; erwartete Größe: $total Bytes (0 = unbekannt)."
        $inputStream = $response.Content.ReadAsStreamAsync().GetAwaiter().GetResult()
        $outputStream = [IO.File]::Open($partial,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::Read)
        $buffer = New-Object byte[] 131072
        $received = [long]0; $lastData = $timer.Elapsed.TotalSeconds; $lastLog = $lastData; $lastBytes = [long]0
        while ($true) {
            $read = $inputStream.ReadAsync($buffer,0,$buffer.Length)
            while (-not $read.Wait(250)) {
                if ($timer.Elapsed.TotalSeconds - $lastData -ge $IdleTimeoutSeconds) { throw "Downloadstillstand: $IdleTimeoutSeconds Sekunden ohne neue Daten; empfangen: $received Bytes." }
                if ($timer.Elapsed.TotalSeconds -ge $MaximumSeconds) { throw "Absolutes Downloadzeitlimit erreicht; empfangen: $received Bytes." }
            }
            $count = $read.GetAwaiter().GetResult()
            if ($count -eq 0) { break }
            $received += $count
            if ($received -gt $MaximumBytes -or ($total -gt 0 -and $received -gt $total)) { throw "Download überschreitet erlaubte Größe: $received Bytes." }
            $outputStream.Write($buffer,0,$count)
            $lastData = $timer.Elapsed.TotalSeconds
            if ($lastData -ge $MaximumSeconds) { throw "Absolutes Downloadzeitlimit erreicht; empfangen: $received Bytes." }
            if ($lastData - $lastLog -ge 10) {
                $speed = [Math]::Round(($received - $lastBytes) / ($lastData - $lastLog) / 1048576,2)
                & $emit "Download: $received / $total Bytes; $speed MiB/s; Laufzeit $([int]$lastData)s."
                $lastLog=$lastData; $lastBytes=$received
            }
        }
        $outputStream.Dispose(); $outputStream=$null
        if ($received -eq 0 -or ($total -gt 0 -and $received -ne $total)) { throw "Download unvollständig: $received / $total Bytes." }
        & $emit "Download beendet: $received Bytes; SHA256-Prüfung beginnt."
        $hash = (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash
        if ($ExpectedSha256 -and $hash -ne $ExpectedSha256) { throw 'Download-Prüfsumme stimmt nicht.' }
        if (Test-Path -LiteralPath $file) { [IO.File]::Replace($partial,$file,[Management.Automation.Language.NullString]::Value) }
        else { [IO.File]::Move($partial,$file) }
        @{Bytes=$received;Sha256=$hash;CompletedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $metadata -Encoding UTF8
        & $emit "Downloadcache übernommen; Dauer $([int]$timer.Elapsed.TotalSeconds)s."
        if ($DestinationPath) { Copy-Item -LiteralPath $file -Destination $DestinationPath -Force }
        return [pscustomobject]@{Path=$file;Bytes=$received;Sha256=$hash;Cached=$false;Seconds=$timer.Elapsed.TotalSeconds}
    } finally {
        if ($outputStream) { $outputStream.Dispose() }
        if ($inputStream) { $inputStream.Dispose() }
        if ($response) { $response.Dispose() }
        if ($client) { $client.Dispose() }
        if ($lock) { $lock.Dispose() }
        $timer.Stop()
    }
}

function Get-WindowsUpdateWinGetCachedArtifacts {
    [CmdletBinding()]
    param([scriptblock]$WriteLog)
    if ((Get-Variable -Name WinGetCachedArtifactsForRun -Scope Script -ErrorAction SilentlyContinue) -and
        (Get-Variable -Name WinGetCachedArtifactsCheckedUtc -Scope Script -ErrorAction SilentlyContinue) -and
        ([DateTime]::UtcNow - $script:WinGetCachedArtifactsCheckedUtc).TotalMinutes -lt 15) {
        $valid = $true
        foreach ($item in $script:WinGetCachedArtifactsForRun) {
            if (-not (Test-Path -LiteralPath $item.Path) -or (Get-Item -LiteralPath $item.Path).Length -ne $item.Bytes -or (Get-FileHash -LiteralPath $item.Path -Algorithm SHA256).Hash -ne $item.Sha256) { $valid = $false; break }
        }
        if ($valid) { return $script:WinGetCachedArtifactsForRun }
    }
    $releaseIndex = Join-Path $env:ProgramData 'WindowsUpdateAdm\DownloadCache\winget-release.json'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try {
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{'User-Agent'='Server-Update-Skripte'} -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    } catch {
        try {
        $latest = Invoke-WebRequest -Uri 'https://github.com/microsoft/winget-cli/releases/latest' -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $uri = if ($latest.BaseResponse.PSObject.Properties['ResponseUri']) { [uri]$latest.BaseResponse.ResponseUri } else { [uri]$latest.BaseResponse.RequestMessage.RequestUri }
        if ($uri.Host -ne 'github.com' -or $uri.AbsolutePath -notmatch '^/microsoft/winget-cli/releases/tag/(v[0-9][A-Za-z0-9._-]*)$') { throw 'Unerwartete WinGet-Releaseweiterleitung.' }
        $tag = $Matches[1]
        $release = [pscustomobject]@{tag_name=$tag;assets=@(
            foreach ($name in @('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle','DesktopAppInstaller_Dependencies.zip')) {
                [pscustomobject]@{name=$name;size=0;digest='';browser_download_url="https://github.com/microsoft/winget-cli/releases/download/$tag/$name"}
            }
        )}
        } catch {
            if (-not (Test-Path -LiteralPath $releaseIndex)) { throw }
            $release = [IO.File]::ReadAllText($releaseIndex) | ConvertFrom-Json
            if ($WriteLog) { & $WriteLog ('[{0:yyyy-MM-dd HH:mm:ss}] Onlineabgleich nicht verfügbar; gespeicherte Release-Metadaten und geprüfte Archive verwenden.' -f (Get-Date)) | Out-Null }
        }
    }
    if ([string]$release.tag_name -notmatch '^v[0-9][A-Za-z0-9._-]*$') { throw 'Ungültige gespeicherte WinGet-Version.' }
    $artifacts = @(
        foreach ($name in @('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle','DesktopAppInstaller_Dependencies.zip')) {
            $asset = @($release.assets | Where-Object name -eq $name)
            if ($asset.Count -ne 1) { throw "WinGet-Release enthält nicht genau ein Asset '$name'." }
            $uri = [uri]$asset[0].browser_download_url
            if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -notlike '/microsoft/winget-cli/releases/download/*') { throw 'Unerwartete WinGet-Assetadresse.' }
            $download = Invoke-WindowsUpdateCachedDownload -Uri $uri -ExpectedBytes ([long]$asset[0].size) -ExpectedSha256 ([string]$asset[0].digest -replace '^sha256:','') -MaximumSeconds 1200 -WriteLog $WriteLog
            [pscustomobject]@{Name=$name;Version=[string]$release.tag_name;Path=$download.Path;Bytes=$download.Bytes;Sha256=$download.Sha256;Folder=(Split-Path -Parent $download.Path)}
        }
    )
    $release | ConvertTo-Json -Depth 12 | Set-Content -LiteralPath $releaseIndex -Encoding UTF8
    $script:WinGetCachedArtifactsCheckedUtc = [DateTime]::UtcNow
    $script:WinGetCachedArtifactsForRun = $artifacts
    return $artifacts
}
