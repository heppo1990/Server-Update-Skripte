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
        $targetComputerRun = (@($BoundParameters.Keys) -contains 'TargetComputer') -and @($BoundParameters['TargetComputer'] | Where-Object { $_ }).Count -gt 0
        $cleanupOnlyRun = (@($BoundParameters.Keys) -contains 'CleanupLegacyTempOnly') -and [bool]$BoundParameters['CleanupLegacyTempOnly']
        $windowsOnlyRun = $targetComputerRun -or $cleanupOnlyRun
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
        $requiredFiles.Add([PSCustomObject]@{ Path = [string]$relativePath; Sha = [string]$RepositoryBlobs[$relativePath] })
    }

    return @($requiredFiles | Sort-Object Path -Unique)
}

# Ergänzt beim Skriptupdate nur fehlende Standardwerte; vorhandene Kundenwerte bleiben erhalten.
function Copy-ServerUpdateJsonValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [PSCustomObject]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $propertyCopy = Copy-ServerUpdateJsonValue -Value $property.Value
            Add-Member -InputObject $copy -NotePropertyName $property.Name -NotePropertyValue $propertyCopy
        }
        return $copy
    }
    if ($Value -is [array]) {
        $copy = @(
            foreach ($item in $Value) { Copy-ServerUpdateJsonValue -Value $item }
        )
        return ,$copy
    }
    return $Value
}

function Add-ServerUpdateMissingJsonProperties {
    param(
        [Parameter(Mandatory)][System.Management.Automation.PSCustomObject]$Destination,
        [Parameter(Mandatory)][System.Management.Automation.PSCustomObject]$Defaults
    )
    $added = 0
    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $destinationProperty = $Destination.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $destinationProperty) {
            $defaultValue = Copy-ServerUpdateJsonValue -Value $defaultProperty.Value
            Add-Member -InputObject $Destination -NotePropertyName $defaultProperty.Name -NotePropertyValue $defaultValue
            $added++
        }
        elseif ($destinationProperty.Value -is [System.Management.Automation.PSCustomObject] -and
                $defaultProperty.Value -is [System.Management.Automation.PSCustomObject]) {
            $added += Add-ServerUpdateMissingJsonProperties -Destination $destinationProperty.Value -Defaults $defaultProperty.Value
        }
    }
    return $added
}

function Update-ServerUpdateSettingsDefaults {
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $defaultsPath = Join-Path $ScriptRoot 'default_settings.json'
    if (-not (Test-Path -LiteralPath $defaultsPath -PathType Leaf)) { return }
    try {
        $defaults = Get-Content -LiteralPath $defaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Standard-Einstellungen konnten nicht eingelesen werden; Kundeneinstellungen bleiben unverändert. Ursache: $($_.Exception.Message)"
        return
    }

    $generalSettingsPath = Join-Path $ScriptRoot 'settings.json'
    $settingsPaths = if (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf) {
        @($generalSettingsPath)
    } else {
        @(Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.settings.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    }

    foreach ($settingsPath in $settingsPaths) {
        $temporaryPath = $null
        try {
            $settings = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($settings -isnot [System.Management.Automation.PSCustomObject] -or
                $defaults -isnot [System.Management.Automation.PSCustomObject]) { continue }

            $addedCount = Add-ServerUpdateMissingJsonProperties -Destination $settings -Defaults $defaults
            if ($addedCount -eq 0) { continue }

            $backupPath = '{0}.bak.{1}' -f $settingsPath, (Get-Date -Format 'yyyyMMdd_HHmmss_fff')
            Copy-Item -LiteralPath $settingsPath -Destination $backupPath -ErrorAction Stop
            $temporaryPath = '{0}.{1}.tmp' -f $settingsPath, [guid]::NewGuid().ToString('N')
            $updatedJson = ConvertTo-Json -InputObject $settings -Depth 100
            [System.IO.File]::WriteAllText($temporaryPath, $updatedJson, ([System.Text.UTF8Encoding]::new($false)))
            [System.IO.File]::Replace($temporaryPath, $settingsPath, $null)
            $temporaryPath = $null
            Write-Host ("{0} fehlende Standard-Einstellung(en) ergänzt; Sicherung: {1}" -f $addedCount, $backupPath) -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Standardwerte konnten in '$([IO.Path]::GetFileName($settingsPath))' nicht ergänzt werden. Vorhandene Einstellungen bleiben erhalten. Ursache: $($_.Exception.Message)"
        }
        finally {
            if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Invoke-ServerUpdateScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters = @{},
        [object[]]$RemainingArguments = @()
    )

    $scriptRoot = Split-Path -Parent $ScriptPath
    $scriptName = [IO.Path]::GetFileName($ScriptPath)
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
            Update-ServerUpdateSettingsDefaults -ScriptRoot $scriptRoot
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
                Update-ServerUpdateSettingsDefaults -ScriptRoot $scriptRoot
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

    # Nur das Installationsskript prüft PS7 über Windows PowerShell 5.1.
    # Das schützt den laufenden Updateprozess vor einem Austausch der PS7-Dateien.
    if ($scriptName -eq 'Install-ServersUpdates.ps1' -and
        $PSVersionTable.PSEdition -eq 'Core' -and
        $env:SERVER_UPDATE_POWERSHELL7_CHECKED -ne '1') {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
            $restartArguments = [System.Collections.Generic.List[string]]::new()
            if ($BoundParameters.Contains('DebugMode') -and [bool]$BoundParameters['DebugMode']) { $restartArguments.Add('-DebugMode') }
            if ($BoundParameters.Contains('TargetComputer')) {
                $restartArguments.Add('-TargetComputer')
                foreach ($target in @($BoundParameters['TargetComputer'])) { $restartArguments.Add([string]$target) }
            }
            if ($BoundParameters.Contains('TestDeferredMail') -and [bool]$BoundParameters['TestDeferredMail']) { $restartArguments.Add('-TestDeferredMail') }

            $statusPath = Join-Path ([IO.Path]::GetTempPath()) ('ServerUpdate-PowerShell7-' + [guid]::NewGuid().ToString('N') + '.json')
            $environmentNames = @(
                'SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH',
                'SERVER_UPDATE_BOOTSTRAP_STATUS_PATH',
                'SERVER_UPDATE_BOOTSTRAP_ARGUMENTS_JSON'
            )
            $previousEnvironment = @{}
            foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
            try {
                $env:SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH = $ScriptPath
                $env:SERVER_UPDATE_BOOTSTRAP_STATUS_PATH = $statusPath
                $env:SERVER_UPDATE_BOOTSTRAP_ARGUMENTS_JSON = ConvertTo-Json -InputObject @($restartArguments.ToArray()) -Compress

                # Der Vorlauf läuft direkt in Windows PowerShell 5.1 und liegt nicht als zusätzliche Datei im Repository.
                $bootstrapSource = @'
$ErrorActionPreference = 'Stop'
$statusPath = $env:SERVER_UPDATE_BOOTSTRAP_STATUS_PATH
$noUpdateExitCodes = @(-1978335188, -1978335189, -1978335192)
$wingetCommand = Get-Command -Name 'winget.exe' -ErrorAction SilentlyContinue
$chocoPath = 'C:\ProgramData\chocolatey\bin\choco.exe'
try {
    if ($wingetCommand) {
        Write-Host 'Prüfe mit Windows PowerShell 5.1, ob Winget ein PowerShell-7-Update anbietet ...'
        $packageOutput = & $wingetCommand.Source upgrade --id Microsoft.PowerShell --exact --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1
        $packageExitCode = $LASTEXITCODE
        if ($packageExitCode -in $noUpdateExitCodes) { exit 0 }
        if ($packageExitCode -ne 0) {
            Write-Warning "PowerShell-7-Update mit Winget fehlgeschlagen (Exitcode $packageExitCode). Der Installationslauf wird fortgesetzt. $($packageOutput | Out-String)"
            exit 0
        }
    }
    elseif (Test-Path -LiteralPath $chocoPath -PathType Leaf) {
        Write-Host 'Winget ist nicht installiert; prüfe mit Windows PowerShell 5.1 Chocolatey auf ein PowerShell-7-Update ...'
        $outdatedOutput = & $chocoPath outdated --limit-output 2>&1
        $chocoExitCode = $LASTEXITCODE
        if ($chocoExitCode -ne 0) {
            Write-Warning "Chocolatey konnte nicht auf veraltete Pakete prüfen (Exitcode $chocoExitCode). Der Installationslauf wird fortgesetzt. $($outdatedOutput | Out-String)"
            exit 0
        }
        $powerShellUpdateAvailable = @($outdatedOutput | Where-Object { ([string]$_).Trim() -match '^powershell-core\|' }).Count -gt 0
        if (-not $powerShellUpdateAvailable) { exit 0 }
        $packageOutput = & $chocoPath upgrade powershell-core --yes --no-progress 2>&1
        $packageExitCode = $LASTEXITCODE
        if ($packageExitCode -ne 0) {
            Write-Warning "PowerShell-7-Update mit Chocolatey fehlgeschlagen (Exitcode $packageExitCode). Der Installationslauf wird fortgesetzt. $($packageOutput | Out-String)"
            exit 0
        }
    }
    else {
        exit 0
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) { throw 'Nach dem Paketupdate wurde pwsh.exe nicht gefunden.' }
    $scriptArguments = @(ConvertFrom-Json -InputObject $env:SERVER_UPDATE_BOOTSTRAP_ARGUMENTS_JSON -ErrorAction Stop)
    $env:SERVER_UPDATE_POWERSHELL7_CHECKED = '1'
    Write-Host 'PowerShell 7 wurde aktualisiert; starte Install-ServersUpdates.ps1 mit der aktualisierten Version neu.'
    & $pwshCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $env:SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH @scriptArguments
    $scriptExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    Set-Content -LiteralPath $statusPath -Value (@{ Restarted = $true; ExitCode = $scriptExitCode } | ConvertTo-Json -Compress) -Encoding UTF8 -Force
}
catch {
    Write-Warning "PS7-Aktualisierung vor dem Installationslauf fehlgeschlagen; vorhandener Lauf wird fortgesetzt. Ursache: $($_.Exception.Message)"
}
'@
                $encodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrapSource))
                & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedBootstrap
                if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                    $restartStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if ($restartStatus.Restarted) { exit ([int]$restartStatus.ExitCode) }
                }
            }
            catch {
                Write-Warning "PS7-Aktualisierungsprüfung mit Windows PowerShell 5.1 fehlgeschlagen; Installationslauf wird fortgesetzt. Ursache: $($_.Exception.Message)"
            }
            finally {
                foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
                Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}
