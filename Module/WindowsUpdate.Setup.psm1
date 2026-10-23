function New-WindowsUpdateAdmDeploymentStatusModuleSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]+(?:\.[0-9]+)*$')]
        [string]$Version
    )

    @"
function Get-WindowsUpdateAdmDeploymentStatus {
    [PSCustomObject]@{ Version = '$Version' }
}
Export-ModuleMember -Function Get-WindowsUpdateAdmDeploymentStatus
"@
}

Export-ModuleMember -Function New-WindowsUpdateAdmDeploymentStatusModuleSource
