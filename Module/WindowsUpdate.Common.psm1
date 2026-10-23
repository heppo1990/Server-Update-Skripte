Set-StrictMode -Version Latest

# Konsolenzustand bleibt im gemeinsamen Modulbereich, damit alle Fachmodule
# dieselben Tabellen- und Zusammenfassungszustände verwenden.
$script:WindowsUpdateConsoleTableActive = $false
$script:WindowsUpdateConsoleTableHasRows = $false
$script:WindowsUpdateConsoleSummaryActive = $false
$script:WindowsUpdateConsoleSummaryDividerCount = 0
$script:WindowsUpdateConsolePackageRowsActive = $false
$script:WindowsUpdateConsolePackageTableActive = $false
$script:WindowsUpdateModuleRoot = $PSScriptRoot

$componentModules = @(
    'WindowsUpdate.Console.psm1',
    'WindowsUpdate.NuGet.psm1',
    'WindowsUpdate.ModulPakete.psm1',
    'WindowsUpdate.PSWindowsUpdate.psm1',
    'WindowsUpdate.WinGetClient.psm1',
    'WindowsUpdate.Paketdarstellung.psm1',
    'WindowsUpdate.Einstellungen.psm1',
    'WindowsUpdate.Aufgabenplanung.psm1',
    'WindowsUpdate.Remoting.psm1',
    'WindowsUpdate.Nachinstallation.psm1',
    'WindowsUpdate.Verlauf.psm1',
    'WindowsUpdate.Ziele.psm1',
    'WindowsUpdate.Paketquellen.psm1',
    'WindowsUpdate.Paketverwaltung.psm1',
    'WindowsUpdate.Berichte.psm1',
    'WindowsUpdate.Check.psm1',
    'WindowsUpdate.Download.psm1',
    'WindowsUpdate.Installation.psm1',
    'WindowsUpdate.Verteilung.psm1',
    'WindowsUpdate.Setup.psm1',
    'WindowsUpdate.Clientzertifikat.psm1'
)
foreach ($componentModule in $componentModules) {
    $componentPath = Join-Path $PSScriptRoot $componentModule
    if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
        throw "Fachmodul fehlt: $componentPath"
    }
    # Eine .psm1-Datei direkt mit dem Punktoperator zu laden behandelt
    # PowerShell als Modulimport und isoliert deren Funktionsbereich. Die
    # Fachmodule werden deshalb als Skriptinhalt in diesem Modul ausgeführt,
    # damit Funktionen sich wie im bisherigen gemeinsamen Modul gegenseitig
    # aufrufen können.
    $componentScript = [scriptblock]::Create([IO.File]::ReadAllText($componentPath))
    . $componentScript
}

Export-ModuleMember -Function Get-WindowsUpdateSettings, Set-WindowsUpdateScheduledCheckTask, Protect-WindowsUpdateSettingsFilePassword, Protect-WindowsUpdateSettingsObjectPassword, Get-WindowsUpdateClientCertificateAuthInfo, Get-WindowsUpdateTargets, Get-WindowsUpdateTargetOperatingSystem, New-WindowsUpdateInvokeCommandParams, Test-WindowsUpdateWinRmPorts, Initialize-WindowsUpdateRemoting, Invoke-WindowsUpdateRemoteCommandWithTimeout, Test-WindowsUpdateConsoleMessage, Format-WindowsUpdateConsoleError, Write-WindowsUpdateConsoleLine, Test-WindowsUpdateJeaSupported, Invoke-WindowsUpdateSystemTask, Invoke-WindowsUpdateWithRetry, Get-WindowsUpdateSshArguments, ConvertTo-WindowsUpdatePackageRows, Format-WindowsUpdatePackageConsoleTable, ConvertTo-WindowsUpdatePackageHtmlTable, Invoke-WindowsUpdatePackageManagers, Invoke-WindowsUpdateFileRetention, Write-WindowsUpdateLog, Write-WindowsUpdateConsoleSummary, Invoke-WindowsUpdateRetentionWithLog, ConvertTo-WindowsUpdateMailSafeString, Send-WindowsUpdateHtmlMail, Add-WindowsUpdateTrustedHost, New-WindowsUpdateNuGetProviderPayload, New-WindowsUpdateModulePayload, Update-NuGetProvider, Update-PSWindowsUpdateModule, Update-WinGetClientModule, Register-WindowsUpdateWinGetAppInstallerForCurrentUser, Repair-WindowsUpdateWinGetPackageManager, Write-WindowsUpdateDiagnostic, Get-WindowsUpdateAdmDeploymentVersion, Get-DeferredWindowsUpdates, Remove-DeferredUpdateTask, Register-OneTimeRemoteTask, Register-StartupRemoteTask, Register-DeferredUpdateTask, Register-DeferredMailTestTask, Add-HistoryEvent, ConvertFrom-HistoryDate, Invoke-HistoryRemoteCommand, Get-LinuxHistoryLines, ConvertTo-HtmlSafe, New-WindowsUpdateHistoryHtml, Write-WindowsUpdateSetupLog, Write-WindowsUpdateSetupDiagnostic, Write-WindowsUpdateClientCertificateDiagnostic, New-WindowsUpdateCheckRedistributionNotice, New-WindowsUpdateCheckExternalSetupNotice, Get-WindowsUpdateCheckClientCertificate, Invoke-WindowsUpdateCheckCacheCleanup, Import-WindowsUpdatePSWindowsUpdateModule, ConvertTo-WindowsUpdateDownloadResult, New-WindowsUpdateDownloadReportHeader, Complete-WindowsUpdateDownloadReport, New-WindowsUpdateDownloadConsoleSummary, Get-NextScheduledTime, Get-NextRebootTimeInWindow, Test-ServerIsVirtual, Test-WindowsUpdateRebootRequired, Register-WindowsUpdateRebootTask, Get-WindowsUpdateDeploymentBootstrapCredential, Get-WindowsUpdateDeploymentClientCertificate, Test-WindowsUpdateDeploymentConfiguration, Add-WindowsUpdateTrustedWinRMServerCertificate, Invoke-WindowsUpdateWinRMDeployment, Invoke-WindowsUpdateServerDeployment, New-WindowsUpdateAdmDeploymentStatusModuleSource, New-WindowsUpdateClientCertificate, Export-WindowsUpdateClientCertificatePublicKey
