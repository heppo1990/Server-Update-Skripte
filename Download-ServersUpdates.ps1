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


[CmdletBinding()]
param(
    # Interne, isolierte Windows-Zielworker; Gesamtbericht bleibt im Elternlauf.
    [string]$ParallelTarget,
    [string]$ParallelResultPath,
    [string]$ParallelContextPath,
    [string]$ParallelLogPath
)

# Ältere Windows-/PowerShell-Versionen verwenden sonst oft TLS 1.0 als Standard.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
# GitHub-Update beim Start: Die eingebundene Routine lädt nur benötigte Skriptdateien.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Komponenten\Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $scriptUpdateTemporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Komponenten/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $scriptUpdateTemporaryPath -ErrorAction Stop
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
if ($scriptUpdateLoaded -and -not $ParallelTarget) {
    Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RemainingArguments $args
}

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Module\WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

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
$Anzahl = 0
$WindowsUnreachableHosts = 0
$LinuxCheckExecuted = $false
$HACheckExecuted = $false
$LinuxCheckAttempted = $false
$HACheckAttempted = $false
$UpdResultFull = $null
$TimeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
if ($ParallelTarget) { $TimeStamp += '-worker-' + [guid]::NewGuid().ToString('N') }
$ScriptName = (Split-Path -Path ($MyInvocation.MyCommand.Name) -Leaf).Replace('.ps1','')
$LogFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_${TimeStamp}.log"
if ($ParallelTarget -and $ParallelLogPath) { $LogFileName = $ParallelLogPath }
$ReportFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_Report_${TimeStamp}.html"

############################################################################################################################################################################
# Funktionen
############################################################################################################################################################################

$script:DeploymentRequiredTargets = @()

function Write-ScriptLog ($Message, [bool]$LogOnly = $false) {
  Write-WindowsUpdateLog -Message $Message -LogFile $LogFileName -ScriptName $ScriptName -RunTimestamp $TimeStamp -WriteLogFile ([bool]($null -ne $UpdateSettings -and $UpdateSettings.WriteLogFile)) -LogOnly:$LogOnly
}

# Hauptskript
############################################################################################################################################################################

$ScriptStartTime = Get-Date
$psVersion = $PSVersionTable.PSVersion.Major

Write-Host ''
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host "Betriebssystem: $([System.Environment]::OSVersion.VersionString)" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ''

$Settings = Get-DownloadSettingsFromCommon
$linuxSettings = if ($Settings.PSObject.Properties['LinuxSettings']) { $Settings.LinuxSettings } else { $null }
$haSettings = if ($Settings.PSObject.Properties['HomeAssistantSettings']) { $Settings.HomeAssistantSettings } else { $null }
$LinuxConfigured = $null -ne $linuxSettings -and $linuxSettings.PSObject.Properties['Hosts'] -and @($linuxSettings.Hosts | Where-Object { $_ }).Count -gt 0
$HAConfigured = $null -ne $haSettings -and $haSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$haSettings.Host)
$LinuxConfiguredHostCount = if ($LinuxConfigured) { @($linuxSettings.Hosts | Where-Object { $_ }).Count } else { 0 }
$UpdateSettings = $Settings.UpdateSettings
if (-not $ParallelTarget) {
  $configuredParallelLimit = Get-WindowsUpdateParallelTargetLimit -Configuration $UpdateSettings
  $parallelNotice = if ($configuredParallelLimit -eq 1) { 'Verarbeitung: Ziele nacheinander; zuerst Windows-VMs, dann physische Windows-Systeme, danach Linux und Home Assistant.' } else { "Parallele Verarbeitung: maximal $configuredParallelLimit Windows-Ziele gleichzeitig; zuerst Windows-VMs, dann physische Windows-Systeme, danach Linux und Home Assistant." }
  Write-Host $parallelNotice -ForegroundColor Gray
}
$MailSettings = $Settings.MailSettings
$TargetComputers = $UpdateSettings.TargetComputers
if ([string]::IsNullOrWhiteSpace($TargetComputers)) {
    $TargetComputers = "Server"
}

$ServerADList = Get-WindowsUpdateTargets `
  -UpdateSettings $UpdateSettings `
  -TargetComputers $TargetComputers `
  -PowerShellMajor $psVersion `
  -LinuxTargetCount $LinuxConfiguredHostCount `
  -HomeAssistantTargetCount $(if ($HAConfigured) { 1 } else { 0 }) `
  -IncludeAdditionalTargetCounts `
  -WriteLog { param($message) Write-ScriptLog $message }

# HTML-Report mit modernem Design
$RepBody = New-WindowsUpdateDownloadReportHeader -ComputerName $ComputerFQDN -Timestamp $TimeStamp -PowerShellVersion ([string]$PSVersionTable.PSVersion)

# Server verarbeiten
# Gemeinsamer Phasenplan: Windows-VMs, Windows physisch, danach Linux und HA.
$executionOriginalWindows = @($ServerADList | Where-Object { $_ })
$executionOriginalLinux = $LinuxConfigured
$executionOriginalHA = $HAConfigured
if ($ParallelTarget) {
  # Der Elternlauf hat die Bauart bereits bestimmt; Worker planen nicht erneut.
  $executionPlan = [pscustomobject]@{Phases=@([pscustomobject]@{Name='Ziel';Targets=@($executionOriginalWindows | ForEach-Object { [pscustomobject]@{Platform='Windows';Name=$_.Name;Target=$_} })});Skipped=@()}
} else {
  $planLinux = if ($executionOriginalLinux) { $linuxSettings } else { $null }
  $planHA = if ($executionOriginalHA) { $haSettings } else { $null }
  $executionPlan = Get-WindowsUpdateExecutionPhases -WindowsTargets $executionOriginalWindows -UpdateSettings $UpdateSettings -LinuxSettings $planLinux -HomeAssistantSettings $planHA -WriteLog { param($message,$logOnly=$false) Write-ScriptLog $message -LogOnly:$logOnly }
  foreach ($skipped in @($executionPlan.Skipped)) {
    $RepBody += "<div class='warning-box'>Ziel $([Net.WebUtility]::HtmlEncode($skipped.Name)) übersprungen: Bauart nicht ermittelbar. $([Net.WebUtility]::HtmlEncode($skipped.Reason))</div>"
    if ($skipped.Platform -eq 'Windows' -and $skipped.Unreachable) { $WindowsUnreachableHosts++ }
  }
}
foreach ($executionPhase in @($executionPlan.Phases)) {
  if (@($executionPhase.Targets).Count -eq 0) { continue }
  $ServerADList = @($executionPhase.Targets | Where-Object Platform -eq Windows | ForEach-Object { $_.Target })
  $LinuxTargetHosts = @($executionPhase.Targets | Where-Object Platform -eq Linux | ForEach-Object { $_.Name })
  $LinuxConfigured = $LinuxTargetHosts.Count -gt 0
  $HAConfigured = @($executionPhase.Targets | Where-Object Platform -eq HomeAssistant).Count -gt 0
  if (-not $ParallelTarget) { Write-ScriptLog "Verarbeitungsphase: $($executionPhase.Name)." -LogOnly:$true }
if ($ServerADList.Count -gt 0) {

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



  # Begrenzte parallele Erreichbarkeitsprüfung, ohne konkurrierende Änderungen,
  # Berichtsdateien oder Update-/Neustartprozesse auf den Zielen.
  if ($ParallelTarget) { $ServerADList = @($ServerADList | Where-Object { $_.Name -ieq $ParallelTarget }) }
  $probeLimit = 4
  if ($UpdateSettings.PSObject.Properties['ParallelProbeLimit']) { $probeLimit = [Math]::Max(1,[Math]::Min(8,[int]$UpdateSettings.ParallelProbeLimit)) }
  $winRmProbeResults = Get-WindowsUpdateWinRmProbeBatch -ComputerName @($ServerADList | ForEach-Object { $_.Name }) -ThrottleLimit $probeLimit
  $parallelLimit = Get-WindowsUpdateParallelTargetLimit -Configuration $UpdateSettings
  if ($ParallelTarget) {
    $ServerADList = @($ServerADList | Where-Object { $_.Name -ieq $ParallelTarget })
    if ($ServerADList.Count -ne 1) { throw 'Parallelziel ist nicht eindeutig in der konfigurierten Zielliste vorhanden.' }
    $Anzahl = 1
    if ($ParallelContextPath) {
      $workerContext = Import-Clixml -LiteralPath $ParallelContextPath
      foreach ($key in $workerContext.Keys) { Set-Variable -Name $key -Value $workerContext[$key] -Scope Script }
    }
  }
  $workerReportPrefixLength = $RepBody.Length
  $parallelCounters = @('UpdCount','WindowsUnreachableHosts')
  $parallelArrays = @('UpdResultFull','DeploymentRequiredTargets')
  if (-not $ParallelTarget -and $parallelLimit -gt 1 -and @($ServerADList).Count -gt 1) {
    $context = @{}
    foreach ($key in @('ManagementPowerShellUpdateExcludeId','ManagementPowerShellUpdateExcludeChocolateyId','SkipWingetUserUpdates')) {
      $value = Get-Variable -Name $key -ValueOnly -ErrorAction SilentlyContinue
      if ($null -ne $value) { $context[$key] = $value }
    }
    $batchResults = @(Invoke-WindowsUpdateTargetBatch -ScriptPath $PSCommandPath -Targets @($ServerADList) -ThrottleLimit $parallelLimit -Context $context -WriteLog { param($message, $logOnly = $false) Write-ScriptLog $message -LogOnly:$logOnly })
    foreach ($workerResult in $batchResults) {
      $RepBody += [string]$workerResult.Html
      foreach ($key in $parallelCounters) {
        $current = Get-Variable -Name $key -ValueOnly -ErrorAction SilentlyContinue
        Set-Variable -Name $key -Value ([int]$current + [int]$workerResult.Data[$key]) -Scope Script
      }
      foreach ($key in $parallelArrays) {
        $existingRows = Get-Variable -Name $key -ValueOnly -ErrorAction SilentlyContinue
        $mergedRows = @()
        foreach ($row in $existingRows) { if ($null -ne $row) { $mergedRows += $row } }
        foreach ($row in $workerResult.Data[$key]) { if ($null -ne $row) { $mergedRows += $row } }
        Set-Variable -Name $key -Value $mergedRows -Scope Script
      }
      if ($workerResult.Data.ContainsKey('PendingPhysicalReboots')) { foreach ($request in @($workerResult.Data.PendingPhysicalReboots)) { $script:PendingPhysicalReboots.Add($request) } }
      if ($workerResult.Data.ContainsKey('DeferredLocalReboot') -and $workerResult.Data.DeferredLocalReboot) { $script:DeferredLocalReboot = $workerResult.Data.DeferredLocalReboot }
      if ($workerResult.Data.ContainsKey('VMRebootLatestAt') -and $workerResult.Data.VMRebootLatestAt -and ($null -eq $script:VMRebootLatestAt -or $workerResult.Data.VMRebootLatestAt -gt $script:VMRebootLatestAt)) { $script:VMRebootLatestAt = $workerResult.Data.VMRebootLatestAt }
    }
  } else {
ForEach ($Server in $ServerADList) {
    $index += 1
    $Servername = $Server.Name
    $isLocalManagementTarget = $Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ComputerFQDN

    if (!([String]::IsNullOrWhiteSpace($Servername))) {
      if ($Anzahl -ne 0) { $PercCompl = $index * 100 / $Anzahl } else { $PercCompl = 100 }
      Write-Progress -Activity "Verarbeite AD-Serverliste" -Status "Verarbeite Server [$Servername] (Nr. $index von $Anzahl)" -PercentComplete $PercCompl

      Try {
        if ($index -gt 1) { Write-ScriptLog '' }
        Write-ScriptLog "Starte Update-Download auf AD-Server $Servername..."
        $RepBody += "<div class='server-title'>Server: ${Servername}</div>"

        $winRmProbe = $winRmProbeResults[$Servername]
        if (-not $winRmProbe.Reachable) {
          $WindowsUnreachableHosts++
          $skipMessage = "WinRM über HTTP (5985) und HTTPS (5986) ist nach $($winRmProbe.AttemptsPerformed) Prüfversuch(en) nicht erreichbar; Ziel wird in diesem Lauf übersprungen."
          Write-ScriptLog "HINWEIS: $Servername – $skipMessage"
          Write-WindowsUpdateConsoleLine -Message "  [Übersprungen] WinRM-Ports 5985/5986 auch nach $($winRmProbe.AttemptsPerformed) Prüfversuchen nicht erreichbar." -AlreadyFiltered
          $serverHtml = [System.Net.WebUtility]::HtmlEncode([string]$Servername)
          $skipHtml = [System.Net.WebUtility]::HtmlEncode($skipMessage)
          $RepBody += "<div class='warning-box'><strong>Download auf $serverHtml übersprungen.</strong> $skipHtml</div>"
          continue
        }
        Write-ScriptLog "WinRM-Portprüfung auf ${Servername}: 5985=$(if (5985 -in $winRmProbe.OpenPorts) { 'offen' } else { 'geschlossen' }); 5986=$(if (5986 -in $winRmProbe.OpenPorts) { 'offen' } else { 'geschlossen' }); erfolgreich nach $($winRmProbe.AttemptsPerformed) Prüfversuch(en)." $true

        $UpdResult = $null

        # Nicht-AD-Ziele erhalten TrustedHosts und Zertifikatsauthentifizierung
        # zentral; AD-Ziele bleiben bei Kerberos ohne Zertifikat.
        $remoting = Initialize-WindowsUpdateRemoting -UpdateSettings $UpdateSettings -TargetComputer $Servername -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        $svcCredential = $remoting.AuthInfo
        $versionParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $svcCredential -OpenTimeoutSeconds 10 -OperationTimeoutSeconds 60
        $deploymentRequirement = Test-WindowsUpdateDeploymentRequirement -InvokeParameters $versionParameters
        if ($deploymentRequirement.RequiresDeployment) {
          $deploymentNotice = "Erneute WindowsUpdateAdm-Verteilung auf $Servername erforderlich: $($deploymentRequirement.Reason) Der Lauf wird mit dem vorhandenen Stand trotzdem versucht."
          Write-ScriptLog $deploymentNotice -LogOnly:$true
          $script:DeploymentRequiredTargets += $Servername

        }

        # Teste ob WindowsUpdateAdm verfügbar ist
        $useJEA = $false
        $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $svcCredential -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        if ($jeaSupported) {
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
            if ($isLocalManagementTarget) {
              Write-ScriptLog "FEHLER: WindowsUpdateAdm auf dem Verwaltungsserver $Servername ist nicht erreichbar; der Download wird ohne lokalen Fallback abgebrochen."
              Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'JEA-Verbindungstest' -Target $Servername -ErrorRecord $_ -Context @('Fallback=keiner; lokale Windows-Zieloperationen müssen über WindowsUpdateAdm/JEA laufen')
              throw "WindowsUpdateAdm auf dem Verwaltungsserver $Servername ist nicht erreichbar; Download abgebrochen."
            }
            Write-ScriptLog "INFO: '$Servername' nutzt Standard-Remoting (WindowsUpdateAdm nicht verfügbar; Details im Log)."
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'JEA-Verbindungstest' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Standard-Remoting')
          }
        }

        # Updates herunterladen
        if ($useJEA) {
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
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'JEA-Download' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Download wird als Fehler behandelt; keine alternative Quelle angenommen')
            if ($msg -match "Get-WindowsUpdate.*not recognized") {
              throw "WindowsUpdateAdm Endpoint hat kein Get-WindowsUpdate verfügbar."
            }
            throw
          }
        } elseif ($isLocalManagementTarget) {
          $reason = 'WindowsUpdateAdm/JEA ist auf dem Verwaltungsserver nicht verfügbar; direkter lokaler oder uneingeschränkter Loopback-Fallback ist deaktiviert.'
          Write-ScriptLog "FEHLER: $reason"
          Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly:$true } -Operation 'JEA-Download-Verwaltungsserver' -Target $Servername -ErrorRecord ([InvalidOperationException]::new($reason)) -Context @('Fallback=keiner')
          throw $reason
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
              Write-ScriptLog "WARNUNG: Client-Zertifikat-Verbindung zu $Servername fehlgeschlagen; Details im Log."
              Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'WinRM-Download-Certificate' -Target $Servername -ErrorRecord $_
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
              Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'WinRM-Download' -Target $Servername -ErrorRecord $_
              throw "Verbindung zu $Servername fehlgeschlagen; Details stehen im Laufprotokoll."
            }
          }
          if (-not $success) { throw "Zertifikats-Download auf $Servername fehlgeschlagen." }
        }

        Write-ScriptLog "Ergebnis des Downloads:"

        if ($UpdResult) {
          $downloadResult = ConvertTo-WindowsUpdateDownloadResult -Updates @($UpdResult)
          $UpdResult = @($downloadResult.Updates)

          foreach ($tableLine in $downloadResult.TableLines) {
            if (-not [string]::IsNullOrWhiteSpace($tableLine)) { Write-ScriptLog $tableLine }
          }

          $UpdResultFull += $UpdResult
          $RepBody += "<table>`n"
          $RepBody += "<tr><th>ComputerName</th><th>Status</th><th>KB</th><th>Size</th><th>Title</th></tr>`n"
          foreach ($upd in $downloadResult.HtmlRows) {
            $RepBody += "<tr><td>$($upd.ComputerName)</td><td>$($upd.Status)</td><td>$($upd.KB)</td><td>$($upd.Size)</td><td>$($upd.Title)</td></tr>`n"
          }
          $RepBody += "</table>"
          $UpdCount += $downloadResult.Count
        } else {
          Write-ScriptLog "... es sind keine Windows-Updates verfügbar."
          $RepBody += "<div class='no-updates'>Keine Updates zum Download verfügbar.</div>"
        }
        Write-ScriptLog ''

      }
      Catch {
        Write-ScriptLog ("Es ist ein Fehler bei Server " + $Servername + " aufgetreten!")
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'WindowsUpdate-Download' -Target $Servername -ErrorRecord $_
        $RepBody += "<div class='warning-box'><strong>Fehler aufgetreten!</strong> Details in der Logdatei.</div>"
      }
    }
  }
  }
  if ($ParallelTarget) {
    $workerData = @{}
    foreach ($key in @($parallelCounters + $parallelArrays + @('PendingPhysicalReboots','DeferredLocalReboot','VMRebootLatestAt'))) {
      $variable = Get-Variable -Name $key -ErrorAction SilentlyContinue
      if ($variable) { $workerData[$key] = $variable.Value }
    }
    [pscustomobject]@{Target=$ParallelTarget;Html=$RepBody.Substring($workerReportPrefixLength);Data=$workerData;LogFile=$LogFileName} | Export-Clixml -LiteralPath $ParallelResultPath -Depth 16
    exit 0
  }

}

# Linux und Home Assistant besitzen keinen getrennten Download-Cache. Der
# Download-Lauf führt deshalb nur die gemeinsame Ersteinrichtung aus, sofern
# nötig, und ermittelt anschließend ausschließlich lesend verfügbare Updates.
$linuxStatsPath = Join-Path (Join-Path $PSScriptRoot 'Logs') 'linux_update_check_stats.json'
$haStatsPath = Join-Path (Join-Path $PSScriptRoot 'Logs') 'ha_update_check_stats.json'
# Alte Ergebnisse eines abgebrochenen Laufs nicht weiterverwenden; beide
# Dateien dienen nur als temporärer Übergabekanal der CheckOnly-Aufrufe.
foreach ($staleStatsPath in @($linuxStatsPath, $haStatsPath)) {
  Remove-Item -LiteralPath $staleStatsPath -Force -ErrorAction SilentlyContinue
}

$linuxCheckScript = Join-Path $PSScriptRoot 'Komponenten\Install-Linux Updates.ps1'
if ($LinuxConfigured -and (Test-Path -LiteralPath $linuxCheckScript)) {
  $LinuxCheckAttempted = $true
  try {
    Write-ScriptLog 'Linux: Kein separater Paketdownload verfügbar – prüfe Einrichtung und verfügbare Updates.'
    # SSH-Eingabeaufforderungen müssen sichtbar bleiben; das Kinderskript ist
    # im Quiet-Modus, damit nur echte SSH-Prompts die Konsole erreichen.
    $sharedAuxLog = if ($UpdateSettings.WriteLogFile) { $LogFileName } else { '' }
    & $linuxCheckScript -TargetHost $LinuxTargetHosts -CheckOnly -Quiet -NoSeparateLog -SharedLogPath $sharedAuxLog
    if (Test-Path -LiteralPath $linuxStatsPath) {
      $linuxStats = Get-Content -LiteralPath $linuxStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $LinuxAvailableUpdateCount += [int]$linuxStats.UpdatesInstalled
      $LinuxCheckExecuted = $true
      foreach ($linuxHost in @($linuxStats.HostStatus)) {
        if ([int]$linuxHost.UpdateCount -gt 0) {
          $packageList = if ($linuxHost.PSObject.Properties['PackageList']) { @($linuxHost.PackageList) } else { @(([string]$linuxHost.Packages -split ',\s*') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
          Write-ScriptLog "Linux auf $($linuxHost.Host): $($linuxHost.UpdateCount) Paketupdates verfügbar."
          foreach ($package in $packageList) { Write-ScriptLog "  $($linuxHost.Host): $package" }
        } else {
          Write-ScriptLog "Linux auf $($linuxHost.Host): keine Paketupdates verfügbar."
        }
        Write-ScriptLog ''
      }
      $RepBody += "<div class='section-title'>🐧 Linux-Updates (nicht herunterladbar)</div>"
      $RepBody += "<div class='info-box'>Verfügbare Linux-Paketupdates: $LinuxAvailableUpdateCount. Linux lädt Updates erst während der Installation herunter.</div>"
    }
  }
  catch {
    Write-ScriptLog 'WARNUNG: Linux-Prüfung im Download-Lauf fehlgeschlagen; Details im Log.'
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'Linux-Check-Download' -Target 'Linux' -ErrorRecord $_
    $RepBody += "<div class='warning-box'>Linux-Prüfung fehlgeschlagen. Details im Log.</div>"
  }
  finally {
    Remove-Item -LiteralPath $linuxStatsPath -Force -ErrorAction SilentlyContinue
  }
}

$haCheckScript = Join-Path $PSScriptRoot 'Komponenten\Install-HomeAssistant Updates.ps1'
if ($HAConfigured -and (Test-Path -LiteralPath $haCheckScript)) {
  $HACheckAttempted = $true
  try {
    Write-ScriptLog 'Home Assistant: Kein separater Paketdownload verfügbar – prüfe Einrichtung und verfügbare Updates.'
    $sharedAuxLog = if ($UpdateSettings.WriteLogFile) { $LogFileName } else { '' }
    & $haCheckScript -CheckOnly -Quiet -NoSeparateLog -SharedLogPath $sharedAuxLog
    if (Test-Path -LiteralPath $haStatsPath) {
      $haStats = Get-Content -LiteralPath $haStatsPath -Raw -Encoding UTF8 | ConvertFrom-Json
      $HAAvailableUpdateCount = [int]$haStats.AvailableUpdates
      $HACheckExecuted = $true
      foreach ($detail in @($haStats.UpdateDetails)) {
        Write-ScriptLog ("Home Assistant auf {0}: {1} {2} → {3}" -f $haStats.Host, $detail.Component, $detail.Current, $detail.Available)
      }
      if ($HAAvailableUpdateCount -eq 0) { Write-ScriptLog "Home Assistant auf $($haStats.Host): keine Updates verfügbar." }
      Write-ScriptLog ''
      $RepBody += "<div class='section-title'>🏠 Home-Assistant-Updates (nicht herunterladbar)</div>"
      $RepBody += "<div class='info-box'>Verfügbare Home-Assistant-Updates: $HAAvailableUpdateCount. Home Assistant lädt Updates erst während der Installation herunter.</div>"
    }
  }
  catch {
    Write-ScriptLog 'WARNUNG: Home-Assistant-Prüfung im Download-Lauf fehlgeschlagen; Details im Log.'
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message } -Operation 'HomeAssistant-Check-Download' -Target ([string]$haSettings.Host) -ErrorRecord $_
    $RepBody += "<div class='warning-box'>Home-Assistant-Prüfung fehlgeschlagen. Details im Log.</div>"
  }
  finally {
    Remove-Item -LiteralPath $haStatsPath -Force -ErrorAction SilentlyContinue
  }
}

}
# Für die Gesamtzählung wieder die vollständigen konfigurierten Ziele verwenden.
$ServerADList = $executionOriginalWindows
$Anzahl = $executionOriginalWindows.Count
$LinuxConfigured = $executionOriginalLinux
$HAConfigured = $executionOriginalHA
$LinuxCheckAttempted = $executionOriginalLinux
$HACheckAttempted = $executionOriginalHA
# Zusammenfassung
$ScriptDuration = [math]::Round((New-TimeSpan -Start $ScriptStartTime).TotalMinutes, 2)
$ProcessedSystemCount = $Anzahl + $(if ($LinuxCheckAttempted) { $LinuxConfiguredHostCount } else { 0 }) + $(if ($HACheckAttempted) { 1 } else { 0 })
$processedSystemParts = @()
if ($Anzahl -gt 0) { $processedSystemParts += "Windows: $Anzahl" }
if ($LinuxCheckAttempted -and $LinuxConfiguredHostCount -gt 0) { $processedSystemParts += "Linux: $LinuxConfiguredHostCount" }
if ($HACheckAttempted) { $processedSystemParts += 'Home Assistant: 1' }
$processedSystemBreakdown = $processedSystemParts -join ', '

if ($script:DeploymentRequiredTargets.Count -gt 0) {
  $deploymentSummary = New-WindowsUpdateDeploymentNotice -Targets @($script:DeploymentRequiredTargets | Sort-Object -Unique) -ScriptRoot $PSScriptRoot -ManagementServer $env:COMPUTERNAME
  Write-ScriptLog $deploymentSummary.Text
  $RepBody += $deploymentSummary.Html
}
$RepBody = Complete-WindowsUpdateDownloadReport -ReportBody $RepBody -DownloadedUpdateCount $UpdCount -UnreachableWindowsCount $WindowsUnreachableHosts -ProcessedSystemCount $ProcessedSystemCount -ProcessedSystemBreakdown $processedSystemBreakdown -DurationMinutes ([string]$ScriptDuration) -IncludeLinux:$LinuxCheckExecuted -LinuxAvailableUpdateCount $LinuxAvailableUpdateCount -IncludeHomeAssistant:$HACheckExecuted -HomeAssistantAvailableUpdateCount $HAAvailableUpdateCount
$downloadSummaryLines = New-WindowsUpdateDownloadConsoleSummary -PowerShellVersion ([string]$PSVersionTable.PSVersion) -ProcessedSystemCount $ProcessedSystemCount -ProcessedSystemBreakdown $processedSystemBreakdown -DownloadedUpdateCount $UpdCount -UnreachableWindowsCount $WindowsUnreachableHosts -IncludeLinux:$LinuxCheckExecuted -LinuxAvailableUpdateCount $LinuxAvailableUpdateCount -IncludeHomeAssistant:$HACheckExecuted -HomeAssistantAvailableUpdateCount $HAAvailableUpdateCount -DurationMinutes ([string]$ScriptDuration)
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
