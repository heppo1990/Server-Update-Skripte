function New-WindowsUpdateAdmDeploymentStatusModuleSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]+(?:\.[0-9]+)*$')]
        [string]$Version,
        [bool]$WinGetUpdateOnly = $false,
        [bool]$ChocolateyUpdateOnly = $true,
        [bool]$WinGetMaintenanceOnly = $false,
        [bool]$ChocolateyMaintenanceOnly = $true
    )

    $moduleSource = @'
function Get-WindowsUpdateAdmDeploymentStatus {
    [PSCustomObject]@{ Version = '__VERSION__'; MaintenanceRevision = '4'; WinGetUpdateOnly = __WINGET_UPDATE_ONLY__; ChocolateyUpdateOnly = __CHOCO_UPDATE_ONLY__; WinGetMaintenanceOnly = __WINGET_MAINTENANCE_ONLY__; ChocolateyMaintenanceOnly = __CHOCO_MAINTENANCE_ONLY__ }
}
function Update-WindowsUpdateAdmWinGetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$')][string]$Id,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$Source
    )

    # JEA veröffentlicht ausschließlich diesen validierten Paket-Update-Aufruf.
    # Install-, Uninstall- und generische Prozessbefehle sind nicht Teil der Rolle.
    $updates = @(Update-WinGetPackage -Id $Id -Source $Source `
        -MatchOption EqualsCaseInsensitive -Mode Silent -Confirm:$false -ErrorAction Stop)
    if ($updates.Count -eq 0) { throw "WinGet lieferte für '$Id' kein Update-Ergebnis." }
    $last = $updates[-1]
    [PSCustomObject]@{
        Id = $Id
        Status = [string]$last.Status
        InstallerErrorCode = [string]$last.InstallerErrorCode
        ExtendedErrorCode = [string]$last.ExtendedErrorCode
        RebootRequired = [bool]$last.RebootRequired
    }
}
function Update-WindowsUpdateAdmChocolateyPackages {
    [CmdletBinding()]
    param()
    $wrapper = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\Update-ChocolateyPackages.cmd'
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw 'Der feste Chocolatey-Updatewrapper fehlt.' }
    $output = & $wrapper 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [PSCustomObject]@{ ExitCode = [int]$exitCode; Output = [string]$output }
}
function Get-WindowsUpdateAdmChocolateyOutdated {
    [CmdletBinding()]
    param()
    $wrapper = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\List-ChocolateyOutdated.cmd'
    $output = & $wrapper 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [PSCustomObject]@{ Success = ([int]$exitCode -in @(0,2)); ExitCode = [int]$exitCode; Output = [string]$output }
}
function Invoke-WindowsUpdateAdmWinGetMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SourceList','SourceUpdate','SourceReset','ClientRepair')][string]$Action
    )
    $wrapperName = switch ($Action) {
        'SourceList' { 'WindowsUpdateAdm-WinGet-SourceList.cmd' }
        'SourceUpdate' { 'WindowsUpdateAdm-WinGet-SourceUpdate.cmd' }
        'SourceReset' { 'WindowsUpdateAdm-WinGet-SourceReset.cmd' }
        'ClientRepair' { 'WindowsUpdateAdm-WinGet-ClientRepair.cmd' }
    }
    $wrapper = Join-Path $env:ProgramFiles ('WindowsPowerShell\Modules\JEA_Updates\' + $wrapperName)
    $output = & $wrapper 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [PSCustomObject]@{ Action = $Action; Success = ([int]$exitCode -eq 0); ExitCode = [int]$exitCode; Output = [string]$output }
}
Export-ModuleMember -Function Get-WindowsUpdateAdmDeploymentStatus, Update-WindowsUpdateAdmWinGetPackage, Get-WindowsUpdateAdmChocolateyOutdated, Update-WindowsUpdateAdmChocolateyPackages, Invoke-WindowsUpdateAdmWinGetMaintenance
'@
    $moduleSource = $moduleSource.Replace('__VERSION__', $Version).
        Replace('__WINGET_UPDATE_ONLY__', ('$' + $WinGetUpdateOnly.ToString().ToLowerInvariant())).
        Replace('__CHOCO_UPDATE_ONLY__', ('$' + $ChocolateyUpdateOnly.ToString().ToLowerInvariant())).
        Replace('__WINGET_MAINTENANCE_ONLY__', ('$' + $WinGetMaintenanceOnly.ToString().ToLowerInvariant())).
        Replace('__CHOCO_MAINTENANCE_ONLY__', ('$' + $ChocolateyMaintenanceOnly.ToString().ToLowerInvariant()))
    return $moduleSource
}

function Write-WindowsUpdateSetupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','UPDATE')][string]$Level = 'INFO',
        [AllowEmptyString()][string]$LogPath,
        [switch]$LogOnly
    )

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try { Add-Content -LiteralPath $LogPath -Value $entry -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Verbose "Setup-Protokoll konnte nicht geschrieben werden: $($_.Exception.Message)" }
    }
    if ($LogOnly) { return }

    $supportsColor = $false
    try {
        $null = $Host.UI.RawUI.ForegroundColor
        $supportsColor = ($Host.Name -eq 'ConsoleHost') -and (-not [Console]::IsOutputRedirected)
    } catch { }
    if (-not $supportsColor) { Write-Host $entry; return }

    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        'SUCCESS' { 'Green' }
        'UPDATE' { 'Cyan' }
        default { $null }
    }
    if ($color) { Write-Host $entry -ForegroundColor $color } else { Write-Host $entry }
}

function Write-WindowsUpdateSetupDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowEmptyString()][string]$LogPath,
        [string]$TargetComputer = $env:COMPUTERNAME,
        [string[]]$Context = @()
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    $details = [System.Collections.Generic.List[string]]::new()
    $details.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [DIAG] Operation=$Operation")
    $details.Add("[DIAG] Target=$TargetComputer")
    foreach ($item in $Context) { if (-not [string]::IsNullOrWhiteSpace($item)) { $details.Add("[DIAG] Context=$item") } }
    $details.Add("[DIAG] ErrorId=$($ErrorRecord.FullyQualifiedErrorId)")
    $details.Add("[DIAG] Category=$($ErrorRecord.CategoryInfo.Category)")
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        $details.Add("[DIAG] Position=$($ErrorRecord.InvocationInfo.PositionMessage.Trim())")
    }
    if ($ErrorRecord.ScriptStackTrace) { $details.Add("[DIAG] ScriptStackTrace=$($ErrorRecord.ScriptStackTrace)") }
    foreach ($line in ($ErrorRecord.Exception.ToString() -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $details.Add("[DIAG] $($line.TrimEnd())") }
    }
    try { Add-Content -LiteralPath $LogPath -Value $details.ToArray() -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Verbose "Setup-Diagnose konnte nicht geschrieben werden: $($_.Exception.Message)" }
}

Export-ModuleMember -Function New-WindowsUpdateAdmDeploymentStatusModuleSource, Write-WindowsUpdateSetupLog, Write-WindowsUpdateSetupDiagnostic
