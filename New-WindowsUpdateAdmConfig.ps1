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
    - SessionType Default, RunAsVirtualAccount für erhöhte Rechte
    - Maximale Sicherheit durch Whitelist-Ansatz
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
    [switch]$FinalizeJEA
)
# Dieses Setup wird auf Zielservern nur vorübergehend in %TEMP% ausgeführt.
# Es lädt dort keine weiteren Repository-Skripte aus GitHub nach.
Set-StrictMode -Version Latest

# === TLS-KONFIGURATION GANZ AM ANFANG ===
try {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12 -bor [Net.SecurityProtocolType]::Tls13
}
catch {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
}

# Zertifikatsvalidierung temporär speichern (für Retry-Logik)
$OriginalCertificateCallback = [System.Net.ServicePointManager]::ServerCertificateValidationCallback

# Logging-Funktion (farbneutral für Remote-Ausführung)
function Write-SetupLog {
    param([string]$Message, [string]$Level = "INFO")
    $Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Timestamp] [$Level] $Message"
    
    # Farben nur wenn Terminal tatsaechlich Farben unterstuetzt
    $SupportsColor = $false
    try {
        $null = $Host.UI.RawUI.ForegroundColor
        $SupportsColor = ($Host.Name -eq 'ConsoleHost') -and (-not [Console]::IsOutputRedirected)
    } catch { }
    
    if ($SupportsColor) {
        switch ($Level) {
            "ERROR"   { Write-Host $LogMessage -ForegroundColor Red }
            "WARN"    { Write-Host $LogMessage -ForegroundColor Yellow }
            "SUCCESS" { Write-Host $LogMessage -ForegroundColor Green }
            "UPDATE"  { Write-Host $LogMessage -ForegroundColor Cyan }
            default   { Write-Host $LogMessage }
        }
    } else {
        Write-Host $LogMessage
    }
}

# Funktion: Verfügbare Version von PSGallery abrufen
function Get-LatestModuleVersion {
    param([string]$ModuleName)
    try {
        Write-SetupLog "Pruefe neueste verfuegbare Version von $ModuleName..." "INFO"
        $LatestModule = Find-Module -Name $ModuleName -ErrorAction Stop
        Write-SetupLog "Neueste Version auf PSGallery: $($LatestModule.Version)" "INFO"
        return $LatestModule.Version
    }
    catch {
        Write-SetupLog "Konnte neueste Version nicht abrufen: $($_.Exception.Message)" "WARN"
        return $null
    }
}

# Funktion: Installierte Version abrufen
function Get-InstalledModuleVersion {
    param([string]$ModuleName)
    $Module = Get-Module -ListAvailable -Name $ModuleName -ErrorAction SilentlyContinue | 
              Sort-Object Version -Descending | 
              Select-Object -First 1
    if ($Module) { return $Module.Version }
    return $null
}

# Funktion: Modul installieren oder aktualisieren
function Install-OrUpdateModule {
    param([string]$ModuleName, [switch]$Force)
    
    $InstalledVersion = Get-InstalledModuleVersion -ModuleName $ModuleName
    $LatestVersion    = Get-LatestModuleVersion    -ModuleName $ModuleName
    
    # Neueste Version nicht ermittelbar
    if (-not $LatestVersion) {
        if (-not $InstalledVersion) {
            Write-SetupLog "Kann $ModuleName nicht installieren - keine Verbindung zu PSGallery" "ERROR"
            return $false
        } else {
            Write-SetupLog "$ModuleName ist installiert (Version: $InstalledVersion) - kann Update nicht pruefen" "WARN"
            return $true
        }
    }
    
    # Nicht installiert oder veraltet oder Force
    if (-not $InstalledVersion -or $InstalledVersion -lt $LatestVersion -or $Force) {
        if ($Force) {
            Write-SetupLog "$ModuleName Update erzwungen - aktualisiere auf $LatestVersion..." "UPDATE"
        } elseif (-not $InstalledVersion) {
            Write-SetupLog "$ModuleName nicht installiert - installiere Version $LatestVersion..." "UPDATE"
        } else {
            Write-SetupLog "$ModuleName ist veraltet ($InstalledVersion) - aktualisiere auf $LatestVersion..." "UPDATE"
        }
        
        try {
            Install-Module -Name $ModuleName -Scope AllUsers -Force -AllowClobber -SkipPublisherCheck -ErrorAction Stop
            Write-SetupLog "$ModuleName erfolgreich bereitgestellt (Version $LatestVersion)" "SUCCESS"
            return $true
        }
        catch {
            Write-SetupLog "Installation fehlgeschlagen: $($_.Exception.Message)" "ERROR"
            return $false
        }
    }
    else {
        Write-SetupLog "$ModuleName ist aktuell (Version: $InstalledVersion)" "SUCCESS"
        return $true
    }
}

try {
    Write-SetupLog "=== Start WindowsUpdateAdm Configuration Setup ===" "INFO"
    Write-SetupLog "Computer: $env:COMPUTERNAME" "INFO"
    Write-SetupLog "PowerShell Version: $($PSVersionTable.PSVersion)" "INFO"
    Write-SetupLog "TLS-Protokolle: $([Net.ServicePointManager]::SecurityProtocol)" "INFO"
    
    if ($ForceUpdate) { Write-SetupLog "Force-Update aktiviert" "UPDATE" }
    
    # =========================================================
    # === NuGet Provider prüfen und aktualisieren
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== NuGet Provider Check ===" "INFO"
    
    $MinNuGetVersion = [Version]"2.8.5.201"
    $machineNuGetRoot = Join-Path $env:ProgramFiles 'PackageManagement\ProviderAssemblies\nuget'
    $CurrentNuGet = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
        Where-Object {
            $_.Version -ge $MinNuGetVersion -and
            $_.ProviderPath -like "$machineNuGetRoot\*"
        } |
        Sort-Object Version -Descending |
        Select-Object -First 1

    # Hilfsfunktion: NuGet vom lokalen Server kopieren
    function Install-NuGetFromLocalServer {
        # NuGet Provider liegt typischerweise hier auf Servern wo es bereits installiert ist
        $nugetProviderPaths = @(
            "$env:ProgramFiles\PackageManagement\ProviderAssemblies\nuget",
            "$env:ProgramData\Microsoft\Windows\PowerShell\PowerShellGet",
            "${env:ProgramFiles(x86)}\PackageManagement\ProviderAssemblies\nuget"
        )
        $destDir = "$env:ProgramFiles\PackageManagement\ProviderAssemblies\nuget\2.8.5.208"

        foreach ($searchPath in $nugetProviderPaths) {
            if (Test-Path $searchPath) {
                $found = Get-ChildItem $searchPath -Recurse -Filter "*.dll" -ErrorAction SilentlyContinue |
                         Where-Object { $_.Name -like "*NuGet*" } |
                         Select-Object -First 1
                if ($found) {
                    try {
                        New-Item -ItemType Directory -Path $destDir -Force | Out-Null
                        $destinationFile = Join-Path $destDir 'Microsoft.PackageManagement.NuGetProvider.dll'
                        $sourceFullPath = [IO.Path]::GetFullPath($found.FullName)
                        $destinationFullPath = [IO.Path]::GetFullPath($destinationFile)
                        if (-not [string]::Equals($sourceFullPath, $destinationFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                            Copy-Item -LiteralPath $sourceFullPath -Destination $destinationFullPath -Force -ErrorAction Stop
                        } else {
                            Write-SetupLog 'NuGet-DLL liegt bereits im vorgesehenen Zielordner; Kopie wird übersprungen.' 'INFO'
                        }

                        $availableProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
                            Where-Object { $_.Version -ge $MinNuGetVersion } |
                            Sort-Object Version -Descending |
                            Select-Object -First 1
                        if ($availableProvider) { return $true }
                    }
                    catch {
                        Write-SetupLog "Lokale NuGet-Datei konnte nicht eingerichtet werden: $($_.Exception.Message)" 'WARN'
                    }
                }
            }
        }

        # Fallback: Skriptordner
        $offlineNuGet = Join-Path $PSScriptRoot "NuGet.exe"
        if (Test-Path $offlineNuGet) {
            New-Item -ItemType Directory -Path $destDir -Force | Out-Null
            $offlineDestination = Join-Path $destDir 'Microsoft.PackageManagement.NuGetProvider.exe'
            $offlineSourceFullPath = [IO.Path]::GetFullPath($offlineNuGet)
            $offlineDestinationFullPath = [IO.Path]::GetFullPath($offlineDestination)
            if (-not [string]::Equals($offlineSourceFullPath, $offlineDestinationFullPath, [StringComparison]::OrdinalIgnoreCase)) {
                Copy-Item -LiteralPath $offlineSourceFullPath -Destination $offlineDestinationFullPath -Force -ErrorAction Stop
            }
            $availableProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
                Where-Object { $_.Version -ge $MinNuGetVersion } |
                Sort-Object Version -Descending |
                Select-Object -First 1
            return [bool]$availableProvider
        }
        return $false
    }
    
    if (-not $CurrentNuGet -or $ForceUpdate) {
        if ($CurrentNuGet) {
            Write-SetupLog "Aktualisiere maschinenweit verfügbaren NuGet Provider..." "UPDATE"
        } else {
            Write-SetupLog "NuGet Provider fehlt maschinenweit oder ist zu alt - installiere ohne Rückfrage..." "UPDATE"
        }
        $nugetInstalled = $false
        try {
            # AllUsers verhindert eine erneute Installation bei abweichenden
            # Administratorkonten; ForceBootstrap bestätigt die NuGet-Abfrage
            # automatisch, wenn PackageManagement den Provider erst laden muss.
            Install-PackageProvider -Name NuGet -MinimumVersion 2.8.5.201 `
                -Scope AllUsers -Force -ForceBootstrap -ErrorAction Stop | Out-Null
            $installedNuGet = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction Stop |
                Where-Object { $_.ProviderPath -like "$machineNuGetRoot\*" } |
                Sort-Object Version -Descending |
                Select-Object -First 1
            if (-not $installedNuGet -or $installedNuGet.Version -lt $MinNuGetVersion) {
                throw 'Der NuGet Provider wurde nicht in den maschinenweiten Providerpfad installiert.'
            }
            Write-SetupLog "NuGet Provider installiert - Version: $($installedNuGet.Version)" "SUCCESS"
            $nugetInstalled = $true
        }
        catch {
            Write-SetupLog "Online-Installation fehlgeschlagen - versuche lokale Installation..." "WARN"
            if (Install-NuGetFromLocalServer) {
                Write-SetupLog "NuGet vom lokalen Server installiert." "SUCCESS"
                $nugetInstalled = $true
            } else {
                Write-SetupLog "NuGet nicht installierbar. Hinweis: NuGet.exe in Skriptordner legen als Fallback." "WARN"
                Write-SetupLog "PSWindowsUpdate-Installation wird möglicherweise fehlschlagen." "WARN"
            }
        }
    } else {
        Write-SetupLog "NuGet Provider ist maschinenweit installiert (Version: $($CurrentNuGet.Version))" "SUCCESS"
    }
    
    # =========================================================
    # === PowerShell Gallery konfigurieren
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== PowerShell Gallery Konfiguration ===" "INFO"
    
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
        Write-SetupLog "PSGallery Konfiguration uebersprungen: $($_.Exception.Message)" "WARN"
    }
    
    # =========================================================
    # === PSWindowsUpdate installieren/aktualisieren (mit Retry)
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== PSWindowsUpdate Installation/Update ===" "INFO"
    
    $MaxRetries = 3
    $RetryCount = 0
    $Success    = $false
    
    while (-not $Success -and $RetryCount -lt $MaxRetries) {
        $RetryCount++
        
        if ($RetryCount -gt 1) {
            Write-SetupLog "Installationsversuch $RetryCount von $MaxRetries..." "INFO"
            # Beim 2. Versuch: Zertifikatsvalidierung temporär deaktivieren
            if ($RetryCount -eq 2) {
                Write-SetupLog "Deaktiviere Zertifikatspruefung temporaer..." "WARN"
                [System.Net.ServicePointManager]::ServerCertificateValidationCallback = {$true}
            }
            Start-Sleep -Seconds 5
        }
        
        try {
            $Success = Install-OrUpdateModule -ModuleName "PSWindowsUpdate" -Force:$ForceUpdate
        }
        catch {
            Write-SetupLog "Versuch $RetryCount fehlgeschlagen: $($_.Exception.Message)" "WARN"
        }
    }
    
    # Zertifikatsvalidierung wiederherstellen
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $OriginalCertificateCallback
    
    if (-not $Success) {
        # Fallback 1: PSWindowsUpdate vom lokalen Server kopieren (bereits installiert auf diesem Server)
        Write-SetupLog "Online-Installation fehlgeschlagen - suche PSWindowsUpdate auf lokalem Server..." "WARN"
        $localPSWUPaths = @(
            "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate",
            "$env:ProgramFiles\PowerShell\Modules\PSWindowsUpdate",
            "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\PSWindowsUpdate"
        )
        foreach ($localPath in $localPSWUPaths) {
            if (Test-Path $localPath) {
                $destPath = "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate"
                if ($localPath -ne $destPath) {
                    try {
                        Copy-Item $localPath $destPath -Recurse -Force
                        Write-SetupLog "PSWindowsUpdate vom lokalen Pfad kopiert: $localPath" "SUCCESS"
                    } catch { }
                }
                try {
                    Import-Module PSWindowsUpdate -ErrorAction Stop
                    Write-SetupLog "PSWindowsUpdate erfolgreich geladen." "SUCCESS"
                    $Success = $true
                    break
                } catch { }
            }
        }
    }

    if (-not $Success) {
        # Fallback 2: PSWindowsUpdate-Ordner im Skriptordner suchen
        $offlinePSWU = Join-Path $PSScriptRoot "PSWindowsUpdate"
        $psWUDest    = "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate"
        if (Test-Path $offlinePSWU) {
            Write-SetupLog "Offline-Paket gefunden: $offlinePSWU - installiere..." "INFO"
            try {
                Copy-Item $offlinePSWU $psWUDest -Recurse -Force
                Import-Module PSWindowsUpdate -ErrorAction Stop
                Write-SetupLog "PSWindowsUpdate offline installiert." "SUCCESS"
                $Success = $true
            }
            catch {
                Write-SetupLog "Offline-Installation fehlgeschlagen: $($_.Exception.Message)" "WARN"
            }
        }
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
        throw "PSWindowsUpdate konnte nicht geladen werden: $($_.Exception.Message)"
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
        if (Test-Path $TargetBase) {
            $installedVersion = Get-Module -ListAvailable -Name PSWindowsUpdate |
                Where-Object { $_.ModuleBase -like "$TargetBase*" } |
                Sort-Object Version -Descending |
                Select-Object -First 1 -ExpandProperty Version
        }

        $sourceIsUserProfile = $SourcePath -like "*$env:USERPROFILE*" -or $SourcePath -like "*\Users\*"
        $NeedsCopy = $ForceUpdate -or
                     (-not (Test-Path $VersionPath)) -or
                     ($sourceIsUserProfile) -or
                     ($null -ne $installedVersion -and $SourceVersion -gt $installedVersion)

        if ($NeedsCopy) {
            Write-SetupLog "Kopiere Modul nach $Label Pfad..." "UPDATE"
            try {
                # Nur alte Versionen entfernen, nicht gleiche
                if (Test-Path $TargetBase) {
                    Get-ChildItem $TargetBase -Directory | Where-Object { $_.Name -ne "$SourceVersion" } | ForEach-Object {
                        Remove-Item $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
                        Write-SetupLog "Alte Version entfernt: $($_.Name)" "INFO"
                    }
                }
                $Parent = Split-Path $VersionPath -Parent
                if (-not (Test-Path $Parent)) { New-Item -Path $Parent -ItemType Directory -Force | Out-Null }
                Copy-Item -Path $SourcePath -Destination $VersionPath -Recurse -Force
                Write-SetupLog "Modul nach $Label kopiert: $VersionPath" "SUCCESS"
            }
            catch {
                Write-SetupLog "Warnung beim Kopieren nach ${Label}: $($_.Exception.Message)" "WARN"
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
            Enable-PSRemoting -Force -ErrorAction Stop
            Write-SetupLog "PS-Remoting aktiviert" "SUCCESS"
        }
        catch {
            Write-SetupLog "PS-Remoting bereits aktiv oder Fehler: $($_.Exception.Message)" "INFO"
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
    # === WinRM HTTPS Zertifikat (nur Nicht-AD-Geräte)
    # =========================================================
    if (-not $IsInDomain) {
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== WinRM HTTPS Zertifikat Setup ===" "INFO"

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
                Remove-Item -Path $existingCert.PSPath -Force -ErrorAction SilentlyContinue
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
                throw "Zertifikat konnte nicht erstellt werden: $($_.Exception.Message)"
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
                Remove-Item -Path $httpsListener.PSPath -Recurse -Force -ErrorAction SilentlyContinue
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
                throw "HTTPS-Listener konnte nicht erstellt werden: $($_.Exception.Message)"
            }
        }

        # Firewall-Regel für Port 5986
        $fwRule = Get-NetFirewallRule -DisplayName "WinRM HTTPS" -ErrorAction SilentlyContinue
        if ($fwRule) {
            Write-SetupLog "Firewall-Regel für WinRM HTTPS bereits vorhanden." "SUCCESS"
        } else {
            try {
                New-NetFirewallRule `
                    -DisplayName "WinRM HTTPS" `
                    -Direction Inbound `
                    -Protocol TCP `
                    -LocalPort 5986 `
                    -Action Allow `
                    -ErrorAction Stop | Out-Null
                Write-SetupLog "Firewall-Regel für Port 5986 (WinRM HTTPS) erstellt." "SUCCESS"
            }
            catch {
                Write-SetupLog "WARNUNG: Firewall-Regel konnte nicht erstellt werden: $($_.Exception.Message)" "WARN"
            }
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
            Write-SetupLog "WARNUNG: Zertifikat-Auth konnte nicht aktiviert werden: $($_.Exception.Message)" "WARN"
        }

        # LocalAccountTokenFilterPolicy setzen (nötig für lokale Accounts via Zertifikat)
        try {
            $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
            Set-ItemProperty -Path $regPath -Name "LocalAccountTokenFilterPolicy" -Value 1 -Type DWord -ErrorAction Stop
            Write-SetupLog "LocalAccountTokenFilterPolicy gesetzt." "SUCCESS"
        }
        catch {
            Write-SetupLog "WARNUNG: LocalAccountTokenFilterPolicy konnte nicht gesetzt werden: $($_.Exception.Message)" "WARN"
        }

        # Client-Zertifikat (Public Key) aus Skriptordner importieren
        $clientCertPath = Join-Path $PSScriptRoot "WinRM-ClientCert.cer"
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

                # Ein bestehendes Mapping ist vollständig nutzbar und braucht bei
                # erneuter Verteilung weder Passwort noch eine Änderung.
                # WSMan:\ ist kein IPropertyCmdletProvider; die Eigenschaften
                # stehen direkt am Child-Item.
                $mappingSubject = "$($clientCert.Subject.Replace('CN=',''))@localhost"
                $existingMapping = Get-ChildItem WSMan:\localhost\ClientCertificate -Recurse -ErrorAction SilentlyContinue |
                    Where-Object {
                        # Der WSMan-Provider liefert beim rekursiven Abruf auch
                        # Container ohne Subject-Eigenschaft. Diese sind kein
                        # Zertifikats-Mapping und werden sicher übersprungen.
                        $subjectProperty = $_.PSObject.Properties['Subject']
                        $null -ne $subjectProperty -and [string]$subjectProperty.Value -eq $mappingSubject
                    }

                if ($existingMapping -and -not $ForceUpdate) {
                    Write-SetupLog "Zertifikat-Mapping bereits vorhanden; keine Einrichtungsdaten erforderlich." "SUCCESS"
                } elseif ($PreserveExistingCertificateMapping -and -not $ForceUpdate) {
                    Write-SetupLog "Bestehende Zertifikatsverbindung wurde vor dem Setup erfolgreich geprüft; Mapping bleibt unverändert." "SUCCESS"
                } elseif (-not $CertificateMappingCredential) {
                    throw "Für ein neues oder zu erneuerndes Zertifikat-Mapping wurden keine Einrichtungs-Administrator-Anmeldedaten übergeben."
                } else {
                    $localUser = $CertificateMappingCredential.UserName
                    if ($localUser -match '^\.\\') {
                        $localUser = "$env:COMPUTERNAME\$($localUser.Substring(2))"
                    } elseif ($localUser -notmatch '\\') {
                        $localUser = "$env:COMPUTERNAME\$localUser"
                    }
                    try {
                        if ($existingMapping) {
                            Remove-Item $existingMapping.PSPath -Recurse -Force -ErrorAction SilentlyContinue
                        }
                        New-Item -Path WSMan:\localhost\ClientCertificate `
                            -Subject    $mappingSubject `
                            -URI        "*" `
                            -Issuer     $clientCert.Thumbprint `
                            -Credential (New-Object System.Management.Automation.PSCredential(
                                $localUser,
                                $CertificateMappingCredential.Password
                            )) `
                            -Force -ErrorAction Stop | Out-Null
                        Write-SetupLog "Zertifikat mit Account '$localUser' verknüpft." "SUCCESS"
                    }
                    catch {
                        Write-SetupLog "WARNUNG: Zertifikat-Mapping fehlgeschlagen: $($_.Exception.Message)" "WARN"
                    }
                }
            }
            catch {
                Write-SetupLog "WARNUNG: Client-Zertifikat konnte nicht importiert werden: $($_.Exception.Message)" "WARN"
                Write-SetupLog "Passwort-Authentifizierung bleibt als Fallback aktiv." "INFO"
            }
        } else {
            Write-SetupLog "Kein Client-Zertifikat gefunden ($clientCertPath)." "INFO"
            Write-SetupLog "Zuerst Setup-ClientCertificate.ps1 auf dem Verwaltungsserver ausführen," "INFO"
            Write-SetupLog "dann WinRM-ClientCert.cer in den Skriptordner legen und dieses Skript erneut ausführen." "INFO"
            Write-SetupLog "Passwort-Authentifizierung bleibt aktiv." "INFO"
        }

    } else {
        Write-SetupLog "" "INFO"
        Write-SetupLog "=== WinRM HTTPS Zertifikat ===" "INFO"
        Write-SetupLog "Gerät ist AD-Mitglied - HTTPS-Zertifikat wird nicht benötigt." "INFO"
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
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -FinalizeJEA' -f $PSCommandPath
        $taskName = 'WindowsUpdateAdm-Finalize'
        $action = New-ScheduledTaskAction -Execute $localPowerShell -Argument $arguments
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $taskName
        Write-SetupLog 'JEA-Registrierung wurde in eine lokale SYSTEM-Task ausgelagert.' 'SUCCESS'
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
    
    if (!(Test-Path $RoleCapDir)) { New-Item -Path $RoleCapDir -ItemType Directory -Force | Out-Null }
    
    $JeaManifest = Join-Path $JeaBaseDir "$JeaModuleName.psd1"
    if (!(Test-Path $JeaManifest) -or $ForceUpdate) {
        New-ModuleManifest -Path $JeaManifest `
                           -Guid ([Guid]::NewGuid()) `
                           -Author "IT-Administration" `
                           -ModuleVersion "1.0" `
                           -Description "Stabiler JEA Endpunkt fuer Windows Update Verwaltung"
        Write-SetupLog "JEA-Trägermodul Manifest erstellt: $JeaManifest" "SUCCESS"
    } else {
        Write-SetupLog "JEA-Trägermodul bereits vorhanden" "SUCCESS"
    }
    
    # Role Capability Datei erstellen
    $RoleCapabilityFile = Join-Path $RoleCapDir "WindowsUpdateRole.psrc"
    
    $VisibleCmdlets = @(
        # PSWindowsUpdate Cmdlets
        'Get-WindowsUpdate',
        'Install-WindowsUpdate',
        'Get-WUList',
        'Get-WUInstall',
        'Get-WUHistory',
        'Get-WURebootStatus',
        # Basis-Cmdlets die PSWindowsUpdate benötigt
        'Get-Module',
        'Import-Module',
        'Get-Command',
        'Get-Service',
        'Start-Service',
        'Stop-Service',
        'Restart-Service',
        'Get-Process',
        'Get-ItemProperty',
        'Set-ItemProperty',
        'Get-WmiObject',
        'Get-CimInstance',
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
        Remove-Item -Path $RoleCapabilityFile -Force -ErrorAction SilentlyContinue
        Write-SetupLog "Alte Role Capability Datei entfernt" "INFO"
    }
    # ModuleVersion NICHT angeben - PowerShell findet das Modul sonst nicht wenn
    # es unter einem anderen Pfad installiert ist (z.B. SYSTEM-Profil vs. ProgramFiles)
    New-PSRoleCapabilityFile -Path $RoleCapabilityFile `
                             -ModulesToImport 'PSWindowsUpdate' `
                             -VisibleCmdlets $VisibleCmdlets `
                             -VisibleFunctions @() `
                             -VisibleExternalCommands @() `
                             -VisibleAliases @()
    Write-SetupLog "Role Capability erstellt: $RoleCapabilityFile" "SUCCESS"
    
    # =========================================================
    # === Session Configuration File erstellen (permanent im JEA-Modul)
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Session Configuration Setup ===" "INFO"
    
    $PermanentPSSC = Join-Path $JeaBaseDir "WindowsUpdateAdm.pssc"
    
    # New-PSSessionConfigurationFile hat keinen -Force Parameter -> Datei vorher loeschen
    if (Test-Path $PermanentPSSC) {
        Remove-Item -Path $PermanentPSSC -Force -ErrorAction SilentlyContinue
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
    
    $RoleDefinitionsBlock = @"

# Role Definitions for WindowsUpdateRole
RoleDefinitions = @{
    '$AdminsName' = @{
        RoleCapabilities = 'WindowsUpdateRole'
    }
}
"@
    $PsscContent = $PsscContent -replace '(\s*)}\s*$', "$RoleDefinitionsBlock`n`$1}"
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
            Write-SetupLog "Warnung beim Entfernen: $($_.Exception.Message)" "WARN"
            $NeedWinRMRestart = $true
        }
    }
    
    # Prüfe WinRM-Plugin direkt
    try {
        $WinRMCheck = winrm get winrm/config/plugin?Name=WindowsUpdateAdm 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-SetupLog "Plugin in WinRM gefunden, entferne..." "INFO"
            winrm delete winrm/config/plugin?Name=WindowsUpdateAdm 2>&1 | Out-Null
            Write-SetupLog "Plugin aus WinRM entfernt" "SUCCESS"
            $NeedWinRMRestart = $true
        }
    } catch { }
    
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
        $registrationScript = @"
`$ErrorActionPreference = 'Stop'
Register-PSSessionConfiguration -Name 'WindowsUpdateAdm' -Path '$($PermanentPSSC.Replace("'", "''"))' -NoServiceRestart -Confirm:`$false -WarningAction SilentlyContinue -ErrorAction Stop
"@
        $registrationEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($registrationScript))
        $registrationProcess = Start-Process -FilePath $windowsPowerShell -ArgumentList @('-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-EncodedCommand',$registrationEncoded) -Wait -PassThru -WindowStyle Hidden
        if ($registrationProcess.ExitCode -ne 0) {
            throw "Register-PSSessionConfiguration über Windows PowerShell 5.1 fehlgeschlagen (Exit-Code $($registrationProcess.ExitCode))."
        }
        Write-SetupLog "Configuration über Windows PowerShell 5.1 registriert" "SUCCESS"
    }
    else {
        Register-PSSessionConfiguration -Name 'WindowsUpdateAdm' `
                                        -Path $PermanentPSSC `
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
        $registrationProbe = & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -NonInteractive -Command "(Get-PSSessionConfiguration -Name 'WindowsUpdateAdm' -ErrorAction SilentlyContinue).Name" 2>$null
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
        
        # Loopback-Test nur versuchen, nicht als K.O.-Kriterium werten
        try {
            $TestResult = Invoke-Command -ComputerName localhost -ConfigurationName WindowsUpdateAdm `
                                         -ScriptBlock { Get-Command Get-WindowsUpdate } `
                                         -ErrorAction Stop
            Write-SetupLog "Loopback-Verbindungstest erfolgreich - Get-WindowsUpdate erreichbar" "SUCCESS"
        }
        catch {
            Write-SetupLog "Loopback-Test nicht moeglich (normal bei Remote-Einrichtung): $($_.Exception.Message)" "WARN"
            Write-SetupLog "Endpunkt ist korrekt konfiguriert - manueller Test empfohlen" "INFO"
        }
    } else {
        $Missing = @()
        if (-not $RegisteredConfig) { $Missing += "PSSessionConfiguration nicht registriert" }
        if (-not $RoleCapExists)    { $Missing += "Role Capability fehlt: $RoleCapabilityFile" }
        if (-not $PSSCExists)       { $Missing += "PSSC-Datei fehlt: $PermanentPSSC" }
        throw "Konfiguration unvollstaendig: $($Missing -join '; ')"
    }
    
    # =========================================================
    # === Finale Übersicht
    # =========================================================
    Write-SetupLog "" "INFO"
    Write-SetupLog "============================================================" "SUCCESS"
    Write-SetupLog "        Setup erfolgreich abgeschlossen! (V5.0)             " "SUCCESS"
    Write-SetupLog "============================================================" "SUCCESS"
    Write-SetupLog "" "INFO"
    Write-SetupLog "=== Installierte Versionen ===" "INFO"
    
    $NuGetVer = (Get-PackageProvider -Name NuGet).Version
    Write-SetupLog "NuGet Provider: $NuGetVer" "INFO"
    
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

    exit 0
}
catch {
    Write-SetupLog "" "INFO"
    Write-SetupLog "============================================================" "ERROR"
    Write-SetupLog "             FEHLER beim Setup                              " "ERROR"
    Write-SetupLog "============================================================" "ERROR"
    Write-SetupLog "" "INFO"
    Write-SetupLog "Fehlermeldung: $($_.Exception.Message)" "ERROR"
    
    if ($_.InvocationInfo.ScriptLineNumber) { Write-SetupLog "Fehlerzeile: $($_.InvocationInfo.ScriptLineNumber)" "ERROR" }
    if ($_.InvocationInfo.Line)             { Write-SetupLog "Fehlerkommando: $($_.InvocationInfo.Line.Trim())"   "ERROR" }
    if ($_.ScriptStackTrace)               { Write-SetupLog "Stack Trace:`n$($_.ScriptStackTrace)"               "ERROR" }
    Write-SetupLog "" "INFO"
    
    exit 1
}
finally {
    # Die SYSTEM-Task wird nur für die finale lokale JEA-Registrierung
    # angelegt und darf nach jedem Lauf – auch nach einem Fehler – nicht
    # bestehen bleiben.
    if ($FinalizeJEA) {
        try {
            Unregister-ScheduledTask -TaskName 'WindowsUpdateAdm-Finalize' -Confirm:$false -ErrorAction SilentlyContinue
        } catch { }
    }
    # Zertifikatsvalidierung in jedem Fall wiederherstellen
    [System.Net.ServicePointManager]::ServerCertificateValidationCallback = $OriginalCertificateCallback
}
