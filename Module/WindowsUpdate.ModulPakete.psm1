# Fachmodul: WindowsUpdate.ModulPakete
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function New-WindowsUpdateModulePayload {
    <# Beschafft aktuelle PowerShell-Module zentral und bereitet sie zur Offline-Übertragung vor. #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string[]]$ModuleName,
        [string]$OfflineModulePath,
        [scriptblock]$WriteLog
    )

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $payloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-ModulePayload-{0}' -f [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $payloadRoot -Force -ErrorAction Stop | Out-Null
    $previousProgressPreference = $ProgressPreference
    $ProgressPreference = 'SilentlyContinue'
    $fallbackNames = @()
    $downloadedPackages = @{}

    function Save-DirectGalleryModulePackage {
        param([Parameter(Mandatory)][string]$PackageName, [string]$RequiredVersion)

        if ($PackageName -notmatch '^[A-Za-z0-9_.-]+$') { throw "Ungültiger Modulname in Paketmetadaten: $PackageName" }
        if ($downloadedPackages.ContainsKey($PackageName)) { return }

        $packageUri = 'https://www.powershellgallery.com/api/v2/package/' + [Uri]::EscapeDataString($PackageName)
        if ($RequiredVersion -match '^(\d+(?:\.\d+){1,3})') {
            $packageUri += '/' + $Matches[1]
        }
        $downloadPath = Join-Path $payloadRoot ('{0}.nupkg' -f $PackageName)
        $extractPath = Join-Path $payloadRoot ('_extract_{0}_{1}' -f $PackageName, [guid]::NewGuid().ToString('N'))

        try {
            Invoke-WebRequest -Uri $packageUri -OutFile $downloadPath -UseBasicParsing `
                -ErrorAction Stop -WarningAction SilentlyContinue
            New-Item -ItemType Directory -Path $extractPath -Force -ErrorAction Stop | Out-Null
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue
            [IO.Compression.ZipFile]::ExtractToDirectory($downloadPath, $extractPath)

            $manifest = Get-ChildItem -LiteralPath $extractPath -Filter "$PackageName.psd1" -File -Recurse -ErrorAction SilentlyContinue |
                Select-Object -First 1
            if (-not $manifest) { throw "Das heruntergeladene Gallery-Paket $PackageName enthält kein Modulmanifest." }

            $nuspec = Get-ChildItem -LiteralPath $extractPath -Filter '*.nuspec' -File -ErrorAction SilentlyContinue |
                Select-Object -First 1
            $packageVersion = $null
            $dependencies = @()
            if ($nuspec) {
                [xml]$nuspecXml = Get-Content -LiteralPath $nuspec.FullName -Raw -ErrorAction Stop
                $versionNode = $nuspecXml.SelectSingleNode("//*[local-name()='metadata']/*[local-name()='version']")
                if ($versionNode) { $packageVersion = [string]$versionNode.InnerText }
                $dependencies = @($nuspecXml.SelectNodes("//*[local-name()='dependency']"))
            }
            if ($packageVersion -notmatch '^\d+(\.\d+){1,3}$') {
                $moduleData = Import-PowerShellDataFile -LiteralPath $manifest.FullName -ErrorAction Stop
                $packageVersion = [string]$moduleData.ModuleVersion
            }
            if ($packageVersion -notmatch '^\d+(\.\d+){1,3}$') { throw "Die Paketversion für $PackageName konnte nicht verifiziert werden." }

            $targetVersionPath = Join-Path (Join-Path $payloadRoot $PackageName) $packageVersion
            New-Item -ItemType Directory -Path $targetVersionPath -Force -ErrorAction Stop | Out-Null
            Copy-Item -Path (Join-Path $manifest.DirectoryName '*') -Destination $targetVersionPath `
                -Recurse -Force -ErrorAction Stop
            $downloadedPackages[$PackageName] = $packageVersion

            foreach ($dependency in $dependencies) {
                $dependencyName = [string]$dependency.GetAttribute('id')
                if ([string]::IsNullOrWhiteSpace($dependencyName) -or $downloadedPackages.ContainsKey($dependencyName)) { continue }
                $null = Save-DirectGalleryModulePackage -PackageName $dependencyName -RequiredVersion ([string]$dependency.GetAttribute('version'))
            }
        }
        finally {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $extractPath) {
                Remove-Item -LiteralPath $extractPath -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    try {
        foreach ($name in $ModuleName) {
            $modulePayload = Join-Path $payloadRoot $name
            try {
                # Save-Module holt aktuelle Gallery-Pakete samt deklarierter Abhängigkeiten.
                # Das läuft auf dem Verwaltungsrechner; Zielserver benötigen keinen NuGet-Zugang.
                Save-Module -Name $name -Repository PSGallery -Path $payloadRoot -Force `
                    -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
                $moduleManifest = Get-ChildItem -LiteralPath $modulePayload -Filter "$name.psd1" -File -Recurse -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if (-not $moduleManifest) { throw "Save-Module hat kein gültiges Modulmanifest für $name abgelegt." }
                if ($WriteLog) { & $WriteLog "$name wurde aktuell aus PSGallery bezogen und für die Offline-Übertragung vorbereitet." 'SUCCESS' }
            }
            catch {
                $onlineError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                if (Test-Path -LiteralPath $modulePayload) {
                    Remove-Item -LiteralPath $modulePayload -Recurse -Force -ErrorAction SilentlyContinue
                }

                try {
                    Save-DirectGalleryModulePackage -PackageName $name
                    $moduleManifest = Get-ChildItem -LiteralPath $modulePayload -Filter "$name.psd1" -File -Recurse -ErrorAction SilentlyContinue |
                        Select-Object -First 1
                    if (-not $moduleManifest) { throw "Das direkte Gallery-Paket für $name wurde nicht korrekt bereitgestellt." }
                    if ($WriteLog) { & $WriteLog "$name samt Abhängigkeiten direkt aus PSGallery geladen; der NuGet-Provider-Bootstrap war nicht nötig." 'SUCCESS' }
                    continue
                }
                catch {
                    $directDownloadError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                    if (Test-Path -LiteralPath $modulePayload) {
                        Remove-Item -LiteralPath $modulePayload -Recurse -Force -ErrorAction SilentlyContinue
                    }
                    $onlineError = "$onlineError; direkter PSGallery-Abruf: $directDownloadError"
                }

                $fallbackPath = $null
                if ($OfflineModulePath) {
                    $namedFallback = Join-Path $OfflineModulePath $name
                    if (Test-Path -LiteralPath $namedFallback -PathType Container) {
                        $fallbackPath = $namedFallback
                    } elseif (Test-Path -LiteralPath (Join-Path $OfflineModulePath "$name.psd1") -PathType Leaf) {
                        $fallbackPath = $OfflineModulePath
                    }
                }

                $fallbackVersionDirectories = @()
                if ($fallbackPath) {
                    $fallbackVersionDirectories = @(Get-ChildItem -LiteralPath $fallbackPath -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^\d+(\.\d+)*$' })
                }

                if ($fallbackVersionDirectories.Count -gt 0) {
                    New-Item -ItemType Directory -Path $modulePayload -Force -ErrorAction Stop | Out-Null
                    foreach ($versionDirectory in $fallbackVersionDirectories) {
                        Copy-Item -LiteralPath $versionDirectory.FullName -Destination $modulePayload -Recurse -Force -ErrorAction Stop
                    }
                    # Ein verteiltes Modulpaket kann weitere benötigte Module enthalten.
                    # Die Abhängigkeiten werden zusammen mit dem Paket an das Ziel kopiert.
                    if ($OfflineModulePath -and $fallbackPath -ine $OfflineModulePath) {
                        foreach ($dependencyDirectory in @(Get-ChildItem -LiteralPath $OfflineModulePath -Directory -ErrorAction SilentlyContinue |
                            Where-Object { $_.Name -ne $name })) {
                            Copy-Item -LiteralPath $dependencyDirectory.FullName -Destination $payloadRoot -Recurse -Force -ErrorAction Stop
                        }
                    }
                    $fallbackNames += "$name (Offlinepaket)"
                } else {
                    $localModule = Get-Module -ListAvailable -Name $name -ErrorAction SilentlyContinue |
                        Sort-Object Version -Descending | Select-Object -First 1
                    if (-not $localModule) {
                        throw "$name konnte online nicht bezogen werden und es ist kein Offlinepaket oder lokales Modul vorhanden. Ursache: $onlineError"
                    }
                    $moduleVersionPath = Join-Path $modulePayload ([string]$localModule.Version)
                    New-Item -ItemType Directory -Path $moduleVersionPath -Force -ErrorAction Stop | Out-Null
                    Copy-Item -Path (Join-Path $localModule.ModuleBase '*') -Destination $moduleVersionPath -Recurse -Force -ErrorAction Stop
                    foreach ($requiredModule in @($localModule.RequiredModules)) {
                        if (-not $requiredModule -or [string]::IsNullOrWhiteSpace([string]$requiredModule.Name)) { continue }
                        $dependency = Get-Module -ListAvailable -Name $requiredModule.Name -ErrorAction SilentlyContinue |
                            Where-Object { -not $requiredModule.Version -or $_.Version -ge $requiredModule.Version } |
                            Sort-Object Version -Descending | Select-Object -First 1
                        if (-not $dependency) { continue }
                        $dependencyVersionPath = Join-Path (Join-Path $payloadRoot $dependency.Name) ([string]$dependency.Version)
                        New-Item -ItemType Directory -Path $dependencyVersionPath -Force -ErrorAction Stop | Out-Null
                        Copy-Item -Path (Join-Path $dependency.ModuleBase '*') -Destination $dependencyVersionPath -Recurse -Force -ErrorAction Stop
                    }
                    $fallbackNames += "$name $($localModule.Version)"
                }

                if ($WriteLog) { & $WriteLog "$name konnte nicht aktuell online bezogen werden; Offline-Fallback wird verwendet. Ursache: $onlineError" 'WARN' }
            }
        }

        $stagedModules = @(Get-ChildItem -LiteralPath $payloadRoot -Directory -ErrorAction SilentlyContinue)
        if ($stagedModules.Count -eq 0) { throw 'Es wurden keine PowerShell-Modulpakete bereitgestellt.' }
        if ($fallbackNames.Count -gt 0 -and $WriteLog) {
            & $WriteLog "Offline-Fallback für: $($fallbackNames -join ', ')." 'WARN'
        }
        return [pscustomobject]@{
            Root = $payloadRoot
            FallbackModules = @($fallbackNames)
        }
    }
    catch {
        Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
    finally {
        if ($null -ne $previousProgressPreference) { $ProgressPreference = $previousProgressPreference }
    }
}

function Get-WindowsUpdateGalleryModuleVersion {
    param([Parameter(Mandatory)][string]$Name)

    try {
        $module = Find-Module -Name $Name -Repository PSGallery -ErrorAction Stop -WarningAction SilentlyContinue |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($module) { return [version]$module.Version }
    } catch { }
    return $null
}
