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

        $stateRoot = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) { $env:ProgramData } else { $env:LOCALAPPDATA }
        $markerWarning = ''
        if ([string]::IsNullOrWhiteSpace($stateRoot)) { $markerWarning = 'Weder ProgramData noch LOCALAPPDATA stehen für den 24-Stunden-Marker zur Verfügung.' }
        if (-not [string]::IsNullOrWhiteSpace($stateRoot)) {
            $stateDirectory = Join-Path $stateRoot 'ServerUpdateSkripte'
            $markerPath = Join-Path $stateDirectory 'WingetAllSourcesResetUtc.txt'
            try {
                if (-not (Test-Path -LiteralPath $stateDirectory -PathType Container)) {
                    New-Item -Path $stateDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
                }
                [IO.File]::WriteAllText($markerPath, [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
            }
            catch { $markerWarning = $_.Exception.ToString() }
        }
        [pscustomobject]@{
            Success = $true
            Message = "WinGet-Standardquellen wurden per CLI zurückgesetzt und 'winget' aktualisiert."
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
