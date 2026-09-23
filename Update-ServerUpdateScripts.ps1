# Aktualisiert vor dem Skriptlauf alle geänderten Programmdateien aus dem öffentlichen main-Branch.

function Get-ServerUpdateGitBlobSha1 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $content = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::UTF8.GetBytes(('blob {0}' -f $content.Length))
    $gitObject = New-Object byte[] ($header.Length + 1 + $content.Length)
    [Array]::Copy($header, 0, $gitObject, 0, $header.Length)
    $gitObject[$header.Length] = 0
    [Array]::Copy($content, 0, $gitObject, $header.Length + 1, $content.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha1.ComputeHash($gitObject))).Replace('-', '').ToLowerInvariant() }
    finally { $sha1.Dispose() }
}

function Get-ServerUpdateConfiguration {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ScriptName
    )

    $configuration = @{
        LinuxHosts = @()
        HomeAssistantHost = ''
    }
    $configurationFiles = @(
        (Join-Path $ScriptRoot 'default_settings.json'),
        (Join-Path $ScriptRoot 'settings.json'),
        (Join-Path $ScriptRoot ($ScriptName + '.settings.json'))
    )
    $configurationFiles += @(Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.settings.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $configurationFiles = @($configurationFiles | Select-Object -Unique)

    foreach ($configurationFile in $configurationFiles) {
        if (-not (Test-Path -LiteralPath $configurationFile -PathType Leaf)) { continue }
        try {
            $settings = Get-Content -LiteralPath $configurationFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($settings.LinuxSettings -and $settings.LinuxSettings.PSObject.Properties['Hosts']) {
                $configuration.LinuxHosts = @($settings.LinuxSettings.Hosts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
            }
            if ($settings.HomeAssistantSettings -and $settings.HomeAssistantSettings.PSObject.Properties['Host']) {
                $configuration.HomeAssistantHost = [string]$settings.HomeAssistantSettings.Host
            }
        }
        catch {
            Write-Warning "Updateprüfung: Konfiguration '$([IO.Path]::GetFileName($configurationFile))' konnte nicht gelesen werden; optionale Skripte werden nicht zusätzlich geladen."
        }
    }

    return $configuration
}

function Get-ServerUpdateRequiredFiles {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryBlobs,
        [System.Collections.IDictionary]$BoundParameters = @{}
    )

    $scriptName = [IO.Path]::GetFileName($ScriptPath)
    $requiredFiles = [System.Collections.Generic.List[object]]::new()
    $windowsOnlyRun = $false
    if ($scriptName -eq 'Install-ServersUpdates.ps1' -or $scriptName -eq 'Verteilung_WindowsUpdateAdmConfig.ps1') {
        $windowsOnlyRun = (@($BoundParameters.Keys) -contains 'TargetComputer') -and @($BoundParameters['TargetComputer'] | Where-Object { $_ }).Count -gt 0
    }

    $configuration = @{ LinuxHosts = @(); HomeAssistantHost = '' }
    if (-not $windowsOnlyRun) {
        $configuration = Get-ServerUpdateConfiguration -ScriptRoot $ScriptRoot -ScriptName $scriptName
    }

    $linuxRequired = $configuration.LinuxHosts.Count -gt 0 -or $scriptName -eq 'Install-Linux Updates.ps1'
    $homeAssistantRequired = -not [string]::IsNullOrWhiteSpace($configuration.HomeAssistantHost) -or $scriptName -eq 'Install-HomeAssistant Updates.ps1'

    foreach ($relativePath in $RepositoryBlobs.Keys) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.(/|$)') { continue }
        if ($relativePath -match '(^|/)\.git(/|$)') { continue }

        $leafName = [IO.Path]::GetFileName($relativePath)
        if ($leafName -ieq '.gitignore' -or [IO.Path]::GetExtension($leafName) -ieq '.md') { continue }
        if ($leafName -ieq 'settings.json' -or $leafName -like '*.settings.json') { continue }
        if ($leafName -match '\.(cer|pfx|p12|key)$') { continue }
        if ($leafName -match '^\.env($|\.)|(^|[._-])(secret|secrets|credential|credentials)([._-]|$)') { continue }
        if ($relativePath -match '(^|/)(Logs|Reports|Certificates|Secrets|RuntimeData)(/|$)') { continue }

        $isLinuxFile = $leafName -match '^(Install-Linux|Linux[._-])' -or $relativePath -match '(^|/)(Linux|linux)/'
        $isHomeAssistantFile = $leafName -match '^(Install-HomeAssistant|HomeAssistant[._-]|HA[._-])' -or $relativePath -match '(^|/)(HomeAssistant|HA)/'
        if ($isLinuxFile -and -not $linuxRequired) { continue }
        if ($isHomeAssistantFile -and -not $homeAssistantRequired) { continue }
        if ($leafName -ieq 'default_settings.json' -and (Test-Path -LiteralPath (Join-Path $ScriptRoot $relativePath) -PathType Leaf)) { continue }

        $requiredFiles.Add([PSCustomObject]@{ Path = [string]$relativePath; Sha = [string]$RepositoryBlobs[$relativePath] })
    }

    return @($requiredFiles | Sort-Object Path -Unique)
}

function Invoke-ServerUpdateScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters = @{},
        [object[]]$RemainingArguments = @()
    )

    $scriptRoot = Split-Path -Parent $ScriptPath
    $repoOwner = 'heppo1990'
    $repoName = 'Server-Update-Skripte'
    $branch = 'main'
    $cacheDirectory = Join-Path $env:ProgramData 'ServerUpdateSkripte'
    $cachePath = Join-Path $cacheDirectory 'UpdateCache.json'
    $latestCommit = $env:SERVER_UPDATE_LATEST_COMMIT
    $restartRequired = $false

    try {
        if ($latestCommit -notmatch '^[0-9a-f]{40}$') {
            $feedUrl = "https://github.com/$repoOwner/$repoName/commits/$branch.atom"
            $feed = Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $commitMatch = [regex]::Match([string]$feed.Content, '::Commit/([0-9a-f]{40})')
            if (-not $commitMatch.Success) { throw 'Die aktuelle Commit-ID konnte nicht aus dem GitHub-Feed gelesen werden.' }
            $latestCommit = $commitMatch.Groups[1].Value
            $env:SERVER_UPDATE_LATEST_COMMIT = $latestCommit
        }

        $manifestCommit = ''
        $repositoryBlobs = @{}
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            try {
                $existingCache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $manifestCommit = [string]$existingCache.ManifestCommit
                if ($existingCache.RepositoryBlobs) {
                    foreach ($property in $existingCache.RepositoryBlobs.PSObject.Properties) {
                        $repositoryBlobs[$property.Name] = [string]$property.Value
                    }
                }
            }
            catch { $repositoryBlobs = @{} }
        }

        if ($manifestCommit -ne $latestCommit -or $repositoryBlobs.Count -eq 0) {
            $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Server-Update-Skripte-Updater' }
            $treeUrl = "https://api.github.com/repos/$repoOwner/$repoName/git/trees/$latestCommit`?recursive=1"
            $treeResponse = Invoke-RestMethod -Uri $treeUrl -Headers $headers -TimeoutSec 20 -ErrorAction Stop
            if ($treeResponse.truncated) { throw 'GitHub lieferte eine unvollständige Dateiliste.' }
            $repositoryBlobs = @{}
            foreach ($item in @($treeResponse.tree | Where-Object { $_.type -eq 'blob' })) {
                $repositoryBlobs[[string]$item.path] = [string]$item.sha
            }
            if ($repositoryBlobs.Count -eq 0) { throw 'Die Dateiliste des Repositorys ist leer.' }
            $manifestCommit = $latestCommit
        }

        $requiredFiles = Get-ServerUpdateRequiredFiles -ScriptRoot $scriptRoot -ScriptPath $ScriptPath -RepositoryBlobs $repositoryBlobs -BoundParameters $BoundParameters

        $filesToFetch = @($requiredFiles | Where-Object {
            $localPath = Join-Path $scriptRoot $_.Path
            (Get-ServerUpdateGitBlobSha1 -Path $localPath) -ne $_.Sha
        })
        if ($filesToFetch.Count -eq 0) {
            try {
                New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
                [PSCustomObject]@{ ManifestCommit = $manifestCommit; RepositoryBlobs = $repositoryBlobs } |
                    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -Encoding UTF8 -Force
            }
            catch { Write-Warning 'Update-Metadaten konnten nicht lokal gespeichert werden; beim nächsten Lauf wird erneut geprüft.' }
            return
        }

        $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ServerUpdateSkripte-' + [guid]::NewGuid().ToString('N'))
        $stageDirectory = Join-Path $temporaryDirectory 'stage'
        $backupDirectory = Join-Path $temporaryDirectory 'backup'
        New-Item -Path $stageDirectory -ItemType Directory -Force | Out-Null
        New-Item -Path $backupDirectory -ItemType Directory -Force | Out-Null
        $changedFiles = [System.Collections.Generic.List[string]]::new()

        try {
            foreach ($file in $filesToFetch) {
                $relativePath = $file.Path
                $encodedPath = (($relativePath -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                $sourceUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$latestCommit/$encodedPath"
                $stagePath = Join-Path $stageDirectory $relativePath
                $stageParent = Split-Path -Parent $stagePath
                if (-not (Test-Path -LiteralPath $stageParent -PathType Container)) {
                    New-Item -Path $stageParent -ItemType Directory -Force | Out-Null
                }
                Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing -TimeoutSec 30 -OutFile $stagePath -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $stagePath -PathType Leaf)) {
                    throw "GitHub lieferte keine gültige Datei für '$relativePath'."
                }
                if ((Get-ServerUpdateGitBlobSha1 -Path $stagePath) -ne $file.Sha) {
                    throw "Die heruntergeladene Datei '$relativePath' stimmt nicht mit dem GitHub-Hash überein."
                }

                $localPath = Join-Path $scriptRoot $relativePath
                if ((Get-ServerUpdateGitBlobSha1 -Path $localPath) -ne $file.Sha) {
                    $changedFiles.Add($relativePath)
                }
            }

            foreach ($relativePath in $changedFiles) {
                $localPath = Join-Path $scriptRoot $relativePath
                if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                    $backupPath = Join-Path $backupDirectory $relativePath
                    $backupParent = Split-Path -Parent $backupPath
                    if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
                        New-Item -Path $backupParent -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $localPath -Destination $backupPath -Force -ErrorAction Stop
                }
            }

            try {
                foreach ($relativePath in $changedFiles) {
                    $localPath = Join-Path $scriptRoot $relativePath
                    $localDirectory = Split-Path -Parent $localPath
                    if (-not (Test-Path -LiteralPath $localDirectory -PathType Container)) {
                        New-Item -Path $localDirectory -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath (Join-Path $stageDirectory $relativePath) -Destination $localPath -Force -ErrorAction Stop
                }
            }
            catch {
                foreach ($relativePath in $changedFiles) {
                    $localPath = Join-Path $scriptRoot $relativePath
                    $backupPath = Join-Path $backupDirectory $relativePath
                    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                        Copy-Item -LiteralPath $backupPath -Destination $localPath -Force -ErrorAction SilentlyContinue
                    }
                    elseif (Test-Path -LiteralPath $localPath -PathType Leaf) {
                        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
                    }
                }
                throw
            }

            try {
                New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
                [PSCustomObject]@{
                    ManifestCommit = $manifestCommit
                    RepositoryBlobs = $repositoryBlobs
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -Encoding UTF8 -Force
            }
            catch {
                Write-Warning 'Update-Metadaten konnten nicht lokal gespeichert werden; beim nächsten Lauf wird erneut geprüft.'
            }
        }
        finally {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }

        $restartRequired = $changedFiles.Count -gt 0
    }
    catch {
        Write-Warning "Automatische Skriptaktualisierung fehlgeschlagen; der vorhandene lokale Stand wird verwendet. Ursache: $($_.Exception.Message)"
    }

    if ($restartRequired) {
        Write-Host ("Skript-Update aus GitHub übernommen ({0} benötigte Datei(en)); starte mit aktualisiertem Stand neu." -f $changedFiles.Count) -ForegroundColor Cyan
        $global:LASTEXITCODE = 0
        & $ScriptPath @BoundParameters @RemainingArguments
        $scriptExitCode = 0
        if (Test-Path variable:global:LASTEXITCODE) { $scriptExitCode = [int]$global:LASTEXITCODE }
        exit $scriptExitCode
    }
}
