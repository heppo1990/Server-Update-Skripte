#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Check-ServersUpdates.ps1 - FIXED für Aufgabenplanung
    Prüft verfügbare Windows Updates auf allen Servern (OHNE Installation)
    
.DESCRIPTION
    - Zeigt nur verfügbare Updates an
    - Installiert NICHTS
    - Leert Windows Update Cache (Download + DataStore) für frische Ergebnisse
    - Führt DetectNow nach Cache-Reset aus damit WU frisch bei MS sucht
    - Nutzt -Online Flag bei Get-WindowsUpdate (kein WSUS, direkt Microsoft)
    - Nutzt WindowsUpdateAdm Configuration wenn verfügbar
    - Erstellt HTML-Report mit modernem Design
    - PowerShell 7 kompatibel (Server 2016-2025)
    - Unterstützt zusätzliche Geräte außerhalb der AD via "AdditionalComputers" in der Settings-JSON
    
.NOTES
    FIX für Aufgabenplanung:
    - Explizites Laden von PSWindowsUpdate mit Fehlerbehandlung
    - CredSSP/NTLM Fallback für Remote-Verbindungen
    - Erweiterte PSModulePath-Behandlung
    
    FIX für veraltete Updates (kein WSUS):
    - DataStore wird zusätzlich zu Download geleert
    - wuauclt /detectnow + DetectNow() COM-Aufruf nach Reset
    - Wartezeit nach DetectNow damit WU-Scan abgeschlossen sein kann
    - Get-WindowsUpdate mit -Online Flag erzwingt direkte MS-Abfrage

.EXAMPLE
    # Standardaufruf - prüft alle Server aus der AD + settings.json
    .\Check-ServersUpdates.ps1

.EXAMPLE
    # Mit PowerShell 7
    pwsh.exe -ExecutionPolicy Bypass -File ".\Check-ServersUpdates.ps1"

.EXAMPLE
    # Als geplante Aufgabe: „Starten in“ auf den Skriptordner setzen, dann:
    powershell.exe -NonInteractive -ExecutionPolicy Bypass -File ".\Check-ServersUpdates.ps1"

#>


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

function Get-CheckSettingsFromCommon {
  Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName $ScriptName -WriteLog { param($message) Write-ScriptLog $message }
}

############################################################################################################################################################################
# Globale Variablen
############################################################################################################################################################################

$Settings = $null
$UpdateSettings = $null
$MailSettings = $null
$ComputerFQDN = [System.Net.Dns]::GetHostEntry($env:COMPUTERNAME).HostName
$UpdCount = 0
$PackageUpdateCount = 0
$WingetUpdateCount = 0
$ChocolateyUpdateCount = 0
$LinuxUpdateCount = 0
$HAUpdateCount = 0
$LinuxCheckErrors = 0
$HACheckErrors = 0
$LinuxCheckExecuted = $false
$HACheckExecuted = $false
$UpdResultFull = $null
$TimeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$ScriptName = (Split-Path -Path ($MyInvocation.MyCommand.Name) -Leaf).Replace('.ps1','')
$LogFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_${TimeStamp}.log"
$ReportFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_Report_${TimeStamp}.html"

############################################################################################################################################################################
# Funktionen
############################################################################################################################################################################

function Write-ScriptLog ($Message) { Write-WindowsUpdateLog -Message $Message -LogFile $LogFileName -ScriptName $ScriptName -RunTimestamp $TimeStamp -WriteLogFile ([bool]($null -ne $UpdateSettings -and $UpdateSettings.WriteLogFile)) }

function Clear-WindowsUpdateCache {
  param(
    [string]$Servername,
    # AuthInfo stammt aus dem gemeinsamen Zertifikatsmodul und enthält den
    # Client-Zertifikat-Thumbprint für Nicht-AD-Ziele.
    $AuthInfo = $null
  )

  # Standardmäßig bewusst aktiv: Kunden werden teils nur selten versorgt und
  # sollen vor dem Scan frische Update-Metadaten erhalten. Der Schalter kann
  # bei häufigen Prüfungen je Kundenkonfiguration deaktiviert werden.
  if ($UpdateSettings.PSObject.Properties.Name -contains 'ClearUpdateCacheBeforeCheck' -and
      -not [bool]$UpdateSettings.ClearUpdateCacheBeforeCheck) {
    Write-ScriptLog "Cache-Bereinigung auf ${Servername} laut Konfiguration übersprungen."
    return
  }
  
  Write-ScriptLog "Bereinige Windows Update Cache (Download + DataStore) auf ${Servername}..."
  
  # -----------------------------------------------------------------------
  # ÄNDERUNG 1: DataStore wird zusätzlich geleert
  # ÄNDERUNG 2: BITS-Dienst wird ebenfalls gestoppt (hält Dateien offen)
  # ÄNDERUNG 3: Nach dem Neustart der Dienste wird DetectNow ausgelöst,
  #             damit Windows Update frisch bei Microsoft sucht und nicht
  #             auf gecachte (veraltete) Metadaten zurückgreift.
  # ÄNDERUNG 4: Wartezeit nach DetectNow (Standard 60s, konfigurierbar)
  # -----------------------------------------------------------------------
  $clearCacheScript = {
    param([int]$DetectNowWaitSec = 60)
    try {
      $result = "SUCCESS"
      
      # Dienste stoppen: erst wuauserv, dann bits
      Stop-Service -Name wuauserv -Force -ErrorAction SilentlyContinue
      Stop-Service -Name bits    -Force -ErrorAction SilentlyContinue

      # Warte bis beide Dienste wirklich gestoppt sind (max 30 Sekunden)
      $maxWait = 30
      foreach ($svc in @('wuauserv','bits')) {
        $waited = 0
        while ((Get-Service -Name $svc).Status -ne 'Stopped' -and $waited -lt $maxWait) {
          Start-Sleep -Seconds 1
          $waited++
        }
        if ((Get-Service -Name $svc).Status -ne 'Stopped') {
          $result = "TIMEOUT_STOP_$svc"
        }
      }

      if ($result -eq "SUCCESS") {
        # Download-Ordner leeren (wie bisher)
        Remove-Item "C:\Windows\SoftwareDistribution\Download\*" -Recurse -Force -ErrorAction SilentlyContinue
        
        # NEU: DataStore leeren (enthält die Update-Metadaten/Datenbank)
        Remove-Item "C:\Windows\SoftwareDistribution\DataStore\*" -Recurse -Force -ErrorAction SilentlyContinue
      }

      # Dienste wieder starten
      Start-Service -Name bits    -ErrorAction SilentlyContinue
      Start-Service -Name wuauserv -ErrorAction SilentlyContinue

      # Warte bis wuauserv läuft
      $waited = 0
      while ((Get-Service -Name wuauserv).Status -ne 'Running' -and $waited -lt $maxWait) {
        Start-Sleep -Seconds 1
        $waited++
      }
      if ((Get-Service -Name wuauserv).Status -ne 'Running') {
        return "SERVICE_FAILED"
      }

      # NEU: DetectNow auslösen damit WU frisch bei Microsoft sucht
      # Methode 1: wuauclt (klassisch, funktioniert auf allen Versionen)
      & wuauclt.exe /detectnow 2>$null
      
      # Methode 2: COM-Objekt (zuverlässiger auf neueren Systemen)
      try {
        $AutoUpdate = New-Object -ComObject Microsoft.Update.AutoUpdate
        $AutoUpdate.DetectNow()
      } catch { }

      # Warten bis der WU-Scan abgeschlossen ist
      Start-Sleep -Seconds $DetectNowWaitSec

      return $result
    }
    catch {
      return "ERROR: $($_.Exception.Message)"
    }
  }
  
  # Wartezeit nach DetectNow aus Settings lesen (Standard 60 Sekunden)
  $detectWait = 60
  if ($UpdateSettings.DetectNowWaitSeconds -gt 0) {
    $detectWait = $UpdateSettings.DetectNowWaitSeconds
  }

  try {
    if ($Servername -eq $env:COMPUTERNAME) {
      $result = & $clearCacheScript -DetectNowWaitSec $detectWait
    } else {
      try {
        $invokeParams = @{
          ComputerName = $Servername
          ScriptBlock  = $clearCacheScript
          ArgumentList = $detectWait
          ErrorAction  = 'Stop'
        }
        if ($AuthInfo) {
          $authParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
          foreach ($key in $authParams.Keys) {
            if ($key -ne 'ComputerName') {
              $invokeParams[$key] = $authParams[$key]
            }
          }
        }
        $result = Invoke-Command @invokeParams
      }
      catch {
        Write-ScriptLog "WARNUNG: Cache-Bereinigung remote fehlgeschlagen: $($_.Exception.Message)"
        $result = "SKIPPED"
      }
    }
    
    switch -Wildcard ($result) {
      "SUCCESS"           { Write-ScriptLog "Cache (Download + DataStore) erfolgreich bereinigt auf ${Servername}. DetectNow wurde ausgelöst, ${detectWait}s gewartet." }
      "TIMEOUT_STOP_*"    { Write-ScriptLog "WARNUNG: Dienst $($result -replace 'TIMEOUT_STOP_','') konnte nicht gestoppt werden auf ${Servername} - Cache möglicherweise unvollständig bereinigt." }
      "SERVICE_FAILED"    { Write-ScriptLog "WARNUNG: wuauserv konnte nach dem Reset nicht gestartet werden auf ${Servername}." }
      "SKIPPED"           { Write-ScriptLog "Cache-Bereinigung auf ${Servername} übersprungen." }
      default             { Write-ScriptLog "Cache-Bereinigung auf ${Servername}: $result" }
    }
  }
  catch {
    Write-ScriptLog "Fehler beim Cache-Clearing auf ${Servername}: $($_.Exception.Message)"
  }
}


function Import-PSWindowsUpdate {
  Write-ScriptLog "Versuche PSWindowsUpdate-Modul zu laden..."
  
  if (Get-Module -Name PSWindowsUpdate) {
    Write-ScriptLog "PSWindowsUpdate ist bereits geladen."
    return $true
  }
  
  try {
    Import-Module PSWindowsUpdate -ErrorAction Stop
    Write-ScriptLog "PSWindowsUpdate erfolgreich geladen (Standard-Pfad)."
    return $true
  }
  catch {
    Write-ScriptLog "Standard-Import fehlgeschlagen: $($_.Exception.Message)"
  }
  
  $possiblePaths = @(
    "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate",
    "${env:ProgramFiles(x86)}\WindowsPowerShell\Modules\PSWindowsUpdate",
    "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\PSWindowsUpdate",
    "C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate"
  )
  
  foreach ($path in $possiblePaths) {
    if (Test-Path $path) {
      Write-ScriptLog "Gefunden in: $path"
      try {
        Import-Module $path -ErrorAction Stop
        Write-ScriptLog "PSWindowsUpdate erfolgreich geladen aus: $path"
        return $true
      }
      catch {
        Write-ScriptLog "Import aus $path fehlgeschlagen: $($_.Exception.Message)"
      }
    }
  }
  
  Write-ScriptLog "FEHLER: PSWindowsUpdate konnte nicht gefunden/geladen werden!"
  Write-ScriptLog "Bitte installieren Sie das Modul mit: Install-Module PSWindowsUpdate -Force"
  return $false
}

# Hauptskript
############################################################################################################################################################################

$ScriptStartTime = Get-Date
$psVersion = $PSVersionTable.PSVersion.Major

Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host "Betriebssystem: $([System.Environment]::OSVersion.VersionString)"
Write-Host "Ausführungskontext: $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)"
Write-Host "═══════════════════════════════════════════════════════════════"

$Settings = Get-CheckSettingsFromCommon
$linuxSettings = if ($Settings.PSObject.Properties['LinuxSettings']) { $Settings.LinuxSettings } else { $null }
$haSettings = if ($Settings.PSObject.Properties['HomeAssistantSettings']) { $Settings.HomeAssistantSettings } else { $null }
$LinuxConfigured = $null -ne $linuxSettings -and $linuxSettings.PSObject.Properties['Hosts'] -and @($linuxSettings.Hosts | Where-Object { $_ }).Count -gt 0
$HAConfigured = $null -ne $haSettings -and $haSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$haSettings.Host)
$UpdateSettings = $Settings.UpdateSettings
$MailSettings = $Settings.MailSettings
$TargetComputers = $UpdateSettings.TargetComputers
if ([string]::IsNullOrWhiteSpace($TargetComputers)) {
  $TargetComputers = "Server"
}
$SucheOnline = if ($UpdateSettings.PSObject.Properties['SucheOnline']) { [bool]$UpdateSettings.SucheOnline } else { $false }
$clearCacheBeforeCheck = if ($UpdateSettings.PSObject.Properties['ClearUpdateCacheBeforeCheck']) { [bool]$UpdateSettings.ClearUpdateCacheBeforeCheck } else { $true }
$updateSourceDescription = if ($SucheOnline) {
  'Microsoft Update ist für die Suche aktiviert.'
} else {
  'Standard-Windows-Updatequelle gemäß Windows-Konfiguration.'
}
$cacheDescription = if ($clearCacheBeforeCheck) {
  'Cache (Download + DataStore) wird vor jedem Check bereinigt.'
} else {
  'Cache-Bereinigung ist laut Konfiguration deaktiviert.'
}
$enableWingetUpdates = if ($UpdateSettings.PSObject.Properties['EnableWingetUpdates']) { [bool]$UpdateSettings.EnableWingetUpdates } else { $true }
$enableChocolateyUpdates = if ($UpdateSettings.PSObject.Properties['EnableChocolateyUpdates']) { [bool]$UpdateSettings.EnableChocolateyUpdates } else { $true }
$packageManagerDescription = "Winget: $(if ($enableWingetUpdates) { 'aktiviert' } else { 'deaktiviert' }); Chocolatey: $(if ($enableChocolateyUpdates) { 'aktiviert' } else { 'deaktiviert' })."

# KRITISCH: PSWindowsUpdate-Modul laden
$moduleLoaded = Import-PSWindowsUpdate
if (-not $moduleLoaded) {
  Write-ScriptLog "KRITISCHER FEHLER: PSWindowsUpdate-Modul nicht verfügbar. Skript wird beendet."
  exit 1
}

$ServerADList = Get-WindowsUpdateTargets -UpdateSettings $UpdateSettings -TargetComputers $TargetComputers -PowerShellMajor $psVersion -WriteLog { param($message) Write-ScriptLog $message }

# HTML-Report initialisieren
$RepBody = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Update-Check Report - $ScriptName</title>
<style>
    body { 
        font-family: Arial, sans-serif; 
        margin: 20px; 
        background-color: #f5f5f5;
    }
    h1 { 
        color: #333; 
        border-bottom: 2px solid #2196F3; 
        padding-bottom: 10px;
    }
    .info-box {
        background-color: white;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #2196F3;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .warning-box {
        background-color: #fff3cd;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #ffc107;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .error-box {
        background-color: #f8d7da;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #dc3545;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    table { 
        border-collapse: collapse; 
        width: 100%; 
        margin: 10px 0; 
        background-color: white;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    th, td { 
        border: 1px solid #ddd; 
        padding: 12px 8px; 
        text-align: left; 
    }
    th { 
        background-color: #2196F3; 
        color: white; 
        font-weight: bold;
    }
    tr:nth-child(even) { 
        background-color: #f9f9f9; 
    }
    tr:hover {
        background-color: #f1f1f1;
    }
    .server-title {
        background-color: #2196F3;
        color: white;
        padding: 10px;
        margin: 15px 0 5px 0;
        font-weight: bold;
        border-radius: 3px;
    }
    .no-updates {
        background-color: #d4edda;
        color: #155724;
        padding: 10px;
        margin: 5px 0;
        border-left: 4px solid #28a745;
    }
    .summary {
        background-color: #e3f2fd;
        padding: 15px;
        margin: 20px 0;
        border-radius: 5px;
        font-size: 1.1em;
    }
    .summary.warning {
        background-color: #fff3cd;
        border-left: 4px solid #ffc107;
    }
    .summary.success {
        background-color: #d4edda;
        border-left: 4px solid #28a745;
    }
</style>
</head>
<body>
<h1>Update-Check Report - ${ComputerFQDN}</h1>
<div class="info-box">
    <p><strong>Computer:</strong> ${ComputerFQDN}</p>
    <p><strong>PowerShell Version:</strong> $($PSVersionTable.PSVersion)</p>
    <p><strong>Ausführungskontext:</strong> $([System.Security.Principal.WindowsIdentity]::GetCurrent().Name)</p>
    <p><strong>Zeitstempel:</strong> ${TimeStamp}</p>
    <p><strong>HINWEIS:</strong> Dieser Report zeigt nur verfügbare Updates. Es wurden <strong>KEINE Updates installiert</strong>!</p>
    <p><strong>Update-Quelle:</strong> ${updateSourceDescription} ${cacheDescription}</p>
    <p><strong>Anwendungsupdates:</strong> ${packageManagerDescription}</p>
</div>
"@

# Server verarbeiten
if ($ServerADList -ne $null) {
  Write-ScriptLog "Verarbeite Windows-Zielliste..."

  # -----------------------------------------------------------------------
  # ÄNDERUNG: ScriptBlocks verwenden jetzt immer -Online
  # Damit fragt PSWindowsUpdate direkt bei der konfigurierten WU-Quelle
  # (=Microsoft, da kein WSUS) an und ignoriert lokale Caches komplett.
  # -----------------------------------------------------------------------

  # ScriptBlock für JEA-Endpoint (WindowsUpdateAdm)
  $sbWU_JEA = {
    param($SucheOnline)
    # Kein -Online Flag - wird von älteren PSWindowsUpdate-Versionen nicht unterstützt.
    # Frische Ergebnisse werden durch den vorherigen Cache-Reset + DetectNow sichergestellt.
    if ($SucheOnline) {
      Get-WindowsUpdate -MicrosoftUpdate
    } else {
      Get-WindowsUpdate
    }
  }

  # ScriptBlock für Standard-Remoting
  $sbWU_Full = {
    param($SucheOnline, $ModulePaths)
    
    if ($ModulePaths) {
      foreach ($path in $ModulePaths) {
        if ($env:PSModulePath -notlike "*$path*") {
          $env:PSModulePath = $env:PSModulePath + ";$path"
        }
      }
    }
    
    $moduleLoaded = $false
    try {
      if (-not (Get-Module -Name PSWindowsUpdate)) { Import-Module PSWindowsUpdate -ErrorAction Stop }
      $moduleLoaded = $true
    }
    catch {
      $possiblePaths = @(
        "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate",
        "${env:ProgramFiles(x86)}\WindowsPowerShell\Modules\PSWindowsUpdate",
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\PSWindowsUpdate"
      )
      foreach ($path in $possiblePaths) {
        if (Test-Path $path) {
          try {
            Import-Module $path -ErrorAction Stop
            $moduleLoaded = $true
            break
          }
          catch { }
        }
      }
    }
    
    if (-not $moduleLoaded) {
      throw "PSWindowsUpdate konnte nicht geladen werden"
    }
    
    # Kein -Online Flag - wird von älteren PSWindowsUpdate-Versionen nicht unterstützt.
    # Frische Ergebnisse werden durch den vorherigen Cache-Reset + DetectNow sichergestellt.
    if ($SucheOnline) {
      Get-WindowsUpdate -MicrosoftUpdate
    } else {
      Get-WindowsUpdate
    }
  }

  $index = 0
  $Anzahl = 0 + $ServerADList.Count

  if ($Anzahl -eq 0) {
    $RepBody += "<div class='warning-box'><p>Der Abruf der Serverliste ist fehlgeschlagen!</p></div>"
  }

  $modulePaths = @($env:PSModulePath -split ';' | Where-Object { $_ -like "*WindowsPowerShell\Modules*" })

  ForEach ($Server in $ServerADList) {
    $index += 1
    $Servername = $Server.Name

    if (!([String]::IsNullOrWhiteSpace($Servername))) {
      if ($Anzahl -ne 0) { $PercCompl = $index * 100 / $Anzahl } else { $PercCompl = 100 }
      Write-Progress -Activity "Verarbeite Windows-Ziele" -Status "Verarbeite Ziel [$Servername] (Nr. $index von $Anzahl)" -PercentComplete $PercCompl

      Try {
        $targetTypeLabel = if ($Server.IsHypervisor) { 'Hypervisor' } elseif ($Server.IsAdditional) { 'Zusatzcomputer' } else { 'AD-Ziel' }
        Write-ScriptLog "Starte Update-Check auf $targetTypeLabel $Servername..."
        $RepBody += "<div class='server-title'>Windows-Ziel: ${Servername}</div>"

        # Nicht-AD-Ziele erhalten TrustedHosts und Zertifikatsauthentifizierung
        # zentral; AD-Ziele bleiben bei Kerberos ohne Zertifikat.
        $remoting = Initialize-WindowsUpdateRemoting -UpdateSettings $UpdateSettings -TargetComputer $Servername -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        $svcCredential = $remoting.AuthInfo

        # Cache leeren UND DetectNow auslösen VOR dem Update-Check
        Clear-WindowsUpdateCache -Servername $Servername -AuthInfo $svcCredential

        $UpdResult = $null

        # Prüfe ob WindowsUpdateAdm verfügbar ist (nur remote)
        $useJEA = $false
        $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $svcCredential -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        if ($Servername -ne $env:COMPUTERNAME -and $jeaSupported) {
          $useJEA = $true
          try {
            $jeaTestParams = @{
              ComputerName        = $Servername
              ConfigurationName   = 'WindowsUpdateAdm'
              ScriptBlock         = { 1 }
              ErrorAction         = 'Stop'
            }
            if ($svcCredential) {
              $authParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $svcCredential -ConfigurationName 'WindowsUpdateAdm'
              foreach ($k in $authParams.Keys) { if ($k -ne 'ComputerName') { $jeaTestParams[$k] = $authParams[$k] } }
            }
            $null = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Verbindungstest auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaTestParams }
          } catch {
            $useJEA = $false
            Write-ScriptLog "INFO: '$Servername' nutzt Standard-Remoting (WindowsUpdateAdm nicht verfügbar)"
          }
        }

        # Updates abrufen
        if ($Servername -eq $env:COMPUTERNAME) {
          Write-ScriptLog "Lokaler Update-Check auf $Servername..."
          $UpdResult = if ($SucheOnline) { Get-WindowsUpdate -MicrosoftUpdate } else { Get-WindowsUpdate }
        } elseif ($useJEA) {
          Write-ScriptLog "Remote Update-Check via JEA auf $Servername..."
          try {
            $jeaParams = @{
              ComputerName      = $Servername
              ConfigurationName = 'WindowsUpdateAdm'
              ArgumentList      = $SucheOnline
              ScriptBlock       = $sbWU_JEA
              ErrorAction       = 'Stop'
            }
            if ($svcCredential) {
              $authExtra = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $svcCredential
              foreach ($k in $authExtra.Keys) { if ($k -ne 'ComputerName') { $jeaParams[$k] = $authExtra[$k] } }
            }
            $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Update-Check auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaParams }
          } catch {
            $msg = $_.Exception.Message
            if ($msg -match "Get-WindowsUpdate.*not recognized|wurde nicht als Name eines Cmdlet") {
              throw "WindowsUpdateAdm Endpoint hat kein Get-WindowsUpdate verfügbar."
            }
            throw
          }
        } elseif (-not $jeaSupported -and $svcCredential) {
          # Windows Server 2016 außerhalb der AD: Windows Update wird im
          # SYSTEM-Kontext einer kurzlebigen, selbstlöschenden Aufgabe geprüft.
          Write-ScriptLog "Remote Update-Check als SYSTEM-Aufgabe auf $Servername..."
          $UpdResult = Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $svcCredential -Mode Check -SearchOnline $SucheOnline -WriteLog { param($message) Write-ScriptLog $message }
          $systemTaskRows = @($UpdResult | Where-Object { $null -ne $_ })
          $systemTaskHasUpdateData = @($systemTaskRows | Where-Object {
            $row = $_
            $hasUpdateData = $false
            foreach ($fieldName in @('Status', 'KB', 'Title')) {
              $property = $row.PSObject.Properties[$fieldName]
              if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                $hasUpdateData = $true
                break
              }
            }
            $hasUpdateData
          }).Count -gt 0
          # Bei älteren Nicht-AD-Servern kann die erste SYSTEM-Suche leer
          # zurückkommen, obwohl Download und Installation Updates finden.
          # Auch eine vollständig leere Ergebnisliste wird deshalb einmal
          # mit einer frischen SYSTEM-Aufgabe erneut geprüft.
          if (-not $systemTaskHasUpdateData) {
            $emptyResultReason = if ($systemTaskRows.Count -eq 0) { 'keine Ergebniszeilen' } else { 'nur leere Ergebniszeilen' }
            Write-ScriptLog "WARNUNG: SYSTEM-Update-Suche auf $Servername lieferte $emptyResultReason; wiederhole die Suche einmal nach 20 Sekunden."
            Start-Sleep -Seconds 20
            $UpdResult = Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $svcCredential -Mode Check -SearchOnline $SucheOnline -WriteLog { param($message) Write-ScriptLog $message }
            $retryRows = @($UpdResult | Where-Object { $null -ne $_ })
            $retryHasUpdateData = @($retryRows | Where-Object {
              $row = $_
              $hasRowData = $false
              foreach ($fieldName in @('Status', 'KB', 'Title')) {
                $property = $row.PSObject.Properties[$fieldName]
                if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
                  $hasRowData = $true
                  break
                }
              }
              $hasRowData
            }).Count -gt 0
            if (-not $retryHasUpdateData) {
              Write-ScriptLog "WARNUNG: Auch die wiederholte SYSTEM-Update-Suche auf $Servername lieferte keine auswertbaren Update-Daten."
            }
          }
        } else {
          Write-ScriptLog "Remote Update-Check via Standard-Remoting auf $Servername..."

          $success = $false

          # Nicht-AD-Gerät: HTTPS mit geprüftem Client- und Serverzertifikat.
          if ($svcCredential) {
            $authLabel = 'Client-Zertifikat'
            Write-ScriptLog "Verwende $authLabel via HTTPS für $Servername"
            try {
              $sessionParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $svcCredential
              $sessionParams.ErrorAction = 'Stop'
              $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "Zertifikats-Update-Check auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @sessionParams -ArgumentList $SucheOnline, $modulePaths -ScriptBlock $sbWU_Full }
              $success = $true
              Write-ScriptLog "Verbindung mit Client-Zertifikat via HTTPS erfolgreich."
            }
            catch {
              Write-ScriptLog "Fehler mit Client-Zertifikat via HTTPS: $($_.Exception.Message)"
            }
          }

          # AD-Gerät: Kerberos/Standard-Authentifizierung durchprobieren
          if (-not $success -and -not $svcCredential) {
            $sessionOptions = New-PSSessionOption -IncludePortInSPN
            $authMethods = @('Default', 'Kerberos', 'Negotiate', 'CredSSP')
            foreach ($authMethod in $authMethods) {
              try {
                Write-ScriptLog "Versuche Verbindung mit Authentifizierung: $authMethod"
                $sessionParams = @{
                  ComputerName  = $Servername
                  ErrorAction   = 'Stop'
                  SessionOption = $sessionOptions
                }
                if ($authMethod -ne 'Default') { $sessionParams.Authentication = $authMethod }
                $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "Update-Check ($authMethod) auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @sessionParams -ArgumentList $SucheOnline, $modulePaths -ScriptBlock $sbWU_Full }
                $success = $true
                Write-ScriptLog "Verbindung erfolgreich mit: $authMethod"
                break
              }
              catch {
                Write-ScriptLog "Fehler mit $authMethod : $($_.Exception.Message)"
                if ($authMethod -eq 'CredSSP' -and $_ -match "CredSSP") {
                  Write-ScriptLog "HINWEIS: CredSSP muss aktiviert werden mit: Enable-WSManCredSSP -Role Client -DelegateComputer $Servername"
                }
              }
            }
          }

          if (-not $success) {
            if ($svcCredential) { throw "Zertifikats-Update-Check auf $Servername fehlgeschlagen." }
            throw "Alle Authentifizierungsmethoden fehlgeschlagen. Siehe Log für Details."
          }
        }

        Write-ScriptLog "Ergebnis der Update-Suche:"

        # Remote-SYSTEM-Aufgaben können bei leerer Suche ein leeres Ergebnisobjekt
        # zurückgeben. Nur Einträge mit Update-Status, KB oder Titel sind Updates.
        $rawUpdateRows = @($UpdResult | Where-Object { $null -ne $_ })
        $updateRows = @($rawUpdateRows | Where-Object {
          $row = $_
          $hasUpdateData = $false
          foreach ($fieldName in @('Status', 'KB', 'Title')) {
            $property = $row.PSObject.Properties[$fieldName]
            if ($null -ne $property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
              $hasUpdateData = $true
              break
            }
          }
          $hasUpdateData
        })
        $emptyUpdateRowCount = $rawUpdateRows.Count - $updateRows.Count
        if ($emptyUpdateRowCount -gt 0) {
          Write-ScriptLog "WARNUNG: $emptyUpdateRowCount leere Ergebniszeile(n) von $Servername verworfen; sie werden nicht als Updates gezählt."
        }
        if ($updateRows.Count -gt 0) {
          ($updateRows | Select-Object ComputerName, Status, KB, Size, Title | Format-Table -AutoSize | Out-String) `
            -split "\r?\n" | ForEach-Object { if ($_) { Write-ScriptLog $_ } }

          $UpdResultFull += $updateRows
          
          $RepBody += "<table>`n"
          $RepBody += "<tr><th>ComputerName</th><th>Status</th><th>KB</th><th>Size</th><th>Title</th></tr>`n"
          
          foreach ($upd in $updateRows) {
            $RepBody += "<tr>"
            $RepBody += "<td>$($upd.ComputerName)</td>"
            $RepBody += "<td>$($upd.Status)</td>"
            $RepBody += "<td>$($upd.KB)</td>"
            $RepBody += "<td>$($upd.Size)</td>"
            $RepBody += "<td>$($upd.Title)</td>"
            $RepBody += "</tr>`n"
          }
          
          $RepBody += "</table>"

          $UpdCount += $updateRows.Count
        } elseif ($rawUpdateRows.Count -gt 0) {
          Write-ScriptLog "WARNUNG: Die Update-Suche auf $Servername lieferte keine auswertbaren Update-Daten."
          $RepBody += "<div class='warning-box'>Die Update-Suche lieferte keine auswertbaren Update-Daten.</div>"
        } else {
          Write-ScriptLog "... es sind keine Windows-Updates verfügbar."
          $RepBody += "<div class='no-updates'>Es sind keine Updates zu installieren.</div>"
        }

        # Zusätzlich installierte Anwendungen über die zentrale Paketverwaltung prüfen.
        try {
          $packageResults = @(Invoke-WindowsUpdatePackageManagers -ComputerName $Servername -AuthInfo $svcCredential -Mode Check -EnableWinget $enableWingetUpdates -EnableChocolatey $enableChocolateyUpdates)
        }
        catch {
          # Paketmanager sind optional. Ein separater Remoting-Fehler darf
          # einen erfolgreichen Windows-Update-Check nicht als Serverfehler
          # bewerten oder den Bericht abbrechen.
          Write-ScriptLog "WARNUNG: Paketmanager-Prüfung auf ${Servername} übersprungen: $($_.Exception.Message)"
          $packageResults = @()
        }
        foreach ($packageResult in $packageResults) {
          if ($packageResult.Skipped) {
            $skipReason = if ([string]::IsNullOrWhiteSpace([string]$packageResult.SkipReason)) { 'ohne Angabe eines Grundes' } else { [string]$packageResult.SkipReason }
            Write-ScriptLog "$($packageResult.Manager)-Prüfung auf ${Servername} übersprungen: $skipReason."
            continue
          }
          if (-not $packageResult.Available) { continue }
          if (-not $packageResult.Success) {
            Write-ScriptLog "WARNUNG: $($packageResult.Manager)-Prüfung auf ${Servername} fehlgeschlagen: $($packageResult.ActionOutput)"
            continue
          }

          $packages = @($packageResult.Packages)
          $packageCount = $packages.Count
          if ($packageCount -eq 0) {
            Write-ScriptLog "$($packageResult.Manager) auf ${Servername}: keine Paketupdates verfügbar."
            continue
          }

          $PackageUpdateCount += $packageCount
          if ($packageResult.Manager -eq 'Winget') { $WingetUpdateCount += $packageCount }
          if ($packageResult.Manager -eq 'Chocolatey') { $ChocolateyUpdateCount += $packageCount }
          Write-ScriptLog "$($packageResult.Manager) auf ${Servername}: $packageCount Paketupdate(s) verfügbar."
          foreach ($package in $packages) { Write-ScriptLog "  ${Servername}: $package" }

          $RepBody += "<div class='info-box'><strong>$($packageResult.Manager)-Updates auf $Servername ($packageCount):</strong><br>"
          $RepBody += (($packages | ForEach-Object { [System.Net.WebUtility]::HtmlEncode([string]$_) }) -join '<br>')
          $RepBody += '</div>'
        }

      }
      Catch {
        Write-ScriptLog ("Es ist ein Fehler bei Server " + $Servername + " aufgetreten!")
        Write-ScriptLog ($_.Exception.Message)
        $RepBody += "<div class='error-box'><strong>Fehler aufgetreten!</strong><br>$($_.Exception.Message)</div>"
      }
    }
  }

} else {
  $RepBody += "<div class='warning-box'><p>Der Abruf der Serverliste ist fehlgeschlagen!</p></div>"
}

# Linux- und Home-Assistant-Checks laufen ausschließlich lesend in ihren
# jeweiligen Skripten. Ihre Ergebnisdateien werden in den gemeinsamen Bericht
# übernommen, ohne Paketinstallation, Backup oder Neustart auszulösen.
$linuxCheckStatsPath = Join-Path $PSScriptRoot 'linux_update_check_stats.json'
$haCheckStatsPath = Join-Path $PSScriptRoot 'ha_update_check_stats.json'
# Reste eines abgebrochenen vorherigen Laufs dürfen nicht in den neuen Bericht
# einfließen. Die Dateien sind nur ein temporärer Übergabekanal.
foreach ($staleStatsPath in @($linuxCheckStatsPath, $haCheckStatsPath)) {
  Remove-Item -LiteralPath $staleStatsPath -Force -ErrorAction SilentlyContinue
}

$linuxCheckScript = Join-Path $PSScriptRoot 'Install-Linux Updates.ps1'
if ($LinuxConfigured -and (Test-Path -LiteralPath $linuxCheckScript)) {
  try {
    Write-ScriptLog 'Starte Linux-Update-Check...'
    & $linuxCheckScript -CheckOnly
    if (Test-Path -LiteralPath $linuxCheckStatsPath) {
      $linuxCheckStats = Get-Content -LiteralPath $linuxCheckStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $LinuxCheckExecuted = $true
      # Die Summe der Hostdetails entspricht exakt den im Bericht gezeigten
      # Paketlisten und ist belastbarer als ein optionales Statistikfeld.
      $LinuxUpdateCount = [int](@($linuxCheckStats.HostStatus | Measure-Object -Property UpdateCount -Sum).Sum)
      $LinuxCheckErrors = [int]$linuxCheckStats.FailedHosts
      $RepBody += "<div class='section-title'>🐧 Linux-Updates</div>"
      foreach ($linuxHost in @($linuxCheckStats.HostStatus)) {
        $RepBody += "<div class='server-title'>Server: $([System.Net.WebUtility]::HtmlEncode([string]$linuxHost.Host))</div>"
        if ($linuxHost.Status -eq 'Fehler') {
          $RepBody += "<div class='error-box'>Linux-Check fehlgeschlagen.</div>"
        } elseif ([int]$linuxHost.UpdateCount -gt 0) {
          $packages = [System.Net.WebUtility]::HtmlEncode([string]$linuxHost.Packages) -replace ' ', '<br>'
          $RepBody += "<div class='info-box'><strong>$($linuxHost.UpdateCount) Paketupdate(s) verfügbar:</strong><br>$packages</div>"
        } else {
          $RepBody += "<div class='no-updates'>Keine Linux-Updates verfügbar.</div>"
        }
      }
    }
    Write-ScriptLog "Linux-Check: $LinuxUpdateCount Paketupdate(s) verfügbar, $LinuxCheckErrors Fehler."
  }
  catch {
    $LinuxCheckErrors++
    Write-ScriptLog "WARNUNG: Linux-Check konnte nicht ausgeführt werden: $($_.Exception.Message)"
    $RepBody += "<div class='error-box'>Linux-Check fehlgeschlagen: $([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</div>"
  }
  finally {
    Remove-Item -LiteralPath $linuxCheckStatsPath -Force -ErrorAction SilentlyContinue
  }
}

$haCheckScript = Join-Path $PSScriptRoot 'Install-HomeAssistant Updates.ps1'
if ($HAConfigured -and (Test-Path -LiteralPath $haCheckScript)) {
  try {
    Write-ScriptLog 'Starte Home-Assistant-Update-Check...'
    & $haCheckScript -CheckOnly
    if (Test-Path -LiteralPath $haCheckStatsPath) {
      $haCheckStats = Get-Content -LiteralPath $haCheckStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $HACheckExecuted = $true
      # Der Mailbericht listet UpdateDetails; daher wird die gleiche Menge
      # auch für die Konsolen- und Gesamtzählung verwendet.
      $HAUpdateCount = @($haCheckStats.UpdateDetails).Count
      if (-not $haCheckStats.Success) { $HACheckErrors++ }
      $RepBody += "<div class='section-title'>🏠 Home-Assistant-Updates</div>"
      $RepBody += "<div class='server-title'>Server: $([System.Net.WebUtility]::HtmlEncode([string]$haCheckStats.Host))</div>"
      if (-not $haCheckStats.Success) {
        $RepBody += "<div class='error-box'>Home-Assistant-Check fehlgeschlagen: $([System.Net.WebUtility]::HtmlEncode([string]$haCheckStats.Error))</div>"
      } elseif ($HAUpdateCount -eq 0) {
        $RepBody += "<div class='no-updates'>Keine Home-Assistant-Updates verfügbar.</div>"
      } else {
        $details = @($haCheckStats.UpdateDetails | ForEach-Object { "{0}: {1} → {2}" -f $_.Component, $_.Current, $_.Available })
        $RepBody += "<div class='info-box'><strong>$HAUpdateCount Update(s) verfügbar:</strong><br>$([System.Net.WebUtility]::HtmlEncode(($details -join "`n")) -replace "`n", '<br>')</div>"
      }
    }
    Write-ScriptLog "Home-Assistant-Check: $HAUpdateCount Update(s) verfügbar, $HACheckErrors Fehler."
  }
  catch {
    $HACheckErrors++
    Write-ScriptLog "WARNUNG: Home-Assistant-Check konnte nicht ausgeführt werden: $($_.Exception.Message)"
    $RepBody += "<div class='error-box'>Home-Assistant-Check fehlgeschlagen: $([System.Net.WebUtility]::HtmlEncode($_.Exception.Message))</div>"
  }
  finally {
    Remove-Item -LiteralPath $haCheckStatsPath -Force -ErrorAction SilentlyContinue
  }
}

# Zusammenfassung
$ScriptDuration = [math]::Round((New-TimeSpan -Start $ScriptStartTime).TotalMinutes, 2)

if (($UpdCount + $PackageUpdateCount + $LinuxUpdateCount + $HAUpdateCount) -eq 0) {
  $RepBody += @"
<div class="summary success">
    <p><strong>Ergebnis: Es sind insgesamt KEINE Updates verfügbar!</strong></p>
    <p>Alle Server sind auf dem neuesten Stand.</p>
</div>
"@
} else {
  $RepBody += @"
<div class="summary warning">
    <p><strong>Ergebnis: Es sind insgesamt $($UpdCount + $PackageUpdateCount + $LinuxUpdateCount + $HAUpdateCount) Update(s) verfügbar!</strong></p>
    <p>Diese Updates können mit dem Install-ServersUpdates.ps1 Skript installiert werden.</p>
</div>
"@
}

$RepBody += @"
<div class="info-box">
    <p><strong>Statistik:</strong></p>
    <ul>
        <li>Geprüfte Server: $Anzahl</li>
        <li>Verfügbare Windows-Updates: $UpdCount</li>
        <li>Verfügbare Anwendungsupdates: $PackageUpdateCount (Winget: $WingetUpdateCount, Chocolatey: $ChocolateyUpdateCount)</li>
        <li>Verarbeitungsdauer: $ScriptDuration Minuten</li>
    </ul>
</div>
</body>
</html>
"@

if ($LinuxCheckExecuted) {
  $RepBody = $RepBody.Replace('        <li>Verarbeitungsdauer:', "        <li>Verfügbare Linux-Updates: $LinuxUpdateCount</li>`n        <li>Verarbeitungsdauer:")
}
if ($HACheckExecuted) {
  $RepBody = $RepBody.Replace('        <li>Verarbeitungsdauer:', "        <li>Verfügbare Home-Assistant-Updates: $HAUpdateCount</li>`n        <li>Verarbeitungsdauer:")
}

$checkSummaryLines = @(
  "PowerShell Version: $($PSVersionTable.PSVersion)",
  "Geprüfte Server: $Anzahl",
  "Verfügbare Windows-Updates: $UpdCount",
  "Verfügbare Anwendungsupdates: $PackageUpdateCount (Winget: $WingetUpdateCount, Chocolatey: $ChocolateyUpdateCount)",
  "Dauer: $ScriptDuration Minuten"
)
if ($LinuxCheckExecuted) { $checkSummaryLines = $checkSummaryLines[0..3] + "Verfügbare Linux-Updates: $LinuxUpdateCount" + $checkSummaryLines[4] }
if ($HACheckExecuted) { $checkSummaryLines = $checkSummaryLines[0..($checkSummaryLines.Count - 2)] + "Verfügbare Home-Assistant-Updates: $HAUpdateCount" + $checkSummaryLines[-1] }
Write-WindowsUpdateConsoleSummary -Title 'UPDATE-CHECK ZUSAMMENFASSUNG' -Lines $checkSummaryLines -WriteLog { param($message) Write-ScriptLog $message }

# E-Mail versenden
# SendMail und Subject direkt hier auswerten - sicher in PS5.1 und PS7
$mailBlock = $MailSettings.Check
$doSendMail = $false
if ($mailBlock -ne $null) {
  $doSendMail = [bool]$mailBlock.SendMail
  $companyName = [string]$MailSettings.CompanyName
  $subjectText = [string]$mailBlock.Subject
  if ([string]::IsNullOrWhiteSpace($subjectText)) { $subjectText = "Server Update-Check" }
  if (-not [string]::IsNullOrWhiteSpace($companyName)) {
    Add-Member -InputObject $MailSettings -NotePropertyName 'Subject' -NotePropertyValue "$companyName - $subjectText" -Force
  } else {
    Add-Member -InputObject $MailSettings -NotePropertyName 'Subject' -NotePropertyValue $subjectText -Force
  }
  # Sender aus Firmenname generieren falls leer
  if ([string]::IsNullOrWhiteSpace($MailSettings.Sender) -and -not [string]::IsNullOrWhiteSpace($companyName)) {
        $mailSafeName = ConvertTo-WindowsUpdateMailSafeString -Text $companyName
    Add-Member -InputObject $MailSettings -NotePropertyName 'Sender' -NotePropertyValue "Updates@$mailSafeName.de" -Force
  }
}
if ($doSendMail) {
  Write-ScriptLog "Versende HTML-Report (Betreff: $($MailSettings.Subject))"
        $null = Send-WindowsUpdateHtmlMail -MailSettings $MailSettings -Subject $MailSettings.Subject -HtmlBody $RepBody -WriteLog { param($message) Write-ScriptLog $message }
} else {
  Write-ScriptLog "Kein Mailversand (SendMail=false fuer Check)."
}

# Report speichern mit UTF-8 BOM
if ($UpdateSettings.WriteReport) {
  Write-ScriptLog "Speichere HTML-Report in $ReportFileName"
  $Utf8BomEncoding = New-Object System.Text.UTF8Encoding $true
  [System.IO.File]::WriteAllText($ReportFileName, $RepBody, $Utf8BomEncoding)
    $CleanUpResult = Invoke-WindowsUpdateRetentionWithLog -Directory (Join-Path $PSScriptRoot 'Logs') -Filter ($ScriptName + '_Report_*.html') -KeepFiles ([int]$UpdateSettings.KeepReportFiles) -Description 'Report- Dateien' -WriteLog { param($message) Write-ScriptLog $message }
}

# Log-Bereinigung
if ($UpdateSettings.WriteLogFile) { 
    $CleanUpResult = Invoke-WindowsUpdateRetentionWithLog -Directory (Join-Path $PSScriptRoot 'Logs') -Filter ($ScriptName + '_*.log') -KeepFiles ([int]$UpdateSettings.KeepLogFiles) -Description '.log- Dateien' -WriteLog { param($message) Write-ScriptLog $message }
}

Write-ScriptLog "Check abgeschlossen."
