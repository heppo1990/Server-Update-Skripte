function New-WindowsUpdateCheckRedistributionNotice {
    param(
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Reason
    )

    [pscustomobject]@{
        Area = 'WindowsUpdateAdm'
        Target = $Target
        Reason = $Reason
        NextStep = 'WindowsUpdateAdm-Verteilung und WinRM-Verbindung prüfen; bei fehlendem oder veraltetem JEA-Endpunkt Verteilung erneut ausführen.'
    }
}

function New-WindowsUpdateCheckExternalSetupNotice {
    param(
        [Parameter(Mandatory)][string]$Area,
        [Parameter(Mandatory)][string]$Target,
        [Parameter(Mandatory)][string]$Reason
    )

    $nextStep = if ($Reason -match 'Verbindung nicht bestätigt') {
        'Zuerst Erreichbarkeit und SSH prüfen; Verteilung nur bei fehlender oder ungültiger Einrichtung erneut ausführen.'
    } elseif ($Area -eq 'Linux') {
        'Bei fehlendem/veraltetem SSH-Schlüssel oder sudo-Setup die Linux-Verteilung erneut ausführen.'
    } else {
        'Bei fehlendem SSH-Schlüssel die Home-Assistant-Verteilung erneut ausführen.'
    }

    [pscustomobject]@{ Area = $Area; Target = $Target; Reason = $Reason; NextStep = $nextStep }
}

function Get-WindowsUpdateCheckClientCertificate {
    param(
        [AllowEmptyString()][string]$Thumbprint,
        [Parameter(Mandatory)][string]$ComputerName,
        [string]$StorePath = 'Cert:\CurrentUser\My'
    )

    $certificates = @(Get-ChildItem -Path $StorePath -ErrorAction Stop)
    if (-not [string]::IsNullOrWhiteSpace($Thumbprint)) {
        return $certificates | Where-Object Thumbprint -eq $Thumbprint | Select-Object -First 1
    }

    $certificates |
        Where-Object Subject -eq "CN=WinRM-UpdateClient-$ComputerName" |
        Sort-Object NotAfter -Descending |
        Select-Object -First 1
}


Export-ModuleMember -Function New-WindowsUpdateCheckRedistributionNotice, New-WindowsUpdateCheckExternalSetupNotice, Get-WindowsUpdateCheckClientCertificate

