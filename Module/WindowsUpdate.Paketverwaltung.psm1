Warning: truncated output (original token count: 66680)
Total output lines: 3768

# Fachmodul: WindowsUpdate.Paketverwaltung
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Get-WindowsUpdateWinGetInstallScriptPayload {
    <# Prüft zuerst den lokalen Cache, vergleicht ihn mit der signierten GitHub-Version und aktualisiert ihn nur bei Bedarf. #>
    [CmdletBinding()]
    param()

    $cacheRoot = Join-Path $env:LOCALAPPDATA 'WindowsUpdateAdm\Cache'
    $cachePath = Join-Path $cacheRoot 'winget-install.ps1'
    $downloadPath = Join-Path ([IO.Path]::GetTempPath()) ('winget-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    $downloadFailure = $null
    $selectedPath = $null
    $source = ''
    $cacheStatus = ''
    $cacheValid = $false
    $cachedVersion = $null
    $cachedHash = ''

    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
        try {
            $cacheSignature = Get-AuthenticodeSignature -FilePath $cachePath -ErrorAction Stop
            if ($cacheSignature.Status -eq [Management.Automation.SignatureStatus]::Valid) {
                $cachedText = [IO.File]::ReadAllText($cachePath)
                $cachedVersionMatch = [regex]::Match($cachedText, '(?im)^\s*\$CurrentVersion\s*=\s*["''](?<Version>\d+(?:\.\d+){1,3})["'']')
                if ($cachedVersionMatch.Success) {
                    $cachedVersion = [version]$cachedVersionMatch.Groups['Version'].Value
                    $cachedHash = (Get-FileHash -LiteralPath $cachePath -Algorithm SHA256 -ErrorAction Stop).Hash
                    $cacheValid = $true
                }
            }
        }
        catch {
            $cacheValid = $false
            $cachedVersion = $null
            $cachedHash = ''
        }
    }

    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri 'https://github.com/asheroto/winget-install/releases/latest/download/winget-install.ps1' -OutFile $downloadPath -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        if ((Get-Item -LiteralPath $downloadPath -ErrorAction Stop).Length -le 0) {
            throw 'GitHub lieferte eine leere Installationsskriptdatei.'
        }
        $signature = Get-AuthenticodeSignature -FilePath $downloadPath -ErrorAction Stop
        if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
            throw "GitHub-Installationsskript hat keine gültige Authenticode-Signatur (Status: $($signature.Status))."
        }
        $downloadedText = [IO.File]::ReadAllText($downloadPath)
        $downloadedVersionMatch = [regex]::Match($downloadedText, '(?im)^\s*\$CurrentVersion\s*=\s*["''](?<Version>\d+(?:\.\d+){1,3})["'']')
        if (-not $downloadedVersionMatch.Success) {
            throw 'Die Version des signierten GitHub-Installationsskripts konnte nicht ausgelesen werden.'
        }
        $downloadedVersion = [version]$downloadedVersionMatch.Groups['Version'].Value
        $downloadedHash = (Get-FileHash -LiteralPath $downloadPath -Algorithm SHA256 -ErrorAction Stop).Hash

        if ($cacheValid -and $cachedVersion -gt $downloadedVersion) {
            $selectedPath = $cachePath
            $signature = Get-AuthenticodeSignature -FilePath $cachePath -ErrorAction Stop
            $source = 'signierter lokaler Cache (neuer als die Onlineversion)'
            $cacheStatus = "Cacheversion $cachedVersion ist neuer als Onlineversion $downloadedVersion; Cache beibehalten."
        }
        elseif ($cacheValid -and $cachedVersion -eq $downloadedVersion -and $cachedHash -eq $downloadedHash) {
            $selectedPath = $cachePath
            $signature = Get-AuthenticodeSignature -FilePath $cachePath -ErrorAction Stop
            $source = 'signierter lokaler Cache (Onlineversion geprüft; unverändert)'
            $cacheStatus = "Cacheversion $cachedVersion ist aktuell; keine Cacheaktualisierung erforderlich."
        }
        else {
            $cacheStatus = if (-not $cacheValid) {
                "Signierte Onlineversion $downloadedVersion wird erstmals im Cache abgelegt."
            } elseif ($cachedVersion -lt $downloadedVersion) {
                "Cache wird von Version $cachedVersion auf $downloadedVersion aktualisiert."
            } else {
                "Signierter Cacheinhalt wird bei unveränderter Version $downloadedVersion aktualisiert."
            }
            $selectedPath = $downloadPath
            $source = 'GitHub-Release'
            try {
                New-Item -Path $cacheRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                $stagingPath = $cachePath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
                try {
                    Copy-Item -LiteralPath $downloadPath -Destination $stagingPath -Force -ErrorAction Stop
                    if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
                        [IO.File]::Replace($stagingPath, $cachePath, $null)
                    } else {
                        Move-Item -LiteralPath $stagingPath -Destination $cachePath -Force -ErrorAction Stop
                    }
                }
                finally {
                    if (Test-Path -LiteralPath $stagingPath -PathType Leaf) {
                        Remove-Item -LiteralPath $stagingPath -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            catch {
                # Die verifizierte Onlinekopie bleibt nutzbar, auch wenn der Cache
                # auf dem Verwaltungsserver nicht aktualisiert werden kann.
                $cacheStatus += " Cache konnte nicht aktualisiert werden: $($_.Exception.Message)"
            }
        }
    }
    catch {
        $downloadFailure = $_.Exception.Message
        if ($cacheValid) {
            $selectedPath = $cachePath
            $signature = Get-AuthenticodeSignature -FilePath $cachePath -ErrorAction Stop
            $source = 'signierter lokaler Cache (GitHub nicht erreichbar)'
            $cacheStatus = "GitHub-Prüfung fehlgeschlagen; gültige Cacheversion $cachedVersion wird weiterverwendet."
        }
        if (-not $selectedPath) {
            throw "winget-install.ps1 konnte nicht von GitHub bezogen werden und es gibt keine gültige lokale Kopie. GitHub: $downloadFailure"
        }
    }
    finally {
        if ($selectedPath -ne $downloadPath -and (Test-Path -LiteralPath $downloadPath -PathType Leaf)) {
            Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
        }
    }

    $scriptText = [IO.File]::ReadAllText($selectedPath)
    $versionMatch = [regex]::Match($scriptText, '(?im)^\s*\$CurrentVersion\s*=\s*["''](?<Version>\d+(?:\.\d+){1,3})["'']')
    if (-not $versionMatch.Success) {
        throw "Die Version des signierten winget-install.ps1 aus $source konnte nicht ausgelesen werden."
    }
    $bytes = [IO.File]::ReadAllBytes($selectedPath)
    $payload = [pscustomobject]@{
        Version = $versionMatch.Groups['Version'].Value
        Source = $source
        CacheStatus = $cacheStatus
        Signer = [string]$signature.SignerCertificate.Subject
        Sha256 = (Get-FileHash -LiteralPath $selectedPath -Algorithm SHA256 -ErrorAction Stop).Hash
        ContentBase64 = [Convert]::ToBase64String($bytes)
        DownloadFailure = $downloadFailure
    }
    if ($selectedPath -eq $downloadPath -and (Test-Path -LiteralPath $downloadPath -PathType Leaf)) {
        Remove-Item -LiteralPath $downloadPath -Force -ErrorAction SilentlyContinue
    }
    $payload
}

function Invoke-WindowsUpdatePackageWorker {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [bool]$IsLocalTarget = $false,
        [switch]$NoTimeout,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [Parameter(Mandatory)][string]$OperationName,
        [scriptblock]$WriteLog
    )

    # Lokale Paketmanager-Prüfungen liefen zuvor in einem versteckten
    # Windows-PowerShell-Unterprozess. WinGet scheitert dort mit
    # 0x800706BA, während derselbe Benutzer und dieselbe Abfrage über
    # Loopback-WinRM funktionieren. Deshalb verwenden lokale und entfernte
    # Ziele denselben Remoting-Pfad.
    $workerComputerName = if ($IsLocalTarget) { $env:COMPUTERNAME } else { $ComputerName }

    if ($NoTimeout) {
        $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $workerComputerName -AuthInfo $AuthInfo
        $invokeParameters.ScriptBlock = $ScriptBlock
        if ($ArgumentList.Count -gt 0) { $invokeParameters.ArgumentList = $ArgumentList }
        return @(Invoke-Command @invokeParameters)
    }

    return @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $workerComputerName -AuthInfo $AuthInfo `
        -ScriptBlock $ScriptBlock -ArgumentList $ArgumentList -TimeoutSeconds $TimeoutSeconds -OperationName $OperationName -WriteLog $WriteLog)
}

function Resolve-WindowsUpdateJeaWinGetResults {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo
    )

    $resolved = @()
    foreach ($item in $Results) {
        $requestProperty = if ($item) { $item.PSObject.Properties['JeaUpgradeRequest'] } else { $null }
        if (-not $requestProperty -or -not $requestProperty.Value) {
            $resolved += $item
            continue
        }

        $request = $requestProperty.Value
        $package = $request.Package
        $packageName = [string]$package.Name
        $packageId = [string]$package.Id
        $source = [string]$package.Source
        $displayName = $packageName
        $updateOutput = ''
        $exitCode = 1
        $success = $false
        try {
            $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName `
                -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -OpenTimeoutSeconds 30 -OperationTimeoutSeconds 5400
            $invokeParameters.ScriptBlock = {
                param([string]$Id, [string]$Source)
                Update-WindowsUpdateAdmWinGetPackage -Id $Id -Source $Source -ErrorAction Stop
            }
            $invokeParameters.ArgumentList = @($packageId, $source)
            $update = @(Invoke-Command @invokeParameters | Select-Object -Last 1)
            if ($update.Count -eq 0) { throw "JEA lieferte kein WinGet-Ergebnis für '$packageId'." }
            $status = [string]$update[0].Status
            $installerCode = [string]$update[0].InstallerErrorCode
            $extendedCode = [string]$update[0].ExtendedErrorCode
            $success = $status -eq 'Ok' -and $installerCode -in @('', '0') -and $extendedCode -in @('', '0')
            $exitCode = if ($success) { 0 } else { 1 }
            $updateOutput = "JEA-Update-WinGetPackage: Status=$status; InstallerErrorCode=$installerCode; ExtendedErrorCode=$extendedCode; RebootRequired=$([bool]$update[0].RebootRequired)"
            if ($update[0].PSObject.Properties['Output']) { $updateOutput += [Environment]::NewLine + [string]$update[0].Output }
        }
        catch {
            $updateOutput = [string]$_.Exception.Message
            if ($updateOutput.Length -gt 1200) { $updateOutput = $updateOutput.Substring(0, 1197) + '...' }
        }

        $resolved += [pscustomobject]@{
            Manager = 'Winget'; Available = $true; Success = $success; Skipped = $false
            SkipReason = ''; ExitCode = $exitCode; Packages = @($package)
            AvailableOutput = [string]$request.AvailableOutput; ActionOutput = $updateOutput
            DiagnosticOutput = if ($success) { '' } else { $updateOutput }
            RequiresManualAction = -not $success
            ErrorSummary = if ($success) { '' } else { "WinGet-Update für '$displayName' [$packageId] über den eingeschränkten JEA-Endpunkt fehlgeschlagen; manuelle Prüfung erforderlich." }
        }
    }
    return @($resolved)
}

function Invoke-WindowsUpdateJeaWinGetClientRepair {
    param([Parameter(Mandatory)][string]$ComputerName, $AuthInfo, [ValidateRange(1,3600)][int]$TimeoutSeconds = 1800)

    $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName `
        -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -OpenTimeoutSeconds 30 -OperationTimeoutSeconds 1800
    $invokeParameters.ScriptBlock = { Invoke-WindowsUpdateAdmWinGetMaintenance -Action ClientRepair -ErrorAction Stop }
    $results = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -ScriptBlock $invokeParameters.ScriptBlock -TimeoutSeconds $TimeoutSeconds -OperationName "WinGet-Clientreparatur auf $ComputerName" | Select-Object -Last 1)
    if ($results.Count -eq 0 -or -not [bool]$results[0].Success) {
        $details = if ($results.Count -gt 0) { [string]$results[0].Output } else { 'JEA lieferte keine strukturierte Reparaturrückgabe.' }
        throw "WinGet-Client-Reparatur über JEA fehlgeschlagen. $details"
    }
    return $results[0]
}

function Resolve-WindowsUpdateJeaChocolateyResults {
    param(
        [Parameter(Mandatory)][object[]]$Results,
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo
    )

    $resolved = @()
    foreach ($item in $Results) {
        $queryRequestProperty = if ($item) { $item.PSObject.Properties['JeaChocolateyQueryRequest'] } else { $null }
        if ($queryRequestProperty -and $queryRequestProperty.Value) {
            $mode = [string]$queryRequestProperty.Value.Mode
            $availableOutput = ''
            $queryExitCode = 1
            try {
                $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName `
                    -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -OpenTimeoutSeconds 30 -OperationTimeoutSeconds 1800
                $invokeParameters.ScriptBlock = { Get-WindowsUpdateAdmChocolateyOutdated -ErrorAction Stop }
                $queryResult = @(Invoke-Command @invokeParameters | Select-Object -Last 1)
                if ($queryResult.Count -eq 0) { throw 'JEA lieferte kein Chocolatey-Abfrageergebnis.' }
                $availableOutput = [string]$queryResult[0].Output
                $queryExitCode = [int]$queryResult[0].ExitCode
                if ($queryExitCode -eq 9009) {
                    $resolved += [pscustomobject]@{
                        Manager='Chocolatey'; Available=$false; Success=$true; Skipped=$true
                        SkipReason='Chocolatey ist nicht installiert.'; ExitCode=9009
                        Packages=@(); AvailableOutput=''; ActionOutput=''
                    }
                    continue
                }
                if (-not [bool]$queryResult[0].Success) { throw "Chocolatey-Abfrage über JEA endete mit Exitcode $queryExitCode. $availableOutput" }
            } catch {
                $resolved += [pscustomobject]@{
                    Manager='Chocolatey'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$queryExitCode
                    Packages=@(); AvailableOutput=$availableOutput; ActionOutput='Chocolatey-Abfrage über JEA fehlgeschlagen.'
                    DiagnosticOutput=$_.Exception.ToString()
                }
                continue
            }
            $queriedPackages = @($availableOutput -split "`r?`n" | Where-Object { $_ -match '^[^|]+\|[^|]+\|[^|]+' } | ForEach-Object {
                $fields = @($_ -split '\|', 4)
                if ($fields.Count -ge 3) {
                    $installedVersion = ([string]$fields[1]).Trim()
                    $availableVersion = ([string]$fields[2]).Trim()
                    if (-not [string]::Equals($installedVersion, $availableVersion, [StringComparison]::OrdinalIgnoreCase)) {
                        [pscustomobject]@{
                            Name=([string]$fields[0]).Trim(); Id=([string]$fields[0]).Trim()
                            InstalledVersion=$installedVersion; AvailableVersion=$availableVersion; Source='chocolatey'
                        }
                    }
                }
            } | Sort-Object Id -Unique)
            if ($mode -eq 'Check' -or $queriedPackages.Count -eq 0) {
                $resolved += [pscustomobject]@{
                    Manager='Chocolatey'; Available=$true; Success=$true; Skipped=$false; SkipReason=''; ExitCode=$queryExitCode
                    Packages=$queriedPackages; AvailableOutput=$availableOutput; ActionOutput=''
                }
                continue
            }
            $item = [pscustomobject]@{
                Manager='Chocolatey'; Available=$true; Success=$true; ExitCode=0; Packages=$queriedPackages
                AvailableOutput=$availableOutput
                JeaChocolateyUpdateRequest=[pscustomobject]@{ Packages=$queriedPackages; AvailableOutput=$availableOutput }
            }
        }
        $requestProperty = if ($item) { $item.PSObject.Properties['JeaChocolateyUpdateRequest'] } else { $null }
        if (-not $requestProperty -or -not $requestProperty.Value) {
            $resolved += $item
            continue
        }

        $request = $requestProperty.Value
        $packages = @($request.Packages)
        $output = ''
        $exitCode = 1
        try {
            $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName `
                -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -OpenTimeoutSeconds 30 -OperationTimeoutSeconds 5400
            $invokeParameters.ScriptBlock = { Update-WindowsUpdateAdmChocolateyPackages -ErrorAction Stop }
            $remoteResult = @(Invoke-Command @invokeParameters | Select-Object -Last 1)
            if ($remoteResult.Count -eq 0) { throw 'JEA lieferte kein Chocolatey-Ergebnis.' }
            $output = [string]$remoteResult[0].Output
            $exitCode = [int]$remoteResult[0].ExitCode
        }
        catch { $output = $_.Exception.ToString(); $exitCode = 1 }

        $succeededNames = @(
            foreach ($line in ($output -split "`r?`n")) {
                $match = [regex]::Match([string]$line, '(?i)^\s*The upgrade of (?<Name>.+?) was successful\.?\s*$')
                if ($match.Success) { $match.Groups['Name'].Value.Trim() }
            }
        )
        $failedIds = @(
            foreach ($line in ($output -split "`r?`n")) {
                $match = [regex]::Match([string]$line, '(?i)^\s*-\s*(?<Id>[^\s(]+)\s+\(exited\s+(?<Code>[^)]+)\)')
                if ($match.Success) { $match.Groups['Id'].Value.Trim() }
            }
        ) | Select-Object -Unique
        $succeededPackages = @($packages | Where-Object { $succeededNames -contains [string]$_.Id -or $succeededNames -contains [string]$_.Name })
        $failedPackages = @(
            foreach ($failedId in $failedIds) {
                $match = @($packages | Where-Object { [string]$_.Id -ieq $failedId -or [string]$_.Name -ieq $failedId } | Select-Object -First 1)
                if ($match.Count -gt 0) { $match[0] }
                else { [pscustomobject]@{ Name=$failedId; Id=$failedId; InstalledVersion=''; AvailableVersion=''; Source='chocolatey' } }
            }
        )

        if ($exitCode -eq 0 -and $failedPackages.Count -eq 0 -and ($succeededPackages.Count -gt 0 -or $succeededNames.Count -eq 0)) {
            $resolved += [pscustomobject]@{
                Manager='Chocolatey'; Available=$true; Success=$true; Skipped=$false; SkipReason=''; ExitCode=0
                Packages=$(if ($succeededPackages.Count -gt 0) { $succeededPackages } else { $packages })
                AvailableOutput=[string]$request.AvailableOutput; ActionOutput=$output
            }
            continue
        }
        if ($failedPackages.Count -eq 0) { $failedPackages = @($packages | Where-Object { $_ -notin $succeededPackages }) }
        if ($succeededPackages.Count -gt 0) {
            $resolved += [pscustomobject]@{
                Manager='Chocolatey'; Available=$true; Success=$true; Skipped=$false; SkipReason=''; ExitCode=0
                Packages=$succeededPackages; AvailableOutput=[string]$request.AvailableOutput; ActionOutput=$output
            }
        }
        $resolved += [pscustomobject]@{
            Manager='Chocolatey'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$exitCode
            Packages=$failedPackages; AvailableOutput=[string]$request.AvailableOutput; ActionOutput=$output
            DiagnosticOutput=$output; RequiresManualAction=$true
            ManualActionText='Chocolatey-Updates über den eingeschränkten JEA-Endpunkt sind fehlgeschlagen. Fehlgeschlagene Pakete manuell prüfen.'
        }
    }
    return @($resolved)
}







function Invoke-WindowsUpdatePackageManagers {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [ValidateSet('Check', 'Install')][string]$Mode = 'Check',
        [bool]$EnableWinget = $true,
        [bool]$EnableChocolatey = $true,
        [bool]$IncludeInteractiveUserUpdates = $true,
        [string[]]$ExcludeWinGetIds = @(),
        [string[]]$ExcludeChocolateyIds = @(),
        [scriptblock]$WriteLog
    )

    # Das Installationsskript wird nur beim fehlenden/defekten WinGet nachgeladen.
    # Die unveränderten signierten Bytes laufen auf dem Ziel ausdrücklich in
    # Windows PowerShell 5.1; diese Ausführung ist für AppX/WinGet erforderlich.
    $wingetInstallScriptWorker = {
        param([string]$ScriptBase64, [string]$ExpectedSha256, [string]$ScriptVersion)
        $ErrorActionPreference = 'Stop'
        $taskRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-WinGetInstall-' + [guid]::NewGuid().ToString('N'))
        $scriptPath = Join-Path $taskRoot 'winget-install.ps1'
        $stdoutPath = Join-Path $taskRoot 'stdout.log'
        $stderrPath = Join-Path $taskRoot 'stderr.log'
        try {
            New-Item -Path $taskRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
            $scriptBytes = [Convert]::FromBase64String($ScriptBase64)
            $sha = [Security.Cryptography.SHA256]::Create()
            try { $actualSha256 = [BitConverter]::ToString($sha.ComputeHash($scriptBytes)).Replace('-', '') } finally { $sha.Dispose() }
            if ($actualSha256 -ine $ExpectedSha256) { throw 'Prüfsumme des übertragenen winget-install.ps1 stimmt nicht mit der geprüften Download-Datei überein.' }
            [IO.File]::WriteAllBytes($scriptPath, $scriptBytes)
            $signature = Get-AuthenticodeSignature -FilePath $scriptPath -ErrorAction Stop
            if ($signature.Status -ne [Management.Automation.SignatureStatus]::Valid) {
                throw "Authenticode-Signatur auf dem Ziel ist nicht gültig (Status: $($signature.Status))."
            }

            $powerShell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $powerShell51 -PathType Leaf)) { throw "Windows PowerShell 5.1 wurde nicht gefunden: $powerShell51" }
            $arguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $scriptPath + '" -Force'
            $process = Start-Process -FilePath $powerShell51 -ArgumentList $arguments -WindowStyle Hidden -Wait -PassThru -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
            $installerOutput = @()
            if (Test-Path -LiteralPath $stdoutPath -PathType Leaf) { $installerOutput += Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue }
            if (Test-Path -LiteralPath $stderrPath -PathType Leaf) { $installerOutput += Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue }
            $installerText = ($installerOutput -join [Environment]::NewLine).Trim()
            if ($process.ExitCode -ne 0) {
                throw "winget-install.ps1 $ScriptVersion endete in Windows PowerShell 5.1 mit Exitcode $($process.ExitCode). Ausgabe: $installerText"
            }

            $registeredPackage = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
            if ($registeredPackage.Count -eq 0) {
                $stagedPackage = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
                    Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
                if ($stagedPackage.Count -gt 0) {
                    Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop | Out-Null
                    $registeredPackage = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                        Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
                }
            }
            if ($registeredPackage.Count -eq 0) { throw "winget-install.ps1 endete erfolgreich, aber App Installer ist danach für den Remoting-Benutzer nicht registriert. Ausgabe: $installerText" }

            $wingetPath = Join-Path ([string]$registeredPackage[0].InstallLocation) 'winget.exe'
            if (-not (Test-Path -LiteralPath $wingetPath -PathType Leaf)) {
                $wingetPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            }
            if (-not (Test-Path -LiteralPath $wingetPath -PathType Leaf)) { throw 'winget-install.ps1 meldete Erfolg, aber winget.exe fehlt weiterhin.' }
            $versionOutput = (& $wingetPath --version 2>&1 | Out-String).Trim()
            $wingetExitCode = $LASTEXITCODE
            if ($wingetExitCode -ne 0 -or $versionOutput -notmatch '(?m)^\s*v?\d+\.\d+') {
                throw "WinGet besteht den Starttest nach der Installation nicht (Exitcode $wingetExitCode). Ausgabe: $versionOutput"
            }
            [pscustomobject]@{
                Success = $true
                ExitCode = [int]$process.ExitCode
                PowerShellVersion = [string]$PSVersionTable.PSVersion
                ScriptVersion = $ScriptVersion
                AppInstallerVersion = [string]$registeredPackage[0].Version
                WinGetPath = $wingetPath
                WinGetVersion = $versionOutput
                Output = $installerText
            }
        }
        finally {
            if (Test-Path -LiteralPath $taskRoot -PathType Container) {
                Remove-Item -LiteralPath $taskRoot -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Der Block läuft lokal oder innerhalb der vorhandenen WinRM-Verbindung.
    # Er gibt ausschließlich strukturierte Daten zurück; Darstellung und Bericht
    # bleiben bei den aufrufenden Skripten.
    $packageScript = {
        param([string]$ExecutionMode, [bool]$UseWinget, [bool]$UseChocolatey, [bool]$SourceResetPerformed = $false, [string]$ExcludedWinGetIds = '', [string]$ExcludedChocolateyIds = '', [bool]$SourcePackageRefreshPerformed = $false, [bool]$IncludeInteractiveUserUpdates = $true, [bool]$PreferPortableWinGet = $false, [bool]$UseJeaForMachineWingetUpdates = $false, [bool]$UseJeaForChocolateyUpdates = $false)

        # Remoting kann ein nicht vorhandenes 8.3-Profil oder Arbeitsverzeichnis
        # übernehmen. Nur einen tatsächlich vorhandenen SID-Profilpfad verwenden.
        Set-Location -LiteralPath $env:WINDIR -ErrorAction Stop
        $profilePath = ''
        $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $profileKey = 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\' + $sid
        $profileData = Get-ItemProperty -LiteralPath $profileKey -ErrorAction S…52680 tokens truncated…rholt." -Force
                    $wingetInstallScriptRan = $true
                    Write-CommonLog $WriteLog "WinGet-Clientreparatur auf $ComputerName über JEA erfolgreich."
                    if (-not [string]::IsNullOrWhiteSpace([string]$installResult.Output)) {
                        Write-CommonLog $WriteLog ("winget-install.ps1-Ausgabe auf " + $ComputerName + ": " + ($installResult.Output -replace '\s+', ' '))
                    }
                }
                catch {
                    $failureDiagnostic = $_.Exception.ToString()
                    $firstDiagnostic += [Environment]::NewLine + 'WinGet-Installationsskript:' + [Environment]::NewLine + $failureDiagnostic
                    $portableFallbackProperty = $firstWingetResult.PSObject.Properties['PortableFallbackSupported']
                    if ($portableFallbackProperty -and [bool]$portableFallbackProperty.Value) {
                        $retryRequired = $true
                        $retryPreferPortableWinGet = $true
                        $retryReason = 'Portabler WinGet-Fallback aus GitHub als nächster Reparaturschritt'
                        Write-CommonLog $WriteLog "winget-install.ps1-Reparaturversuch auf $ComputerName abgeschlossen; wechsle zur portablen WinGet-CLI aus GitHub und wiederhole die Prüfung in einer neuen Verbindung. Details des Reparaturversuchs: $failureDiagnostic"
                    }
                    else {
                        $failure = "WinGet-Installation/Reparatur auf $ComputerName fehlgeschlagen; Details im Log."
                        $packageResults += [pscustomobject]@{
                            Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null
                            Packages=@(); AvailableOutput=''; ActionOutput=$failure; DiagnosticOutput=$firstDiagnostic
                        }
                        Write-CommonLog $WriteLog $failure 'WARN'
                    }
                }
            }
            elseif ($sourceRepairProperty -and [bool]$sourceRepairProperty.Value) {
                $retryRequired = $true
                $retrySourcePackageRepair = $true
                $retryRuntimeRepairRequired = $true
                $retryRequiresSourceReset = $true
                $reasonProperty = $firstWingetResult.PSObject.Properties['RetryReason']
                $retryReason = if ($reasonProperty) { [string]$reasonProperty.Value } else { 'WinGet-Quellenpaket V2 gezielt repariert' }
            }
            elseif ($resetProperty -and [bool]$resetProperty.Value) {
                $retryRequired = $true
                $retryRuntimeRepairRequired = $true
                $retryRequiresSourceReset = $true
                $retryReason = 'Quellenreset erforderlich'
            }
            elseif ($sourcePackageRefreshProperty -and [bool]$sourcePackageRefreshProperty.Value) {
                $retryRequired = $true
                $retryRuntimeRepairRequired = $true
                $retryRequiresSourceReset = $true
                $retryRequiresSourcePackageRefresh = $true
                $retryReason = 'WinGet-Quellenpaket muss im Remoting-Benutzerkontext erneuert werden'
            }
            elseif ($monthlyResetProperty -and [bool]$monthlyResetProperty.Value) {
                $retryRequired = $true
                $retryRuntimeRepairRequired = $true
                $retryRequiresSourceReset = $true
                $retryAfterMonthlySourceReset = $true
                $retryReason = 'Monatlicher WinGet-Wartungsreset fällig; zentralen Reparaturablauf ausführen'
            }
            elseif ($connectionProperty -and [bool]$connectionProperty.Value) {
                $retryRequired = $true
                $retryRuntimeRepairRequired = $true
                $retryRequiresSourceReset = $true
                $reasonProperty = $firstWingetResult.PSObject.Properties['RetryReason']
                $retryReason = if ($reasonProperty -and -not [string]::IsNullOrWhiteSpace([string]$reasonProperty.Value)) {
                    [string]$reasonProperty.Value
                } else {
                    'WinGet-RPC-Fehler; frische Verbindung erforderlich'
                }
            }
            else { $packageResults += $wingetResults }
        }
        catch [System.TimeoutException] {
            $retryRequired = $true
            $retryRuntimeRepairRequired = $true
            $retryRequiresSourceReset = $true
            $retryReason = 'Zeitlimit erreicht; Quellenreset erforderlich'
            $firstDiagnostic = $_.Exception.ToString()
        }

        if ($retryRequired) {
            $completedInitialPackages = @($wingetResults | Where-Object {
                $_.Manager -eq 'Winget' -and [bool]$_.Success -and @($_.Packages).Count -gt 0
            })
            if ($completedInitialPackages.Count -gt 0) { $packageResults += $completedInitialPackages }
            $retryDescription = if ($retryPreferPortableWinGet) {
                'Bereitstellung der portablen WinGet-CLI aus dem aktuellen GitHub-Release und einmalige Wiederholung'
            } elseif ($retrySourcePackageRepair) {
                'zentraler WinGet-Reparaturablauf einschließlich winget-install.ps1, Quellenreset, Quellenpaketprüfung und einmaliger Wiederholung'
            } elseif ($retryAfterMonthlySourceReset) {
                'zentraler WinGet-Wartungsablauf einschließlich winget-install.ps1, Quellenreset, Quellenpaketprüfung und einmaliger Wiederholung'
            } elseif ($retryRequiresSourceReset) {
                'Quellenreset, Erneuerung des WinGet-Quellenpakets und einmalige Wiederholung'
            } elseif ($retryRequiresSourcePackageRefresh) {
                'Erneuerung des WinGet-Quellenpakets und einmalige Wiederholung'
            } else { 'einmalige Wiederholung' }
            $sourceResetPerformed = $false
            Write-CommonLog $WriteLog "WinGet auf ${ComputerName}: $retryReason; starte $retryDescription über eine neue Verbindung."
            try {
                if ($retryRuntimeRepairRequired -and -not $wingetInstallScriptRan -and -not $retryPreferPortableWinGet) {
                    Write-CommonLog $WriteLog "Zentraler WinGet-Reparaturablauf auf ${ComputerName}: signaturgeprüfte winget-install.ps1-Clientreparatur über JEA und Windows PowerShell 5.1; Paket-Installationen und -Deinstallationen sind nicht freigegeben."
                    try {
                    $installResult = Invoke-WindowsUpdateJeaWinGetClientRepair -ComputerName $ComputerName -AuthInfo $AuthInfo -TimeoutSeconds (Get-WinGetRemainingSeconds -ReserveSeconds 60 -MaxSeconds 180)
                    if ([string]$installResult.Output -match '__WINGET_PORTABLE__|portable Microsoft-CLI erfolgreich') {
                        $retryPreferPortableWinGet = $true
                        $retryReason = 'Portable Microsoft-CLI wurde erfolgreich bereitgestellt'
                    }
                    $wingetInstallScriptRan = $true
                    Write-CommonLog $WriteLog "Zentrale WinGet-Clientreparatur auf $ComputerName über JEA erfolgreich."
                    if (-not [string]::IsNullOrWhiteSpace([string]$installResult.Output)) {
                        Write-CommonLog $WriteLog ("winget-install.ps1-Ausgabe auf " + $ComputerName + ": " + ($installResult.Output -replace '\s+', ' '))
                    }
                    } catch {
                        $wingetInstallScriptRan = $true
                        $firstDiagnostic += [Environment]::NewLine + 'Clientreparatur: ' + $_.Exception.ToString()
                        Write-CommonLog $WriteLog "WinGet-Reparatur auf ${ComputerName} nicht vollständig; reservierte Abschlussabfrage wird trotzdem versucht." $true
                    }
                }
                if (-not $retryPreferPortableWinGet -and ($retrySourcePackageRepair -or $retryReason -match '(?i)(WinGet nach Reparatur oder App-Installer-Registrierung|winget-install\.ps1)')) {
                    # Nach einer AppX-Registrierung meldet Add-AppxPackage den
                    # Vorgang synchron als abgeschlossen, während App Installer
                    # und WinGet-Quelle im Remoting-Kontext noch kurz den neuen
                    # Paketstatus übernehmen. Ein sofortiger neuer WinRM-Job
                    # kann dann hängen; ein nachfolgender Check funktioniert,
                    # sobald die Registrierung vollständig sichtbar ist.
                    $appxSettleDelaySeconds = 15
                    Write-CommonLog $WriteLog "AppX-Registrierung auf $ComputerName wurde geändert; warte $appxSettleDelaySeconds Sekunden vor der WinGet-Wiederholung in neuer Verbindung."
                    if ($hasCheckTimeout -and (Get-WinGetRemainingSeconds) -le $appxSettleDelaySeconds) { throw [TimeoutException]::new('WinGet-Gesamtzeitlimit vor AppX-Wiederholung erreicht.') }
                    Start-Sleep -Seconds $appxSettleDelaySeconds
                }
                if ($retryRequiresSourceReset) {
                    try {
                    $sourceResetResult = $null
                    if ($isLocalTarget) {
                        $sourceResetResult = Reset-WindowsUpdateLocalWinGetSources -TimeoutSeconds (Get-WinGetRemainingSeconds -ReserveSeconds 45 -MaxSeconds 120) -WriteLog $WriteLog
                    } else {
                        $sourceResetResult = Reset-WindowsUpdateRemoteWinGetSources -ComputerName $ComputerName -AuthInfo $AuthInfo -TimeoutSeconds (Get-WinGetRemainingSeconds -ReserveSeconds 45 -MaxSeconds 120) -WriteLog $WriteLog
                    }
                    $sourceResetPerformed = if ($sourceResetResult -and $sourceResetResult.PSObject.Properties['ResetPerformed']) {
                        [bool]$sourceResetResult.ResetPerformed
                    } else { $true }
                    if ($sourceResetPerformed) {
                        Write-CommonLog $WriteLog "WinGet-Quellen auf $ComputerName zurückgesetzt; Wiederholungsprüfung startet in einer neuen Sitzung."
                    } else {
                        Write-CommonLog $WriteLog "WinGet-Quellenreset auf $ComputerName wegen des 24-Stunden-Schutzes ausgelassen; WinGet-Quellenpaket wird geprüft und die Abfrage in einer neuen Sitzung wiederholt."
                    }
                    } catch {
                        Write-CommonLog $WriteLog "WinGet-Quellenreset auf ${ComputerName} nicht abgeschlossen: $($_.Exception.Message). Abschlussabfrage wird trotzdem versucht." $true
                        $sourceResetPerformed = $false
                    }
                }
                # Nur tatsächlich bestätigte Quellenpflege darf eine leere
                # Wiederholungsabfrage als gültig freigeben. Ein angeforderter,
                # aber fehlgeschlagener JEA-Reset (z. B. Zugriff verweigert)
                # und ein bloß gestarteter Reparaturversuch zählen nicht.
                # Eine explizit angeforderte Quellenpaket-Erneuerung wird im
                # folgenden Worker ausgeführt und dort bei Fehlschlag gemeldet.
                $sourcePackageRefreshPerformed = $retryRequiresSourcePackageRefresh -or $sourceResetPerformed

                $retryParameters = @{
                    ComputerName = $ComputerName
                    AuthInfo = $AuthInfo
                    ScriptBlock = $packageScript
                    ArgumentList = @($Mode, $true, $false, $sourceResetPerformed, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $sourcePackageRefreshPerformed, $IncludeInteractiveUserUpdates, $retryPreferPortableWinGet, ($Mode -eq 'Install' -and -not $isLocalTarget))
                    IsLocalTarget = $isLocalTarget
                    OperationName = "WinGet-Wiederholungsprüfung auf $ComputerName"
                    WriteLog = $WriteLog
                }
                if ($hasCheckTimeout) { $retryParameters.TimeoutSeconds = Get-WinGetRemainingSeconds }
                else { $retryParameters.NoTimeout = $true }
                $retryResults = @(Invoke-WindowsUpdatePackageWorker @retryParameters | Where-Object { $_.Manager -eq 'Winget' })
                if ($Mode -eq 'Install' -and -not $isLocalTarget) {
                    $retryResults = @(Resolve-WindowsUpdateJeaWinGetResults -Results $retryResults -ComputerName $ComputerName -AuthInfo $AuthInfo)
                }
                if ($retryResults.Count -eq 0) { throw 'Die Wiederholungsprüfung lieferte kein WinGet-Ergebnis.' }
                $retryResult = $retryResults[-1]
                $retryDiagnosticProperty = $retryResult.PSObject.Properties['DiagnosticOutput']
                if ($retryDiagnosticProperty) { $retryDiagnostic = [string]$retryDiagnosticProperty.Value }
                $retryResetProperty = $retryResult.PSObject.Properties['RetryAfterSourceReset']
                $retryRefreshProperty = $retryResult.PSObject.Properties['RetryAfterSourcePackageRefresh']
                $retryConnectionProperty = $retryResult.PSObject.Properties['RetryFreshConnection']

                # Eine AppX-Registrierung kann erst nach der ersten frischen
                # Verbindung sichtbar sein. Meldet diese Verbindung danach
                # einen leeren Suchlauf, dessen Zustand einen Quellenreset
                # oder eine Quellenpaket-Erneuerung verlangt, führen wir genau
                # diesen Folgeschritt aus und prüfen ein letztes Mal in einer
                # weiteren neuen Verbindung.
                if (($retryResetProperty -and [bool]$retryResetProperty.Value) -or
                    ($retryRefreshProperty -and [bool]$retryRefreshProperty.Value)) {
                    $followupResetPerformed = $false
                    if ($retryResetProperty -and [bool]$retryResetProperty.Value) {
                        Write-CommonLog $WriteLog "WinGet auf $ComputerName blieb nach der ersten Wiederholung leer; Quellenreset wird jetzt ausgeführt, danach folgt eine weitere neue Verbindung."
                        try {
                        $followupResetResult = $null
                        if ($isLocalTarget) {
                            $followupResetResult = Reset-WindowsUpdateLocalWinGetSources -TimeoutSeconds (Get-WinGetRemainingSeconds -ReserveSeconds 45 -MaxSeconds 120) -WriteLog $WriteLog
                        } else {
                            $followupResetResult = Reset-WindowsUpdateRemoteWinGetSources -ComputerName $ComputerName -AuthInfo $AuthInfo -TimeoutSeconds (Get-WinGetRemainingSeconds -ReserveSeconds 45 -MaxSeconds 120) -WriteLog $WriteLog
                        }
                        $followupResetPerformed = if ($followupResetResult -and $followupResetResult.PSObject.Properties['ResetPerformed']) {
                            [bool]$followupResetResult.ResetPerformed
                        } else { $true }
                        } catch {
                            Write-CommonLog $WriteLog "WinGet-Folgequellenreset auf ${ComputerName} nicht abgeschlossen; Abschlussabfrage wird mit verbleibendem Budget versucht: $($_.Exception.Message)" $true
                            $followupResetPerformed = $false
                        }
                        $retryRequiresSourceReset = $followupResetPerformed
                    }
                    else {
                        Write-CommonLog $WriteLog "WinGet auf $ComputerName verlangt nach der ersten Wiederholung eine Quellenpaket-Erneuerung; starte sie vor einer weiteren neuen Verbindung."
                        $retryRequiresSourcePackageRefresh = $true
                    }

                    $sourcePackageRefreshPerformed = $true
                    $followupParameters = @{
                        ComputerName = $ComputerName
                        AuthInfo = $AuthInfo
                        ScriptBlock = $packageScript
                        ArgumentList = @($Mode, $true, $false, $followupResetPerformed, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $sourcePackageRefreshPerformed, $IncludeInteractiveUserUpdates, $retryPreferPortableWinGet, ($Mode -eq 'Install' -and -not $isLocalTarget))
                        IsLocalTarget = $isLocalTarget
                        OperationName = "WinGet-Folgeprüfung auf $ComputerName"
                        WriteLog = $WriteLog
                    }
                    if ($hasCheckTimeout) { $followupParameters.TimeoutSeconds = Get-WinGetRemainingSeconds }
                    else { $followupParameters.NoTimeout = $true }
                    $followupResults = @(Invoke-WindowsUpdatePackageWorker @followupParameters | Where-Object { $_.Manager -eq 'Winget' })
                    if ($Mode -eq 'Install' -and -not $isLocalTarget) {
                        $followupResults = @(Resolve-WindowsUpdateJeaWinGetResults -Results $followupResults -ComputerName $ComputerName -AuthInfo $AuthInfo)
                    }
                    if ($followupResults.Count -eq 0) { throw 'Die WinGet-Folgeprüfung nach Quellenkorrektur lieferte kein Ergebnis.' }

                    $followupResult = $followupResults[-1]
                    $followupDiagnosticProperty = $followupResult.PSObject.Properties['DiagnosticOutput']
                    if ($followupDiagnosticProperty -and -not [string]::IsNullOrWhiteSpace([string]$followupDiagnosticProperty.Value)) {
                        $followupDiagnostic = [string]$followupDiagnosticProperty.Value
                        if ([string]::IsNullOrWhiteSpace($retryDiagnostic)) {
                            $retryDiagnostic = $followupDiagnostic
                        } else {
                            $retryDiagnostic += [Environment]::NewLine + $followupDiagnostic
                        }
                    }
                    $retryResults = $followupResults
                    $retryResult = $followupResult
                    $retryResetProperty = $retryResult.PSObject.Properties['RetryAfterSourceReset']
                    $retryRefreshProperty = $retryResult.PSObject.Properties['RetryAfterSourcePackageRefresh']
                    $retryConnectionProperty = $retryResult.PSObject.Properties['RetryFreshConnection']
                }

                if (($retryResetProperty -and [bool]$retryResetProperty.Value) -or
                    ($retryRefreshProperty -and [bool]$retryRefreshProperty.Value) -or
                    ($retryConnectionProperty -and [bool]$retryConnectionProperty.Value)) {
                    $retryDetail = ([string]$retryResult.ActionOutput -replace '\s+', ' ').Trim()
                    if ([string]::IsNullOrWhiteSpace($retryDetail)) { $retryDetail = 'WinGet lieferte erneut kein auswertbares Ergebnis.' }
                    throw "Wiederholungsprüfung blieb fehlerhaft: $retryDetail"
                }
                if (-not [bool]$retryResult.Success) {
                    $retryDetail = ([string]$retryResult.ActionOutput -replace '\s+', ' ').Trim()
                    if ([string]::IsNullOrWhiteSpace($retryDetail)) { $retryDetail = 'WinGet meldete einen Abfragefehler.' }
                    throw "Wiederholungsprüfung fehlgeschlagen: $retryDetail"
                }
                if ($retryPreferPortableWinGet) {
                    try {
                        New-Item -ItemType Directory -Path $portablePreferenceRoot -Force -ErrorAction Stop | Out-Null
                        [IO.File]::WriteAllText($portablePreferencePath, [DateTime]::UtcNow.ToString('o'))
                    } catch {
                        Write-CommonLog $WriteLog "Portablen WinGet-Betrieb auf $ComputerName nicht gespeichert: $($_.Exception.Message)"
                    }
                }
                $retryMessage = if ($retryPreferPortableWinGet) {
                    'WinGet-Wiederholungsprüfung mit portabler GitHub-CLI in neuer Sitzung erfolgreich.'
                } elseif ($sourcePackageRefreshPerformed -and @($retryResult.Packages).Count -eq 0) {
                    'WinGet-Abfrage nach Prüfung des Quellenpakets in neuer Verbindung erfolgreich; keine Paketupdates verfügbar.'
                } elseif ($retryRequiresSourceReset) {
                    'WinGet-Wiederholungsprüfung nach Quellenreset und Erneuerung des Quellenpakets erfolgreich.'
                } elseif ($retryRequiresSourcePackageRefresh) {
                    'WinGet-Wiederholungsprüfung nach Erneuerung des Quellenpakets erfolgreich.'
                } else {
                    'WinGet-Wiederholungsprüfung in neuer Sitzung erfolgreich.'
                }
                $initialBootstrapProperty = if ($firstWingetResult) { $firstWingetResult.PSObject.Properties['BootstrapMessage'] } else { $null }
                $initialBootstrapMessage = if ($initialBootstrapProperty) { [string]$initialBootstrapProperty.Value } else { '' }
                foreach ($wingetResult in $retryResults) {
                    $bootstrapProperty = $wingetResult.PSObject.Properties['BootstrapMessage']
                    $existingMessage = if ($bootstrapProperty) { [string]$bootstrapProperty.Value } else { '' }
                    $combinedBootstrapMessage = @($initialBootstrapMessage, $existingMessage, $retryMessage) |
                        Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } |
                        Select-Object -Unique
                    Add-Member -InputObject $wingetResult -NotePropertyName BootstrapMessage -NotePropertyValue ($combinedBootstrapMessage -join ' ') -Force
                }
                $packageResults += $retryResults
            }
            catch {
                if ([string]::IsNullOrWhiteSpace($retryDiagnostic)) { $retryDiagnostic = [string]$_.Exception.ToString() }
                $failureMessage = "WinGet-Prüfung auf $ComputerName fehlgeschlagen; Details im Log."
                $fullDiagnostic = "Erste WinGet-Prüfung:`r`n$firstDiagnostic`r`nWiederholungsprüfung:`r`n$retryDiagnostic"
                $partialResult = $retryResult
                if (-not $partialResult -or @($partialResult.Packages).Count -eq 0) { $partialResult = $firstWingetResult }
                $partialPackages = @()
                $partialOutput = ''
                if ($partialResult) {
                    $partialPackages = @($partialResult.Packages)
                    $partialOutput = [string]$partialResult.AvailableOutput
                }
                $packageResults += [pscustomobject]@{
                    Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''
                    ExitCode=$null; Packages=$partialPackages; AvailableOutput=$partialOutput
                    ActionOutput=$failureMessage; DiagnosticOutput=$fullDiagnostic
                }
            }
        }
    }
    # Zusätzliche Schutzprüfung auf dem Aufrufer: Auch wenn Chocolatey-Zeilen
    # aus einem abweichenden/älteren Abfragepfad zurückkommen, dürfen Pakete
    # mit identischer installierter und verfügbarer Version nicht gezählt
    # oder ausgegeben werden.
    foreach ($chocoResult in @($packageResults | Where-Object { $_.Manager -eq 'Chocolatey' })) {
        $suppressedCount = 0
        $filteredPackages = @(
            foreach ($package in @($chocoResult.Packages)) {
                $installedVersion = ''
                $availableVersion = ''
                if ($package -is [string]) {
                    $fields = @(([string]$package) -split '\|', 4)
                    if ($fields.Count -ge 3) {
                        $installedVersion = ([string]$fields[1]).Trim()
                        $availableVersion = ([string]$fields[2]).Trim()
                    }
                }
                elseif ($package) {
                    $installedProperty = $package.PSObject.Properties['InstalledVersion']
                    $availableProperty = $package.PSObject.Properties['AvailableVersion']
                    if ($installedProperty) { $installedVersion = ([string]$installedProperty.Value).Trim() }
                    if ($availableProperty) { $availableVersion = ([string]$availableProperty.Value).Trim() }
                }
                if (-not [string]::IsNullOrWhiteSpace($installedVersion) -and
                    -not [string]::IsNullOrWhiteSpace($availableVersion) -and
                    [string]::Equals($installedVersion, $availableVersion, [StringComparison]::OrdinalIgnoreCase)) {
                    $suppressedCount++
                    continue
                }
                $package
            }
        )
        $chocoResult.Packages = $filteredPackages
        if ($suppressedCount -gt 0) {
            $duplicateVersionDiagnostic = "Chocolatey: $suppressedCount Paketzeile(n) mit identischer installierter und verfügbarer Version als Nicht-Updates verworfen."
            $existingDiagnostic = $chocoResult.PSObject.Properties['DiagnosticOutput']
            if ($existingDiagnostic -and -not [string]::IsNullOrWhiteSpace([string]$existingDiagnostic.Value)) {
                $chocoResult.DiagnosticOutput = ([string]$existingDiagnostic.Value + [Environment]::NewLine + $duplicateVersionDiagnostic)
            }
            else {
                Add-Member -InputObject $chocoResult -NotePropertyName DiagnosticOutput -NotePropertyValue $duplicateVersionDiagnostic
            }
        }
    }

    foreach ($packageResult in $packageResults) {
        $diagnosticProperty = $packageResult.PSObject.Properties['DiagnosticOutput']
        if ($diagnosticProperty -and -not [string]::IsNullOrWhiteSpace([string]$diagnosticProperty.Value) -and $WriteLog) {
            if ([bool]$packageResult.Success) {
                # Historische Reparaturfehler gehören nach erfolgreicher Wiederholung nur ins Log.
                $successfulDiagnosticSink = $WriteLog
                $successfulDiagnosticLogger = {
                    param($message)
                    & $successfulDiagnosticSink $message $true
                }.GetNewClosure()
                Write-WindowsUpdateDiagnostic -WriteLog $successfulDiagnosticLogger -Operation "$($packageResult.Manager)-$Mode" -Target $ComputerName -DiagnosticText ([string]$diagnosticProperty.Value)
            } else {
                Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation "$($packageResult.Manager)-$Mode" -Target $ComputerName -DiagnosticText ([string]$diagnosticProperty.Value)
            }
        }
        if ($packageResult.Manager -eq 'Winget') {
            $availableOutputProperty = $packageResult.PSObject.Properties['AvailableOutput']
            if ($availableOutputProperty) {
                $agreementLines = @(([string]$availableOutputProperty.Value -split "`r?`n") | Where-Object {
                    $_ -match '(?i)(Terms of Transaction|Vereinbarungen der Quelle|Nutzungsbedingungen der Quelle|geographic region|geografische Region|accept.*agreement|Zustimmung.*Vereinbarung)'
                })
                foreach ($agreementLine in $agreementLines) {
                    Write-CommonLog $WriteLog "[WinGet-Zustimmung] $(([string]$agreementLine).Trim())"
                }
            }
        }
        $bootstrapMessageProperty = $packageResult.PSObject.Properties['BootstrapMessage']
        if ($packageResult.Manager -eq 'Winget' -and $bootstrapMessageProperty -and -not [string]::IsNullOrWhiteSpace([string]$bootstrapMessageProperty.Value)) {
            $bootstrapMessage = [string]$bootstrapMessageProperty.Value
            $logOnly = $bootstrapMessage -match '(?i)WinGet-Abfrage war erfolgreich; keine Paketupdates verfügbar\. Quellenreset wegen des monatlichen Limits übersprungen\.|WinGet-Abfrage nach Quellenreset in neuer Sitzung erfolgreich; keine Paketupdates verfügbar\.|WinGet-Abfrage nach Prüfung des Quellenpakets in neuer Verbindung erfolgreich; keine Paketupdates verfügbar\.'
            if ($WriteLog) { & $WriteLog $bootstrapMessage ([bool]$logOnly) }
        }
    }
    return @($packageResults)
}

