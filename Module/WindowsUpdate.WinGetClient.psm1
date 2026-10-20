# Fachmodul: WindowsUpdate.WinGetClient
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Update-WinGetClientModule {
    <# Installiert/aktualisiert Microsoft.WinGet.Client maschinenweit für Windows PowerShell 5.1. #>
    [CmdletBinding()]
    param(
        [scriptblock]$WriteLog,
        [string]$OfflineModulePath,
        [string]$ComputerName,
        $AuthInfo
    )

    if (-not [string]::IsNullOrWhiteSpace($ComputerName) -and $ComputerName -ine $env:COMPUTERNAME) {
        $galleryVersion = Get-WindowsUpdateGalleryModuleVersion -Name 'Microsoft.WinGet.Client'
        if ($galleryVersion) {
            $versionSession = $null
            try {
                $sessionParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo -OperationTimeoutSeconds 1800
                $versionSession = New-PSSession @sessionParameters
                $installedVersion = Invoke-Command -Session $versionSession -ScriptBlock {
                    $root = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Microsoft.WinGet.Client'
                    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
                        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
                } -ErrorAction Stop
                if ($installedVersion -and [version]$installedVersion -ge $galleryVersion) {
                    Write-PSWindowsUpdateModuleLog $WriteLog "[$ComputerName] Microsoft.WinGet.Client ist aktuell (Version $installedVersion); kein Pakettransfer erforderlich." 'SUCCESS'
                    return $true
                }
            } catch {
                Write-PSWindowsUpdateModuleLog $WriteLog "[$ComputerName] Versionsprüfung vor dem Pakettransfer nicht möglich; führe vollständige Modulprüfung aus. Ursache: $($_.Exception.Message)" 'INFO'
            } finally {
                if ($versionSession) { Remove-PSSession -Session $versionSession -ErrorAction SilentlyContinue }
            }
        }
    } else {
        $galleryVersion = Get-WindowsUpdateGalleryModuleVersion -Name 'Microsoft.WinGet.Client'
        if ($galleryVersion) {
            $moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\Microsoft.WinGet.Client'
            $installedVersion = Get-ChildItem -LiteralPath $moduleRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
                Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
            if ($installedVersion -and [version]$installedVersion -ge $galleryVersion) {
                Write-PSWindowsUpdateModuleLog $WriteLog "Microsoft.WinGet.Client ist aktuell (Version $installedVersion); kein Paketdownload erforderlich." 'SUCCESS'
                return $true
            }
        }
    }

    $modulePayload = $null
    try {
        $modulePayload = New-WindowsUpdateModulePayload -ModuleName 'Microsoft.WinGet.Client' `
            -OfflineModulePath $OfflineModulePath -WriteLog $WriteLog
        $OfflineModulePath = $modulePayload.Root
    }
    catch {
        Write-PSWindowsUpdateModuleLog $WriteLog "Microsoft.WinGet.Client konnte online oder aus einem Offlinepaket nicht beschafft werden: $($_.Exception.Message)" 'WARN'
        return $false
    }

    $worker = {
        param([string]$OfflineModulePath)
        $ErrorActionPreference = 'Stop'
        $ProgressPreference = 'SilentlyContinue'
        $logs = [System.Collections.Generic.List[object]]::new()

        try {
            $childScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
try {
    # Isoliere Windows PowerShell von an den Kindprozess vererbten PS7-Modulpfaden.
    $windowsPowerShellModulePaths = @(
        (Join-Path $HOME 'Documents\WindowsPowerShell\Modules'),
        (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
        (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules')
    )
    if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
        $windowsPowerShellModulePaths += Join-Path ${env:ProgramFiles(x86)} 'WindowsPowerShell\Modules'
    }
    $env:PSModulePath = ($windowsPowerShellModulePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) -join ';'
    $offlinePathEncoded = '__OFFLINE_MODULE_PATH__'
    $offlineModulePath = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($offlinePathEncoded))
    if ($offlineModulePath -and (Test-Path -LiteralPath $offlineModulePath -PathType Container)) {
        $offlineClientRoot = Join-Path $offlineModulePath 'Microsoft.WinGet.Client'
        $offlineClientVersions = @(Get-ChildItem -LiteralPath $offlineClientRoot -Directory -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^\d+(\.\d+)*$' } |
            Sort-Object { [version]$_.Name } -Descending)
        if ($offlineClientVersions.Count -gt 0) {
            $offlineModules = @(Get-ChildItem -LiteralPath $offlineModulePath -Directory -ErrorAction SilentlyContinue)
            $moduleRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'
            foreach ($offlineModule in $offlineModules) {
                $versionFolders = @(Get-ChildItem -LiteralPath $offlineModule.FullName -Directory -ErrorAction SilentlyContinue |
                    Where-Object { $_.Name -match '^\d+(\.\d+)*$' })
                foreach ($versionFolder in $versionFolders) {
                    $targetVersion = Join-Path (Join-Path $moduleRoot $offlineModule.Name) $versionFolder.Name
                    if (-not (Test-Path -LiteralPath $targetVersion -PathType Container)) {
                        New-Item -ItemType Directory -Path (Split-Path -Parent $targetVersion) -Force -ErrorAction Stop | Out-Null
                        Copy-Item -LiteralPath $versionFolder.FullName -Destination $targetVersion -Recurse -Force -ErrorAction Stop
                    }
                }
            }
            $stagedVersion = [version]$offlineClientVersions[0].Name
            $installedOffline = Get-Module -ListAvailable -Name Microsoft.WinGet.Client -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
            if (-not $installedOffline -or $installedOffline.Version -lt $stagedVersion) {
                throw "Microsoft.WinGet.Client $stagedVersion wurde bereitgestellt, ist aber nach der Kopie nicht auffindbar."
            }
            $state = if ($installedOffline.Version -gt $stagedVersion) { 'vorhandene neuere Version beibehalten' } else { 'aus Offline-Paket bereitgestellt/geprüft' }
            "__WINGETCLIENT__SUCCESS`t$($installedOffline.Version)`t$state"
            exit 0
        }
    }
    throw 'Kein gültiges zentral vorbereitetes Offlinepaket für Microsoft.WinGet.Client vorhanden; lokaler NuGet-/PSGallery-Bootstrap wird nicht versucht.'
}
catch {
    $detail = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
    $detail += " PSModulePath=$env:PSModulePath"
    $detailPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($detail))
    "__WINGETCLIENT__ERROR`t$detailPayload"
    exit 1
}
'@
            $offlinePathEncoded = if ([string]::IsNullOrWhiteSpace($OfflineModulePath)) { '' } else {
                [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($OfflineModulePath))
            }
            $childScript = $childScript.Replace('__OFFLINE_MODULE_PATH__', $offlinePathEncoded)
            $encodedCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))
            $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) { throw 'Windows PowerShell 5.1 wurde nicht gefunden.' }
            $workerRoot = Join-Path ([IO.Path]::GetTempPath()) ('WinGetClientModule-{0}' -f [guid]::NewGuid().ToString('N'))
            $stdoutPath = Join-Path $workerRoot 'stdout.txt'
            $stderrPath = Join-Path $workerRoot 'stderr.txt'
            $childExitCode = -1
            $childOutput = @()
            try {
                New-Item -ItemType Directory -Path $workerRoot -Force -ErrorAction Stop | Out-Null
                $workerProcess = Start-Process -FilePath $windowsPowerShell `
                    -ArgumentList @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedCommand) `
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
            $resultLine = @($childOutput | Where-Object { $_ -match '^__WINGETCLIENT__(SUCCESS|ERROR)\t' } | Select-Object -Last 1)
            if ($resultLine.Count -gt 0 -and $resultLine[0] -match '^__WINGETCLIENT__SUCCESS\t(?<Version>[^\t]+)\t(?<State>.+)$') {
                if ($Matches.State -eq 'aktuell') { $logs.Add([pscustomobject]@{ Type = 'Log'; Message = "Microsoft.WinGet.Client ist aktuell (Version $($Matches.Version))."; Level = 'SUCCESS' }) }
                else { $logs.Add([pscustomobject]@{ Type = 'Log'; Message = "Microsoft.WinGet.Client bereit (Version $($Matches.Version); $($Matches.State))."; Level = 'SUCCESS' }) }
            }
            else {
                if ($resultLine.Count -gt 0 -and $resultLine[0] -match '^__WINGETCLIENT__ERROR\t(?<Detail>[A-Za-z0-9+/=]+)$') {
                    try { $detail = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($Matches.Detail)) }
                    catch { $detail = 'Fehlerdetails des Modul-Unterprozesses waren nicht lesbar.' }
                } else {
                    $detail = ($childOutput -join ' ' -replace '\s+', ' ').Trim()
                }
                if ($detail.Length -gt 350) { $detail = $detail.Substring(0, 347) + '...' }
                throw "Microsoft.WinGet.Client konnte nicht installiert/aktualisiert werden (Exitcode $childExitCode)$(if ($detail) { ": $detail" })."
            }
        }
        catch {
            $detail = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            $logs.Add([pscustomobject]@{ Type = 'Log'; Message = "WinGet-Client-Modulpflege fehlgeschlagen: $detail"; Level = 'WARN' })
        }
        return @($logs)
    }

    $session = $null
    $remotePayloadPath = $null
    try {
        if ([string]::IsNullOrWhiteSpace($ComputerName) -or $ComputerName -ieq $env:COMPUTERNAME -or $ComputerName -ieq 'localhost') {
            $results = @(& $worker $OfflineModulePath)
        } else {
            $sessionParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo -OperationTimeoutSeconds 1800
            $session = New-PSSession @sessionParameters
            $remotePayloadPath = Join-Path ([IO.Path]::GetTempPath()) ('WinGetClientPayload-{0}' -f [guid]::NewGuid().ToString('N'))
            Invoke-Command -Session $session -ScriptBlock {
                param($Path)
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
            } -ArgumentList $remotePayloadPath -ErrorAction Stop
            Copy-Item -Path (Join-Path $OfflineModulePath '*') -Destination $remotePayloadPath `
                -ToSession $session -Recurse -Force -ErrorAction Stop
            $results = @(Invoke-Command -Session $session -ScriptBlock $worker -ArgumentList $remotePayloadPath -ErrorAction Stop)
        }
    }
    catch {
        $destination = if ($ComputerName) { " auf $ComputerName" } else { '' }
        Write-PSWindowsUpdateModuleLog $WriteLog "WinGet-Client-Modulpflege$destination fehlgeschlagen: $($_.Exception.Message)" 'WARN'
        return $false
    }
    finally {
        if ($session -and $remotePayloadPath) {
            Invoke-Command -Session $session -ScriptBlock {
                param($Path)
                Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
            } -ArgumentList $remotePayloadPath -ErrorAction SilentlyContinue
        }
        if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
        if ($modulePayload -and $modulePayload.Root) {
            Remove-Item -LiteralPath $modulePayload.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
    }

    foreach ($entry in $results) {
        if ($entry -and $entry.Type -eq 'Log') {
            $prefix = if ($ComputerName -and $ComputerName -ine $env:COMPUTERNAME) { "[$ComputerName] " } else { '' }
            Write-PSWindowsUpdateModuleLog $WriteLog ($prefix + [string]$entry.Message) ([string]$entry.Level)
        }
    }
    return -not (@($results | Where-Object { $_.Type -eq 'Log' -and $_.Level -eq 'WARN' }).Count -gt 0)
}

function Register-WindowsUpdateWinGetAppInstallerForCurrentUser {
    <# Registriert App Installer für den aktuellen Benutzer und beschafft fehlende GitHub-Abhängigkeiten. #>
    [CmdletBinding()]
    param()

    # Die AppX-/WinGet-COM-Aktivierung schlägt bei erhöhtem PowerShell 7 fehl;
    # deshalb läuft die Registrierung dort wie bisher in Windows PowerShell 5.1.
    # Fehlen dem Zielprofil AppX-Frameworks, wird das offizielle GitHub-Release
    # samt x64-Abhängigkeiten installiert. Add-AppxPackage prüft Signatur und
    # Paketintegrität beim Bereitstellen.
    $registrationWorker = {
        $ErrorActionPreference = 'Stop'
        $allPackages = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) })
        $currentPackages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) })
        $latestPackage = @($allPackages + $currentPackages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
        if ($latestPackage.Count -eq 0) {
            return [pscustomobject]@{ AppInstallerVersion = ''; RegistrationChanged = $false; InstalledFromGitHub = $false }
        }

        $targetVersion = [version]$latestPackage[0].Version
        $currentPackage = @($currentPackages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
        $currentVersion = if ($currentPackage.Count -gt 0) { [version]$currentPackage[0].Version } else { [version]'0.0' }
        $registrationChanged = $currentVersion -lt $targetVersion
        $installedFromGitHub = $false
        if ($registrationChanged) {
            $manifestPath = Join-Path ([string]$latestPackage[0].InstallLocation) 'AppxManifest.xml'
            if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                throw "App Installer $targetVersion ist vorhanden, aber sein Manifest fehlt: $manifestPath"
            }
            try {
                Add-AppxPackage -Path $manifestPath -Register -DisableDevelopmentMode -ErrorAction Stop | Out-Null
            }
            catch {
                $registrationError = $_
                if ($registrationError.Exception.Message -notmatch '(?i)Microsoft\.WindowsAppRuntime|Framework.*nicht gefunden|0x80073CF3|0x80073D19') { throw }

                $payloadRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-WinGet-GitHub-' + [guid]::NewGuid().ToString('N'))
                $extractRoot = Join-Path $payloadRoot 'Dependencies'
                $bundlePath = Join-Path $payloadRoot 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
                $dependenciesZip = Join-Path $payloadRoot 'DesktopAppInstaller_Dependencies.zip'
                try {
                    New-Item -Path $extractRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    $releaseBase = 'https://github.com/microsoft/winget-cli/releases/latest/download'
                    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                    Invoke-WebRequest -Uri "$releaseBase/Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle" `
                        -OutFile $bundlePath -UseBasicParsing -ErrorAction Stop
                    Invoke-WebRequest -Uri "$releaseBase/DesktopAppInstaller_Dependencies.zip" `
                        -OutFile $dependenciesZip -UseBasicParsing -ErrorAction Stop
                    if ((Get-Item -LiteralPath $bundlePath).Length -le 0 -or (Get-Item -LiteralPath $dependenciesZip).Length -le 0) {
                        throw 'Ein oder mehrere GitHub-Releasepakete sind leer.'
                    }
                    Expand-Archive -LiteralPath $dependenciesZip -DestinationPath $extractRoot -Force -ErrorAction Stop
                    $dependencyPackages = @(Get-ChildItem -LiteralPath $extractRoot -Recurse -File -ErrorAction Stop |
                        Where-Object {
                            $_.Extension -in '.appx', '.msix', '.appxbundle', '.msixbundle' -and
                            $_.FullName -match '(?i)(x64|amd64|neutral)'
                        } | Sort-Object FullName | ForEach-Object FullName)
                    if ($dependencyPackages.Count -eq 0) {
                        throw 'Das GitHub-Abhängigkeitenpaket enthält keine x64-/neutralen AppX-Abhängigkeiten.'
                    }
                    Add-AppxPackage -Path $bundlePath -DependencyPath $dependencyPackages -ForceUpdateFromAnyVersion -ErrorAction Stop | Out-Null
                    $installedFromGitHub = $true
                    $registrationChanged = $true
                }
                catch {
                    throw "App Installer konnte nicht aus dem offiziellen GitHub-Release einschließlich Abhängigkeiten bereitgestellt werden. Registrierungsfehler: $($registrationError.Exception.Message) GitHub-Fehler: $($_.Exception.Message)"
                }
                finally {
                    Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
        }

        $registeredPackage = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
            Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
        if ($registeredPackage.Count -eq 0 -or [string]$registeredPackage[0].Status -ne 'Ok') {
            throw "App Installer $targetVersion wurde für den aktuellen Benutzer nicht erfolgreich registriert."
        }
        [pscustomobject]@{
            AppInstallerVersion = [string]$registeredPackage[0].Version
            RegistrationChanged = $registrationChanged
            InstalledFromGitHub = $installedFromGitHub
        }
    }

    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $registrationResult = @(Invoke-WindowsUpdateLocalCommandWithTimeout -ScriptBlock $registrationWorker `
            -TimeoutSeconds 900 -OperationName 'App-Installer-Bereitstellung aus dem WinGet-GitHub-Release')
        if ($registrationResult.Count -eq 0) { throw 'Windows PowerShell 5.1 lieferte kein Ergebnis der App-Installer-Bereitstellung.' }
        return $registrationResult[-1]
    }
    & $registrationWorker
}

function Repair-WindowsUpdateWinGetPackageManager {
    <# Repariert WinGet und registriert die bereitgestellte App-Installer-Version für den aktuellen Benutzer. #>
    [CmdletBinding()]
    param()

    # Repair-WinGetPackageManager verwendet dieselbe WinRT/COM-Schnittstelle
    # wie Get-WinGetPackage. In erhöhtem PS7 schlägt deren Aktivierung mit
    # 0x800706BA fehl; der PS5.1-Prozess läuft mit demselben Benutzer-Token.
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $repairWorker = {
            $ErrorActionPreference = 'Stop'
            Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
            $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
            Assert-WinGetPackageManager -ErrorAction Stop | Out-Null
            [pscustomobject]@{ WinGetVersion = [string](Get-WinGetVersion -ErrorAction Stop) }
        }
        $repairResult = @(Invoke-WindowsUpdateLocalCommandWithTimeout -ScriptBlock $repairWorker `
            -TimeoutSeconds 1800 -OperationName 'WinGet-Reparatur über Microsoft.WinGet.Client')
        if ($repairResult.Count -eq 0) { throw 'Windows PowerShell 5.1 lieferte kein Ergebnis der WinGet-Reparatur.' }
        $registration = Register-WindowsUpdateWinGetAppInstallerForCurrentUser
        return [pscustomobject]@{
            WinGetVersion = [string]$repairResult[-1].WinGetVersion
            AppInstallerVersion = [string]$registration.AppInstallerVersion
            RegistrationChanged = [bool]$registration.RegistrationChanged
        }
    }

    $ErrorActionPreference = 'Stop'
    Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
    $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
    Assert-WinGetPackageManager -ErrorAction Stop | Out-Null
    $registration = Register-WindowsUpdateWinGetAppInstallerForCurrentUser
    [pscustomobject]@{
        WinGetVersion = [string](Get-WinGetVersion -ErrorAction Stop)
        AppInstallerVersion = [string]$registration.AppInstallerVersion
        RegistrationChanged = [bool]$registration.RegistrationChanged
    }
}
