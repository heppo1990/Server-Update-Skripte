#Requires -RunAsAdministrator

<#
.SYNOPSIS
    New-WindowsUpdateAdmConfig.ps1
    Richtet WindowsUpdateAdm mit minimalen Berechtigungen ein (Role Capability)
    
.DESCRIPTION
    - Prüft und installiert/aktualisiert NuGet Provider auf neueste Version
    - Prüft und installiert/aktualisiert PSWindowsUpdate auf neueste Version
    - Erstellt stabiles JEA-Trägermodul (JEA_Updates) für Role Capabilities
    - Erstellt Role Capability Datei mit nur benötigten Cmdlets
    - SessionType Default und ConstrainedLanguage mit eng begrenzten Role Capabilities
    - Clientzertifikate werden auf die erforderlichen PowerShell-Endpunkt-URIs begrenzt
    - Sprachunabhängige SID-Auflösung für Administratoren (S-1-5-32-544)
    - Permanente Speicherung der Konfigurationsdateien
    - Finaler Verbindungstest zur Verifikation
    - Wird via Verteilung_WindowsUpdateAdmConfig.ps1 per WinRM verteilt
    - Verknüpft auf Nicht-AD-Geräten das Client-Zertifikat mit dem vorhandenen lokalen Administrator
    
.PARAMETER ForceUpdate
    Erzwingt Update auch wenn bereits installiert

.NOTES
    FileName: New-WindowsUpdateAdmConfig.ps1
    Author: IT-Administration
    Requires: Administrator-Rechte
    Distribution: Via Verteilung_WindowsUpdateAdmConfig.ps1 per WinRM
    Version: 5.0 - Zertifikat-Authentifizierung für Nicht-AD-Geräte

.EXAMPLE
    # Standardaufruf auf AD-Server (kein Passwort nötig)
    .\New-WindowsUpdateAdmConfig.ps1

.EXAMPLE
    # Erzwinge Neuinstallation/Update auch wenn bereits konfiguriert
    .\New-WindowsUpdateAdmConfig.ps1 -ForceUpdate

#>

param(
    [Parameter(Mandatory=$false)]
    [switch]$ForceUpdate,

    # Bestehendes lokales Administratorkonto, das bei der einmaligen
    # Einrichtung direkt mit dem Client-Zertifikat verknüpft wird.
    [Parameter(Mandatory=$false)]
    $CertificateMappingCredential = $null,

    # Die zentrale Verteilung setzt diesen Schalter bei einer bereits
    # erfolgreich aufgebauten Client-Zertifikatsverbindung. Das bestehende
    # Mapping ist dann nachweislich funktionsfähig und wird nicht ohne
    # Einrichtungsdaten neu angelegt.
    [Parameter(Mandatory=$false)]
    [switch]$PreserveExistingCertificateMapping,

    # Wird ausschließlich durch die zentrale Verteilung in einem lokalen
    # Folgeprozess aufgerufen. So darf die JEA-Registrierung WinRM neu starten,
    # ohne die ursprüngliche Einrichtungs-Remotesitzung abzubrechen.
    [Parameter(Mandatory=$false)]
    [switch]$FinalizeJEA,

    # Interne Übergabe: Der SYSTEM-Finalisierungslauf schreibt in dasselbe
    # Protokoll wie das vorausgehende Remote-Setup.
    [Parameter(Mandatory=$false)]
    [string]$ResumeLogPath,

    # Wird von der zentralen Verteilung gesetzt, wenn WinGet-Updates aktiviert sind.
    [Parameter(Mandatory=$false)]
    [switch]$InstallWinGetClientModule,

    # Temporärer Stammordner mit auf dem Verwaltungsserver bereitgestellten
    # Offline-Modulpaketen (Modulname\Version). Wird nach dem Setup entfernt.
    [Parameter(Mandatory=$false)]
    [string]$OfflineModuleRoot,

    # Interne Übergabe der Verteilung: Versionsprüfung auf diesem Ziel war
    # erfolgreich und alle benötigten Module/Provider sind bereits aktuell.
    [Parameter(Mandatory=$false)]
    [switch]$ModulesVerifiedCurrent,

    # Computerkonto des Verwaltungsservers. Dieses erhält ausschließlich die
    # eingeschränkte JEA-Rolle für Update-Abfragen aus einem SYSTEM-Aufgabenlauf.
    [Parameter(Mandatory=$false)]
    [string]$ManagementComputerAccount,

    # SID des Verwaltungsserver-Computerkontos, zentral aus AD ermittelt.
    # Wird für die JEA-Endpunkt-ACL direkt als SID verwendet, damit das Ziel
    # das Konto bei der Registrierung nicht per NTAccount auflösen muss.
    [Parameter(Mandatory=$false)]
    [string]$ManagementComputerSid,

    # SID des lokalen Kontos, auf das das Clientzertifikat gemappt wird.
    # Wird an die SYSTEM-Finalisierung übergeben, damit die Endpunkt-ACL den
    # Zertifikatsbenutzer gezielt und unabhängig von Remote-UAC autorisiert.
    [Parameter(Mandatory=$false)]
    [string]$CertificateMappingSid,

    # Principalname des zertifikatsgemappten Kontos für die JEA-Rollenzuordnung.
    [Parameter(Mandatory=$false)]
    [string]$CertificateMappedPrincipal,

    # Für Ziele außerhalb der Verwaltungs-AD wird Zertifikats-Remoting auch
    # dann benötigt, wenn das Gerät Mitglied einer anderen AD-Domäne ist.
    [Parameter(Mandatory=$false)]
    [switch]$EnableClientCertificateRemoting,

    # Nur beim Bootstrap ohne bereits funktionierende Zertifikatsverbindung:
    # Remote-UAC während der Einrichtung temporär öffnen und in jedem
    # Abschluss-/Fehlerpfad wieder schließen.
    [Parameter(Mandatory=$false)]
    [switch]$TemporaryLocalAccountBootstrap,

    # Interne Übergabe der zentral ermittelten WindowsUpdateAdm-Version.
    # Die Verteilung und das Setup protokollieren und registrieren denselben Wert.
    [Parameter(Mandatory=$false)]
    [string]$DeploymentVersion,

    # Ausschließlich erlaubte Verwaltungsserver-Adressen für WinRM HTTPS.
    # Die Verteilung übergibt die expliziten Settings oder ermittelt sie zentral.
    [Parameter(Mandatory=$false)]
    [string[]]$WinRMFirewallRemoteAddresses = @()
)
# Dieses Setup wird auf Zielservern nur vorübergehend in %TEMP% ausgeführt.
# Es lädt dort keine weiteren Repository-Skripte aus GitHub nach.
Set-StrictMode -Version Latest
$commonModulePath = Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1'
if (-not (Test-Path -LiteralPath $commonModulePath -PathType Leaf)) {
    $commonModulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Module\WindowsUpdate.Common.psm1'
}
Import-Module $commonModulePath -Force -ErrorAction Stop

# === TLS-KONFIGURATION GANZ AM ANFANG ===
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Zertifikatsvalidierung temporär speichern (für Retry-Logik)
$OriginalCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback
$script:SetupLogPath = $null
$script:SetupSucceeded = $false
$script:CertificateBootstrapHandoff = $false
try {
    $setupLogDirectory = Join-Path $env:ProgramData 'WindowsUpdateAdm\Logs'
    New-Item -Path $setupLogDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
    $resumeLogIsValid = $false
    if ($FinalizeJEA -and -not [string]::IsNullOrWhiteSpace($ResumeLogPath)) {
        try {
            $expectedLogDirectory = [IO.Path]::GetFullPath($setupLogDirectory).TrimEnd('\')
            $candidateLogPath = [IO.Path]::GetFullPath($ResumeLogPath)
            $candidateDirectory = [IO.Path]::GetDirectoryName($candidateLogPath).TrimEnd('\')
            $candidateNamePattern = '^{0}_\d{{8}}_\d{{6}}\.log$' -f [regex]::Escape("Setup_$env:COMPUTERNAME")
            $resumeLogIsValid =
                $candidateDirectory -ieq $expectedLogDirectory -and
                [IO.Path]::GetFileName($candidateLogPath) -match $candidateNamePattern -and
                (Test-Path -LiteralPath $candidateLogPath -PathType Leaf)
            if ($resumeLogIsValid) { $script:SetupLogPath = $candidateLogPath }
        }
        catch {
            $resumeLogIsValid = $false
        }
    }
    if (-not $resumeLogIsValid) {
        $script:SetupLogPath = Join-Path $setupLogDirectory ('Setup_{0}_{1}.log' -f $env:COMPUTERNAME, (Get-Date -Format 'yyyyMMdd_HHmmss'))
    }
    if (-not $FinalizeJEA) {
        $retention = Invoke-WindowsUpdateFileRetention -Directory $setupLogDirectory -Filter ("Setup_{0}_*.log" -f $env:COMPUTERNAME) -KeepFiles 9
        if (@($retention.FailedFiles).Count -gt 0) { Write-Verbose 'Ältere Setup-Protokolle konnten nicht vollständig bereinigt werden.' }
    }
}
catch {
    Write-Verbose "Setup-Protokoll konnte nicht vorbereitet werden: $($_.Exception.Message)"
}

# Logging-Funktion (farbneutral für Remote-Ausführung)
function Write-SetupLog {
    param([string]$Message, [string]$Level = "INFO", [switch]$LogOnly)
    Write-WindowsUpdateSetupLog -Message $Message -Level $Level -LogPath $script:SetupLogPath -LogOnly:$LogOnly
}

function Write-SetupDiagnostic {
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [string[]]$Context = @()
    )

    Write-WindowsUpdateSetupDiagnostic -Operation $Operation -ErrorRecord $ErrorRecord -LogPath $script:SetupLogPath -TargetComputer $env:COMPUTERNAME -Context $Context
}

function Set-WindowsUpdateLocalAccountTokenFilterPolicy {
    param(
        [Parameter(Mandatory)][ValidateSet(0, 1)][int]$Value,
        [Parameter(Mandatory)][string]$Reason
    )

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    New-Item -Path $regPath -Force -ErrorAction Stop | Out-Null
    New-ItemProperty -LiteralPath $regPath -Name LocalAccountTokenFilterPolicy -Value $Value `
        -PropertyType DWord -Force -ErrorAction Stop | Out-Null
    Write-SetupLog "LocalAccountTokenFilterPolicy=$Value ($Reason)." 'SUCCESS'
}

function Clear-WindowsUpdateLocalAccountTokenFilterPolicy {
    param([Parameter(Mandatory)][string]$Reason)

    $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
    $current = Get-ItemProperty -LiteralPath $regPath -Name LocalAccountTokenFilterPolicy -ErrorAction SilentlyContinue
    if ($null -ne $current) {
        Remove-ItemProperty -LiteralPath $regPath -Name LocalAccountTokenFilterPolicy -ErrorAction Stop
    }
    Write-SetupLog "LocalAccountTokenFilterPolicy entfernt ($Reason); Windows-Standard (0) gilt." 'SUCCESS'
}

try {
    $targetBuild = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber
    $script:ClientCertificateEndpointUris = @('http://schemas.microsoft.com/powershell/WindowsUpdateAdm')
    if ($EnableClientCertificateRemoting -and $targetBuild -le 17763) {
        # Server 2016/2019 führt die vorhandene kurzlebige SYSTEM-Aufgabe über
        # den Microsoft.PowerShell-Endpunkt aus. Genau dieser zweite URI bleibt
        # als Kompatibilitätsausnahme zugelassen; andere PowerShell-Endpunkte
        # sowie Wildcard-URIs bleiben ausgeschlossen.
        $script:ClientCertificateEndpointUris += 'http://schemas.microsoft.com/powershell/Microsoft.PowerShell'
    }
    $script:CertificateMappedPrincipal = $CertificateMappedPrincipal
    $script:CertificateMappingSid = $CertificateMappingSid
    Write-SetupLog "=== Start WindowsUpdateAdm Configuration Setup ===" "INFO"
    if ($script:SetupLogPath) { Write-SetupLog "Protokoll: $script:SetupLogPath" "INFO" }
    Write-SetupLog "Computer: $env:COMPUTERNAME" "INFO"
    Write-SetupLog "PowerShell Version: $($PSVersionTable.PSVersion)" "INFO"
    Write-SetupLog "TLS-Protokolle: $([Net.ServicePointManager]::SecurityProtocol)" "INFO"
    $offlineRoot = if ($OfflineModuleRoot) { $OfflineModuleRoot } else { $PSScriptRoot }
    $offlinePSWU = Join-Path $offlineRoot 'PSWindowsUpdate'

    if ($ForceUpdate) { Write-SetupLog "Force-Update aktiviert" "UPDATE" }
    
    # =========================================================
    # === NuGet Provider prüfen und aktualisieren
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== NuGet Provider Check ===" "INFO"
    
    $offlineModulesPresent = Test-Path -LiteralPath $offlinePSWU -PathType Container
    if ($ModulesVerifiedCurrent) {
        $nugetReady = $true
    } else {
        $offlineNuGetProvider = Join-Path $offlineRoot 'NuGetProvider'
        $nugetReady = Update-NuGetProvider -Force:$ForceUpdate -OfflineProviderPath $offlineNuGetProvider -WriteLog {
            param($message, $level)
            Write-SetupLog $message $level
        }
        if (-not $nugetReady) {
            Write-SetupLog 'NuGet-Provider nicht verfügbar; bereitgestellte Module lassen sich weiterhin ohne NuGet laden.' 'WARN'
        }
    }

    if ($ModulesVerifiedCurrent) {
        Write-SetupLog 'Modul- und NuGet-Versionen wurden durch die Verteilung geprüft; keine Pakete werden aktualisiert.' 'INFO'
    } elseif ($InstallWinGetClientModule) {
        # NuGet steht nun bereit, bevor Update-WinGetClientModule Gallery- und
        # Paketabfragen startet. So kommt auf alten PowerShellGet-Ständen
        # keine interaktive Provider-Rückfrage.
        Write-SetupLog "=== WinGet-Client-Modul ===" "INFO"
        $winGetClientReady = Update-WinGetClientModule -OfflineModulePath $offlineRoot -WriteLog {
            param($message, $level)
            Write-SetupLog $message $level
        }
        if (-not $winGetClientReady) {
            Write-SetupLog "WinGet-Client-Modul konnte nicht aktualisiert werden; WindowsUpdateAdm-Setup wird fortgesetzt." "WARN"
        }
    }

    # === PowerShell Gallery konfigurieren
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== PowerShell Gallery Konfiguration ===" "INFO"
    
    if ($ModulesVerifiedCurrent -or $offlineModulesPresent) {
        Write-SetupLog 'PSGallery-Konfiguration übersprungen; PSWindowsUpdate wird aus dem bereitgestellten Offline-Paket gepflegt.' 'INFO'
    } else {
    try {
        $PSGallery = Get-PSRepository -Name PSGallery -ErrorAction Stop
        if ($PSGallery.InstallationPolicy -ne 'Trusted') {
            Write-SetupLog "Setze PSGallery auf 'Trusted'..." "INFO"
            Set-PSRepository -Name PSGallery -InstallationPolicy Trusted -ErrorAction Stop
            Write-SetupLog "PSGallery als vertrauenswuerdig markiert" "SUCCESS"
        } else {
            Write-SetupLog "PSGallery bereits als vertrauenswuerdig konfiguriert" "SUCCESS"
        }
    }
    catch {
        Write-SetupLog 'PSGallery-Konfiguration übersprungen; Details im Setup-Protokoll.' 'WARN'
        Write-SetupDiagnostic -Operation 'PSGallery-Konfiguration' -ErrorRecord $_
    }
    }
    
    # =========================================================
    # === PSWindowsUpdate installieren/aktualisieren (mit Retry)
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== PSWindowsUpdate Installation/Update ===" "INFO"
    
    if ($ModulesVerifiedCurrent) {
        $Success = $true
        Write-SetupLog 'PSWindowsUpdate ist laut zentraler Versionsprüfung aktuell.' 'SUCCESS'
    } else {
        $Success = Update-PSWindowsUpdateModule -Force:$ForceUpdate -OfflineModulePath $offlinePSWU `
            -WriteLog { param($message, $level) Write-SetupLog $message $level }
    }

    if (-not $Success) {
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== WICHTIG: PSWindowsUpdate konnte nicht automatisch installiert werden ===" "ERROR"
        Write-SetupLog "Bitte installiere PSWindowsUpdate manuell:" "INFO"
        Write-SetupLog "Option A - Offline-Paket in Skriptordner legen:" "INFO"
        Write-SetupLog "  1. Auf einem PC mit Internet ausführen:" "INFO"
        Write-SetupLog "     Save-Module -Name PSWindowsUpdate -Path '<Skriptordner>'" "INFO"
        Write-SetupLog "  2. Dieses Skript erneut ausführen - erkennt Ordner automatisch." "INFO"
        Write-SetupLog "Option B - Direkt ins Modulverzeichnis installieren:" "INFO"
        Write-SetupLog "  C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate" "INFO"
        throw "PSWindowsUpdate konnte nach $MaxRetries Versuchen nicht installiert werden. Siehe Anleitung oben."
    }
    
    # === Modul testen ===
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== PSWindowsUpdate Modul Test ===" "INFO"
    try {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        $Commands   = Get-Command -Module PSWindowsUpdate
        $ModuleInfo = Get-Module  -Name PSWindowsUpdate
        Write-SetupLog "PSWindowsUpdate erfolgreich geladen" "SUCCESS"
        Write-SetupLog "Modul-Version: $($ModuleInfo.Version)" "INFO"
        Write-SetupLog "Verfuegbare Cmdlets: $($Commands.Count)" "INFO"
        $ImportantCmdlets = $Commands | Where-Object { $_.Name -match '^(Get|Install|Remove|Hide|Show)-WindowsUpdate$|^Get-WU' } | Select-Object -First 5
        Write-SetupLog "Wichtigste Cmdlets:" "INFO"
        foreach ($Cmd in $ImportantCmdlets) { Write-SetupLog "  - $($Cmd.Name)" "INFO" }
    }
    catch {
        Write-SetupDiagnostic -Operation 'PSWindowsUpdate-Modultest' -ErrorRecord $_
        throw 'PSWindowsUpdate konnte nicht geladen werden; Details stehen im Setup-Protokoll.'
    }
    
    # =========================================================
    # === Modul-Verfügbarkeit für PS5 + PS7 sicherstellen
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Dual PowerShell Support (PS5 + PS7) ===" "INFO"
    
    $PS5Path = "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate"
    $PS7Path = "$env:ProgramFiles\PowerShell\Modules\PSWindowsUpdate"
    
    $CurrentModule = Get-Module -ListAvailable -Name PSWindowsUpdate | Sort-Object Version -Descending | Select-Object -First 1
    $SourcePath    = $CurrentModule.ModuleBase
    $SourceVersion = $CurrentModule.Version
    Write-SetupLog "Aktuelles Modul gefunden in: $SourcePath (Version: $SourceVersion)" "INFO"
    
    foreach ($TargetBase in @($PS5Path, $PS7Path)) {
        $Label       = if ($TargetBase -like "*WindowsPowerShell*") { "PowerShell 5.1" } else { "PowerShell 7" }
        $VersionPath = Join-Path $TargetBase $SourceVersion

        # Nur kopieren wenn:
        # - Zielversion nicht vorhanden
        # - ForceUpdate gesetzt
        # - Quelle ist ein Benutzerprofil-Pfad (SYSTEM findet es nicht)
        $installedVersion = $null
        if (Test-Path -LiteralPath $TargetBase -PathType Container) {
            $targetManifests = @(Get-ChildItem -LiteralPath $TargetBase -Filter 'PSWindowsUpdate.psd1' -File -Recurse -ErrorAction SilentlyContinue)
            foreach ($targetManifest in $targetManifests) {
                try {
                    $manifestData = Import-PowerShellDataFile -LiteralPath $targetManifest.FullName -ErrorAction Stop
                    $manifestVersion = [version]$manifestData.ModuleVersion
                    $rootModule = [string]$manifestData.RootModule
                    if ($rootModule -and -not (Test-Path -LiteralPath (Join-Path $targetManifest.DirectoryName $rootModule) -PathType Leaf)) { continue }
                    if ($null -eq $installedVersion -or $manifestVersion -gt $installedVersion) { $installedVersion = $manifestVersion }
                } catch {
                    # Ein fehlendes oder ungültiges Manifest zählt nicht als installierte Version.
                }
            }
        }

        $sourceIsUserProfile = $SourcePath -like "*$env:USERPROFILE*" -or $SourcePath -like "*\Users\*"
        $NeedsCopy = $ForceUpdate -or
                     ($null -eq $installedVersion) -or
                     ($sourceIsUserProfile) -or
                     ([version]$SourceVersion -gt [version]$installedVersion)

        if ($NeedsCopy) {
            Write-SetupLog "Kopiere Modul nach $Label Pfad..." "UPDATE"
            try {
                # Nur alte Versionen entfernen, nicht gleiche
                if (Test-Path $TargetBase) {
                    Get-ChildItem $TargetBase -Directory | Where-Object { $_.Name -ne "$SourceVersion" } | ForEach-Object {
                        Remove-Item $_.FullName -Recurse -Force -ErrorAction Stop
                        Write-SetupLog "Alte Version entfernt: $($_.Name)" "INFO"
                    }
                }
                $Parent = Split-Path $VersionPath -Parent
                if (-not (Test-Path $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $SourcePath -Destination $VersionPath -Recurse -Force
                Write-SetupLog "Modul nach $Label kopiert: $VersionPath" "SUCCESS"
            }
            catch {
                Write-SetupLog "Modul konnte nicht nach ${Label} kopiert werden; Details im Setup-Protokoll." 'WARN'
                Write-SetupDiagnostic -Operation 'PSWindowsUpdate-Modulkopie' -ErrorRecord $_ -Context @("Destination=$Label")
            }
        } else {
            Write-SetupLog "Modul bereits korrekt in $Label vorhanden (Version: $installedVersion)" "SUCCESS"
        }
    }
    
    # =========================================================
    # === PS-Remoting aktivieren
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== PS-Remoting Konfiguration ===" "INFO"
    # $PSSenderInfo existiert nur innerhalb einer Remoting-Sitzung. Unter
    # StrictMode darf die lokale Ausführung diese automatische Variable nicht
    # direkt lesen, weil sie dort nicht angelegt ist.
    $IsRemoteSetup = Test-Path -LiteralPath 'Variable:\PSSenderInfo'
    if ($IsRemoteSetup) {
        # Die aktuelle Sitzung beweist, dass WinRM bereits erreichbar ist.
        # Enable-PSRemoting würde den Dienst neu konfigurieren und diese
        # Ersteinrichtungs-Sitzung unnötig abbrechen.
        Write-SetupLog "Remote-Setup erkannt – PS-Remoting wird nicht erneut aktiviert." "INFO"
    } else {
        try {
            if ($PSVersionTable.PSEdition -eq 'Core') {
                # Die PowerShell-7-Warnung, dass Windows-PowerShell-Endpunkte
                # nicht mit aktiviert werden, ist hier erwartet: Das Setup
                # registriert den benötigten WindowsUpdateAdm-Endpunkt separat.
                # Kein zweiter Enable-PSRemoting-Lauf, der weitere Standard-
                # Endpunkte für eingehenden Remotezugriff freischalten würde.
                Enable-PSRemoting -Force -WarningAction SilentlyContinue -ErrorAction Stop
                Write-SetupLog "PowerShell-7-Remoting aktiviert; WindowsUpdateAdm wird separat als JEA-Endpunkt registriert." "SUCCESS"
            } else {
                Enable-PSRemoting -Force -ErrorAction Stop
                Write-SetupLog "PS-Remoting aktiviert" "SUCCESS"
            }
        }
        catch {
            Write-SetupLog 'PS-Remoting ist bereits aktiv oder konnte nicht erneut aktiviert werden; Details im Setup-Protokoll.' 'INFO'
            Write-SetupDiagnostic -Operation 'PS-Remoting-Konfiguration' -ErrorRecord $_
        }
    }

    # =========================================================
    # === Alte Service-Accounts entfernen (nur Nicht-AD-Geräte)
    # Das Zertifikat wird mit dem bei der Einrichtung verwendeten, bestehenden
    # Administratorkonto verknüpft. Zusätzliche svc-Administratoren sind nicht
    # mehr erforderlich.
    # =========================================================
    $IsInDomain = (Get-CimInstance -ClassName Win32_ComputerSystem).PartOfDomain

    if (-not $IsInDomain) {
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== Alte Service-Accounts entfernen ===" "INFO"
        foreach ($legacyAccount in @('svc-updates', 'svc-wupdate-hv')) {
            if ([string]::IsNullOrWhiteSpace($legacyAccount)) { continue }
            $existingAccount = Get-LocalUser -Name $legacyAccount -ErrorAction SilentlyContinue
            if ($existingAccount) {
                Remove-LocalUser -Name $legacyAccount -ErrorAction Stop
                Write-SetupLog "Nicht mehr benötigter Service-Account '$legacyAccount' entfernt." "SUCCESS"
            }
        }
    } else {
        Write-SetupLog "" "INFO"
        Write-SetupLog "Gerät ist Mitglied einer AD-Domäne - kein lokaler Service-Account erforderlich." "INFO"
    }

    # =========================================================
    # === WinRM HTTPS Zertifikat (für Nicht-AD-Ziele und fremde Domänen)
    # =========================================================
    if (-not $IsInDomain -or $EnableClientCertificateRemoting) {
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== WinRM HTTPS Zertifikat Setup ===" "INFO"
        if ($IsInDomain -and $EnableClientCertificateRemoting) {
            Write-SetupLog "Ziel ist Mitglied einer Domäne außerhalb der Verwaltungs-AD; Zertifikats-Remoting wird eingerichtet." "INFO"
        }

        $hostname = $env:COMPUTERNAME
        $certStore = "Cert:\LocalMachine\My"
        $ServerAuthOID = "1.3.6.1.5.5.7.3.1"

        # 1. Bestehende Zertifikate prüfen
        $existingCert = Get-ChildItem $certStore |
            Where-Object { $_.Subject -eq "CN=$hostname" -and $_.NotAfter -gt (Get-Date).AddDays(30) } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1

        # 2. Validierung: Hat das gefundene Zertifikat die nötige EKU?
        if ($existingCert) {
            $hasServerAuth = $existingCert.Extensions | 
                             Where-Object { $_.Oid.FriendlyName -eq "Enhanced Key Usage" -or $_.Oid.Value -eq "2.5.29.37" } |
                             Where-Object { $_.Format($false) -match $ServerAuthOID -or $_.Format($false) -match "Serverauthentifizierung" }

            if (-not $hasServerAuth) {
                Write-SetupLog "Vorhandenes Zertifikat hat keine Server-EKU. Lösche ungültiges Zertifikat..." "WARN"
                Remove-Item -Path $existingCert.PSPath -Force
                $existingCert = $null
            }
        }

        # 3. Zertifikat nutzen oder neu erstellen
        if ($existingCert -and -not $ForceUpdate) {
            Write-SetupLog "Gültiges Zertifikat bereits vorhanden (läuft ab: $($existingCert.NotAfter.ToString('yyyy-MM-dd')))" "SUCCESS"
            $cert = $existingCert
        } else {
            if ($existingCert) {
                Write-SetupLog "Erneuere Zertifikat (ForceUpdate)..." "UPDATE"
                Remove-Item -Path $existingCert.PSPath -Force -ErrorAction Stop
            } else {
                Write-SetupLog "Erstelle neues selbstsigniertes Zertifikat für $hostname..." "INFO"
            }
            try {
                $cert = New-SelfSignedCertificate `
                    -DnsName $hostname `
                    -CertStoreLocation $certStore `
                    -NotAfter (Get-Date).AddYears(10) `
                    -KeyUsage DigitalSignature, KeyEncipherment `
                    -TextExtension @("2.5.29.37={text}$ServerAuthOID") `
                    -HashAlgorithm "SHA256" `
                    -ErrorAction Stop
                Write-SetupLog "Zertifikat erstellt: $($cert.Thumbprint) (inkl. Server-EKU)" "SUCCESS"
            }
            catch {
                Write-SetupDiagnostic -Operation 'WinRM-HTTPS-Zertifikat' -ErrorRecord $_ -Context @("Computer=$hostname")
                throw 'WinRM-HTTPS-Zertifikat konnte nicht erstellt werden; Details stehen im Setup-Protokoll.'
            }
        }
        

        # Prüfen ob HTTPS-Listener bereits existiert
        $httpsListener = Get-ChildItem WSMan:\localhost\Listener |
            Where-Object { (Get-Item "$($_.PSPath)\Transport" -ErrorAction SilentlyContinue).Value -eq 'HTTPS' } |
            Select-Object -First 1

        if ($httpsListener -and -not $ForceUpdate) {
            Write-SetupLog "WinRM HTTPS-Listener bereits vorhanden." "SUCCESS"
        } else {
            if ($httpsListener) {
                Write-SetupLog "Entferne alten HTTPS-Listener..." "INFO"
                Remove-Item -Path $httpsListener.PSPath -Recurse -Force -ErrorAction Stop
            }
            Write-SetupLog "Erstelle WinRM HTTPS-Listener..." "INFO"
            try {
                New-Item -Path WSMan:\localhost\Listener `
                    -Transport HTTPS `
                    -Address * `
                    -CertificateThumbprint $cert.Thumbprint `
                    -Force -ErrorAction Stop | Out-Null
                Write-SetupLog "WinRM HTTPS-Listener erstellt (Port 5986)" "SUCCESS"
            }
            catch {
                Write-SetupDiagnostic -Operation 'WinRM-HTTPS-Listener' -ErrorRecord $_ -Context @("Computer=$hostname")
                throw 'WinRM-HTTPS-Listener konnte nicht erstellt werden; Details stehen im Setup-Protokoll.'
            }
        }

        # HTTP.sys muss Clientzertifikate bereits während des TLS-Handshakes
        # aushandeln. Ein WSMan-Zertifikatsmapping allein reicht nicht: ohne
        # diese Option liefert WinRM 401/503 und meldet, dass kein
        # Clientzertifikat abgerufen werden konnte.
        try {
            $sslBindingOutput = @(& "$env:SystemRoot\System32\netsh.exe" http show sslcert ipport=0.0.0.0:5986 2>&1)
            $sslBindingExitCode = $LASTEXITCODE
            $sslBindingText = ($sslBindingOutput | ForEach-Object { [string]$_ }) -join "`n"
            if ($sslBindingExitCode -ne 0) {
                throw "HTTP.sys-Bindung für 0.0.0.0:5986 konnte nicht gelesen werden (netsh Exitcode $sslBindingExitCode): $sslBindingText"
            }

            # netsh lokalisiert die Beschriftungen. Die Werte selbst (Hash,
            # GUID, Store und Enabled/Disabled) sind sprachneutral.
            $certificateHashMatch = [regex]::Match($sslBindingText, '(?im)^\s*(?:Certificate\s+Hash|Zertifikathash|Zertifikat-Hash)\s*:\s*([0-9a-f]{40,64})\s*$')
            $applicationIdMatch = [regex]::Match($sslBindingText, '(?im)^\s*(?:Application\s+ID|Anwendungs-ID)\s*:\s*(\{?[0-9a-f-]{36}\}?)\s*$')
            $certificateStoreMatch = [regex]::Match($sslBindingText, '(?im)^\s*(?:Certificate\s+Store\s+Name|Zertifikatspeichername|Zertifikatsspeichername)\s*:\s*(\S+)\s*$')
            $negotiationMatch = [regex]::Match($sslBindingText, '(?im)^\s*(?:Client\s+Certificate\s+Negotiation|Clientzertifikat\s+aushandeln)\s*:\s*(Enabled|Disabled|Aktiviert|Deaktiviert)\s*$')

            if (-not $certificateHashMatch.Success -or -not $applicationIdMatch.Success -or -not $certificateStoreMatch.Success -or -not $negotiationMatch.Success) {
                throw "Die HTTP.sys-Bindungswerte konnten nicht sicher ausgewertet werden. Ausgabe: $sslBindingText"
            }

            $clientCertificateNegotiationEnabled = $negotiationMatch.Groups[1].Value -match '^(?i:Enabled|Aktiviert)$'
            if (-not $clientCertificateNegotiationEnabled) {
                $certificateHash = $certificateHashMatch.Groups[1].Value
                $applicationId = $applicationIdMatch.Groups[1].Value
                $certificateStoreName = $certificateStoreMatch.Groups[1].Value
                if ($certificateStoreName -match '^(?i:\(?null\)?)$') { $certificateStoreName = 'MY' }
                $netshArguments = @(
                    'http', 'update', 'sslcert', 'ipport=0.0.0.0:5986',
                    "certhash=$certificateHash", "appid=$applicationId",
                    "certstorename=$certificateStoreName", 'clientcertnegotiation=enable'
                )
                $updateOutput = @(& "$env:SystemRoot\System32\netsh.exe" @netshArguments 2>&1)
                $updateExitCode = $LASTEXITCODE
                if ($updateExitCode -ne 0) {
                    throw "HTTP.sys-Clientzertifikataushandlung konnte nicht aktiviert werden (netsh Exitcode $updateExitCode): $($updateOutput -join ' ')"
                }

                $verifyOutput = @(& "$env:SystemRoot\System32\netsh.exe" http show sslcert ipport=0.0.0.0:5986 2>&1)
                $verifyExitCode = $LASTEXITCODE
                $verifyText = ($verifyOutput | ForEach-Object { [string]$_ }) -join "`n"
                $verifyNegotiationMatch = [regex]::Match($verifyText, '(?im)^\s*(?:Client\s+Certificate\s+Negotiation|Clientzertifikat\s+aushandeln)\s*:\s*(Enabled|Disabled|Aktiviert|Deaktiviert)\s*$')
                if ($verifyExitCode -ne 0 -or -not $verifyNegotiationMatch.Success -or $verifyNegotiationMatch.Groups[1].Value -notmatch '^(?i:Enabled|Aktiviert)$') {
                    throw "Aktivierung der HTTP.sys-Clientzertifikataushandlung wurde nicht bestätigt. Ausgabe: $verifyText"
                }

                Write-SetupLog "HTTP.sys-Clientzertifikataushandlung für WinRM HTTPS (5986) aktiviert und verifiziert." "SUCCESS"
            } else {
                Write-SetupLog "HTTP.sys handelt Clientzertifikate für WinRM HTTPS (5986) bereits aus." "SUCCESS"
            }
        }
        catch {
            Write-SetupDiagnostic -Operation 'HTTP.sys-Clientzertifikataushandlung' -ErrorRecord $_ -Context @("Computer=$hostname", 'Binding=0.0.0.0:5986')
            throw 'HTTP.sys-Clientzertifikataushandlung für WinRM HTTPS konnte nicht sicher eingerichtet werden; Details stehen im Setup-Protokoll.'
        }

        # Firewall-Regel für Port 5986 ausschließlich aus den freigegebenen
        # Verwaltungsserver-Adressen erreichbar machen. Ohne ermittelte oder
        # konfigurierte Quellen wird keine breite Freigabe angelegt.
        try {
            $allowedRemoteAddresses = @($WinRMFirewallRemoteAddresses | ForEach-Object { ([string]$_).Trim() } |
                Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)
            if ($allowedRemoteAddresses.Count -eq 0) {
                throw 'Es wurden keine zulässigen Verwaltungsserver-IP-Adressen übergeben; eine offene Freigabe wird aus Sicherheitsgründen nicht erstellt.'
            }

            $fwRules = @(Get-NetFirewallRule -DisplayName 'WinRM HTTPS' -ErrorAction SilentlyContinue)
            if ($fwRules.Count -eq 0) {
                $null = New-NetFirewallRule `
                    -DisplayName 'WinRM HTTPS' `
                    -Direction Inbound `
                    -Protocol TCP `
                    -LocalPort 5986 `
                    -RemoteAddress $allowedRemoteAddresses `
                    -Profile Any `
                    -Action Allow `
                    -Enabled True `
                    -ErrorAction Stop
                $fwRules = @(Get-NetFirewallRule -DisplayName 'WinRM HTTPS' -ErrorAction Stop)
                Write-SetupLog "Eingehende WinRM-HTTPS-Regel erstellt; erlaubte Quellen: $($allowedRemoteAddresses -join ', ')." 'INFO'
            } else {
                foreach ($rule in $fwRules) {
                    Set-NetFirewallRule -InputObject $rule -Enabled True -Direction Inbound -Action Allow -Profile Any -ErrorAction Stop
                    $addressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
                    Set-NetFirewallAddressFilter -InputObject $addressFilter -RemoteAddress $allowedRemoteAddresses -ErrorAction Stop
                    $portFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
                    Set-NetFirewallPortFilter -InputObject $portFilter -Protocol TCP -LocalPort 5986 -ErrorAction Stop
                }
                Write-SetupLog "Vorhandene WinRM-HTTPS-Regel(n) auf die erlaubten Verwaltungsquellen eingeschränkt: $($allowedRemoteAddresses -join ', ')." 'INFO'
            }

            foreach ($rule in $fwRules) {
                $actualFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
                $actualAddresses = @($actualFilter.RemoteAddress | ForEach-Object { [string]$_ } | Sort-Object -Unique)
                $expectedAddresses = @($allowedRemoteAddresses | Sort-Object -Unique)
                if (Compare-Object -ReferenceObject $expectedAddresses -DifferenceObject $actualAddresses) {
                    throw "Firewall-Regel '$($rule.Name)' besitzt nach dem Setzen nicht die erwarteten Quelladressen. Erwartet: $($expectedAddresses -join ', '); gefunden: $($actualAddresses -join ', ')."
                }
                $actualPortFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $rule -ErrorAction Stop
                if ([string]$actualPortFilter.Protocol -notin @('TCP', '6') -or
                    (@($actualPortFilter.LocalPort | ForEach-Object { [string]$_ }) -notcontains '5986')) {
                    throw "Firewall-Regel '$($rule.Name)' ist nicht auf TCP-Port 5986 begrenzt."
                }
            }
            Write-SetupLog 'WinRM-HTTPS-Firewallregel und Quelladressbeschränkung erfolgreich verifiziert.' 'SUCCESS'

            try {
                $managedRuleNames = @($fwRules | ForEach-Object { [string]$_.Name })
                $otherHttpsRules = [System.Collections.Generic.List[object]]::new()
                foreach ($candidateRule in @(Get-NetFirewallRule -PolicyStore ActiveStore -Enabled True -Direction Inbound -Action Allow -ErrorAction Stop)) {
                    if ($candidateRule.Name -in $managedRuleNames) { continue }
                    $candidatePortFilter = Get-NetFirewallPortFilter -AssociatedNetFirewallRule $candidateRule -ErrorAction Stop
                    if (-not $candidatePortFilter) {
                        throw "Portfilter für aktive Firewall-Regel '$($candidateRule.Name)' konnte nicht ermittelt werden."
                    }
                    $candidateProtocol = [string]$candidatePortFilter.Protocol
                    $candidatePorts = @($candidatePortFilter.LocalPort | ForEach-Object { [string]$_ })
                    $allowsWinRmHttps = $false
                    if ($candidateProtocol -in @('TCP', '6', 'Any', '256')) {
                        foreach ($portEntry in $candidatePorts) {
                            if ($portEntry -in @('Any', '*')) { $allowsWinRmHttps = $true; break }
                            if ($portEntry -match '^\d+$' -and [int]$portEntry -eq 5986) { $allowsWinRmHttps = $true; break }
                            if ($portEntry -match '^(?<Start>\d+)-(?<End>\d+)$' -and
                                [int]$Matches.Start -le 5986 -and [int]$Matches.End -ge 5986) {
                                $allowsWinRmHttps = $true
                                break
                            }
                        }
                    }
                    if (-not $allowsWinRmHttps) { continue }

                    # Port=Any ist bei anwendungs- oder dienstgebundenen
                    # Regeln kein pauschaler WinRM-Zugriff. Nur Regeln, die
                    # System/svchost/WinRM treffen können, werden weiter als
                    # mögliche Freigabe für den Listener betrachtet.
                    $applicationFilters = @(Get-NetFirewallApplicationFilter -AssociatedNetFirewallRule $candidateRule -ErrorAction Stop)
                    if (-not $applicationFilters) {
                        throw "Anwendungsfilter für aktive Firewall-Regel '$($candidateRule.Name)' konnte nicht ermittelt werden."
                    }
                    $candidatePrograms = @($applicationFilters | ForEach-Object { [string]$_.Program } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    $candidatePackages = @($applicationFilters | ForEach-Object { [string]$_.Package } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -notin @('Any', '*') })
                    if ($candidatePackages.Count -gt 0) { continue }
                    $programsCouldMatchWinRm = $true
                    if ($candidatePrograms.Count -gt 0) {
                        $programsCouldMatchWinRm = @($candidatePrograms | Where-Object {
                            $_ -in @('Any', '*', 'System') -or $_ -match '(?i)(^|\\)svchost\.exe$'
                        }).Count -gt 0
                    }
                    if (-not $programsCouldMatchWinRm) { continue }

                    $serviceFilters = @(Get-NetFirewallServiceFilter -AssociatedNetFirewallRule $candidateRule -ErrorAction Stop)
                    if (-not $serviceFilters) {
                        throw "Dienstfilter für aktive Firewall-Regel '$($candidateRule.Name)' konnte nicht ermittelt werden."
                    }
                    $candidateServices = @($serviceFilters | ForEach-Object { [string]$_.Service } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
                    if ($candidateServices.Count -gt 0 -and
                        @($candidateServices | Where-Object { $_ -in @('Any', '*', 'WinRM') }).Count -eq 0) { continue }

                    $candidateAddressFilter = Get-NetFirewallAddressFilter -AssociatedNetFirewallRule $candidateRule -ErrorAction Stop
                    if (-not $candidateAddressFilter) {
                        throw "Adressfilter für aktive Firewall-Regel '$($candidateRule.Name)' konnte nicht ermittelt werden."
                    }
                    $candidateRemoteAddresses = @($candidateAddressFilter.RemoteAddress | ForEach-Object { [string]$_ })
                    if ($candidateRemoteAddresses.Count -eq 0) { $candidateRemoteAddresses = @('nicht ermittelbar') }
                    $hasBroadOrUnverifiedSource = $false
                    foreach ($source in $candidateRemoteAddresses) {
                        # Zusätzliche Regeln sind nur dann kompatibel mit der
                        # Quellenbeschränkung, wenn jede Quelle exakt in der
                        # für diese Verteilung freigegebenen Liste enthalten ist.
                        # Any, LocalSubnet, größere Netze und nicht auflösbare
                        # Adressformen fallen damit fail-closed durch.
                        if ($source -notin $allowedRemoteAddresses) {
                            $hasBroadOrUnverifiedSource = $true
                        }
                    }
                    $otherHttpsRules.Add([pscustomobject]@{
                        Name = [string]$candidateRule.Name
                        DisplayName = [string]$candidateRule.DisplayName
                        Profile = [string]$candidateRule.Profile
                        Protocol = $candidateProtocol
                        LocalPort = ($candidatePorts -join ',')
                        RemoteAddress = ($candidateRemoteAddresses -join ',')
                        BroadOrUnverifiedSource = $hasBroadOrUnverifiedSource
                    })
                }
                foreach ($candidateRule in $otherHttpsRules) {
                    $level = if ($candidateRule.BroadOrUnverifiedSource) { 'WARN' } else { 'INFO' }
                    Write-SetupLog "Zusätzliche aktive WinRM-HTTPS-Regel inventarisiert: Name=$($candidateRule.Name); Anzeige=$($candidateRule.DisplayName); Profil=$($candidateRule.Profile); Protokoll=$($candidateRule.Protocol); Port=$($candidateRule.LocalPort); RemoteAddress=$($candidateRule.RemoteAddress)." $level
                }
                $broadHttpsRules = @($otherHttpsRules | Where-Object { $_.BroadOrUnverifiedSource })
                if ($broadHttpsRules.Count -gt 0) {
                    $broadNames = ($broadHttpsRules | ForEach-Object { $_.Name }) -join ', '
                    throw "Weitere aktive WinRM-HTTPS-Regeln erlauben beliebige oder nicht prüfbare Quellen ($broadNames); diese Regel(n) müssen eingeschränkt oder entfernt werden, bevor die Verteilung als sicher gilt."
                }
            }
            catch {
                Write-SetupLog 'Weitere aktive WinRM-HTTPS-Regeln konnten nicht sicher inventarisiert werden; Setup wird abgebrochen.' 'ERROR'
                Write-SetupDiagnostic -Operation 'WinRM-Firewall-Inventar' -ErrorRecord $_
                throw
            }
        }
        catch {
            Write-SetupLog 'WinRM-HTTPS-Firewallregel konnte nicht sicher eingeschränkt oder verifiziert werden; Setup wird abgebrochen.' 'ERROR'
            Write-SetupDiagnostic -Operation 'WinRM-Firewallregel' -ErrorRecord $_ -Context @("RemoteAddresses=$($WinRMFirewallRemoteAddresses -join ', ')")
            throw 'WinRM-HTTPS-Firewallregel konnte nicht sicher eingerichtet werden; Details stehen im Setup-Protokoll.'
        }

        Write-SetupLog "WinRM HTTPS Setup abgeschlossen." "SUCCESS"

        # =========================================================
        # === Zertifikat-Authentifizierung einrichten
        # Client-Zertifikat vom Verwaltungsserver importieren und
        # mit dem bei der Einrichtung verwendeten lokalen Administrator verknüpfen
        # =========================================================
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== Zertifikat-Authentifizierung Setup ===" "INFO"

        # Zertifikat-Auth in WinRM aktivieren
        try {
            Set-Item WSMan:\localhost\Service\Auth\Certificate -Value $true -ErrorAction Stop
            Write-SetupLog "WinRM Zertifikat-Authentifizierung aktiviert." "SUCCESS"
        }
        catch {
            Write-SetupLog 'Zertifikatsauthentifizierung konnte nicht aktiviert werden; Details im Setup-Protokoll.' 'WARN'
            Write-SetupDiagnostic -Operation 'WinRM-Zertifikatsauthentifizierung' -ErrorRecord $_
        }

        # Ohne bereits funktionierende Zertifikatsverbindung ist für den
        # lokalen Konto-Bootstrap die Remote-UAC-Ausnahme erforderlich. Sie
        # bleibt nur bis zur SYSTEM-Finalisierung geöffnet und wird dort sowie
        # bei jedem erkannten Fehler wieder geschlossen. Mit nutzbarem
        # Zertifikatskanal bleibt sie deaktiviert.
        try {
            $regPath = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
            $tokenFilterSettings = Get-ItemProperty -LiteralPath $regPath -ErrorAction SilentlyContinue
            $tokenFilterProperty = if ($null -ne $tokenFilterSettings) {
                $tokenFilterSettings.PSObject.Properties['LocalAccountTokenFilterPolicy']
            } else { $null }
            $tokenFilterValue = if ($null -ne $tokenFilterProperty) { $tokenFilterProperty.Value } else { $null }
            if ($TemporaryLocalAccountBootstrap -and $EnableClientCertificateRemoting) {
                # Einen vorhandenen lokalen Override vorübergehend entfernen;
                # der SYSTEM-Finalizer stellt danach den Windows-Standard her.
                Clear-WindowsUpdateLocalAccountTokenFilterPolicy -Reason 'vorübergehender Zertifikats-Bootstrap beginnt; vorherige lokale Überschreibung entfernt'
                Set-WindowsUpdateLocalAccountTokenFilterPolicy -Value 1 -Reason 'temporärer lokaler Konto-Bootstrap; Registrywert wird nach der SYSTEM-Finalisierung entfernt'
            } else {
                if ($null -ne $tokenFilterValue) {
                    Clear-WindowsUpdateLocalAccountTokenFilterPolicy -Reason 'Zertifikatszugriff eingerichtet; Windows-Standard wiederhergestellt'
                } else {
                    Write-SetupLog 'LocalAccountTokenFilterPolicy ist nicht gesetzt; Windows-Standard gilt.' 'SUCCESS'
                }
            }
        }
        catch {
            Write-SetupLog 'LocalAccountTokenFilterPolicy konnte nicht gesetzt werden; Details im Setup-Protokoll.' 'WARN'
            Write-SetupDiagnostic -Operation 'LocalAccountTokenFilterPolicy' -ErrorRecord $_
        }

        # Client-Zertifikat (Public Key) aus Skriptordner importieren
        $clientCertPath = Join-Path $PSScriptRoot 'WinRM-ClientCert.cer'
        if (Test-Path $clientCertPath) {
            Write-SetupLog "Importiere Client-Zertifikat: $clientCertPath" "INFO"
            try {
                # In Trusted Root und TrustedPeople importieren
                $clientCert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($clientCertPath)

                $rootStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("Root", "LocalMachine")
                $rootStore.Open("ReadWrite")
                $rootStore.Add($clientCert)
                $rootStore.Close()

                $trustedStore = New-Object System.Security.Cryptography.X509Certificates.X509Store("TrustedPeople", "LocalMachine")
                $trustedStore.Open("ReadWrite")
                $trustedStore.Add($clientCert)
                $trustedStore.Close()

                Write-SetupLog "Client-Zertifikat importiert: $($clientCert.Thumbprint)" "SUCCESS"

                # Ein Mapping gilt nur dann als aktuell, wenn auch sein Issuer
                # auf den gerade importierten Zertifikat-Thumbprint zeigt.
                # Der WSMan-Provider liefert diese Werte je nach Windows-Version
                # direkt als Eigenschaften oder gebündelt in der Keys-Auflistung.
                function Get-WUAdmClientCertificateMappingValue {
                    param($Mapping, [string]$Name)
                    $property = $Mapping.PSObject.Properties[$Name]
                    if ($null -ne $property -and $null -ne $property.Value) {
                        return [string]$property.Value
                    }
                    $keysProperty = $Mapping.PSObject.Properties['Keys']
                    if ($null -ne $keysProperty -and $null -ne $keysProperty.Value) {
                        foreach ($key in @($keysProperty.Value)) {
                            $parts = ([string]$key) -split '=', 2
                            if ($parts.Count -eq 2 -and $parts[0] -ieq $Name) {
                                return [string]$parts[1]
                            }
                        }
                    }
                    return $null
                }
                $mappingSubject = "$($clientCert.Subject.Replace('CN=',''))@localhost"
                $allMappings = @(Get-ChildItem WSMan:\localhost\ClientCertificate -Recurse -ErrorAction SilentlyContinue)
                $subjectMappings = @($allMappings |
                    Where-Object {
                        (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Subject') -eq $mappingSubject
                    })
                # Der Issuerwert ist bei unserem selbstsignierten Clientzertifikat
                # dessen Thumbprint. Alte Wildcard- oder anders benannte Einträge
                # mit derselben Zertifikatidentität können eine neue Zuordnung
                # überlagern und WinRM mit HTTP 12186 ablehnen lassen.
                $issuerMappings = @($allMappings | Where-Object {
                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Issuer') -eq $clientCert.Thumbprint
                })
                $currentMapping = @($subjectMappings | Where-Object {
                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Issuer') -eq $clientCert.Thumbprint -and
                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'URI') -in $script:ClientCertificateEndpointUris
                })
                $certificateMappingConfirmed = $false

                if ($FinalizeJEA -and
                    -not [string]::IsNullOrWhiteSpace($script:CertificateMappedPrincipal) -and
                    -not [string]::IsNullOrWhiteSpace($script:CertificateMappingSid)) {
                    # Die SYSTEM-Finalisierung besitzt absichtlich keine
                    # Bootstrap-Anmeldedaten. Sie muss deshalb die Principal-
                    # und SID-Werte aus dem ersten Setup-Lauf verwenden und
                    # darf sie nicht aus einem eventuell unvollständigen
                    # WSMan-Mapping mit leerem UserName zurückberechnen.
                    Write-SetupLog "SYSTEM-Finalisierung übernimmt die Bootstrap-Identität '$($script:CertificateMappedPrincipal)' und SID '$($script:CertificateMappingSid)' unverändert." 'INFO'
                    $certificateMappingConfirmed = $false
                } elseif ($PreserveExistingCertificateMapping -and -not $ForceUpdate) {
                    $mappingUris = @($currentMapping | ForEach-Object { Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'URI' })
                    $missingMappingUris = @($script:ClientCertificateEndpointUris | Where-Object { $_ -notin $mappingUris })
                    if ($currentMapping.Count -ne $script:ClientCertificateEndpointUris.Count -or $missingMappingUris.Count -gt 0) {
                        throw "Das bestehende Zertifikatsmapping ist nicht eindeutig auf die benötigten Endpunkte begrenzt (Mappings: $($currentMapping.Count); erwartet: $($script:ClientCertificateEndpointUris.Count)); Einrichtung mit Bootstrap-Anmeldedaten erneut ausführen."
                    }
                    $mappedUserName = [string](Get-WUAdmClientCertificateMappingValue -Mapping $currentMapping[0] -Name 'UserName')
                    $mappedLocalUser = ($mappedUserName -split '\\')[-1]
                    $script:CertificateMappedPrincipal = "$env:COMPUTERNAME\$mappedLocalUser"
                    $script:CertificateMappingSid = (New-Object System.Security.Principal.NTAccount($script:CertificateMappedPrincipal)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                    Write-SetupLog "Zertifikatverbindung wurde vor dem Setup bestätigt; Mapping für den aktuellen Thumbprint bleibt erhalten." "SUCCESS"
                    $currentMappingPaths = @($currentMapping | ForEach-Object { $_.PSPath })
                    $staleMappings = @($subjectMappings + $issuerMappings | Where-Object {
                        $_.PSPath -notin $currentMappingPaths
                    } | Sort-Object -Property PSPath -Unique)
                    foreach ($staleMapping in $staleMappings) {
                        Remove-Item $staleMapping.PSPath -Recurse -Force -ErrorAction Stop
                    }
                    $certificateMappingConfirmed = $true
                } elseif ($currentMapping.Count -gt 0 -and -not $CertificateMappingCredential -and -not $ForceUpdate) {
                    # Ohne Einrichtungsdaten kann ein vorhandener Eintrag nicht
                    # erneuert werden. Die Verteilung bestätigt die Verbindung
                    # normalerweise vorher und setzt dann PreserveExisting... .
                    if ($currentMapping.Count -eq $script:ClientCertificateEndpointUris.Count -and $issuerMappings.Count -eq $script:ClientCertificateEndpointUris.Count) {
                        $mappedUserName = [string](Get-WUAdmClientCertificateMappingValue -Mapping $currentMapping[0] -Name 'UserName')
                        $mappedLocalUser = ($mappedUserName -split '\\')[-1]
                        $script:CertificateMappedPrincipal = "$env:COMPUTERNAME\$mappedLocalUser"
                        $script:CertificateMappingSid = (New-Object System.Security.Principal.NTAccount($script:CertificateMappedPrincipal)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                        $certificateMappingConfirmed = $false
                        Write-SetupLog "Ein Zertifikat-Mapping für den aktuellen Thumbprint ist vorhanden; seine Funktion wird anschließend durch den zentralen Verbindungstest bestätigt." "INFO"
                    } else {
                        throw "Zertifikatsmapping ist mehrdeutig (passende Subject/Issuer-Einträge: $($currentMapping.Count); alle Einträge mit Zertifikat-Issuer: $($issuerMappings.Count)); Einrichtungsdaten zum Bereinigen und Erneuern fehlen."
                    }
                } elseif (-not $CertificateMappingCredential) {
                    throw "Für ein neues oder zu erneuerndes Zertifikat-Mapping wurden keine Einrichtungs-Administrator-Anmeldedaten übergeben."
                } else {
                    # WinRM-Zertifikatsmappings nehmen einen lokalen Kontonamen
                    # an. Ein Präfix wie COMPUTER\Benutzer oder .\Benutzer gehört
                    # nicht in das Mapping; es kann zwar als Eintrag gespeichert
                    # werden, lässt sich danach aber nicht zuverlässig auflösen.
                    $credentialUserName = [string]$CertificateMappingCredential.UserName
                    $localUser = ($credentialUserName -split '\\')[-1]
                    if ([string]::IsNullOrWhiteSpace($localUser)) {
                        throw 'Der lokale Kontoname für das WinRM-Zertifikatsmapping ist leer.'
                    }
                    $script:CertificateMappedPrincipal = "$env:COMPUTERNAME\$localUser"
                    $script:CertificateMappingSid = (New-Object System.Security.Principal.NTAccount($script:CertificateMappedPrincipal)).Translate([System.Security.Principal.SecurityIdentifier]).Value
                    try {
                        # Diese Anmeldedaten wurden vom Aufrufer verwendet, wenn
                        # die Client-Zertifikatsverbindung nicht funktioniert hat.
                        # Zuerst exacte Mappings einrichten und verifizieren,
                        # solange ein altes Mapping den Bootstrap-Zugang noch
                        # ermöglicht. Erst danach Wildcards und kollidierende
                        # Zuordnungen entfernen.
                        $mappingCredential = New-Object System.Management.Automation.PSCredential(
                            $localUser,
                            $CertificateMappingCredential.Password
                        )
                        foreach ($mappingUri in $script:ClientCertificateEndpointUris) {
                            New-Item -Path WSMan:\localhost\ClientCertificate `
                                -Subject    $mappingSubject `
                                -URI        $mappingUri `
                                -Issuer     $clientCert.Thumbprint `
                                -Credential $mappingCredential `
                                -Force -ErrorAction Stop | Out-Null
                        }
                        $verifiedMappings = @(Get-ChildItem WSMan:\localhost\ClientCertificate -Recurse -ErrorAction SilentlyContinue |
                            Where-Object {
                                (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Subject') -eq $mappingSubject -and
                                (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Issuer') -eq $clientCert.Thumbprint -and
                                (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'URI') -in $script:ClientCertificateEndpointUris
                            })
                        $remainingIssuerMappings = @(Get-ChildItem WSMan:\localhost\ClientCertificate -Recurse -ErrorAction SilentlyContinue |
                            Where-Object {
                                (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Issuer') -eq $clientCert.Thumbprint
                            })
                        $verifiedUris = @($verifiedMappings | ForEach-Object { Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'URI' })
                        $missingVerifiedUris = @($script:ClientCertificateEndpointUris | Where-Object { $_ -notin $verifiedUris })
                        if ($verifiedMappings.Count -ne $script:ClientCertificateEndpointUris.Count -or $missingVerifiedUris.Count -gt 0) {
                            $mappingDetails = @($issuerMappings | ForEach-Object {
                                'Subject={0}; URI={1}; Issuer={2}; UserName={3}' -f `
                                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Subject'), `
                                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'URI'), `
                                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Issuer'), `
                                    (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'UserName')
                            }) -join ' | '
                            throw "Zertifikatsmapping ist nach dem Anlegen nicht eindeutig (gültige Zuordnungen: $($verifiedMappings.Count); Einträge für Zertifikat: $($remainingIssuerMappings.Count); erwartet: $($script:ClientCertificateEndpointUris.Count)). Vorhandene Einträge: $mappingDetails"
                        }
                        $verifiedMappingPaths = @($verifiedMappings | ForEach-Object { $_.PSPath })
                        $staleMappings = @($subjectMappings + $issuerMappings | Where-Object {
                            $_.PSPath -notin $verifiedMappingPaths
                        } | Sort-Object -Property PSPath -Unique)
                        foreach ($staleMapping in $staleMappings) {
                            Remove-Item $staleMapping.PSPath -Recurse -Force -ErrorAction Stop
                        }
                        $remainingIssuerMappings = @(Get-ChildItem WSMan:\localhost\ClientCertificate -Recurse -ErrorAction SilentlyContinue |
                            Where-Object {
                                (Get-WUAdmClientCertificateMappingValue -Mapping $_ -Name 'Issuer') -eq $clientCert.Thumbprint
                            })
                        if ($remainingIssuerMappings.Count -ne $script:ClientCertificateEndpointUris.Count) {
                            throw "Nach dem Bereinigen bleiben $($remainingIssuerMappings.Count) Mappings für das Zertifikat bestehen; erwartet werden exakt $($script:ClientCertificateEndpointUris.Count)."
                        }
                        $certificateMappingConfirmed = $true
                        Write-SetupLog "Zertifikat-Mapping für Account '$localUser' anhand von Subject, Issuer und exakt begrenzten Endpunkt-URIs verifiziert (Subject='$mappingSubject', Issuer='$($clientCert.Thumbprint)'). Der abschließende Zertifikat-Endpunkttest bestätigt die Kontoanmeldung." "SUCCESS"
                    }
                    catch {
                        Write-SetupLog 'FEHLER: Zertifikat-Mapping konnte nicht sicher eingerichtet und bestätigt werden.' 'ERROR'
                        Write-SetupDiagnostic -Operation 'WinRM-Zertifikatmapping' -ErrorRecord $_ -Context @("User=$localUser")
                        throw
                    }
                }

                # Alte öffentliche Kopien erst entfernen, nachdem das Mapping
                # für den aktuellen Thumbprint auf dem Ziel bestätigt wurde.
                if ($certificateMappingConfirmed) {
                    Write-SetupLog "WinRM-Zertifikatsmapping für Thumbprint $($clientCert.Thumbprint) bestätigt." 'SUCCESS'
                    foreach ($storeName in @('Root', 'TrustedPeople')) {
                        $store = New-Object System.Security.Cryptography.X509Certificates.X509Store($storeName, 'LocalMachine')
                        try {
                            $store.Open('ReadWrite')
                            $oldCertificates = @($store.Certificates | Where-Object {
                                $_.Subject -eq $clientCert.Subject -and $_.Thumbprint -ne $clientCert.Thumbprint
                            })
                            foreach ($oldCertificate in $oldCertificates) {
                                $store.Remove($oldCertificate)
                            }
                            if ($oldCertificates.Count -gt 0) {
                                Write-SetupLog "$($oldCertificates.Count) altes öffentliches Client-Zertifikat(e) aus LocalMachine\$storeName entfernt." 'SUCCESS'
                            }
                        }
                        finally {
                            $store.Close()
                        }
                    }
                } else {
                    Write-SetupLog 'Alte öffentliche Zertifikate bleiben erhalten: Mapping für den aktuellen Thumbprint konnte nicht bestätigt werden.' 'WARN'
                }
            }
            catch {
                $certificateFailureLevel = if ($EnableClientCertificateRemoting) { 'ERROR' } else { 'WARN' }
                Write-SetupLog 'Client-Zertifikat oder dessen WinRM-Mapping konnte nicht vollständig eingerichtet werden; Details im Setup-Protokoll.' $certificateFailureLevel
                Write-SetupDiagnostic -Operation 'WinRM-Clientzertifikat-Import' -ErrorRecord $_ -Context @("Path=$clientCertPath")
                if ($EnableClientCertificateRemoting) { throw }
                Write-SetupLog "Passwort-Authentifizierung bleibt als Fallback aktiv." "INFO"
            }
        } else {
            Write-SetupLog "Kein Client-Zertifikat gefunden ($clientCertPath)." "INFO"
            Write-SetupLog "Zuerst Komponenten\Setup-ClientCertificate.ps1 auf dem Verwaltungsserver ausführen," "INFO"
            Write-SetupLog "dann Komponenten\WinRM-ClientCert.cer bereitstellen und dieses Skript erneut ausführen." "INFO"
            if ($EnableClientCertificateRemoting) {
                throw "Client-Zertifikat fehlt, obwohl Clientzertifikat-Remoting aktiviert ist: $clientCertPath"
            }
            Write-SetupLog "Passwort-Authentifizierung bleibt aktiv." "INFO"
        }

    } else {
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== WinRM HTTPS Zertifikat ===" "INFO"
        Write-SetupLog "Ziel wird per Kerberos in der Verwaltungs-AD verwaltet - HTTPS-Zertifikat wird nicht benötigt." "INFO"
    }

    
    # Register-PSSessionConfiguration trennt laut WinRM alle aktiven
    # PowerShell-Sitzungen, wenn ein Endpoint neu registriert wird. Daher den
    # finalen JEA-Schritt bei einer Remote-Einrichtung in eine lokale Task
    # auslagern. Ein gewöhnlicher Child-Prozess wird beim Ende einer WinRM-
    # Sitzung nicht auf allen Systemen zuverlässig weitergeführt.
    if ($IsRemoteSetup -and -not $FinalizeJEA) {
        # Keinen App-Ausführungsalias verwenden: Auf Systemen mit der
        # Microsoft-Store-Version von PowerShell 7 kann dieser auf
        # WindowsApps zeigen. JEA/WinRM-SessionConfigs müssen jedoch über
        # Windows PowerShell 5.1 registriert werden.
        $localPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $localPowerShell)) {
            throw "Windows PowerShell 5.1 wurde nicht gefunden: $localPowerShell"
        }
        # Die SYSTEM-Finalisierung erhält denselben Sollwert wie der
        # Remote-Prozess. Sie soll die Version nicht aus einem eventuell
        # anders aufgelösten Modulpfad ableiten.
        $taskDeploymentVersion = if (-not [string]::IsNullOrWhiteSpace($DeploymentVersion)) {
            $DeploymentVersion
        } else {
            Get-WindowsUpdateAdmDeploymentVersion
        }
        # Der initiale Remote-Lauf hat Modul- und NuGet-Pflege bereits
        # abgeschlossen. Die lokale SYSTEM-Finalisierung registriert nur JEA
        # und darf weder erneut NuGet aufrufen noch temporäre Offlinepakete
        # benötigen.
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -FinalizeJEA -ModulesVerifiedCurrent -DeploymentVersion "{1}" -ResumeLogPath "{2}"' -f $PSCommandPath, $taskDeploymentVersion, $script:SetupLogPath
        if ($EnableClientCertificateRemoting) { $arguments += ' -EnableClientCertificateRemoting' }
        if ($TemporaryLocalAccountBootstrap) { $arguments += ' -TemporaryLocalAccountBootstrap' }
        if (-not [string]::IsNullOrWhiteSpace($ManagementComputerAccount)) {
            # Die SYSTEM-Finalisierung muss dieselbe eingeschränkte JEA-Rolle
            # für den Verwaltungsserver registrieren wie der ursprüngliche Lauf.
            $arguments += ' -ManagementComputerAccount "{0}"' -f $ManagementComputerAccount
        }
        if (-not [string]::IsNullOrWhiteSpace($ManagementComputerSid)) {
            $arguments += ' -ManagementComputerSid "{0}"' -f $ManagementComputerSid
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CertificateMappingSid)) {
            $arguments += ' -CertificateMappingSid "{0}"' -f $script:CertificateMappingSid
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CertificateMappedPrincipal)) {
            $arguments += ' -CertificateMappedPrincipal "{0}"' -f $script:CertificateMappedPrincipal
        }
        if (@($WinRMFirewallRemoteAddresses).Count -gt 0) {
            # Die SYSTEM-Finalisierung führt das Setup erneut aus und muss
            # dieselbe explizite Quellenliste für die HTTPS-Firewallregel erhalten.
            $quotedFirewallAddresses = @($WinRMFirewallRemoteAddresses | ForEach-Object {
                '"{0}"' -f ([string]$_).Replace('"', '')
            })
            $arguments += ' -WinRMFirewallRemoteAddresses {0}' -f ($quotedFirewallAddresses -join ' ')
        }
        $taskName = 'WindowsUpdateAdm-Finalize'
        $scheduledTaskCmdletsAvailable = (Get-Command -Name New-ScheduledTaskAction -ErrorAction SilentlyContinue) -and
            (Get-Command -Name New-ScheduledTaskPrincipal -ErrorAction SilentlyContinue) -and
            (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue) -and
            (Get-Command -Name Start-ScheduledTask -ErrorAction SilentlyContinue)
        if ($scheduledTaskCmdletsAvailable) {
            $action = New-ScheduledTaskAction -Execute $localPowerShell -Argument $arguments
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName $taskName
        }
        else {
            # Windows 7 besitzt nicht zuverlässig das ScheduledTasks-Modul;
            # schtasks.exe kann dort dieselbe einmalige SYSTEM-Aufgabe anlegen.
            $schtasks = Join-Path $env:WINDIR 'System32\schtasks.exe'
            if (-not (Test-Path -LiteralPath $schtasks -PathType Leaf)) {
                throw 'Weder ScheduledTasks-Cmdlets noch schtasks.exe sind verfügbar.'
            }
            $startAt = (Get-Date).AddMinutes(1)
            $startDate = $startAt.ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
            $startTime = $startAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            $taskCommand = '"{0}" {1}' -f $localPowerShell, $arguments
            $createOutput = & $schtasks /Create /TN $taskName /SC ONCE /SD $startDate /ST $startTime /RU SYSTEM /RL HIGHEST /TR $taskCommand /F 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Die JEA-Finalisierungsaufgabe konnte mit schtasks.exe nicht erstellt werden: $((@($createOutput) -join ' ').Trim())"
            }
            $runOutput = & $schtasks /Run /TN $taskName 2>&1
            if ($LASTEXITCODE -ne 0) {
                throw "Die JEA-Finalisierungsaufgabe konnte mit schtasks.exe nicht gestartet werden: $((@($runOutput) -join ' ').Trim())"
            }
        }
        Write-SetupLog 'JEA-Registrierung wurde in eine lokale SYSTEM-Task ausgelagert.' 'SUCCESS'
        $script:CertificateBootstrapHandoff = $true
        exit 0
    }

    # === Stabiles JEA-Trägermodul erstellen (FIX aus v3.2)
    # Verhindert "Role Capability not found" Fehler
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== JEA Role Capability Setup ===" "INFO"
    
    $JeaModuleName = "JEA_Updates"
    $JeaBaseDir    = "$env:ProgramFiles\WindowsPowerShell\Modules\$JeaModuleName"
    $RoleCapDir    = Join-Path $JeaBaseDir "RoleCapabilities"

    $JeaModuleFile = Join-Path $JeaBaseDir "$JeaModuleName.psm1"
    if ([string]::IsNullOrWhiteSpace($DeploymentVersion)) {
        # Die Verteilung übergibt die zentral ermittelte Version ausdrücklich.
        # Das Setup wird auf älteren Zielsystemen als einzelne Datei ausgeführt;
        # dort muss die Versionsfunktion aus dem übertragenen Fachmodul nicht
        # zwingend im Skriptbereich verfügbar sein.
        $deploymentVersionCommand = Get-Command -Name Get-WindowsUpdateAdmDeploymentVersion -ErrorAction SilentlyContinue
        if (-not $deploymentVersionCommand) {
            throw 'Keine WindowsUpdateAdm-Version übergeben und Get-WindowsUpdateAdmDeploymentVersion ist nicht verfügbar.'
        }
        $deploymentVersion = [string](Get-WindowsUpdateAdmDeploymentVersion)
    } else {
        $deploymentVersion = [string]$DeploymentVersion
    }
    if ([string]::IsNullOrWhiteSpace($deploymentVersion)) {
        throw 'Die WindowsUpdateAdm-Bereitstellungsversion ist leer.'
    }
    $JeaModuleSource = New-WindowsUpdateAdmDeploymentStatusModuleSource -Version $deploymentVersion -TargetBuild $targetBuild -ClientCertificateUris $script:ClientCertificateEndpointUris
    if (-not (Test-Path -LiteralPath $JeaBaseDir)) { New-Item -Path $JeaBaseDir -ItemType Directory -Force | Out-Null }
    [System.IO.File]::WriteAllText($JeaModuleFile, $JeaModuleSource, [System.Text.UTF8Encoding]::new($true))
    Write-SetupLog "JEA-Statusabfrage erstellt (Version $deploymentVersion): $JeaModuleFile" "SUCCESS"
    
    if (!(Test-Path $RoleCapDir)) { New-Item -Path $RoleCapDir -ItemType Directory -Force | Out-Null }
    
    $JeaManifest = Join-Path $JeaBaseDir "$JeaModuleName.psd1"
    $manifestExists = Test-Path -LiteralPath $JeaManifest -PathType Leaf
    $manifestNeedsRebuild = -not $manifestExists
    if ($manifestExists) {
        if ($ForceUpdate) {
            $manifestNeedsRebuild = $true
            Write-SetupLog 'Force-Update: JEA-Trägermodul-Manifest wird neu erstellt.' 'UPDATE'
        } else {
            try {
                Test-ModuleManifest -Path $JeaManifest -ErrorAction Stop | Out-Null
            }
            catch {
                $manifestNeedsRebuild = $true
                $manifestLength = (Get-Item -LiteralPath $JeaManifest -ErrorAction Stop).Length
                Write-SetupLog "Ungültiges JEA-Trägermodul-Manifest erkannt (Dateigröße: $manifestLength Byte); es wird gesichert und neu erstellt." 'WARN'
            }
        }
    }

    if ($manifestNeedsRebuild -and $manifestExists) {
        $manifestBackupDirectory = Join-Path $env:ProgramData 'WindowsUpdateAdm\Logs'
        if (-not (Test-Path -LiteralPath $manifestBackupDirectory -PathType Container)) {
            New-Item -Path $manifestBackupDirectory -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        $manifestBackupPath = Join-Path $manifestBackupDirectory ("JEA_Updates.psd1.invalid-{0}.bak" -f (Get-Date -Format 'yyyyMMdd_HHmmss_fff'))
        Copy-Item -LiteralPath $JeaManifest -Destination $manifestBackupPath -ErrorAction Stop
        Remove-Item -LiteralPath $JeaManifest -Force -ErrorAction Stop
        Write-SetupLog "Vorheriges JEA-Manifest zur Diagnose gesichert: $manifestBackupPath" 'INFO'
    }

    if ($manifestNeedsRebuild) {
        New-ModuleManifest -Path $JeaManifest `
                           -RootModule "$JeaModuleName.psm1" `
                           -Guid ([Guid]::NewGuid()) `
                           -Author "IT-Administration" `
                           -ModuleVersion "1.0" `
                           -FunctionsToExport @('Get-WindowsUpdateAdmDeploymentStatus') `
                           -Description "Stabiler JEA Endpunkt fuer Windows Update Verwaltung"
        Write-SetupLog "JEA-Trägermodul-Manifest neu erstellt: $JeaManifest" 'SUCCESS'
    } else {
        try {
            # Vorhandene Manifeste stammen teils aus älteren Verteilungen und
            # enthielten weder RootModule noch den Export der Statusfunktion.
            # Ohne beide Angaben wird die erzeugte .psm1 bei ModulesToImport
            # nicht mit der Statusfunktion in die JEA-Sitzung geladen.
            Update-ModuleManifest -Path $JeaManifest `
                                  -RootModule "$JeaModuleName.psm1" `
                                  -FunctionsToExport @('Get-WindowsUpdateAdmDeploymentStatus') `
                                  -ErrorAction Stop
            Write-SetupLog "JEA-Trägermodul-Manifest aktualisiert (RootModule und Statusfunktion): $JeaManifest" "SUCCESS"
        }
        catch {
            Write-SetupDiagnostic -Operation 'JEA-Trägermodul-Manifest' -ErrorRecord $_ -Context @("Path=$JeaManifest")
            throw 'JEA-Trägermodul-Manifest konnte nicht auf die Statusfunktion aktualisiert werden; Details stehen im Setup-Protokoll.'
        }
    }

    try {
        Test-ModuleManifest -Path $JeaManifest -ErrorAction Stop | Out-Null
        Write-SetupLog 'JEA-Trägermodul-Manifest ist gültig.' 'SUCCESS'
    }
    catch {
        Write-SetupDiagnostic -Operation 'JEA-Trägermodul-Manifest validieren' -ErrorRecord $_ -Context @("Path=$JeaManifest")
        throw 'Das JEA-Trägermodul-Manifest ist nach der Erstellung/Aktualisierung weiterhin ungültig.'
    }
    
    # Role Capability Datei erstellen
    $RoleCapabilityFile = Join-Path $RoleCapDir "WindowsUpdateRole.psrc"
    $CheckRoleCapabilityFile = Join-Path $RoleCapDir "WindowsUpdateCheckRole.psrc"
    
    $VisibleCmdlets = @(
        # Nur Updateverwaltung und die minimal für die Skriptblöcke nötigen
        # Pipeline-/Ausgabebefehle veröffentlichen. Keine Registry-Schreib-,
        # Modulimport-, Prozess-, Dienst-, WMI-/CIM- oder externen Befehle.
        'Get-WindowsUpdate',
        'Get-WURebootStatus',
        'Get-Command',
        'Select-Object',
        'Where-Object',
        'ForEach-Object',
        'Write-Output',
        'Write-Verbose',
        'Write-Warning',
        'Write-Host',
        'Out-Null',
        'Out-Default'
    )
    
    Write-SetupLog "Erlaubte Cmdlets: $($VisibleCmdlets.Count)" "INFO"
    
    # New-PSRoleCapabilityFile hat keinen -Force Parameter -> Datei vorher loeschen
    if (Test-Path $RoleCapabilityFile) {
        Remove-Item -Path $RoleCapabilityFile -Force -ErrorAction Stop
        Write-SetupLog "Alte Role Capability Datei entfernt" "INFO"
    }
    # ModuleVersion NICHT angeben - PowerShell findet das Modul sonst nicht wenn
    # es unter einem anderen Pfad installiert ist (z.B. SYSTEM-Profil vs. ProgramFiles)
    New-PSRoleCapabilityFile -Path $RoleCapabilityFile `
                             -ModulesToImport @('PSWindowsUpdate', $JeaModuleName) `
                             -VisibleCmdlets $VisibleCmdlets `
                             -VisibleFunctions @('Get-WindowsUpdateAdmDeploymentStatus') `
                             -VisibleExternalCommands @() `
                             -VisibleAliases @()
    Write-SetupLog "Role Capability erstellt: $RoleCapabilityFile" "SUCCESS"

    # Für geplante Checks unter SYSTEM authentifiziert sich der Verwaltungsserver
    # per Kerberos mit seinem Computerkonto. Diese Rolle erlaubt genau den vom
    # Check verwendeten Get-WindowsUpdate-Aufruf und keine Installations-Cmdlets.
    $checkRoleCmdlets = @(
        @{
            Name = 'Get-WindowsUpdate'
            Parameters = @(@{ Name = 'MicrosoftUpdate' })
        }
    )
    if (Test-Path -LiteralPath $CheckRoleCapabilityFile) {
        Remove-Item -LiteralPath $CheckRoleCapabilityFile -Force -ErrorAction Stop
    }
    New-PSRoleCapabilityFile -Path $CheckRoleCapabilityFile `
                             -ModulesToImport @('PSWindowsUpdate', $JeaModuleName) `
                             -VisibleCmdlets $checkRoleCmdlets `
                             -VisibleFunctions @('Get-WindowsUpdateAdmDeploymentStatus') `
                             -VisibleExternalCommands @() `
                             -VisibleAliases @()
    Write-SetupLog "Eingeschränkte Check-Rolle erstellt: $CheckRoleCapabilityFile" "SUCCESS"
    
    # =========================================================
    # === Session Configuration File erstellen (permanent im JEA-Modul)
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Session Configuration Setup ===" "INFO"
    
    $PermanentPSSC = Join-Path $JeaBaseDir "WindowsUpdateAdm.pssc"
    
    # New-PSSessionConfigurationFile hat keinen -Force Parameter -> Datei vorher loeschen
    if (Test-Path $PermanentPSSC) {
        Remove-Item -Path $PermanentPSSC -Force -ErrorAction Stop
        Write-SetupLog "Alte Session Configuration Datei entfernt" "INFO"
    }
    # Windows Server 2016 (Build 14393) verarbeitet JEA mit
    # RunAsVirtualAccount und WinRM-Clientzertifikaten nicht zuverlässig.
    # Das betrifft ausschließlich Nicht-AD-Systeme. AD-Systeme behalten auch
    # auf Server 2016 den virtuellen SYSTEM-Kontext, den Windows Update für
    # Download und Installation benötigt.
    $osBuild = [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber
    $sessionConfigurationParameters = @{
        Path              = $PermanentPSSC
        SessionType       = 'Default'
        ModulesToImport   = @('PSWindowsUpdate', $JeaModuleName)
        ExecutionPolicy   = 'RemoteSigned'
        LanguageMode      = 'ConstrainedLanguage'
    }
    if (-not $IsInDomain -and $osBuild -le 14393) {
        Write-SetupLog "Windows Server 2016-Kompatibilitätsmodus: JEA verwendet den zertifikatsgemappten Administrator-Kontext." "WARN"
    } else {
        $sessionConfigurationParameters['RunAsVirtualAccount'] = $true
        Write-SetupLog "JEA verwendet einen virtuellen SYSTEM-Kontext." "INFO"
    }
    New-PSSessionConfigurationFile @sessionConfigurationParameters
    Write-SetupLog "Session Configuration File erstellt: $PermanentPSSC" "SUCCESS"
    
    # Sprachunabhängige SID-Auflösung für Administratoren
    Write-SetupLog "Ermittle Administrators-Gruppe (SID S-1-5-32-544)..." "INFO"
    try {
        $AdminsSID  = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
        $AdminsName = $AdminsSID.Translate([System.Security.Principal.NTAccount]).Value
        Write-SetupLog "Administrators-Gruppe erkannt als: $AdminsName" "SUCCESS"
    }
    catch {
        Write-SetupLog "SID-Aufloesung fehlgeschlagen, versuche Fallback..." "WARN"
        foreach ($Name in @("$env:COMPUTERNAME\Administratoren","$env:COMPUTERNAME\Administrators","BUILTIN\Administratoren","BUILTIN\Administrators")) {
            try {
                $null = (New-Object System.Security.Principal.NTAccount($Name)).Translate([System.Security.Principal.SecurityIdentifier])
                $AdminsName = $Name
                Write-SetupLog "Administrators-Gruppe gefunden: $AdminsName" "SUCCESS"
                break
            } catch { continue }
        }
        if (-not $AdminsName) {
            $AdminsName = "BUILTIN\Administrators"
            Write-SetupLog "Fallback auf: $AdminsName" "WARN"
        }
    }
    
    # PSSC-Datei einlesen und RoleDefinitions hinzufügen
    Write-SetupLog "Fuege RoleDefinitions zur Session Configuration hinzu..." "INFO"
    $PsscContent = Get-Content $PermanentPSSC -Raw
    
    # Vorhandene RoleDefinitions entfernen, um Duplikate zu vermeiden
    $PsscContent = $PsscContent -replace 'RoleDefinitions = @\{.*?\}', ''
    
    $checkRoleDefinition = ''
    if (-not [string]::IsNullOrWhiteSpace($ManagementComputerAccount)) {
        if ($ManagementComputerAccount -notmatch '^[^\\]+\\[^\\]+\$$') {
            throw "Ungültiges Verwaltungsserver-Computerkonto: '$ManagementComputerAccount'. Erwartet wird DOMAIN\COMPUTER$."
        }
        if ($ManagementComputerSid -notmatch '^S-1-5-21-(?:\d+-){3}\d+$') {
            throw "Ungültige oder fehlende SID für das Verwaltungsserver-Computerkonto '$ManagementComputerAccount': '$ManagementComputerSid'. Die SID muss zentral aus AD übergeben werden."
        }

        # Windows PowerShell 5.1 versucht beim Registrieren einer PSSC,
        # RoleDefinitions-Schlüssel selbst per NTAccount in SIDs umzuwandeln.
        # Bei einem defekten/gestörten Domänen-Trust scheitert das selbst dann,
        # wenn eine explizite Endpoint-SDDL mit der bereits bekannten SID
        # übergeben wird. Deshalb wird die Rolle an eine lokale Gruppe gebunden
        # und die vom Verwaltungsserver zentral gelesene SID direkt als
        # Gruppenmitglied eingetragen (ohne Namensauflösung).
        $checkGroupName = 'WindowsUpdateAdmCheck'
        $localComputerEntry = [ADSI]("WinNT://$env:COMPUTERNAME,computer")
        try {
            $checkGroup = $localComputerEntry.Children.Find($checkGroupName, 'group')
        }
        catch {
            $checkGroup = $localComputerEntry.Create('group', $checkGroupName)
            $checkGroup.SetInfo()
            Write-SetupLog "Lokale JEA-Gruppe erstellt: $checkGroupName" "SUCCESS"
        }

        $nativeClassName = 'WUAdmNetApi_' + [guid]::NewGuid().ToString('N')
        $nativeSource = @"
using System;
using System.Runtime.InteropServices;
public static class $nativeClassName
{
    [DllImport("netapi32.dll", CharSet = CharSet.Unicode)]
    public static extern int NetLocalGroupAddMembers(string servername, string groupname, int level, IntPtr buffer, int totalentries);
}
"@
        $nativeType = Add-Type -TypeDefinition $nativeSource -PassThru -ErrorAction Stop
        $managerSidObject = [System.Security.Principal.SecurityIdentifier]::new($ManagementComputerSid)
        $managerSidBytes = New-Object byte[] $managerSidObject.BinaryLength
        $managerSidObject.GetBinaryForm($managerSidBytes, 0)
        $sidPointer = [IntPtr]::Zero
        $memberInfoPointer = [IntPtr]::Zero
        try {
            $sidPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal($managerSidBytes.Length)
            [Runtime.InteropServices.Marshal]::Copy($managerSidBytes, 0, $sidPointer, $managerSidBytes.Length)
            $memberInfoPointer = [Runtime.InteropServices.Marshal]::AllocHGlobal([IntPtr]::Size)
            [Runtime.InteropServices.Marshal]::WriteIntPtr($memberInfoPointer, $sidPointer)
            $addMemberMethod = $nativeType.GetMethod('NetLocalGroupAddMembers')
            $addMemberResult = $addMemberMethod.Invoke($null, [object[]]@($null, $checkGroupName, 0, $memberInfoPointer, 1))
            if ($addMemberResult -notin 0, 1378) {
                throw "Verwaltungsserver-SID konnte nicht zur lokalen JEA-Gruppe hinzugefügt werden (NetLocalGroupAddMembers: $addMemberResult)."
            }
        }
        finally {
            if ($memberInfoPointer -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($memberInfoPointer)
            }
            if ($sidPointer -ne [IntPtr]::Zero) {
                [Runtime.InteropServices.Marshal]::FreeHGlobal($sidPointer)
            }
        }

        $checkRolePrincipal = "$env:COMPUTERNAME\$checkGroupName"
        $operatingSystem = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
        if ([int]$operatingSystem.ProductType -eq 2) {
            # Domänencontroller besitzen keine lokale SAM. Die dort erstellte
            # Gruppe wird im Domänenkontext geführt, daher ist COMPUTERNAME\Gruppe
            # für RoleDefinitions nicht auflösbar. Den kanonischen Namen aus der
            # Gruppen-SID ermitteln, statt einen Domänennamen fest einzutragen.
            $checkGroup.RefreshCache(@('objectSid'))
            $checkGroupSidBytes = [byte[]]$checkGroup.Properties['objectSid'].Value
            if (-not $checkGroupSidBytes -or $checkGroupSidBytes.Length -eq 0) {
                throw "Die SID der JEA-Prüfgruppe '$checkGroupName' konnte auf dem Domänencontroller nicht gelesen werden."
            }
            $checkGroupSid = [System.Security.Principal.SecurityIdentifier]::new($checkGroupSidBytes, 0)
            $checkRolePrincipal = $checkGroupSid.Translate([System.Security.Principal.NTAccount]).Value
            if ([string]::IsNullOrWhiteSpace($checkRolePrincipal) -or
                $checkRolePrincipal -notmatch ('\\' + [regex]::Escape($checkGroupName) + '$')) {
                throw "Die JEA-Prüfgruppe konnte auf dem Domänencontroller nicht in einen gültigen Kontonamen übersetzt werden: '$checkRolePrincipal'."
            }
            Write-SetupLog "Domänencontroller erkannt; JEA-Prüfgruppe über SID als '$checkRolePrincipal' aufgelöst." 'INFO'
        }
        $escapedCheckRolePrincipal = $checkRolePrincipal.Replace("'", "''")
        $checkRoleDefinition = @"
    '$escapedCheckRolePrincipal' = @{
        RoleCapabilities = 'WindowsUpdateCheckRole'
    }
"@
        Write-SetupLog "Verwaltungsserver $ManagementComputerAccount (SID $ManagementComputerSid) ist Mitglied der lokalen JEA-Gruppe $checkGroupName; diese erhält ausschließlich die eingeschränkte Abfrage-Rolle." "INFO"
    }

    $certificateRoleDefinition = ''
    if (-not [string]::IsNullOrWhiteSpace($script:CertificateMappedPrincipal)) {
        $escapedCertificatePrincipal = $script:CertificateMappedPrincipal.Replace("'", "''")
        $certificateRoleDefinition = @"
    '$escapedCertificatePrincipal' = @{
        RoleCapabilities = 'WindowsUpdateRole'
    }
"@
    }

    $RoleDefinitionsBlock = @"

# Role Definitions for WindowsUpdateRole
RoleDefinitions = @{
    '$AdminsName' = @{
        RoleCapabilities = 'WindowsUpdateRole'
    }
$checkRoleDefinition$certificateRoleDefinition}
"@
    $PsscContent = [regex]::Replace(
        $PsscContent,
        '(\s*)}\s*$',
        [System.Text.RegularExpressions.MatchEvaluator]{
            param($match)
            $RoleDefinitionsBlock + "`n" + $match.Groups[1].Value + '}'
        }
    )
    Set-Content -Path $PermanentPSSC -Value $PsscContent -Force
    Write-SetupLog "RoleDefinitions erfolgreich eingefuegt" "SUCCESS"
    
    # =========================================================
    # === WinRM / Session Configuration registrieren
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== WinRM Endpunkt Registrierung ===" "INFO"
    
    $ExistingConfig    = Get-PSSessionConfiguration -Name 'WindowsUpdateAdm' -ErrorAction SilentlyContinue
    $NeedWinRMRestart  = $false
    
    if ($ExistingConfig) {
        Write-SetupLog "Entferne alte Configuration..." "INFO"
        try {
            Unregister-PSSessionConfiguration -Name 'WindowsUpdateAdm' -NoServiceRestart -Force -Confirm:$false -ErrorAction Stop
            Write-SetupLog "Alte Configuration entfernt" "SUCCESS"
            $NeedWinRMRestart = $true
        }
        catch {
            Write-SetupLog 'Alte WinRM-Endpunktregistrierung konnte nicht entfernt werden; Details im Setup-Protokoll.' 'WARN'
            Write-SetupDiagnostic -Operation 'WinRM-Endpunktbereinigung' -ErrorRecord $_
            $NeedWinRMRestart = $true
        }
    }
    
    # Prüfe WinRM-Plugin direkt
    try {
        $winrmCheckOutput = @(& winrm get 'winrm/config/plugin?Name=WindowsUpdateAdm' 2>&1)
        $winrmCheckExitCode = $LASTEXITCODE
        if ($winrmCheckExitCode -eq 0) {
            Write-SetupLog "Plugin in WinRM gefunden, entferne..." "INFO"
            $winrmDeleteOutput = @(& winrm delete 'winrm/config/plugin?Name=WindowsUpdateAdm' 2>&1)
            $winrmDeleteExitCode = $LASTEXITCODE
            if ($winrmDeleteExitCode -ne 0) {
                $deleteDetails = ($winrmDeleteOutput | ForEach-Object { ([string]$_).Trim() } | Where-Object { $_ }) -join ' | '
                Write-SetupLog "Altes WinRM-Plugin konnte nicht entfernt werden (Exit-Code $winrmDeleteExitCode); Setup wird abgebrochen." "ERROR"
                if ($deleteDetails) { Write-SetupLog "winrm delete-Ausgabe: $deleteDetails" "INFO" -LogOnly }
                throw "winrm delete für WindowsUpdateAdm ist mit Exit-Code $winrmDeleteExitCode fehlgeschlagen."
            }
            Write-SetupLog "Plugin aus WinRM entfernt" "SUCCESS"
            $NeedWinRMRestart = $true
        } else {
            Write-SetupLog "winrm get für das alte Plugin lieferte Exit-Code $winrmCheckExitCode; Ausgabe wird zur Diagnose protokolliert." "INFO" -LogOnly
            foreach ($line in $winrmCheckOutput) {
                $lineText = ([string]$line).Trim()
                if ($lineText) { Write-SetupLog "winrm get-Ausgabe: $lineText" "INFO" -LogOnly }
            }
        }
    } catch {
        Write-SetupLog 'Prüfung oder Bereinigung des alten WinRM-Plugins ist fehlgeschlagen; Setup wird abgebrochen.' 'ERROR'
        Write-SetupDiagnostic -Operation 'WinRM-Pluginprüfung und -bereinigung' -ErrorRecord $_
        throw
    }
    
    if ($NeedWinRMRestart) {
        if ($IsRemoteSetup) {
            Write-SetupLog "WinRM-Neustart wird bis zum Abschluss des Remote-Setups verschoben." "INFO"
        } else {
            Write-SetupLog "Starte WinRM neu..." "INFO"
            Restart-Service WinRM -Force -ErrorAction Stop
            Start-Sleep -Seconds 5
            if ((Get-Service WinRM).Status -ne 'Running') {
                Start-Service WinRM -ErrorAction Stop
                Start-Sleep -Seconds 3
            }
            Write-SetupLog "WinRM neu gestartet" "SUCCESS"
        }
    }
    
    # Neue Configuration registrieren
    Write-SetupLog "Registriere WindowsUpdateAdm Configuration..." "INFO"
    # PowerShell 7 (insbesondere die AppX-/Store-Version) verwendet für
    # Register-PSSessionConfiguration einen eigenen, geschützten SessionConfig-
    # Pfad. JEA/WinRM-Konfigurationen müssen deshalb auch bei einem lokalen
    # Start aus PowerShell 7 über Windows PowerShell 5.1 registriert werden.
    # Die Cmdlets geben dabei pauschale Neustart-/Trennungswarnungen aus,
    # obwohl -NoServiceRestart gesetzt ist und der Neustart unten gezielt
    # gesteuert wird. Nur diese vorsorglichen Warnungen werden unterdrückt;
    # Fehler bleiben durch -ErrorAction Stop sichtbar.
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $windowsPowerShell)) {
            throw "Windows PowerShell 5.1 wurde nicht gefunden: $windowsPowerShell"
        }
        $jeaAclEntries = @('(A;;GA;;;BA)')
        if (-not [string]::IsNullOrWhiteSpace($ManagementComputerSid)) {
            $jeaAclEntries += "(A;;GXGR;;;$ManagementComputerSid)"
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CertificateMappingSid)) {
            $jeaAclEntries += "(A;;GXGR;;;$script:CertificateMappingSid)"
        }
        $jeaSecurityDescriptorSddl = 'O:NSG:BAD:P{0}S:P(AU;FA;GA;;;WD)(AU;SA;GXGW;;;WD)' -f ($jeaAclEntries -join '')
        $registrationScript = @"
`$ErrorActionPreference = 'Stop'
Register-PSSessionConfiguration -Name 'WindowsUpdateAdm' -Path '$($PermanentPSSC.Replace("'", "''"))' -SecurityDescriptorSddl '$jeaSecurityDescriptorSddl' -NoServiceRestart -Confirm:`$false -WarningAction SilentlyContinue -ErrorAction Stop
"@
        $registrationEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($registrationScript))
        $registrationProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$registrationEncoded) -Wait -PassThru -WindowStyle Hidden
        if ($registrationProcess.ExitCode -ne 0) {
            throw "Register-PSSessionConfiguration über Windows PowerShell 5.1 fehlgeschlagen (Exit-Code $($registrationProcess.ExitCode))."
        }
        Write-SetupLog "Configuration über Windows PowerShell 5.1 registriert" "SUCCESS"
    }
    else {
        $jeaAclEntries = @('(A;;GA;;;BA)')
        if (-not [string]::IsNullOrWhiteSpace($ManagementComputerSid)) {
            $jeaAclEntries += "(A;;GXGR;;;$ManagementComputerSid)"
        }
        if (-not [string]::IsNullOrWhiteSpace($script:CertificateMappingSid)) {
            $jeaAclEntries += "(A;;GXGR;;;$script:CertificateMappingSid)"
        }
        $jeaSecurityDescriptorSddl = 'O:NSG:BAD:P{0}S:P(AU;FA;GA;;;WD)(AU;SA;GXGW;;;WD)' -f ($jeaAclEntries -join '')
        Register-PSSessionConfiguration -Name 'WindowsUpdateAdm' `
                                        -Path $PermanentPSSC `
                                        -SecurityDescriptorSddl $jeaSecurityDescriptorSddl `
                                        -NoServiceRestart `
                                        -Confirm:$false `
                                        -WarningAction SilentlyContinue `
                                        -ErrorAction Stop
    }
    Write-SetupLog "Configuration registriert" "SUCCESS"
    
    # WinRM Service neu starten zur Aktivierung
    if ($IsRemoteSetup) {
        Write-SetupLog "Plane WinRM-Neustart nach Abschluss der Remote-Verbindung..." "INFO"
        # Siehe oben: stets die Windows-PowerShell-Binärdatei, nie einen
        # PowerShell-7-AppX-Alias, für WinRM- und JEA-Systemaufgaben nutzen.
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (-not (Test-Path -LiteralPath $psExe)) {
            throw "Windows PowerShell 5.1 wurde nicht gefunden: $psExe"
        }
        Start-Process -FilePath $psExe `
            -ArgumentList '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 15; Restart-Service WinRM -Force"' `
            -WindowStyle Hidden
        Write-SetupLog "Configuration wird nach dem verzögerten WinRM-Neustart aktiviert." "SUCCESS"
    } else {
        Write-SetupLog "Aktiviere Configuration durch WinRM Neustart..." "INFO"
        Restart-Service WinRM -Force -ErrorAction Stop
        Start-Sleep -Seconds 3
        Write-SetupLog "Configuration aktiviert" "SUCCESS"
    }
    
    # =========================================================
    # === Finaler Verbindungstest
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Finaler Verbindungstest ===" "INFO"
    
    # Pruefe ob der Endpunkt korrekt registriert ist (ohne Loopback-Verbindung)
    if ($PSVersionTable.PSEdition -eq 'Core') {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $probeRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdateAdm-Probe-{0}' -f [guid]::NewGuid().ToString('N'))
        $probeOutputPath = Join-Path $probeRoot 'stdout.txt'
        $probeErrorPath = Join-Path $probeRoot 'stderr.txt'
        $probeProcess = $null
        try {
            if (-not (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf)) {
                throw "Windows PowerShell 5.1 wurde nicht gefunden: $windowsPowerShell"
            }
            New-Item -ItemType Directory -Path $probeRoot -Force -ErrorAction Stop | Out-Null
            $probeCommand = "(Get-PSSessionConfiguration -Name 'WindowsUpdateAdm' -ErrorAction SilentlyContinue).Name"
            $encodedProbeCommand = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($probeCommand))
            $probeProcess = Start-Process -FilePath $windowsPowerShell `
                -ArgumentList @('-NoProfile', '-NonInteractive', '-EncodedCommand', $encodedProbeCommand) `
                -Wait -PassThru -WindowStyle Hidden `
                -RedirectStandardOutput $probeOutputPath -RedirectStandardError $probeErrorPath -ErrorAction Stop
            $registrationProbe = if (Test-Path -LiteralPath $probeOutputPath -PathType Leaf) {
                @(Get-Content -LiteralPath $probeOutputPath -ErrorAction SilentlyContinue)
            } else { @() }
            if ($probeProcess.ExitCode -ne 0) {
                $probeErrorText = if (Test-Path -LiteralPath $probeErrorPath -PathType Leaf) {
                    (Get-Content -LiteralPath $probeErrorPath -Raw -ErrorAction SilentlyContinue).Trim()
                } else { '' }
                Write-SetupLog "WARN: PowerShell-5.1-Endpunktprüfung endete mit Exitcode $($probeProcess.ExitCode). $probeErrorText" 'WARN'
            }
        }
        finally {
            if ($probeProcess) { $probeProcess.Dispose() }
            Remove-Item -LiteralPath $probeRoot -Recurse -Force -ErrorAction SilentlyContinue
        }
        $RegisteredConfig = if (@($registrationProbe) -contains 'WindowsUpdateAdm') { [PSCustomObject]@{ Name = 'WindowsUpdateAdm' } } else { $null }
    }
    else {
        $RegisteredConfig = Get-PSSessionConfiguration -Name 'WindowsUpdateAdm' -ErrorAction SilentlyContinue
    }
    $RoleCapExists    = Test-Path (Join-Path $RoleCapDir "WindowsUpdateRole.psrc")
    $PSSCExists       = Test-Path $PermanentPSSC
    
    if ($RegisteredConfig -and $RoleCapExists -and $PSSCExists) {
        Write-SetupLog "Endpunkt registriert: $($RegisteredConfig.Name)" "SUCCESS"
        Write-SetupLog "Role Capability vorhanden: $RoleCapabilityFile" "SUCCESS"
        Write-SetupLog "Session Config vorhanden: $PermanentPSSC" "SUCCESS"
        
        if ($FinalizeJEA) {
            # Die einmalige JEA-Registrierung läuft als SYSTEM. Dieses Konto
            # ist nicht zwangsläufig durch die auf Administratoren begrenzte
            # Endpunkt-ACL zugelassen; ein lokaler WinRM-Aufruf würde daher
            # AccessDenied melden, obwohl der Endpunkt korrekt registriert ist.
            # Die tatsächliche Erreichbarkeit wird vom Verwaltungsserver aus
            # über die konfigurierte WinRM-Authentifizierung geprüft.
            Write-SetupLog 'Lokaler Loopback-Test im SYSTEM-Finalisierungskontext übersprungen; Endpunktprüfung erfolgt vom Verwaltungsserver.' 'INFO'
        } else {
            # Bei einem lokalen, interaktiven Setup ist der Loopback-Test
            # aussagekräftig. Ein Fehler bleibt eine Warnung, kein K.O.-Kriterium.
            try {
                $TestResult = Invoke-Command -ComputerName localhost -ConfigurationName WindowsUpdateAdm `
                                             -ScriptBlock { Get-Command Get-WindowsUpdate } `
                                             -ErrorAction Stop
                Write-SetupLog "Loopback-Verbindungstest erfolgreich - Get-WindowsUpdate erreichbar" "SUCCESS"
            }
            catch {
                Write-SetupLog 'Lokaler Loopback-Test nicht möglich; der Endpunkt ist registriert, externer Verbindungstest erforderlich.' 'WARN'
                Write-SetupDiagnostic -Operation 'WinRM-Loopback-Test' -ErrorRecord $_ -Context @('RemoteSetup=False', 'FinalizeJEA=False')
            }
        }
    } else {
        $Missing = @()
        if (-not $RegisteredConfig) { $Missing += "PSSessionConfiguration nicht registriert" }
        if (-not $RoleCapExists)    { $Missing += "Role Capability fehlt: $RoleCapabilityFile" }
        if (-not $PSSCExists)       { $Missing += "PSSC-Datei fehlt: $PermanentPSSC" }
        throw "Konfiguration unvollstaendig: $($Missing -join '; ')"
    }

    if ($TemporaryLocalAccountBootstrap -and $EnableClientCertificateRemoting) {
        Clear-WindowsUpdateLocalAccountTokenFilterPolicy -Reason 'JEA-Endpunkt erfolgreich finalisiert; temporäre Bootstrap-Ausnahme geschlossen'
    }
    
    # =========================================================
    # === Finale Übersicht
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "============================================================" "SUCCESS"
    if ($FinalizeJEA) {
        Write-SetupLog "Lokales Setup abgeschlossen; zentrale Endpunktprüfung folgt (WindowsUpdateAdm-Bereitstellungsversion $deploymentVersion)." "INFO"
    } else {
        Write-SetupLog "Setup erfolgreich abgeschlossen! (WindowsUpdateAdm-Bereitstellungsversion $deploymentVersion)." "SUCCESS"
    }
    Write-SetupLog "============================================================" "SUCCESS"
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Installierte Versionen ===" "INFO"
    
    $NuGetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if ($NuGetProvider) {
        Write-SetupLog "NuGet Provider: $($NuGetProvider.Version)" "INFO"
    } elseif ($offlineModulesPresent) {
        Write-SetupLog 'NuGet Provider: nicht installiert (Offline-Modulpakete verwendet; auf dem Ziel nicht erforderlich).' 'INFO'
    } else {
        Write-SetupLog 'NuGet Provider: nicht verfügbar; Online-Modulpflege auf diesem Ziel ist eingeschränkt.' 'WARN'
    }
    
    foreach ($TargetBase in @($PS5Path, $PS7Path)) {
    $Label = if ($TargetBase -contains "WindowsPowerShell") { "PS 5.1" } else { "PS 7  " }
    if (Test-Path $TargetBase) {
        # Wir schauen direkt nach den Versionsordnern (Zahlen)
        $Versions = Get-ChildItem -Path $TargetBase -Directory | 
                    Where-Object { $_.Name -match '^\d+(\.\d+)*' } | 
                    Sort-Object { [version]$_.Name } -Descending
        
        if ($Versions) {
            Write-SetupLog "PSWindowsUpdate ($Label): $($Versions[0].Name)" "INFO"
        } else {
            Write-SetupLog "PSWindowsUpdate ($Label): Ordner leer/keine Version" "WARN"
        }
    } else {
        Write-SetupLog "PSWindowsUpdate ($Label): Nicht installiert" "WARN"
    }
}

    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Configuration Details ===" "INFO"
    $Config = Get-PSSessionConfiguration -Name 'WindowsUpdateAdm' -ErrorAction SilentlyContinue
    if ($Config) {
        Write-SetupLog "Name:      $($Config.Name)" "INFO"
        Write-SetupLog "PSVersion: $($Config.PSVersion)" "INFO"
        Write-SetupLog "RunAsUser: Virtual Account - SYSTEM" "INFO"
        Write-SetupLog "JEA-Modul: $JeaBaseDir" "INFO"
        Write-SetupLog "Permission: $($Config.Permission)" "INFO"
    }

    if (-not $IsInDomain) {
        $winrmCert = Get-ChildItem "Cert:\LocalMachine\My" |
            Where-Object { $_.Subject -eq "CN=$env:COMPUTERNAME" } |
            Sort-Object NotAfter -Descending | Select-Object -First 1
        if ($winrmCert) {
            Write-SetupLog "" "INFO"
            Write-SetupLog "=== WinRM HTTPS Zertifikat ===" "INFO"
            Write-SetupLog "Thumbprint: $($winrmCert.Thumbprint)" "INFO"
            Write-SetupLog "Gültig bis: $($winrmCert.NotAfter.ToString('yyyy-MM-dd'))" "INFO"
        }
    }
    
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Test-Befehle ===" "INFO"
    Write-SetupLog "PowerShell 5.1:" "INFO"
    Write-SetupLog "  powershell.exe -Command `"Invoke-Command -ComputerName $env:COMPUTERNAME -ConfigurationName WindowsUpdateAdm -ScriptBlock { Get-WindowsUpdate }`"" "INFO"
    Write-SetupLog "" "INFO"
    Write-SetupLog "PowerShell 7:" "INFO"
    Write-SetupLog "  pwsh.exe -Command `"Invoke-Command -ComputerName $env:COMPUTERNAME -ConfigurationName WindowsUpdateAdm -ScriptBlock { Get-WindowsUpdate }`"" "INFO"
    Write-SetupLog "" "INFO"

    # Nicht-AD-Ziele werden ausschließlich von
    # Verteilung_WindowsUpdateAdmConfig.ps1 per WinRM eingerichtet.

    $script:SetupSucceeded = $true
    exit 0
}
catch {
    Write-SetupLog "" "INFO"
    Write-SetupLog "============================================================" "ERROR"
    Write-SetupLog "             FEHLER beim Setup                              " "ERROR"
    Write-SetupLog "============================================================" "ERROR"
    Write-SetupLog "" "INFO"
    Write-SetupLog "Setup fehlgeschlagen; vollständige Diagnose: $script:SetupLogPath" 'ERROR'
    Write-SetupDiagnostic -Operation 'WindowsUpdateAdm-Setup' -ErrorRecord $_
    Write-SetupLog "" "INFO"
    
    exit 1
}
finally {
    # Ein abgebrochener Bootstrap darf die globale Remote-UAC-Ausnahme nicht
    # offen lassen. Bei erfolgreicher Übergabe schließt die SYSTEM-Finalisierung
    # sie; diese selbst schließt sie immer, auch bei einem Fehler.
    if ($TemporaryLocalAccountBootstrap -and $EnableClientCertificateRemoting -and
        ($FinalizeJEA -or -not $script:CertificateBootstrapHandoff)) {
        try {
            Clear-WindowsUpdateLocalAccountTokenFilterPolicy -Reason 'Sicherheitsrückstellung im Finally-Pfad'
        }
        catch {
            Write-SetupLog 'FEHLER: LocalAccountTokenFilterPolicy konnte im Finally-Pfad nicht entfernt werden.' 'ERROR'
            Write-SetupDiagnostic -Operation 'Remote-UAC-Bootstrap zurückstellen' -ErrorRecord $_ -Context @('Sollzustand=unconfigured (Windows-Standard 0)', "FinalizeJEA=$FinalizeJEA")
        }
    }

    # Die SYSTEM-Task wird nur für die finale lokale JEA-Registrierung
    # angelegt und darf nach jedem Lauf – auch nach einem Fehler – nicht
    # bestehen bleiben.
    if ($FinalizeJEA) {
        try {
            $unregisterCommand = Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue
            if ($unregisterCommand) {
                $existingTask = $null
                try { $existingTask = Get-ScheduledTask -TaskName 'WindowsUpdateAdm-Finalize' -ErrorAction Stop }
                catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
                if ($existingTask) {
                    Unregister-ScheduledTask -TaskName 'WindowsUpdateAdm-Finalize' -Confirm:$false -ErrorAction Stop
                    $remainingTask = $null
                    try { $remainingTask = Get-ScheduledTask -TaskName 'WindowsUpdateAdm-Finalize' -ErrorAction Stop }
                    catch { if ($_.CategoryInfo.Category -ne 'ObjectNotFound') { throw } }
                    if ($remainingTask) {
                        throw 'Die temporäre JEA-Finalisierungsaufgabe ist nach dem Entfernen weiterhin registriert.'
                    }
                }
            }
            else {
                # Windows 7 bereinigt die einmalige Finalisierungsaufgabe über schtasks.exe.
                $schtasks = Join-Path $env:WINDIR 'System32\schtasks.exe'
                if (Test-Path -LiteralPath $schtasks -PathType Leaf) {
                    $queryOutput = @(& $schtasks /Query /TN 'WindowsUpdateAdm-Finalize' 2>&1)
                    $queryExitCode = $LASTEXITCODE
                    if ($queryExitCode -eq 0) {
                        $deleteOutput = @(& $schtasks /Delete /TN 'WindowsUpdateAdm-Finalize' /F 2>&1)
                        $deleteExitCode = $LASTEXITCODE
                        if ($deleteExitCode -ne 0) {
                            throw "schtasks.exe konnte die temporäre JEA-Finalisierungsaufgabe nicht löschen (Exitcode $deleteExitCode): $($deleteOutput -join ' ')"
                        }
                    }
                    elseif (($queryOutput -join ' ') -notmatch '(?i)(cannot find|does not exist|nicht gefunden|existiert nicht)') {
                        throw "Vorhandensein der temporären JEA-Finalisierungsaufgabe konnte nicht geprüft werden (Exitcode $queryExitCode): $($queryOutput -join ' ')"
                    }
                }
            }
        }
        catch {
            Write-SetupLog 'WARN: Temporäre JEA-Finalisierungsaufgabe konnte nicht sicher entfernt werden; Details stehen im Setup-Protokoll.' 'WARN'
            Write-SetupDiagnostic -Operation 'Temporäre JEA-Finalisierungsaufgabe entfernen' -ErrorRecord $_ -Context 'FinalizeJEA=true'
        }
    }
    # Zertifikatsvalidierung in jedem Fall wiederherstellen
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $OriginalCertificateCallback

    # Nach einem erfolgreichen Setup bleibt pro Ziel nur das neueste
    # Setup-Protokoll erhalten. Bei Fehlern bleiben ältere Logs zur Diagnose.
    if ($script:SetupSucceeded -and $script:SetupLogPath) {
        try {
            $setupLogDirectory = Split-Path -Parent $script:SetupLogPath
            $retention = Invoke-WindowsUpdateFileRetention `
                -Directory $setupLogDirectory `
                -Filter ("Setup_{0}_*.log" -f $env:COMPUTERNAME) `
                -KeepFiles 1
            if (@($retention.FailedFiles).Count -gt 0) {
                Write-Verbose 'Ältere erfolgreiche Setup-Protokolle konnten nicht vollständig bereinigt werden.'
            }
        }
        catch {
            Write-Verbose "Ältere erfolgreiche Setup-Protokolle konnten nicht bereinigt werden: $($_.Exception.Message)"
        }
    }
}
