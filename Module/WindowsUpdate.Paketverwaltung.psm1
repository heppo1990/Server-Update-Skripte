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
        [string[]]$ExcludeWinGetIds = @(),
        [string[]]$ExcludeChocolateyIds = @(),
        [scriptblock]$WriteLog
    )

    # Der Block läuft lokal oder innerhalb der vorhandenen WinRM-Verbindung.
    # Er gibt ausschließlich strukturierte Daten zurück; Darstellung und Bericht
    # bleiben bei den aufrufenden Skripten.
    $packageScript = {
        param([string]$ExecutionMode, [bool]$UseWinget, [bool]$UseChocolatey, [bool]$SourceResetPerformed = $false, [string]$ExcludedWinGetIds = '', [string]$ExcludedChocolateyIds = '', [bool]$SourcePackageRefreshPerformed = $false)

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

        function Ensure-WinGetSourcePackageForCurrentUser {
            param([switch]$Refresh)
            # Die WinGet-Communityquelle wird als benutzerbezogenes AppX-Paket
            # bereitgestellt. In nicht interaktiven WinRM-Sitzungen kann WinGet
            # den Index zwar herunterladen, aber nicht zuverlässig registrieren.
            # Deshalb fehlt er später trotz erreichbarer Quelle im Benutzerprofil.
            # Ein Quellenreset kann einen veralteten Zustand allein nicht beheben.
            # Ein vorhandenes Paket wird aber nur ersetzt, wenn das heruntergeladene
            # MSIX tatsächlich neuer ist. Eine erneute AppX-Registrierung derselben
            # Version kann auf Servern mit aktivem Paketprofil an PLM scheitern.
            $bootstrapScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$refreshSource = __REFRESH_SOURCE__
$sourcePath = $null
$sourceChanged = $false
$sourceRefreshed = $false
try {
    $registered = @(Get-AppxPackage -Name Microsoft.Winget.Source -ErrorAction Stop |
        Where-Object { $_.Status -eq 'Ok' })
    if ($registered.Count -eq 0 -or $refreshSource) {
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
            }
            finally { $archive.Dispose() }

            $installedVersion = @($registered | Sort-Object { [version]$_.Version } -Descending |
                Select-Object -First 1)[0].Version
            $shouldRegister = $downloadVersion -gt [version]$installedVersion
        }

        if ($shouldRegister) {
            $sourceChanged = $true
            Add-AppxPackage -Path $sourcePath -ErrorAction Stop
            $registered = @(Get-AppxPackage -Name Microsoft.Winget.Source -ErrorAction Stop |
                Where-Object { $_.Status -eq 'Ok' })
            if ($registered.Count -eq 0) {
                throw 'Das WinGet-Quellenpaket wurde nach Add-AppxPackage im aktuellen Benutzerprofil nicht gefunden.'
            }
            $sourceRefreshed = $sourceWasRegistered
        }
    }
    [Console]::Out.WriteLine('__WINGETSOURCE__SUCCESS|{0}|{1}|{2}', [string]$registered[-1].Version, $sourceChanged, $sourceRefreshed)
}
catch {
    [Console]::Error.WriteLine($_.Exception.ToString())
    exit 1
}
finally {
    if ($sourcePath -and (Test-Path -LiteralPath $sourcePath)) {
        Remove-Item -LiteralPath $sourcePath -Force -ErrorAction SilentlyContinue
    }
}
'@
            $refreshSourceLiteral = if ($Refresh) { '$true' } else { '$false' }
            $bootstrapScript = $bootstrapScript.Replace('__REFRESH_SOURCE__', $refreshSourceLiteral)
            $shellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
                throw 'Windows PowerShell 5.1 wurde für die WinGet-Quellenregistrierung nicht gefunden.'
            }
            $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrapScript))
            $processResult = Invoke-WindowsUpdateHiddenProcess -Path $shellPath -Arguments @(
                '-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-EncodedCommand', $encodedScript
            )
            $output = [string]$processResult.Output
            $exitCode = [int]$processResult.ExitCode
            $successLine = @($output -split "`r?`n" | Where-Object { $_ -match '^__WINGETSOURCE__SUCCESS\|' } | Select-Object -Last 1)
            if ($exitCode -ne 0 -or $successLine.Count -eq 0) {
                throw "Registrierung des WinGet-Quellenpakets fehlgeschlagen (Exitcode $exitCode): $output"
            }
            $successFields = $successLine[0] -split '\|', 4
            return [pscustomobject]@{
                Changed = [bool]::Parse($successFields[2]) -and -not [bool]::Parse($successFields[3])
                Version = $successFields[1]
                Refreshed = [bool]::Parse($successFields[3])
                Output = $output
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
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ Path = $Path } -Compress)))
                    $childSource = @'
$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$wingetArguments = @($data.Arguments)
& $data.Path --version 2>&1
exit $LASTEXITCODE
'@ -replace '__PAYLOAD__', $payload
                    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
                    $output = (& $shellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedChild 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
                } else {
                    $output = (& $Path --version 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
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
            return $Line -match '(?i)([\u2580-\u259F]|\d+(?:\.\d+)?\s*(?:KB|MB|GB)\s*/\s*\d+(?:\.\d+)?\s*(?:KB|MB|GB)|\b\d{1,3}%\b|Terms of Transaction|terms of use|Nutzungsbedingungen|Vereinbarungen der Quelle|Vereinbarungen vor der Verwendung|geographic region|geografische Region|two-letter region|zwei Buchstaben.*Region|accept.*agreement|Zustimmung.*Vereinbarung|no installed package found|es wurde kein installiertes Paket gefunden|no available upgrade|no upgrades available|keine Paketupdates verfügbar|keine Aktualisierungen verfügbar|failed when searching|Fehler beim Durchsuchen der Quelle|Ergebnisse werden nicht einbezogen|results? (?:are )?not included|Store terms|Store-Bedingungen)'
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
            param([Parameter(Mandatory)][string]$Path)
            if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                throw 'winget.exe wurde für den CLI-Fallback nicht gefunden.'
            }
            $cliResult = Invoke-WingetRunspaceWithTimeout -ArgumentList @($Path) -TimeoutSeconds 210 -ScriptBlock {
                param([string]$WingetPath)
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
            # Pakete in genau diesem Benutzerkontext aktualisiert.
            $upgradeLines = @()
            $notes = @()
            $packageResults = @()
            $currentSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
            $users = @{}
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

            foreach ($userSid in @($users.Keys)) {
                $userName = [string]$users[$userSid]
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
                $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
                if (-not (Test-Path -LiteralPath $powershellPath -PathType Leaf)) {
                    $notes += "Abfrage für '$userName' übersprungen: Windows PowerShell fehlt."
                    continue
                }

                $resultPathJson = ConvertTo-Json -InputObject $resultPath -Compress
                $queryScript = @'
$ErrorActionPreference = 'Stop'
$resultPath = __RESULT_PATH__
$query = [ordered]@{ Success = $false; Output = ''; ExitCode = -1; Error = ''; Packages = @() }
try {
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
    $startInfo.Arguments = 'list --upgrade-available --source winget --accept-source-agreements --disable-interactivity'
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
            $package = [ordered]@{
                Name = $match.Groups['Name'].Value.Trim()
                Id = $match.Groups['Id'].Value
                InstalledVersion = $match.Groups['Installed'].Value
                AvailableVersion = $match.Groups['Available'].Value
                Source = if ($match.Groups['Source'].Success) { $match.Groups['Source'].Value } else { 'winget' }
                Success = $false
                ExitCode = -1
                Output = ''
            }
            $arguments = @(
                'upgrade', '--id', $package.Id, '--exact', '--source', $package.Source,
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
                if (-not $installer.WaitForExit(1800000)) {
                    try { $installer.Kill() } catch { }
                    throw "WinGet-Installation für $($package.Id) überschritt das Zeitlimit von 30 Minuten."
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
                $installUpdatesLiteral = if ($InstallUpdates) { '$true' } else { '$false' }
                $queryScript = $queryScript.Replace('__INSTALL_UPDATES__', $installUpdatesLiteral)
                $encodedQuery = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($queryScript))
                $taskRegistered = $false
                try {
                    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
                    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument "-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedQuery"
                    $principal = New-ScheduledTaskPrincipal -UserId $userSid -LogonType Interactive -RunLevel Limited
                    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
                    $taskRegistered = $true
                    $taskStartedAt = Get-Date
                    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    # Die Aufgabe erhält insgesamt 30 Minuten; auch ein
                    # einzelner langsamer Paketprozess darf bis zu 30 Minuten laufen.
                    $taskTimeoutSeconds = if ($InstallUpdates) { 1800 } else { 300 }
                    $deadline = (Get-Date).AddSeconds($taskTimeoutSeconds)
                    while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf) -and (Get-Date) -lt $deadline) {
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
                    foreach ($row in @(Get-WingetUpgradeLines -Output ([string]$userQuery.Output))) {
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
                            Output = [string]$package.Output
                        }
                    }
                    if ($InstallUpdates) {
                        if (@($userQuery.Packages).Count -eq 0) {
                            $queryOutput = [string]$userQuery.Output
                            if ([string]::IsNullOrWhiteSpace($queryOutput)) { $queryOutput = '<keine Ausgabe>' }
                            $notes += "Benutzerbezogene WinGet-Abfrage als '$userName': Parser erkannte 0 Paketzeilen (Exitcode $($userQuery.ExitCode)); Roh-Ausgabe: $queryOutput"
                        }
                        $notes += "Benutzerbezogene WinGet-Installation als '$userName': $(@($userQuery.Packages | Where-Object Success).Count) erfolgreich, $(@($userQuery.Packages | Where-Object { -not $_.Success }).Count) fehlgeschlagen."
                    } else {
                        $notes += "Benutzerbezogene WinGet-Abfrage als '$userName' erfolgreich."
                    }
                }
                catch {
                    $notes += "Benutzerbezogene WinGet-Abfrage für '$userName' nicht möglich: $($_.Exception.Message)"
                    if ($InstallUpdates) {
                        $packageResults += [pscustomobject]@{
                            Name = 'WinGet-Benutzerupdates'; Id = ''; InstalledVersion = ''
                            AvailableVersion = ''; Source = 'winget'; UserName = $userName
                            Success = $false; ExitCode = 1; Output = [string]$_.Exception.Message
                        }
                    }
                }
                finally {
                    if ($taskRegistered) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
                    Remove-Item -LiteralPath $resultPath -Force -ErrorAction SilentlyContinue
                }
            }
            [pscustomobject]@{ Lines = @($upgradeLines); Notes = @($notes); Packages = @($packageResults) }
        }

        function Invoke-WingetCliPackageUpdate {
            param(
                [Parameter(Mandatory)][string]$Path,
                [Parameter(Mandatory)][string]$Id,
                [Parameter(Mandatory)][string]$Source,
                [Parameter(Mandatory)][string]$Version
            )
            try {
                $arguments = @(
                    'upgrade', '--id', $Id, '--exact', '--source', $Source, '--version', $Version,
                    '--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity'
                )
                $output = (& $Path @arguments 2>&1 | Out-String -Width 1200).Trim()
                $exitCode = $LASTEXITCODE
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
            $knownDefaultSources = @('msstore', 'winget', 'winget-font')
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
            $missingDefaults = @($knownDefaultSources | Where-Object { $_ -notin $sourcesAfterReset })
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
            if ($latestPackage.Count -eq 0) { return [pscustomobject]@{ Version = ''; RegistrationChanged = $false } }

            $targetVersion = [version]$latestPackage[0].Version
            $currentPackage = @($currentPackages | Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
            $currentVersion = if ($currentPackage.Count -gt 0) { [version]$currentPackage[0].Version } else { [version]'0.0' }
            $registrationChanged = $currentVersion -lt $targetVersion
            if ($registrationChanged) {
                $manifestPath = Join-Path ([string]$latestPackage[0].InstallLocation) 'AppxManifest.xml'
                if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
                    throw "App Installer $targetVersion ist vorhanden, aber sein Manifest fehlt: $manifestPath"
                }
                Add-AppxPackage -Path $manifestPath -Register -DisableDevelopmentMode -ErrorAction Stop | Out-Null
            }

            $registeredPackage = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
                Where-Object { [version]$_.Version -ge $targetVersion } |
                Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
            if ($registeredPackage.Count -eq 0 -or [string]$registeredPackage[0].Status -ne 'Ok') {
                throw "App Installer $targetVersion wurde für den aktuellen Benutzer nicht erfolgreich registriert."
            }
            return [pscustomobject]@{ Version = [string]$registeredPackage[0].Version; RegistrationChanged = $registrationChanged }
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
                if ($ExecutionMode -eq 'Install' -and $packages.Count -gt 0) {
                    $upgradeOutput = & $chocoPath upgrade all -y 2>&1 | Out-String
                    $upgradeExitCode = $LASTEXITCODE
                    if (-not [string]::IsNullOrWhiteSpace($upgradeOutput)) {
                        $actionOutput = (@($actionOutput, $upgradeOutput.Trim()) | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) -join "`r`n"
                    }
                    $exitCode = $upgradeExitCode
                }
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
            $wingetPath = Resolve-WingetExecutable
            $wingetBootstrapMessage = ''
            $wingetDiagnosticOutput = ''
            $wingetPreparationSucceeded = $true
            $wingetReconnectRequired = $false
            if ($ExecutionMode -eq 'Check' -and $wingetPath) {
                try {
                    $appInstallerRegistration = Register-LatestWinGetAppInstallerForCurrentUser
                    if ($appInstallerRegistration.RegistrationChanged) {
                        $wingetBootstrapMessage += " App Installer $($appInstallerRegistration.Version) für den aktuellen Benutzer registriert."
                        $wingetPath = Resolve-WingetExecutable
                        $wingetReconnectRequired = $true
                    }
                }
                catch {
                    $registrationError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
                    if ($registrationError.Length -gt 250) { $registrationError = $registrationError.Substring(0, 247) + '...' }
                    $wingetBootstrapMessage += ' App-Installer-Registrierung fehlgeschlagen; Details im Log.'
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
                    if ($sourcePackageRegistration.Changed) {
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
            if ($ExecutionMode -eq 'Check' -and $serverCaption -match 'Windows Server (2019|2022)') {
                $wingetHealth = Test-WingetExecutable -Path $wingetPath
                if (-not $wingetHealth.Works) {
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
                # Ergänze benutzerbezogene Updates angemeldeter interaktiver
                # Benutzer. Beim Installationslauf werden sie in derselben
                # Benutzersitzung aktualisiert, in der der Check sie gefunden hat.
                if ($ExecutionMode -in @('Check', 'Install')) {
                    $interactiveQuery = Get-WingetInteractiveUserUpgradeLines -InstallUpdates:($ExecutionMode -eq 'Install')
                    $interactiveLines = @($interactiveQuery.Lines)
                    if ($ExecutionMode -eq 'Check' -and $interactiveLines.Count -gt 0) {
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
                    if ($ExecutionMode -eq 'Install') {
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
                            $manualText = if ($manualAction) {
                                "Benutzerbezogenes WinGet-Update '$($interactivePackage.Name)' für '$($interactivePackage.UserName)' fehlgeschlagen (Exitcode $($interactivePackage.ExitCode)). $packageOutput"
                            } else { '' }
                            $result += [pscustomobject]@{
                                Manager='Winget'; Available=$true; Success=([bool]$interactivePackage.Success)
                                Skipped=$false; SkipReason=''; ExitCode=[int]$interactivePackage.ExitCode
                                Packages=@($packageRow); AvailableOutput=''; ActionOutput=$packageOutput
                                RequiresManualAction=$manualAction; ManualActionText=$manualText
                                InteractiveUser=[string]$interactivePackage.UserName
                            }
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
                if ($sourceFailureLines.Count -gt 0) {
                    $sourceFailureText = @($sourceFailureLines | ForEach-Object { Get-WingetCompactOutput -Text ([string]$_) }) -join ' '
                    if ($ExecutionMode -eq 'Install' -and $packageLines.Count -gt 0) {
                        $result += [PSCustomObject]@{
                            Manager='Winget'; Available=$true; Success=$true; Skipped=$false; SkipReason=''; ExitCode=0
                            Packages=$packageLines; AvailableOutput=$availableOutput; ActionOutput=''
                            DiagnosticOutput=$wingetDiagnosticOutput
                        }
                    }
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
                                $moduleUpdate = Invoke-WingetCliPackageUpdate -Path $wingetPath -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value
                            } else {
                                $moduleUpdate = Invoke-WingetModulePackageUpdate -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value
                                if (-not $moduleUpdate.Success) {
                                    $moduleFailureOutput = [string]$moduleUpdate.Output
                                    $cliUpdate = Invoke-WingetCliPackageUpdate -Path $wingetPath -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value
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
                                    $retryResult = Invoke-WingetModulePackageUpdate -Id $packageId -Source $packageSource -Version $packageMatch.Groups['AvailableVersion'].Value
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
                }
                catch {
                    $exceptionMessage = [string]$_.Exception.Message
                    $retryFreshConnection = $exceptionMessage -match '(?i)(0x800706ba|-2147023174|Failed to create instance|RPC server is unavailable|RPC-Server nicht verfügbar)'
                    $queryTimedOut = $_.Exception -is [System.TimeoutException] -or
                        $exceptionMessage -match '(?i)(WinGet-Katalogabfrage hat das Zeitlimit|WinGet.*Zeitlimit von 5 Minuten überschritten)'
                    $retryAfterSourceReset = $queryTimedOut -and $ExecutionMode -eq 'Check'
                    $retryFreshConnection = $retryFreshConnection -or ($queryTimedOut -and $ExecutionMode -eq 'Install')
                    $result += [PSCustomObject]@{
                        Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null
                        Packages=@(); AvailableOutput=''; ActionOutput='WinGet-Abfrage fehlgeschlagen; Details im Log.'; DiagnosticOutput=$(if ($wingetDiagnosticOutput) { "$wingetDiagnosticOutput`r`nAbfragefehler:`r`n$($_.Exception.ToString())" } else { $_.Exception.ToString() })
                        RetryFreshConnection=$retryFreshConnection; RetryAfterSourceReset=$retryAfterSourceReset
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
            -ScriptBlock $packageScript -ArgumentList @($Mode, $false, $EnableChocolatey, $false, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ',')) -IsLocalTarget $isLocalTarget `
            -NoTimeout -OperationName "Paketmanager-Prüfung auf $ComputerName")
    }
    else {
        # Chocolatey und WinGet getrennt ausführen. So bleiben Chocolatey-
        # Ergebnisse erhalten, auch wenn WinGet hängen bleibt oder wiederholt wird.
        $baseResults = @(Invoke-WindowsUpdatePackageWorker -ComputerName $ComputerName -AuthInfo $AuthInfo `
            -ScriptBlock $packageScript -ArgumentList @($Mode, $false, $EnableChocolatey, $false, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ',')) -IsLocalTarget $isLocalTarget `
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
                ArgumentList = @($Mode, $true, $false, $false, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $false)
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
                    ArgumentList = @($Mode, $true, $false, $sourceResetPerformed, ($ExcludeWinGetIds -join ','), ($ExcludeChocolateyIds -join ','), $sourcePackageRefreshPerformed)
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
