# Fachmodul: WindowsUpdate.Paketquellen
# Quellenpflege wird ausschließlich über die eng begrenzte JEA-Funktion ausgeführt.

function Reset-WindowsUpdateRemoteWinGetSources {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [scriptblock]$WriteLog
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    $firstFailure = ''
    for ($attempt = 1; $attempt -le 2; $attempt++) {
        try {
            $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName `
                -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -OpenTimeoutSeconds 30 `
                -OperationTimeoutSeconds ([Math]::Min(14400, [Math]::Max(60, $TimeoutSeconds + 30)))
            $invokeParameters.ScriptBlock = { Invoke-WindowsUpdateAdmWinGetMaintenance -Action SourceReset -ErrorAction Stop }
            $remaining = [int][Math]::Floor(($deadline - [DateTime]::UtcNow).TotalSeconds)
            if ($remaining -lt 1) { throw [TimeoutException]::new('Zeitlimit für den WinGet-Quellenreset erreicht.') }
            $result = @(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $AuthInfo -ConfigurationName 'WindowsUpdateAdm' -ScriptBlock $invokeParameters.ScriptBlock -TimeoutSeconds $remaining -OperationName "WinGet-Quellenreset auf $ComputerName" -WriteLog $WriteLog | Select-Object -Last 1)
            if ($result.Count -eq 0 -or -not [bool]$result[0].Success) {
                $detail = if ($result.Count -gt 0) { [string]$result[0].Output } else { 'keine strukturierte Rückgabe' }
                throw "JEA-Quellenreset lieferte keinen bestätigten Erfolg. $detail"
            }
            $response = [pscustomobject]@{
                Success = $true
                ResetPerformed = $true
                Message = 'WinGet-Quellen wurden über die eingeschränkte JEA-Funktion zurückgesetzt und aktualisiert.'
                ResetOutput = [string]$result[0].Output
                SourceUpdateOutput = ''
                MarkerWarning = ''
            }
            Write-CommonLog $WriteLog "WinGet-Quellenreset auf $ComputerName über JEA erfolgreich: $($response.ResetOutput)"
            if ($attempt -gt 1) { Write-CommonLog $WriteLog "WinGet-Quellenreset auf $ComputerName nach einmaliger Wiederholung erfolgreich; erster Fehler: $firstFailure" }
            return $response
        }
        catch {
            $failure = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
            $transientAppxFailure = $failure -match '(?i)(marked for deletion|zum Löschen markiert|Error trying to initialize the application data container settings server)'
            if (-not $transientAppxFailure -or $attempt -ge 2) {
                if ($attempt -ge 2 -and $transientAppxFailure) {
                    throw "JEA-WinGet-Quellenreset auf $ComputerName schlug nach einmaliger Wiederholung fehl. Erster Fehler: $firstFailure Zweiter Fehler: $failure"
                }
                throw
            }
            $firstFailure = $failure
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'JEA-WinGet-Quellenreset wiederholen' -Target $ComputerName `
                -DiagnosticText $failure -Context @('Transienter AppX-Fehler; Wiederholung=1/1; Wartezeit=10s; frische JEA-Verbindung')
            if (($deadline - [DateTime]::UtcNow).TotalSeconds -le 10) { throw [TimeoutException]::new('Zeitlimit vor Wiederholung des WinGet-Quellenresets erreicht.') }
            Start-Sleep -Seconds 10
        }
    }
}
