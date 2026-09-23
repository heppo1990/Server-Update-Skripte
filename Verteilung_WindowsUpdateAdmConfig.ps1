#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Verteilung_WindowsUpdateAdmConfig.ps1
    Verteilt New-WindowsUpdateAdmConfig.ps1 auf alle Windows-Server im AD

.DESCRIPTION
    - Überträgt das Setup per WinRM
    - Verwendet Kerberos für AD-Geräte und Client-Zertifikate für Nicht-AD-Geräte
    - Protokolliert Erfolg/Fehler pro Server
    - Raeumt temporaere Dateien auf
    - Liest Ziele über default_settings.json, settings.json und optional
      Verteilung_WindowsUpdateAdmConfig.settings.json

.NOTES
    FileName: Verteilung_WindowsUpdateAdmConfig.ps1
    Requires: ActiveDirectory-Modul (optional für AD-Ermittlung)
              Administrator-Rechte
#>

[CmdletBinding()]
param(
    # Beschränkt die Verteilung auf genau ein Windows-Ziel. Linux und Home
    # Assistant werden in diesem Modus bewusst nicht zusätzlich eingerichtet.
    [string]$TargetComputer,
    # Bereinigt ausschließlich alte, eindeutig markierte Temp-Ablagen auf den
    # Remote-Zielen und überspringt die erneute WindowsUpdateAdm-Einrichtung.
    [switch]$CleanupLegacyTempOnly
)
# GitHub-Update beim Start: Die eingebundene Routine lädt nur benötigte Skriptdateien.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $scriptUpdateTemporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $scriptUpdateTemporaryPath -ErrorAction Stop
        Move-Item -LiteralPath $scriptUpdateTemporaryPath -Destination $scriptUpdatePath -Force -ErrorAction Stop
    }
    catch {
        Remove-Item -LiteralPath ($scriptUpdatePath + '.download') -Force -ErrorAction SilentlyContinue
        Write-Warning 'GitHub-Updater nicht erreichbar; vorhandene Skriptversion wird ausgeführt.'
    }
}
$scriptUpdateLoaded = $false
if (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf) {
    try {
        . $scriptUpdatePath
        $scriptUpdateLoaded = [bool](Get-Command -Name 'Invoke-ServerUpdateScripts' -CommandType Function -ErrorAction SilentlyContinue)
    }
    catch {
        Write-Warning "GitHub-Updater konnte nicht geladen werden; vorhandene Skriptversion wird ausgeführt. Ursache: $($_.Exception.Message)"
    }
}
if ($scriptUpdateLoaded) {
    Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RemainingArguments $args
}



Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

# Konfiguration
$PSSCfgSkriptFile = "New-WindowsUpdateAdmConfig.ps1"
$ScriptName = [IO.Path]::GetFileNameWithoutExtension($PSCommandPath)

function Write-DeployLog {
    param([string]$Message)
    Write-Host $Message -ForegroundColor Gray
}

$Settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $ScriptName -WriteLog { param($message) Write-DeployLog $message }
$UpdateSettings = $Settings.UpdateSettings
$TargetComputers = $UpdateSettings.TargetComputers
if ([string]::IsNullOrWhiteSpace($TargetComputers)) {
    $TargetComputers = "Server"
}

# Header
Write-Host "`n+=======================================+" -ForegroundColor Cyan
Write-Host "|  WindowsUpdateAdm Config Verteilung   |" -ForegroundColor Cyan
Write-Host "+=======================================+`n" -ForegroundColor Cyan

# Voraussetzungen pruefen
if (-not (Test-Path "$PSScriptRoot\$PSSCfgSkriptFile")) {
    Write-Host "FEHLER: Setup-Skript nicht gefunden: $PSScriptRoot\$PSSCfgSkriptFile" -ForegroundColor Red
    exit 1
}

# Die zentrale Zielermittlung liefert exakt dieselbe Zielmenge wie Check,
# Download und Installation. Für die Verteilung wird nur der Verbindungstyp
# aus den Markierungen abgeleitet.
$Serverlist = Get-WindowsUpdateTargets -UpdateSettings $UpdateSettings -TargetComputers $TargetComputers -WriteLog {
    param($message)
    Write-DeployLog $message
} | ForEach-Object {
    [PSCustomObject]@{
        Name       = $_.Name
        DeployType = if ($_.IsHypervisor) { 'Hypervisor' } elseif ($_.IsAdditional) { 'Additional' } else { 'AD' }
    }
}
if (-not [string]::IsNullOrWhiteSpace($TargetComputer)) {
    $Serverlist = @($Serverlist | Where-Object { $_.Name -ieq $TargetComputer })
    if ($Serverlist.Count -eq 0) {
        throw "Das Ziel '$TargetComputer' wurde nicht in der ermittelten Windows-Zielliste gefunden."
    }
    Write-Host "Eingeschränkter Lauf: $($Serverlist[0].Name)" -ForegroundColor Yellow
}
Write-Host "Gesamtliste: $($Serverlist.Count) Gerät(e)`n" -ForegroundColor Green

# Das Client-Zertifikat wird nur benötigt, wenn mindestens ein Nicht-AD-Gerät
# eingerichtet wird. Es wird bei Bedarf automatisch im Skriptordner erstellt.
$nonAdTargets = @($Serverlist | Where-Object { $_.DeployType -and $_.DeployType -ne 'AD' })
if ($nonAdTargets.Count -gt 0) {
    $clientCertificate = Join-Path $PSScriptRoot 'WinRM-ClientCert.cer'
    $certificateSetup = Join-Path $PSScriptRoot 'Setup-ClientCertificate.ps1'
    if (-not (Test-Path $certificateSetup)) {
        throw "Das Zertifikat-Setup-Skript wurde nicht gefunden: $certificateSetup"
    }
    if (-not (Test-Path $clientCertificate)) {
        Write-Host "Client-Zertifikat fehlt – erstelle es automatisch..." -ForegroundColor Yellow
    } else {
        Write-Host "Client-Zertifikat vorhanden – synchronisiere Konfigurationen..." -ForegroundColor Gray
    }
    & $certificateSetup -NonInteractive
    if (-not (Test-Path $clientCertificate)) {
        throw "Das automatische Erstellen des Client-Zertifikats ist fehlgeschlagen."
    }
}

# Ergebnis-Tracking
$Results      = @()
$SuccessCount = 0
$FailCount    = 0
$script:BootstrapCredential = $null

function Add-TrustedWinRMServerCertificate {
    param(
        [Parameter(Mandatory)]$Session,
        [Parameter(Mandatory)][string]$Servername
    )

    $serverCertificate = Invoke-Command -Session $Session -ScriptBlock {
        $listener = Get-ChildItem WSMan:\localhost\Listener |
            Where-Object { (Get-Item "$($_.PSPath)\Transport" -ErrorAction Stop).Value -eq 'HTTPS' } |
            Select-Object -First 1
        if (-not $listener) { throw 'Kein WinRM-HTTPS-Listener vorhanden.' }
        $thumbprint = (Get-Item "$($listener.PSPath)\CertificateThumbprint" -ErrorAction Stop).Value
        $certificate = Get-Item "Cert:\LocalMachine\My\$thumbprint" -ErrorAction Stop
        [PSCustomObject]@{
            Thumbprint = $certificate.Thumbprint
            Subject    = $certificate.Subject
            RawData    = $certificate.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
        }
    } -ErrorAction Stop

    $certificate = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new([byte[]]$serverCertificate.RawData)
    $store = [System.Security.Cryptography.X509Certificates.X509Store]::new('Root', 'CurrentUser')
    $store.Open([System.Security.Cryptography.X509Certificates.OpenFlags]::ReadWrite)
    try {
        $known = $store.Certificates | Where-Object { $_.Thumbprint -eq $certificate.Thumbprint } | Select-Object -First 1
        if (-not $known) {
            $store.Add($certificate)
            Write-Host "  +- WinRM-Serverzertifikat von $Servername als vertrauenswürdig hinterlegt ($($certificate.Thumbprint))." -ForegroundColor Green
        } else {
            Write-Host "  +- WinRM-Serverzertifikat von $Servername ist bereits vertrauenswürdig." -ForegroundColor Gray
        }
    }
    finally {
        $store.Close()
        $certificate.Dispose()
    }
}

# Die Ersteinrichtung darf nicht vom administrativen SMB-Share (C$) abhängen.
# AD-Geräte verbinden sich per Kerberos. Nicht-AD-Geräte verwenden einmalig
# interaktiv abgefragte lokale Administrator-Anmeldedaten; danach übernimmt die
# im Setup eingerichtete Client-Zertifikat-Authentifizierung.
function Invoke-WinRMDeployment {
    param(
        [string]$Servername,
        [string]$PSSCfgSkriptFile,
        [string]$RootDirectory,
        [string]$DeployType,
        [switch]$CleanupLegacyTempOnly
    )

    $session = $null
    $remoteTemp = $null
    $usedCertificate = $false
    $bootstrapCredential = $null
    try {
        if ($DeployType -ne 'AD') {
            # Lokale Konten auf Nicht-AD-Zielen dürfen nicht als
            # "Server\Benutzer" an Kerberos übergeben werden. Negotiate
            # erlaubt den NTLM-Fallback; TrustedHosts ist nur für den
            # einmaligen HTTP-Fallback relevant.
            Add-WindowsUpdateTrustedHost -ComputerName $Servername -WriteLog { param($message) Write-DeployLog $message }
            # Bei Wiederholungen zuerst das bereits eingerichtete Client-Zertifikat testen.
            # Nur bei einer echten Ersteinrichtung werden Zugangsdaten benötigt.
            $clientCert = Get-ChildItem 'Cert:\CurrentUser\My' |
                Where-Object { $_.Subject -eq "CN=WinRM-UpdateClient-$env:COMPUTERNAME" -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending |
                Select-Object -First 1
            if ($clientCert) {
                try {
                    Write-Host "  +- Prüfe bestehende WinRM-Zertifikatsverbindung..." -ForegroundColor Gray
                    $session = New-PSSession -ComputerName $Servername -UseSSL `
                        -CertificateThumbprint $clientCert.Thumbprint `
                        -ErrorAction Stop
                    $usedCertificate = $true
                    Write-Host "  +- Zertifikatsverbindung erfolgreich – keine Zugangsdaten erforderlich." -ForegroundColor Green
                }
                catch {
                    Write-Host "  +- Strenge Zertifikatsprüfung noch nicht verfügbar – stelle Vertrauenskette einmalig her." -ForegroundColor Yellow
                    try {
                        $session = New-PSSession -ComputerName $Servername -UseSSL `
                            -CertificateThumbprint $clientCert.Thumbprint `
                            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) `
                            -ErrorAction Stop
                        $usedCertificate = $true
                        Write-Host "  +- Bestehende Client-Zertifikatsverbindung für die einmalige Vertrauensmigration verwendet." -ForegroundColor Gray
                    }
                    catch {
                        Write-Host "  +- Client-Zertifikatsverbindung nicht verfügbar – verwende Einrichtungsdaten." -ForegroundColor Yellow
                    }
                }
            }

            if (-not $session) {
                if ($null -eq $script:BootstrapCredential) {
                    Write-Host "  +- Einmalig lokale Administrator-Anmeldedaten für Nicht-AD-Geräte eingeben..." -ForegroundColor Yellow
                    $script:BootstrapCredential = Get-Credential -Message "Einmalige WinRM-Einrichtung für Nicht-AD-Geräte (z. B. .\Administrator)"
                }
                $bootstrapCredential = $script:BootstrapCredential
                Write-Host "  +- Verbinde per WinRM ($DeployType)..." -ForegroundColor Gray
                try {
                    $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -UseSSL `
                        -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                }
                catch {
                    # Vor der Einrichtung existiert bei manchen Geräten noch kein
                    # HTTPS-Listener. HTTP ist ausschließlich der einmalige Fallback.
                    Write-Host "  +- WinRM/HTTPS noch nicht verfügbar; versuche einmalig WinRM/HTTP..." -ForegroundColor Yellow
                    try {
                        $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -ErrorAction Stop
                    }
                    catch {
                        # Ein lokales Administratorkonto kann je Nicht-AD-Gerät
                        # unterschiedlich heißen. Werden zwischengespeicherte
                        # Daten abgelehnt, fragen wir genau für dieses Ziel neu.
                        Write-Host "  +- Vorherige Einrichtungsdaten wurden von $Servername abgelehnt." -ForegroundColor Yellow
                        $bootstrapCredential = Get-Credential -Message "Lokale Administrator-Anmeldedaten für $Servername (z. B. .\Administrator)"
                        try {
                            $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -UseSSL `
                                -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                        }
                        catch {
                            Write-Host "  +- WinRM/HTTPS noch nicht verfügbar; versuche $Servername einmalig per HTTP..." -ForegroundColor Yellow
                            $session = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential -Authentication Negotiate -ErrorAction Stop
                        }
                        $script:BootstrapCredential = $bootstrapCredential
                    }
                }
            }
        } else {
            Write-Host "  +- Verbinde per WinRM ($DeployType)..." -ForegroundColor Gray
            $session = New-PSSession -ComputerName $Servername -ErrorAction Stop
        }

        # Alte Ablagerungen der früheren benutzerspezifischen TEMP-Ablage bereinigen.
        # Profilverzeichnisse werden nur dann entfernt, wenn sie unregistriert und
        # nach dem Löschen der eindeutig benannten Setup-Reste vollständig leer sind.
        $removedLegacyPaths = Invoke-Command -Session $session -ScriptBlock {
            $removed = [System.Collections.Generic.List[string]]::new()
            # Verbliebene markierte Setup-Ordner werden beim nächsten Lauf
            # nach 30 Minuten entfernt; die Schonfrist schützt parallele Setups.
            $cutoff = (Get-Date).AddMinutes(-30)
            $windowsTemp = Join-Path $env:WINDIR 'Temp'
            $usersRoot = Join-Path $env:SystemDrive 'Users'
            $registeredProfiles = @{}

            try {
                Get-ChildItem -LiteralPath 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' -ErrorAction Stop | ForEach-Object {
                    $profilePath = (Get-ItemProperty -LiteralPath $_.PSPath -Name ProfileImagePath -ErrorAction SilentlyContinue).ProfileImagePath
                    if ($profilePath) {
                        $normalizedProfile = [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables([string]$profilePath)).TrimEnd('\')
                        $registeredProfiles[$normalizedProfile] = $true
                    }
                }
            }
            catch {
                # Ohne sichere Profilliste keine Benutzerordner entfernen.
                $registeredProfiles['__PROFILE_LOOKUP_FAILED__'] = $true
            }

            $legacyTemps = [System.Collections.Generic.List[string]]::new()
            $legacyTemps.Add($windowsTemp)
            $userDirectories = @()
            if (Test-Path -LiteralPath $usersRoot -PathType Container) {
                $userDirectories = @(Get-ChildItem -LiteralPath $usersRoot -Directory -Force -ErrorAction SilentlyContinue)
                foreach ($userDirectory in $userDirectories) {
                    $legacyTemps.Add((Join-Path $userDirectory.FullName 'AppData\Local\Temp'))
                }
            }

            foreach ($tempDirectory in @($legacyTemps | Select-Object -Unique)) {
                if (-not (Test-Path -LiteralPath $tempDirectory -PathType Container)) { continue }
                try {
                    $tempItem = Get-Item -LiteralPath $tempDirectory -Force -ErrorAction Stop
                    if ($tempItem.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    foreach ($staleSetup in @(Get-ChildItem -LiteralPath $tempDirectory -Directory -Filter 'WindowsUpdateAdmSetup_*' -Force -ErrorAction SilentlyContinue)) {
                        if ($staleSetup.LastWriteTime -gt $cutoff -or ($staleSetup.Attributes -band [IO.FileAttributes]::ReparsePoint)) { continue }
                        Remove-Item -LiteralPath $staleSetup.FullName -Recurse -Force -ErrorAction Stop
                        $removed.Add($staleSetup.FullName)
                    }
                }
                catch {
                    # Eine einzelne gesperrte Alt-Ablage verhindert keine neue Verteilung.
                }
            }

            foreach ($userDirectory in $userDirectories) {
                try {
                    if ($userDirectory.Name -in @('Default', 'Default User', 'Public', 'All Users')) { continue }
                    if ($userDirectory.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
                    $profileTempPath = Join-Path $userDirectory.FullName 'AppData\Local\Temp'
                    if (-not (Test-Path -LiteralPath $profileTempPath -PathType Container)) { continue }
                    $normalizedUserPath = [IO.Path]::GetFullPath($userDirectory.FullName).TrimEnd('\')
                    if ($registeredProfiles.ContainsKey($normalizedUserPath) -or $registeredProfiles.ContainsKey('__PROFILE_LOOKUP_FAILED__')) { continue }

                    foreach ($emptyPath in @(
                        $profileTempPath,
                        (Join-Path $userDirectory.FullName 'AppData\Local'),
                        (Join-Path $userDirectory.FullName 'AppData'),
                        $userDirectory.FullName
                    )) {
                        if (-not (Test-Path -LiteralPath $emptyPath -PathType Container)) { continue }
                        $item = Get-Item -LiteralPath $emptyPath -Force -ErrorAction Stop
                        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { break }
                        if ([IO.Directory]::GetFileSystemEntries($emptyPath).Count -ne 0) { break }
                        Remove-Item -LiteralPath $emptyPath -Force -ErrorAction Stop
                        $removed.Add($emptyPath)
                    }
                }
                catch {
                    # Bei Unsicherheit bleibt der betreffende Ordner unangetastet.
                }
            }

            return @($removed)
        } -ErrorAction Stop
        foreach ($removedPath in @($removedLegacyPaths)) {
            Write-Host "  +- Veraltete, eindeutig markierte Temp-Ablage bereinigt: $removedPath" -ForegroundColor DarkYellow
        }
        if ($CleanupLegacyTempOnly) {
            return [PSCustomObject]@{
                Status = 'Success'
                Message = 'Temp-Altlasten geprüft; WindowsUpdateAdm-Setup wurde auf Wunsch nicht erneut ausgeführt.'
            }
        }

        $remoteTemp = Invoke-Command -Session $session -ScriptBlock {
            param($folderName)
            # Nicht den benutzerspezifischen TEMP-Pfad verwenden: WinRM kann
            # dort einen nicht existierenden Profilpfad liefern. Der Ordner
            # bleibt deshalb im maschinenweiten Windows-Temp-Verzeichnis.
            Join-Path (Join-Path $env:WINDIR 'Temp') $folderName
        } -ArgumentList "WindowsUpdateAdmSetup_$([guid]::NewGuid().ToString('N'))" -ErrorAction Stop

        Invoke-Command -Session $session -ScriptBlock {
            param($path)
            New-Item -ItemType Directory -Path $path -Force | Out-Null
        } -ArgumentList $remoteTemp -ErrorAction Stop

        Write-Host "  +- Übertrage Setup per WinRM..." -ForegroundColor Gray
        Copy-Item -Path (Join-Path $RootDirectory $PSSCfgSkriptFile) `
                  -Destination (Join-Path $remoteTemp $PSSCfgSkriptFile) `
                  -ToSession $session -Force -ErrorAction Stop

        # AD-Geräte erhalten weder Client-Zertifikat noch Zertifikats-Mapping.
        if ($DeployType -ne 'AD') {
            $certSource = Join-Path $RootDirectory 'WinRM-ClientCert.cer'
            if (-not (Test-Path $certSource)) {
                throw "Client-Zertifikat fehlt: $certSource. Zuerst Setup-ClientCertificate.ps1 ausführen."
            }
            Copy-Item -Path $certSource -Destination (Join-Path $remoteTemp 'WinRM-ClientCert.cer') `
                      -ToSession $session -Force -ErrorAction Stop
        }

        $setupParameters = @{}
        if ($DeployType -eq 'Hypervisor' -and -not $usedCertificate) {
            $setupParameters.CertificateMappingCredential = $bootstrapCredential
        } elseif ($DeployType -eq 'Additional' -and -not $usedCertificate) {
            $setupParameters.CertificateMappingCredential = $bootstrapCredential
        } elseif ($DeployType -ne 'AD' -and $usedCertificate) {
            $setupParameters.PreserveExistingCertificateMapping = $true
        }

        Write-Host "  +- Fuehre Setup aus ($DeployType)..." -ForegroundColor Gray
        $null = Invoke-Command -Session $session -ScriptBlock {
            param($path, $scriptName, $parameters)
            & (Join-Path $path $scriptName) @parameters
        } -ArgumentList $remoteTemp, $PSSCfgSkriptFile, $setupParameters -ErrorAction Stop

        if ($DeployType -ne 'AD') {
            Add-TrustedWinRMServerCertificate -Session $session -Servername $Servername
        }

        # Das Remote-Setup plant den WinRM-Neustart absichtlich verzögert,
        # damit diese erste Sitzung sauber enden kann. Auf Nicht-AD Server
        # 2016/2019 wird Windows Update später bewusst via SYSTEM-Aufgabe
        # ausgeführt; ein funktionierender JEA-Endpunkt ist dort keine
        # Voraussetzung für eine erfolgreiche Einrichtung.
        $requiresJeaEndpointTest = $DeployType -eq 'AD'
        if ($DeployType -ne 'AD') {
            try {
                $versionProbe = Invoke-Command -Session $session -ScriptBlock {
                    [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber
                } -ErrorAction Stop
                if ([int]$versionProbe -gt 17763) { $requiresJeaEndpointTest = $true }
                else {
                    Write-Host "  +- Windows Server 2016/2019 erkannt – JEA-Endpunkttest wird übersprungen (Updates laufen später als SYSTEM-Aufgabe)." -ForegroundColor Gray
                }
            }
            catch {
                # Kann die Version nicht bestimmt werden, wird der etablierte
                # Endpunkttest beibehalten statt eine unvollständige Einrichtung
                # als erfolgreich zu melden.
                $requiresJeaEndpointTest = $true
            }
        }

        if (-not $requiresJeaEndpointTest) {
            return [PSCustomObject]@{
                Status = 'Success'
                Message = 'WindowsUpdateAdm eingerichtet; Windows Update erfolgt auf Server 2016/2019 per Client-Zertifikat und SYSTEM-Aufgabe'
            }
        }

        Write-Host "  +- Warte 30 Sekunden auf WinRM-Neustart und Endpoint-Aktivierung..." -ForegroundColor Gray
        Start-Sleep -Seconds 30

        $testParams = @{
            ComputerName      = $Servername
            ConfigurationName = 'WindowsUpdateAdm'
            ScriptBlock       = { Get-Command Get-WindowsUpdate -ErrorAction Stop | Select-Object -First 1 -ExpandProperty Name }
            ErrorAction       = 'Stop'
        }
        if ($DeployType -ne 'AD') {
            $clientCert = Get-ChildItem 'Cert:\CurrentUser\My' |
                Where-Object { $_.Subject -eq "CN=WinRM-UpdateClient-$env:COMPUTERNAME" -and $_.NotAfter -gt (Get-Date) } |
                Sort-Object NotAfter -Descending |
                Select-Object -First 1
            if (-not $clientCert) {
                throw 'Lokales Client-Zertifikat für den Verbindungstest wurde nicht gefunden.'
            }
            $testParams.UseSSL               = $true
            $testParams.CertificateThumbprint = $clientCert.Thumbprint
        }

        Write-Host "  +- Teste neue Verbindung zum WindowsUpdateAdm-Endpunkt..." -ForegroundColor Gray
        $endpointCommand = Invoke-WindowsUpdateWithRetry -OperationName "WindowsUpdateAdm-Endpunkt auf $Servername" -RetryCount 5 -RetryDelaySeconds 30 -WriteLog {
            param($message)
            if ($message -like 'Wiederhole *') {
                Write-Host '  +- Endpunkt noch nicht bereit – erneuter Test in 30 Sekunden...' -ForegroundColor DarkYellow
            }
        } -ScriptBlock {
            $command = Invoke-Command @testParams
            if ($command -ne 'Get-WindowsUpdate') {
                throw "WindowsUpdateAdm-Endpunkt lieferte unerwartetes Ergebnis: $command"
            }
            return $command
        }
        Write-Host "  +- WindowsUpdateAdm-Endpunkt erfolgreich getestet." -ForegroundColor Green

        return [PSCustomObject]@{
            Status = 'Success'
            Message = if ($DeployType -eq 'AD') {
                'WindowsUpdateAdm per Kerberos konfiguriert'
            } else {
                'WindowsUpdateAdm eingerichtet; weitere Verbindungen erfolgen per Client-Zertifikat'
            }
        }
    }
    finally {
        if ($session) {
            if ($remoteTemp) {
                try {
                    # Das Setup kann WinRM neu starten. Dadurch wird die zuvor
                    # verwendete Sitzung Broken, selbst wenn der Endpunkttest
                    # über eine neue Verbindung bereits erfolgreich war.
                    $cleanupSession = $session
                    try {
                        $remoteTempRemoved = Invoke-Command -Session $cleanupSession -ScriptBlock {
                            param($path)
                            if (Test-Path -LiteralPath $path) {
                                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                            }
                            return (-not (Test-Path -LiteralPath $path))
                        } -ArgumentList $remoteTemp -ErrorAction Stop
                    }
                    catch {
                        $initialCleanupError = $_
                        if ($cleanupSession.State -eq 'Opened') {
                            Remove-PSSession -Session $cleanupSession -ErrorAction SilentlyContinue
                        }
                        $cleanupSession = $null

                        # Bei einer abgebrochenen Sitzung für die Bereinigung
                        # eine frische WinRM-Verbindung mit denselben
                        # Anmeldedaten bzw. demselben Client-Zertifikat öffnen.
                        for ($attempt = 1; $attempt -le 5 -and -not $cleanupSession; $attempt++) {
                            try {
                                if ($DeployType -eq 'AD') {
                                    $cleanupSession = New-PSSession -ComputerName $Servername -ErrorAction Stop
                                } elseif ($usedCertificate -and $clientCert) {
                                    try {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -UseSSL `
                                            -CertificateThumbprint $clientCert.Thumbprint -ErrorAction Stop
                                    } catch {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -UseSSL `
                                            -CertificateThumbprint $clientCert.Thumbprint `
                                            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                                    }
                                } elseif ($bootstrapCredential) {
                                    try {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential `
                                            -Authentication Negotiate -UseSSL `
                                            -SessionOption (New-PSSessionOption -SkipCACheck -SkipCNCheck) -ErrorAction Stop
                                    } catch {
                                        $cleanupSession = New-PSSession -ComputerName $Servername -Credential $bootstrapCredential `
                                            -Authentication Negotiate -ErrorAction Stop
                                    }
                                } else {
                                    throw 'Für die erneute WinRM-Verbindung stehen keine Anmeldedaten zur Verfügung.'
                                }
                            } catch {
                                if ($attempt -lt 5) { Start-Sleep -Seconds 5 }
                            }
                        }

                        if (-not $cleanupSession) { throw $initialCleanupError }
                        $remoteTempRemoved = Invoke-Command -Session $cleanupSession -ScriptBlock {
                            param($path)
                            if (Test-Path -LiteralPath $path) {
                                Remove-Item -LiteralPath $path -Recurse -Force -ErrorAction Stop
                            }
                            return (-not (Test-Path -LiteralPath $path))
                        } -ArgumentList $remoteTemp -ErrorAction Stop
                    }
                    if (-not $remoteTempRemoved) {
                        Write-Warning "Temporärer Setup-Ordner auf $Servername konnte nicht bestätigt entfernt werden: $remoteTemp"
                    }
                }
                catch {
                    Write-Warning "Temporärer Setup-Ordner auf $Servername konnte nicht entfernt werden: $remoteTemp. Ursache: $($_.Exception.Message)"
                }
                finally {
                    if ($cleanupSession -and $cleanupSession -ne $session) {
                        Remove-PSSession -Session $cleanupSession -ErrorAction SilentlyContinue
                    }
                }
            }
            Remove-PSSession -Session $session -ErrorAction SilentlyContinue
        }
    }
}

# Hilfsfunktion: einzelnen Server verarbeiten
function Invoke-ServerDeployment {
    param(
        [string]$Servername,
        [string]$PSSCfgSkriptFile,
        [string]$RootDirectory,
        [string]$DeployType = "AD",
        [switch]$CleanupLegacyTempOnly
    )

    $result = [PSCustomObject]@{
        Status  = "Pending"
        Message = ""
    }

    # Remote ausschließlich per WinRM verteilen: kein C$ erforderlich.
    if ($Servername -ne $env:COMPUTERNAME) {
        try {
            return Invoke-WinRMDeployment `
                -Servername $Servername `
                -PSSCfgSkriptFile $PSSCfgSkriptFile `
                -RootDirectory $RootDirectory `
                -DeployType $DeployType `
                -CleanupLegacyTempOnly:$CleanupLegacyTempOnly
        }
        catch {
            $result.Status  = 'Failed'
            $errorText = $_.Exception.Message
            if ($errorText -match 'Interner Fehler') {
                $result.Message = 'Zertifikatsanmeldung zum JEA-Endpunkt nach 5 Versuchen abgelehnt.'
            } elseif ($errorText -match 'Access is denied|Zugriff verweigert|Unauthorized|Anmeldeinformationen|Credential') {
                $result.Message = "WinRM-Anmeldung für $Servername abgelehnt: $errorText"
            } else {
                $result.Message = "WinRM/JEA-Endpunkt nach 5 Versuchen nicht erreichbar: $errorText"
            }
            return $result
        }
    }

    if ($CleanupLegacyTempOnly) {
        $result.Status = 'Skipped'
        $result.Message = 'Lokales Ziel im Bereinigungslauf übersprungen; nur Remote-Ziele werden bereinigt.'
        return $result
    }

    # Lokales Setup direkt aus dem gemeinsamen Skriptordner ausführen.
    try {
        $localParameters = @{}
        # Das Setup schreibt bewusst seinen Fortschritt auf den Host. Sonstige
        # Pipeline-Ausgaben dürfen jedoch nicht als zweites Deployment-Ergebnis
        # an den Aufrufer zurückfließen.
        $null = & (Join-Path $RootDirectory $PSSCfgSkriptFile) @localParameters
        if ($LASTEXITCODE -ne 0) {
            throw "Lokales Setup auf $Servername wurde mit Exit-Code $LASTEXITCODE beendet."
        }
        $result.Status = 'Success'
        $result.Message = 'WindowsUpdateAdm lokal konfiguriert'
        return $result
    }
    catch {
        $result.Status  = 'Failed'
        $result.Message = $_.Exception.Message
        return $result
    }

}

# Server verarbeiten
ForEach ($Server in $Serverlist) {
    $Servername = $Server.Name
    if ([String]::IsNullOrWhiteSpace($Servername)) {
        $Servername = $Server
    }
    if ([String]::IsNullOrWhiteSpace($Servername)) {
        continue
    }

    Write-Host "[$Servername] " -NoNewline -ForegroundColor Yellow
    $deployTypeLabel = if ($Server.DeployType) { $Server.DeployType } else { "AD" }
    Write-Host "Starte Deployment ($deployTypeLabel)..." -ForegroundColor Gray

    $deployResult = Invoke-ServerDeployment `
        -Servername                $Servername `
        -PSSCfgSkriptFile          $PSSCfgSkriptFile `
        -RootDirectory             $PSScriptRoot `
        -DeployType                $deployTypeLabel `
        -CleanupLegacyTempOnly:$CleanupLegacyTempOnly

    $ServerResult = [PSCustomObject]@{
        ServerName = $Servername
        Status     = $deployResult.Status
        Message    = $deployResult.Message
        Timestamp  = Get-Date
    }

    if ($deployResult.Status -eq "Success") {
        $SuccessCount++
    }
    elseif ($deployResult.Status -eq "Failed") {
        $FailCount++
    }

    $Results += $ServerResult
    Write-Host ""
}

# Beim regulären Gesamtlauf werden SSH-Schlüssel, Schlüssel-Login und die
# begrenzten sudo-/HA-Voraussetzungen vorbereitet. Die beiden Skripte behalten
# dieselbe Ersteinrichtung zusätzlich für Check, Download und Installation.
if ([string]::IsNullOrWhiteSpace($TargetComputer) -and -not $CleanupLegacyTempOnly) {
    $hostPowerShell = Join-Path $PSHOME 'pwsh.exe'
    if (-not (Test-Path -LiteralPath $hostPowerShell)) { $hostPowerShell = (Get-Process -Id $PID).Path }
    $linuxSettings = if ($Settings.PSObject.Properties['LinuxSettings']) { $Settings.LinuxSettings } else { $null }
    $haSettings = if ($Settings.PSObject.Properties['HomeAssistantSettings']) { $Settings.HomeAssistantSettings } else { $null }
    $linuxConfigured = $null -ne $linuxSettings -and $linuxSettings.PSObject.Properties['Hosts'] -and @($linuxSettings.Hosts | Where-Object { $_ }).Count -gt 0
    $haConfigured = $null -ne $haSettings -and $haSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$haSettings.Host)
    $connectionSetups = @()
    if ($linuxConfigured) { $connectionSetups += [PSCustomObject]@{ Name = 'Linux'; Script = 'Install-Linux Updates.ps1' } }
    if ($haConfigured) { $connectionSetups += [PSCustomObject]@{ Name = 'Home Assistant'; Script = 'Install-HomeAssistant Updates.ps1' } }
    foreach ($connectionSetup in $connectionSetups) {
        $connectionScript = Join-Path $PSScriptRoot $connectionSetup.Script
        if (-not (Test-Path -LiteralPath $connectionScript)) {
            Write-Warning "$($connectionSetup.Name)-Einrichtung übersprungen: Skript nicht gefunden."
            continue
        }
        Write-Host "[$($connectionSetup.Name)] Prüfe Verbindung und führe Ersteinrichtung aus ..." -ForegroundColor Cyan
        try {
            & $hostPowerShell -NoProfile -ExecutionPolicy Bypass -File $connectionScript -CheckOnly
            if ($LASTEXITCODE -ne 0) { throw "Exit-Code $LASTEXITCODE" }
            Write-Host "  +- $($connectionSetup.Name)-Verbindung vorbereitet." -ForegroundColor Green
        }
        catch {
            Write-Warning "$($connectionSetup.Name)-Einrichtung nicht abgeschlossen: $($_.Exception.Message)"
        }
    }
}

# Zusammenfassung
Write-Host "+=======================================+" -ForegroundColor Cyan
Write-Host "|         ZUSAMMENFASSUNG               |" -ForegroundColor Cyan
Write-Host "+=======================================+`n" -ForegroundColor Cyan

$Results | Format-Table ServerName, Status, Message -AutoSize

Write-Host "Ergebnis:" -ForegroundColor Cyan
Write-Host "  Erfolgreich: $SuccessCount" -ForegroundColor Green
Write-Host "  Fehler:      $FailCount" -ForegroundColor $(if ($FailCount -eq 0) { "Green" } else { "Red" })
Write-Host "  Gesamt:      $($Results.Count)" -ForegroundColor Gray

# Fehlerhafte Server anzeigen
if ($FailCount -gt 0) {
    Write-Host "`nFehlerhafte Server (manuelle Nachbearbeitung erforderlich):" -ForegroundColor Yellow
    $Results | Where-Object { $_.Status -eq "Failed" } | ForEach-Object {
        Write-Host "  - $($_.ServerName): $($_.Message)" -ForegroundColor Red
    }
}

Write-Host "`nNaechster Schritt:" -ForegroundColor Cyan
Write-Host "Teste die Configuration mit:" -ForegroundColor Gray
Write-Host "Invoke-Command -ComputerName <SERVERNAME> -ConfigurationName 'WindowsUpdateAdm' -ScriptBlock { Get-WindowsUpdate }" -ForegroundColor Yellow
Write-Host ""
