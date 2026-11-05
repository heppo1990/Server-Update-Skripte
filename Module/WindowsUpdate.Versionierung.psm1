function Get-WindowsUpdateAdmDeploymentVersion {
    '5.1.0'
}

function Get-WindowsUpdateScriptsVersion {
    '5.1.29'
}

function Test-WindowsUpdateAdmVersion {
    param([string]$Actual, [string]$Expected)
    if ($Actual -notmatch '^\d+(?:\.\d+){0,2}$' -or $Expected -notmatch '^\d+(?:\.\d+){0,2}$') { return $false }
    $actualParts = @($Actual -split '\.') + @('0','0','0')
    $expectedParts = @($Expected -split '\.') + @('0','0','0')
    return ([version]($actualParts[0..2] -join '.')) -eq ([version]($expectedParts[0..2] -join '.'))
}
function Test-WindowsUpdateDeploymentRequirement {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable]$InvokeParameters)
    $expected = Get-WindowsUpdateAdmDeploymentVersion
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        return [pscustomobject]@{ RequiresDeployment=$false; Skipped=$true; Version=''; ExpectedVersion=$expected; Reason='SYSTEM-Abfragerolle veröffentlicht keine Bereitstellungskennung.' }
    }
    $parameters = @{}
    foreach ($key in $InvokeParameters.Keys) { $parameters[$key] = $InvokeParameters[$key] }
    $parameters.ConfigurationName = 'WindowsUpdateAdm'
    $parameters.ScriptBlock = { Get-WindowsUpdateAdmDeploymentStatus -ErrorAction Stop }
    [void]$parameters.Remove('ArgumentList')
    $parameters.ErrorAction = 'Stop'
    $actual = ''
    try {
        $status = Invoke-Command @parameters
        $actual = [string]$status.Version
    } catch {
        # Alte Zertifikatsziele unterstützen den JEA-Aufruf teils nicht.
        # Nur den festen Statusquelltext lesen; keine Datei ausführen.
        try {
            [void]$parameters.Remove('ConfigurationName')
            $parameters.ScriptBlock = {
                $path = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\JEA_Updates.psm1'
                $text = [IO.File]::ReadAllText($path)
                $match = [regex]::Match($text, "function\s+Get-WindowsUpdateAdmDeploymentStatus[\s\S]*?Version\s*=\s*'(?<Version>[^']+)'")
                if (-not $match.Success) { throw 'Bereitstellungskennung fehlt im Statusmodul.' }
                $match.Groups['Version'].Value
            }
            $actual = [string](Invoke-Command @parameters)
        } catch {
            return [pscustomobject]@{ RequiresDeployment=$true; Skipped=$false; Version=''; ExpectedVersion=$expected; Reason=('Bereitstellungsstatus nicht lesbar: ' + $_.Exception.Message) }
        }
    }
    $current = Test-WindowsUpdateAdmVersion -Actual $actual -Expected $expected
    $reason = if ($current) { '' } else { "WindowsUpdateAdm-Version '$actual' weicht vom erforderlichen Stand '$expected' ab; Verteilung ausführen." }
    [pscustomobject]@{ RequiresDeployment=(-not $current); Skipped=$false; Version=$actual; ExpectedVersion=$expected; Reason=$reason }
}
function New-WindowsUpdateDeploymentNotice {
    param([string[]]$Targets, [Parameter(Mandatory)][string]$ScriptRoot, [Parameter(Mandatory)][string]$ManagementServer)
    $path = Join-Path $ScriptRoot 'Verteilung_WindowsUpdateAdmConfig.ps1'
    $command = "& '" + $path.Replace("'", "''") + "'"
    $text = "Neue WindowsUpdateAdm-Verteilung nötig für: $($Targets -join ', '). Auf $ManagementServer in PowerShell ausführen: $command"
    [pscustomobject]@{
        Text = $text
        Html = "<div class='warning-box'><strong>Neue WindowsUpdateAdm-Verteilung nötig</strong><br>Betroffene Ziele: $([Net.WebUtility]::HtmlEncode(($Targets -join ', ')))<br>Auf $([Net.WebUtility]::HtmlEncode($ManagementServer)) in PowerShell ausführen:<br><code>$([Net.WebUtility]::HtmlEncode($command))</code></div>"
    }
}
