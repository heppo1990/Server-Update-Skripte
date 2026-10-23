function New-WindowsUpdateClientCertificate {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$StorePath,
        [Parameter(Mandatory)][string]$UserPrincipalName,
        [ValidateRange(1, 30)][int]$ValidYears = 10
    )

    New-SelfSignedCertificate `
        -Subject $Subject `
        -CertStoreLocation $StorePath `
        -KeyUsage DigitalSignature, KeyEncipherment `
        -KeyAlgorithm RSA `
        -KeyLength 4096 `
        -HashAlgorithm SHA256 `
        -NotAfter (Get-Date).AddYears($ValidYears) `
        -TextExtension @(
            '2.5.29.37={text}1.3.6.1.5.5.7.3.2',
            "2.5.29.17={text}upn=$UserPrincipalName"
        ) `
        -ErrorAction Stop
}

function Export-WindowsUpdateClientCertificatePublicKey {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Security.Cryptography.X509Certificates.X509Certificate2]$Certificate,
        [Parameter(Mandatory)][string]$Path,
        [string]$LegacyPath
    )

    $directory = Split-Path -Parent $Path
    if (-not (Test-Path -LiteralPath $directory -PathType Container)) {
        New-Item -Path $directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    }
    $bytes = $Certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($Path, $bytes)
    if (-not [string]::IsNullOrWhiteSpace($LegacyPath) -and
        (Test-Path -LiteralPath $LegacyPath -PathType Leaf)) {
        Remove-Item -LiteralPath $LegacyPath -Force -ErrorAction Stop
    }
    Get-Item -LiteralPath $Path -ErrorAction Stop
}

function Write-WindowsUpdateClientCertificateDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$LogPath,
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowEmptyString()][string]$Context
    )

    try {
        $logDirectory = Split-Path -Parent $LogPath
        if (-not (Test-Path -LiteralPath $logDirectory -PathType Container)) {
            New-Item -Path $logDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $details = @(
            "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [ERROR] $Operation"
            "Benutzer: $([Security.Principal.WindowsIdentity]::GetCurrent().Name)"
            "Kontext: $Context"
            "ErrorId: $($ErrorRecord.FullyQualifiedErrorId)"
            "Kategorie: $($ErrorRecord.CategoryInfo)"
            "Aufrufstelle: $($ErrorRecord.InvocationInfo.PositionMessage)"
            "Stacktrace: $($ErrorRecord.ScriptStackTrace)"
            "Ausnahme: $($ErrorRecord.Exception.ToString())"
            ''
        ) -join [Environment]::NewLine
        Add-Content -LiteralPath $LogPath -Value $details -Encoding UTF8 -ErrorAction Stop
    }
    catch { Write-Verbose "Diagnose konnte nicht protokolliert werden: $($_.Exception.Message)" }
}

Export-ModuleMember -Function New-WindowsUpdateClientCertificate, Export-WindowsUpdateClientCertificatePublicKey, Write-WindowsUpdateClientCertificateDiagnostic
