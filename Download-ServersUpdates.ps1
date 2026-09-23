#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Download-ServersUpdates.ps1
    Lädt Windows Updates auf alle Server herunter (OHNE Installation)
    
.DESCRIPTION
    - Lädt nur Updates herunter
    - Installiert NICHTS
    - Nutzt WindowsUpdateAdm Configuration wenn verfügbar
    - Erstellt HTML-Report mit modernem Design
    - PowerShell 7 kompatibel (Server 2016-2025)
    - Unterstützt zusätzliche Geräte außerhalb der AD via "AdditionalComputers" in der Settings-JSON

.EXAMPLE
    # Standardaufruf - lädt Updates für alle Server herunter
    .\Download-ServersUpdates.ps1

.EXAMPLE
    # Mit PowerShell 7
    pwsh.exe -ExecutionPolicy Bypass -File ".\Download-ServersUpdates.ps1"

.EXAMPLE
    # Als geplante Aufgabe: „Starten in“ auf den Skriptordner setzen, dann:
    powershell.exe -NonInteractive -ExecutionPolicy Bypass -File ".\Download-ServersUpdates.ps1"

#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

function Get-DownloadSettingsFromCommon {
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
$LinuxAvailableUpdateCount = 0
$HAAvailableUpdateCount = 0
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

function Write-ScriptLog ($Message) {
  Write-WindowsUpdateLog -Message $Message -LogFile $LogFileName -ScriptName $ScriptName -RunTimestamp $TimeStamp -WriteLogFile ([bool]($null -ne $UpdateSettings -and $UpdateSettings.WriteLogFile))
}

# Hauptskript
############################################################################################################################################################################

$ScriptStartTime = Get-Date
$psVersion = $PSVersionTable.PSVersion.Major

Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host "Betriebssystem: $([System.Environment]::OSVersion.VersionString)"
Write-Host "═══════════════════════════════════════════════════════════════"

$Settings = Get-DownloadSettingsFromCommon
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

$ServerADList = Get-WindowsUpdateTargets -UpdateSettings $UpdateSettings -TargetComputers $TargetComputers -PowerShellMajor $psVersion -WriteLog { param($message) Write-ScriptLog $message }

# HTML-Report mit modernem Design
$RepBody = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Update-Download Report - ${ComputerFQDN}</title>
<style>
    body { 
        font-family: Arial, sans-serif; 
        margin: 20px; 
        background-color: #f5f5f5;
    }
    h1 { 
        color: #333; 
        border-bottom: 2px solid #FF9800; 
        padding-bottom: 10px;
    }
    .info-box {
        background-color: white;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #FF9800;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .warning-box {
        background-color: #fff3cd;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #ffc107;
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
        background-color: #FF9800; 
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
        background-color: #FF9800;
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
        background-color: #fff3e0;
        padding: 15px;
        margin: 20px 0;
        border-radius: 5px;
        font-size: 1.1em;
        border-left: 4px solid #FF9800;
    }
</style>
</head>
<body>
<h1>Update-Download Report - ${ComputerFQDN}</h1>
<div class="info-box">
    <p><strong>Computer:</strong> ${ComputerFQDN}</p>
    <p><strong>PowerShell Version:</strong> $($PSVersionTable.PSVersion)</p>
    <p><strong>Zeitstempel:</strong> ${TimeStamp}</p>
    <p><strong>HINWEIS:</strong> Dieser Report zeigt heruntergeladene Updates. Es wurden <strong>KEINE Updates installiert</strong>!</p>
</div>
"@

# Server verarbeiten
if ($ServerADList -ne $null) {
  Write-ScriptLog "Verarbeite AD-Serverliste..."

  $SucheOnline = $UpdateSettings.SucheOnline

  # ScriptBlocks für Download
  $sbWU_JEA = {
    param($SucheOnline)
    if ($SucheOnline) { 
      Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Download 
    } else { 
      Get-WindowsUpdate -AcceptAll -Download 
    }
  }

  $sbWU_Full = {
    param($SucheOnline)
    Import-Module PSWindowsUpdate -ErrorAction Stop
    if ($SucheOnline) { 
      Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Download 
    } else { 
      Get-WindowsUpdate -AcceptAll -Download 
    }
  }

  $index = 0
  $Anzahl = 0 + $ServerADList.Count

  if ($Anzahl -eq 0) {
    $RepBody += "<div class='warning-box'><p>Der Abruf der Serverliste ist fehlgeschlagen!</p></div>"
  }

  ForEach ($Server in $ServerADList) {
    $index += 1
    $Servername = $Server.Name

    if (!([String]::IsNullOrWhiteSpace($Servername))) {
      if ($Anzahl -ne 0) { $PercCompl = $index * 100 / $Anzahl } else { $PercCompl = 100 }
      Write-Progress -Activity "Verarbeite AD-Serverliste" -Status "Verarbeite Server [$Servername] (Nr. $index von $Anzahl)" -PercentComplete $PercCompl

      Try {
        Write-ScriptLog "Starte Update-Download auf AD-Server $Servername..."
        $RepBody += "<div class='server-title'>Server: ${Servername}</div>"

        $UpdResult = $null

        # Nicht-AD-Ziele erhalten TrustedHosts und Zertifikatsauthentifizierung
        # zentral; AD-Ziele bleiben bei Kerberos ohne Zertifikat.
        $remoting = Initialize-WindowsUpdateRemoting -UpdateSettings $UpdateSettings -TargetComputer $Servername -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        $svcCredential = $remoting.AuthInfo

        # Teste ob WindowsUpdateAdm verfügbar ist
        $useJEA = $false
        $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $svcCredential -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        if ($Servername -ne $env:COMPUTERNAME -and $jeaSupported) {
          $useJEA = $true
          try {
            $jeaTestParams = @{
              ComputerName      = $Servername
              ConfigurationName = 'WindowsUpdateAdm'
              ScriptBlock       = { 1 }
              ErrorAction       = 'Stop'
            }
            if ($svcCredential) {
              $authParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $svcCredential -ConfigurationName 'WindowsUpdateAdm'
              foreach ($k in $authParams.Keys) { if ($k -ne 'ComputerName') { $jeaTestParams[$k] = $authParams[$k] } }
            }
            $null = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Verbindungstest auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaTestParams }
          } catch {
            $useJEA = $false
            Write-ScriptLog "INFO: '$Servername' nutzt Standard-Remoting"
          }
        }

        # Updates herunterladen
        if ($Servername -eq $env:COMPUTERNAME) {
          Write-ScriptLog "Lokaler Download auf $Servername..."
          if (-not (Get-Module -Name PSWindowsUpdate)) { Import-Module PSWindowsUpdate -ErrorAction Stop }
          $UpdResult = if ($SucheOnline) {
            Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Download
          } else {
            Get-WindowsUpdate -AcceptAll -Download
          }
        } elseif ($useJEA) {
          Write-ScriptLog "Remote Download via JEA auf $Servername..."
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
            $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Download auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaParams }
          } catch {
            $msg = $_.Exception.Message
            if ($msg -match "Get-WindowsUpdate.*not recognized") {
              throw "WindowsUpdateAdm Endpoint hat kein Get-WindowsUpdate verfügbar."
            }
            throw
          }
        } elseif (-not $jeaSupported -and $svcCredential) {
          # Windows Server 2016 außerhalb der AD: Der über Client-Zertifikat
          # gemappte Administrator darf Windows Update nicht zuverlässig
          # herunterladen. Die Verbindung legt daher nur eine selbstlöschende
          # SYSTEM-Aufgabe an und liest deren Ergebnis wieder aus.
          Write-ScriptLog "Remote Download als SYSTEM-Aufgabe auf $Servername..."
          $UpdResult = Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $svcCredential -Mode Download -SearchOnline $SucheOnline -WriteLog { param($message) Write-ScriptLog $message }
        } else {
          Write-ScriptLog "Remote Download via Standard-Remoting auf $Servername..."

          $success = $false

          # Nicht-AD-Gerät: HTTPS mit geprüftem Client- und Serverzertifikat.
          if ($svcCredential) {
            $authLabel = 'Client-Zertifikat'
            Write-ScriptLog "Verwende $authLabel via HTTPS für $Servername"
            try {
              $sessionParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $svcCredential
              $sessionParams.ErrorAction = 'Stop'
              $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "Zertifikats-Download auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @sessionParams -ArgumentList $SucheOnline -ScriptBlock $sbWU_Full }
              $success = $true
              Write-ScriptLog "Verbindung mit Client-Zertifikat via HTTPS erfolgreich."
            }
            catch {
              Write-ScriptLog "Fehler mit Client-Zertifikat via HTTPS: $($_.Exception.Message)"
            }
          }

          # AD-Gerät: Standard Kerberos/Negotiate
          if (-not $success -and -not $svcCredential) {
            try {
              $sessionOptions = New-PSSessionOption -IncludePortInSPN
              $sessionParams = @{
                ComputerName  = $Servername
                ErrorAction   = 'Stop'
                SessionOption = $sessionOptions
              }
              $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "Update-Download auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @sessionParams -ArgumentList $SucheOnline -ScriptBlock $sbWU_Full }
              $success = $true
            }
            catch {
              throw "Verbindung zu $Servername fehlgeschlagen: $($_.Exception.Message)"
            }
          }
          if (-not $success) { throw "Zertifikats-Download auf $Servername fehlgeschlagen." }
        }

        Write-ScriptLog "Ergebnis des Downloads:"

        if ($UpdResult) {
          # Duplikate entfernen (Get-WindowsUpdate -Download gibt Updates manchmal doppelt zurück)
          $UpdResult = $UpdResult | Sort-Object -Property KB, ComputerName -Unique
          
          # Log-Ausgabe
          ($UpdResult | Select-Object ComputerName, Status, KB, Size, Title | Format-Table -AutoSize | Out-String) `
            -split "\r?\n" | ForEach-Object { if ($_) { Write-ScriptLog $_ } }

          # HTML-Tabelle
          $UpdResultFull += @($UpdResult)
          
          $RepBody += "<table>`n"
          $RepBody += "<tr><th>ComputerName</th><th>Status</th><th>KB</th><th>Size</th><th>Title</th></tr>`n"
          
          foreach ($upd in $UpdResult) {
            $RepBody += "<tr>"
            $RepBody += "<td>$($upd.ComputerName)</td>"
            $RepBody += "<td>$($upd.Status)</td>"
            $RepBody += "<td>$($upd.KB)</td>"
            $RepBody += "<td>$($upd.Size)</td>"
            $RepBody += "<td>$($upd.Title)</td>"
            $RepBody += "</tr>`n"
          }
          
          $RepBody += "</table>"

          $UpdCount += @($UpdResult).Count
        } else {
          Write-ScriptLog "... keine Updates zum Download verfügbar."
          $RepBody += "<div class='no-updates'>Keine Updates zum Download verfügbar.</div>"
        }

      }
      Catch {
        Write-ScriptLog ("Es ist ein Fehler bei Server " + $Servername + " aufgetreten!")
        Write-ScriptLog ($_.Exception.Message)
        $RepBody += "<div class='warning-box'><strong>Fehler aufgetreten!</strong> Details in der Logdatei.</div>"
      }
    }
  }

} else {
  $RepBody += "<div class='warning-box'><p>Der Abruf der Serverliste ist fehlgeschlagen!</p></div>"
}

# Linux und Home Assistant besitzen keinen getrennten Download-Cache. Der
# Download-Lauf führt deshalb nur die gemeinsame Ersteinrichtung aus, sofern
# nötig, und ermittelt anschließend ausschließlich lesend verfügbare Updates.
$linuxCheckScript = Join-Path $PSScriptRoot 'Install-Linux Updates.ps1'
if ($LinuxConfigured -and (Test-Path -LiteralPath $linuxCheckScript)) {
  try {
    Write-ScriptLog 'Linux: Kein separater Paketdownload verfügbar – prüfe Einrichtung und verfügbare Updates.'
    & $linuxCheckScript -CheckOnly
    $linuxStatsPath = Join-Path $PSScriptRoot 'linux_update_check_stats.json'
    if (Test-Path -LiteralPath $linuxStatsPath) {
      $linuxStats = Get-Content -LiteralPath $linuxStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $LinuxAvailableUpdateCount = [int]$linuxStats.UpdatesInstalled
      $LinuxCheckExecuted = $true
      $RepBody += "<div class='section-title'>🐧 Linux-Updates (nicht herunterladbar)</div>"
      $RepBody += "<div class='info-box'>Verfügbare Linux-Paketupdates: $LinuxAvailableUpdateCount. Linux lädt Updates erst während der Installation herunter.</div>"
    }
  }
  catch {
    Write-ScriptLog "WARNUNG: Linux-Prüfung im Download-Lauf fehlgeschlagen: $($_.Exception.Message)"
    $RepBody += "<div class='warning-box'>Linux-Prüfung fehlgeschlagen. Details im Log.</div>"
  }
}

$haCheckScript = Join-Path $PSScriptRoot 'Install-HomeAssistant Updates.ps1'
if ($HAConfigured -and (Test-Path -LiteralPath $haCheckScript)) {
  try {
    Write-ScriptLog 'Home Assistant: Kein separater Paketdownload verfügbar – prüfe Einrichtung und verfügbare Updates.'
    & $haCheckScript -CheckOnly
    $haStatsPath = Join-Path $PSScriptRoot 'ha_update_check_stats.json'
    if (Test-Path -LiteralPath $haStatsPath) {
      $haStats = Get-Content -LiteralPath $haStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $HAAvailableUpdateCount = [int]$haStats.AvailableUpdates
      $HACheckExecuted = $true
      $RepBody += "<div class='section-title'>🏠 Home-Assistant-Updates (nicht herunterladbar)</div>"
      $RepBody += "<div class='info-box'>Verfügbare Home-Assistant-Updates: $HAAvailableUpdateCount. Home Assistant lädt Updates erst während der Installation herunter.</div>"
    }
  }
  catch {
    Write-ScriptLog "WARNUNG: Home-Assistant-Prüfung im Download-Lauf fehlgeschlagen: $($_.Exception.Message)"
    $RepBody += "<div class='warning-box'>Home-Assistant-Prüfung fehlgeschlagen. Details im Log.</div>"
  }
}

# Zusammenfassung
$ScriptDuration = [math]::Round((New-TimeSpan -Start $ScriptStartTime).TotalMinutes, 2)

if ($UpdCount -eq 0) {
  $RepBody += @"
<div class="summary">
    <p><strong>Ergebnis: Es wurden KEINE Updates heruntergeladen!</strong></p>
    <p>Keine Updates verfügbar oder alle bereits heruntergeladen.</p>
</div>
"@
} else {
  $RepBody += @"
<div class="summary">
    <p><strong>Ergebnis: Es wurden $UpdCount Update(s) heruntergeladen!</strong></p>
    <p>Diese Updates können mit dem Install-ServersUpdates.ps1 Skript installiert werden.</p>
</div>
"@
}

$RepBody += @"
<div class="info-box">
    <p><strong>Statistik:</strong></p>
    <ul>
        <li>Verarbeitete Server: $Anzahl</li>
        <li>Heruntergeladene Updates: $UpdCount</li>
        <li>Verarbeitungsdauer: $ScriptDuration Minuten</li>
    </ul>
</div>
</body>
</html>
"@

if ($LinuxCheckExecuted) {
  $RepBody = $RepBody.Replace('        <li>Verarbeitungsdauer:', "        <li>Linux-Updates verfügbar (nicht separat herunterladbar): $LinuxAvailableUpdateCount</li>`n        <li>Verarbeitungsdauer:")
}
if ($HACheckExecuted) {
  $RepBody = $RepBody.Replace('        <li>Verarbeitungsdauer:', "        <li>Home-Assistant-Updates verfügbar (nicht separat herunterladbar): $HAAvailableUpdateCount</li>`n        <li>Verarbeitungsdauer:")
}

 $downloadSummaryLines = @(
  "PowerShell Version: $($PSVersionTable.PSVersion)",
  "Verarbeitete Server: $Anzahl",
  "Heruntergeladene Updates: $UpdCount",
  "Dauer: $ScriptDuration Minuten"
)
if ($LinuxCheckExecuted) { $downloadSummaryLines = $downloadSummaryLines[0..2] + "Linux-Updates verfügbar (nicht separat herunterladbar): $LinuxAvailableUpdateCount" + $downloadSummaryLines[3] }
if ($HACheckExecuted) { $downloadSummaryLines = $downloadSummaryLines[0..($downloadSummaryLines.Count - 2)] + "Home-Assistant-Updates verfügbar (nicht separat herunterladbar): $HAAvailableUpdateCount" + $downloadSummaryLines[-1] }
Write-WindowsUpdateConsoleSummary -Title 'UPDATE-DOWNLOAD ZUSAMMENFASSUNG' -Lines $downloadSummaryLines -WriteLog { param($message) Write-ScriptLog $message }

# E-Mail versenden
# SendMail und Subject direkt hier auswerten - sicher in PS5.1 und PS7
$mailBlock = $MailSettings.Download
$doSendMail = $false
if ($mailBlock -ne $null) {
  $doSendMail = [bool]$mailBlock.SendMail
  $companyName = [string]$MailSettings.CompanyName
  $subjectText = [string]$mailBlock.Subject
  if ([string]::IsNullOrWhiteSpace($subjectText)) { $subjectText = "Server Updates heruntergeladen" }
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
  Write-ScriptLog "Kein Mailversand (SendMail=false fuer Download)."
}

# Report speichern
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

Write-ScriptLog "Download abgeschlossen."
