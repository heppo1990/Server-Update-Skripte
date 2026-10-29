# Fachmodul: WindowsUpdate.Paketquellen
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Reset-WindowsUpdateRemoteWinGetSources {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [scriptblock]$WriteLog
    )

    $resetScript = {
        $ErrorActionPreference = 'Stop'
        # winget-font ist eine integrierte, optionale Quelle. Sie darf beim
        # Reset nicht als kundeneigene Quelle gelten und ist danach nicht Pflicht.
        $knownDefaultSources = @('msstore', 'winget', 'winget-font')
        $requiredDefaultSources = @('msstore', 'winget')
        $stateRoots = @($env:LOCALAPPDATA, $env:ProgramData) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
        foreach ($stateRoot in $stateRoots) {
            if ([string]::IsNullOrWhiteSpace([string]$stateRoot)) { continue }
            $stateDirectory = Join-Path ([string]$stateRoot) 'ServerUpdateSkripte'
            $markerPath = Join-Path $stateDirectory 'WingetAllSourcesResetUtc.txt'
            if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                try {
                    $lastResetUtc = [DateTime]::MinValue
                    $markerText = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop
                    if ([DateTime]::TryParse($markerText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$lastResetUtc) -and
                        ([DateTime]::UtcNow - $lastResetUtc.ToUniversalTime()).TotalHours -lt 24) {
                        # Frühere Versionen speicherten den Marker teils nur
                        # unter ProgramData. In den Benutzerordner spiegeln,
                        # damit auch die WinGet-Prüfung im nächsten Schritt den
                        # 24-Stunden-Schutz erkennt.
                        foreach ($syncRoot in $stateRoots) {
                            if ([string]::IsNullOrWhiteSpace([string]$syncRoot)) { continue }
                            try {
                                $syncDirectory = Join-Path ([string]$syncRoot) 'ServerUpdateSkripte'
                                if (-not (Test-Path -LiteralPath $syncDirectory -PathType Container)) {
                                    New-Item -Path $syncDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                                }
                                [IO.File]::WriteAllText((Join-Path $syncDirectory 'WingetAllSourcesResetUtc.txt'), $markerText.Trim(), [Text.UTF8Encoding]::new($false))
                            } catch { }
                        }
                        return [pscustomobject]@{
                            Success = $true
                            ResetPerformed = $false
                            Message = 'Der 24-Stunden-Schutz verhindert einen erneuten WinGet-Quellenreset; Quellenpaketprüfung und Wiederholungsabfrage laufen weiter.'
                            ResetOutput = ''
                            SourceUpdateOutput = ''
                            MarkerWarning = ''
                        }
                    }
                } catch { }
            }
        }

        function Invoke-WinGetCliWithoutWindow {
            param([Parameter(Mandatory)][string]$Executable, [string[]]$Arguments = @())
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
                if (-not $process.Start()) { throw 'WinGet-CLI-Prozess konnte nicht gestartet werden.' }
                $stdoutTask = $process.StandardOutput.ReadToEndAsync()
                $stderrTask = $process.StandardError.ReadToEndAsync()
                if (-not $process.WaitForExit(180000)) {
                    try { $process.Kill() } catch { }
                    throw 'WinGet-CLI-Prozess überschritt das Zeitlimit von 180 Sekunden.'
                }
                $process.WaitForExit()
                $output = @($stdoutTask.GetAwaiter().GetResult(), $stderrTask.GetAwaiter().GetResult()) |
                    Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($output -join [Environment]::NewLine).Trim() }
            }
            finally { $process.Dispose() }
        }

        $appInstaller = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Ok' -and $_.InstallLocation } |
            Sort-Object { [version]$_.Version } -Descending | Select-Object -First 1)
        if ($appInstaller.Count -eq 0) { throw 'Microsoft Desktop App Installer ist für den Remoting-Benutzer nicht registriert.' }
        $wingetPath = Join-Path ([string]$appInstaller[0].InstallLocation) 'winget.exe'
        if (-not (Test-Path -LiteralPath $wingetPath -PathType Leaf)) { throw "winget.exe fehlt im App-Installer-Paketpfad: $wingetPath" }

        $sourceListResult = Invoke-WinGetCliWithoutWindow -Executable $wingetPath -Arguments @('source', 'list', '--disable-interactivity')
        $sourceList = [string]$sourceListResult.Output
        $sourceListExitCode = [int]$sourceListResult.ExitCode
        if ($sourceListExitCode -ne 0 -or [string]::IsNullOrWhiteSpace($sourceList)) {
            throw "WinGet-Quellenliste konnte vor dem Reset nicht zuverlässig gelesen werden (Exitcode $sourceListExitCode): $sourceList"
        }
        $configuredSourceNames = @(
            foreach ($line in ($sourceList -split "`r?`n")) {
                if ($line -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name }
            }
        )
        if ($configuredSourceNames.Count -eq 0) { throw 'WinGet-Quellenliste enthielt keine auswertbaren Quellen; Reset abgebrochen.' }
        $customSources = @($configuredSourceNames | Where-Object { $_ -notin $knownDefaultSources } | Select-Object -Unique)
        if ($customSources.Count -gt 0) {
            throw "Kundeneigene WinGet-Quelle(n) erkannt ($($customSources -join ', ')); Reset wurde ausgelassen, damit diese erhalten bleiben."
        }

        # Immer zuerst das aktuelle, offizielle Quellenpaket online prüfen.
        # WinGet versucht ein veraltetes source.msix sonst selbst aus
        # wsmprovhost heraus zu registrieren und kann dabei mit 0x80070520
        # scheitern. Eine neuere Version wird im Benutzerkontext registriert.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $registeredSource = @(Get-AppxPackage -Name Microsoft.Winget.Source -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending)
        $sourcePackagePath = Join-Path ([IO.Path]::GetTempPath()) ('winget-source-' + [guid]::NewGuid().ToString('N') + '.msix')
        $sourcePackageVersion = [version]'0.0'
        try {
            Invoke-WebRequest -Uri 'https://cdn.winget.microsoft.com/cache/source2.msix' -OutFile $sourcePackagePath -UseBasicParsing -TimeoutSec 180 -ErrorAction Stop
            Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
            $sourceArchive = [System.IO.Compression.ZipFile]::OpenRead($sourcePackagePath)
            try {
                $sourceManifestEntry = $sourceArchive.GetEntry('AppxManifest.xml')
                if (-not $sourceManifestEntry) { throw 'Das online geladene WinGet-Quellenpaket enthält kein AppxManifest.xml.' }
                $sourceManifestReader = [IO.StreamReader]::new($sourceManifestEntry.Open())
                try { [xml]$sourceManifest = $sourceManifestReader.ReadToEnd() }
                finally { $sourceManifestReader.Dispose() }
                $sourcePackageVersion = [version]$sourceManifest.Package.Identity.Version
            }
            finally { $sourceArchive.Dispose() }

            $installedSourceVersion = if ($registeredSource.Count -gt 0) { [version]$registeredSource[0].Version } else { [version]'0.0' }
            if ($installedSourceVersion -lt $sourcePackageVersion) {
                $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
                $userName = [string]$identity.Name
                if ([string]::IsNullOrWhiteSpace($userName) -or $userName -match '^NT AUTHORITY\\SYSTEM$') {
                    throw "Quellenpaket $sourcePackageVersion benötigt ein konkretes Benutzerkonto; erkannt: '$userName'."
                }
                $taskName = 'WindowsUpdateAdm-WinGetSource-' + [guid]::NewGuid().ToString('N')
                $taskRoot = Join-Path ([IO.Path]::GetTempPath()) $taskName
                $taskScriptPath = Join-Path $taskRoot 'register-source.ps1'
                $taskResultPath = Join-Path $taskRoot 'result.json'
                $taskRegistered = $false
                try {
                    New-Item -Path $taskRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                    $quotedPackagePath = "'" + $sourcePackagePath.Replace("'", "''") + "'"
                    $taskScript = @"
`$ErrorActionPreference = 'Stop'
`$response = [ordered]@{ Success = `$false; Error = '' }
try {
    Add-AppxPackage -Path $quotedPackagePath -ErrorAction Stop
    `$response.Success = `$true
} catch { `$response.Error = `$_.Exception.ToString() }
try { [IO.File]::WriteAllText('$($taskResultPath.Replace("'", "''"))', (`$response | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new(`$false)) } catch { exit 2 }
if (-not `$response.Success) { exit 1 }
"@
                    [IO.File]::WriteAllText($taskScriptPath, $taskScript, [Text.UTF8Encoding]::new($false))
                    $powershellPath = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
                    $action = New-ScheduledTaskAction -Execute $powershellPath -Argument ('-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $taskScriptPath)
                    $hasInteractiveSession = $false
                    try {
                        $processes = @(Get-Process -Name explorer -IncludeUserName -ErrorAction Stop)
                        $hasInteractiveSession = @($processes | Where-Object { [string]$_.UserName -ieq $userName }).Count -gt 0
                    } catch { }
                    $logonType = if ($hasInteractiveSession) { 'Interactive' } else { 'S4U' }
                    $principal = New-ScheduledTaskPrincipal -UserId $userName -LogonType $logonType -RunLevel Highest
                    $settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 5) -StartWhenAvailable
                    Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings -Force -ErrorAction Stop | Out-Null
                    $taskRegistered = $true
                    Start-ScheduledTask -TaskName $taskName -ErrorAction Stop
                    $deadline = (Get-Date).AddMinutes(5)
                    while (-not (Test-Path -LiteralPath $taskResultPath -PathType Leaf) -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
                    if (-not (Test-Path -LiteralPath $taskResultPath -PathType Leaf)) {
                        $taskInfo = Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
                        $taskCode = if ($taskInfo) { $taskInfo.LastTaskResult } else { 'unbekannt' }
                        throw "AppX-Registrierungsaufgabe für das WinGet-Quellenpaket lieferte kein Ergebnis; LastTaskResult=$taskCode."
                    }
                    $taskResponse = Get-Content -LiteralPath $taskResultPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if (-not $taskResponse.Success) { throw "AppX-Registrierung des WinGet-Quellenpakets unter '$userName' ($logonType) fehlgeschlagen: $($taskResponse.Error)" }
                }
                finally {
                    if ($taskRegistered) {
                        Stop-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
                        Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
                    }
                    if (Test-Path -LiteralPath $taskRoot -PathType Container) { Remove-Item -LiteralPath $taskRoot -Recurse -Force -ErrorAction SilentlyContinue }
                }
                $registeredSource = @(Get-AppxPackage -Name Microsoft.Winget.Source -ErrorAction Stop |
                    Where-Object { $_.Status -eq 'Ok' } | Sort-Object { [version]$_.Version } -Descending)
                if ($registeredSource.Count -eq 0 -or [version]$registeredSource[0].Version -lt $sourcePackageVersion) {
                    throw "Quellenpaket $sourcePackageVersion wurde nach der Benutzeraufgabe nicht bestätigt."
                }
            }
        }
        finally {
            if (Test-Path -LiteralPath $sourcePackagePath -PathType Leaf) { Remove-Item -LiteralPath $sourcePackagePath -Force -ErrorAction SilentlyContinue }
        }

        $resetResult = Invoke-WinGetCliWithoutWindow -Executable $wingetPath -Arguments @('source', 'reset', '--force', '--disable-interactivity')
        $resetOutput = [string]$resetResult.Output
        $resetExitCode = [int]$resetResult.ExitCode
        if ($resetExitCode -ne 0) { throw "WinGet-CLI-Quellenreset fehlgeschlagen (Exitcode $resetExitCode): $resetOutput" }

        # Den Katalog unmittelbar über dieselbe CLI aktualisieren, die der
        # Benutzer remote erfolgreich getestet hat. Die folgende Paketabfrage
        # läuft anschließend über eine neue WinRM-Verbindung.
        $updateResult = Invoke-WinGetCliWithoutWindow -Executable $wingetPath -Arguments @('source', 'update', '--name', 'winget', '--disable-interactivity')
        $updateOutput = [string]$updateResult.Output
        $updateExitCode = [int]$updateResult.ExitCode
        if ($updateExitCode -ne 0) { throw "WinGet-Quelle 'winget' konnte nach dem Reset nicht aktualisiert werden (Exitcode $updateExitCode): $updateOutput" }
        if ($updateOutput -match '(?im)^\s*(?:Abgebrochen|Cancelled)\s*$|Fehler beim Versuch, die Quelle zu aktualisieren|Failed when attempting to update source') {
            throw "WinGet-Quelle 'winget' meldete trotz Exitcode 0 einen abgebrochenen/fehlgeschlagenen Aktualisierungsvorgang: $updateOutput"
        }

        $sourcesAfterResetResult = Invoke-WinGetCliWithoutWindow -Executable $wingetPath -Arguments @('source', 'list', '--disable-interactivity')
        $sourcesAfterResetOutput = [string]$sourcesAfterResetResult.Output
        $sourcesAfterResetExitCode = [int]$sourcesAfterResetResult.ExitCode
        if ($sourcesAfterResetExitCode -ne 0) { throw "WinGet-Quellenliste konnte nach dem Reset nicht gelesen werden (Exitcode $sourcesAfterResetExitCode): $sourcesAfterResetOutput" }
        $sourcesAfterReset = @(
            foreach ($line in ($sourcesAfterResetOutput -split "`r?`n")) {
                if ($line -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name }
            }
        )
        $missingDefaults = @($requiredDefaultSources | Where-Object { $_ -notin $sourcesAfterReset })
        if ($missingDefaults.Count -gt 0) { throw "WinGet-Standardquelle(n) fehlen nach dem Reset: $($missingDefaults -join ', ')." }

        $wingetDetailsResult = Invoke-WinGetCliWithoutWindow -Executable $wingetPath -Arguments @('source', 'list', '--name', 'winget', '--disable-interactivity')
        $wingetDetailsOutput = [string]$wingetDetailsResult.Output
        if ([int]$wingetDetailsResult.ExitCode -ne 0) { throw "Details der WinGet-Quelle konnten nach dem Reset nicht gelesen werden (Exitcode $($wingetDetailsResult.ExitCode)): $wingetDetailsOutput" }
        $updatedMatch = [regex]::Match($wingetDetailsOutput, '(?im)^\s*(?:Updated|Aktualisiert)\s+(?<Value>.+?)\s*$')
        if (-not $updatedMatch.Success) { throw "WinGet-Quelle 'winget' liefert nach dem Reset keinen prüfbaren Aktualisierungszeitpunkt: $wingetDetailsOutput" }
        $updatedValue = $updatedMatch.Groups['Value'].Value.Trim()
        if ($updatedValue -match '(?i)^(?:never|nie|unknown|unbekannt|not updated|nicht aktualisiert)$') {
            throw "WinGet-Quelle 'winget' wurde nach dem Reset nicht aktualisiert (Aktualisiert=$updatedValue)."
        }

        $markerWarning = ''
        if ($stateRoots.Count -eq 0) { $markerWarning = 'Weder ProgramData noch LOCALAPPDATA stehen für den 24-Stunden-Marker zur Verfügung.' }
        foreach ($stateRoot in $stateRoots) {
            if ([string]::IsNullOrWhiteSpace([string]$stateRoot)) { continue }
            $stateDirectory = Join-Path ([string]$stateRoot) 'ServerUpdateSkripte'
            $markerPath = Join-Path $stateDirectory 'WingetAllSourcesResetUtc.txt'
            try {
                if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
                    New-Item -Path $stateDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                [IO.File]::WriteAllText($markerPath, [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
            }
            catch {
                $markerErrors = @($markerWarning, $_.Exception.ToString()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
                $markerWarning = $markerErrors -join [Environment]::NewLine
            }
        }
        [pscustomobject]@{
            Success = $true
            ResetPerformed = $true
            Message = "WinGet-Quellenpaket $sourcePackageVersion online geprüft; Standardquellen per CLI zurückgesetzt und 'winget' aktualisiert ($updatedValue)."
            ResetOutput = $resetOutput
            SourceUpdateOutput = $updateOutput
            MarkerWarning = $markerWarning
        }
    }

    $firstFailure = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            # Invoke-Command verwendet pro Aufruf eine neue Remoting-Sitzung.
            # AppX kann vorübergehend mit einem zum Löschen markierten Schlüssel
            # scheitern; nur diesen bekannten transienten Fehler einmal erneut versuchen.
            $result = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $AuthInfo `
                -ScriptBlock $resetScript -TimeoutSeconds $TimeoutSeconds -OperationName "Quellenreset auf $ComputerName" -WriteLog $WriteLog)
            if ($result.Count -eq 0 -or -not $result[-1].Success) { throw "Quellenreset auf $ComputerName lieferte keine Erfolgsbestätigung." }
            Write-CommonLog $WriteLog "WinGet-CLI-Quellenreset auf $ComputerName erfolgreich: $([string]$result[-1].Message) Reset-Ausgabe: $([string]$result[-1].ResetOutput) Quellenupdate-Ausgabe: $([string]$result[-1].SourceUpdateOutput)"
            if (-not [string]::IsNullOrWhiteSpace([string]$result[-1].MarkerWarning)) {
                Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'WinGet-Quellenreset-Zeitmarker speichern' -Target $ComputerName -DiagnosticText ([string]$result[-1].MarkerWarning) -Context @('Reset selbst war erfolgreich; die 24-Stunden-Begrenzung kann nicht zuverlässig greifen.')
            }
            if ($attempt -gt 1) { Write-CommonLog $WriteLog "WinGet-Quellenreset auf $ComputerName nach einmaliger Wiederholung erfolgreich; erster Fehler: $firstFailure" }
            return $result[-1]
        }
        catch {
            $resetFailure = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            $transientAppxFailure = $resetFailure -match '(?i)(marked for deletion|zum Löschen markiert|Error trying to initialize the application data container settings server)'
            if (-not $transientAppxFailure) { throw }
            if ($attempt -ge 2) {
                throw "Quellenreset auf $ComputerName schlug nach einmaliger Wiederholung fehl. Erster Fehler: $firstFailure Zweiter Fehler: $resetFailure"
            }

            $firstFailure = $resetFailure
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'WinGet-Quellenreset wiederholen' -Target $ComputerName -DiagnosticText $resetFailure -Context @('Transienter AppX-Fehler; Wiederholung=1/1; Wartezeit=10s; danach frische WinRM-Verbindung')
            Write-CommonLog $WriteLog "WinGet-Quellenreset auf $ComputerName traf auf einen vorübergehenden AppX-Fehler; neuer Versuch in 10 Sekunden über eine frische Verbindung."
            Start-Sleep -Seconds 10
        }
    }

    throw "Quellenreset auf $ComputerName fehlgeschlagen. Erster Fehler: $firstFailure"
}
