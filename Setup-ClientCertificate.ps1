#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Setup-ClientCertificate.ps1
    Erstellt ein Client-Zertifikat für passwortlose WinRM-Authentifizierung
    auf Nicht-AD-Geräten (AdditionalComputers, HypervisorComputers)

.DESCRIPTION
    - Erstellt ein selbstsigniertes Client-Zertifikat im Zertifikatsstore
    - Exportiert den öffentlichen Schlüssel als .cer Datei
    - Der öffentliche Schlüssel muss auf die Zielgeräte verteilt werden
      (passiert automatisch durch New-WindowsUpdateAdmConfig.ps1 / Verteilung)

.EXAMPLE
    # Standardaufruf - erstellt Zertifikat mit 10 Jahren Gültigkeit
    .\Setup-ClientCertificate.ps1

.EXAMPLE
    # Mit eigenem Anzeigenamen
    .\Setup-ClientCertificate.ps1 -CertName "WinRM-Updates-MeinServer"

.NOTES
    Das Zertifikat wird in Cert:\CurrentUser\My gespeichert.
    Der exportierte Public Key (.cer) wird im Skriptordner abgelegt.
    Thumbprint wird in vorhandene Laufzeit-Konfigurationen automatisch eingetragen.
    Lesen der Einstellungen erfolgt wie bei Check/Install über
    default_settings.json, settings.json und eine optionale skriptspezifische JSON.
#>

param(
    [Parameter(Mandatory=$false)]
    [string]$CertName = "WinRM-UpdateClient-$env:COMPUTERNAME",

    [Parameter(Mandatory=$false)]
    [int]$ValidYears = 10,

    # Für automatischen Aufruf durch die Verteilung: vorhandenes Zertifikat
    # ohne Rückfrage weiterverwenden und die Konfigurationen synchronisieren.
    [Parameter(Mandatory=$false)]
    [switch]$NonInteractive
)

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

Write-Host "`n=== Client-Zertifikat Setup für WinRM ===" -ForegroundColor Cyan
Write-Host "Verwaltungsserver: $env:COMPUTERNAME" -ForegroundColor Gray

$ScriptName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)
$Settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $ScriptName -WriteLog {
    param($message)
    Write-Host $message -ForegroundColor Gray
}
$currentThumbprint = [string]$Settings.UpdateSettings.ClientCertThumbprint
if ([string]::IsNullOrWhiteSpace($currentThumbprint)) {
    Write-Host "Aktuell kein ClientCertThumbprint in der zusammengeführten Konfiguration." -ForegroundColor Gray
} else {
    Write-Host "Aktueller ClientCertThumbprint aus der Konfiguration: $currentThumbprint" -ForegroundColor Gray
}

$certStorePath = "Cert:\CurrentUser\My"
$exportPath    = Join-Path $PSScriptRoot "WinRM-ClientCert.cer"
$certUpn       = "$CertName@localhost"
$settingsFiles = @()
$genericSettings = Join-Path $PSScriptRoot 'settings.json'
if (Test-Path $genericSettings) {
    $settingsFiles += $genericSettings
}

# Alle vorhandenen skriptspezifischen Laufzeit-Konfigurationen ergänzen.
# Vorlagen und bewusst angelegte Kopien sind nicht aktiv und bleiben unverändert.
$settingsFiles += Get-ChildItem -Path $PSScriptRoot -File -Filter '*.settings.json' |
    Where-Object { $_.Name -notmatch ' - Kopie\.json$' } |
    Select-Object -ExpandProperty FullName
$settingsFiles = @($settingsFiles | Select-Object -Unique)

# Prüfen ob bereits ein gültiges Zertifikat mit diesem Namen existiert
$existingCert = Get-ChildItem $certStorePath |
    Where-Object { $_.Subject -eq "CN=$CertName" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
    Sort-Object NotAfter -Descending |
    Select-Object -First 1

# WinRM verlangt für Benutzerzertifikate einen UPN im Subject Alternative
# Name. Ältere Versionen dieses Skripts haben nur einen CN erstellt und sind
# daher nicht für CertificateThumbprint-Authentifizierung verwendbar.
if ($existingCert) {
    $hasUpnSan = $existingCert.Extensions |
        Where-Object { $_.Oid.Value -eq '2.5.29.17' } |
        Where-Object { $_.Format($false) -match [regex]::Escape($certUpn) }
    if (-not $hasUpnSan) {
        Write-Host "Vorhandenes Zertifikat hat keinen WinRM-kompatiblen UPN-SAN und wird erneuert." -ForegroundColor Yellow
        $existingCert = $null
    }
}

if ($existingCert) {
    Write-Host "`nVorhandenes Zertifikat gefunden:" -ForegroundColor Yellow
    Write-Host "  Subject:    $($existingCert.Subject)" -ForegroundColor White
    Write-Host "  Thumbprint: $($existingCert.Thumbprint)" -ForegroundColor White
    Write-Host "  Gültig bis: $($existingCert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor White

    $choice = if ($NonInteractive) { 'n' } else { Read-Host "`nNeues Zertifikat erstellen? (j/N)" }
    if ($choice -notmatch '^[jJ]$') {
        Write-Host "Verwende vorhandenes Zertifikat." -ForegroundColor Green
        $cert = $existingCert
    } else {
        $existingCert = $null
    }
}

if (-not $existingCert) {
    Write-Host "`nErstelle Client-Zertifikat '$CertName'..." -ForegroundColor Cyan
    try {
        $cert = New-SelfSignedCertificate `
            -Subject        "CN=$CertName" `
            -CertStoreLocation $certStorePath `
            -KeyUsage       DigitalSignature, KeyEncipherment `
            -KeyAlgorithm   RSA `
            -KeyLength      4096 `
            -HashAlgorithm  SHA256 `
            -NotAfter       (Get-Date).AddYears($ValidYears) `
            -TextExtension  @(
                "2.5.29.37={text}1.3.6.1.5.5.7.3.2",
                "2.5.29.17={text}upn=$certUpn"
            ) `
            -ErrorAction    Stop

        Write-Host "Zertifikat erstellt:" -ForegroundColor Green
        Write-Host "  Thumbprint: $($cert.Thumbprint)" -ForegroundColor White
        Write-Host "  Gültig bis: $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor White
    }
    catch {
        Write-Host "FEHLER beim Erstellen des Zertifikats: $($_.Exception.Message)" -ForegroundColor Red
        exit 1
    }
}

# Public Key exportieren
Write-Host "`nExportiere Public Key nach: $exportPath" -ForegroundColor Cyan
try {
    $certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
    [System.IO.File]::WriteAllBytes($exportPath, $certBytes)
    Write-Host "Public Key exportiert." -ForegroundColor Green
}
catch {
    Write-Host "FEHLER beim Exportieren: $($_.Exception.Message)" -ForegroundColor Red
    exit 1
}

# Thumbprint in settings.json und alle vorhandenen skriptspezifischen
# Laufzeit-Konfigurationen eintragen. default_settings.json bleibt unverändert.
if ($settingsFiles.Count -gt 0) {
    foreach ($settingsFile in $settingsFiles) {
        try {
            $settings = Get-Content $settingsFile -Raw -Encoding UTF8 | ConvertFrom-Json
            if (-not $settings.UpdateSettings.PSObject.Properties['ClientCertThumbprint']) {
                $settings.UpdateSettings | Add-Member -NotePropertyName 'ClientCertThumbprint' -NotePropertyValue $cert.Thumbprint -Force
            } else {
                $settings.UpdateSettings.ClientCertThumbprint = $cert.Thumbprint
            }

            $json = $settings | ConvertTo-Json -Depth 10
            [System.IO.File]::WriteAllText($settingsFile, $json, [System.Text.UTF8Encoding]::new($true))
            Write-Host "Thumbprint eingetragen: $settingsFile" -ForegroundColor Green
        }
        catch {
            Write-Host "WARNUNG: Konfiguration konnte nicht aktualisiert werden ($settingsFile): $($_.Exception.Message)" -ForegroundColor Yellow
        }
    }
} else {
    Write-Host "`nHinweis: Keine Laufzeit-Konfiguration gefunden." -ForegroundColor Yellow
    Write-Host "Bitte manuell eintragen: `"ClientCertThumbprint`": `"$($cert.Thumbprint)`"" -ForegroundColor White
}

Write-Host "`n=== Zusammenfassung ===" -ForegroundColor Cyan
Write-Host "Thumbprint:  $($cert.Thumbprint)" -ForegroundColor White
Write-Host "Public Key:  $exportPath" -ForegroundColor White
Write-Host ""
Write-Host "Nächster Schritt:" -ForegroundColor Cyan
Write-Host "New-WindowsUpdateAdmConfig.ps1 ausführen (verteilt den Public Key automatisch)" -ForegroundColor Gray
