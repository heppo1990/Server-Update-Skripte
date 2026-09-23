# Aktualisiert vor dem Skriptlauf nur die benötigten Dateien aus dem öffentlichen main-Branch.

function Get-ServerUpdateFileHash {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
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
        [System.Collections.IDictionary]$BoundParameters = @{}
    )

    $scriptName = [IO.Path]::GetFileName($ScriptPath)
    $requiredFiles = [System.Collections.Generic.List[string]]::new()
    $requiredFiles.Add('Update-ServerUpdateScripts.ps1')
    $requiredFiles.Add($scriptName)

    $scriptsUsingCommonModule = @(
        'Check-ServersUpdates.ps1', 'Download-ServersUpdates.ps1', 'Install-ServersUpdates.ps1',
        'Install-Linux Updates.ps1', 'Install-HomeAssistant Updates.ps1', 'PendingReboot.ps1',
        'Setup-ClientCertificate.ps1', 'Verteilung_WindowsUpdateAdmConfig.ps1'
    )
    if ($scriptName -in $scriptsUsingCommonModule) { $requiredFiles.Add('WindowsUpdate.Common.psm1') }

    if ($scriptName -eq 'Verteilung_WindowsUpdateAdmConfig.ps1') {
        $requiredFiles.Add('New-WindowsUpdateAdmConfig.ps1')
        $requiredFiles.Add('Setup-ClientCertificate.ps1')
    }

    $supportsOptionalSystems = $scriptName -in @(
        'Check-ServersUpdates.ps1', 'Download-ServersUpdates.ps1',
        'Install-ServersUpdates.ps1', 'Verteilung_WindowsUpdateAdmConfig.ps1'
    )
    $windowsOnlyRun = $false
    if ($scriptName -eq 'Install-ServersUpdates.ps1' -or $scriptName -eq 'Verteilung_WindowsUpdateAdmConfig.ps1') {
        $windowsOnlyRun = $BoundParameters.Contains('TargetComputer') -and @($BoundParameters['TargetComputer'] | Where-Object { $_ }).Count -gt 0
    }

    if ($supportsOptionalSystems -and -not $windowsOnlyRun) {
        $configuration = Get-ServerUpdateConfiguration -ScriptRoot $ScriptRoot -ScriptName $scriptName
        if ($configuration.LinuxHosts.Count -gt 0) { $requiredFiles.Add('Install-Linux Updates.ps1') }
        if (-not [string]::IsNullOrWhiteSpace($configuration.HomeAssistantHost)) { $requiredFiles.Add('Install-HomeAssistant Updates.ps1') }
    }

    # Die Standarddatei wird nur dann aus dem Repository ergänzt, wenn sie lokal fehlt.
    if (-not (Test-Path -LiteralPath (Join-Path $ScriptRoot 'default_settings.json') -PathType Leaf)) {
        $requiredFiles.Add('default_settings.json')
    }

    return @($requiredFiles | Select-Object -Unique)
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

        $requiredFiles = Get-ServerUpdateRequiredFiles -ScriptRoot $scriptRoot -ScriptPath $ScriptPath -BoundParameters $BoundParameters
        $fileState = @{}
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            try {
                $existingCache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if ($existingCache.Files) {
                    foreach ($property in $existingCache.Files.PSObject.Properties) {
                        $fileState[$property.Name] = [string]$property.Value
                    }
                }
            }
            catch { $fileState = @{} }
        }

        $filesToFetch = @($requiredFiles | Where-Object {
            $localPath = Join-Path $scriptRoot $_
            -not (Test-Path -LiteralPath $localPath -PathType Leaf) -or $fileState[$_] -ne $latestCommit
        })
        if ($filesToFetch.Count -eq 0) { return }

        $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ServerUpdateSkripte-' + [guid]::NewGuid().ToString('N'))
        $stageDirectory = Join-Path $temporaryDirectory 'stage'
        $backupDirectory = Join-Path $temporaryDirectory 'backup'
        New-Item -Path $stageDirectory -ItemType Directory -Force | Out-Null
        New-Item -Path $backupDirectory -ItemType Directory -Force | Out-Null
        $changedFiles = [System.Collections.Generic.List[string]]::new()

        try {
            foreach ($relativePath in $filesToFetch) {
                $encodedPath = (($relativePath -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                $sourceUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$latestCommit/$encodedPath"
                $stagePath = Join-Path $stageDirectory $relativePath
                Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing -TimeoutSec 30 -OutFile $stagePath -ErrorAction Stop
                if (-not (Test-Path -LiteralPath $stagePath -PathType Leaf) -or (Get-Item -LiteralPath $stagePath).Length -eq 0) {
                    throw "GitHub lieferte keine gültige Datei für '$relativePath'."
                }

                $localPath = Join-Path $scriptRoot $relativePath
                if ((Get-ServerUpdateFileHash -Path $localPath) -ne (Get-ServerUpdateFileHash -Path $stagePath)) {
                    $changedFiles.Add($relativePath)
                }
            }

            foreach ($relativePath in $changedFiles) {
                $localPath = Join-Path $scriptRoot $relativePath
                if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                    Copy-Item -LiteralPath $localPath -Destination (Join-Path $backupDirectory $relativePath) -Force -ErrorAction Stop
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

            foreach ($relativePath in $filesToFetch) { $fileState[$relativePath] = $latestCommit }
            try {
                New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
                [PSCustomObject]@{ Files = $fileState } |
                    ConvertTo-Json -Depth 5 |
                    Set-Content -LiteralPath $cachePath -Encoding UTF8 -Force
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
