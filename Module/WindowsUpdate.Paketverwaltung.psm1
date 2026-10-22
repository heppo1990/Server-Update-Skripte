# Fachmodul: WindowsUpdate.Paketverwaltung
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

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

    # Der Block läuft lokal oder innerhalb der vorhandenen WinRM-Verbindung.
    # Er gibt ausschließlich strukturierte Daten zurück; Darstellung und Bericht
    # bleiben bei den aufrufenden Skripten.
    $packageScript = {
        param([string]$ExecutionMode, [bool]$UseWinget, [bool]$UseChocolatey, [bool]$SourceResetPerformed = $false, [string]$ExcludedWinGetIds = '', [string]$ExcludedChocolateyIds = '', [bool]$SourcePackageRefreshPerformed = $false, [bool]$IncludeInteractiveUserUpdates = $true)

        function Invoke-WinGetCurrentUserAppxTask {
            param(
                [Parameter(Mandatory)][string]$ScriptText,
                [ValidateRange(30, 1800)][int]$TimeoutSeconds = 600,
                [Parameter(Mandatory)][string]$Purpose
            )
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $userName = [string]$identity.Name
            if ([string]::IsNullOrWhiteSpace($userName) -or $userName -match '^NT AUTHORITY\\SYSTEM$') {
                throw "AppX-Benutzeraufgabe für '$Purpose' benötigt ein konkretes Benutzerkonto; erkannt: '$userName'."
            }

            $taskName = 'WindowsUpdateAdm-WinGetAppX-' + [guid]::NewGuid().ToString('N')
            $taskRoot = Join-Path ([IO.Path]::GetTempPath()) $taskName
            $resultPath = Join-Path $taskRoot 'result.json'
            $taskScriptPath = Join-Path $taskRoot 'worker.ps1'
            $taskRegistered = $false
            try {
                New-Item -Path $taskRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -Compress -InputObject @{
                    ScriptText = $ScriptText
                    ResultPath = $resultPath
                })))
                $worker = @'
$ErrorActionPreference = 'Stop'
$payload = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$response = [ordered]@{ Success = $false; Output = ''; Error = '' }
try {
    $captured = @(& ([scriptblock]::Create([string]$payload.ScriptText)) *>&1)
    $response.Output = ($captured | Out-String -Width 300).Trim()
    $response.Success = $true
} catch {
    $response.Error = $_.Exception.ToString()
    $response.Output = (@($response.Output, ($_.ErrorDetails.Message), ($_.Exception.Message)) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
}
try {
    [IO.File]::WriteAllText([string]$payload.ResultPath, ($response | ConvertTo-Json -Compress -Depth 4), [Text.UTF8Encoding]::new($false))
} catch { exit 2 }
if (-not $response.Success) { exit 1 }
'@ -replace '__PAYLOAD__', $payload
                [IO.File]::WriteAllText($taskScriptPath, $worker, [Text.UTF8Encoding]::new($false))
                $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
                $action = New-ScheduledTaskAction -Execute $powershellPath -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $taskScriptPath)

                # Wenn das Remoting-Konto angemeldet ist, muss AppX im interaktiven
                # Profil registrieren (der auf SRVTS01 nachgewiesene PLM-Fall).
                # Ohne Sitzung wird dieselbe Identität als S4U-Aufgabe verwendet;
                # die Nutzlast liegt lokal, daher braucht die Aufgabe keinen Netzzugriff.
                $hasInteractiveSession = $false
                try {
                    $processes = @(Get-Process -Name explorer -IncludeUserName -ErrorAction Stop)
                    $hasInteractiveSession = @($processes | Where-Object { [string]$_.UserName -ieq $userName }).Count -gt 0
                } catch { }
                $logonType = if ($hasInteractiveSession) { 'Interactive' } else { 'S4U' }
                $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType $logonType -RunLevel Highest
                $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Seconds $TimeoutSeconds) -StartWhenAvailable
                Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
                $taskRegistered = $true
                Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
                while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and (Get-Date) -lt $deadline) {
                    Start-Sleep -Milliseconds 500
                }
                if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                    $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                    $lastResult = if ($taskInfo) { "; LastTaskResult=$($taskInfo.LastTaskResult)" } else { '' }
                    Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                    throw "AppX-Aufgabe '$Purpose' unter '$userName' (Anmeldetyp $logonType) lieferte nach $TimeoutSeconds Sekunden kein Ergebnis$lastResult."
                }
                $response = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                if (-not $response.Success) {
                    throw "AppX-Aufgabe '$Purpose' unter '$userName' (Anmeldetyp $logonType) fehlgeschlagen: $([string]$response.Error) $([string]$response.Output)"
                }
                return [pscustomobject]@{ UserName = $userName; LogonType = $logonType; Output = [string]$response.Output }
            }
            finally {
                if ($taskRegistered) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
                if (Test-Path -LiteralPath $taskRoot -PathType Container) { Remove-Item -LiteralPath $taskRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

        function Invoke-WindowsUpdateHiddenProcess {
            param(
                [Parameter(Mandatory)][string]$Path,
                [string[]]$Arguments = @(),
                [ValidateRange(1, 300)][int]$TimeoutSeconds = 180
            )
            $quotedArguments = foreach ($argument in $Arguments) {
                $value = [string]$argument
                if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
            }
            $startInfo = [Diagnostics.ProcessStartInfo]::new()
            $startInfo.FileName = $Path
            $startInfo.Arguments = $quotedArguments -join ' '
            $startInfo.WorkingDirectory = Split-Path -Parent $Path
            $startInfo.UseShellExecute = $false
            $startInfo.CreateNoWindow = $true
            $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
            $startInfo.RedirectStandardOutput = $true
            $startInfo.RedirectStandardError = $true
            $process = [Diagnostics.Process]::new()
            try {
                $process.StartInfo = $startInfo
                if (-not $process.Start()) { throw "Prozess konnte nicht gestartet werden: $Path" }
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
                    try { $process.Kill() } catch { }
                    throw "Prozess überschritt das Zeitlimit von $TimeoutSeconds Sekunden: $Path"
                }
                $process.WaitForExit()
                $output = @($stdoutTask.GetAwaiter().GetResult(), $stderrTask.GetAwaiter().GetResult()) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($output -join [Environment]::NewLine).Trim() }
            }
            finally { $process.Dispose() }
        }

        function Invoke-WingetRunspaceWithTimeout {
            param(
                [Parameter(Mandatory)][scriptblock]$ScriptBlock,
                [object[]]$ArgumentList = @(),
                [ValidateRange(1, 300)][int]$TimeoutSeconds = 60
            )
            $runspace = $null
            $worker = $null
            $asyncResult = $null
            try {
                # Start-Job startet für jede Abfrage einen eigenen powershell.exe-
                # Prozess; genau diese Konsolen blitzen im interaktiven Lauf auf.
                # Ein eigener Runspace hält die Abfrage im aktuellen Prozess.
                $runspace = [System.Management.Automation.Runspaces.RunspaceFactory]::CreateRunspace()
                $runspace.ApartmentState = [System.Threading.ApartmentState]::MTA
                $runspace.Open()
                $worker = [System.Management.Automation.PowerShell]::Create()
                $worker.Runspace = $runspace
                [void]$worker.AddScript($ScriptBlock.ToString())
                foreach ($argument in $ArgumentList) { [void]$worker.AddArgument($argument) }
                $asyncResult = $worker.BeginInvoke()
                if (-not $asyncResult.AsyncWaitHandle.WaitOne($TimeoutSeconds * 1000)) {
                    $worker.Stop()
                    throw [System.TimeoutException]::new("WinGet-Abfrage hat das Zeitlimit von $TimeoutSeconds Sekunden überschritten.")
                }
                $results = @($worker.EndInvoke($asyncResult))
                if ($worker.HadErrors -and $worker.Streams.Error.Count -gt 0) {
                    throw [System.InvalidOperationException]::new([string]$worker.Streams.Error[0])
                }
                return $results
            }
            finally {
                if ($asyncResult -and $asyncResult.AsyncWaitHandle) { $asyncResult.AsyncWaitHandle.Close() }
                if ($worker) { $worker.Dispose() }
                if ($runspace) { $runspace.Dispose() }
            }
        }

        # Winget ist eine benutzerbezogene App-Installer-Anwendung. Im
        # LocalSystem-Kontext ist es nicht zuverlässig verfügbar und darf dort
        # daher weder gesucht noch ausgeführt werden.
        $isSystemContext = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

        function Resolve-WingetExecutable {
            if (-not [string]::IsNullOrWhiteSpace([string]$script:WindowsUpdatePortableWinGetPath) -and
                (Test-Path -LiteralPath $script:WindowsUpdatePortableWinGetPath -PathType Leaf -ErrorAction SilentlyContinue)) {
                return [string]$script:WindowsUpdatePortableWinGetPath
            }
            # Bevorzugt die EXE aus dem für diesen Benutzer registrierten
            # App-Installer-Paket. Der WindowsApps-App-Ausführungsalias kann
            # veraltet sein oder auf eine andere Paketversion zeigen.
            $registeredPackages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                Where-Object { $_.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
                Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending)
            foreach ($registeredPackage in $registeredPackages) {
                $registeredExecutable = Join-Path ([string]$registeredPackage.InstallLocation) 'winget.exe'
                if (Test-Path -LiteralPath $registeredExecutable -PathType Leaf -ErrorAction SilentlyContinue) {
                    return $registeredExecutable
                }
            }

            # Falls das Paket für den Benutzer nicht registriert ist, die
            # installierten WindowsApps-Pfade nach Paketversion durchsuchen.
            $programFilesRoots = @('C:\Program Files', $env:ProgramFiles) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
            $installedCandidates = @()
            foreach ($programFilesRoot in $programFilesRoots) {
                $patterns = @()
                $patterns += Join-Path $programFilesRoot 'WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
                # Neuere bzw. paketierte Layouts verwenden Unterordner für Version und Architektur.
                $patterns += Join-Path $programFilesRoot 'WindowsApps\Microsoft.DesktopAppInstaller\*\winget.exe'
                $patterns += Join-Path $programFilesRoot 'WindowsApps\Microsoft.DesktopAppInstaller\*\*\winget.exe'
                foreach ($pattern in $patterns) {
                    $paths = if ($pattern -match '[*?]') {
                        @(Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
                    } elseif (Test-Path -LiteralPath $pattern -PathType Leaf -ErrorAction SilentlyContinue) {
                        @($pattern)
                    } else { @() }
                    foreach ($candidatePath in $paths) {
                        $candidateItem = Get-Item -LiteralPath $candidatePath -ErrorAction SilentlyContinue
                        if (-not $candidateItem) { continue }
                        $versionMatch = [regex]::Match($candidatePath, 'Microsoft\.DesktopAppInstaller_(?<Version>\d+(?:\.\d+){1,3})_')
                        $candidateVersion = if ($versionMatch.Success) { try { [version]$versionMatch.Groups['Version'].Value } catch { [version]'0.0' } } else { [version]'0.0' }
                        $installedCandidates += [pscustomobject]@{
                            Path = $candidatePath
                            Version = $candidateVersion
                            LastWriteTime = $candidateItem.LastWriteTime
                        }
                    }
                }
            }
            $bestInstalledCandidate = @($installedCandidates | Sort-Object Version, LastWriteTime -Descending | Select-Object -First 1)
            if ($bestInstalledCandidate.Count -gt 0 -and
                (Test-Path -LiteralPath $bestInstalledCandidate[0].Path -PathType Leaf -ErrorAction SilentlyContinue)) {
                return [string]$bestInstalledCandidate[0].Path
            }

            # Alias bzw. PATH nur als letzte Rückfalloption verwenden.
            $command = Get-Command winget -ErrorAction SilentlyContinue
            if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source) -and
                (Test-Path -LiteralPath ([string]$command.Source) -PathType Leaf -ErrorAction SilentlyContinue)) {
                return [string]$command.Source
            }
            if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                $aliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
                if (Test-Path -LiteralPath $aliasPath -PathType Leaf -ErrorAction SilentlyContinue) { return $aliasPath }
            }
            return $null
        }

        function Get-WinGetPortableClientFromGitHub {
            # WinGet kann auf Server 2019 experimentell aus einem entpackten
            # GitHub-MSIX-Bundle ausgeführt werden. Die Releaseversion und ein
            # optionaler SHA-256-Wert kommen dynamisch aus GitHub-Metadaten.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
                -Headers @{ 'User-Agent' = 'Server-Update-Skripte'; Accept = 'application/vnd.github+json' } `
                -TimeoutSec 30 -ErrorAction Stop
            $releaseTag = [string]$release.tag_name
            if ([string]::IsNullOrWhiteSpace($releaseTag)) { throw 'GitHub lieferte keinen Tag für das aktuelle WinGet-Release.' }
            $asset = @($release.assets | Where-Object {
                [string]$_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            } | Select-Object -First 1)
            if ($asset.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$asset[0].browser_download_url)) {
                throw "GitHub-Release '$releaseTag' enthält nicht das erwartete App-Installer-MSIX-Bundle."
            }

            $safeTag = [regex]::Replace($releaseTag, '[^A-Za-z0-9._-]', '_')
            $cacheRoot = Join-Path $env:LOCALAPPDATA 'WindowsUpdateAdm\WinGetPortable'
            $packageRoot = Join-Path $cacheRoot $safeTag
            $cachedExecutable = @(Get-ChildItem -LiteralPath $packageRoot -Filter winget.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($cachedExecutable.Count -gt 0) {
                try {
                    $cachedProbe = Invoke-WindowsUpdateHiddenProcess -Path $cachedExecutable[0].FullName -Arguments @('--version') -TimeoutSeconds 30
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
                Invoke-WebRequest -Uri ([string]$asset[0].browser_download_url) -OutFile $bundlePath `
                    -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
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

        function Ensure-WinGetSourcePackageForCurrentUser {
            param([switch]$Refresh)
            # Quelle online im Remoting-Kontext beschaffen, AppX danach aber
            # in einer kurzlebigen Aufgabe unter demselben Benutzer registrieren.
            # So wird der auf SRVTS01 beobachtete PLM-Zugriff aus wsmprovhost vermieden.
            $registered = @(Get-AppxPackage -Name Microsoft.Winget.Source -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending)
            $sourcePath = $null
            $sourceChanged = $false
            $sourceRefreshed = $false
            $registrationTaskResult = $null
            try {
                if ($registered.Count -eq 0 -or $Refresh) {
                    $sourceWasRegistered = $registered.Count -gt 0
                    $sourcePath = Join-Path $env:TEMP ('winget-source-{0}.msix' -f [guid]::NewGuid().ToString('N'))
                    Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache/source2.msix' `
                        -OutFile $sourcePath -UseBasicParsing -ErrorAction Stop

                    $shouldRegister = -not $sourceWasRegistered
                    if ($sourceWasRegistered) {
                        Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                        $archive = [System.IO.Compression.ZipFile]::OpenRead($sourcePath)
                        try {
                            $manifestEntry = $archive.GetEntry('AppxManifest.xml')
                            if (-not $manifestEntry) { throw 'Das WinGet-Quellenpaket enthält kein AppxManifest.xml.' }
                            $manifestReader = [System.IO.StreamReader]::new($manifestEntry.Open())
                            try { $manifest = [xml]$manifestReader.ReadToEnd() }
                            finally { $manifestReader.Dispose() }
                            $downloadVersion = [version]$manifest.Package.Identity.Version
                        } finally { $archive.Dispose() }
                        $installedVersion = [version]$registered[0].Version
                        $shouldRegister = $downloadVersion -gt $installedVersion
                    }

                    if ($shouldRegister) {
                        $quotedSourcePath = "'" + $sourcePath.Replace("'", "''") + "'"
                        $registrationTaskResult = Invoke-WinGetCurrentUserAppxTask -Purpose 'WinGet-Quellenpaket registrieren' -ScriptText @"
`$ErrorActionPreference = 'Stop'
Add-AppxPackage -Path $quotedSourcePath -ErrorAction Stop
"@
                        $registered = @(Get-AppxPackage -Name Microsoft.Winget.Source -ErrorAction Stop |
                            Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending)
                        if ($registered.Count -eq 0) { throw 'Quellenpaket wurde nach der Benutzeraufgabe nicht registriert.' }
                        $sourceChanged = $true
                        $sourceRefreshed = $sourceWasRegistered
                    }
                }
                if ($registered.Count -eq 0) { throw 'WinGet-Quellenpaket ist für den Remoting-Benutzer nicht registriert.' }
                $marker = '__WINGETSOURCE__SUCCESS|{0}|{1}|{2}' -f [string]$registered[0].Version, $sourceChanged, $sourceRefreshed
            }
            finally {
                if ($sourcePath -and (Test-Path -LiteralPath $sourcePath -PathType Leaf)) {
                    Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
                }
            }
            return [pscustomobject]@{
                Changed = $sourceChanged
                Version = [string]$registered[0].Version
                Refreshed = $sourceRefreshed
                Output = $marker
                UserName = if ($registrationTaskResult) { [string]$registrationTaskResult.UserName } else { [string][Security.Principal.WindowsIdentity]::GetCurrent().Name }
                LogonType = if ($registrationTaskResult) { [string]$registrationTaskResult.LogonType } else { '' }
            }
        }

        function Test-WingetExecutable {
            param([string]$Path, [switch]$FreshPowerShell)
            if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                return [PSCustomObject]@{ Works = $false; Output = 'winget.exe wurde nicht gefunden.' }
            }
            try {
                if ($FreshPowerShell) {
                    # Ein Kindprozess liest nach einer Reparatur die aktualisierte
                    # Umgebung neu ein; der Pfad wird dabei trotzdem explizit übergeben.
                    $shellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ Path = $Path; WorkingDirectory = (Split-Path -Parent $Path) } -Compress)))
                    $childSource = @'
$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$wingetArguments = @($data.Arguments)
Set-Location -LiteralPath $data.WorkingDirectory
& $data.Path --version 2>&1
exit $LASTEXITCODE
'@ -replace '__PAYLOAD__', $payload
                    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
                    $output = (& $shellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedChild 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
                } else {
                    Push-Location -LiteralPath (Split-Path -Parent $Path)
                    try {
                    $output = (& $Path --version 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
                    } finally { Pop-Location }
                }
                $works = $exitCode -eq 0 -and $output -match '(?m)^\s*v?\d+\.\d+'
                if ($works) { return [PSCustomObject]@{ Works = $true; Output = "ExitCode=$exitCode; Ausgabe=$output" } }
                $failureSummary = if ($output -match '(?i)(Zugriff verweigert|Access is denied|access denied)') {
                    'Zugriff auf winget.exe verweigert.'
                } else {
                    @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -join ''
                }
                if ([string]::IsNullOrWhiteSpace($failureSummary)) { $failureSummary = "ExitCode=$exitCode; keine Versionsausgabe erhalten." }
                if ($failureSummary.Length -gt 200) { $failureSummary = $failureSummary.Substring(0, 197) + '...' }
                return [PSCustomObject]@{ Works = $false; Output = "ExitCode=$exitCode; $failureSummary"; DiagnosticOutput = $output }
            }
            catch {
                $diagnostic = $_.Exception.ToString()
                $failureSummary = if ($_.Exception.Message -match '(?i)(Zugriff verweigert|Access is denied|access denied)') {
                    'Zugriff auf winget.exe verweigert.'
                } else {
                    ([string]$_.Exception.Message -split "`r?`n")[0].Trim()
                }
                if ([string]::IsNullOrWhiteSpace($failureSummary)) { $failureSummary = 'WinGet-Versionsprüfung fehlgeschlagen.' }
                if ($failureSummary.Length -gt 200) { $failureSummary = $failureSummary.Substring(0, 197) + '...' }
                return [PSCustomObject]@{ Works = $false; Output = $failureSummary; DiagnosticOutput = $diagnostic }
            }
        }

        function Test-WingetModuleApi {
            param([switch]$FreshPowerShell)

            $probeScript = @'
$ErrorActionPreference = 'Stop'
try {
    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
    Assert-WinGetPackageManager -ErrorAction Stop | Out-Null
    $null = @(Get-WinGetPackage -Count 1 -ErrorAction Stop)
    [Console]::Out.WriteLine("WinGet-Modulabfrage erfolgreich (Version $([string](Get-WinGetVersion))).")
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
'@
            try {
                if ($FreshPowerShell) {
                    $shellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
                        throw 'Windows PowerShell 5.1 wurde für die frische WinGet-Prüfung nicht gefunden.'
                    }
                    $encodedProbe = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeScript))
                    $output = (& $shellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedProbe 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
                }
                else {
                    $ErrorActionPreference = 'Stop'
                    Import-Module Microsoft.WinGet.Client -ErrorAction Stop
                    Assert-WinGetPackageManager -ErrorAction Stop | Out-Null
                    $null = @(Get-WinGetPackage -Count 1 -ErrorAction Stop)
                    $output = "WinGet-Modulabfrage erfolgreich (Version $([string](Get-WinGetVersion)))."
                    $exitCode = 0
                }
                $works = $exitCode -eq 0
                $diagnostic = [string]$output
            }
            catch {
                $works = $false
                $diagnostic = $_.Exception.ToString()
            }

            $summary = if ($works) {
                ([string]$diagnostic -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Last 1).Trim()
            }
            else {
                ([string]$diagnostic -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($summary)) { $summary = 'WinGet-Modulabfrage fehlgeschlagen.' }
            if ($summary.Length -gt 200) { $summary = $summary.Substring(0, 197) + '...' }
            $rpcFailure = -not $works -and $diagnostic -match '(?i)(0x800706ba|-2147023174|Failed to create instance|RPC-Server nicht verfügbar|RPC server is unavailable)'
            return [PSCustomObject]@{
                Works = $works
                RepairRequired = $rpcFailure
                Output = $summary
                DiagnosticOutput = $diagnostic
            }
        }

        function Test-WingetSourceFailureLine {
            param([string]$Line)
            return $Line -match '(?i)(Fehler bei der WinGet-Abfrage für Quelle|Fehler beim Durchsuchen der Quelle|Fehler beim Versuch, die Quelle zu aktualisieren|Fehler beim Aktualisieren der Quelle|An error occurred while searching the source|Failed when searching (?:the )?source|Failed in attempting to update the source|error occurred while updating source)'
        }

        function Test-WingetNonPackageOutputLine {
            param([AllowNull()][string]$Line)
            if ([string]::IsNullOrWhiteSpace($Line)) { return $true }
            return $Line -match '(?i)([\u2580-\u259F]|\d+(?:\.\d+)?\s*(?:KB|MB|GB)\s*/\s*\d+(?:\.\d+)?\s*(?:KB|MB|GB)|\b\d{1,3}%\b|Terms of Transaction|terms of use|Nutzungsbedingungen|Vereinbarungen der Quelle|Vereinbarungen vor der Verwendung|geographic region|geografische Region|two-letter region|zwei Buchstaben.*Region|accept.*agreement|Zustimmung.*Vereinbarung|no installed package found|es wurde kein installiertes Paket gefunden|no available upgrade|no upgrades available|keine Paketupdates verfügbar|keine Aktualisierungen verfügbar|failed when searching|Fehler beim Durchsuchen der Quelle|Ergebnisse werden nicht einbezogen|results? (?:are )?not included|(?:packages?|pakete)\s+(?:have|verfügen über)\s+pins?|^\s*\d+\s+pakete?\s+verf.{1,2}gen\s+.{0,10}pins?\b.*(?:ergebnisse|results?)|pins?\s+(?:prevent|verhindern)\s+(?:an?\s+)?upgrade|Store terms|Store-Bedingungen)'
        }

        function Get-WingetCompactOutput {
            param([AllowNull()][string]$Text, [int]$MaximumLength = 500)
            if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
            $clean = [regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
            $lines = @($clean -split "`r?`n" | ForEach-Object { ([string]$_).Trim() } | Where-Object {
                $_ -and
                $_ -notmatch '[\u2580-\u259F]' -and
                $_ -notmatch '\u00e2\u2013' -and
                $_ -notmatch '^[-\\|/](?:\s*[-\\|/]){2,}' -and
                $_ -notmatch '(?i)\d+(?:\.\d+)?\s*(?:KB|MB|GB)\s*/\s*\d+(?:\.\d+)?\s*(?:KB|MB|GB)'
            })
            $summary = $lines -join ' '
            if ($summary.Length -gt $MaximumLength) { $summary = $summary.Substring(0, $MaximumLength - 3) + '...' }
            return $summary
        }

        function Get-WingetUpgradeLines {
            param([string]$Output, [string]$DefaultSource = 'winget')
            $rowPattern = '^\s*(?<Name>.+)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<InstalledVersion>\S+)\s+(?<AvailableVersion>\S+)(?:\s+(?<Source>\S+))?\s*$'
            $rows = foreach ($line in ($Output -split "`r?`n")) {
                if (Test-WingetSourceFailureLine -Line $line) { continue }
                if (Test-WingetNonPackageOutputLine -Line $line) { continue }
                # Je nach WinGet-Version und Umleitung heißen Tabellenköpfe
                # Name/Id/Version oder SearchName/SearchId/SearchVersion.
                # Sie sehen sonst wie eine Paketzeile aus und würden gezählt.
                $headerColumns = @($line.Trim() -split '\s+')
                if ($headerColumns.Count -ge 4 -and
                    $headerColumns[0] -in @('Name', 'SearchName') -and
                    $headerColumns[1] -in @('Id', 'SearchId') -and
                    $headerColumns[2] -in @('Version', 'SearchVersion')) { continue }
                $match = [regex]::Match($line, $rowPattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if (-not $match.Success) { continue }
                if ($match.Groups['Id'].Value -in @('Id', 'SearchId') -or
                    $match.Groups['InstalledVersion'].Value -in @('Version', 'SearchVersion') -or
                    $match.Groups['AvailableVersion'].Value -in @('Available', 'AvailableHeader')) { continue }
                $source = if ($match.Groups['Source'].Success) { $match.Groups['Source'].Value } else { $DefaultSource }
                [string]::Format('{0}  {1}  {2}  {3}  {4}',
                    $match.Groups['Name'].Value.Trim(), $match.Groups['Id'].Value,
                    $match.Groups['InstalledVersion'].Value, $match.Groups['AvailableVersion'].Value, $source)
            }
            return @($rows)
        }

        function Invoke-WingetCliUpgradeQuery {
            param(
                [Parameter(Mandatory)][string]$Path,
                [ValidateSet('machine', 'user')][string]$Scope
            )
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw 'winget.exe wurde für den CLI-Fallback nicht gefunden.'
            }
            $cliResult = Invoke-WingetRunspaceWithTimeout -ArgumentList @($Path, $Scope) -TimeoutSeconds 210 -ScriptBlock {
                param([string]$WingetPath, [string]$QueryScope)
                $ErrorActionPreference = 'Stop'
                $runtimeContext = [pscustomobject]@{
                    Executable = $WingetPath
                    User = [Security.Principal.WindowsIdentity]::GetCurrent().Name
                    UserSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
                    PowerShell = $PSVersionTable.PSVersion.ToString()
                }
                try {
                    $utf8 = [System.Text.UTF8Encoding]::new($false)
                    [Console]::OutputEncoding = $utf8
                    $OutputEncoding = $utf8
                } catch { }
                function Remove-WingetProgressOutput {
                    param([AllowNull()][string]$Text)
                    if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
                    $clean = [regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
                    $clean = $clean -replace "`r`n", "`n" -replace "`r", "`n"
                    $keptLines = foreach ($line in ($clean -split "`n")) {
                        $trimmed = ([string]$line).Trim()
                        if ([string]::IsNullOrWhiteSpace($trimmed)) { continue }
                        if ($trimmed -match '[\u2580-\u259F]' -or
                            $trimmed -match '(?i)\d+(?:\.\d+)?\s*(?:KB|MB|GB)\s*/\s*\d+(?:\.\d+)?\s*(?:KB|MB|GB)' -or
                            $trimmed -match '^\s*(?:[-\\|/]\s*){1,3}$' -or
                            $trimmed -match '^\s*\d{1,3}%\s*$') { continue }
                        $trimmed
                    }
                    return (@($keptLines) -join [Environment]::NewLine)
                }
                function Invoke-WingetCliHidden {
                    param([Parameter(Mandatory)][string]$Executable, [string[]]$Arguments)
                    $quotedArguments = foreach ($argument in $Arguments) {
                        $value = [string]$argument
                        if ($value -match '[\s"]') { '"' + $value.Replace('"', '\"') + '"' } else { $value }
                    }
                    $startInfo = [Diagnostics.ProcessStartInfo]::new()
                    $startInfo.FileName = $Executable
                    $startInfo.Arguments = $quotedArguments -join ' '
                    $startInfo.WorkingDirectory = Split-Path -Parent $Executable
                    $startInfo.UseShellExecute = $false
                    $startInfo.CreateNoWindow = $true
                    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
                    $startInfo.RedirectStandardOutput = $true
                    $startInfo.RedirectStandardError = $true
                    $process = [Diagnostics.Process]::new()
                    try {
                        $process.StartInfo = $startInfo
                        if (-not $process.Start()) { throw 'winget.exe konnte nicht gestartet werden.' }
                        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                        $stderrTask = $process.StandardError.ReadToEndAsync()
                        if (-not $process.WaitForExit(180000)) {
                            try { $process.Kill() } catch { }
                            throw 'winget.exe überschritt das Zeitlimit von 3 Minuten.'
                        }
                        $process.WaitForExit()
                        $output = @($stdoutTask.GetAwaiter().GetResult(), $stderrTask.GetAwaiter().GetResult()) |
                            Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                        [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($output -join [Environment]::NewLine) }
                    }
                    finally { $process.Dispose() }
                }
                try {
                    $sourceListResult = Invoke-WingetCliHidden -Executable $WingetPath -Arguments @('source', 'list', '--disable-interactivity')
                    $sourceListOutput = Remove-WingetProgressOutput -Text ([string]$sourceListResult.Output)
                    $sourceListExitCode = [int]$sourceListResult.ExitCode
                    $sourceListError = ''
                }
                catch {
                    [pscustomobject]@{
                        Success = $false; SourceListOutput = ''; SourceListExitCode = -1
                        SourceListError = $_.Exception.ToString(); Context = $runtimeContext
                        Sources = @(); SkippedSources = @(); Results = @()
                    }
                    return
                }
                $explicitSourceNames = @()
                $skippedSources = @()
                if ($sourceListExitCode -eq 0) {
                    foreach ($line in ($sourceListOutput -split "`r?`n")) {
                        if ($line -match '^\s*Name\b' -or $line -match '^\s*[-=]{3,}') { continue }
                        if ($line -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?<Explicit>true|false)\s*$') {
                            $sourceName = $Matches.Name
                            if ($sourceName -ieq 'winget-font') {
                                # Integrierte, standardmäßig explizite Quelle für Schriftarten;
                                # sie ist keine allgemeine Quelle für App-Updates.
                                $skippedSources += $sourceName
                                continue
                            }
                            # Alle nicht expliziten Quellen werden gemeinsam abgefragt.
                            # Kundeneigene explizite Quellen brauchen einen eigenen Aufruf.
                            if ($Matches.Explicit -ieq 'true') { $explicitSourceNames += $sourceName }
                        }
                    }
                    $explicitSourceNames = @($explicitSourceNames | Select-Object -Unique)
                }

                if ($sourceListExitCode -ne 0) {
                    [pscustomobject]@{
                        Success = $false; SourceListOutput = $sourceListOutput; SourceListExitCode = $sourceListExitCode
                        SourceListError = ''; Context = $runtimeContext
                        Sources = @(); SkippedSources = @($skippedSources); Results = @()
                    }
                    return
                }

                $sourceResults = @()
                $queryDefinitions = @([pscustomobject]@{ Source = '(Standardquellen)'; Explicit = $false })
                foreach ($sourceName in $explicitSourceNames) {
                    $queryDefinitions += [pscustomobject]@{ Source = $sourceName; Explicit = $true }
                }
                foreach ($queryDefinition in $queryDefinitions) {
                    $sourceName = [string]$queryDefinition.Source
                    $arguments = @(
                        'list', '--upgrade-available',
                        '--accept-source-agreements', '--disable-interactivity'
                    )
                    if (-not [string]::IsNullOrWhiteSpace($QueryScope)) { $arguments += @('--scope', $QueryScope) }
                    if ($queryDefinition.Explicit) { $arguments += @('--source', $sourceName) }
                    try {
                        $queryResult = Invoke-WingetCliHidden -Executable $WingetPath -Arguments $arguments
                        $output = Remove-WingetProgressOutput -Text ([string]$queryResult.Output)
                        $sourceResults += [pscustomobject]@{
                            Source = $sourceName; Output = $output; ExitCode = [int]$queryResult.ExitCode; Error = ''
                        }
                    }
                    catch {
                        $sourceResults += [pscustomobject]@{
                            Source = $sourceName; Output = ''; ExitCode = -1; Error = $_.Exception.ToString()
                        }
                    }
                }
                [pscustomobject]@{
                    Success = $true; SourceListOutput = $sourceListOutput; SourceListExitCode = $sourceListExitCode
                    SourceListError = $sourceListError; Context = $runtimeContext
                    Sources = @($queryDefinitions | ForEach-Object { $_.Source }); SkippedSources = @($skippedSources)
                    Results = @($sourceResults)
                }
            } | Select-Object -Last 1
            if (-not $cliResult) { throw 'WinGet-CLI-Abfrage lieferte keine Rückgabe.' }

            $context = $cliResult.Context
            $diagnostics = @(
                "WinGet-CLI-Kontext: Benutzer=$($context.User); SID=$($context.UserSid); PowerShell=$($context.PowerShell); Pfad=$($context.Executable)"
                "Quellenliste (Exitcode $($cliResult.SourceListExitCode)):`r`n$($cliResult.SourceListOutput)"
            )
            if (-not [string]::IsNullOrWhiteSpace([string]$cliResult.SourceListError)) {
                $diagnostics += "Quellenlistenaufruf-Ausnahme:`r`n$($cliResult.SourceListError)"
            }
            if (@($cliResult.SkippedSources).Count -gt 0) {
                $diagnostics += "Übersprungene integrierte Quellen ohne App-Updates: $(@($cliResult.SkippedSources) -join ', ')."
            }
            if (-not $cliResult.Success) {
                $exception = [System.InvalidOperationException]::new('WinGet-Quellen konnten für den CLI-Fallback nicht zuverlässig ermittelt werden.')
                $exception.Data['WinGetDiagnosticOutput'] = $diagnostics -join "`r`n"
                throw $exception
            }

            $allRows = @()
            $sourceFailures = @()
            $seenPackages = @{}
            foreach ($sourceResult in @($cliResult.Results)) {
                $sourceName = [string]$sourceResult.Source
                $sourceOutput = [string]$sourceResult.Output
                $sourceExitCode = [int]$sourceResult.ExitCode
                $sourceErrorProperty = $sourceResult.PSObject.Properties['Error']
                if ($sourceErrorProperty -and -not [string]::IsNullOrWhiteSpace([string]$sourceErrorProperty.Value)) {
                    $diagnostics += "Quelle '$sourceName' (Startfehler):`r`n$([string]$sourceErrorProperty.Value)"
                } else {
                    $diagnostics += "Quelle '$sourceName' (Exitcode $sourceExitCode):`r`n$sourceOutput"
                }
                # list --upgrade-available verwendet bei erfolgreicher Leerabfrage
                # je nach WinGet-Version/Quelle einen Nicht-Null-Exitcode.
                $reportedSourceFailure = @($sourceOutput -split "`r?`n" | Where-Object {
                    Test-WingetSourceFailureLine -Line ([string]$_)
                }).Count -gt 0
                $successfulEmptyResult = -not $reportedSourceFailure -and
                    $sourceOutput -match '(?i)(no installed package found matching input criteria|es wurde kein installiertes paket gefunden, das den eingabekriterien entspricht|no available upgrade|no upgrades available|keine paketupdates verfügbar|keine aktualisierungen verfügbar|0 upgrades? available|0 paketupdates? verfügbar)'
                if (($sourceExitCode -ne 0 -and -not $successfulEmptyResult) -or $reportedSourceFailure) {
                    $detail = if ($sourceErrorProperty -and -not [string]::IsNullOrWhiteSpace([string]$sourceErrorProperty.Value)) {
                        Get-WingetCompactOutput -Text ([string]$sourceErrorProperty.Value) -MaximumLength 500
                    } else {
                        $failureLine = @($sourceOutput -split "`r?`n" | Where-Object {
                            Test-WingetSourceFailureLine -Line ([string]$_)
                        } | Select-Object -First 1)
                        if ($failureLine.Count -gt 0) { Get-WingetCompactOutput -Text ([string]$failureLine[0]) -MaximumLength 500 }
                        else { Get-WingetCompactOutput -Text $sourceOutput -MaximumLength 500 }
                    }
                    if ([string]::IsNullOrWhiteSpace($detail)) { $detail = "winget.exe list --upgrade-available endete mit Exitcode $sourceExitCode." }
                    $sourceFailures += "Fehler bei der WinGet-Abfrage für Quelle '$sourceName' - $detail"
                    continue
                }

                $defaultSource = if ($sourceName -eq '(Standardquellen)') { 'winget' } else { $sourceName }
                foreach ($row in @(Get-WingetUpgradeLines -Output $sourceOutput -DefaultSource $defaultSource)) {
                    $match = [regex]::Match($row, '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<Installed>\S+)\s+(?<Available>\S+)\s+(?<Source>\S+)\s*$')
                    if (-not $match.Success) { continue }
                    $packageKey = '{0}|{1}' -f $match.Groups['Id'].Value.ToLowerInvariant(), $match.Groups['Source'].Value.ToLowerInvariant()
                    if ($seenPackages.ContainsKey($packageKey)) { continue }
                    $seenPackages[$packageKey] = $true
                    $allRows += $row
                }
            }

            [pscustomobject]@{
                Output = (@($allRows) + @($sourceFailures)) -join [Environment]::NewLine
                DiagnosticOutput = $diagnostics -join "`r`n"
                Sources = @($cliResult.Sources)
                SkippedSources = @($cliResult.SkippedSources)
                FailedSources = @($sourceFailures)
            }
        }

        function Get-WingetInteractiveUserUpgradeLines {
            param([switch]$InstallUpdates)
            # WinGet läuft im WinRM-Aufruf unter dem Remoting-Konto. Dadurch
            # fehlen benutzerbezogene Installationen anderer angemeldeter
            # Benutzer (z. B. VS Code User). Die Zusatzabfrage läuft als
            # kurzlebige interaktive Aufgabe in deren vorhandener Sitzung.
            # Im Check wird nur gelesen; beim Installieren werden die gefundenen
            # Pakete in genau diesem Benutzerkontext aktualisiert. Auf Windows
            # Servern wird diese Zusatzabfrage absichtlich ausgelassen: Dort
            # sind keine benutzerbezogenen Serverpakete vorgesehen, und Aufgaben
            # im angemeldeten interaktiven Benutzerkontext können hängen bleiben.
            $upgradeLines = @()
            $notes = @()
            $packageResults = @()
            if (-not $IncludeInteractiveUserUpdates) {
                return [pscustomobject]@{
                    Lines = @()
                    Notes = @('Benutzerbezogene WinGet-Zusatzprüfung wurde für diesen Lauf über die Settings oder per -SkipWingetUserUpdates deaktiviert.')
                    Packages = @()
                }
            }
            try {
                $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $productType = [int]$operatingSystem.ProductType
            }
            catch {
                return [pscustomobject]@{
                    Lines = @()
                    Notes = @("Benutzerbezogene WinGet-Prüfung vorsorglich ausgelassen: Windows-Produkttyp konnte nicht ermittelt werden ($($_.Exception.Message)).")
                }
            }
            if ($productType -ne 1) {
                return [pscustomobject]@{
                    Lines = @()
                    Notes = @("Benutzerbezogene WinGet-Prüfung und -Installation auf Windows Server ausgelassen (ProductType $productType). Maschinenweite WinGet-Updates und Chocolatey laufen weiter.")
                }
            }
            $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $currentIdentity = [Security.Principal.WindowsIdentity]::GetCurrent().Name

            # Entferne verwaiste, nicht mehr laufende Aufgaben aus abgebrochenen
            # WinGet-Benutzerläufen. Aktive Aufgaben bleiben unangetastet, damit
            # parallele Installationsläufe nicht unterbrochen werden.
            try {
                $orphanedTasks = @(Get-ScheduledTask -ErrorAction Stop |
                    Where-Object { $_.TaskName -like 'WindowsUpdateAdm-WinGetCheck-*' -or $_.TaskName -like 'WindowsUpdateAdm-WinGetInstall-*' })
                $removedTaskCount = 0
                $activeTaskCount = 0
                foreach ($orphanedTask in $orphanedTasks) {
                    if ([string]$orphanedTask.State -eq 'Running') {
                        $activeTaskCount++
                        continue
                    }
                    try {
                        Unregister-ScheduledTask -TaskName $orphanedTask.TaskName -TaskPath $orphanedTask.TaskPath -Confirm:$false -ErrorAction Stop
                        $removedTaskCount++
                    } catch {
                        $notes += "Verwaiste WinGet-Aufgabe '$($orphanedTask.TaskPath)$($orphanedTask.TaskName)' konnte nicht entfernt werden: $($_.Exception.Message)"
                    }
                }
                if ($removedTaskCount -gt 0) { $notes += "$removedTaskCount verwaiste, nicht laufende WinGet-Benutzeraufgabe(n) aus früheren Läufen entfernt." }
                if ($activeTaskCount -gt 0) { $notes += "$activeTaskCount aktive WinGet-Benutzeraufgabe(n) aus früheren oder parallelen Läufen bleiben unangetastet." }
            } catch {
                $notes += "Verwaiste WinGet-Benutzeraufgaben konnten nicht geprüft werden: $($_.Exception.Message)"
            }

            $users = @{}
            $explorerProcesses = @()
            try {
                $explorerProcesses = @(Get-CimInstance -ClassName Win32_Process -Filter "Name='explorer.exe'" -ErrorAction Stop)
                foreach ($process in $explorerProcesses) {
                    if ([int]$process.SessionId -eq 0) { continue }
                    $owner = Invoke-CimMethod -InputObject $process -MethodName GetOwner -ErrorAction Stop
                    $ownerSid = Invoke-CimMethod -InputObject $process -MethodName GetOwnerSid -ErrorAction Stop
                    if ($owner.ReturnValue -ne 0 -or $ownerSid.ReturnValue -ne 0 -or
                        [string]::IsNullOrWhiteSpace([string]$ownerSid.Sid) -or $ownerSid.Sid -eq $currentSid) { continue }
                    if (-not $users.ContainsKey([string]$ownerSid.Sid)) {
                        $users[[string]$ownerSid.Sid] = '{0}\{1}' -f [string]$owner.Domain, [string]$owner.User
                    }
                }
            }
            catch {
                return [pscustomobject]@{ Lines = @(); Notes = @("Abfrage angemeldeter Benutzer nicht möglich: $($_.Exception.Message)") }
            }

            $notes += "Benutzerbezogene WinGet-Prüfung gestartet: Remoting-Konto='$currentIdentity'; interaktive Explorer-Sitzungen=$($explorerProcesses.Count); andere Benutzerprofile=$($users.Count); Modus=$(if ($InstallUpdates) { 'Install' } else { 'Check' })."

            foreach ($userSid in @($users.Keys)) {
                $userName = [string]$users[$userSid]
                $userCheckStartedAt = Get-Date
                $notes += "Benutzerabfrage vorbereitet: Konto='$userName'; SID='$userSid'; LogonType=Interactive; Quelle=winget; Scope=user."
                $taskPurpose = if ($InstallUpdates) { 'Install' } else { 'Check' }
                $taskName = "WindowsUpdateAdm-WinGet$taskPurpose-" + [guid]::NewGuid().ToString('N')
                # Die Aufgabe läuft mit dem normalen Benutzerkonto. C:\Windows\Temp
                # ist je nach ACL nicht zuverlässig beschreibbar; dann blieb die
                # Rückgabedatei aus und der Aufrufer wartete unnötig fünf Minuten.
                $userProfile = Get-CimInstance -ClassName Win32_UserProfile -Filter "SID='$userSid'" -ErrorAction SilentlyContinue |
                    Select-Object -First 1
                if (-not $userProfile -or [string]::IsNullOrWhiteSpace([string]$userProfile.LocalPath)) {
                    $notes += "Benutzerbezogene WinGet-Abfrage für '$userName' nicht möglich: Benutzerprofil wurde nicht gefunden."
                    if ($InstallUpdates) {
                        $packageResults += [pscustomobject]@{
                            Name = 'WinGet-Benutzerupdates'; Id = ''; InstalledVersion = ''
                            AvailableVersion = ''; Source = 'winget'; UserName = $userName
                            Success = $false; ExitCode = 1; Output = 'Benutzerprofil wurde nicht gefunden.'
                        }
                    }
                    continue
                }
                $userTempPath = Join-Path ([string]$userProfile.LocalPath) 'AppData\Local\Temp'
                if (-not (Test-Path -LiteralPath $userTempPath -PathType Container)) {
                    $notes += "Benutzerbezogene WinGet-Abfrage für '$userName' nicht möglich: Profil-Tempverzeichnis fehlt."
                    if ($InstallUpdates) {
                        $packageResults += [pscustomobject]@{
                            Name = 'WinGet-Benutzerupdates'; Id = ''; InstalledVersion = ''
                            AvailableVersion = ''; Source = 'winget'; UserName = $userName
                            Success = $false; ExitCode = 1; Output = 'Profil-Tempverzeichnis fehlt.'
                        }
                    }
                    continue
                }
                $resultPath = Join-Path $userTempPath "$taskName.json"
                $progressPath = Join-Path $userTempPath "$taskName.progress.json"
                $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
                    $notes += "Abfrage für '$userName' übersprungen: Windows PowerShell fehlt."
                    continue
                }

                $resultPathJson = ConvertTo-Json -InputObject $resultPath -Compress
                $progressPathJson = ConvertTo-Json -InputObject $progressPath -Compress
                $queryScript = @'
$ErrorActionPreference = 'Stop'
$resultPath = __RESULT_PATH__
$progressPath = __PROGRESS_PATH__
$query = [ordered]@{ Success = $false; Output = ''; ExitCode = -1; Error = ''; Packages = @(); AccountIsAdministratorMember = $false; TokenIsElevated = $false }
try {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    $adminGroupSid = 'S-1-5-32-544'
    $query.AccountIsAdministratorMember = @($identity.Groups | ForEach-Object { $_.Value }) -contains $adminGroupSid
    $query.TokenIsElevated = ([Security.Principal.WindowsPrincipal]::new($identity)).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    $app = Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
        Where-Object { $_.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
        Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending |
        Select-Object -First 1
    if (-not $app) { throw 'App Installer ist für diesen Benutzer nicht registriert.' }
    $winget = Join-Path ([string]$app.InstallLocation) 'winget.exe'
    if (-not (Test-Path -LiteralPath $winget -PathType Leaf)) { throw 'winget.exe wurde im Benutzerkontext nicht gefunden.' }
    $startInfo = [Diagnostics.ProcessStartInfo]::new()
    $startInfo.FileName = $winget
    # Die Benutzerabfrage beschränkt sich auf die WinGet-Communityquelle.
    # msstore kann trotz NonInteractive-Option eine interaktive Zustimmung
    # anfordern und dadurch die geplante Aufgabe bis zum Timeout blockieren.
    $startInfo.Arguments = 'list --upgrade-available --scope user --source winget --accept-source-agreements --disable-interactivity'
    $startInfo.UseShellExecute = $false
    $startInfo.CreateNoWindow = $false
    $startInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
    $startInfo.RedirectStandardInput = $true
    $startInfo.RedirectStandardOutput = $true
    $startInfo.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $startInfo
        if (-not $process.Start()) { throw 'winget.exe konnte nicht gestartet werden.' }
        $process.StandardInput.Close()
        $stdoutTask = $process.StandardOutput.ReadToEndAsync()
        $stderrTask = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(270000)) {
            try { $process.Kill() } catch { }
            throw 'winget.exe überschritt das Zeitlimit von viereinhalb Minuten.'
        }
        $process.WaitForExit()
        if (-not [Threading.Tasks.Task]::WaitAll([Threading.Tasks.Task[]]@($stdoutTask, $stderrTask), 10000)) {
            throw 'winget.exe wurde beendet, aber seine Ausgabekanäle wurden nicht geschlossen; die Benutzerabfrage wird als Fehler zurückgegeben.'
        }
        $query.ExitCode = [int]$process.ExitCode
        $stdout = $stdoutTask.GetAwaiter().GetResult()
        $stderr = $stderrTask.GetAwaiter().GetResult()
    }
    finally { $process.Dispose() }
    $outputParts = @()
    if (-not [string]::IsNullOrWhiteSpace($stdout)) { $outputParts += $stdout.Trim() }
    if (-not [string]::IsNullOrWhiteSpace($stderr)) { $outputParts += $stderr.Trim() }
    $query.Output = ($outputParts -join [Environment]::NewLine).Trim()
    $query.Success = ($query.ExitCode -eq 0 -or $query.Output -match '(?i)(no installed package found|es wurde kein installiertes paket gefunden|no available upgrade|no upgrades available|keine paketupdates verfügbar|keine aktualisierungen verfügbar)')
    if (__INSTALL_UPDATES__ -and $query.Success) {
        # Nur Zeilen innerhalb der eigentlichen WinGet-Tabelle werten. Vor
        # der Tabelle können Hinweise und Quellenabfragen dieselbe Spaltenform
        # haben und dürfen nicht als Paketupdates installiert werden.
        # Der Tabellenkopf kann durch die Windows-PowerShell-5.1-Ausgabeumleitung
        # falsch dekodierte Umlaute enthalten (z. B. "Verf├╝gbar"). Die ersten
        # drei Spaltennamen sind stabil; die Bezeichnung der vierten Spalte nicht.
        $headerPattern = '^\s*(?:Name|SearchName)\s+(?:Id|SearchId)\s+(?:Version|SearchVersion)\s+\S+(?:\s+\S+)?\s*$'
        # WinGet richtet Spalten mit variabler Breite aus. Zwischen ID und
        # Versionswerten kann dabei nur ein Leerzeichen stehen.
        $packagePattern = '^\s*(?<Name>.+?)\s{2,}(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<Installed>\S+)\s+(?<Available>\S+)(?:\s+(?<Source>\S+))?\s*$'
        $tableHeaderSeen = $false
        $tableActive = $false
        $packagesToInstall = @()
        foreach ($line in @($query.Output -split "`r?`n")) {
            if (-not $tableActive) {
                if ($line -match $headerPattern) { $tableHeaderSeen = $true; continue }
                # WinGet kann die Trennlinie als einen durchgehenden Strichlauf
                # oder in Spaltengruppen ausgeben.
                if ($tableHeaderSeen -and $line -match '^\s*-{3,}(?:\s+-{2,})*\s*$') { $tableActive = $true; continue }
                continue
            }
            if ([string]::IsNullOrWhiteSpace([string]$line)) { break }
            $match = [regex]::Match([string]$line, $packagePattern)
            if (-not $match.Success) { continue }
            $packagesToInstall += [ordered]@{
                Name = $match.Groups['Name'].Value.Trim()
                Id = $match.Groups['Id'].Value
                InstalledVersion = $match.Groups['Installed'].Value
                AvailableVersion = $match.Groups['Available'].Value
                Source = if ($match.Groups['Source'].Success) { $match.Groups['Source'].Value } else { 'winget' }
                Success = $false
                ExitCode = -1
                Output = ''
            }
        }
        $progress = [ordered]@{
            PackageCount = @($packagesToInstall).Count
            DetectedAtUtc = [DateTime]::UtcNow.ToString('o')
        }
        $temporaryProgressPath = "$progressPath.tmp"
        [IO.File]::WriteAllText($temporaryProgressPath, ($progress | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $progressPath -PathType Leaf) { Remove-Item -LiteralPath $progressPath -Force }
        [IO.File]::Move($temporaryProgressPath, $progressPath)
        foreach ($package in $packagesToInstall) {
            $arguments = @(
                'upgrade', '--id', $package.Id, '--exact', '--scope', 'user', '--source', $package.Source,
                '--version', $package.AvailableVersion, '--silent',
                '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
            )
            $quotedArguments = foreach ($argument in $arguments) {
                $value = [string]$argument
                if ($value -match '[\s"]') { '"' + $value.Replace('"', '\\"') + '"' } else { $value }
            }
            $installInfo = [Diagnostics.ProcessStartInfo]::new()
            $installInfo.FileName = $winget
            $installInfo.Arguments = $quotedArguments -join ' '
            $installInfo.UseShellExecute = $false
            $installInfo.CreateNoWindow = $false
            $installInfo.WindowStyle = [Diagnostics.ProcessWindowStyle]::Normal
            $installInfo.RedirectStandardInput = $true
            $installInfo.RedirectStandardOutput = $true
            $installInfo.RedirectStandardError = $true
            $installer = [Diagnostics.Process]::new()
            try {
                $installer.StartInfo = $installInfo
                if (-not $installer.Start()) { throw 'winget.exe konnte nicht gestartet werden.' }
                $installer.StandardInput.Close()
                $stdoutTask = $installer.StandardOutput.ReadToEndAsync()
                $stderrTask = $installer.StandardError.ReadToEndAsync()
                if (-not $installer.WaitForExit(900000)) {
                    try { $installer.Kill() } catch { }
                    throw "WinGet-Installation für $($package.Id) überschritt das Zeitlimit von 15 Minuten."
                }
                $installer.WaitForExit()
                $package.ExitCode = [int]$installer.ExitCode
                $installOutput = @($stdoutTask.GetAwaiter().GetResult(), $stderrTask.GetAwaiter().GetResult()) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                $package.Output = ($installOutput -join [Environment]::NewLine).Trim()
                $package.Success = ($package.ExitCode -eq 0 -and $package.Output -notmatch '(?i)(Installation fehlgeschlagen|installation failed|abgebrochen|cancelled)')
            }
            catch {
                $package.Output = $_.Exception.Message
                if ($package.ExitCode -lt 0) { $package.ExitCode = 1 }
                $package.Success = $false
            }
            finally { $installer.Dispose() }
            $query.Packages += $package
        }
    }
}
catch { $query.Error = $_.Exception.ToString() }
finally {
    try {
        $temporaryResultPath = "$resultPath.tmp"
        [IO.File]::WriteAllText($temporaryResultPath, ($query | ConvertTo-Json -Compress), [Text.Encoding]::UTF8)
        if (Test-Path -LiteralPath $resultPath -PathType Leaf) { Remove-Item -LiteralPath $resultPath -Force }
        [IO.File]::Move($temporaryResultPath, $resultPath)
    } catch { }
}
'@
                $queryScript = $queryScript.Replace('__RESULT_PATH__', $resultPathJson)
                $queryScript = $queryScript.Replace('__PROGRESS_PATH__', $progressPathJson)
                $installUpdatesLiteral = if ($InstallUpdates) { '$true' } else { '$false' }
                $queryScript = $queryScript.Replace('__INSTALL_UPDATES__', $installUpdatesLiteral)
                $encodedQuery = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($queryScript))
                $taskRegistered = $false
                try {
                    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
                    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedQuery"
                    # Task Scheduler resolves an interactive logon more reliably by
                    # the canonical account name than by the user's SID. On some
                    # targets the SID principal is reported as not logged on even
                    # while that user's console session is active.
                    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType Interactive -RunLevel Limited
                    $notes += "Benutzeraufgabe wird mit interaktivem Principal '$userName' (SID '$userSid') registriert."
                    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
                    $taskRegistered = $true
                    $taskStartedAt = Get-Date
                    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    # Die Paketabfrage erhält fünf Minuten. Danach bekommt die
                    # Aufgabe 15 Minuten je erkanntem Paket, insgesamt höchstens 90 Minuten.
                    $taskTimeoutSeconds = 300
                    $deadline = $taskStartedAt.AddSeconds($taskTimeoutSeconds)
                    $maximumDeadline = $taskStartedAt.AddMinutes(90)
                    $progressApplied = $false
                    while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and (Get-Date) -lt $deadline) {
                        if ($InstallUpdates -and -not $progressApplied -and (Test-Path -LiteralPath $progressPath -PathType Leaf)) {
                            try {
                                $progress = Get-Content -LiteralPath $progressPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                                $packageCount = [Math]::Max(0, [int]$progress.PackageCount)
                                $detectedAt = [DateTime]::Parse([string]$progress.DetectedAtUtc).ToLocalTime()
                                if ($packageCount -gt 0) {
                                    $packageBudgetSeconds = [Math]::Min(5400, $packageCount * 900)
                                    $packageDeadline = $detectedAt.AddSeconds($packageBudgetSeconds)
                                    $deadline = if ($packageDeadline -lt $maximumDeadline) { $packageDeadline } else { $maximumDeadline }
                                    $taskTimeoutSeconds = [Math]::Max(0, [int][Math]::Ceiling(($deadline - $taskStartedAt).TotalSeconds))
                                    $notes += "Benutzerbezogene WinGet-Installation für '$userName': $packageCount Paket(e), 15 Minuten je Paket; berechnetes Gesamtzeitlimit $([Math]::Round(($deadline - $taskStartedAt).TotalMinutes, 1)) Minuten (maximal 90)."
                                }
                                $progressApplied = $true
                            } catch {
                                $notes += "Zeitlimit für die Benutzeraufgabe von '$userName' konnte nicht aus der Paketanzahl berechnet werden: $($_.Exception.Message)"
                                $progressApplied = $true
                            }
                        }
                        $taskState = $null
                        $taskInfo = $null
                        try {
                            $taskState = (Get-ScheduledTask -TaskName $taskName -ErrorAction Stop).State
                            $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction Stop
                        } catch { }
                        if ($taskState -eq 'Ready' -and $taskInfo -and $taskInfo.LastRunTime -ge $taskStartedAt) {
                            throw "Benutzeraufgabe für '$userName' wurde beendet, ohne eine Ergebnisdatei zu schreiben (LastTaskResult=$($taskInfo.LastTaskResult))."
                        }
                        Start-Sleep -Milliseconds 500
                    }
                    if (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                        $taskResult = if ($taskInfo) { "; LastTaskResult=$($taskInfo.LastTaskResult)" } else { '' }
                        throw "Benutzerbezogene WinGet-Aufgabe für '$userName' blieb $taskTimeoutSeconds Sekunden ohne Rückgabe$taskResult."
                    }
                    $userQuery = Get-Content -LiteralPath $resultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if (-not $userQuery.Success) {
                        $detail = if ($userQuery.Error) { [string]$userQuery.Error } else { "WinGet-Exitcode $($userQuery.ExitCode): $($userQuery.Output)" }
                        throw $detail
                    }
                    $parsedUserLines = @(Get-WingetUpgradeLines -Output ([string]$userQuery.Output))
                    foreach ($row in $parsedUserLines) {
                        $match = [regex]::Match([string]$row, '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<Installed>\S+)\s+(?<Available>\S+)\s+(?<Source>\S+)\s*$')
                        if (-not $match.Success) { continue }
                        $displayName = "[$userName] $($match.Groups['Name'].Value.Trim())"
                        $upgradeLines += [string]::Format('{0}  {1}  {2}  {3}  {4}', $displayName,
                            $match.Groups['Id'].Value, $match.Groups['Installed'].Value,
                            $match.Groups['Available'].Value, $match.Groups['Source'].Value)
                    }
                    foreach ($package in @($userQuery.Packages)) {
                        $packageResults += [pscustomobject]@{
                            Name = [string]$package.Name; Id = [string]$package.Id
                            InstalledVersion = [string]$package.InstalledVersion
                            AvailableVersion = [string]$package.AvailableVersion
                            Source = [string]$package.Source; UserName = $userName
                            Success = [bool]$package.Success; ExitCode = [int]$package.ExitCode
                            AccountIsAdministratorMember = [bool]$userQuery.AccountIsAdministratorMember
                            TokenIsElevated = [bool]$userQuery.TokenIsElevated
                            Output = [string]$package.Output
                        }
                    }
                    if ($InstallUpdates) {
                        if (@($userQuery.Packages).Count -eq 0) {
                            $queryOutput = [string]$userQuery.Output
                            if ([string]::IsNullOrWhiteSpace($queryOutput)) { $queryOutput = '<keine Ausgabe>' }
                            $notes += "Benutzerbezogene WinGet-Abfrage als '$userName': Parser erkannte 0 Paketzeilen (Exitcode $($userQuery.ExitCode)); Roh-Ausgabe: $queryOutput"
                        }
                        $notes += "Berechtigungsstatus für '$userName': Mitglied der lokalen Administratoren=$([bool]$userQuery.AccountIsAdministratorMember); aktueller Aufgabentoken erhöht=$([bool]$userQuery.TokenIsElevated)."
                        $notes += "Benutzerbezogene WinGet-Installation als '$userName': $(@($userQuery.Packages | Where-Object Success).Count) erfolgreich, $(@($userQuery.Packages | Where-Object { -not $_.Success }).Count) fehlgeschlagen."
                    } else {
                        $notes += "Benutzerbezogene WinGet-Abfrage als '$userName' erfolgreich: Exitcode $($userQuery.ExitCode); erkannte Updatezeilen=$($parsedUserLines.Count); Laufzeit=$([Math]::Round(((Get-Date) - $userCheckStartedAt).TotalSeconds, 1)) Sekunden."
                    }
                }
                catch {
                    $notes += "Benutzerbezogene WinGet-Abfrage für '$userName' fehlgeschlagen nach $([Math]::Round(((Get-Date) - $userCheckStartedAt).TotalSeconds, 1)) Sekunden: $($_.Exception.Message)"
                    if ($InstallUpdates) {
                        $packageResults += [pscustomobject]@{
                            Name = 'WinGet-Benutzerupdates'; Id = ''; InstalledVersion = ''
                            AvailableVersion = ''; Source = 'winget'; UserName = $userName
                            Success = $false; ExitCode = 1; Output = [string]$_.Exception.Message
                        }
                    }
                }
                finally {
                    if ($taskRegistered) {
                        try {
                            $registeredTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                            if (-not $registeredTask) {
                                $notes += "Temporäre WinGet-Benutzeraufgabe '$taskName' für '$userName' war beim Aufräumen bereits entfernt."
                            } else {
                                if ([string]$registeredTask.State -eq 'Running' -and -not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
                                    Stop-ScheduledTask -TaskName $taskName -ErrorAction Stop
                                    $notes += "Nicht abgeschlossene WinGet-Benutzeraufgabe '$taskName' für '$userName' nach Fehler/Timeout gestoppt."
                                }
                                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction Stop
                                $notes += "Temporäre WinGet-Benutzeraufgabe '$taskName' für '$userName' entfernt."
                            }
                        } catch {
                            $notes += "Temporäre WinGet-Benutzeraufgabe '$taskName' für '$userName' konnte nicht vollständig bereinigt werden: $($_.Exception.Message)"
                        }
                    }
                    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath $progressPath -Force -ErrorAction SilentlyContinue
                    Remove-Item -LiteralPath "$progressPath.tmp" -Force -ErrorAction SilentlyContinue
                }
            }
            [pscustomobject]@{ Lines = @($upgradeLines); Notes = @($notes); Packages = @($packageResults) }
        }

        function Invoke-WingetCliPackageUpdate {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Id,
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Version,
                [ValidateSet('machine', 'user')][string]$Scope
            )
            try {
                $arguments = @(
                    'upgrade', '--id', $Id, '--exact', '--source', $Source, '--version', $Version,
                    '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
                )
                if (-not [string]::IsNullOrWhiteSpace($Scope)) {
                    $arguments = @('upgrade', '--id', $Id, '--exact', '--scope', $Scope, '--source', $Source, '--version', $Version,
                        '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                }
                Push-Location -LiteralPath (Split-Path -Parent $Path)
                try {
                    $output = (& $Path @arguments 2>&1 | Out-String -Width 1200).Trim()
                    $exitCode = $LASTEXITCODE
                }
                finally { Pop-Location }
                $summary = if ([string]::IsNullOrWhiteSpace($output)) { "winget.exe upgrade endete mit Exitcode $exitCode." } else { $output }
                return [PSCustomObject]@{ Success=($exitCode -eq 0); ExitCode=$exitCode; Output=$summary; Result=$null }
            }
            catch {
                return [PSCustomObject]@{ Success=$false; ExitCode=1; Output=([string]$_.Exception.Message -replace '\s+', ' ').Trim(); Result=$null }
            }
        }

        function Get-WingetModuleUpdateOutput {
            try {
                # Katalogabfragen bleiben zeitlich begrenzt, laufen aber im
                # separaten Runspace desselben Prozesses statt in einem Start-Job.
                $queryResult = Invoke-WingetRunspaceWithTimeout -TimeoutSeconds 60 -ScriptBlock {
                    $ErrorActionPreference = 'Stop'
                    try {
                        Import-Module Microsoft.WinGet.Client -ErrorAction Stop
                        $packages = @(Get-WinGetPackage -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable })
                        $lines = foreach ($package in $packages) {
                            $availableVersions = @($package.AvailableVersions)
                            $availableVersion = if ($availableVersions.Count -gt 0) { [string]$availableVersions[0] } else { 'unbekannt' }
                            $sourceName = [string]$package.Source
                            if ([string]::IsNullOrWhiteSpace($sourceName)) { throw "Für '$($package.Name)' [$($package.Id)] wurde keine WinGet-Quelle zurückgegeben." }
                            [string]::Format('{0}  {1}  {2}  {3}  {4}', [string]$package.Name, [string]$package.Id, [string]$package.InstalledVersion, $availableVersion, $sourceName)
                        }
                        [pscustomobject]@{ Success = $true; Output = (@($lines) -join [Environment]::NewLine); Error = '' }
                    }
                    catch {
                        $detail = ([string]$_.Exception.Message -split "`r?`n")[0].Trim()
                        if ($detail -match '(?i)(Fehler beim Durchsuchen der Quelle|Fehler beim Versuch, die Quelle zu aktualisieren|An error occurred while searching the source|Failed when searching (?:the )?source|Failed in attempting to update the source)') {
                            [pscustomobject]@{ Success = $true; Output = $detail; Error = '' }
                        }
                        else {
                            [pscustomobject]@{ Success = $false; Output = ''; Error = $_.Exception.ToString() }
                        }
                    }
                } | Select-Object -Last 1
                if (-not $queryResult) { throw 'WinGet-Katalogabfrage lieferte keine Rückgabe.' }
                if (-not $queryResult.Success) { throw [string]$queryResult.Error }
                return [string]$queryResult.Output
            }
            catch {
                if ($_.Exception -is [System.TimeoutException]) { throw }
                $detail = ([string]$_.Exception.Message -split "`r?`n")[0].Trim()
                if ($detail.Length -gt 350) { $detail = $detail.Substring(0, 347) + '...' }
                if (Test-WingetSourceFailureLine -Line $detail) { return $detail }
                throw
            }
        }

        function Invoke-WingetModulePackageUpdate {
            param(
                [Parameter(Mandatory)][string]$Id,
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Version
            )
            try {
                Import-Module Microsoft.WinGet.Client -ErrorAction Stop
                $updateResult = @(Update-WinGetPackage -Id $Id -Source $Source -Version $Version -MatchOption EqualsCaseInsensitive -Mode Silent -Confirm:$false -ErrorAction Stop)
                if ($updateResult.Count -eq 0) { throw 'Microsoft.WinGet.Client lieferte kein Installationsresultat.' }
                $status = [string]$updateResult[-1].Status
                $installerCode = [string]$updateResult[-1].InstallerErrorCode
                $extendedCode = [string]$updateResult[-1].ExtendedErrorCode
                $summary = "Status=$status"
                if ($installerCode -and $installerCode -ne '0') { $summary += "; InstallerErrorCode=$installerCode" }
                if ($extendedCode -and $extendedCode -ne '0') { $summary += "; ExtendedErrorCode=$extendedCode" }
                foreach ($code in @($installerCode, $extendedCode)) {
                    if ($code -match '^\-?\d+$') {
                        try { $summary += ('; Fehlercode=0x{0:X8}' -f [uint32]([int64]$code)) } catch { }
                    }
                }
                if ($updateResult[-1].RebootRequired) { $summary += '; Neustart erforderlich' }
                $success = $status -eq 'Ok' -and (-not $installerCode -or $installerCode -eq '0')
                return [PSCustomObject]@{ Success=$success; ExitCode=$(if ($success) { 0 } else { 1 }); Output=$summary; Result=$updateResult[-1] }
            }
            catch {
                return [PSCustomObject]@{ Success=$false; ExitCode=1; Output=([string]$_.Exception.Message -replace '\s+', ' ').Trim(); Result=$null }
            }
        }

        function Get-WingetSourceResetState {
            $sourceStateRoot = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
                $env:ProgramData
            } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                $env:LOCALAPPDATA
            } else {
                $env:USERPROFILE
            }
            $sourceStateDirectory = Join-Path $sourceStateRoot 'ServerUpdateSkripte'
            # Neuer Markername: ältere Skriptstände haben Standardquellen
            # einzeln zurückgesetzt. Deren Zeitmarke darf den ersten vollständigen
            # Quellenreset nach diesem Fix nicht unterdrücken.
            $markerPath = Join-Path $sourceStateDirectory 'WingetAllSourcesResetUtc.txt'
            $allowed = $true
            try {
                if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                    $lastResetUtc = [DateTime]::MinValue
                    $markerText = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop
                    if ([DateTime]::TryParse($markerText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$lastResetUtc) -and
                        ([DateTime]::UtcNow - $lastResetUtc.ToUniversalTime()).TotalHours -lt 24) {
                        $allowed = $false
                    }
                }
            }
            catch {
                # Ein nicht lesbarer Marker darf eine notwendige Reparatur
                # nicht verhindern; der Fehler wird beim Speichern protokolliert.
                $allowed = $true
            }
            return [PSCustomObject]@{ Allowed = $allowed; Directory = $sourceStateDirectory; MarkerPath = $markerPath }
        }

        function Reset-WingetDefaultSources {
            param([Parameter(Mandatory)][string]$Path)
            # winget-font ist eine integrierte, optionale Quelle. Sie darf beim
            # Reset nicht als kundeneigene Quelle gelten und ist danach nicht Pflicht.
            $knownDefaultSources = @('msstore', 'winget', 'winget-font')
            $requiredDefaultSources = @('msstore', 'winget')
            $configuredResult = Invoke-WindowsUpdateHiddenProcess -Path $Path -Arguments @('source', 'list', '--disable-interactivity')
            $configuredOutput = [string]$configuredResult.Output
            $configuredExitCode = [int]$configuredResult.ExitCode
            if ($configuredExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($configuredOutput)) {
                throw "WinGet-Quellenliste konnte vor dem Reset nicht zuverlässig gelesen werden (Exitcode $configuredExitCode): $configuredOutput"
            }
            $configuredNames = @(
                foreach ($line in ($configuredOutput -split "`r?`n")) {
                    if ($line -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name }
                }
            )
            if ($configuredNames.Count -eq 0) { throw 'WinGet-Quellenliste enthielt keine auswertbaren Quellen; Reset abgebrochen.' }
            $customSources = @($configuredNames | Where-Object { $_ -notin $knownDefaultSources } | Select-Object -Unique)
            if ($customSources.Count -gt 0) {
                throw "Kundeneigene WinGet-Quelle(n) erkannt ($($customSources -join ', ')); Reset wurde ausgelassen, damit diese erhalten bleiben."
            }

            # Den explizit bewährten CLI-Reset verwenden. Anschließend wird die
            # Paketquelle vor dem Retry aktualisiert.
            $resetResult = Invoke-WindowsUpdateHiddenProcess -Path $Path -Arguments @('source', 'reset', '--force', '--disable-interactivity')
            $resetOutput = [string]$resetResult.Output
            $resetExitCode = [int]$resetResult.ExitCode
            if ($resetExitCode -ne 0) { throw "WinGet-CLI-Quellenreset fehlgeschlagen (Exitcode $resetExitCode): $resetOutput" }
            $updateResult = Invoke-WindowsUpdateHiddenProcess -Path $Path -Arguments @('source', 'update', '--name', 'winget', '--disable-interactivity')
            $updateOutput = [string]$updateResult.Output
            $updateExitCode = [int]$updateResult.ExitCode
            if ($updateExitCode -ne 0) { throw "WinGet-Quelle 'winget' konnte nach dem Reset nicht aktualisiert werden (Exitcode $updateExitCode): $updateOutput" }
            $sourcesAfterResult = Invoke-WindowsUpdateHiddenProcess -Path $Path -Arguments @('source', 'list', '--disable-interactivity')
            $sourcesAfterOutput = [string]$sourcesAfterResult.Output
            $sourcesAfterExitCode = [int]$sourcesAfterResult.ExitCode
            if ($sourcesAfterExitCode -ne 0) { throw "WinGet-Quellenliste konnte nach dem Reset nicht gelesen werden (Exitcode $sourcesAfterExitCode): $sourcesAfterOutput" }
            $sourcesAfterReset = @(
                foreach ($line in ($sourcesAfterOutput -split "`r?`n")) {
                    if ($line -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name }
                }
            )
            $missingDefaults = @($requiredDefaultSources | Where-Object { $_ -notin $sourcesAfterReset })
            if ($missingDefaults.Count -gt 0) {
                throw "WinGet-Standardquelle(n) fehlen nach dem Reset: $($missingDefaults -join ', ')."
            }
        }

        function Save-WingetSourceResetState {
            param([Parameter(Mandatory)]$State)
            if (-not (Test-Path -LiteralPath $State.Directory -PathType Container)) {
                New-Item -Path $State.Directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            [IO.File]::WriteAllText($State.MarkerPath, [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
        }

        function Register-LatestWinGetAppInstallerForCurrentUser {
            $allPackages = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) })
            $currentPackages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) })
            $latestPackage = @($allPackages + $currentPackages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
            $targetVersion = if ($latestPackage.Count -gt 0) { [version]$latestPackage[0].Version } else { [version]'0.0' }
            $currentPackage = @($currentPackages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
            $currentVersion = if ($currentPackage.Count -gt 0) { [version]$currentPackage[0].Version } else { [version]'0.0' }
            $registrationChanged = $currentVersion -lt $targetVersion
            $wingetAliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            $aliasRegistrationRequired = -not (Test-Path -LiteralPath $wingetAliasPath -PathType Leaf)
            $registrationRequired = $registrationChanged -or $aliasRegistrationRequired
            $aliasRegistrationMessage = ''
            $installedFromGitHub = $false
            $appxTaskRuns = @()

            # Bei einem WinGet.Client/App-Installer-Versionskonflikt kann dessen
            # COM-Reparatur selbst scheitern. In diesem Fall die aktuelle offizielle
            # GitHub-Version dynamisch beziehen und im Benutzerkontext bereitstellen;
            # keine feste Paketversion oder Hashwerte voraussetzen.
            $clientModule = @(Get-Module -ListAvailable -Name Microsoft.WinGet.Client -ErrorAction SilentlyContinue |
                Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending | Select-Object -First 1)
            $moduleVersion = if ($clientModule.Count -gt 0) { try { [version]$clientModule[0].Version } catch { [version]'0.0' } } else { [version]'0.0' }
            $minimumAppInstallerVersion = if ($moduleVersion.Build -ge 0) {
                [version]::new($moduleVersion.Major, $moduleVersion.Minor, $moduleVersion.Build, [Math]::Max(0, $moduleVersion.Revision))
            } else { $moduleVersion }
            if ($moduleVersion -le [version]'0.0') {
                throw 'Microsoft.WinGet.Client ist nicht verfügbar; die erforderliche App-Installer-Version kann nicht ermittelt werden.'
            }
            if ($currentVersion -lt $minimumAppInstallerVersion) {
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
                        Where-Object { $_.Extension -in '.appx', '.msix', '.appxbundle', '.msixbundle' -and $_.FullName -match '(?i)(x64|amd64|neutral)' } |
                        Sort-Object FullName | ForEach-Object FullName)
                    if ($dependencyPackages.Count -eq 0) { throw 'GitHub-Abhängigkeitenpaket enthält keine passenden AppX-Abhängigkeiten.' }
                    $quotedBundlePath = "'" + $bundlePath.Replace("'", "''") + "'"
                    $quotedDependencyList = @($dependencyPackages | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', '
                    $appxTaskResult = Invoke-WinGetCurrentUserAppxTask -Purpose 'aktuelle App-Installer-Version aus GitHub bereitstellen' -ScriptText @"
`$ErrorActionPreference = 'Stop'
`$dependencies = @($quotedDependencyList)
Add-AppxPackage -Path $quotedBundlePath -DependencyPath `$dependencies -ForceUpdateFromAnyVersion -ErrorAction Stop | Out-Null
"@
                    $appxTaskRuns += $appxTaskResult
                    $registeredPackage = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
                        Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
                    if ($registeredPackage.Count -eq 0 -or [version]$registeredPackage[0].Version -lt $minimumAppInstallerVersion) {
                        $actualVersion = if ($registeredPackage.Count -gt 0) { [string]$registeredPackage[0].Version } else { 'nicht registriert' }
                        throw "GitHub-Bereitstellung ergab App Installer $actualVersion; benötigt wird mindestens $minimumAppInstallerVersion."
                    }
                    $targetVersion = [version]$registeredPackage[0].Version
                    $currentVersion = $targetVersion
                    $registrationChanged = $true
                    $installedFromGitHub = $true
                }
                catch {
                    throw "App Installer ist für Microsoft.WinGet.Client $minimumAppInstallerVersion zu alt ($currentVersion); Bereitstellung aus dem offiziellen GitHub-Release fehlgeschlagen: $($_.Exception.ToString())"
                }
                finally {
                    Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
                }
            }
            if ($aliasRegistrationRequired -and -not $registrationChanged) {
                $aliasRegistrationMessage = "WinGet-Ausführungsalias fehlt für den aktuellen Benutzer ($wingetAliasPath); App Installer wird erneut registriert."
            }
            if ($registrationRequired -and -not $installedFromGitHub) {
                $manifestPath = Join-Path ([string]$latestPackage[0].InstallLocation) 'AppxManifest.xml'
                if (-not $installedFromGitHub -and -not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    throw "App Installer $targetVersion ist vorhanden, aber sein Manifest fehlt: $manifestPath"
                }
                if (-not $installedFromGitHub) { try {
                    $appxTaskResult = Invoke-WinGetCurrentUserAppxTask -Purpose 'App Installer registrieren' -ScriptText @"
`$ErrorActionPreference = 'Stop'
Add-AppxPackage -RegisterByFamilyName -MainPackage 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe' -ErrorAction Stop | Out-Null
"@
                    $appxTaskRuns += $appxTaskResult
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
                        $quotedBundlePath = "'" + $bundlePath.Replace("'", "''") + "'"
                        $quotedDependencyList = @($dependencyPackages | ForEach-Object { "'" + ([string]$_).Replace("'", "''") + "'" }) -join ', '
                        $appxTaskResult = Invoke-WinGetCurrentUserAppxTask -Purpose 'App Installer aus GitHub-Paket bereitstellen' -ScriptText @"
`$ErrorActionPreference = 'Stop'
`$dependencies = @($quotedDependencyList)
Add-AppxPackage -Path $quotedBundlePath -DependencyPath `$dependencies -ForceUpdateFromAnyVersion -ErrorAction Stop | Out-Null
"@
                        $appxTaskRuns += $appxTaskResult
                        $registrationChanged = $true
                        $installedFromGitHub = $true
                    }
                    catch {
                        throw "App Installer konnte nicht aus dem offiziellen GitHub-Release einschließlich Abhängigkeiten bereitgestellt werden. Registrierungsfehler: $($registrationError.Exception.Message) GitHub-Fehler: $($_.Exception.Message)"
                    }
                    finally {
                        Remove-Item -LiteralPath $payloadRoot -Recurse -Force -ErrorAction SilentlyContinue
                    }
                } }
            }

            $aliasRegistered = Test-Path -LiteralPath $wingetAliasPath -PathType Leaf
            if (-not $aliasRegistered) {
                throw "App Installer $targetVersion wurde für den aktuellen Benutzer registriert, aber der WinGet-Ausführungsalias fehlt weiterhin: $wingetAliasPath"
            }

            $registeredPackage = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
                Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
            if ($registeredPackage.Count -eq 0 -or [string]$registeredPackage[0].Status -ne 'Ok') {
                throw "App Installer $targetVersion wurde für den aktuellen Benutzer nicht erfolgreich registriert."
            }
            return [pscustomobject]@{
                Version = [string]$registeredPackage[0].Version
                RegistrationChanged = [bool]($registrationChanged -or $aliasRegistrationRequired)
                AliasRegistrationMessage = $aliasRegistrationMessage
                InstalledFromGitHub = [bool]$installedFromGitHub
                TaskRuns = @($appxTaskRuns)
            }
        }

        # Kein generisches .NET-List-Objekt: PowerShell 7 kann dieses beim
        # Rückgabewert einer verschachtelten ScriptBlock-Ausführung fehlerhaft
        # binden ("Argument types do not match"). Ein normales PS-Array ist
        # für die wenigen Paketmanager-Ergebnisse vollkommen ausreichend.
        $result = @()
        $chocoPath = 'C:\ProgramData\chocolatey\bin\choco.exe'
        if (-not $UseChocolatey) {
            $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$false; Success=$true; Skipped=$true; SkipReason='per Konfiguration deaktiviert'; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }
        elseif (Test-Path -LiteralPath $chocoPath) {
            try {
                $availableOutput = & $chocoPath outdated --limit-output 2>&1 | Out-String
                $chocoQueryExitCode = $LASTEXITCODE
                $chocoSourceFailurePattern = '(?i)(Unable to connect to source|Failed to fetch results from .*feed|Der Antwortstatuscode gibt keinen Erfolg an|Response status code does not indicate success|Fehler beim Abrufen der Ergebnisse.*Quelle|Quelle.*nicht erreichbar)'
                $chocoSourceFailures = @($availableOutput -split "`r?`n" | Where-Object { $_ -match $chocoSourceFailurePattern })
                $packages = @($availableOutput -split "`r?`n" | Where-Object { $_ -match '^[^|]+\|[^|]+\|[^|]+' } | ForEach-Object {
                    $fields = @($_ -split '\|', 4)
                    if ($fields.Count -ge 3) {
                        $installedVersion = ([string]$fields[1]).Trim()
                        $availableVersion = ([string]$fields[2]).Trim()
                        # Chocolatey kann bei einem nicht erreichbaren Feed trotzdem
                        # eine Zeile mit der installierten Version in beiden
                        # Versionsfeldern und Exitcode 0 ausgeben. Das ist kein Update.
                        if (-not [string]::Equals($installedVersion, $availableVersion, [StringComparison]::OrdinalIgnoreCase)) {
                            [pscustomobject]@{
                                Name = ([string]$fields[0]).Trim(); Id = ([string]$fields[0]).Trim()
                                InstalledVersion = $installedVersion; AvailableVersion = $availableVersion
                                Source = 'chocolatey'
                            }
                        }
                    }
                } | Sort-Object Id -Unique)
                $excludedChocolateyIdList = @($ExcludedChocolateyIds -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($ExecutionMode -eq 'Install' -and $excludedChocolateyIdList.Count -gt 0 -and $packages.Count -gt 0) {
                    $excludedPackages = @($packages | Where-Object { [string]$_.Id -in $excludedChocolateyIdList })
                    foreach ($excludedPackage in $excludedPackages) {
                        $result += [PSCustomObject]@{
                            Manager='Chocolatey'; Available=$true; Success=$true; Skipped=$true
                            SkipReason="Paket '$($excludedPackage.Id)' wurde bereits im PowerShell-7-Vorabpfad behandelt und wird in diesem Installationslauf nicht erneut gestartet."
                            ExitCode=0; Packages=@($excludedPackage); AvailableOutput=$availableOutput; ActionOutput=''
                        }
                    }
                    $packages = @($packages | Where-Object { [string]$_.Id -notin $excludedChocolateyIdList })
                }
                $chocoQuerySucceeded = $chocoQueryExitCode -in @(0, 2) -and $chocoSourceFailures.Count -eq 0
                $actionOutput = if ($chocoQuerySucceeded) { '' } else { 'Chocolatey-Abfrage unvollständig; Paketupdates sind nicht verlässlich bestimmbar. Details im Log.' }
                $exitCode = $chocoQueryExitCode
                $chocoSplitResultHandled = $false
                if ($ExecutionMode -eq 'Install' -and $packages.Count -gt 0) {
                    $upgradeOutput = & $chocoPath upgrade all -y 2>&1 | Out-String
                    $upgradeExitCode = $LASTEXITCODE
                    if (-not [string]::IsNullOrWhiteSpace($upgradeOutput)) {
                        $actionOutput = (@($actionOutput, $upgradeOutput.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n"
                    }
                    $exitCode = $upgradeExitCode

                    # Chocolatey kann mehrere Pakete erfolgreich aktualisieren,
                    # bevor ein späteres Paket (zum Beispiel wegen einer
                    # abweichenden Prüfsumme) fehlschlägt. Erfolg und Nacharbeit
                    # pro Paket aus der Chocolatey-Zusammenfassung trennen.
                    $chocoSucceededNames = @(
                        foreach ($line in ($upgradeOutput -split "`r?`n")) {
                            $match = [regex]::Match([string]$line, '(?i)^\s*The upgrade of (?<Name>.+?) was successful\.?\s*$')
                            if ($match.Success) { $match.Groups['Name'].Value.Trim() }
                        }
                    )
                    $chocoFailedIds = @(
                        foreach ($line in ($upgradeOutput -split "`r?`n")) {
                            $match = [regex]::Match([string]$line, '(?i)^\s*-\s*(?<Id>[^\s(]+)\s+\(exited\s+(?<Code>[^)]+)\)')
                            if ($match.Success) { $match.Groups['Id'].Value.Trim() }
                        }
                    ) | Select-Object -Unique

                    $chocoSucceededPackages = @(
                        foreach ($candidate in $packages) {
                            if ($chocoSucceededNames -contains [string]$candidate.Id -or
                                $chocoSucceededNames -contains [string]$candidate.Name) { $candidate }
                        }
                    )
                    $chocoFailedPackages = @(
                        foreach ($failedId in $chocoFailedIds) {
                            $matchedPackage = @($packages | Where-Object { [string]$_.Id -ieq [string]$failedId -or [string]$_.Name -ieq [string]$failedId } | Select-Object -First 1)
                            if ($matchedPackage.Count -gt 0) { $matchedPackage[0] }
                            else {
                                [pscustomobject]@{
                                    Name = [string]$failedId; Id = [string]$failedId
                                    InstalledVersion = ''; AvailableVersion = ''; Source = 'chocolatey'
                                }
                            }
                        }
                    )

                    if ($chocoFailedPackages.Count -gt 0 -or $upgradeExitCode -ne 0) {
                        if ($chocoSucceededPackages.Count -eq 0 -and $chocoSucceededNames.Count -eq 0 -and $chocoFailedIds.Count -gt 0) {
                            $chocoFailedPackages = @($packages | Where-Object { [string]$_.Id -in $chocoFailedIds })
                        }
                        if ($chocoFailedPackages.Count -eq 0) {
                            $chocoFailedPackages = @($packages | Where-Object { $_ -notin $chocoSucceededPackages })
                        }

                        if ($chocoSucceededPackages.Count -gt 0) {
                            $result += [pscustomobject]@{
                                Manager='Chocolatey'; Available=$true; Success=$true; Skipped=$false; SkipReason=''
                                ExitCode=0; Packages=$chocoSucceededPackages; AvailableOutput=$availableOutput
                                ActionOutput=$upgradeOutput
                            }
                        }

                        $failureSummary = if ($chocoFailedIds.Count -gt 0) {
                            "Chocolatey konnte $($chocoFailedPackages.Count) Paket(e) nicht aktualisieren ($($chocoFailedIds -join ', ')). Erfolgreich abgeschlossene Pakete sind separat aufgeführt. Bitte die fehlgeschlagenen Pakete manuell prüfen; Prüfsummenprüfung bleibt aktiv."
                        } else {
                            'Chocolatey meldet einen Installationsfehler. Erfolgreich abgeschlossene Pakete sind separat aufgeführt; die übrigen gefundenen Pakete bitte manuell prüfen. Prüfsummenprüfung bleibt aktiv.'
                        }
                        $result += [pscustomobject]@{
                            Manager='Chocolatey'; Available=$true; Success=$false; Skipped=$false; SkipReason=''
                            ExitCode=$upgradeExitCode; Packages=$chocoFailedPackages; AvailableOutput=$availableOutput
                            ActionOutput=$upgradeOutput; DiagnosticOutput=$upgradeOutput
                            RequiresManualAction=$true; ManualActionText=$failureSummary
                        }
                        $chocoSplitResultHandled = $true
                    }

                    if (-not $chocoSplitResultHandled -and $chocoSucceededPackages.Count -gt 0) { $packages = $chocoSucceededPackages }
                }
                if (-not $chocoSplitResultHandled) {
                    $chocoSuccess = $chocoQuerySucceeded -and ($ExecutionMode -ne 'Install' -or $exitCode -eq 0)
                    $chocoDiagnostic = if ($chocoSourceFailures.Count -gt 0) {
                        (@($chocoSourceFailures | ForEach-Object {
                            ([string]$_ -replace '(?i)(https?://)[^/@\s]+:[^/@\s]+@', '$1<redacted>@' -replace '(?i)([?&](?:password|passwd|token|apikey|api_key|key)=)[^&\s''"]+', '$1<redacted>')
                        }) -join [Environment]::NewLine)
                    } elseif (-not $chocoQuerySucceeded) {
                        ([string]$availableOutput -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 10) -join [Environment]::NewLine
                    } else { '' }
                    $chocoResult = [PSCustomObject]@{ Manager='Chocolatey'; Available=$true; Success=$chocoSuccess; Skipped=$false; SkipReason=''; ExitCode=$exitCode; Packages=$packages; AvailableOutput=$availableOutput; ActionOutput=$actionOutput }
                    if (-not [string]::IsNullOrWhiteSpace($chocoDiagnostic)) {
                        Add-Member -InputObject $chocoResult -NotePropertyName DiagnosticOutput -NotePropertyValue $chocoDiagnostic
                    }
                    $result += $chocoResult
                }
            }
            catch {
                $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='Chocolatey-Abfrage fehlgeschlagen; Details im Log.'; DiagnosticOutput=$_.Exception.ToString() }
            }
        }
        else {
            $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$false; Success=$true; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }

        if (-not $UseWinget) {
            $result += [PSCustomObject]@{ Manager='Winget'; Available=$false; Success=$true; Skipped=$true; SkipReason='per Konfiguration deaktiviert'; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }
        elseif ($isSystemContext) {
            $result += [PSCustomObject]@{ Manager='Winget'; Available=$false; Success=$true; Skipped=$true; SkipReason='SYSTEM-Kontext (Winget ist benutzerbezogen)'; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }
        else {
            $script:WindowsUpdatePortableWinGetPath = $null
            $wingetPortableMode = $false
            $isWindowsServer2019 = $false
            try {
                $osInformation = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
                $isWindowsServer2019 = ([int]$osInformation.ProductType -gt 1) -and ([int]$osInformation.BuildNumber -eq 17763)
            }
            catch { }
            $wingetPath = Resolve-WingetExecutable
            $wingetBootstrapMessage = ''
            $wingetDiagnosticOutput = ''
            $wingetInteractiveUserDiagnosticOutput = ''
            $wingetPreparationSucceeded = $true
            $wingetReconnectRequired = $false
            $appInstallerRegistrationChanged = $false
            $wingetQuerySources = @()
            $wingetModuleUseAllowed = $true
            if ($isWindowsServer2019) {
                try {
                    $portableClient = Get-WinGetPortableClientFromGitHub
                    $script:WindowsUpdatePortableWinGetPath = [string]$portableClient.Path
                    $wingetPath = [string]$portableClient.Path
                    $wingetPortableMode = $true
                    $wingetModuleUseAllowed = $false
                    $cacheState = if ($portableClient.Cached) { 'aus lokalem Cache' } else { 'neu aus dem aktuellen GitHub-Release entpackt' }
                    $wingetBootstrapMessage += " Windows Server 2019: experimentelle WinGet-CLI $($portableClient.Version) $cacheState; PowerShell-Modul und AppX-Registrierungsreparatur werden umgangen."
                }
                catch {
                    $wingetPreparationSucceeded = $false
                    $wingetBootstrapMessage += ' Experimentelle WinGet-CLI konnte nicht aus dem aktuellen GitHub-Release bereitgestellt werden.'
                    $wingetDiagnosticOutput += "WinGet-GitHub-Extraktion:`r`n$($_.Exception.ToString())`r`n"
                }
            }
            if ($ExecutionMode -eq 'Check' -and $wingetPath -and -not $wingetPortableMode -and $wingetPreparationSucceeded) {
                # WinGet.Client benötigt für seine COM-Abfrage eine AppX-
                # Registrierung im tatsächlich ausführenden Benutzerkonto.
                # Eine winget.exe im WindowsApps-Verzeichnis allein reicht
                # nicht: ein Paket, das nur für einen anderen Benutzer oder
                # nur für SYSTEM gestaged ist, lässt den Modulaufruf scheitern.
                try {
                    $appInstallerRegistration = Register-LatestWinGetAppInstallerForCurrentUser
                    if ($appInstallerRegistration.RegistrationChanged) {
                        $appInstallerRegistrationChanged = $true
                        $wingetPath = Resolve-WingetExecutable
                        $wingetBootstrapMessage += " App Installer $($appInstallerRegistration.Version) für den aktuellen Remoting-Benutzer registriert; WinGet-Abfrage wird in einer neuen Verbindung fortgesetzt."
                        if (-not [string]::IsNullOrWhiteSpace([string]$appInstallerRegistration.AliasRegistrationMessage)) {
                            $wingetBootstrapMessage += " $($appInstallerRegistration.AliasRegistrationMessage)"
                        }
                        foreach ($taskRun in @($appInstallerRegistration.TaskRuns)) {
                            $wingetBootstrapMessage += " AppX-Aufgabe: Konto=$($taskRun.UserName); Anmeldetyp=$($taskRun.LogonType)."
                        }
                        if ($appInstallerRegistration.InstalledFromGitHub) {
                            $wingetBootstrapMessage += ' App Installer und fehlende Abhängigkeiten wurden aus dem offiziellen WinGet-GitHub-Release bereitgestellt.'
                        }
                        $wingetReconnectRequired = $true
                    } else {
                        $wingetBootstrapMessage += " App Installer $($appInstallerRegistration.Version) ist für den aktuellen Remoting-Benutzer bereits registriert."
                    }
                }
                catch {
                    $wingetPreparationSucceeded = $false
                    $wingetModuleUseAllowed = $false
                    $wingetBootstrapMessage += ' App Installer konnte für den aktuellen Remoting-Benutzer nicht registriert werden; WinGet-Modulabfrage wird nicht gestartet.'
                    $wingetDiagnosticOutput += "App-Installer-Registrierung:`r`n$($_.Exception.ToString())`r`n"
                }
            }
            if ($ExecutionMode -in @('Check', 'Install') -and $wingetPath -and $wingetPreparationSucceeded) {
                try {
                    $refreshSourcePackage = $SourceResetPerformed -or $SourcePackageRefreshPerformed
                    $sourcePackageRegistration = Ensure-WinGetSourcePackageForCurrentUser -Refresh:$refreshSourcePackage
                    if ($sourcePackageRegistration.Output -match '__WINGETSOURCE__SUCCESS') {
                        if ($sourcePackageRegistration.Refreshed) {
                            $wingetBootstrapMessage += " WinGet-Quellenpaket für den aktuellen Benutzer nach leerer Abfrage erneuert (Version $($sourcePackageRegistration.Version))."
                        } else {
                            $wingetBootstrapMessage += " WinGet-Quellenpaket für den aktuellen Benutzer verfügbar (Version $($sourcePackageRegistration.Version))."
                        }
                    }
                    if ($sourcePackageRegistration.Changed -or $appInstallerRegistrationChanged) {
                        # Nach einer Registrierung im Benutzerprofil Quellen
                        # neu initialisieren, wie beim nachgewiesenen SRVTS01-Fix.
                        # Kundeneigene Quellen werden vor dem Reset geschützt.
                        $wingetPath = Resolve-WingetExecutable
                        $sourceListResult = Invoke-WindowsUpdateHiddenProcess -Path $wingetPath -Arguments @('source', 'list', '--disable-interactivity')
                        if ($sourceListResult.ExitCode -ne 0) {
                            throw "WinGet-Quellenliste vor dem Benutzerquellen-Reset fehlgeschlagen (Exitcode $($sourceListResult.ExitCode)): $($sourceListResult.Output)"
                        }
                        $sourceNames = @(
                            foreach ($sourceLine in ([string]$sourceListResult.Output -split "`r?`n")) {
                                if ($sourceLine -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name }
                            }
                        )
                        $customSourceNames = @($sourceNames | Where-Object { $_ -notin @('msstore', 'winget', 'winget-font') } | Select-Object -Unique)
                        if ($customSourceNames.Count -gt 0) {
                            throw "WinGet-Quellenpaket wurde registriert, aber Quellenreset wegen kundeneigener Quelle(n) ausgelassen: $($customSourceNames -join ', ')."
                        }
                        $sourceResetResult = Invoke-WindowsUpdateHiddenProcess -Path $wingetPath -Arguments @('source', 'reset', '--force', '--disable-interactivity')
                        if ($sourceResetResult.ExitCode -ne 0) {
                            throw "WinGet-Quellenreset nach Benutzerregistrierung fehlgeschlagen (Exitcode $($sourceResetResult.ExitCode)): $($sourceResetResult.Output)"
                        }
                        $sourceUpdateResult = Invoke-WindowsUpdateHiddenProcess -Path $wingetPath -Arguments @('source', 'update', '--name', 'winget', '--disable-interactivity')
                        if ($sourceUpdateResult.ExitCode -ne 0) {
                            throw "WinGet-Quelle konnte nach Benutzerregistrierung nicht aktualisiert werden (Exitcode $($sourceUpdateResult.ExitCode)): $($sourceUpdateResult.Output)"
                        }
                        $wingetBootstrapMessage += " WinGet-Quellen im Benutzerkontext nach AppX-Komponentenänderung zurückgesetzt und Quelle 'winget' aktualisiert; Abfrage wird in einer frischen Verbindung wiederholt."
                        if ($refreshSourcePackage) {
                            $wingetBootstrapMessage += ' WinGet-Quellenpaket wurde im aktuellen Remoting-Kontext ergänzt.'
                        } else {
                            $wingetBootstrapMessage += ' WinGet-Quellenpaket wurde ergänzt; Abfrage wird in einer neuen Verbindung wiederholt.'
                            $wingetReconnectRequired = $true
                        }
                    }
                }
                catch {
                    $wingetPreparationSucceeded = $false
                    $wingetBootstrapMessage += ' WinGet-Quellenpaket konnte für den aktuellen Benutzer nicht registriert werden; Details im Log.'
                    $wingetDiagnosticOutput += "WinGet-Quellenpaket:`r`n$($_.Exception.ToString())`r`n"
                }
            }
            if ($ExecutionMode -eq 'Check') {
                if (-not $wingetPortableMode) {
                # Microsoft.WinGet.Client 1.29.380+ benötigt für Aufrufe in
                # erhöhten Sitzungen auch einen App-Installer derselben
                # Mindestgeneration. Bei einem älteren DesktopAppInstaller
                # kann winrtact.dll den wsmprovhost-Prozess zum Absturz bringen;
                # der Fehler ist dann nicht mehr per PowerShell-Catch fangbar.
                $clientModule = @(Get-Module -ListAvailable -Name Microsoft.WinGet.Client -ErrorAction SilentlyContinue |
                    Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending |
                    Select-Object -First 1)
                $currentAppInstaller = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                    Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending |
                    Select-Object -First 1)
                $clientModuleVersion = if ($clientModule.Count -gt 0) { try { [version]$clientModule[0].Version } catch { [version]'0.0' } } else { [version]'0.0' }
                $appInstallerVersion = if ($currentAppInstaller.Count -gt 0) { try { [version]$currentAppInstaller[0].Version } catch { [version]'0.0' } } else { [version]'0.0' }
                $minimumElevatedAppInstallerVersion = if ($clientModuleVersion -ge [version]'1.29.380.0') {
                    $clientModuleVersion
                } else {
                    [version]'0.0'
                }

                if ($clientModuleVersion -ge $minimumElevatedAppInstallerVersion -and
                    $appInstallerVersion -lt $minimumElevatedAppInstallerVersion) {
                    $wingetBootstrapMessage += " Versionskonflikt erkannt: Microsoft.WinGet.Client $clientModuleVersion benötigt für erhöhte Abfragen App Installer $minimumElevatedAppInstallerVersion oder neuer; registriert ist $appInstallerVersion."
                    try {
                        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
                        $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
                        $currentAppInstaller = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction SilentlyContinue |
                            Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending |
                            Select-Object -First 1)
                        $appInstallerVersion = if ($currentAppInstaller.Count -gt 0) { try { [version]$currentAppInstaller[0].Version } catch { [version]'0.0' } } else { [version]'0.0' }
                        if ($appInstallerVersion -lt $minimumElevatedAppInstallerVersion) {
                            throw "App-Installer-Reparatur abgeschlossen, aber registrierte Version $appInstallerVersion bleibt unter der benötigten Version $minimumElevatedAppInstallerVersion."
                        }
                        $wingetPath = Resolve-WingetExecutable
                        $wingetBootstrapMessage += " App Installer wurde auf Version $appInstallerVersion repariert; WinGet-Abfrage wird in einer neuen Verbindung fortgesetzt."
                        $wingetReconnectRequired = $true
                    }
                    catch {
                        # Die WinGet-CLI kann weiterhin korrekt abfragen, auch
                        # wenn der PowerShell-Client nicht zur AppX-Version
                        # passt. Den inkompatiblen nativen Modulaufruf deshalb
                        # unterlassen und den Reparaturfehler nachvollziehbar
                        # protokollieren, statt den WSMan-Host abstürzen zu lassen.
                        $wingetModuleUseAllowed = $false
                        $wingetBootstrapMessage += ' App-Installer-Reparatur nicht abgeschlossen; PowerShell-Modulabfrage wird ausgelassen und die WinGet-CLI verwendet.'
                        $wingetDiagnosticOutput += "WinGet-Komponentenreparatur:`r`n$($_.Exception.ToString())`r`n"
                    }
                }
                }

                $wingetHealth = Test-WingetExecutable -Path $wingetPath
                if (-not $wingetHealth.Works -and $wingetPortableMode) {
                    $wingetPreparationSucceeded = $false
                    $wingetBootstrapMessage += " Die experimentelle WinGet-CLI aus GitHub lässt sich nicht ausführen ($($wingetHealth.Output))."
                    $wingetDiagnosticOutput += "WinGet-GitHub-CLI-Test:`r`n$($wingetHealth.DiagnosticOutput)`r`n"
                }
                elseif (-not $wingetHealth.Works) {
                    $healthProblems = @()
                    if (-not $wingetHealth.Works) { $healthProblems += "winget.exe: $($wingetHealth.Output)" }
                    $wingetBootstrapMessage += " WinGet auf $env:COMPUTERNAME ($serverCaption) ist nicht funktionsfähig ($($healthProblems -join '; ')); starte Reparatur."
                    try {
                        Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
                        $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
                        Assert-WinGetPackageManager -ErrorAction Stop | Out-Null
                        $moduleVersion = [string](Get-WinGetVersion -ErrorAction Stop)
                        $wingetBootstrapMessage += " Reparatur über Microsoft.WinGet.Client abgeschlossen ($moduleVersion)."
                        $appInstallerRegistration = Register-LatestWinGetAppInstallerForCurrentUser
                        $registrationText = if ($appInstallerRegistration.RegistrationChanged) { 'für den aktuellen Benutzer registriert' } else { 'bereits für den aktuellen Benutzer registriert' }
                        $wingetBootstrapMessage += " App Installer $($appInstallerRegistration.Version) $registrationText."
                        if (-not [string]::IsNullOrWhiteSpace([string]$appInstallerRegistration.AliasRegistrationMessage)) {
                            $wingetBootstrapMessage += " $($appInstallerRegistration.AliasRegistrationMessage)"
                        }
                        if ($appInstallerRegistration.InstalledFromGitHub) {
                            $wingetBootstrapMessage += ' App Installer und fehlende Abhängigkeiten wurden aus dem offiziellen WinGet-GitHub-Release bereitgestellt.'
                        }
                        $wingetPath = Resolve-WingetExecutable
                        $wingetHealth = Test-WingetExecutable -Path $wingetPath -FreshPowerShell
                        if (-not $wingetHealth.Works) { throw "WinGet ist nach der Reparatur weiterhin nicht funktionsfähig: $($wingetHealth.Output)" }
                        $wingetBootstrapMessage += " Reparatur erfolgreich; $($wingetHealth.Output)"
                        $wingetReconnectRequired = $true
                    }
                    catch {
                        $wingetPreparationSucceeded = $false
                        $wingetBootstrapMessage += ' Reparatur fehlgeschlagen; Details im Log.'
                        $wingetDiagnosticOutput += "WinGet-Reparatur:`r`n$($_.Exception.ToString())`r`n"
                    }
                }
            }

            if (-not $wingetPreparationSucceeded -or $wingetReconnectRequired) {
                $retryFreshConnection = $wingetReconnectRequired -or
                    $wingetBootstrapMessage -match '(?i)(0x800706ba|-2147023174|Failed to create instance|RPC server is unavailable|RPC-Server nicht verfügbar)'
                $retryReason = if ($wingetReconnectRequired) { 'WinGet nach Reparatur oder App-Installer-Registrierung' } else { '' }
                $result += [PSCustomObject]@{
                    Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null
                    Packages=@(); AvailableOutput=''; ActionOutput=$wingetBootstrapMessage; BootstrapMessage=$wingetBootstrapMessage; DiagnosticOutput=$wingetDiagnosticOutput
                    RetryFreshConnection=$retryFreshConnection; RetryReason=$retryReason
                }
            }
            else {
                try {
                $env:PROCESSOR_ARCHITECTURE = 'AMD64'
                $wingetCliFallback = $false
                if ($ExecutionMode -eq 'Install') {
                    # Im Installationslauf wird der Maschinen-Scope zuerst
                    # gezielt abgefragt. Die Benutzer-Scope-Abfrage folgt erst
                    # nach Abschluss dieser Pakete in der interaktiven Sitzung.
                    $cliQueryResult = Invoke-WingetCliUpgradeQuery -Path $wingetPath -Scope machine
                    $availableOutput = [string]$cliQueryResult.Output
                    $wingetQuerySources = @($cliQueryResult.Sources)
                    $wingetCliFallback = $true
                    $machineScopeSummary = "WinGet-Installationsabfrage auf Maschinen-Scope begrenzt; Quellen $(@($cliQueryResult.Sources) -join ', ')."
                    if (@($cliQueryResult.FailedSources).Count -gt 0) {
                        $machineScopeSummary += " Quellenfehler: $(@($cliQueryResult.FailedSources).Count)."
                    }
                    $wingetDiagnosticOutput = "$machineScopeSummary`r`n$([string]$cliQueryResult.DiagnosticOutput)"
                }
                elseif (-not $wingetModuleUseAllowed) {
                    # Bei bekannt inkompatiblen Modul-/AppX-Versionen ist der
                    # PowerShell-Aufruf nicht sicher: winrtact.dll kann den
                    # gesamten WSMan-Anbieterhost beenden. Die CLI bleibt der
                    # native, versionsgebundene WinGet-Einstiegspunkt.
                    $cliQueryResult = Invoke-WingetCliUpgradeQuery -Path $wingetPath
                    $availableOutput = [string]$cliQueryResult.Output
                    $wingetQuerySources = @($cliQueryResult.Sources)
                    $wingetCliFallback = $true
                    $cliCompatibilitySummary = "WinGet-CLI-Abfrage statt PowerShell-Modul wegen Versionskonflikt; Quellen $(@($cliQueryResult.Sources) -join ', ')."
                    if (@($cliQueryResult.FailedSources).Count -gt 0) {
                        $cliCompatibilitySummary += " Quellenfehler: $(@($cliQueryResult.FailedSources).Count)."
                    }
                    $wingetDiagnosticOutput = "$cliCompatibilitySummary`r`n$([string]$cliQueryResult.DiagnosticOutput)"
                }
                else {
                try {
                    $availableOutput = Get-WingetModuleUpdateOutput
                }
                catch {
                    $moduleQueryFailure = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                    $moduleQueryDiagnostic = [string]$_.Exception.ToString()
                    try {
                        $cliQueryResult = Invoke-WingetCliUpgradeQuery -Path $wingetPath
                        $availableOutput = [string]$cliQueryResult.Output
                        $wingetCliFallback = $true
                        $fallbackSummary = "Modulabfrage fehlgeschlagen; CLI-Fallback über Quellen $(@($cliQueryResult.Sources) -join ', ')."
                        if (@($cliQueryResult.FailedSources).Count -gt 0) {
                            $fallbackSummary += " Quellenfehler: $(@($cliQueryResult.FailedSources).Count)."
                        }
                        $wingetDiagnosticOutput = "$fallbackSummary`r`n$moduleQueryDiagnostic`r`nCLI-Fallback:`r`n$([string]$cliQueryResult.DiagnosticOutput)"
                    }
                    catch {
                        $cliDiagnosticProperty = $_.Exception.Data['WinGetDiagnosticOutput']
                        $cliQueryDiagnostic = if ($cliDiagnosticProperty) { [string]$cliDiagnosticProperty } else { [string]$_.Exception.ToString() }
                        $wingetDiagnosticOutput = "Modulabfrage fehlgeschlagen:`r`n$moduleQueryDiagnostic`r`nCLI-Fallback fehlgeschlagen:`r`n$cliQueryDiagnostic"
                        throw "WinGet-Modulabfrage fehlgeschlagen ($moduleQueryFailure); CLI-Fallback ebenfalls fehlgeschlagen: $($_.Exception.Message)"
                    }
                }
                # Ein erfolgreicher, aber leerer Modulaufruf gilt nicht allein
                # als Beleg dafür, dass keine Updates existieren. WinGet kann
                # über die CLI Treffer liefern, obwohl das Modul leer zurückkommt.
                # In diesem Fall dieselbe Benutzerquelle zusätzlich per CLI prüfen.
                $moduleSourceFailureLines = @($availableOutput -split "`r?`n" | Where-Object {
                    Test-WingetSourceFailureLine -Line ([string]$_)
                })
                if (-not $wingetCliFallback -and $moduleSourceFailureLines.Count -eq 0 -and
                    @(Get-WingetUpgradeLines -Output $availableOutput).Count -eq 0) {
                    $moduleEmptyOutput = [string]$availableOutput
                    $cliQueryResult = Invoke-WingetCliUpgradeQuery -Path $wingetPath
                    $availableOutput = [string]$cliQueryResult.Output
                    $wingetCliFallback = $true
                    $emptyVerificationSummary = "WinGet-Modul lieferte keine Treffer; CLI-Gegenprüfung über Quellen $(@($cliQueryResult.Sources) -join ', ')."
                    if (@($cliQueryResult.FailedSources).Count -gt 0) {
                        $emptyVerificationSummary += " Quellenfehler: $(@($cliQueryResult.FailedSources).Count)."
                    }
                    $wingetDiagnosticOutput = "$emptyVerificationSummary`r`nModulausgabe:`r`n$moduleEmptyOutput`r`nCLI-Gegenprüfung:`r`n$([string]$cliQueryResult.DiagnosticOutput)"
                }
                }
                # Im Check werden benutzerbezogene Updates zusätzlich ermittelt.
                # Bei der Installation folgt diese Abfrage erst nach den
                # maschinenweiten Paketen, damit gemeinsame Installer wie MSI
                # nicht gleichzeitig aus beiden Benutzerkontexten gestartet werden.
                if ($ExecutionMode -eq 'Check') {
                    $interactiveQuery = Get-WingetInteractiveUserUpgradeLines
                    $wingetInteractiveUserDiagnosticOutput = @($interactiveQuery.Notes) -join "`r`n"
                    $interactiveLines = @($interactiveQuery.Lines)
                    if ($interactiveLines.Count -gt 0) {
                        $knownPackages = @{}
                        foreach ($existingLine in @(Get-WingetUpgradeLines -Output $availableOutput)) {
                            $existingMatch = [regex]::Match([string]$existingLine, '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<Installed>\S+)\s+(?<Available>\S+)\s+(?<Source>\S+)\s*$')
                            if ($existingMatch.Success) {
                                $existingKey = '{0}|{1}|{2}' -f $existingMatch.Groups['Id'].Value.ToLowerInvariant(), $existingMatch.Groups['Source'].Value.ToLowerInvariant(), $existingMatch.Groups['Name'].Value.ToLowerInvariant()
                                $knownPackages[$existingKey] = $true
                            }
                        }
                        $additionalLines = foreach ($interactiveLine in $interactiveLines) {
                            $interactiveMatch = [regex]::Match([string]$interactiveLine, '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<Installed>\S+)\s+(?<Available>\S+)\s+(?<Source>\S+)\s*$')
                            if (-not $interactiveMatch.Success) { continue }
                            $interactiveKey = '{0}|{1}|{2}' -f $interactiveMatch.Groups['Id'].Value.ToLowerInvariant(), $interactiveMatch.Groups['Source'].Value.ToLowerInvariant(), $interactiveMatch.Groups['Name'].Value.ToLowerInvariant()
                            if ($knownPackages.ContainsKey($interactiveKey)) { continue }
                            $knownPackages[$interactiveKey] = $true
                            $interactiveLine
                        }
                        if (@($additionalLines).Count -gt 0) {
                            $availableOutput = (@($availableOutput, @($additionalLines)) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join [Environment]::NewLine
                        }
                    }
                    if (@($interactiveQuery.Notes).Count -gt 0) {
                        $wingetDiagnosticOutput += "`r`nAbfrage angemeldeter Benutzer:`r`n$(@($interactiveQuery.Notes) -join "`r`n")"
                    }
                }
                $sourceFailureLines = @($availableOutput -split "`r?`n" | Where-Object {
                    Test-WingetSourceFailureLine -Line ([string]$_)
                })
                $wingetSourceRefreshOutput = ''
                # Auswertbare Pakettreffer behalten, auch wenn eine andere
                # Quelle im selben CLI-Lauf einen Fehler zurückliefert.
                $packageLines = @(Get-WingetUpgradeLines -Output $availableOutput)
                if ($ExecutionMode -eq 'Install' -and $sourceFailureLines.Count -gt 0 -and $packageLines.Count -gt 0) {
                    $initialPackageLines = @($packageLines)
                    $initialAvailableOutput = [string]$availableOutput
                    $initialSourceFailures = @($sourceFailureLines)
                    $initialFailureText = @($initialSourceFailures | ForEach-Object { Get-WingetCompactOutput -Text ([string]$_) }) -join ' '
                    $sourcesToRefresh = @(
                        foreach ($sourceName in $wingetQuerySources) {
                            if ($initialFailureText -match [regex]::Escape([string]$sourceName)) { [string]$sourceName }
                        }
                    )
                    $sourcesToRefresh = @($sourcesToRefresh | Select-Object -Unique)
                    if ($sourcesToRefresh.Count -eq 0 -and $initialFailureText -match '(?i)winget') { $sourcesToRefresh = @('winget') }
                    $refreshDiagnostics = @()
                    $sourceUpdateSucceeded = $sourcesToRefresh.Count -gt 0
                    foreach ($sourceName in $sourcesToRefresh) {
                        try {
                            $sourceUpdateResult = Invoke-WindowsUpdateHiddenProcess -Path $wingetPath -Arguments @('source', 'update', '--name', $sourceName, '--disable-interactivity') -TimeoutSeconds 120
                            $sourceUpdateOutput = Get-WingetCompactOutput -Text ([string]$sourceUpdateResult.Output) -MaximumLength 300
                            $refreshDiagnostics += "Quelle '$sourceName' direkt aktualisiert (Exitcode $($sourceUpdateResult.ExitCode)): $sourceUpdateOutput"
                            if ([int]$sourceUpdateResult.ExitCode -ne 0) { $sourceUpdateSucceeded = $false }
                        }
                        catch {
                            $sourceUpdateSucceeded = $false
                            $refreshDiagnostics += "Quelle '$sourceName' direktes Update fehlgeschlagen: $(([string]$_.Exception.Message -replace '\s+', ' ').Trim())"
                        }
                    }
                    if ($sourceUpdateSucceeded) {
                        try {
                            $sourceRetryResult = Invoke-WingetCliUpgradeQuery -Path $wingetPath -Scope machine
                            $sourceRetryOutput = [string]$sourceRetryResult.Output
                            $sourceRetryFailures = @($sourceRetryOutput -split "`r?`n" | Where-Object {
                                Test-WingetSourceFailureLine -Line ([string]$_)
                            })
                            $sourceRetryPackages = @(Get-WingetUpgradeLines -Output $sourceRetryOutput)
                            $refreshDiagnostics += "WinGet-Suche nach Quellenaktualisierung erneut ausgeführt; Quellenfehler=$($sourceRetryFailures.Count), Paketupdates=$($sourceRetryPackages.Count)."
                            $wingetDiagnosticOutput += "`r`nWinGet-Quellenwiederholung:`r`n$($refreshDiagnostics -join "`r`n")`r`n$([string]$sourceRetryResult.DiagnosticOutput)"
                            if ($sourceRetryFailures.Count -eq 0) {
                                $availableOutput = $sourceRetryOutput
                                $sourceFailureLines = @()
                                $packageLines = @($sourceRetryPackages)
                                $wingetQuerySources = @($sourceRetryResult.Sources)
                            }
                            elseif ($sourceRetryPackages.Count -gt 0) {
                                # Die Wiederholung hat weiterhin einen Quellenfehler,
                                # aber verwertbare Treffer. Die gefundenen Pakete
                                # werden trotzdem einzeln versucht; die unvollständige
                                # Quelle bleibt anschließend als manuelle Prüfung offen.
                                $availableOutput = $sourceRetryOutput
                                $sourceFailureLines = @($sourceRetryFailures)
                                $packageLines = @($sourceRetryPackages)
                                $wingetQuerySources = @($sourceRetryResult.Sources)
                            }
                            else {
                                # Bei weiterhin fehlerhafter Quelle die ursprünglich
                                # eindeutig ermittelten Updates nicht verlieren.
                                $availableOutput = $initialAvailableOutput
                                $sourceFailureLines = @($initialSourceFailures) + @($sourceRetryFailures)
                                $packageLines = @($initialPackageLines)
                            }
                        }
                        catch {
                            $refreshDiagnostics += "WinGet-Suche nach Quellenaktualisierung fehlgeschlagen: $(([string]$_.Exception.Message -replace '\s+', ' ').Trim())"
                            $wingetDiagnosticOutput += "`r`nWinGet-Quellenwiederholung:`r`n$($refreshDiagnostics -join "`r`n")"
                            # Die zuerst gefundenen Paketzeilen sind weiterhin
                            # eindeutig; unten wird jedes Update einzeln geprüft.
                            $availableOutput = $initialAvailableOutput
                            $sourceFailureLines = @($initialSourceFailures)
                            $packageLines = @($initialPackageLines)
                        }
                    }
                    else {
                        $wingetDiagnosticOutput += "`r`nWinGet-Quellenaktualisierung:`r`n$($refreshDiagnostics -join "`r`n")"
                        $availableOutput = $initialAvailableOutput
                        $sourceFailureLines = @($initialSourceFailures)
                        $packageLines = @($initialPackageLines)
                    }
                }
                $excludedIdList = @($ExcludedWinGetIds -split ',' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                if ($ExecutionMode -eq 'Install' -and $excludedIdList.Count -gt 0 -and $packageLines.Count -gt 0) {
                    $eligiblePackageLines = @()
                    foreach ($candidatePackageLine in $packageLines) {
                        $candidateMatch = [regex]::Match(
                            [string]$candidatePackageLine,
                            '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<InstalledVersion>\S+)\s+(?<AvailableVersion>\S+)\s+(?<Source>[^\s]+)\s*$',
                            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                        )
                        if ($candidateMatch.Success -and [string]$candidateMatch.Groups['Id'].Value -in $excludedIdList) {
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$true; Skipped=$true
                                SkipReason="Paket '$($candidateMatch.Groups['Id'].Value)' wurde bereits im Verwaltungsserver-Vorabpfad behandelt und wird in diesem Installationslauf nicht erneut gestartet."
                                ExitCode=0; Packages=@($candidatePackageLine); AvailableOutput=$availableOutput; ActionOutput=''
                            }
                        }
                        else { $eligiblePackageLines += $candidatePackageLine }
                    }
                    $packageLines = @($eligiblePackageLines)
                }
                if ($sourceFailureLines.Count -gt 0 -and ($ExecutionMode -eq 'Check' -or $packageLines.Count -eq 0)) {
                    $sourceFailureText = @($sourceFailureLines | ForEach-Object { Get-WingetCompactOutput -Text ([string]$_) }) -join ' '
                    $result += [PSCustomObject]@{
                        Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=1
                        Packages=$(if ($ExecutionMode -eq 'Check') { $packageLines } else { @() }); AvailableOutput=$availableOutput; ActionOutput=$sourceFailureText
                        DiagnosticOutput=$wingetDiagnosticOutput
                        RetryAfterSourceReset=($ExecutionMode -eq 'Check')
                    }
                    return @($result)
                }
                # Winget liefert eine formatierte Tabelle. Echte Upgrade-Zeilen
                # enden mit ihrer Paketquelle (winget oder msstore); Status- und
                # Lizenztexte tun dies nicht. Quellenfehler können ebenfalls
                # mit "winget" enden und dürfen daher nicht als Paket gelten.
                if ($ExecutionMode -eq 'Check' -and $packageLines.Count -eq 0 -and $sourceFailureLines.Count -eq 0) {
                    if ($SourceResetPerformed -or $SourcePackageRefreshPerformed) {
                        # Die äußere Wiederholungslogik hat Quellenreset oder
                        # Quellenpaketprüfung bereits ausgeführt. Eine weiterhin
                        # leere, fehlerfreie Suche ist jetzt ein gültiges Ergebnis;
                        # sie darf keine zweite Reparaturrunde anfordern.
                    }
                    else {
                        # Ein erfolgreicher, aber leerer Suchlauf kann auf einen
                        # beschädigten lokalen Quellenzustand hindeuten. Der nötige
                        # vollständige Reset erfolgt nur, wenn keine kundeneigenen
                        # Quellen vorhanden sind.
                        $sourceResetState = Get-WingetSourceResetState
                        if ($sourceResetState.Allowed) {
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null
                                Packages=@(); AvailableOutput=$availableOutput
                                ActionOutput='WinGet-Suche war leer; Quellenreset und eine erneute Prüfung in neuer Verbindung erforderlich.'
                                RetryAfterSourceReset=$true
                            }
                            return @($result)
                        }
                        else {
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null
                                Packages=@(); AvailableOutput=$availableOutput
                                ActionOutput='WinGet-Suche war leer und der Quellenreset ist noch durch das 24-Stunden-Limit gesperrt; das Quellenpaket muss erneuert und die Abfrage wiederholt werden.'
                                RetryAfterSourcePackageRefresh=$true
                            }
                            return @($result)
                        }
                    }
                }
                $actionOutput = ''
                $exitCode = 0
                if ($ExecutionMode -eq 'Install' -and $packageLines.Count -gt 0) {
                    # Pakete einzeln ausführen, damit ein Installationsart-Konflikt
                    # ein anderes Paket nicht am Aktualisieren hindert. Es wird
                    # bewusst kein --installer-type erzwungen und nichts entfernt.
                    $noUpdateCodes = @(-1978335188, -1978335189, -1978335192)
                    foreach ($packageLine in $packageLines) {
                        # WinGet richtet Tabellen je nach Terminalbreite und
                        # Ausgabeumleitung unterschiedlich aus. Paketname und ID
                        # sind deshalb nicht zuverlässig durch mehrere Leerzeichen
                        # getrennt. Die letzten vier Spalten (ID, installierte
                        # Version, verfügbare Version, Quelle) werden von rechts
                        # erkannt; so wird eine Versionsnummer nie als Paket-ID
                        # fehlinterpretiert.
                        $packageMatch = [regex]::Match(
                            [string]$packageLine,
                            '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<InstalledVersion>\S+)\s+(?<AvailableVersion>\S+)\s+(?<Source>[^\s]+)\s*$',
                            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                        )
                        if (-not $packageMatch.Success) {
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$false; Skipped=$true
                                SkipReason="Paket-ID konnte nicht sicher aus der WinGet-Liste gelesen werden: $($packageLine.Trim())"
                                ExitCode=$null; Packages=@(); AvailableOutput=$availableOutput; ActionOutput=''
                                RequiresManualAction=$true; ManualActionText="Paketzeile konnte nicht automatisch zugeordnet werden: $($packageLine.Trim()). Bitte dieses WinGet-Update manuell prüfen."
                            }
                            continue
                        }

                        $packageId = $packageMatch.Groups['Id'].Value
                        $packageName = $packageMatch.Groups['Name'].Value.Trim()
                        $packageSource = if ($packageMatch.Groups['Source'].Success) { $packageMatch.Groups['Source'].Value } else { 'winget' }
                        $packageActionOutput = ''
                        try {
                            if ($wingetCliFallback) {
                                $moduleUpdate = Invoke-WingetCliPackageUpdate -Path $wingetPath -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value -Scope machine
                            } else {
                                $moduleUpdate = Invoke-WingetModulePackageUpdate -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value
                                if (-not $moduleUpdate.Success) {
                                    $moduleFailureOutput = [string]$moduleUpdate.Output
                                    $cliUpdate = Invoke-WingetCliPackageUpdate -Path $wingetPath -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value -Scope machine
                                    if ($cliUpdate.Success) {
                                        $moduleUpdate = $cliUpdate
                                    }
                                    else {
                                        $moduleUpdate = [PSCustomObject]@{
                                            Success = $false
                                            ExitCode = $cliUpdate.ExitCode
                                            Output = "Modul: $moduleFailureOutput; CLI-Fallback: $($cliUpdate.Output)"
                                            Result = $null
                                        }
                                    }
                                }
                            }
                            if (-not $packageActionOutput) { $packageActionOutput = [string]$moduleUpdate.Output }
                            $packageExitCode = [int]$moduleUpdate.ExitCode
                            # WinGet kann in seiner lokalen Quelle noch auf einen
                            # bereits entfernten Manifest-Hash zeigen. In diesem
                            # Fall aktualisieren wir die Standardquellen per CLI
                            # und wiederholen das Paket einmal.
                            if ($packageActionOutput -match '(?i)(0x80190194|GetUpstreamFile failed on source: https://cdn\.winget\.microsoft\.com/cache)') {
                                try {
                                    Reset-WingetDefaultSources -Path $wingetPath
                                    $sourceUpdateOutput = 'WinGet-Standardquellen per CLI zurückgesetzt und Quelle winget aktualisiert.'
                                    $sourceUpdateExitCode = 0
                                }
                                catch {
                                    $sourceUpdateOutput = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                                    $sourceUpdateExitCode = 1
                                }
                                $packageActionOutput += "`nGezieltes Aktualisieren der WinGet-Quelle nach HTTP-404 (ExitCode $sourceUpdateExitCode):`n$($sourceUpdateOutput.Trim())"
                                if ($sourceUpdateExitCode -eq 0) {
                                    $retryResult = Invoke-WingetCliPackageUpdate -Path $wingetPath -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value -Scope machine
                                    $packageExitCode = [int]$retryResult.ExitCode
                                    $packageActionOutput += "`nErneuter Paketversuch nach Quellenaktualisierung:`n$([string]$retryResult.Output)"
                                }
                            }
                            $noInstalledPackage = $packageActionOutput -match '(?i)(kein installiertes Paket gefunden|no installed package found)'
                            $technologyMismatch = $packageActionOutput -match '(?i)(Installationstechnologie unterscheidet sich|installation technology (?:is|differs from|does not match)|technology.*different from the current installed)'
                            $appxSessionFailure = $packageActionOutput -match '(?i)(0x80073D19|2147958041|Fehler aufgrund der Abmeldung eines Benutzers|An error occurred because a user was logged off)'
                            $appxRegistrationFailure = $packageActionOutput -match '(?i)(0x80070002|2147942402)' -and
                                $packageActionOutput -match '(?i)(RegisterByPackageFullName|RegisterPackageByFullName|im Repository nicht gefunden werden konnte|could not be found in the repository)'
                            if ($technologyMismatch) {
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=$false; Skipped=$true
                                    SkipReason="Paket '$packageName' [$packageId]: WinGet meldet einen Konflikt der Installationstechnologie. Es wurde nichts deinstalliert."
                                    ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$packageActionOutput
                                    RequiresManualAction=$true; ManualActionText="Paket '$packageName' [$packageId] konnte wegen eines Konflikts der Installationstechnologie nicht automatisch aktualisiert werden. Bitte Installationsart manuell prüfen und das Paket aktualisieren."
                                }
                            }
                            elseif ($appxSessionFailure -or $appxRegistrationFailure) {
                                $manualCommand = "Import-Module Microsoft.WinGet.Client; Update-WinGetPackage -Id '$packageId' -Source '$packageSource' -Mode Interactive"
                                $failureReason = if ($appxSessionFailure) {
                                    'Windows meldet 0x80073D19 (Benutzer abgemeldet), während WinGet eine AppX-Abhängigkeit bereitstellt.'
                                } else {
                                    'WinGet konnte das AppX-Paket nach der Bereitstellung nicht im Paketrepository registrieren (0x80070002).'
                                }
                                $manualHint = "Paket '$packageName' [$packageId] konnte über WinRM nicht abgeschlossen werden. $failureReason Dieses AppX-Update muss direkt auf dem Zielsystem in einer angemeldeten PowerShell-Sitzung ausgeführt werden: $manualCommand"
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''
                                    ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput
                                    ActionOutput=$manualHint; DiagnosticOutput=$packageActionOutput
                                    RequiresManualAction=$true; ManualActionText=$manualHint
                                }
                            }
                            elseif ($noInstalledPackage) {
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=$false; Skipped=$true
                                    SkipReason="Paket '$packageName' [$packageId] steht in der Upgrade-Liste, konnte aber per ID und exaktem Namen nicht als installiertes Paket aufgelöst werden. Es wurde übersprungen."
                                    ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$packageActionOutput
                                    RequiresManualAction=$true; ManualActionText="Paket '$packageName' [$packageId] steht in der WinGet-Upgrade-Liste, wurde lokal aber nicht als installiert erkannt. Bitte Installation und Paket-ID manuell prüfen."
                                }
                            }
                            else {
                                $installerErrorCode = [regex]::Match($packageActionOutput, '(?i)0x[0-9a-f]{8}').Value
                                $packageErrorSummary = "Paket '$packageName' [$packageId] konnte nicht automatisch aktualisiert werden"
                                if ($installerErrorCode) { $packageErrorSummary += " ($installerErrorCode)" }
                                elseif ($null -ne $packageExitCode) { $packageErrorSummary += " (Exitcode $packageExitCode)" }
                                $packageErrorSummary += '; manuelle Prüfung erforderlich.'
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=($packageExitCode -eq 0 -or $packageExitCode -in $noUpdateCodes); Skipped=$false
                                    SkipReason=''; ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$packageActionOutput
                                    ErrorSummary=$packageErrorSummary; DiagnosticOutput=$packageActionOutput; RequiresManualAction=($packageExitCode -ne 0 -and $packageExitCode -notin $noUpdateCodes)
                                }
                            }
                        }
                        catch {
                            $packageException = $_.Exception.Message
                            if ($packageException.Length -gt 240) { $packageException = $packageException.Substring(0, 237) + '...' }
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''
                                ExitCode=$null; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$_.Exception.Message
                                ErrorSummary="Paket '$packageName' [$packageId] konnte nicht automatisch aktualisiert werden; manuelle Prüfung erforderlich. $packageException"
                                DiagnosticOutput=$_.Exception.ToString(); RequiresManualAction=$true
                            }
                        }
                    }
                    if ($sourceFailureLines.Count -gt 0) {
                        $sourceFailureText = @($sourceFailureLines | ForEach-Object { Get-WingetCompactOutput -Text ([string]$_) }) -join ' '
                        $result += [PSCustomObject]@{
                            Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=1
                            Packages=@($packageLines); AvailableOutput=$availableOutput
                            ActionOutput="Die WinGet-Quelle konnte auch nach der einmaligen Aktualisierung nicht fehlerfrei abgefragt werden. Erkannte Pakete wurden einzeln versucht; die Suche kann unvollständig sein. Quellenfehler: $sourceFailureText"
                            DiagnosticOutput=$wingetDiagnosticOutput
                            RequiresManualAction=$true
                            ManualActionText="WinGet-Quelle blieb trotz einmaligem Aktualisierungsversuch fehlerhaft. Erkannte Pakete wurden einzeln versucht; bitte die WinGet-Suche auf Vollständigkeit prüfen. Quellenfehler: $sourceFailureText"
                        }
                    }
                }
                    else {
                    if ($sourceFailureLines.Count -gt 0) {
                        $wingetFailureDetails = @()
                        if (-not [string]::IsNullOrWhiteSpace($wingetBootstrapMessage)) { $wingetFailureDetails += $wingetBootstrapMessage.Trim() }
                        foreach ($failureLine in $sourceFailureLines) {
                            $compactFailure = Get-WingetCompactOutput -Text ([string]$failureLine)
                            if ($compactFailure -and $wingetFailureDetails -notcontains $compactFailure) { $wingetFailureDetails += $compactFailure }
                        }
                        $actionOutput = $wingetFailureDetails -join ' '
                    }
                    $result += [PSCustomObject]@{ Manager='Winget'; Available=$true; Success=($sourceFailureLines.Count -eq 0); Skipped=$false; SkipReason=''; ExitCode=$(if ($sourceFailureLines.Count -gt 0) { 1 } else { 0 }); Packages=$packageLines; AvailableOutput=$availableOutput; ActionOutput=$actionOutput }
                }
                if ($ExecutionMode -eq 'Install') {
                    $interactiveQuery = Get-WingetInteractiveUserUpgradeLines -InstallUpdates
                    $wingetInteractiveUserDiagnosticOutput = @($interactiveQuery.Notes) -join "`r`n"
                    foreach ($interactivePackage in @($interactiveQuery.Packages)) {
                        $displayName = "[$($interactivePackage.UserName)] $($interactivePackage.Name)"
                        $packageRow = [pscustomobject]@{
                            Name = $displayName; Id = $interactivePackage.Id
                            InstalledVersion = $interactivePackage.InstalledVersion
                            AvailableVersion = $interactivePackage.AvailableVersion
                            Source = $interactivePackage.Source
                        }
                        $packageOutput = [string]$interactivePackage.Output
                        $manualAction = -not [bool]$interactivePackage.Success
                        $adminMembershipKnown = $null -ne $interactivePackage.PSObject.Properties['AccountIsAdministratorMember']
                        $tokenElevationKnown = $null -ne $interactivePackage.PSObject.Properties['TokenIsElevated']
                        $privilegeHint = if ($manualAction -and $adminMembershipKnown -and -not [bool]$interactivePackage.AccountIsAdministratorMember) {
                            'Das Konto ist kein Mitglied der lokalen Administratoren. Wenn der Installer erhöhte Rechte verlangt, kann dieser automatische Lauf keine UAC-Genehmigung oder Administratorkennwörter bereitstellen.'
                        } elseif ($manualAction -and $tokenElevationKnown -and -not [bool]$interactivePackage.TokenIsElevated) {
                            'Der Benutzeraufgaben-Token ist nicht erhöht. Wenn der Installer erhöhte Rechte verlangt, kann dieser automatische Lauf keine UAC-Genehmigung oder Administratorkennwörter bereitstellen.'
                        } else { '' }
                        $manualText = if ($manualAction) {
                            "Benutzerbezogenes WinGet-Update '$($interactivePackage.Name)' für '$($interactivePackage.UserName)' fehlgeschlagen (Exitcode $($interactivePackage.ExitCode)). $privilegeHint $packageOutput"
                        } else { '' }
                        $result += [pscustomobject]@{
                            Manager='Winget'; Available=$true; Success=([bool]$interactivePackage.Success)
                            Skipped=$false; SkipReason=''; ExitCode=[int]$interactivePackage.ExitCode
                            Packages=@($packageRow); AvailableOutput=''; ActionOutput=$packageOutput
                            RequiresManualAction=$manualAction; ManualActionText=$manualText
                            InteractiveUser=[string]$interactivePackage.UserName
                        }
                    }
                    if (@($interactiveQuery.Notes).Count -gt 0) {
                        $wingetDiagnosticOutput += "`r`nAbfrage angemeldeter Benutzer nach maschinenweiten Updates:`r`n$(@($interactiveQuery.Notes) -join "`r`n")"
                    }
                }
                }
                catch {
                    $exceptionMessage = [string]$_.Exception.Message
                    $retryFreshConnection = $exceptionMessage -match '(?i)(0x800706ba|-2147023174|Failed to create instance|RPC server is unavailable|RPC-Server nicht verfügbar)'
                    $queryTimedOut = $_.Exception -is [System.TimeoutException] -or
                        $exceptionMessage -match '(?i)(WinGet-Katalogabfrage hat das Zeitlimit|WinGet.*Zeitlimit von 5 Minuten überschritten)'
                    $retryAfterSourceReset = $queryTimedOut -and $ExecutionMode -eq 'Check'
                    $retryFreshConnection = $retryFreshConnection -or ($queryTimedOut -and $ExecutionMode -eq 'Install')
                    $exceptionDiagnostic = @(
                        $_.Exception.ToString()
                        if (-not [string]::IsNullOrWhiteSpace([string]$_.ScriptStackTrace)) { "PowerShell-Stacktrace:`r`n$($_.ScriptStackTrace)" }
                    ) -join "`r`n"
                    $diagnosticText = if ($wingetDiagnosticOutput) { "$wingetDiagnosticOutput`r`nAbfragefehler:`r`n$exceptionDiagnostic" } else { $exceptionDiagnostic }

                    # Ein Fehler in einer nachgelagerten WinGet-Auswertung darf
                    # bereits erfasste Einzelresultate nicht durch einen
                    # zusätzlichen allgemeinen WinGet-Fehler überdecken. Das
                    # gilt auch, wenn ein Paket korrekt als manuelle Nacharbeit
                    # dokumentiert wurde.
                    $recordedInstallResults = @($result | Where-Object {
                        $_.Manager -eq 'Winget' -and @($_.Packages).Count -gt 0
                    })
                    if ($ExecutionMode -eq 'Install' -and $recordedInstallResults.Count -gt 0) {
                        foreach ($recordedResult in $recordedInstallResults) {
                            $diagnosticProperty = $recordedResult.PSObject.Properties['DiagnosticOutput']
                            $existingDiagnostic = if ($diagnosticProperty) { [string]$diagnosticProperty.Value } else { '' }
                            $combinedDiagnostic = (@($existingDiagnostic, "WinGet-Folgeauswertung nach den Einzelversuchen fehlgeschlagen; die dokumentierten Paketresultate bleiben maßgeblich:`r`n$diagnosticText" |
                                Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join "`r`n")
                            if ($diagnosticProperty) {
                                $recordedResult.DiagnosticOutput = $combinedDiagnostic
                            }
                            else {
                                Add-Member -InputObject $recordedResult -NotePropertyName DiagnosticOutput -NotePropertyValue $combinedDiagnostic
                            }
                        }
                    }
                    else {
                        $result += [PSCustomObject]@{
                            Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null
                            Packages=@(); AvailableOutput=''; ActionOutput='WinGet-Abfrage fehlgeschlagen; Details im Log.'; DiagnosticOutput=$diagnosticText
                            RetryFreshConnection=$retryFreshConnection; RetryAfterSourceReset=$retryAfterSourceReset
                        }
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($wingetDiagnosticOutput)) {
                foreach ($wingetResult in @($result | Where-Object { $_.Manager -eq 'Winget' })) {
                    if (-not $wingetResult.PSObject.Properties['DiagnosticOutput']) {
                        Add-Member -InputObject $wingetResult -NotePropertyName DiagnosticOutput -NotePropertyValue $wingetDiagnosticOutput
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($wingetInteractiveUserDiagnosticOutput)) {
                foreach ($wingetResult in @($result | Where-Object { $_.Manager -eq 'Winget' })) {
                    Add-Member -InputObject $wingetResult -NotePropertyName InteractiveUserDiagnosticOutput -NotePropertyValue $wingetInteractiveUserDiagnosticOutput -Force
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($wingetBootstrapMessage)) {
                foreach ($wingetResult in @($result | Where-Object { $_.Manager -eq 'Winget' })) {
                    Add-Member -InputObject $wingetResult -NotePropertyName BootstrapMessage -NotePropertyValue $wingetBootstrapMessage -Force
                }
            }
        }
        return @($result)
    }

    $localNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    $isLocalTarget = $localNames -contains $ComputerName
    $packageResults = @()

    if (-not $EnableWinget) {
        $packageResults = @(Invoke-WindowsUpdatePackageWorker -ComputerName $ComputerName -AuthInfo $AuthInfo `
            -ScriptBlock $packageScript -ArgumentList @($Mode, $false, $EnableChocolatey, $false, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $false, $IncludeInteractiveUserUpdates) -IsLocalTarget $isLocalTarget `
            -NoTimeout -OperationName "Paketmanager-Prüfung auf $ComputerName")
    }
    else {
        # Chocolatey und WinGet getrennt ausführen. So bleiben Chocolatey-
        # Ergebnisse erhalten, auch wenn WinGet hängen bleibt oder wiederholt wird.
        $baseResults = @(Invoke-WindowsUpdatePackageWorker -ComputerName $ComputerName -AuthInfo $AuthInfo `
            -ScriptBlock $packageScript -ArgumentList @($Mode, $false, $EnableChocolatey, $false, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $false, $IncludeInteractiveUserUpdates) -IsLocalTarget $isLocalTarget `
            -NoTimeout -OperationName "Chocolatey-Prüfung auf $ComputerName")
        $packageResults += @($baseResults | Where-Object { $_.Manager -eq 'Chocolatey' })

        $wingetTimeoutSeconds = 300
        $hasCheckTimeout = $Mode -eq 'Check'
        $firstWingetResult = $null
        $retryRequired = $false
        $retryRequiresSourceReset = $false
        $retryRequiresSourcePackageRefresh = $false
        $retryReason = ''
        $firstDiagnostic = ''
        $retryDiagnostic = ''
        $retryResult = $null
        if ($hasCheckTimeout) { Write-CommonLog $WriteLog "WinGet-Prüfung auf $ComputerName gestartet (Zeitlimit: 5 Minuten)." }

        try {
            $initialParameters = @{
                ComputerName = $ComputerName
                AuthInfo = $AuthInfo
                ScriptBlock = $packageScript
                ArgumentList = @($Mode, $true, $false, $false, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $false, $IncludeInteractiveUserUpdates)
                IsLocalTarget = $isLocalTarget
                OperationName = "WinGet-Prüfung auf $ComputerName"
                WriteLog = $WriteLog
            }
            if ($hasCheckTimeout) { $initialParameters.TimeoutSeconds = $wingetTimeoutSeconds }
            else { $initialParameters.NoTimeout = $true }
            $wingetResults = @(Invoke-WindowsUpdatePackageWorker @initialParameters | Where-Object { $_.Manager -eq 'Winget' })
            if ($wingetResults.Count -eq 0) { throw 'Die WinGet-Prüfung lieferte kein Ergebnis.' }
            $firstWingetResult = $wingetResults[-1]
            $firstDiagnosticProperty = $firstWingetResult.PSObject.Properties['DiagnosticOutput']
            if ($firstDiagnosticProperty) { $firstDiagnostic = [string]$firstDiagnosticProperty.Value }
            $resetProperty = $firstWingetResult.PSObject.Properties['RetryAfterSourceReset']
            $sourcePackageRefreshProperty = $firstWingetResult.PSObject.Properties['RetryAfterSourcePackageRefresh']
            $connectionProperty = $firstWingetResult.PSObject.Properties['RetryFreshConnection']
            if ($resetProperty -and [bool]$resetProperty.Value) {
                $retryRequired = $true
                $retryRequiresSourceReset = $true
                $retryReason = 'Quellenreset erforderlich'
            }
            elseif ($sourcePackageRefreshProperty -and [bool]$sourcePackageRefreshProperty.Value) {
                $retryRequired = $true
                $retryRequiresSourcePackageRefresh = $true
                $retryReason = 'WinGet-Quellenpaket muss im Remoting-Benutzerkontext erneuert werden'
            }
            elseif ($connectionProperty -and [bool]$connectionProperty.Value) {
                $retryRequired = $true
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
            $retryRequiresSourceReset = $true
            $retryReason = 'Zeitlimit erreicht; Quellenreset erforderlich'
            $firstDiagnostic = $_.Exception.ToString()
        }

        if ($retryRequired) {
            $retryDescription = if ($retryRequiresSourceReset) {
                'Quellenreset, Erneuerung des WinGet-Quellenpakets und einmalige Wiederholung'
            } elseif ($retryRequiresSourcePackageRefresh) {
                'Erneuerung des WinGet-Quellenpakets und einmalige Wiederholung'
            } else { 'einmalige Wiederholung' }
            $sourceResetPerformed = $false
            Write-CommonLog $WriteLog "WinGet auf ${ComputerName}: $retryReason; starte $retryDescription über eine neue Verbindung."
            try {
                if ($retryReason -match '(?i)WinGet nach Reparatur oder App-Installer-Registrierung') {
                    # Nach einer AppX-Registrierung meldet Add-AppxPackage den
                    # Vorgang synchron als abgeschlossen, während App Installer
                    # und WinGet-Quelle im Remoting-Kontext noch kurz den neuen
                    # Paketstatus übernehmen. Ein sofortiger neuer WinRM-Job
                    # kann dann hängen; ein nachfolgender Check funktioniert,
                    # sobald die Registrierung vollständig sichtbar ist.
                    $appxSettleDelaySeconds = 15
                    Write-CommonLog $WriteLog "AppX-Registrierung auf $ComputerName wurde geändert; warte $appxSettleDelaySeconds Sekunden vor der WinGet-Wiederholung in neuer Verbindung."
                    Start-Sleep -Seconds $appxSettleDelaySeconds
                }
                if ($retryRequiresSourceReset) {
                    if ($isLocalTarget) {
                        $null = Reset-WindowsUpdateLocalWinGetSources -TimeoutSeconds $wingetTimeoutSeconds -WriteLog $WriteLog
                    } else {
                        $null = Reset-WindowsUpdateRemoteWinGetSources -ComputerName $ComputerName -AuthInfo $AuthInfo -TimeoutSeconds $wingetTimeoutSeconds -WriteLog $WriteLog
                    }
                    $sourceResetPerformed = $true
                    Write-CommonLog $WriteLog "WinGet-Quellen auf $ComputerName zurückgesetzt; Wiederholungsprüfung startet in einer neuen Sitzung."
                }
                $sourcePackageRefreshPerformed = $retryRequiresSourcePackageRefresh -or $sourceResetPerformed

                $retryParameters = @{
                    ComputerName = $ComputerName
                    AuthInfo = $AuthInfo
                    ScriptBlock = $packageScript
                    ArgumentList = @($Mode, $true, $false, $sourceResetPerformed, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $sourcePackageRefreshPerformed, $IncludeInteractiveUserUpdates)
                    IsLocalTarget = $isLocalTarget
                    OperationName = "WinGet-Wiederholungsprüfung auf $ComputerName"
                    WriteLog = $WriteLog
                }
                if ($hasCheckTimeout) { $retryParameters.TimeoutSeconds = $wingetTimeoutSeconds }
                else { $retryParameters.NoTimeout = $true }
                $retryResults = @(Invoke-WindowsUpdatePackageWorker @retryParameters | Where-Object { $_.Manager -eq 'Winget' })
                if ($retryResults.Count -eq 0) { throw 'Die Wiederholungsprüfung lieferte kein WinGet-Ergebnis.' }
                $retryResult = $retryResults[-1]
                $retryDiagnosticProperty = $retryResult.PSObject.Properties['DiagnosticOutput']
                if ($retryDiagnosticProperty) { $retryDiagnostic = [string]$retryDiagnosticProperty.Value }
                $retryResetProperty = $retryResult.PSObject.Properties['RetryAfterSourceReset']
                $retryConnectionProperty = $retryResult.PSObject.Properties['RetryFreshConnection']
                if (($retryResetProperty -and [bool]$retryResetProperty.Value) -or
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
                $retryMessage = if ($sourcePackageRefreshPerformed -and @($retryResult.Packages).Count -eq 0) {
                    'WinGet-Abfrage nach Prüfung des Quellenpakets in neuer Verbindung erfolgreich; keine Paketupdates verfügbar.'
                } elseif ($retryRequiresSourceReset) {
                    'WinGet-Wiederholungsprüfung nach Quellenreset und Erneuerung des Quellenpakets erfolgreich.'
                } elseif ($retryRequiresSourcePackageRefresh) {
                    'WinGet-Wiederholungsprüfung nach Erneuerung des Quellenpakets erfolgreich.'
                } else {
                    'WinGet-Wiederholungsprüfung in neuer Sitzung erfolgreich.'
                }
                foreach ($wingetResult in $retryResults) {
                    $bootstrapProperty = $wingetResult.PSObject.Properties['BootstrapMessage']
                    $existingMessage = if ($bootstrapProperty) { [string]$bootstrapProperty.Value } else { '' }
                    if ([string]::IsNullOrWhiteSpace($existingMessage)) {
                        Add-Member -InputObject $wingetResult -NotePropertyName BootstrapMessage -NotePropertyValue $retryMessage -Force
                    } else {
                        Add-Member -InputObject $wingetResult -NotePropertyName BootstrapMessage -NotePropertyValue "$existingMessage $retryMessage" -Force
                    }
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
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation "$($packageResult.Manager)-$Mode" -Target $ComputerName -DiagnosticText ([string]$diagnosticProperty.Value)
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
            $logOnly = $bootstrapMessage -match '(?i)WinGet-Abfrage war erfolgreich; keine Paketupdates verfügbar\. Quellenreset wegen des 24-Stunden-Limits übersprungen\.|WinGet-Abfrage nach Quellenreset in neuer Sitzung erfolgreich; keine Paketupdates verfügbar\.|WinGet-Abfrage nach Prüfung des Quellenpakets in neuer Verbindung erfolgreich; keine Paketupdates verfügbar\.'
            if ($WriteLog) { & $WriteLog $bootstrapMessage ([bool]$logOnly) }
        }
    }
    return @($packageResults)
}
