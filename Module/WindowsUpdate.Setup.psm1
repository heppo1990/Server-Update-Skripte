function New-WindowsUpdateAdmDeploymentStatusModuleSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]+(?:\.[0-9]+)*$')]
        [string]$Version,
        [Parameter(Mandatory)]
        [ValidateRange(0, 100000)]
        [int]$TargetBuild,
        [string[]]$ClientCertificateUris = @('http://schemas.microsoft.com/powershell/WindowsUpdateAdm')
    )

    $uriLiteralList = foreach ($uri in $ClientCertificateUris) {
        "'{0}'" -f ([string]$uri).Replace("'", "''")
    }
    $uriLiterals = @($uriLiteralList) -join ', '
    @"
function Get-WindowsUpdateAdmDeploymentStatus {
    @{ Version = '$Version'; TargetBuild = $TargetBuild; ClientCertificateUris = @($uriLiterals) }
}
Export-ModuleMember -Function Get-WindowsUpdateAdmDeploymentStatus
"@
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
