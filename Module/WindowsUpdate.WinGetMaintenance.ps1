param(
    [Parameter(Mandatory)][ValidateSet('SourceList','SourceUpdate','SourceReset','ClientRepair')][string]$Action,
    [ValidateSet('','Appx','Asheroto','Microsoft','Portable')][string]$RepairStage = ''
)
$ErrorActionPreference = 'Stop'
$script:WinGetMaintenanceWorkerPath = $PSCommandPath
# BEGIN GENERATED DOWNLOAD CACHE
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
# END GENERATED DOWNLOAD CACHE

function Get-WinGetPath {

    $portableRoot = Join-Path $PSScriptRoot 'WinGetPortable'
    $portable = @(Get-ChildItem -LiteralPath $portableRoot -Filter winget.exe -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    foreach ($candidate in $portable) {
        try {
            $signature = Get-AuthenticodeSignature -FilePath $candidate.FullName -ErrorAction Stop
            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { continue }
            $probe = Invoke-WinGet -Path $candidate.FullName -Arguments @('--version') -TimeoutSeconds 10
            if ($probe.ExitCode -eq 0 -and $probe.Output -match '\d+\.\d+') { return $candidate.FullName }
        } catch { }
    }
    $packages = @()
    try {
        $packages = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
            Sort-Object { [version]$_.Version } -Descending)
    } catch { }
    if ($packages.Count -eq 0) {
        try {
            $packages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
                Sort-Object { [version]$_.Version } -Descending)
        } catch { }
    }
    if ($packages.Count -gt 0) {
        $path = Join-Path ([string]$packages[0].InstallLocation) 'winget.exe'
        if (Test-Path -LiteralPath $path -PathType Leaf) {
            try {
                $probe = Invoke-WinGet -Path $path -Arguments @('--version') -TimeoutSeconds 10
                if ($probe.ExitCode -eq 0 -and $probe.Output -match '\d+\.\d+') { return $path }
            } catch { }
        }
    }
    return $null
}
function Invoke-WinGet {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments, [ValidateRange(1,300)][int]$TimeoutSeconds=300)
    $quoted = foreach ($item in $Arguments) { if ($item -match '[\s"]') { '"' + $item.Replace('"','\"') + '"' } else { $item } }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Path; $start.Arguments = $quoted -join ' '; $start.UseShellExecute = $false
    $start.WorkingDirectory = Split-Path -Parent $Path
    $start.EnvironmentVariables['PATH'] = $start.WorkingDirectory + ';' + $env:PATH
    $start.CreateNoWindow = $true; $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'winget.exe konnte nicht gestartet werden.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) { try { $process.Kill() } catch {}; throw "WinGet-Aktion überschritt $TimeoutSeconds Sekunden." }
        $process.WaitForExit()
        $text = @($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($text -join [Environment]::NewLine).Trim() }
    } finally { $process.Dispose() }
}
        function Get-WinGetPortableClientFromGitHub {
            # WinGet kann auf Server 2019 experimentell aus einem entpackten
            # GitHub-MSIX-Bundle ausgeführt werden. Die Releaseversion und ein
            # optionaler SHA-256-Wert kommen dynamisch aus GitHub-Metadaten.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            try {
                $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
                    -Headers @{ 'User-Agent' = 'Server-Update-Skripte'; Accept = 'application/vnd.github+json' } `
                    -TimeoutSec 8 -ErrorAction Stop
            } catch {
                $onlineError = $_.Exception.Message
                try {
                    $latest = Invoke-WebRequest -Uri 'https://github.com/microsoft/winget-cli/releases/latest' -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
                    $releaseUri = if ($latest.BaseResponse.PSObject.Properties['ResponseUri']) { [uri]$latest.BaseResponse.ResponseUri } else { [uri]$latest.BaseResponse.RequestMessage.RequestUri }
                    if ($releaseUri.Host -ne 'github.com' -or $releaseUri.AbsolutePath -notmatch '^/microsoft/winget-cli/releases/tag/(v[0-9][A-Za-z0-9._-]*)$') { throw 'Unerwartete Release-Weiterleitung.' }
                    $tag = $Matches[1]
                    $release = [pscustomobject]@{ tag_name=$tag; assets=@(
                        foreach ($name in @('Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle','DesktopAppInstaller_Dependencies.zip')) {
                            [pscustomobject]@{name=$name; browser_download_url="https://github.com/microsoft/winget-cli/releases/download/$tag/$name"; digest=''}
                        }
                    ) }
                } catch {
                foreach ($fallbackRoot in @((Join-Path $PSScriptRoot 'WinGetPortable'))) {
                    if (-not [IO.Directory]::Exists($fallbackRoot)) { continue }
                    foreach ($candidate in [IO.Directory]::EnumerateFiles($fallbackRoot, 'winget.exe', [IO.SearchOption]::AllDirectories)) {
                        try {
                            $signature = Get-AuthenticodeSignature -FilePath $candidate -ErrorAction Stop
                            if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { continue }
                            $probe = Invoke-WinGet -Path $candidate -Arguments @('--version') -TimeoutSeconds 10
                            if ($probe.ExitCode -eq 0 -and $probe.Output -match '(?m)^\s*v?(\d+\.\d+[.\d]*)\s*$') {
                                return [pscustomobject]@{Path=$candidate;Version=$Matches[1];ReleaseTag=$Matches[1];Cached=$true;OfflineCache=$true;OnlineDiagnostic=$onlineError}
                            }
                        } catch { }
                    }
                }
                throw "GitHub-Releaseabfrage fehlgeschlagen und keine signaturgeprüfte startfähige CLI im Cache gefunden: $onlineError"
                }
            }
            $releaseTag = [string]$release.tag_name
            if ([string]::IsNullOrWhiteSpace($releaseTag)) { throw 'GitHub lieferte keinen Tag für das aktuelle WinGet-Release.' }
            $asset = @($release.assets | Where-Object {
                [string]$_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            } | Select-Object -First 1)
            if ($asset.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$asset[0].browser_download_url)) {
                throw "GitHub-Release '$releaseTag' enthält nicht das erwartete App-Installer-MSIX-Bundle."
            }

            $safeTag = [regex]::Replace($releaseTag, '[^A-Za-z0-9._-]', '_')
            $cacheRoot = Join-Path $PSScriptRoot 'WinGetPortable'
            $packageRoot = Join-Path $cacheRoot $safeTag
            $cachedExecutable = @(Get-ChildItem -LiteralPath $packageRoot -Filter winget.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($cachedExecutable.Count -gt 0) {
                try {
                    $cachedSignature = Get-AuthenticodeSignature -FilePath $cachedExecutable[0].FullName -ErrorAction Stop
                    if ($cachedSignature.Status -ne 'Valid' -or $cachedSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Portable CLI im Cache hat keine gültige Microsoft-Signatur.' }
                    $cachedProbe = Invoke-WinGet -Path $cachedExecutable[0].FullName -Arguments @('--version') -TimeoutSeconds 10
                    if ([int]$cachedProbe.ExitCode -eq 0 -and [string]$cachedProbe.Output -match '(?m)^\s*v?\d+\.\d+') {
                        return [pscustomobject]@{ Path = $cachedExecutable[0].FullName; Version = $releaseTag; ReleaseTag = $releaseTag; Cached = $true }
                    }
                }
                catch { }
                Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction Stop
            }

            $workingRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-WinGet-Portable-' + [guid]::NewGuid().ToString('N'))
            $bundlePath = Join-Path $workingRoot 'DesktopAppInstaller.msixbundle'
            $packagePath = Join-Path $workingRoot 'AppInstaller_x64.msix'
            try {
                New-Item -Path $workingRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                $downloadSize = if ($asset[0].PSObject.Properties['size']) { [long]$asset[0].size } else { 0 }
                $downloadHash = ([string]$asset[0].digest -replace '^sha256:','')
                Invoke-WindowsUpdateCachedDownload -Uri ([uri]$asset[0].browser_download_url) -DestinationPath $bundlePath -ExpectedBytes $downloadSize -ExpectedSha256 $downloadHash -MaximumSeconds 1200 -WriteLog { param($line) [Console]::Out.WriteLine($line) } | Out-Null
                if ((Get-Item -LiteralPath $bundlePath -ErrorAction Stop).Length -le 0) { throw 'Das GitHub-MSIX-Bundle ist leer.' }

                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                $bundleArchive = [IO.Compression.ZipFile]::OpenRead($bundlePath)
                try {
                    $x64Package = @($bundleArchive.Entries | Where-Object {
                        [IO.Path]::GetFileName([string]$_.FullName) -match '(?i)^AppInstaller_x64\.msix$'
                    } | Select-Object -First 1)
                    if ($x64Package.Count -eq 0) {
                        $availablePackages = @($bundleArchive.Entries | Where-Object {
                            [IO.Path]::GetExtension([string]$_.FullName) -in '.msix', '.appx'
                        } | ForEach-Object FullName)
                        throw "Das GitHub-Bundle enthält kein x64-App-Installer-Paket. Enthalten: $($availablePackages -join ', ')"
                    }
                    $inputStream = $x64Package[0].Open()
                    try {
                        $outputStream = [IO.File]::Create($packagePath)
                        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                    } finally { $inputStream.Dispose() }
                }
                finally { $bundleArchive.Dispose() }

                if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction Stop }
                New-Item -Path $packageRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                [IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $packageRoot)
                $extractedExecutable = @(Get-ChildItem -LiteralPath $packageRoot -Filter winget.exe -File -Recurse -ErrorAction Stop | Select-Object -First 1)
                if ($extractedExecutable.Count -eq 0) { throw 'Das entpackte GitHub-App-Installer-Paket enthält keine winget.exe.' }

                $dependencyAsset = @($release.assets | Where-Object name -eq 'DesktopAppInstaller_Dependencies.zip')
                if ($dependencyAsset.Count -ne 1) { throw 'Microsoft-Abhängigkeiten fehlen.' }
                $dependencyHash = ''
                if ([string]$dependencyAsset[0].digest -match '^sha256:([a-fA-F0-9]{64})$') { $dependencyHash = $Matches[1] }
                $dependencyUri = [uri]$dependencyAsset[0].browser_download_url
                if ($dependencyUri.Scheme -ne 'https' -or $dependencyUri.Host -ne 'github.com' -or $dependencyUri.AbsolutePath -notlike '/microsoft/winget-cli/releases/download/*') { throw 'Ungültige Abhängigkeitsquelle.' }
                $dependencyZip = Join-Path $workingRoot 'Dependencies.zip'
                $dependencySize = if ($dependencyAsset[0].PSObject.Properties['size']) { [long]$dependencyAsset[0].size } else { 0 }
                Invoke-WindowsUpdateCachedDownload -Uri $dependencyUri -DestinationPath $dependencyZip -ExpectedBytes $dependencySize -ExpectedSha256 $dependencyHash -MaximumSeconds 1200 -WriteLog { param($line) [Console]::Out.WriteLine($line) } | Out-Null
                if ($dependencyHash -and (Get-FileHash -LiteralPath $dependencyZip -Algorithm SHA256).Hash -ine $dependencyHash) { throw 'Abhängigkeitsprüfsumme stimmt nicht.' }
                $dependencyRoot = Join-Path $workingRoot 'Dependencies'
                Expand-Archive -LiteralPath $dependencyZip -DestinationPath $dependencyRoot -ErrorAction Stop
                foreach ($dependencyPackage in @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File | Where-Object { $_.Extension -in '.appx','.msix' -and $_.FullName -match '[\\/]x64[\\/]' })) {
                    $dllRoot = Join-Path $workingRoot ([guid]::NewGuid().ToString('N'))
                    [IO.Compression.ZipFile]::ExtractToDirectory($dependencyPackage.FullName, $dllRoot)
                    foreach ($dll in @(Get-ChildItem -LiteralPath $dllRoot -Recurse -Filter '*.dll' -File)) {
                        $dllSignature = Get-AuthenticodeSignature -FilePath $dll.FullName -ErrorAction Stop
                        if ($dllSignature.Status -ne 'Valid' -or $dllSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw "Ungültige Microsoft-Signatur: $($dll.Name)" }
                        $destination = Join-Path (Split-Path -Parent $extractedExecutable[0].FullName) $dll.Name
                        if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $dll.FullName -Destination $destination -ErrorAction Stop }
                    }
                }
                $packageVersion = $releaseTag
                $manifestPath = Join-Path $packageRoot 'AppxManifest.xml'
                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
                    $identity = $manifest.SelectSingleNode("//*[local-name()='Identity']")
                    if ($identity -and -not [string]::IsNullOrWhiteSpace([string]$identity.Version)) { $packageVersion = [string]$identity.Version }
                }
                if ([string]$asset[0].digest -match '^sha256:(?<Hash>[0-9a-fA-F]{64})$') {
                    $expectedHash = $Matches.Hash
                    $actualHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($actualHash -ine $expectedHash) { throw 'Die Bundle-Prüfsumme weicht vom dynamischen GitHub-Release-Metadatum ab.' }
                }
                $exeSignature = Get-AuthenticodeSignature -FilePath $extractedExecutable[0].FullName -ErrorAction Stop
                if ($exeSignature.Status -ne 'Valid' -or $exeSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Entpackte portable CLI hat keine gültige Microsoft-Signatur.' }
                return [pscustomobject]@{ Path = $extractedExecutable[0].FullName; Version = $packageVersion; ReleaseTag = $releaseTag; Cached = $false }
            }
            catch {
                if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue }
                throw
            }
            finally {
                if (Test-Path -LiteralPath $workingRoot) { Remove-Item -LiteralPath $workingRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

function Test-WinGetStartAccessDenied {
    param([Parameter(Mandatory)][System.Exception]$Exception)
    $current = $Exception
    while ($null -ne $current) {
        if ($current -is [System.ComponentModel.Win32Exception] -and $current.NativeErrorCode -eq 5) { return $true }
        if ($current.HResult -eq -2147024891) { return $true }
        $current = $current.InnerException
    }
    return $false
}

function Invoke-WinGetSourceResetSequence {
    param([Parameter(Mandatory)][string]$Path)
    $list = Invoke-WinGet -Path $Path -Arguments @('source','list','--disable-interactivity')
    if ($list.ExitCode -ne 0) { throw "WinGet-Quellenliste fehlgeschlagen: $($list.Output)" }
    $names = @($list.Output -split "`r?`n" | ForEach-Object { if ($_ -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name } })
    $custom = @($names | Where-Object { $_ -notin @('winget','msstore','winget-font') } | Select-Object -Unique)
    if ($custom.Count -gt 0) { throw "Quellenreset zum Schutz kundeneigener Quelle(n) ausgelassen: $($custom -join ', ')" }
    $reset = Invoke-WinGet -Path $Path -Arguments @('source','reset','--force')
    if ($reset.ExitCode -ne 0) { throw "WinGet-Quellenreset fehlgeschlagen: $($reset.Output)" }
    $refresh = Invoke-WinGet -Path $Path -Arguments @('source','update','--name','winget','--disable-interactivity')
    if ($refresh.ExitCode -ne 0) { throw "WinGet-Quellenaktualisierung nach Reset fehlgeschlagen: $($refresh.Output)" }
    return [pscustomobject]@{ Path=$Path; Output=($reset.Output + [Environment]::NewLine + $refresh.Output).Trim() }
}

# Fester Wartungsbaustein; keine vom JEA-Aufrufer gelieferten Pfade oder Befehle.
function Repair-WindowsUpdateWinGetAppx {
    $root = Join-Path $PSScriptRoot 'AppxRepair'
    New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{'User-Agent'='Server-Update-Skripte'} -TimeoutSec 30 -ErrorAction Stop
    function Get-RepairAsset {
        param([string]$Name)
        $asset = @($release.assets | Where-Object name -eq $Name)
        if ($asset.Count -ne 1) { throw "Microsoft-Release enthält nicht genau ein Asset '$Name'." }
        $uri = [uri]$asset[0].browser_download_url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -notlike '/microsoft/winget-cli/releases/download/*') { throw 'Unerwartete Microsoft-Downloadadresse.' }
        $path = Join-Path $root $Name
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $path -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        if ([string]$asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw "Release-Digest fehlt für '$Name'." }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Matches[1]) { throw "Release-Digest stimmt nicht für '$Name'." }
        return $path
    }
    $bundle = Get-RepairAsset 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $dependencies = Get-RepairAsset 'DesktopAppInstaller_Dependencies.zip'
    $licenseAssets = @($release.assets | Where-Object { $_.name -like '*License*.xml' })
    if ($licenseAssets.Count -ne 1) { throw 'Microsoft-Release enthält keine eindeutige App-Installer-Lizenz.' }
    $license = Get-RepairAsset ([string]$licenseAssets[0].name)
    $extract = Join-Path $root ([guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $dependencies -DestinationPath $extract -ErrorAction Stop
    $dependencyPaths = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object { $_.Extension -in '.appx','.msix' -and $_.FullName -match '[\\/]x64[\\/]' } | ForEach-Object FullName)
    if ($dependencyPaths.Count -eq 0) { throw 'Keine x64-Abhängigkeiten im Microsoft-Release gefunden.' }
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $dependencyPaths -LicensePath $license -ErrorAction Stop | Out-Null
    } finally {
        $resolvedExtract = [IO.Path]::GetFullPath($extract)
        $allowedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        if ($resolvedExtract.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output 'App-Installer-Maschinenbestand samt Abhängigkeiten aus aktuellem Microsoft-Release provisioniert.'
    # Nur bereits angemeldete echte Benutzer; keine Kennwörter und kein neues Administratorkonto.
    $user = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Output 'Benutzerregistrierung ausstehend: kein interaktiv angemeldeter Benutzer verfügbar.'
        return
    }
    $sid = ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
    $profile = @(Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid -and $_.Loaded -and -not $_.Special })
    if ($profile.Count -ne 1) { throw "Kein geladenes echtes Benutzerprofil für '$user'." }
    $registration = Join-Path $root 'Register-AppInstaller.ps1'
    [IO.File]::WriteAllText($registration, "`$ErrorActionPreference='Stop'; Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop", [Text.UTF8Encoding]::new($true))
    $name = 'WindowsUpdateAdm-AppxRegistration-' + $PID
    try {
        $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $registration + '"')
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(2)
        do {
            Start-Sleep -Seconds 2
            $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        } while (($info.LastRunTime -lt (Get-Date).AddMinutes(-3) -or $task.State -in 'Running','Queued') -and (Get-Date) -lt $deadline)
        if ($task.State -in 'Running','Queued' -or $info.LastTaskResult -ne 0) { throw "Benutzerregistrierung fehlgeschlagen/abgelaufen: $($info.LastTaskResult)." }
        $registered = @(Get-AppxPackage -User $sid -Name Microsoft.DesktopAppInstaller -ErrorAction Stop | Where-Object Status -eq 'Ok')
        if ($registered.Count -eq 0) { throw 'App Installer nach Registrierungsaufgabe nicht im Benutzerprofil bestätigt.' }
        Write-Output "App Installer im echten Benutzerprofil '$user' registriert und bestätigt."
    } finally {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

# Jede Stufe läuft in einem eigenen PS5-Prozess. Ein blockierendes AppX-Cmdlet
# darf den portablen Rückfall und die spätere Paketabfrage nicht verdrängen.
function Invoke-WinGetRepairStage {
    param([Parameter(Mandatory)][ValidateSet('Appx','Asheroto','Microsoft','Portable')][string]$Stage,
          [Parameter(Mandatory)][int]$TimeoutSeconds)
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $startInfo.Arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $script:WinGetMaintenanceWorkerPath + '" -Action ClientRepair -RepairStage ' + $Stage
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $true
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $startInfo.WorkingDirectory = $PSScriptRoot
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    $timedOut = $false
    $stageProcessId = 0
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw "Reparaturstufe $Stage konnte nicht starten." }
        $stageProcessId = $process.Id
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timedOut = $true
            # Auch winget-install-Unterprozesse beenden; nicht nur die PS-Hülle.
            $kill = [Diagnostics.ProcessStartInfo]::new()
            $kill.FileName = Join-Path $env:WINDIR 'System32\taskkill.exe'
            $kill.Arguments = '/PID ' + $process.Id + ' /T /F'
            $kill.UseShellExecute = $false; $kill.CreateNoWindow = $true
            $killer = [Diagnostics.Process]::Start($kill)
            try { if (-not $killer.WaitForExit(2000)) { $killer.Kill() } } finally { $killer.Dispose() }
            if (-not $process.WaitForExit(1000)) { try { $process.Kill() } catch {} }
        }
        $output = @()
        foreach ($stream in @($stdout,$stderr)) {
            if ($stream.Wait(1000)) { $output += $stream.GetAwaiter().GetResult() }
        }
        if ($timedOut) { $output += "Stufe $Stage nach $TimeoutSeconds Sekunden beendet; nächste Stufe wird versucht." }
        [pscustomobject]@{ Stage=$Stage; Success=(-not $timedOut -and $process.HasExited -and $process.ExitCode -eq 0); TimedOut=$timedOut; Output=($output -join [Environment]::NewLine) }
    } finally {
        # Die vom AppX-Unterprozess angelegte Benutzeraufgabe gehört nicht zum Prozessbaum.
        if ($Stage -eq 'Appx' -and $stageProcessId -gt 0) {
            $taskName = 'WindowsUpdateAdm-AppxRegistration-' + $stageProcessId
            Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
        }
        if ($Stage -eq 'Asheroto' -and $stageProcessId -gt 0) {
            Remove-Item -LiteralPath (Join-Path ([IO.Path]::GetTempPath()) ('winget-install-' + $stageProcessId + '.ps1')) -Force -ErrorAction SilentlyContinue
        }
        $process.Dispose()
    }
}

if ($Action -eq 'ClientRepair') {
    if ($RepairStage) {
        $temp = Join-Path ([IO.Path]::GetTempPath()) ('winget-install-' + $PID + '.ps1')
        try {
            switch ($RepairStage) {
                'Appx' { Repair-WindowsUpdateWinGetAppx }
                'Asheroto' {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/asheroto/winget-install/releases/latest' -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $assets = @($release.assets | Where-Object { $_.name -eq 'winget-install.ps1' })
        if ($assets.Count -ne 1) { throw 'GitHub-Release enthält kein eindeutiges winget-install.ps1.' }
        $asset = $assets[0]
        if ([string]$asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'GitHub-Release enthält keinen SHA256-Digest.' }
        $releaseHash = $Matches[1]
        $downloadUri = [uri]$asset.browser_download_url
        if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -ne 'github.com' -or $downloadUri.AbsolutePath -notlike '/asheroto/winget-install/releases/download/*/winget-install.ps1') { throw 'Unerwartete Release-Downloadadresse.' }
        Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -OutFile $temp -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $sig = Get-AuthenticodeSignature -FilePath $temp -ErrorAction Stop

        $hashMatches = (Get-FileHash -LiteralPath $temp -Algorithm SHA256 -ErrorAction Stop).Hash -eq $releaseHash
        if (-not $hashMatches -or $sig.Status -notin @([Management.Automation.SignatureStatus]::Valid, [Management.Automation.SignatureStatus]::NotSigned)) {
            throw "WinGet-Reparaturskript ist weder gültig signiert noch die per Online-Digest bestätigte Release-Datei."
        }
        $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $installerResult = Invoke-WinGet -Path $ps51 -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$temp,'-Force')
        $out = $installerResult.Output
        $code = $installerResult.ExitCode
        if ($code -ne 0) { throw "winget-install.ps1 -Force endete mit Exitcode $code. $out" }
        $clientPath = Get-WinGetPath
        $clientProbe = Invoke-WinGet -Path $clientPath -Arguments @('--version') -TimeoutSeconds 10
        $version = $clientProbe.Output
        if ($clientProbe.ExitCode -ne 0 -or $version -notmatch '(?m)^\s*v?\d+\.\d+') { throw "WinGet-Starttest fehlgeschlagen: Pfad=$clientPath; Exitcode=$($clientProbe.ExitCode); Ausgabe=$version; Installerausgabe=$out" }

                    [Console]::Out.WriteLine("Geprüfte winget-install.ps1 ausgeführt; WinGet $version. $out")
                }
                'Microsoft' {
                    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
                    $repairParameters = @{ Latest=$true; Force=$true; ErrorAction='Stop' }
                    if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') { $repairParameters.AllUsers=$true }
                    Repair-WinGetPackageManager @repairParameters | Out-String | Write-Output
                    $probe = Invoke-WinGet -Path (Get-WinGetPath) -Arguments @('--version') -TimeoutSeconds 10
                    if ($probe.ExitCode -ne 0 -or $probe.Output -notmatch '(?m)^\s*v?\d+\.\d+') { throw 'WinGet-Starttest nach Microsoft-Reparatur fehlgeschlagen.' }
                    [Console]::Out.WriteLine("Microsoft-Reparatur erfolgreich: $($probe.Output)")
                }
                'Portable' {
                    $portableClient = Get-WinGetPortableClientFromGitHub
                    $probe = Invoke-WinGet -Path $portableClient.Path -Arguments @('--version') -TimeoutSeconds 10
                    if ($probe.ExitCode -ne 0 -or $probe.Output -notmatch '(?m)^\s*v?\d+\.\d+') { throw 'Portabler WinGet-Starttest fehlgeschlagen.' }
                    [Console]::Out.WriteLine("__WINGET_PORTABLE__ portable Microsoft-CLI erfolgreich: $($probe.Output)")
                }
            }
            exit 0
        } catch { [Console]::Out.WriteLine($_.Exception.ToString()); exit 1 }
        finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
    }
    $existing = Get-WinGetPath
    if ($existing) {
        [Console]::Out.WriteLine("Vorhandene CLI erfolgreich geprüft: $existing")
        if ($existing -like '*WinGetPortable*') { [Console]::Out.WriteLine('__WINGET_PORTABLE__') }
        exit 0
    }
    $usable = $false
    foreach ($stage in @(
        @{Name='Appx';Seconds=20}, @{Name='Asheroto';Seconds=35},
        @{Name='Microsoft';Seconds=20}, @{Name='Portable';Seconds=2700}
    )) {
        try {
            $result = Invoke-WinGetRepairStage -Stage $stage.Name -TimeoutSeconds $stage.Seconds
            [Console]::Out.WriteLine("Reparaturstufe $($stage.Name): Erfolg=$($result.Success); Zeitlimit=$($stage.Seconds)s")
            [Console]::Out.WriteLine($result.Output)
            if ($result.Success -and ($stage.Name -ne 'Appx' -or (Get-WinGetPath))) { $usable = $true; break }
        } catch { [Console]::Out.WriteLine("Reparaturstufe $($stage.Name) fehlgeschlagen: $($_.Exception.Message)") }
    }
    if ($usable) { exit 0 }
    [Console]::Out.WriteLine('Keine Reparaturstufe hat eine startfähige WinGet-CLI bestätigt.')
    exit 1
}
$winget = Get-WinGetPath
if (-not $winget) { throw 'Keine startfähige CLI vorhanden. ClientRepair muss die Beschaffung zuerst erfolgreich abschließen; diese Aktion startet keinen erneuten Download.' }
$args = switch ($Action) {
    'SourceList' { @('source','list','--disable-interactivity') }
    'SourceUpdate' { @('source','update','--disable-interactivity') }
    'SourceReset' {
        try {
            $resetResult = Invoke-WinGetSourceResetSequence -Path $winget
        } catch {
            if (-not (Test-WinGetStartAccessDenied -Exception $_.Exception)) { throw }
            throw 'Bestätigte CLI wurde beim Quellenreset verweigert; kein weiterer Download im selben Lauf.'
        }
        [pscustomobject]@{ Action=$Action; Success=$true; ExitCode=0; Output=$resetResult.Output }
        exit 0
    }
}
$result = Invoke-WinGet -Path $winget -Arguments $args
[pscustomobject]@{ Action=$Action; Success=($result.ExitCode -eq 0); ExitCode=$result.ExitCode; Output=$result.Output }
exit $result.ExitCode
