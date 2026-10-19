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
    'WindowsUpdate.Remoting.psm1',
    'WindowsUpdate.Ziele.psm1',
    'WindowsUpdate.Paketquellen.psm1',
    'WindowsUpdate.Paketverwaltung.psm1',
    'WindowsUpdate.Berichte.psm1'
)
foreach ($componentModule in $componentModules) {
    $componentPath = Join-Path $PSScriptRoot $componentModule
    if (-not (Test-Path -LiteralPath $componentPath -PathType Leaf)) {
        throw "Fachmodul fehlt: $componentPath"
    }
    . $componentPath
}

Export-ModuleMember -Function Get-WindowsUpdateSettings, Protect-WindowsUpdateSettingsFilePassword, Protect-WindowsUpdateSettingsObjectPassword, Get-WindowsUpdateClientCertificateAuthInfo, Get-WindowsUpdateTargets, Get-WindowsUpdateTargetOperatingSystem, New-WindowsUpdateInvokeCommandParams, Initialize-WindowsUpdateRemoting, Test-WindowsUpdateConsoleMessage, Format-WindowsUpdateConsoleError, Write-WindowsUpdateConsoleLine, Test-WindowsUpdateJeaSupported, Invoke-WindowsUpdateSystemTask, Invoke-WindowsUpdateWithRetry, Get-WindowsUpdateSshArguments, ConvertTo-WindowsUpdatePackageRows, Format-WindowsUpdatePackageConsoleTable, ConvertTo-WindowsUpdatePackageHtmlTable, Invoke-WindowsUpdatePackageManagers, Invoke-WindowsUpdateFileRetention, Write-WindowsUpdateLog, Write-WindowsUpdateConsoleSummary, Invoke-WindowsUpdateRetentionWithLog, ConvertTo-WindowsUpdateMailSafeString, Send-WindowsUpdateHtmlMail, Add-WindowsUpdateTrustedHost, New-WindowsUpdateNuGetProviderPayload, New-WindowsUpdateModulePayload, Update-NuGetProvider, Update-PSWindowsUpdateModule, Update-WinGetClientModule, Register-WindowsUpdateWinGetAppInstallerForCurrentUser, Repair-WindowsUpdateWinGetPackageManager, Write-WindowsUpdateDiagnostic, Get-WindowsUpdateAdmDeploymentVersion
