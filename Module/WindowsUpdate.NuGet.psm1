# Fachmodul: WindowsUpdate.NuGet
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Update-PS7PackageManagementModule {
    <# Prüft PackageManagement in PowerShell 7; aus PS5 wird dafür ein neuer pwsh-Prozess gestartet. #>
    param([switch]$Force, [scriptblock]$WriteLog)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if ($PSVersionTable.PSVersion.Major -lt 7) {
        $pwsh = Get-Command -Name pwsh.exe -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $pwsh) { return $true }

        $updaterDefinition = (Get-Command -Name Update-PS7PackageManagementModule -CommandType Function).Definition
        $forceArgument = if ($Force) { '-Force' } else { '' }
        $childScript = @"
function Update-PS7PackageManagementModule {
$updaterDefinition
}
`$writeLog = { param(`$Message, `$Level) Write-Output ("__PMLOG__`$Level`t`$Message") }
`$null = Update-PS7PackageManagementModule -WriteLog `$writeLog $forceArgument
"@
        $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
        $workerRoot = Join-Path ([IO.Path]::GetTempPath()) ('PS7PackageManagement-{0}' -f [guid]::NewGuid().ToString('N'))
        $stdoutPath = Join-Path $workerRoot 'stdout.txt'
        $stderrPath = Join-Path $workerRoot 'stderr.txt'
        $childOutput = @()
        $childExitCode = -1
        try {
            New-Item -ItemType Directory -Path $workerRoot -Force -ErrorAction Stop | Out-Null
            $workerProcess = Start-Process -FilePath $pwsh.Source `
                -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedCommand) `
                -Wait -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
            $childExitCode = $workerProcess.ExitCode
            $stdout = if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { @(Get-Content -LiteralPath $stdoutPath -ErrorAction SilentlyContinue) } else { @() }
            $stderr = if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { @(Get-Content -LiteralPath $stderrPath -ErrorAction SilentlyContinue) } else { @() }
            $childOutput = @($stdout + $stderr | ForEach-Object { [string]$_ })
        }
        finally {
            Remove-Item -LiteralPath $workerRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $unparsedOutput = @()
        foreach ($line in $childOutput) {
            if ($line -match '^__PMLOG__(INFO|WARN|SUCCESS|UPDATE)\t(.*)$') {
                if ($WriteLog) { & $WriteLog $Matches[2] $Matches[1] }
                continue
            }
            if (-not [string]::IsNullOrWhiteSpace($line)) { $unparsedOutput += $line.Trim() }
        }
        if ($childExitCode -ne 0) {
            $detail = ($unparsedOutput -join ' ' -replace '\s+', ' ').Trim()
            if ($detail.Length -gt 400) { $detail = $detail.Substring(0, 397) + '...' }
            $message = 'PackageManagement-Prüfung in PowerShell 7 fehlgeschlagen; vorhandener Stand bleibt aktiv.'
            if ($detail) { $message += " Ursache: $detail" }
            if ($WriteLog) { & $WriteLog $message 'WARN' } else { Write-Warning $message }
        }
        return $true
    }

    $installedModule = Get-Module -ListAvailable -Name PackageManagement -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    try {
        $galleryModule = Find-Module -Name PackageManagement -Repository PSGallery -ErrorAction Stop
        $latestVersion = [version]$galleryModule.Version
    }
    catch {
        $detail = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        $currentVersion = if ($installedModule) { [string]$installedModule.Version } else { 'nicht ermittelt' }
        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'PackageManagement für PowerShell 7 suchen' -ErrorRecord $_ -Context @('Fallback=vorhandene Version bleibt aktiv')
        $message = "PackageManagement-Version für PowerShell 7 konnte nicht geprüft werden (vorhanden: $currentVersion)."
        if ($detail) { $message += " Ursache: $detail" }
        if ($WriteLog) { & $WriteLog $message 'WARN' } else { Write-Warning $message }
        return $true
    }

    if ($installedModule -and $installedModule.Version -ge $latestVersion -and -not $Force) {
        if ($WriteLog) { & $WriteLog "PackageManagement für PowerShell 7 ist aktuell (Version $($installedModule.Version))." 'SUCCESS' }
        return $true
    }

    $oldVersion = if ($installedModule) { [string]$installedModule.Version } else { 'nicht installiert' }
    if ($WriteLog) { & $WriteLog "PackageManagement für PowerShell 7 wird aktualisiert: $oldVersion -> $latestVersion." 'UPDATE' }
    $installSucceeded = $false
    for ($attempt = 1; $attempt -le 3 -and -not $installSucceeded; $attempt++) {
        try {
            Install-Module -Name PackageManagement -Repository PSGallery -RequiredVersion ([string]$latestVersion) `
                -Scope AllUsers -Force -AllowClobber -Confirm:$false -ErrorAction Stop | Out-Null
            $installSucceeded = $true
        }
        catch {
            $detail = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            if ($attempt -lt 3) {
                if ($WriteLog) { & $WriteLog "PackageManagement-Updateversuch $attempt/3 fehlgeschlagen; neuer Versuch in 5 Sekunden. Ursache: $detail" 'WARN' }
                Start-Sleep -Seconds 5
            }
            else {
                if ($WriteLog) { & $WriteLog "PackageManagement konnte für PowerShell 7 nicht aktualisiert werden; vorhandener Stand bleibt aktiv. Ursache: $detail" 'WARN' }
            }
        }
    }
    if (-not $installSucceeded) { return $true }

    $verifiedModule = Get-Module -ListAvailable -Name PackageManagement -ErrorAction SilentlyContinue |
        Where-Object { $_.Version -ge $latestVersion } |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $verifiedModule) {
        if ($WriteLog) { & $WriteLog "PackageManagement $latestVersion wurde installiert, ist aber im PowerShell-7-Modulpfad nicht auffindbar." 'WARN' }
        return $true
    }

    if ($WriteLog) { & $WriteLog "PackageManagement für PowerShell 7 aktualisiert (Version $($verifiedModule.Version)); wirksam ab dem nächsten PowerShell-7-Prozess." 'SUCCESS' }
    return $true
}

function New-WindowsUpdateNuGetProviderPayload {
    <# Beschafft den NuGet-Provider zentral online und erstellt ein temporäres Offlinepaket. #>
    param([Parameter(Mandatory)][string]$DestinationPath, [scriptblock]$WriteLog)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $providerRoot = Join-Path $DestinationPath 'NuGetProvider'
    New-Item -ItemType Directory -Path $providerRoot -Force -ErrorAction Stop | Out-Null
    $providerVersion = $null

    try {
        # Nur den klassischen OneGet-Bootstrap-Provider verwenden. Der integrierte
        # NuGet-Provider 3.0.0.1 aus PowerShell 7 ist kein Paket dieses Feeds.
        $provider = Find-PackageProvider -Name NuGet -AllVersions -ForceBootstrap -Force `
            -ErrorAction Stop -WarningAction SilentlyContinue |
            Where-Object { $_.Source -match '(?i)(cdn\.oneget\.org|onegetcdn\.azureedge\.net)/providers/nuget-\d+(\.\d+){1,3}\.package\.swidtag$' } |
            Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
        if ($provider) { $providerVersion = [string]$provider.Version }
    } catch { }

    if ($providerVersion -notmatch '^\d+(\.\d+){1,3}$') {
        # 2.8.5.208 ist die letzte von Microsoft dokumentierte Provider-Version.
        $providerVersion = '2.8.5.208'
    }

    $targetVersionPath = Join-Path $providerRoot $providerVersion
    New-Item -ItemType Directory -Path $targetVersionPath -Force -ErrorAction Stop | Out-Null
    $providerFile = Join-Path $targetVersionPath 'Microsoft.PackageManagement.NuGetProvider.dll'
    $providerUri = "https://cdn.oneget.org/providers/Microsoft.PackageManagement.NuGetProvider-$providerVersion.dll"
    try {
        Invoke-WebRequest -Uri $providerUri -OutFile $providerFile -UseBasicParsing `
            -ErrorAction Stop -WarningAction SilentlyContinue
        if (-not (Test-Path -LiteralPath $providerFile -PathType Leaf) -or (Get-Item -LiteralPath $providerFile).Length -lt 1024) {
            throw 'Der heruntergeladene NuGet-Provider ist leer oder unvollständig.'
        }
        if ($WriteLog) { & $WriteLog "NuGet-Provider $providerVersion zentral online geladen und für Offline-Übertragung vorbereitet." 'SUCCESS' }
        return [pscustomobject]@{ Root = $providerRoot; Version = $providerVersion; Source = 'Online' }
    }
    catch {
        Remove-Item -LiteralPath $targetVersionPath -Recurse -Force -ErrorAction SilentlyContinue
        $localProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_.ProviderPath -match '(?i)[\\/]PackageManagement[\\/]ProviderAssemblies[\\/]nuget[\\/]' } |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $localProvider -or -not $localProvider.ProviderPath -or
            -not (Test-Path -LiteralPath $localProvider.ProviderPath -PathType Leaf)) {
            Remove-Item -LiteralPath $providerRoot -Recurse -Force -ErrorAction SilentlyContinue
            throw "NuGet-Provider konnte online nicht geladen werden und es ist kein lokales Fallback vorhanden: $($_.Exception.Message)"
        }
        $fallbackVersion = [string]$localProvider.Version
        $fallbackPath = Join-Path $providerRoot $fallbackVersion
        New-Item -ItemType Directory -Path $fallbackPath -Force -ErrorAction Stop | Out-Null
        Copy-Item -LiteralPath $localProvider.ProviderPath -Destination (Join-Path $fallbackPath 'Microsoft.PackageManagement.NuGetProvider.dll') -Force -ErrorAction Stop
        if ($WriteLog) { & $WriteLog "NuGet-Provider online nicht erreichbar; lokale Version $fallbackVersion als Offline-Fallback vorbereitet. Ursache: $($_.Exception.Message)" 'WARN' }
        return [pscustomobject]@{ Root = $providerRoot; Version = $fallbackVersion; Source = 'Fallback' }
    }
}

function Update-NuGetProvider {
    <# Aktualisiert den NuGet-Provider im gemeinsamen Rechnerpfad auf die neueste Bootstrap-Version. #>
    param([switch]$Force, [string]$OfflineProviderPath, [scriptblock]$WriteLog)

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    $minimumVersion = [version]'2.8.5.201'
    $providerRoot = Join-Path $env:ProgramFiles 'PackageManagement\ProviderAssemblies\nuget'
    $availableProviders = @(Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue)
    $installedProvider = $availableProviders |
        Where-Object { $_.ProviderPath -like "$providerRoot\*" } |
        Sort-Object Version -Descending | Select-Object -First 1
    $latestProvider = $null

    # PowerShell 7 enthält NuGet im eigenen PackageManagement-Modul; der
    # Bootstrap-Feed stellt diesen integrierten Provider nicht als Update bereit.
    if ($PSVersionTable.PSVersion.Major -ge 7) {
        $builtInProviderRoot = Join-Path $PSHOME 'Modules\PackageManagement\coreclr\'
        $builtInProvider = $availableProviders |
            Where-Object { $_.ProviderPath -like "$builtInProviderRoot*" } |
            Sort-Object Version -Descending | Select-Object -First 1
        if ($builtInProvider -and $builtInProvider.Version -ge $minimumVersion) {
            if ($WriteLog) { & $WriteLog "NuGet ist in PowerShell $($PSVersionTable.PSVersion.Major) enthalten (Version $($builtInProvider.Version))." 'SUCCESS' }
            return $true
        }
    }

    # Das zentrale Paket wird zunächst nur gesucht. Die installierte Version
    # muss mit dem aktuellen Online-Stand verglichen werden, bevor eine Datei
    # kopiert oder der Provider importiert wird.
    $stagedProvider = $null
    if ($OfflineProviderPath -and (Test-Path -LiteralPath $OfflineProviderPath -PathType Container)) {
        $stagedProvider = Get-ChildItem -LiteralPath $OfflineProviderPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' -and
                (Test-Path -LiteralPath (Join-Path $_.FullName 'Microsoft.PackageManagement.NuGetProvider.dll') -PathType Leaf) } |
            Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    }
    $onlineInstallError = $null
    $fallbackError = $null
    try {
        # Die Suche prüft Bootstrap-Feed und PSGallery. Ein "No match" aus PSGallery
        # darf die gefundenen Bootstrap-Versionen nicht durch ErrorAction Stop verwerfen.
        $latestProvider = Find-PackageProvider -Name NuGet -AllVersions -ForceBootstrap -Force `
            -ErrorAction SilentlyContinue -WarningAction SilentlyContinue |
            Where-Object { $_.Source -match '(?i)(cdn\.oneget\.org|onegetcdn\.azureedge\.net)/providers/nuget-\d+(\.\d+){1,3}\.package\.swidtag$' } |
            Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1
    }
    catch {
        $message = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        $onlineInstallError = $message
    }

    if (-not $latestProvider) {
        if (-not $onlineInstallError) { $onlineInstallError = 'Die aktuelle Version konnte nicht aus dem Bootstrap-Feed ermittelt werden.' }
        $targetVersion = $null
    } else {
        $targetVersion = [version]$latestProvider.Version
    }

    if ($targetVersion -and $installedProvider -and $installedProvider.Version -ge $targetVersion -and -not $Force) {
        if ($WriteLog) { & $WriteLog "NuGet ist aktuell (Version $($installedProvider.Version))." 'SUCCESS' }
        return $true
    }

    # Erst wenn der Onlinevergleich eine Aktualisierung nötig macht oder der
    # Feed nicht erreichbar ist, das zentral vorbereitete Paket bereitstellen.
    $stagedVersion = if ($stagedProvider) { [version]$stagedProvider.Name } else { $null }
    if ($stagedProvider -and ($Force -or -not $installedProvider -or
            $installedProvider.Version -lt $stagedVersion) -and
        (-not $targetVersion -or $stagedVersion -ge $targetVersion)) {
        try {
            if (-not $targetVersion -or $stagedVersion -ge $targetVersion) {
                $stagedDll = Join-Path $stagedProvider.FullName 'Microsoft.PackageManagement.NuGetProvider.dll'
                $stagedTarget = Join-Path (Join-Path $providerRoot ([string]$stagedVersion)) 'Microsoft.PackageManagement.NuGetProvider.dll'
                if (-not (Test-Path -LiteralPath $stagedTarget -PathType Leaf)) {
                    New-Item -ItemType Directory -Path (Split-Path -Parent $stagedTarget) -Force -ErrorAction Stop | Out-Null
                    Copy-Item -LiteralPath $stagedDll -Destination $stagedTarget -Force -ErrorAction Stop
                }
                $null = Import-PackageProvider -Name NuGet -RequiredVersion ([string]$stagedVersion) -Force -ErrorAction Stop -WarningAction SilentlyContinue
                $installedProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction Stop |
                    Where-Object { $_.ProviderPath -like "$providerRoot\*" -and $_.Version -ge $stagedVersion } |
                    Sort-Object Version -Descending | Select-Object -First 1
                if (-not $installedProvider) { throw "NuGet $stagedVersion wurde nach der Offlinebereitstellung nicht erkannt." }
                if ($WriteLog) { & $WriteLog "NuGet-Provider $($installedProvider.Version) aus dem zentral vorbereiteten Paket bereitgestellt; der Zielserver benötigte keinen Onlinezugriff." 'SUCCESS' }
                return $true
            }
        } catch {
            $stagedProviderError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            if ($WriteLog) { & $WriteLog "Zentrales NuGet-Offlinepaket konnte nicht installiert werden; versuche den Onlineweg. Ursache: $stagedProviderError" 'WARN' }
        }
    }

    if ($targetVersion) {
        $oldVersion = if ($installedProvider) { [string]$installedProvider.Version } else { 'nicht installiert' }
        if ($WriteLog) { & $WriteLog "Aktualisiere NuGet: $oldVersion -> $targetVersion." 'UPDATE' }
        try {
            Install-PackageProvider -Name NuGet -RequiredVersion ([string]$targetVersion) -Scope AllUsers `
                -Force -ForceBootstrap -Confirm:$false -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
            $installedProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
                Where-Object { $_.ProviderPath -like "$providerRoot\*" -and $_.Version -ge $targetVersion } |
                Sort-Object Version -Descending | Select-Object -First 1
            if (-not $installedProvider) { throw "NuGet $targetVersion wurde nicht im Rechnerpfad gefunden." }
            if ($WriteLog) { & $WriteLog "NuGet erfolgreich aktualisiert (Version $($installedProvider.Version))." 'SUCCESS' }
            return $true
        } catch {
            $onlineInstallError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        }
    }

    # Der Feed/Bootstrap ist ausgefallen: bevorzugt das zentral übertragene Paket,
    # erst danach den bereits auf diesem Rechner vorhandenen Provider.
    $fallbackVersionDirectory = $null
    if ($OfflineProviderPath -and (Test-Path -LiteralPath $OfflineProviderPath -PathType Container)) {
        $fallbackVersionDirectory = Get-ChildItem -LiteralPath $OfflineProviderPath -Directory -ErrorAction SilentlyContinue |
            Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'Microsoft.PackageManagement.NuGetProvider.dll') -PathType Leaf } |
            Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
    }
    $fallbackDll = if ($fallbackVersionDirectory) { Join-Path $fallbackVersionDirectory.FullName 'Microsoft.PackageManagement.NuGetProvider.dll' } else { $null }
    $fallbackVersion = if ($fallbackVersionDirectory) { [version]$fallbackVersionDirectory.Name } else { $null }
    if (-not $fallbackDll -and $installedProvider -and $installedProvider.ProviderPath -and (Test-Path -LiteralPath $installedProvider.ProviderPath -PathType Leaf)) {
        $fallbackDll = $installedProvider.ProviderPath
        $fallbackVersion = [version]$installedProvider.Version
    }
    if ($fallbackDll -and $fallbackVersion -ge $minimumVersion) {
        try {
            $fallbackTarget = Join-Path (Join-Path $providerRoot ([string]$fallbackVersion)) 'Microsoft.PackageManagement.NuGetProvider.dll'
            New-Item -ItemType Directory -Path (Split-Path -Parent $fallbackTarget) -Force -ErrorAction Stop | Out-Null
            if ([IO.Path]::GetFullPath($fallbackDll) -ne [IO.Path]::GetFullPath($fallbackTarget)) {
                Copy-Item -LiteralPath $fallbackDll -Destination $fallbackTarget -Force -ErrorAction Stop
            }
            $installedProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction Stop |
                Where-Object { $_.ProviderPath -like "$providerRoot\*" -and $_.Version -ge $fallbackVersion } |
                Sort-Object Version -Descending | Select-Object -First 1
            if (-not $installedProvider) { throw "NuGet $fallbackVersion wurde aus dem Offlinepaket nicht geladen." }
            if ($WriteLog) { & $WriteLog "NuGet aus Offlinepaket bereitgestellt (Version $($installedProvider.Version)); Onlineabruf war nicht verfügbar." 'SUCCESS' }
            return $true
        } catch {
            $fallbackError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
        }
    }

    $reason = if ($onlineInstallError) { " Onlinefehler: $onlineInstallError" } else { '' }
    if ($fallbackError) { $reason += " Offlinefehler: $fallbackError" }
    if ($WriteLog) { & $WriteLog "NuGet-Provider konnte weder online aktualisiert noch offline bereitgestellt werden.$reason" 'WARN' }
    return [bool]($installedProvider -and $installedProvider.Version -ge $minimumVersion)
}
