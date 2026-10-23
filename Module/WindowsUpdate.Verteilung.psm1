function Get-WindowsUpdateDeploymentBootstrapCredential {
    param([Parameter(Mandatory)][string]$Servername)
    $message = "Einmalige WinRM-Einrichtung für $Servername. Bitte den tatsächlichen lokalen Administratorkontonamen eingeben, z. B. $Servername\Konto oder .\Konto."
    Get-Credential -Message $message
}

function Get-WindowsUpdateDeploymentClientCertificate {
    param(
        [Parameter(Mandatory)][object]$UpdateSettings,
        [string]$ComputerName = $env:COMPUTERNAME
    )

    $configuredThumbprint = if ($UpdateSettings.PSObject.Properties['ClientCertThumbprint']) {
        [string]$UpdateSettings.ClientCertThumbprint
    } else { '' }
    $certificates = @(Get-ChildItem 'Cert:\CurrentUser\My' -ErrorAction SilentlyContinue)
    if (-not [string]::IsNullOrWhiteSpace($configuredThumbprint)) {
        $certificate = $certificates | Where-Object Thumbprint -eq $configuredThumbprint | Select-Object -First 1
    } else {
        $certificate = $certificates |
            Where-Object Subject -eq "CN=WinRM-UpdateClient-$ComputerName" |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
    }
    if ($certificate -and $certificate.NotAfter -gt (Get-Date) -and $certificate.HasPrivateKey) { return $certificate }
    return $null
}

function Test-WindowsUpdateDeploymentConfiguration {
    param(
        [Parameter(Mandatory)][string]$Servername,
        [Parameter(Mandatory)][string]$DeployType,
        [Parameter(Mandatory)][string]$ExpectedDeploymentVersion,
        [Parameter(Mandatory)][object]$UpdateSettings,
        [string]$ManagementComputerName = $env:COMPUTERNAME
    )

    $certificate = $null
    if ($DeployType -ne 'AD') {
        $certificate = Get-WindowsUpdateDeploymentClientCertificate -UpdateSettings $UpdateSettings -ComputerName $ManagementComputerName
        if (-not $certificate) {
            return [PSCustomObject]@{ IsCurrent = $false; Reason = 'Das konfigurierte Clientzertifikat fehlt, ist abgelaufen oder besitzt keinen privaten Schlüssel.'; Version = '' }
        }
    }

    $endpointParameters = @{
        ComputerName = $Servername
        ConfigurationName = 'WindowsUpdateAdm'
        SessionOption = (New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000)
        ErrorAction = 'Stop'
        ScriptBlock = {
            $updateCommand = Get-Command Get-WindowsUpdate -ErrorAction Stop | Select-Object -First 1
            $deploymentStatus = Get-WindowsUpdateAdmDeploymentStatus -ErrorAction Stop
            [PSCustomObject]@{ UpdateCommand = [string]$updateCommand.Name; DeploymentVersion = [string]$deploymentStatus.Version }
        }
    }
    if ($certificate) {
        $endpointParameters.UseSSL = $true
        $endpointParameters.CertificateThumbprint = $certificate.Thumbprint
    }

    try {
        $status = Invoke-Command @endpointParameters
        if ($status.UpdateCommand -ne 'Get-WindowsUpdate') { throw 'Der WindowsUpdateAdm-Endpunkt stellt Get-WindowsUpdate nicht bereit.' }
        if ($status.DeploymentVersion -eq $ExpectedDeploymentVersion) {
            return [PSCustomObject]@{ IsCurrent = $true; Reason = ''; Version = [string]$status.DeploymentVersion }
        }
        $reason = "Konfigurationsversion $($status.DeploymentVersion) gefunden; erwartet wird $ExpectedDeploymentVersion."
    }
    catch { $reason = $_.Exception.Message }

    if ($certificate -and $reason -and $DeployType -ne 'AD') {
        try {
            $legacyStatus = Invoke-Command -ComputerName $Servername -UseSSL `
                -CertificateThumbprint $certificate.Thumbprint `
                -SessionOption (New-PSSessionOption -OpenTimeout 10000 -OperationTimeout 30000) `
                -ErrorAction Stop -ScriptBlock {
                    $build = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber
                    $modulePath = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\JEA_Updates.psm1'
                    $moduleText = if (Test-Path -LiteralPath $modulePath -PathType Leaf) { Get-Content -LiteralPath $modulePath -Raw -ErrorAction Stop } else { '' }
                    $versionMatch = [regex]::Match($moduleText, "function\s+Get-WindowsUpdateAdmDeploymentStatus[\s\S]*?Version\s*=\s*'(?<Version>[^']+)'", [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                    [PSCustomObject]@{
                        Build = $build
                        HasStatusFunction = $versionMatch.Success
                        DeploymentVersion = if ($versionMatch.Success) { [string]$versionMatch.Groups['Version'].Value } else { '' }
                    }
                }
            if ([int]$legacyStatus.Build -le 17763) {
                if ($legacyStatus.HasStatusFunction -and $legacyStatus.DeploymentVersion -eq $ExpectedDeploymentVersion) {
                    return [PSCustomObject]@{ IsCurrent = $true; Reason = ''; Version = [string]$legacyStatus.DeploymentVersion }
                }
                $reason = "Server-Build $($legacyStatus.Build): Modulversion '$($legacyStatus.DeploymentVersion)' gefunden; erwartet wird $ExpectedDeploymentVersion."
            }
        }
        catch { $reason += " Zertifikatsprüfung am normalen WinRM-Endpunkt ebenfalls fehlgeschlagen: $($_.Exception.Message)" }
    }

    [PSCustomObject]@{ IsCurrent = $false; Reason = $reason; Version = '' }
}

Export-ModuleMember -Function Get-WindowsUpdateDeploymentBootstrapCredential, Get-WindowsUpdateDeploymentClientCertificate, Test-WindowsUpdateDeploymentConfiguration
