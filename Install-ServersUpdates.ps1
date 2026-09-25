#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Install-ServersUpdates.ps1
    Umfassendes Update-Management für Windows-Server, Linux und Home Assistant
    
.DESCRIPTION
    - Windows Updates (PSWindowsUpdate) - Installation
    - Package Manager Updates (Chocolatey, Winget)
    - Linux Updates (via externes Skript)
    - Home Assistant Updates (via externes Skript)
    - HTML-Reports & E-Mail-Benachrichtigung
    - PowerShell 7 kompatibel (Server 2016-2025)
    - Unterstützt zusätzliche Geräte außerhalb der AD via "AdditionalComputers" in der Settings-JSON
    
.PARAMETER Debug
    Aktiviert erweiterte Debug-Ausgaben
    
.EXAMPLE
    .\Install-ServersUpdates.ps1
    Führt das Skript ohne Debug-Ausgaben aus
    
.EXAMPLE
    .\Install-ServersUpdates.ps1 -Debug
    Führt das Skript mit erweiterten Debug-Informationen aus

.EXAMPLE
    # Standardaufruf - installiert Updates auf allen Servern
    .\Install-ServersUpdates.ps1

.EXAMPLE
    # Mit PowerShell 7
    pwsh.exe -ExecutionPolicy Bypass -File ".\Install-ServersUpdates.ps1"

.EXAMPLE
    # Als geplante Aufgabe: „Starten in“ auf den Skriptordner setzen, dann:
    powershell.exe -NonInteractive -ExecutionPolicy Bypass -File ".\Install-ServersUpdates.ps1"

#>

[CmdletBinding()]
param(
    [switch]$DebugMode,
    # Optional: begrenzt einen Lauf auf die angegebenen Server, z. B. -TargetComputer SrvHV01
    [Alias('ComputerName')]
    [string[]]$TargetComputer,
    # Sendet ausschließlich eine Testmail aus dem SYSTEM-Kontext des Zielservers.
    [switch]$TestDeferredMail
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

function Get-InstallSettingsFromCommon {
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
$WindowsUpdateDetails = @()
$PackageUpdateDetails = @()
$PackageUpdateCount = 0
$WingetUpdateCount = 0
$ChocolateyUpdateCount = 0
$LinuxUpdateDetails = @()
$script:VMRebootIndex = 0
$script:VMRebootLatestAt = $null
$script:PendingPhysicalReboots = [System.Collections.Generic.List[object]]::new()
$script:PendingLinuxPhysicalReboots = [System.Collections.Generic.List[object]]::new()
$script:PendingHAPhysicalReboots = [System.Collections.Generic.List[object]]::new()
$script:DeferredLocalReboot = $null
$UpdResultFull = $null
$TimeStamp = Get-Date -Format "yyyy-MM-dd_HH-mm"
$ScriptName = (Split-Path -Path ($MyInvocation.MyCommand.Name) -Leaf).Replace('.ps1','')
$LogFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_${TimeStamp}.log"
$ReportFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_Report_${TimeStamp}.html"

############################################################################################################################################################################
# Funktionen
############################################################################################################################################################################

function Write-ScriptLog {
  param(
    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [string]$Message = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$IsDebug
  )
  
  Write-WindowsUpdateLog -Message $Message -LogFile $LogFileName -ScriptName $ScriptName -RunTimestamp $TimeStamp -WriteLogFile ([bool]($null -ne $UpdateSettings -and $UpdateSettings.WriteLogFile)) -IsDebug:$IsDebug -DebugEnabled ([bool]$DebugMode)
}

function Invoke-PackageManagerUpdates {
  param(
    [Parameter(Mandatory)][string]$Servername,
    $AuthInfo = $null
  )

  try {
    $enableWinget = if ($UpdateSettings.PSObject.Properties['EnableWingetUpdates']) { [bool]$UpdateSettings.EnableWingetUpdates } else { $true }
    $enableChocolatey = if ($UpdateSettings.PSObject.Properties['EnableChocolateyUpdates']) { [bool]$UpdateSettings.EnableChocolateyUpdates } else { $true }
    $results = @(Invoke-WindowsUpdatePackageManagers -ComputerName $Servername -AuthInfo $AuthInfo -Mode Install -EnableWinget $enableWinget -EnableChocolatey $enableChocolatey)
    foreach ($result in $results) {
      if ($result.Skipped) {
        $skipReason = if ([string]::IsNullOrWhiteSpace([string]$result.SkipReason)) { 'ohne Angabe eines Grundes' } else { [string]$result.SkipReason }
        Write-ScriptLog "$($result.Manager)-Update auf ${Servername} übersprungen: $skipReason."
        continue
      }
      if (-not $result.Available) {
        Write-ScriptLog "$($result.Manager) ist auf $Servername nicht installiert."
        continue
      }
      if (-not $result.Success) {
        Write-ScriptLog "Fehler bei $($result.Manager) auf ${Servername}: $($result.ActionOutput)"
        continue
      }

      $packageCount = @($result.Packages).Count
      if ($packageCount -eq 0) {
        Write-ScriptLog "$($result.Manager) auf ${Servername}: Keine Paketupdates verfügbar."
        continue
      }

      Write-ScriptLog "$($result.Manager) auf ${Servername}: $packageCount Paketupdate(s) erkannt und verarbeitet."
      foreach ($package in @($result.Packages)) {
        Write-ScriptLog "  ${Servername}: $package"
      }
      if ($DebugMode -and -not [string]::IsNullOrWhiteSpace([string]$result.ActionOutput)) {
        Write-ScriptLog "Vollständiger $($result.Manager)-Output von ${Servername}:" -IsDebug
        $result.ActionOutput -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-ScriptLog "  $_" -IsDebug }
      }
    }
    return $results
  }
  catch {
    Write-ScriptLog "Fehler bei Package-Manager-Updates auf ${Servername}: $($_.Exception.Message)"
    return @()
  }
}

function Invoke-WindowsUpdates {
  param(
    [Parameter(Mandatory)][string]$Servername,
    [bool]$SucheOnline,
    $AuthInfo = $null,
    [string[]]$DeferredCategories = @(),
    [string[]]$DeferredKBs = @(),
    [bool]$DeferredOnly = $false
  )
  
  try {
    Write-ScriptLog "Starte Windows-Updates auf ${Servername}..."
    
    $LocalFqdn2 = "$($env:COMPUTERNAME).$($env:USERDNSDOMAIN)"
    $IsLocal = $Servername -ieq $env:COMPUTERNAME -or 
               $Servername -ieq $ComputerFQDN -or 
               $Servername -ieq $LocalFqdn2
    
    if ($IsLocal) {
      if (-not (Get-Module -Name PSWindowsUpdate)) { Import-Module PSWindowsUpdate -ErrorAction Stop }
      $wuParams = @{ AcceptAll = $true; Install = $true; IgnoreReboot = $true }
      if ($SucheOnline) { $wuParams.MicrosoftUpdate = $true }
            if (-not $DeferredOnly) {
              if ($DeferredCategories.Count -gt 0) { $wuParams.NotCategory = $DeferredCategories }
              if ($DeferredKBs.Count -gt 0) { $wuParams.NotKBArticleID = $DeferredKBs }
            }
      if ($DeferredOnly) {
        $UpdResult = @()
        foreach ($kb in $DeferredKBs) { $UpdResult += @(Get-WindowsUpdate @wuParams -KBArticleID $kb) }
        foreach ($category in $DeferredCategories) { $UpdResult += @(Get-WindowsUpdate @wuParams -Category $category) }
      } else { $UpdResult = Get-WindowsUpdate @wuParams }
    } else {
      $useJEA = $false
      $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-ScriptLog $message }
      if ($jeaSupported) {
      try {
        $jeaTestParams = @{
          ComputerName      = $Servername
          ConfigurationName = 'WindowsUpdateAdm'
          ScriptBlock       = { 1 }
          ErrorAction       = 'Stop'
        }
        if ($AuthInfo) {
          $authParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
          foreach ($key in $authParams.Keys) { if ($key -ne 'ComputerName') { $jeaTestParams[$key] = $authParams[$key] } }
        }
        $null = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Verbindungstest auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaTestParams }
        $useJEA = $true
      } catch {
        Write-ScriptLog "INFO: WindowsUpdateAdm nicht verfügbar auf ${Servername}, nutze Standard-Remoting" -IsDebug
      }
      }
      
      if ($useJEA) {
        $jeaParams = @{
          ComputerName      = $Servername
          ConfigurationName = 'WindowsUpdateAdm'
          ArgumentList      = @($SucheOnline, $DeferredCategories, $DeferredKBs, $DeferredOnly)
          ErrorAction       = 'Stop'
          ScriptBlock       = {
            param($Online, $Categories, $KBs, $OnlyDeferred)
            $wuParams = @{ AcceptAll = $true; Install = $true; IgnoreReboot = $true }
            if ($Online) { $wuParams.MicrosoftUpdate = $true }
            if (-not $OnlyDeferred) {
              if ($Categories.Count -gt 0) { $wuParams.NotCategory = $Categories }
              if ($KBs.Count -gt 0) { $wuParams.NotKBArticleID = $KBs }
            }
            if ($OnlyDeferred) {
              $updates = @()
              foreach ($kb in $KBs) { $updates += @(Get-WindowsUpdate @wuParams -KBArticleID $kb) }
              foreach ($category in $Categories) { $updates += @(Get-WindowsUpdate @wuParams -Category $category) }
              $updates
            } else { Get-WindowsUpdate @wuParams }
          }
        }
        if ($AuthInfo) {
          $authParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
          foreach ($key in $authParams.Keys) { if ($key -ne 'ComputerName') { $jeaParams[$key] = $authParams[$key] } }
        }
        $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Update-Installation auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaParams }
      } elseif (-not $jeaSupported -and $AuthInfo) {
        # Windows Server 2016 außerhalb der AD: Der über das Client-Zertifikat
        # gemappte Administrator hat keinen vollständigen Windows-Update-Zugriff.
        # Daher führt eine selbstlöschende SYSTEM-Aufgabe die Installation aus.
        Write-ScriptLog "Remote Update-Installation als SYSTEM-Aufgabe auf ${Servername}..."
        $UpdResult = Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode Install -SearchOnline $SucheOnline -DeferredCategories $DeferredCategories -DeferredKBs $DeferredKBs -DeferredOnly $DeferredOnly -WriteLog { param($message) Write-ScriptLog $message }
      } else {
        $success = $false

        # Nicht-AD-Gerät: HTTPS mit geprüftem Client- und Serverzertifikat.
        if ($AuthInfo) {
          Write-ScriptLog "Verwende Client-Zertifikat via HTTPS für ${Servername}" -IsDebug
          try {
            $sessionParams = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
            $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "Zertifikats-Update-Installation auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @sessionParams -ArgumentList @($SucheOnline, $DeferredCategories, $DeferredKBs, $DeferredOnly) -ScriptBlock {
              param($Online, $Categories, $KBs, $OnlyDeferred)
              Import-Module PSWindowsUpdate -ErrorAction Stop
              $wuParams = @{ AcceptAll = $true; Install = $true; IgnoreReboot = $true }
              if ($Online) { $wuParams.MicrosoftUpdate = $true }
              if (-not $OnlyDeferred) {
                if ($Categories.Count -gt 0) { $wuParams.NotCategory = $Categories }
                if ($KBs.Count -gt 0) { $wuParams.NotKBArticleID = $KBs }
              }
              if ($OnlyDeferred) {
                $updates = @()
                foreach ($kb in $KBs) { $updates += @(Get-WindowsUpdate @wuParams -KBArticleID $kb) }
                foreach ($category in $Categories) { $updates += @(Get-WindowsUpdate @wuParams -Category $category) }
                $updates
              } else { Get-WindowsUpdate @wuParams }
            } }
            $success = $true
            Write-ScriptLog "Verbindung mit Client-Zertifikat via HTTPS erfolgreich." -IsDebug
          }
          catch {
            Write-ScriptLog "Fehler mit Client-Zertifikat via HTTPS: $($_.Exception.Message)"
          }
        }

        # AD-Gerät: Standard Kerberos/Negotiate
        if (-not $success -and -not $AuthInfo) {
          $sessionOptions = New-PSSessionOption -IncludePortInSPN
          $sessionParams = @{
            ComputerName  = $Servername
            ErrorAction   = 'Stop'
            SessionOption = $sessionOptions
          }
          $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "Update-Installation auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @sessionParams -ArgumentList $SucheOnline -ScriptBlock {
            param($Online)
            Import-Module PSWindowsUpdate -ErrorAction Stop
            if ($Online) {
              Get-WindowsUpdate -MicrosoftUpdate -AcceptAll -Install -IgnoreReboot
            } else {
              Get-WindowsUpdate -AcceptAll -Install -IgnoreReboot
            }
          } }
        }
        if (-not $success) { throw "Zertifikats-Update-Installation auf $Servername fehlgeschlagen." }
      }
    }
    
    if ($UpdResult) {
      $UpdResult = $UpdResult | Sort-Object -Property KB, ComputerName -Unique
      Write-ScriptLog "Windows-Updates installiert auf ${Servername}: $(@($UpdResult).Count) Update(s)"
    } else {
      Write-ScriptLog "Keine Windows-Updates installiert auf ${Servername}"
    }
    
    return @(,$UpdResult)
  }
  catch {
    Write-ScriptLog "Fehler bei Windows-Updates auf ${Servername}: $($_.Exception.Message)"
    return @()
  }
}

function Get-DeferredWindowsUpdates {
  <#
    Prüft ausschließlich die für die Nachinstallation konfigurierte Auswahl.
    Ein Prüfungsfehler ist absichtlich kein Grund, eine Neustart-/Nach-
    installationsaufgabe anzulegen: Im Zweifel wird nichts automatisch neu
    gestartet.
  #>
  param(
    [Parameter(Mandatory)][string]$Servername,
    [bool]$SucheOnline,
    $AuthInfo = $null,
    [string[]]$DeferredCategories = @(),
    [string[]]$DeferredKBs = @()
  )

  try {
    $isLocal = $Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ComputerFQDN
    $query = {
      param($Online, $Categories, $KBs)
      $wuParams = @{ AcceptAll = $true; IgnoreReboot = $true }
      if ($Online) { $wuParams.MicrosoftUpdate = $true }
      $updates = @()
      foreach ($kb in @($KBs)) { $updates += @(Get-WindowsUpdate @wuParams -KBArticleID $kb) }
      foreach ($category in @($Categories)) { $updates += @(Get-WindowsUpdate @wuParams -Category $category) }
      $updates
    }

    if ($isLocal) {
      if (-not (Get-Module -Name PSWindowsUpdate)) { Import-Module PSWindowsUpdate -ErrorAction Stop }
      $updates = @(& $query $SucheOnline $DeferredCategories $DeferredKBs)
    }
    else {
      $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-ScriptLog $message }
      if (-not $jeaSupported -and $AuthInfo) {
        Write-ScriptLog "Prüfe zurückgestellte Updates als SYSTEM-Aufgabe auf $Servername..."
        $updates = @(Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode Check -SearchOnline $SucheOnline -DeferredCategories $DeferredCategories -DeferredKBs $DeferredKBs -DeferredOnly $true -WriteLog { param($message) Write-ScriptLog $message })
      }
      else {
        $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo -ConfigurationName $(if ($jeaSupported) { 'WindowsUpdateAdm' } else { $null })
        $params.ScriptBlock = $query
        $params.ArgumentList = @($SucheOnline, $DeferredCategories, $DeferredKBs)
        $updates = @(Invoke-WindowsUpdateWithRetry -OperationName "Prüfung zurückgestellter Updates auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @params })
      }
    }
    return [PSCustomObject]@{ Success = $true; Updates = @($updates | Sort-Object KB, ComputerName -Unique); Error = '' }
  }
  catch {
    Write-ScriptLog "WARNUNG: Zurückgestellte Updates auf $Servername konnten nicht geprüft werden: $($_.Exception.Message)"
    return [PSCustomObject]@{ Success = $false; Updates = @(); Error = $_.Exception.Message }
  }
}

function Remove-DeferredUpdateTask {
  param([Parameter(Mandatory)][string]$Servername, $AuthInfo = $null)
  $taskName = 'WindowsUpdateAdm-DeferredUpdates'
  $removeTask = {
    param($Name)
    $workerPath = Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm') 'DeferredUpdates.ps1'
    if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
      Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
      $removed = $true
    } else {
      $removed = $false
    }
    Remove-Item -LiteralPath $workerPath -Force -ErrorAction SilentlyContinue
    return $removed
  }
  if ($Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ComputerFQDN) {
    $removed = [bool](& $removeTask $taskName)
  }
  else {
    $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-ScriptLog $message }
    if (-not $jeaSupported -and $AuthInfo) {
      # Auf Nicht-AD Server 2016 löscht SYSTEM die alte Aufgabe zuverlässig,
      # auch wenn der gemappte Zertifikat-Administrator dafür kein Recht hat.
      $result = @(Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode RemoveDeferredTask -WriteLog { param($message) Write-ScriptLog $message })
      $removed = [bool]($result | Select-Object -First 1 -ExpandProperty Removed)
    }
    else {
      $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
      $params.ScriptBlock = $removeTask; $params.ArgumentList = $taskName
      $removed = [bool](Invoke-WindowsUpdateWithRetry -OperationName "Entfernen der Nachinstallationsaufgabe auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @params })
    }
  }
  if ($removed) { Write-ScriptLog "Keine zurückgestellten Updates auf ${Servername}: vorhandene Nachinstallationsaufgabe wurde gelöscht." }
  else { Write-ScriptLog "Keine zurückgestellten Updates auf ${Servername}: keine Nachinstallationsaufgabe vorhanden." }
}

function Get-NextScheduledTime {
  param([Parameter(Mandatory)][string]$Time)
  if ([string]::IsNullOrWhiteSpace($Time)) { return $null }
  $parsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($Time, [ref]$parsed)) {
    throw "Ungültige Uhrzeit '$Time'. Erwartet wird z. B. 19:00."
  }
  $when = (Get-Date).Date.Add($parsed.TimeOfDay)
  if ($when -le (Get-Date)) { $when = $when.AddDays(1) }
  return $when
}

function Get-NextRebootTimeInWindow {
  param(
    [Parameter(Mandatory)][string]$StartTime,
    [string]$LatestTime,
    [int]$DelayMinutes = 0,
    [datetime]$NotBefore = [datetime]::MinValue,
    [switch]$PreferImmediate
  )
  if ($PreferImmediate) {
    $now = Get-Date
    $immediateAt = $now.AddMinutes(1 + $DelayMinutes)
    if ([string]::IsNullOrWhiteSpace($LatestTime) -or [string]::IsNullOrWhiteSpace($StartTime)) { return $immediateAt }
    $startParsed = [datetime]::MinValue
    $latestParsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($StartTime, [ref]$startParsed) -or -not [datetime]::TryParse($LatestTime, [ref]$latestParsed)) {
      throw 'Ungültige VM-Wartungsfenster-Uhrzeit für einen sofortigen Neustart.'
    }
    $windowStart = $now.Date.Add($startParsed.TimeOfDay)
    if ($now -lt $windowStart) { $windowStart = $windowStart.AddDays(-1) }
    $windowEnd = $windowStart.Date.Add($latestParsed.TimeOfDay)
    if ($windowEnd -le $windowStart) { $windowEnd = $windowEnd.AddDays(1) }
    if ($now -ge $windowStart -and $immediateAt -le $windowEnd) { return $immediateAt }
  }
  $start = Get-NextScheduledTime $StartTime
  if ([string]::IsNullOrWhiteSpace($LatestTime)) {
    $scheduled = $start.AddMinutes($DelayMinutes)
    while ($scheduled -lt $NotBefore) { $scheduled = $scheduled.AddDays(1) }
    return $scheduled
  }

  $latestParsed = [datetime]::MinValue
  if (-not [datetime]::TryParse($LatestTime, [ref]$latestParsed)) {
    throw "Ungültige späteste Neustartzeit '$LatestTime'. Erwartet wird z. B. 23:00."
  }
  $latest = $start.Date.Add($latestParsed.TimeOfDay)
  if ($latest -lt $start) { $latest = $latest.AddDays(1) }
  $scheduled = $start.AddMinutes($DelayMinutes)
  while ($scheduled -gt $latest -or $scheduled -lt $NotBefore) {
    $start = $start.AddDays(1)
    $latest = $latest.AddDays(1)
    $scheduled = $start.AddMinutes($DelayMinutes)
    if ($scheduled -gt $latest) {
      throw "Der Neustartversatz von $DelayMinutes Minute(n) liegt außerhalb des konfigurierten Wartungsfensters."
    }
  }
  return $scheduled
}

function Test-ServerIsVirtual {
  param([string]$Servername, $AuthInfo = $null)
  $sb = {
    $cs = Get-CimInstance Win32_ComputerSystem
    $bios = Get-CimInstance Win32_BIOS
    ($cs.Manufacturer + ' ' + $cs.Model + ' ' + $bios.Manufacturer) -match 'VMware|VirtualBox|Virtual Machine|KVM|QEMU|Xen|Bochs'
  }
  if ($Servername -ieq $env:COMPUTERNAME) { return (& $sb) }
  # Nicht-AD Windows Server 2016 kann den JEA-Endpunkt mit Client-Zertifikat
  # nicht im nötigen SYSTEM-Kontext nutzen. Die reine CIM-Abfrage funktioniert
  # über die geprüfte Standard-Zertifikatsverbindung des lokalen Admins.
  $configurationName = if (Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-ScriptLog $message }) { 'WindowsUpdateAdm' } else { $null }
  $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo -ConfigurationName $configurationName
  $params.ScriptBlock = $sb
  return [bool](Invoke-Command @params)
}

function Test-WindowsUpdateRebootRequired {
  param([string]$Servername, $AuthInfo = $null)
  $sb = {
    # -Silent verhindert die interaktive Rückfrage von PSWindowsUpdate.
    $status = Get-WURebootStatus -Silent -ErrorAction Stop
    if ($status -is [bool]) { return $status }
    if ($null -ne $status -and $null -ne $status.PSObject.Properties['RebootRequired']) {
      return [bool]$status.RebootRequired
    }
    return $false
  }
  if ($Servername -ieq $env:COMPUTERNAME) { return [bool](& $sb) }
  $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-ScriptLog $message }
  # Nicht-AD Server 2016 verweigert dem gemappten Zertifikat-Administrator
  # teilweise selbst Get-WURebootStatus. Die Abfrage läuft daher gleich wie
  # die Installation als selbstlöschende SYSTEM-Aufgabe.
  if (-not $jeaSupported -and $AuthInfo) {
    $systemResult = @(Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode RebootStatus -WriteLog { param($message) Write-ScriptLog $message })
    return [bool]($systemResult | Select-Object -First 1 -ExpandProperty RebootRequired)
  }
  $configurationName = if ($jeaSupported) { 'WindowsUpdateAdm' } else { $null }
  $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo -ConfigurationName $configurationName
  $params.ScriptBlock = $sb
  return [bool](Invoke-Command @params)
}

function Register-OneTimeRemoteTask {
  param(
    [Parameter(Mandatory)][string]$Servername,
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][datetime]$At,
    [Parameter(Mandatory)][string]$Script,
    $AuthInfo = $null
  )
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $sb = {
    param($Name, $RunAt, $Encoded)
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $Encoded"
    $trigger = New-ScheduledTaskTrigger -Once -At $RunAt
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
  }
  if ($Servername -ieq $env:COMPUTERNAME) { & $sb $TaskName $At $encoded; return }
  # Keine Erweiterung der JEA-Rechte: Aufgaben werden über die normale WinRM-Verbindung
  # des ohnehin administrativen Aufrufers angelegt.
  $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
  $params.ScriptBlock = $sb; $params.ArgumentList = @($TaskName, $At, $encoded)
  Invoke-WindowsUpdateWithRetry -OperationName "Remote-Aufgabe '$TaskName' auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @params | Out-Null }
}

function Register-StartupRemoteTask {
  param(
    [Parameter(Mandatory)][string]$Servername,
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$Script,
    $AuthInfo = $null,
    [datetime]$At = [datetime]::MinValue
  )
  # Der vollständige Worker ist für -EncodedCommand zu groß (Windows begrenzt
  # die Prozessbefehlszeile). Er wird geschützt als temporäre Datei abgelegt;
  # der Task-Aufruf selbst enthält nur noch den kurzen -File-Pfad.
  $sb = {
    param($Name, $WorkerScript, $RunAt)
    $WorkerPath = Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm') 'DeferredUpdates.ps1'
    New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerPath) -Force | Out-Null
    New-Item -ItemType File -Path $WorkerPath -Force | Out-Null
    # SMTP-Daten im Worker dürfen nur SYSTEM und lokale Administratoren lesen.
    $acl = New-Object System.Security.AccessControl.FileSecurity
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
      $identity = New-Object System.Security.Principal.SecurityIdentifier($sid)
      $rule = New-Object System.Security.AccessControl.FileSystemAccessRule($identity, 'FullControl', 'Allow')
      $acl.AddAccessRule($rule)
    }
    Set-Acl -LiteralPath $WorkerPath -AclObject $acl -ErrorAction Stop
    $utf8Bom = New-Object System.Text.UTF8Encoding($true)
    [System.IO.File]::WriteAllText($WorkerPath, $WorkerScript, $utf8Bom)
    # Der kurze Starthelfer protokolliert auch Parser-/Startfehler, bevor der
    # Worker seine eigene DeferredUpdates.log initialisieren kann.
    $workerPathLiteral = $WorkerPath.Replace("'", "''")
    $taskLogPath = Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-TaskRunner.log'
    $taskLogLiteral = $taskLogPath.Replace("'", "''")
    $runnerSource = @"
`$ErrorActionPreference = 'Stop'
`$taskLogPath = '$taskLogLiteral'
try {
  New-Item -ItemType Directory -Path (Split-Path -Parent `$taskLogPath) -Force | Out-Null
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Task-Starthelfer gestartet." | Add-Content -LiteralPath `$taskLogPath -Encoding UTF8
  & '$workerPathLiteral' *>> `$taskLogPath
  `$workerSucceeded = `$?
  if (-not `$workerSucceeded) { throw 'Der Worker wurde mit einem PowerShell-Fehler beendet; Details stehen in diesem Protokoll.' }
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  Worker-Aufruf beendet." | Add-Content -LiteralPath `$taskLogPath -Encoding UTF8
} catch {
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  FEHLER im Task-Starthelfer: `$($_ | Out-String)" | Add-Content -LiteralPath `$taskLogPath -Encoding UTF8
  exit 1
}
"@
    $runnerEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runnerSource))
    $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $runnerEncoded"
    # Bei gesetztem Wartungsfenster wird täglich zu dieser Uhrzeit und zusätzlich
    # direkt nach dem Systemstart geprüft. So kann die Nachinstallation nach
    # Ablauf der Mindestwartezeit noch im selben offenen Fenster beginnen.
    $triggers = if ($RunAt -gt [datetime]::MinValue) {
      @((New-ScheduledTaskTrigger -Daily -At $RunAt), (New-ScheduledTaskTrigger -AtStartup))
    } else {
      @((New-ScheduledTaskTrigger -AtStartup))
    }
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    Register-ScheduledTask -TaskName $Name -Action $action -Trigger $triggers -Principal $principal -Force | Out-Null
  }
  if ($Servername -ieq $env:COMPUTERNAME) { & $sb $TaskName $Script $At; return }
  $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
  $params.ScriptBlock = $sb; $params.ArgumentList = @($TaskName, $Script, $At)
  Invoke-WindowsUpdateWithRetry -OperationName "Remote-Startaufgabe '$TaskName' auf $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @params | Out-Null }
}

function Register-RebootTask {
  param([string]$Servername, [string]$RebootTime, [string]$LatestRebootTime, [int]$DelayMinutes = 0, [datetime]$NotBefore = [datetime]::MinValue, [switch]$Immediately, $AuthInfo = $null)
  if (-not $Immediately -and [string]::IsNullOrWhiteSpace($RebootTime)) { return }
  # Eine Minute Abstand verhindert, dass die Verbindung des Installationslaufs abgeschnitten wird.
  if ($Immediately -and -not [string]::IsNullOrWhiteSpace($RebootTime) -and -not [string]::IsNullOrWhiteSpace($LatestRebootTime)) {
    $at = Get-NextRebootTimeInWindow -StartTime $RebootTime -LatestTime $LatestRebootTime -DelayMinutes $DelayMinutes -NotBefore $NotBefore -PreferImmediate
  } elseif ($Immediately) {
    $at = (Get-Date).AddMinutes(1 + $DelayMinutes)
  } else {
    $at = Get-NextRebootTimeInWindow -StartTime $RebootTime -LatestTime $LatestRebootTime -DelayMinutes $DelayMinutes -NotBefore $NotBefore
  }
  $taskName = 'WindowsUpdateAdm-Reboot'
  $registeredAt = [DateTime]::UtcNow.ToFileTimeUtc()
  $script = @"
`$taskName = '$taskName'
try {
  `$registeredAt = [DateTime]::FromFileTimeUtc($registeredAt)
  `$lastBoot = ([DateTime](Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUniversalTime()
  # Neustart wird erst nach dem Entfernen der Aufgabe angefordert.
  # Der Aufrufer legt diese Aufgabe nur nach tatsächlich installierten Windows-Updates an.
  # Ein manueller Neustart zwischenzeitlich wird am Bootzeitpunkt erkannt und nicht wiederholt.
  if (`$lastBoot -le `$registeredAt) {
    Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue
    shutdown.exe /r /t 15 /f | Out-Null
  }
} finally { Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue }
"@
  Register-OneTimeRemoteTask -Servername $Servername -TaskName $taskName -At $at -Script $script -AuthInfo $AuthInfo
  $rebootMode = if ($Immediately) { 'sofort nach Abschluss' } else { $at.ToString('dd.MM.yyyy HH:mm') }
  Write-ScriptLog "Neustartaufgabe auf $Servername geplant: $rebootMode (selbstlöschend; entfällt bei zwischenzeitlichem manuellem Neustart)."
}

function Request-RebootTask {
  param(
    [string]$Servername,
    [string]$RebootTime,
    [string]$LatestRebootTime,
    [int]$DelayMinutes = 0,
    [datetime]$NotBefore = [datetime]::MinValue,
    [switch]$Immediately,
    $AuthInfo = $null
  )
  $isLocalManagementServer = $Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ComputerFQDN
  if ($isLocalManagementServer) {
    # Der Verwaltungsserver darf den Gesamt-Lauf nicht unterbrechen. Sein
    # Neustart wird deshalb erst nach Berichten, Mail und allen Zielservern angelegt.
    $script:DeferredLocalReboot = [PSCustomObject]@{
      Servername   = $Servername
      RebootTime   = $RebootTime
      LatestRebootTime = $LatestRebootTime
      NotBefore = $NotBefore
      DelayMinutes = $DelayMinutes
      Immediately  = [bool]$Immediately
      AuthInfo     = $AuthInfo
    }
    Write-ScriptLog "Neustart für den Verwaltungsserver $Servername wird erst nach Abschluss aller Zielserver geplant."
    return
  }
  Register-RebootTask -Servername $Servername -RebootTime $RebootTime -LatestRebootTime $LatestRebootTime -DelayMinutes $DelayMinutes -NotBefore $NotBefore -Immediately:$Immediately -AuthInfo $AuthInfo
}

function Register-DeferredLocalRebootTask {
  if ($null -eq $script:DeferredLocalReboot) { return }
  $request = $script:DeferredLocalReboot
  Write-ScriptLog "Alle Zielserver sind verarbeitet – plane nun den Neustart des Verwaltungsservers $($request.Servername)."
  Register-RebootTask -Servername $request.Servername -RebootTime $request.RebootTime -LatestRebootTime $request.LatestRebootTime -DelayMinutes $request.DelayMinutes -NotBefore $request.NotBefore -Immediately:$request.Immediately -AuthInfo $request.AuthInfo
  $script:DeferredLocalReboot = $null
}

function Register-DeferredUpdateTask {
  param([string]$Servername, [string[]]$DeferredCategories, [string[]]$DeferredKBs = @(), [int]$DelayMinutes = 1440, [bool]$SucheOnline, $AuthInfo = $null, [datetime]$ScheduledAt = [datetime]::MinValue, [string]$MaintenanceEndTime = '')
  # Die Aufgabe wird ausschließlich beim nächsten Boot gestartet.
  # Erst dessen LastBootUpTime ist der Startpunkt der Nachinstallationsfrist.
  $taskName = 'WindowsUpdateAdm-DeferredUpdates'
  # InputObject verhindert, dass ein leeres Array zu JSON-null wird und später
  # als ein einzelnes leeres KB-Element interpretiert wird.
  $categories = ConvertTo-Json -InputObject @($DeferredCategories) -Compress
  $deferredKBsJson = ConvertTo-Json -InputObject @($DeferredKBs) -Compress
  # Die Aufgabe wird vor dem normalen Mail-Report registriert. Deshalb werden
  # Sender und Betreff hier bereits mit den Installationswerten ergänzt.
  $deferredMailSettings = $MailSettings | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json
  if (-not $deferredMailSettings.Install) {
    Add-Member -InputObject $deferredMailSettings -NotePropertyName 'Install' -NotePropertyValue ([PSCustomObject]@{}) -Force
  }
  $deferredCompanyName = [string]$deferredMailSettings.CompanyName
  if ([string]::IsNullOrWhiteSpace([string]$deferredMailSettings.Sender) -and -not [string]::IsNullOrWhiteSpace($deferredCompanyName)) {
    $deferredMailSafeName = ConvertTo-WindowsUpdateMailSafeString -Text $deferredCompanyName
    Add-Member -InputObject $deferredMailSettings -NotePropertyName 'Sender' -NotePropertyValue "Updates@$deferredMailSafeName.de" -Force
  }
  if ([string]::IsNullOrWhiteSpace([string]$deferredMailSettings.Install.Subject)) {
    Add-Member -InputObject $deferredMailSettings.Install -NotePropertyName 'Subject' -NotePropertyValue 'Server Updates installiert' -Force
  }
  $mailJson = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($deferredMailSettings | ConvertTo-Json -Depth 5 -Compress)))
  $registeredAt = [DateTime]::UtcNow.ToFileTimeUtc()
  $scheduledAtFileTime = if ($ScheduledAt -gt [datetime]::MinValue) { $ScheduledAt.ToUniversalTime().ToFileTimeUtc() } else { 0 }
  $maintenanceEndBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($MaintenanceEndTime))
  $script = @"
`$taskName = '$taskName'
try {
  `$logDirectory = Join-Path `$env:ProgramData 'WindowsUpdateAdm'
  `$logFile = Join-Path `$logDirectory 'DeferredUpdates.log'
  New-Item -ItemType Directory -Path `$logDirectory -Force | Out-Null
  function Write-DeferredLog([string]`$Message) {
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `$Message" | Add-Content -LiteralPath `$logFile -Encoding UTF8
  }
  `$waitForReboot = `$false
  `$scheduledAt = if ($scheduledAtFileTime -gt 0) { [DateTime]::FromFileTimeUtc($scheduledAtFileTime) } else { [DateTime]::MinValue }
  `$maintenanceEndTime = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$maintenanceEndBase64'))
  Write-DeferredLog 'Nachinstallationsaufgabe gestartet.'
  `$registeredAt = [DateTime]::FromFileTimeUtc($registeredAt)
  `$lastBoot = ([DateTime](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime()
  `$rebootDetected = `$lastBoot -gt `$registeredAt
  `$rebootDueAt = if (`$rebootDetected) { `$lastBoot.AddMinutes($DelayMinutes) } else { [DateTime]::MinValue }
  `$windowEnd = [DateTime]::MaxValue
  if (`$scheduledAt -gt [DateTime]::MinValue) {
    `$windowOpen = `$true
    if (-not [string]::IsNullOrWhiteSpace(`$maintenanceEndTime)) {
      `$endParsed = [DateTime]::MinValue
      if (-not [DateTime]::TryParse(`$maintenanceEndTime, [ref]`$endParsed)) { throw "Ungültiges Wartungsfenster-Ende: `$maintenanceEndTime" }
      `$nowLocal = Get-Date
      `$windowStart = `$nowLocal.Date.Add(`$scheduledAt.ToLocalTime().TimeOfDay)
      if (`$nowLocal -lt `$windowStart) { `$windowStart = `$windowStart.AddDays(-1) }
      `$windowEnd = `$windowStart.Date.Add(`$endParsed.TimeOfDay)
      if (`$windowEnd -le `$windowStart) { `$windowEnd = `$windowEnd.AddDays(1) }
      `$windowOpen = `$nowLocal -ge `$windowStart -and `$nowLocal -lt `$windowEnd
    }
    # Die Aufgabe wird täglich im Wartungsfenster gestartet. Nach einem
    # Neustart darf dessen Wartezeit das Fenster nicht unterschreiten.
    if (-not `$windowOpen) {
      `$waitForReboot = `$true
      Write-DeferredLog "Wartungsfenster ist geschlossen. Die Aufgabe wartet auf das nächste tägliche Wartungsfenster."
    } elseif (`$rebootDetected -and [DateTime]::UtcNow -lt `$rebootDueAt) {
      `$dueLocal = `$rebootDueAt.ToLocalTime()
      `$canWaitInsideWindow = `$scheduledAt -le [DateTime]::MinValue -or (`$windowOpen -and `$dueLocal -lt `$windowEnd)
      if (`$canWaitInsideWindow) {
        `$secondsUntilDue = [int][Math]::Ceiling((`$dueLocal - (Get-Date)).TotalSeconds)
        if (`$secondsUntilDue -gt 0) {
          Write-DeferredLog "Mindestwartezeit läuft bis `$(`$dueLocal.ToString('yyyy-MM-dd HH:mm:ss')); die Nachinstallation startet danach im aktuellen Wartungsfenster."
          Start-Sleep -Seconds `$secondsUntilDue
        }
        `$afterWait = Get-Date
        if (`$scheduledAt -gt [DateTime]::MinValue -and -not [string]::IsNullOrWhiteSpace(`$maintenanceEndTime) -and `$afterWait -ge `$windowEnd) {
          `$waitForReboot = `$true
          Write-DeferredLog 'Die Mindestwartezeit endet erst nach dem Wartungsfenster. Nachinstallation wird bis zum nächsten Wartungsfenster verschoben.'
        } else {
          Write-DeferredLog 'Mindestwartezeit erfüllt. Nachinstallation beginnt jetzt im laufenden Wartungsfenster.'
        }
      } else {
        `$waitForReboot = `$true
        Write-DeferredLog "Mindestwartezeit läuft bis `$(`$dueLocal.ToString('yyyy-MM-dd HH:mm:ss)) und passt nicht mehr in das offene Wartungsfenster. Nachinstallation wartet auf das nächste Fenster."
      }
    } else {
      Write-DeferredLog 'Wartungsfenster erreicht und Mindestwartezeit erfüllt (oder seit Aufgabenanlage kein Neustart erfolgt). Nachinstallation wird jetzt ausgeführt.'
    }
  } elseif (-not `$rebootDetected) {
    # Ohne Wartungszeit bleibt die Aufgabe bis zum Neustart aktiv.
    `$waitForReboot = `$true
    Write-DeferredLog 'Kein Wartungsfenster konfiguriert und noch kein Neustart erkannt. Aufgabe wartet auf Systemstart.'
  } elseif ([DateTime]::UtcNow -lt `$rebootDueAt) {
    # Ohne Wartungszeit wartet der laufende Task direkt bis zum Ende des Mindestabstands.
    `$dueLocal = `$rebootDueAt.ToLocalTime()
    `$secondsUntilDue = [int][Math]::Ceiling((`$dueLocal - (Get-Date)).TotalSeconds)
    if (`$secondsUntilDue -gt 0) {
      Write-DeferredLog "Kein Wartungsfenster konfiguriert. Mindestwartezeit läuft bis `$(`$dueLocal.ToString('yyyy-MM-dd HH:mm:ss'))."
      Start-Sleep -Seconds `$secondsUntilDue
    }
    Write-DeferredLog 'Mindestwartezeit erfüllt. Nachinstallation beginnt jetzt.'
  }
  if (-not `$waitForReboot) {
    Import-Module PSWindowsUpdate -ErrorAction Stop
    `$categories = @('$categories' | ConvertFrom-Json | Where-Object { -not [string]::IsNullOrWhiteSpace([string]`$_) })
    `$deferredKBs = @('$deferredKBsJson' | ConvertFrom-Json | Where-Object { -not [string]::IsNullOrWhiteSpace([string]`$_) })
    `$results = @()
    `$selectionParts = @()
    if (`$deferredKBs.Count -gt 0) {
      Write-DeferredLog "Installiere zurückgestellte KBs: `$(`$deferredKBs -join ', ')."
      `$selectionParts += "KBs: `$(`$deferredKBs -join ', ')"
      foreach (`$kb in `$deferredKBs) { `$results += @(Get-WindowsUpdate -KBArticleID `$kb -AcceptAll -Install -IgnoreReboot) }
    }
    if (`$categories.Count -gt 0) {
      Write-DeferredLog "Installiere zurückgestellte Kategorien: `$(`$categories -join ', ')."
      `$selectionParts += "Kategorien: `$(`$categories -join ', ')"
      foreach (`$category in `$categories) { `$results += @(Get-WindowsUpdate -Category `$category -AcceptAll -Install -IgnoreReboot) }
    }
    `$selection = `$selectionParts -join '; '
    `$rows = foreach (`$result in @(`$results)) {
      `$kb = [System.Net.WebUtility]::HtmlEncode([string]`$result.KB)
      `$title = [System.Net.WebUtility]::HtmlEncode([string]`$result.Title)
      `$status = [System.Net.WebUtility]::HtmlEncode([string]`$result.Status)
      "<tr><td>`$env:COMPUTERNAME</td><td>`$status</td><td>`$kb</td><td>`$title</td></tr>"
    }
    if (-not `$rows) { `$rows = '<tr><td colspan="4">Keine zurückgestellten Updates waren mehr verfügbar.</td></tr>' }
    `$safeSelection = [System.Net.WebUtility]::HtmlEncode(`$selection)
    `$body = @'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><style>
body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; color: #333; }
h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
.info-box { background-color: white; padding: 15px; margin: 10px 0; border-left: 4px solid #4CAF50; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
.section-title { background-color: #2196F3; color: white; padding: 10px; margin: 20px 0 10px 0; font-weight: bold; border-radius: 3px; }
.summary { background-color: #e8f5e9; border-left: 4px solid #4CAF50; padding: 15px; margin: 20px 0; border-radius: 5px; }
table { border-collapse: collapse; width: 100%; margin: 10px 0; background-color: white; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
th, td { border: 1px solid #ddd; padding: 10px 8px; text-align: left; }
th { background-color: #4CAF50; color: white; }
tr:nth-child(even) { background-color: #f9f9f9; }
</style></head><body>
<h1>Nachinstallation – Server Updates</h1>
<div class="info-box"><p><strong>Computer:</strong> {{computer}}</p><p><strong>Zeitpunkt:</strong> {{date}}</p><p><strong>Auswahl:</strong> {{selection}}</p></div>
<div class="section-title">Nachinstallierte Windows-Updates</div>
<table><tr><th>Computername</th><th>Status</th><th>KB</th><th>Titel</th></tr>{{rows}}</table>
<div class="summary"><strong>Ergebnis:</strong> Die Nachinstallation wurde abgeschlossen. Installierte Updates: {{count}}.</div>
</body></html>
'@
    `$body = `$body.Replace('{{computer}}', [System.Net.WebUtility]::HtmlEncode(`$env:COMPUTERNAME)).Replace('{{date}}', (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')).Replace('{{selection}}', `$safeSelection).Replace('{{rows}}', (`$rows -join '')).Replace('{{count}}', [string]`$(@(`$results).Count))
    `$mail = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$mailJson')) | ConvertFrom-Json
    if (`$mail.Install.SendMail -and `$mail.Host -and `$mail.MailTo) {
      `$mailSent = `$false
      for (`$attempt = 1; `$attempt -le 3 -and -not `$mailSent; `$attempt++) {
        try {
          Write-DeferredLog "Sende Abschluss-E-Mail (Versuch `$attempt/3) an `$mail.MailTo über `$mail.Host:`$(`$mail.Port)."
          `$smtp = New-Object Net.Mail.SmtpClient(`$mail.Host, [int]`$mail.Port)
          `$smtp.EnableSsl = [bool]`$mail.UseSSL
          if (`$mail.Auth) { `$smtp.Credentials = New-Object Net.NetworkCredential(`$mail.AuthUser, `$mail.AuthPass) }
      `$message = New-Object Net.Mail.MailMessage(`$mail.Sender, `$mail.MailTo, ('Nachinstallation: ' + `$mail.Install.Subject), `$body)
      `$message.BodyEncoding = [Text.Encoding]::UTF8
      `$message.IsBodyHtml = `$true
          `$smtp.Send(`$message); `$message.Dispose(); `$smtp.Dispose()
          `$mailSent = `$true
          Write-DeferredLog 'Abschluss-E-Mail erfolgreich versendet.'
        } catch {
          Write-DeferredLog "Abschluss-E-Mail fehlgeschlagen (Versuch `$attempt/3): `$(`$_.Exception.Message)"
          if (`$attempt -lt 3) { Start-Sleep -Seconds 30 }
        }
      }
      if (-not `$mailSent) { throw 'Abschluss-E-Mail konnte nach drei Versuchen nicht versendet werden.' }
    } else {
      Write-DeferredLog 'Abschluss-E-Mail übersprungen: SendMail, SMTP-Host oder Empfänger fehlen.'
    }
    `$rebootStatus = Get-WURebootStatus -Silent -ErrorAction Stop
    `$rebootRequired = if (`$rebootStatus -is [bool]) { `$rebootStatus } elseif (`$null -ne `$rebootStatus -and `$null -ne `$rebootStatus.PSObject.Properties['RebootRequired']) { [bool]`$rebootStatus.RebootRequired } else { `$false }
    Write-DeferredLog "Get-WURebootStatus meldet RebootRequired = `$rebootRequired."
    if (`$rebootRequired) {
      Write-DeferredLog 'Nachinstallationsmail abgeschlossen. Erforderlicher Neustart wird jetzt sofort ausgelöst.'
      Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue
      Remove-Item -LiteralPath (Join-Path `$logDirectory 'DeferredUpdates.ps1') -Force -ErrorAction SilentlyContinue
      shutdown.exe /r /t 0 /f | Out-Null
    }
  }
} catch {
  `$failureMessage = `$_.Exception.Message
  try { Write-DeferredLog "FEHLER: `$failureMessage" } catch { }
  try {
    `$mail = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$mailJson')) | ConvertFrom-Json
    if (`$mail.Install.SendMail -and `$mail.Host -and `$mail.MailTo) {
      `$smtp = New-Object Net.Mail.SmtpClient(`$mail.Host, [int]`$mail.Port); `$smtp.EnableSsl = [bool]`$mail.UseSSL
      if (`$mail.Auth) { `$smtp.Credentials = New-Object Net.NetworkCredential(`$mail.AuthUser, `$mail.AuthPass) }
      `$message = New-Object Net.Mail.MailMessage(`$mail.Sender, `$mail.MailTo, ('FEHLER Nachinstallation: ' + `$mail.Install.Subject), "Nachinstallation auf `$env:COMPUTERNAME fehlgeschlagen: `$(`$_.Exception.Message)")
      `$smtp.Send(`$message); `$message.Dispose(); `$smtp.Dispose()
      Write-DeferredLog 'Fehler-E-Mail erfolgreich versendet.'
    }
  } catch {
    try { Write-DeferredLog "Fehler-E-Mail konnte nicht versendet werden: `$(`$_.Exception.Message)" } catch { }
  }
} finally {
  # Während der Wartephase bleibt die Aufgabe erhalten; nach Ausführung oder Fehler wird sie entfernt.
  if (-not `$waitForReboot) {
    Write-DeferredLog 'Aufgabe wird entfernt.'
    Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path `$logDirectory 'DeferredUpdates.ps1') -Force -ErrorAction SilentlyContinue
  }
}

"@
  Register-StartupRemoteTask -Servername $Servername -TaskName $taskName -Script $script -AuthInfo $AuthInfo -At $ScheduledAt
  $selectionText = @(
    if ($DeferredKBs.Count -gt 0) { "KBs: $($DeferredKBs -join ', ')" }
    if ($DeferredCategories.Count -gt 0) { "Kategorien: $($DeferredCategories -join ', ')" }
  ) -join '; '
  $activationText = if ($ScheduledAt -gt [datetime]::MinValue) { "im Wartungsfenster $($ScheduledAt.ToString('dd.MM.yyyy HH:mm'))" } else { 'beim nächsten Neustart' }
  Write-ScriptLog "Nachinstallation auf $Servername wird $activationText aktiviert und startet danach nach $DelayMinutes Minute(n) ($selectionText; selbstlöschend)."
}

function Register-DeferredMailTestTask {
  param([string]$Servername, $AuthInfo = $null)

  $taskName = 'WindowsUpdateAdm-TestDeferredMail'
  $mailJson = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($MailSettings | ConvertTo-Json -Depth 5 -Compress)))
  $script = @"
`$taskName = '$taskName'
`$logDirectory = Join-Path `$env:ProgramData 'WindowsUpdateAdm'
`$logFile = Join-Path `$logDirectory 'DeferredUpdates.log'
New-Item -ItemType Directory -Path `$logDirectory -Force | Out-Null
function Write-TestMailLog([string]`$Message) {
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  TESTMAIL: `$Message" | Add-Content -LiteralPath `$logFile -Encoding UTF8
}
try {
  Write-TestMailLog 'Testmail-Aufgabe gestartet.'
  `$mail = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$mailJson')) | ConvertFrom-Json
  if (-not `$mail.Install.SendMail -or -not `$mail.Host -or -not `$mail.MailTo) {
    throw 'Mailversand ist nicht vollständig konfiguriert (SendMail, SMTP-Host oder Empfänger fehlen).'
  }
  `$subject = '[TEST] Nachinstallation: ' + `$mail.Install.Subject
  `$body = @'
<!DOCTYPE html>
<html><head><meta charset="UTF-8"><style>
body { font-family: Arial, sans-serif; margin: 20px; background-color: #f5f5f5; color: #333; }
h1 { color: #333; border-bottom: 2px solid #4CAF50; padding-bottom: 10px; }
.info-box { background-color: white; padding: 15px; margin: 10px 0; border-left: 4px solid #4CAF50; box-shadow: 0 2px 4px rgba(0,0,0,0.1); }
.section-title { background-color: #2196F3; color: white; padding: 10px; margin: 20px 0 10px 0; font-weight: bold; border-radius: 3px; }
.summary { background-color: #e8f5e9; border-left: 4px solid #4CAF50; padding: 15px; margin: 20px 0; border-radius: 5px; }
</style></head><body>
<h1>Nachinstallation – Server Updates</h1>
<div class="info-box"><p><strong>Computer:</strong> {{computer}}</p><p><strong>Zeitpunkt:</strong> {{date}}</p></div>
<div class="section-title">Test des Mailversands</div>
<div class="summary"><strong>Ergebnis:</strong> Dies ist ein erfolgreicher Test der Nachinstallationsmail aus dem SYSTEM-Kontext. Es wurden keine Updates installiert und kein Neustart ausgelöst.</div>
</body></html>
'@
  `$body = `$body.Replace('{{computer}}', [System.Net.WebUtility]::HtmlEncode(`$env:COMPUTERNAME)).Replace('{{date}}', (Get-Date -Format 'dd.MM.yyyy HH:mm:ss'))
  `$mailSent = `$false
  for (`$attempt = 1; `$attempt -le 3 -and -not `$mailSent; `$attempt++) {
    try {
      Write-TestMailLog "Sende Testmail (Versuch `$attempt/3)."
      `$smtp = New-Object Net.Mail.SmtpClient(`$mail.Host, [int]`$mail.Port)
      `$smtp.EnableSsl = [bool]`$mail.UseSSL
      if (`$mail.Auth) { `$smtp.Credentials = New-Object Net.NetworkCredential(`$mail.AuthUser, `$mail.AuthPass) }
      `$message = New-Object Net.Mail.MailMessage(`$mail.Sender, `$mail.MailTo, `$subject, `$body)
      `$message.BodyEncoding = [Text.Encoding]::UTF8
      `$message.IsBodyHtml = `$true
      `$smtp.Send(`$message)
      `$message.Dispose(); `$smtp.Dispose()
      `$mailSent = `$true
      Write-TestMailLog 'Testmail erfolgreich versendet.'
    } catch {
      Write-TestMailLog "Testmail fehlgeschlagen (Versuch `$attempt/3): `$(`$_.Exception.Message)"
      if (`$attempt -lt 3) { Start-Sleep -Seconds 30 }
    }
  }
  if (-not `$mailSent) { throw 'Testmail konnte nach drei Versuchen nicht versendet werden.' }
} catch {
  Write-TestMailLog "FEHLER: `$(`$_.Exception.Message)"
} finally {
  Unregister-ScheduledTask -TaskName `$taskName -Confirm:`$false -ErrorAction SilentlyContinue
}
"@
  # Kurzer Abstand lässt den Aufruf sauber enden und prüft den echten SYSTEM-Kontext.
  Register-OneTimeRemoteTask -Servername $Servername -TaskName $taskName -At (Get-Date).AddMinutes(1) -Script $script -AuthInfo $AuthInfo
  Write-ScriptLog "Testmail-Aufgabe auf $Servername geplant (Start in etwa einer Minute; selbstlöschend)."
}

############################################################################################################################################################################
# Hauptskript
############################################################################################################################################################################

$ScriptStartTime = Get-Date
$psVersion = $PSVersionTable.PSVersion.Major

if ($DebugMode) {
  Write-Host "═══════════════════════════════════════" -ForegroundColor Yellow
  Write-Host " DEBUG-MODUS AKTIVIERT" -ForegroundColor Yellow
  Write-Host " Erweiterte Ausgaben werden angezeigt" -ForegroundColor Yellow
  Write-Host "═══════════════════════════════════════" -ForegroundColor Yellow
  Write-Host ""
}

Write-Host "═══════════════════════════════════════════════════════════════"
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)"
Write-Host "Betriebssystem: $([System.Environment]::OSVersion.VersionString)"
Write-Host "═══════════════════════════════════════════════════════════════"

$Settings = Get-InstallSettingsFromCommon
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

# Zähler initialisieren
$LinuxServerCount = 0
$HAServerCount = 0
$LinuxUpdatesInstalled = 0
$LinuxUpdatesFailed = 0
$HAUpdatesInstalled = 0
$HAUpdatesFailed = 0
$LinuxScriptExecuted = $false
$HAScriptExecuted = $false

# Linux-Updates Skript
$LinuxUpdateScript = Join-Path -Path $PSScriptRoot -ChildPath "Install-Linux Updates.ps1"
$LinuxStatsFile = Join-Path $PSScriptRoot "linux_update_stats.json"
$IsWindowsOnlyRun = $TargetComputer -and $TargetComputer.Count -gt 0

if ($IsWindowsOnlyRun) {
  Write-ScriptLog "Eingeschränkter Windows-Testlauf: Linux-Updates werden übersprungen."
} elseif ($LinuxConfigured -and (Test-Path $LinuxUpdateScript)) {
  $LinuxScriptExecuted = $true
  Write-ScriptLog "Führe Linux-Updates Skript aus: $LinuxUpdateScript"
  try {
    & $LinuxUpdateScript -VMRebootIndexStart $script:VMRebootIndex -DeferPhysicalReboots
    Write-ScriptLog "Linux-Updates Skript erfolgreich ausgeführt."
    
    if (Test-Path $LinuxStatsFile) {
        $LinuxStats = Get-Content $LinuxStatsFile | ConvertFrom-Json
      if ($LinuxStats.PSObject.Properties.Name -contains 'PendingPhysicalReboots') {
        foreach ($pendingLinuxReboot in @($LinuxStats.PendingPhysicalReboots)) { $script:PendingLinuxPhysicalReboots.Add($pendingLinuxReboot) }
      }
      $LinuxServerCount = $LinuxStats.TotalHosts
      
      if ($LinuxStats.PSObject.Properties.Name -contains 'UpdatesInstalled') {
        $LinuxUpdatesInstalled = $LinuxStats.UpdatesInstalled
        $LinuxUpdatesFailed = if ($LinuxStats.PSObject.Properties.Name -contains 'FailedHosts') { $LinuxStats.FailedHosts } else { 0 }
        
        if ($LinuxStats.PSObject.Properties.Name -contains 'HostStatus') {
          # ConvertFrom-Json liefert bei exakt einem Host ein Einzelobjekt.
          # Für die spätere Berichtsverarbeitung stets als Array normalisieren.
          $LinuxUpdateDetails = @($LinuxStats.HostStatus)
        }
        if ($LinuxStats.PSObject.Properties.Name -contains 'VMRebootsScheduled') {
          $script:VMRebootIndex += [int]$LinuxStats.VMRebootsScheduled
        }
        
        Write-ScriptLog "Linux-Stats: $LinuxServerCount Server verarbeitet, $LinuxUpdatesInstalled Update(s) installiert, $LinuxUpdatesFailed fehlgeschlagen"
      }
      else {
        $LinuxUpdatesInstalled = 0
        $LinuxUpdatesFailed = 0
        Write-ScriptLog "Linux-Stats: $LinuxServerCount Server, keine Detail-Informationen"
      }
      
      Remove-Item $LinuxStatsFile -Force -ErrorAction SilentlyContinue
      Write-ScriptLog "Linux-Stats-Datei gelöscht: $LinuxStatsFile"
    }
  }
  catch {
    Write-ScriptLog "Fehler beim Ausführen des Linux-Updates Skripts: $($_.Exception.Message)"
    # Die Hauptmeldung einer verschachtelten Skriptausführung enthält häufig
    # keine Zeilennummer. Für einen eventuellen Folgefehler wird deshalb die
    # echte Position des Linux-Skripts mitprotokolliert.
    if ($_.InvocationInfo.PositionMessage) {
      Write-ScriptLog "Linux-Fehlerposition: $($_.InvocationInfo.PositionMessage)"
    }
    if ($_.ScriptStackTrace) {
      Write-ScriptLog "Linux-Fehlerstack: $($_.ScriptStackTrace)"
    }
  }
}

# Home Assistant-Updates Skript
$HAUpdateScript = Join-Path -Path $PSScriptRoot -ChildPath "Install-HomeAssistant Updates.ps1"
$HAStatsFile = Join-Path $PSScriptRoot "ha_update_stats.json"

if ($IsWindowsOnlyRun) {
  Write-ScriptLog "Eingeschränkter Windows-Testlauf: Home-Assistant-Updates werden übersprungen."
} elseif ($HAConfigured -and (Test-Path $HAUpdateScript)) {
  $HAScriptExecuted = $true
  Write-ScriptLog "Führe Home Assistant-Updates Skript aus: $HAUpdateScript"
  try {
    & $HAUpdateScript -VMRebootIndexStart $script:VMRebootIndex -DeferPhysicalReboots
    Write-ScriptLog "Home Assistant-Updates Skript erfolgreich ausgeführt."
    
    if (Test-Path $HAStatsFile) {
      $HAStats = Get-Content $HAStatsFile | ConvertFrom-Json
      if ($HAStats.PSObject.Properties.Name -contains 'PendingPhysicalReboot' -and $null -ne $HAStats.PendingPhysicalReboot) {
        $script:PendingHAPhysicalReboots.Add($HAStats.PendingPhysicalReboot)
      }
      $HAServerCount = $HAStats.TotalHosts
      
      if ($HAStats.PSObject.Properties.Name -contains 'SuccessfulUpdates') {
        $HAUpdatesInstalled = $HAStats.SuccessfulUpdates
      } else {
        $HAUpdatesInstalled = 0
      }
      
      if ($HAStats.PSObject.Properties.Name -contains 'FailedUpdates') {
        $HAUpdatesFailed = $HAStats.FailedUpdates
      } else {
        $HAUpdatesFailed = 0
      }
      
      if ($HAStats.PSObject.Properties.Name -contains 'HostStatus') {
        $HAUpdateDetails = $HAStats.HostStatus
      } elseif ($HAStats.PSObject.Properties.Name -contains 'UpdateDetails') {
        $HAUpdateDetails = $HAStats.UpdateDetails
      }
      if ($HAStats.PSObject.Properties.Name -contains 'VMRebootsScheduled') {
        $script:VMRebootIndex += [int]$HAStats.VMRebootsScheduled
      }
      
      Write-ScriptLog "HA-Stats: $HAServerCount Instanz(en), $HAUpdatesInstalled Update(s) installiert, $HAUpdatesFailed fehlgeschlagen"
      
      Remove-Item $HAStatsFile -Force -ErrorAction SilentlyContinue
      Write-ScriptLog "HA-Stats-Datei gelöscht: $HAStatsFile"
    }
  }
  catch {
    Write-ScriptLog "Fehler beim Ausführen des Home Assistant-Updates Skripts: $($_.Exception.Message)"
  }
}

# Die optionalen Linux-/HA-Skripte melden bereits geplante VM-Neustarts über
# den gemeinsamen Zähler. Damit kann die physische Windows-Gruppe ihren
# Neustart frühestens eine Stunde nach dem letzten VM-Neustart beginnen.
$vmRebootIntervalMinutes = [Math]::Max(0, [int]$UpdateSettings.VMRebootIntervalMinutes)
if ($script:VMRebootIndex -gt 0) {
  if ([bool]$UpdateSettings.VMRebootImmediately) {
    $script:VMRebootLatestAt = (Get-Date).AddMinutes(1 + (($script:VMRebootIndex - 1) * $vmRebootIntervalMinutes))
  } elseif (-not [string]::IsNullOrWhiteSpace([string]$UpdateSettings.VMRebootStartTime)) {
    $script:VMRebootLatestAt = Get-NextRebootTimeInWindow -StartTime ([string]$UpdateSettings.VMRebootStartTime) -LatestTime ([string]$UpdateSettings.VMRebootWindowEndTime) -DelayMinutes (($script:VMRebootIndex - 1) * $vmRebootIntervalMinutes)
  }
}

$ServerADList = Get-WindowsUpdateTargets -UpdateSettings $UpdateSettings -TargetComputers $TargetComputers -PowerShellMajor $psVersion -WriteLog { param($message) Write-ScriptLog $message }
# Ein gezielter Testlauf verändert die allgemeine Serverliste nicht, sondern filtert sie nur für diesen Start.
if ($TargetComputer -and $TargetComputer.Count -gt 0) {
  $requestedNames = @($TargetComputer | ForEach-Object { $_.Trim() } | Where-Object { $_ })
  $ServerADList = @($ServerADList | Where-Object { $requestedNames -contains $_.Name })
  if ($ServerADList.Count -eq 0) {
    throw "Keines der angegebenen Testziele wurde in der konfigurierten Serverliste gefunden: $($requestedNames -join ', ')"
  }
  Write-ScriptLog "Eingeschränkter Lauf: $($ServerADList.Count) Ziel(e): $($ServerADList.Name -join ', ')"
}

# Testet den Versand aus exakt dem später verwendeten SYSTEM-Kontext. Es werden
# weder Updates installiert noch Neustarts oder reguläre Berichte ausgelöst.
if ($TestDeferredMail) {
  if (-not $TargetComputer -or $TargetComputer.Count -eq 0) {
    throw 'Für -TestDeferredMail muss mindestens ein Ziel mit -TargetComputer angegeben werden.'
  }
  foreach ($server in $ServerADList) {
    $testAuthInfo = $null
    if ($server.IsHypervisor) {
      $testAuthInfo = Get-WindowsUpdateClientCertificateAuthInfo -UpdateSettings $UpdateSettings -TargetComputer $server.Name -WriteLog { param($message) Write-ScriptLog $message }
    } elseif ($server.IsAdditional) {
      $testAuthInfo = Get-WindowsUpdateClientCertificateAuthInfo -UpdateSettings $UpdateSettings -TargetComputer $server.Name -WriteLog { param($message) Write-ScriptLog $message }
    }
    Register-DeferredMailTestTask -Servername $server.Name -AuthInfo $testAuthInfo
  }
  Write-ScriptLog 'Testmail-Aufgabe angelegt. Es wurden keine Updates installiert und keine Neustarts geplant.'
  exit 0
}

# HTML-Report mit modernem Design
$RepBody = @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Update-Installation Report - ${ComputerFQDN}</title>
<style>
    body { 
        font-family: Arial, sans-serif; 
        margin: 20px; 
        background-color: #f5f5f5;
    }
    h1 { 
        color: #333; 
        border-bottom: 2px solid #4CAF50; 
        padding-bottom: 10px;
    }
    h2 {
        color: #555;
        margin-top: 20px;
        border-bottom: 1px solid #ddd;
        padding-bottom: 5px;
    }
    .info-box {
        background-color: white;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #4CAF50;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .info-box ul {
        margin: 10px 0;
        padding-left: 20px;
    }
    .info-box li {
        margin: 5px 0;
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
        background-color: #4CAF50; 
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
        background-color: #4CAF50;
        color: white;
        padding: 10px;
        margin: 15px 0 5px 0;
        font-weight: bold;
        border-radius: 3px;
    }
    .section-title {
        background-color: #2196F3;
        color: white;
        padding: 10px;
        margin: 20px 0 10px 0;
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
        background-color: #e8f5e9;
        padding: 15px;
        margin: 20px 0;
        border-radius: 5px;
        font-size: 1.1em;
    }
    .summary.warning {
        background-color: #fff3e0;
        border-left: 4px solid #ff9800;
    }
    .summary.success {
        background-color: #e8f5e9;
        border-left: 4px solid #4CAF50;
    }
    .linux-package-list {
        background-color: #f9f9f9;
        padding: 10px;
        margin: 5px 0;
        border-left: 3px solid #2196F3;
        font-family: 'Courier New', monospace;
        font-size: 0.9em;
    }
</style>
</head>
<body>
<h1>Update-Installation Report - ${ComputerFQDN}</h1>
<div class="info-box">
    <p><strong>Computer:</strong> ${ComputerFQDN}</p>
    <p><strong>PowerShell Version:</strong> $($PSVersionTable.PSVersion)</p>
    <p><strong>Zeitstempel:</strong> ${TimeStamp}</p>
</div>
"@

# Windows-Server verarbeiten
$ErrorCount = 0
$WindowsAdCount = 0
$WindowsNonAdCount = 0

if ($ServerADList -ne $null) {
  Write-ScriptLog "Verarbeite AD-Serverliste..."
  
  $RepBody += "<div class='section-title'>🖥️ Windows-Server Updates</div>"

  $SucheOnline = $UpdateSettings.SucheOnline
  $index = 0
  $Anzahl = 0 + $ServerADList.Count
  $WindowsNonAdCount = @($ServerADList | Where-Object { $_.IsAdditional -or $_.IsHypervisor }).Count
  $WindowsAdCount = $Anzahl - $WindowsNonAdCount

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
        Write-ScriptLog "Starte Update-Installation auf AD-Server $Servername..."
        $RepBody += "<div class='server-title'>Server: ${Servername}</div>"

        # Nicht-AD-Ziele erhalten TrustedHosts und Zertifikatsauthentifizierung
        # zentral; AD-Ziele bleiben bei Kerberos ohne Zertifikat.
        $remoting = Initialize-WindowsUpdateRemoting -UpdateSettings $UpdateSettings -TargetComputer $Servername -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        $svcCredential = $remoting.AuthInfo

        # Package-Manager-Updates
        $packageResults = @(Invoke-PackageManagerUpdates -Servername $Servername -AuthInfo $svcCredential)
        foreach ($packageResult in $packageResults) {
          if (-not $packageResult.Available -or -not $packageResult.Success) { continue }
          $packages = @($packageResult.Packages)
          if ($packages.Count -eq 0) { continue }
          $PackageUpdateCount += $packages.Count
          if ($packageResult.Manager -eq 'Winget') { $WingetUpdateCount += $packages.Count }
          if ($packageResult.Manager -eq 'Chocolatey') { $ChocolateyUpdateCount += $packages.Count }
          $PackageUpdateDetails += [PSCustomObject]@{ Server = $Servername; Manager = $packageResult.Manager; Packages = $packages }
        }

        # Zurückgestellte Kategorien + Zeitpunkte aus Settings lesen
        $deferredCategories  = @()
        $deferredKBs         = @()
        $physicalRebootTime  = [string]$UpdateSettings.PhysicalRebootTime
        $physicalRebootWindowEndTime = [string]$UpdateSettings.PhysicalRebootWindowEndTime
        $vmRebootStartTime   = [string]$UpdateSettings.VMRebootStartTime
        $vmRebootWindowEndTime = [string]$UpdateSettings.VMRebootWindowEndTime
        $vmRebootImmediately = [bool]$UpdateSettings.VMRebootImmediately
        # 1.440 Minuten entsprechen 24 Stunden. Minuten erlauben auch einen schnellen, sicheren Funktionstest.
        $deferredDelayMinutes = [int]$UpdateSettings.DeferredUpdateDelayMinutes
        $installDeferred     = [bool]$UpdateSettings.InstallDeferredUpdates
        if ($UpdateSettings.DeferredUpdateCategories -and $UpdateSettings.DeferredUpdateCategories.Count -gt 0) {
          $deferredCategories = [string[]]$UpdateSettings.DeferredUpdateCategories
        }
        if ($UpdateSettings.DeferredUpdateKBs -and $UpdateSettings.DeferredUpdateKBs.Count -gt 0) {
          $deferredKBs = [string[]]$UpdateSettings.DeferredUpdateKBs
        }
        Write-ScriptLog "Zurückgestellte Kategorien: $($deferredCategories -join ', '); KBs: $($deferredKBs -join ', '); Nachinstallation aktiviert: $installDeferred"

        # Windows-Updates installieren (ohne zurückgestellte Kategorien)
        $UpdResult = Invoke-WindowsUpdates -Servername $Servername -SucheOnline $SucheOnline -AuthInfo $svcCredential -DeferredCategories $deferredCategories -DeferredKBs $deferredKBs -DeferredOnly $false

        # Ohne installierte Hauptupdates gibt es keinen durch diesen Lauf
        # verursachten Neustartbedarf. Insbesondere auf Server 2016 vermeiden
        # wir damit eine unnötige privilegierte Statusabfrage.
        $mainUpdateCount = @($UpdResult | Where-Object { $_ -and ($_.KB -or $_.Title) }).Count
        if ($mainUpdateCount -gt 0) {
          # PSWindowsUpdate kennt den tatsächlichen Neustartbedarf zuverlässiger
          # als eine Prüfung einzelner Registry-Schlüssel.
          $rebootRequired = Test-WindowsUpdateRebootRequired -Servername $Servername -AuthInfo $svcCredential
          Write-ScriptLog "Get-WURebootStatus auf $($Servername): RebootRequired = $rebootRequired"
        }
        else {
          $rebootRequired = $false
          Write-ScriptLog "Kein Neustartstatus für $Servername abgefragt: In diesem Hauptlauf wurden keine Windows-Updates installiert."
        }
        if ($rebootRequired) {
          $isVirtual = Test-ServerIsVirtual -Servername $Servername -AuthInfo $svcCredential
          $vmDelayMinutes = $script:VMRebootIndex * $vmRebootIntervalMinutes
          if ($isVirtual -and $vmRebootImmediately) {
            $vmRebootAt = Get-NextRebootTimeInWindow -StartTime $vmRebootStartTime -LatestTime $vmRebootWindowEndTime -DelayMinutes $vmDelayMinutes -PreferImmediate
            Request-RebootTask -Servername $Servername -Immediately -RebootTime $vmRebootStartTime -LatestRebootTime $vmRebootWindowEndTime -DelayMinutes $vmDelayMinutes -AuthInfo $svcCredential
            $script:VMRebootIndex++
            if ($null -eq $script:VMRebootLatestAt -or $vmRebootAt -gt $script:VMRebootLatestAt) { $script:VMRebootLatestAt = $vmRebootAt }
          } elseif ($isVirtual -and -not [string]::IsNullOrWhiteSpace($vmRebootStartTime)) {
            $vmRebootAt = Get-NextRebootTimeInWindow -StartTime $vmRebootStartTime -LatestTime $vmRebootWindowEndTime -DelayMinutes $vmDelayMinutes
            Request-RebootTask -Servername $Servername -RebootTime $vmRebootStartTime -LatestRebootTime $vmRebootWindowEndTime -DelayMinutes $vmDelayMinutes -AuthInfo $svcCredential
            $script:VMRebootIndex++
            if ($null -eq $script:VMRebootLatestAt -or $vmRebootAt -gt $script:VMRebootLatestAt) { $script:VMRebootLatestAt = $vmRebootAt }
          } elseif (-not $isVirtual -and -not [string]::IsNullOrWhiteSpace($physicalRebootTime)) {
            $script:PendingPhysicalReboots.Add([PSCustomObject]@{ Servername = $Servername; RebootTime = $physicalRebootTime; LatestRebootTime = $physicalRebootWindowEndTime; AuthInfo = $svcCredential })
          }
        } else {
          Write-ScriptLog "Kein automatischer Neustart für $($Servername): Get-WURebootStatus meldet keinen ausstehenden Neustart."
        }

        # Geplante Aufgabe nur dann anlegen, wenn die zurückgestellte Auswahl
        # auf diesem konkreten Server noch Updates liefert. Damit wird weder
        # ein überflüssiger Task noch ein unnötiger Neustart erzeugt.
        if ($installDeferred -and ($deferredCategories.Count -gt 0 -or $deferredKBs.Count -gt 0)) {
          $deferredCheck = Get-DeferredWindowsUpdates -Servername $Servername -SucheOnline $SucheOnline -AuthInfo $svcCredential -DeferredCategories $deferredCategories -DeferredKBs $deferredKBs
          if ($deferredCheck.Success -and @($deferredCheck.Updates).Count -gt 0) {
            Write-ScriptLog "Zurückgestellte Updates auf $Servername verfügbar: $(@($deferredCheck.Updates).Count)."
            $isVirtualForDeferred = Test-ServerIsVirtual -Servername $Servername -AuthInfo $svcCredential
            $deferredMaintenanceTime = if ($isVirtualForDeferred) { $vmRebootStartTime } else { $physicalRebootTime }
            $deferredMaintenanceEndTime = if ($isVirtualForDeferred) { [string]$UpdateSettings.VMRebootWindowEndTime } else { [string]$UpdateSettings.PhysicalRebootWindowEndTime }
            $deferredScheduledAt = if (-not [string]::IsNullOrWhiteSpace($deferredMaintenanceTime)) { Get-NextScheduledTime $deferredMaintenanceTime } else { [datetime]::MinValue }
            if ($deferredScheduledAt -gt [datetime]::MinValue) {
              Write-ScriptLog "Nachinstallation auf $Servername für das Wartungsfenster $($deferredScheduledAt.ToString('dd.MM.yyyy HH:mm')) geplant ($([string]$(if ($isVirtualForDeferred) { 'VM' } else { 'physisch' })))."
            } else {
              Write-ScriptLog "WARNUNG: Für $Servername ist kein Wartungszeitpunkt konfiguriert; Nachinstallation wartet auf den nächsten Neustart."
            }
            Register-DeferredUpdateTask `
              -Servername          $Servername `
              -DeferredCategories  $deferredCategories `
              -DeferredKBs         $deferredKBs `
              -DelayMinutes        $deferredDelayMinutes `
              -SucheOnline         $SucheOnline `
              -AuthInfo            $svcCredential `
              -ScheduledAt         $deferredScheduledAt `
              -MaintenanceEndTime  $deferredMaintenanceEndTime

            # Der Report nennt den Aktivierungszeitpunkt und die Mindestwartezeit
            # direkt beim betroffenen Server. Die tatsächliche Installation kann
            # später beginnen, falls erst ein Neustart oder das nächste
            # Wartungsfenster abgewartet werden muss.
            $deferredSelection = @(
              if ($deferredKBs.Count -gt 0) { "KBs: $($deferredKBs -join ', ')" }
              if ($deferredCategories.Count -gt 0) { "Kategorien: $($deferredCategories -join ', ')" }
            ) -join '; '
            $deferredSelectionHtml = [System.Net.WebUtility]::HtmlEncode($deferredSelection)
            $deferredDelayText = "Die Installation startet nach einem erkannten Neustart frühestens nach $deferredDelayMinutes Minute(n)."
            if ($deferredScheduledAt -gt [datetime]::MinValue) {
              $deferredPlanText = "Nachinstallation eingeplant: ab Wartungsfenster $($deferredScheduledAt.ToString('dd.MM.yyyy HH:mm')) ($([string]$(if ($isVirtualForDeferred) { 'VM' } else { 'physisch' }))). $deferredDelayText"
            } else {
              $deferredPlanText = "Nachinstallation eingeplant: beim nächsten Neustart. $deferredDelayText"
            }
            $deferredPlanHtml = [System.Net.WebUtility]::HtmlEncode($deferredPlanText)
            $RepBody += "<div class='warning-box'><strong>$deferredPlanHtml</strong><br>Zurückgestellt: $deferredSelectionHtml</div>"
          }
          elseif ($deferredCheck.Success) {
            Remove-DeferredUpdateTask -Servername $Servername -AuthInfo $svcCredential
          }
          else {
            Write-ScriptLog "WARNUNG: Nachinstallationsaufgabe auf $Servername wird wegen fehlgeschlagener Update-Prüfung nicht verändert."
          }
        }
        else {
          # Auch wenn die Nachinstallation global ausgeschaltet wurde oder
          # keine Auswahl mehr konfiguriert ist, darf ein alter Task nicht
          # später noch einen sinnlosen Neustart auslösen.
          Remove-DeferredUpdateTask -Servername $Servername -AuthInfo $svcCredential
        }

        Write-ScriptLog "Ergebnis der Installation:"
        
        if ($UpdResult -and -not ($UpdResult -is [Array])) {
            $UpdResult = @($UpdResult)
        }
        
        if ($UpdResult -and @($UpdResult).Count -gt 0) {
          $ServerUpdateCount = @($UpdResult).Count
          
          Write-ScriptLog "Server ${Servername}: $ServerUpdateCount Update(s) gefunden" -IsDebug
          
          try {
            ($UpdResult | Select-Object ComputerName, Status, KB, Size, Title -ErrorAction SilentlyContinue | Format-Table -AutoSize | Out-String) `
              -split "\r?\n" | ForEach-Object { if ($_ -and $_.Trim()) { Write-ScriptLog $_ } }
          } catch {
            Write-ScriptLog "Fehler beim Formatieren der Update-Liste: $($_.Exception.Message)" -IsDebug
          }

          $validUpdates = $UpdResult | Where-Object { 
            $_ -and 
            $_.GetType().Name -ne 'String' -and 
            ($_.KB -or $_.Title -or $_.PSObject.Properties.Name -contains 'KB')
          }
          
          if ($validUpdates -and @($validUpdates).Count -gt 0) {
            $UpdResultFull += @($validUpdates)
            
            $RepBody += "<table>`n"
            $RepBody += "<tr><th>ComputerName</th><th>Status</th><th>KB</th><th>Size</th><th>Title</th></tr>`n"
            
            foreach ($upd in $validUpdates) {
              $RepBody += "<tr>"
              $RepBody += "<td>$($upd.ComputerName)</td>"
              $RepBody += "<td>$($upd.Status)</td>"
              $RepBody += "<td>$($upd.KB)</td>"
              $RepBody += "<td>$($upd.Size)</td>"
              $RepBody += "<td>$($upd.Title)</td>"
              $RepBody += "</tr>`n"
              
              $WindowsUpdateDetails += [PSCustomObject]@{
                Server = $Servername
                KB = $upd.KB
                Title = $upd.Title
                Status = $upd.Status
              }
            }
            
            $RepBody += "</table>"

            $UpdCount += @($validUpdates).Count
            Write-ScriptLog "Installierte Updates auf ${Servername}: $(@($validUpdates).Count) (Gesamt: $UpdCount)"
          } else {
            Write-ScriptLog "Keine gültigen Update-Objekte gefunden" -IsDebug
            Write-ScriptLog "... keine Updates installiert."
            $RepBody += "<div class='no-updates'>Keine Updates installiert.</div>"
          }
        } else {
          Write-ScriptLog "... keine Updates installiert."
          $RepBody += "<div class='no-updates'>Keine Updates installiert.</div>"
        }
      }
      Catch {
        Write-ScriptLog ("Es ist ein Fehler bei Server " + $Servername + " aufgetreten!")
        Write-ScriptLog ($_.Exception.Message)
        $RepBody += "<div class='warning-box'><strong>Fehler aufgetreten!</strong><br>$($_.Exception.Message)</div>"
        $ErrorCount++
      }
    }
  }
} else {
  $RepBody += "<div class='warning-box'><p>Der Abruf der Serverliste ist fehlgeschlagen!</p></div>"
}

# Physische Windows-Systeme starten erst nach dem VM-Neustartblock. Für jeden
# VM-Neustart wird vorsorglich bis zu einer Stunde Ausfallzeit eingeplant.
$physicalRebootNotBefore = if ($null -ne $script:VMRebootLatestAt) { $script:VMRebootLatestAt.AddHours(1) } else { [datetime]::MinValue }

# Linux- und Home-Assistant-Hosts verwenden dieselbe Physisch-nach-VM-Regel.
# Ihre Neustarts werden von den Einzelskripten gemeldet und erst jetzt gemeinsam eingeplant.
foreach ($pendingLinuxReboot in $script:PendingLinuxPhysicalReboots) {
  try {
    $plannedAt = Get-NextRebootTimeInWindow -StartTime ([string]$pendingLinuxReboot.RebootTime) -LatestTime ([string]$pendingLinuxReboot.LatestRebootTime) -NotBefore $physicalRebootNotBefore
    $delayMinutes = [Math]::Max(1, [int][Math]::Ceiling(($plannedAt - (Get-Date)).TotalMinutes))
    $sshPath = [string]$pendingLinuxReboot.SSHPath
    $sshArgs = @(Get-WindowsUpdateSshArguments -KeyPath ([string]$pendingLinuxReboot.KeyPath) -BatchMode -AcceptNewHostKey)
    $sshArgs += ('{0}@{1}' -f [string]$pendingLinuxReboot.User, [string]$pendingLinuxReboot.Host), "sudo /sbin/shutdown -r +$delayMinutes"
    & $sshPath @sshArgs 2>&1 | ForEach-Object { if ($_){ Write-ScriptLog "[$($pendingLinuxReboot.Host)] $_" } }
    if ($LASTEXITCODE -ne 0) { throw "SSH lieferte Exit-Code $LASTEXITCODE." }
    Write-ScriptLog "Physischer Linux-Neustart auf $($pendingLinuxReboot.Host) für $($plannedAt.ToString('dd.MM.yyyy HH:mm')) eingeplant."
  }
  catch { Write-ScriptLog "Physischer Linux-Neustart auf $($pendingLinuxReboot.Host) konnte nicht eingeplant werden: $($_.Exception.Message)" }
}
foreach ($pendingHAReboot in $script:PendingHAPhysicalReboots) {
  try {
    $plannedAt = Get-NextRebootTimeInWindow -StartTime ([string]$pendingHAReboot.RebootTime) -LatestTime ([string]$pendingHAReboot.LatestRebootTime) -NotBefore $physicalRebootNotBefore
    $delayMinutes = [Math]::Max(1, [int][Math]::Ceiling(($plannedAt - (Get-Date)).TotalMinutes))
    $sshPath = [string]$pendingHAReboot.SSHPath
    $sshArgs = @(Get-WindowsUpdateSshArguments -KeyPath ([string]$pendingHAReboot.KeyPath) -Port ([int]$pendingHAReboot.Port) -BatchMode -AcceptNewHostKey)
    $sshArgs += ('{0}@{1}' -f [string]$pendingHAReboot.User, [string]$pendingHAReboot.Host)
    $haCommand = if ($delayMinutes -le 1) { 'ha host reboot' } else { "nohup sh -c 'sleep $($delayMinutes * 60); ha host reboot' >/dev/null 2>&1 &" }
    $sshArgs += $haCommand
    & $sshPath @sshArgs 2>&1 | ForEach-Object { if ($_){ Write-ScriptLog "[Home Assistant $($pendingHAReboot.Host)] $_" } }
    if ($LASTEXITCODE -ne 0) { throw "SSH lieferte Exit-Code $LASTEXITCODE." }
    Write-ScriptLog "Physischer Home-Assistant-Neustart auf $($pendingHAReboot.Host) für $($plannedAt.ToString('dd.MM.yyyy HH:mm')) eingeplant."
  }
  catch { Write-ScriptLog "Physischer Home-Assistant-Neustart auf $($pendingHAReboot.Host) konnte nicht eingeplant werden: $($_.Exception.Message)" }
}

foreach ($pendingReboot in $script:PendingPhysicalReboots) {
  if ($physicalRebootNotBefore -gt [datetime]::MinValue) {
    $plannedPhysicalAt = Get-NextRebootTimeInWindow -StartTime $pendingReboot.RebootTime -LatestTime $pendingReboot.LatestRebootTime
    if ($plannedPhysicalAt -lt $physicalRebootNotBefore) {
      Write-ScriptLog "Physischer Neustart auf $($pendingReboot.Servername) wird wegen des VM-Neustartblocks auf das nächste Wartungsfenster verschoben (VMs bis $($script:VMRebootLatestAt.ToString('dd.MM.yyyy HH:mm')); eine Stunde Puffer)."
    }
  }
  Request-RebootTask -Servername $pendingReboot.Servername -RebootTime $pendingReboot.RebootTime -LatestRebootTime $pendingReboot.LatestRebootTime -NotBefore $physicalRebootNotBefore -AuthInfo $pendingReboot.AuthInfo
}

# Anwendungsupdates in Report einfügen
if ($PackageUpdateDetails.Count -gt 0) {
  $RepBody += "<div class='section-title'>📦 Anwendungsupdates</div>"
  foreach ($packageInfo in $PackageUpdateDetails) {
    $packageList = @($packageInfo.Packages | ForEach-Object { [System.Net.WebUtility]::HtmlEncode([string]$_) }) -join '<br>'
    $RepBody += "<div class='server-title'>Server: $($packageInfo.Server) – $($packageInfo.Manager)</div>"
    $RepBody += "<div class='linux-package-list'><strong>Aktualisierte Pakete ($(@($packageInfo.Packages).Count)):</strong><br>$packageList</div>"
  }
}

# Linux-Updates in Report einfügen
if ($LinuxScriptExecuted) {
  $RepBody += "<div class='section-title'>🐧 Linux-Server Updates</div>"
  
  if ($LinuxUpdateDetails -and @($LinuxUpdateDetails).Count -gt 0) {
    foreach ($hostInfo in $LinuxUpdateDetails) {
      $RepBody += "<div class='server-title'>Server: $($hostInfo.Host)</div>"
      
      if ($hostInfo.UpdateCount -gt 0) {
        $RepBody += "<p><strong>Installierte Updates:</strong> $($hostInfo.UpdateCount)</p>"
        
        if ($hostInfo.Packages) {
          $RepBody += "<div class='linux-package-list'>"
          $RepBody += "<strong>Aktualisierte Pakete:</strong><br>"
          $RepBody += $hostInfo.Packages
          $RepBody += "</div>"
        }
      } else {
        $RepBody += "<div class='no-updates'>Keine Updates installiert.</div>"
      }
    }
  } else {
    $RepBody += "<div class='no-updates'>Alle Linux-Server sind auf dem neuesten Stand.</div>"
  }
}

# Home Assistant-Updates in Report einfügen
if ($HAScriptExecuted) {
  $RepBody += "<div class='section-title'>🏠 Home Assistant Updates</div>"
  
  if ($HAUpdateDetails -and $HAUpdateDetails.Count -gt 0) {
    foreach ($hostInfo in $HAUpdateDetails) {
      $RepBody += "<div class='server-title'>Instanz: $($hostInfo.Host)</div>"
      
      if ($hostInfo.UpdateCount -gt 0 -or $hostInfo.Status -eq "Erfolgreich") {
        $RepBody += "<p><strong>Status:</strong> $($hostInfo.Status)</p>"
        
        if ($hostInfo.UpdateCount) {
          $RepBody += "<p><strong>Installierte Updates:</strong> $($hostInfo.UpdateCount)</p>"
        }
        
        if ($hostInfo.Details) {
          $RepBody += "<div class='linux-package-list'>"
          $RepBody += "<strong>Details:</strong><br>"
          $RepBody += $hostInfo.Details
          $RepBody += "</div>"
        }
      } else {
        $RepBody += "<div class='no-updates'>Keine Updates installiert.</div>"
      }
    }
  } else {
    $RepBody += "<div class='no-updates'>Alle Home Assistant-Instanzen sind auf dem neuesten Stand.</div>"
  }
}

# Zusammenfassung
$ScriptDuration = [math]::Round((New-TimeSpan -Start $ScriptStartTime).TotalMinutes, 2)
$TotalServerCount = $Anzahl + $LinuxServerCount + $HAServerCount
$TotalUpdatesInstalled = $UpdCount + $PackageUpdateCount + $LinuxUpdatesInstalled + $HAUpdatesInstalled
$TotalUpdatesFailed = $ErrorCount + $LinuxUpdatesFailed + $HAUpdatesFailed

if ($TotalUpdatesInstalled -eq 0) {
  $RepBody += @"
<div class="summary success">
    <p><strong>✅ Ergebnis: Es wurden KEINE Updates installiert!</strong></p>
    <p>Alle Systeme sind auf dem neuesten Stand.</p>
</div>
"@
} else {
  $RepBody += @"
<div class="summary warning">
    <p><strong>⚠️ Ergebnis: Es wurden insgesamt $TotalUpdatesInstalled Update(s) installiert!</strong></p>
    <p>Bitte überprüfen Sie die Details oben und planen Sie gegebenenfalls Neustarts ein.</p>
</div>
"@
}

$RepBody += @"
<div class="info-box">
    <h2>📊 Detaillierte Zusammenfassung</h2>
    <h3>Serveranzahl</h3>
    <p><strong>Gesamtanzahl Server:</strong> $TotalServerCount</p>
    <ul>
        <li>Windows-Server (AD): $WindowsAdCount</li>
        <li>Windows-Server (Nicht-AD): $WindowsNonAdCount</li>
"@

if ($LinuxScriptExecuted) {
  $RepBody += "        <li>Linux-Server: $LinuxServerCount</li>`n"
}

if ($HAScriptExecuted) {
  $RepBody += "        <li>Home Assistant: $HAServerCount</li>`n"
}

$RepBody += @"
    </ul>
    
    <h3>Installierte Updates</h3>
    <p><strong>Gesamt installiert:</strong> $TotalUpdatesInstalled</p>
    <ul>
        <li>Windows-Updates: $UpdCount</li>
"@

if ($PackageUpdateCount -gt 0) {
  $RepBody += "        <li>Anwendungsupdates: $PackageUpdateCount (Winget: $WingetUpdateCount, Chocolatey: $ChocolateyUpdateCount)</li>`n"
}
if ($LinuxScriptExecuted) {
  $RepBody += "        <li>Linux-Updates: $LinuxUpdatesInstalled</li>`n"
}

if ($HAScriptExecuted) {
  $RepBody += "        <li>Home Assistant-Updates: $HAUpdatesInstalled</li>`n"
}

$RepBody += @"
    </ul>
    
    <h3>Fehler</h3>
    <p><strong>Fehler aufgetreten:</strong> $TotalUpdatesFailed</p>
    <ul>
        <li>Windows: $ErrorCount</li>
"@

if ($LinuxScriptExecuted) {
  $RepBody += "        <li>Linux: $LinuxUpdatesFailed</li>`n"
}

if ($HAScriptExecuted) {
  $RepBody += "        <li>Home Assistant: $HAUpdatesFailed</li>`n"
}

$RepBody += @"
    </ul>
    
    <p><strong>⏱️ Verarbeitungsdauer:</strong> $ScriptDuration Minuten</p>
</div>
</body>
</html>
"@

$summaryLines = @(
  "Gesamtanzahl Server: $TotalServerCount",
  "  • Windows-Server (AD): $WindowsAdCount",
  "  • Windows-Server (Nicht-AD): $WindowsNonAdCount"
)
if ($LinuxScriptExecuted) { $summaryLines += "  • Linux-Server: $LinuxServerCount" }
if ($HAScriptExecuted) { $summaryLines += "  • Home Assistant: $HAServerCount" }
$summaryLines += @('', "Updates installiert: $TotalUpdatesInstalled", "  • Windows: $UpdCount")
if ($PackageUpdateCount -gt 0) { $summaryLines += "  • Anwendungen: $PackageUpdateCount (Winget: $WingetUpdateCount, Chocolatey: $ChocolateyUpdateCount)" }
if ($LinuxScriptExecuted) { $summaryLines += "  • Linux: $LinuxUpdatesInstalled" }
if ($HAScriptExecuted) { $summaryLines += "  • Home Assistant: $HAUpdatesInstalled" }
$summaryLines += @('', "Fehler: $TotalUpdatesFailed", "  • Windows: $ErrorCount")
if ($LinuxScriptExecuted) { $summaryLines += "  • Linux: $LinuxUpdatesFailed" }
if ($HAScriptExecuted) { $summaryLines += "  • Home Assistant: $HAUpdatesFailed" }
$summaryLines += @('', "Dauer: $ScriptDuration Minuten")
Write-WindowsUpdateConsoleSummary -Title 'UPDATE-INSTALLATION ZUSAMMENFASSUNG' -Lines $summaryLines -WriteLog { param($message) Write-ScriptLog $message }
# E-Mail versenden
# SendMail und Subject direkt hier auswerten - sicher in PS5.1 und PS7
$mailBlock = $MailSettings.Install
$doSendMail = $false
if ($mailBlock -ne $null) {
  $doSendMail = [bool]$mailBlock.SendMail
  $companyName = [string]$MailSettings.CompanyName
  $subjectText = [string]$mailBlock.Subject
  if ([string]::IsNullOrWhiteSpace($subjectText)) { $subjectText = "Server Updates installiert" }
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
  Write-ScriptLog "Kein Mailversand (SendMail=false fuer Install)."
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

# Der Verwaltungsserver wird bewusst erst ganz am Ende geplant, damit ein
# unmittelbarer VM-Neustart keinen noch laufenden Gesamt-Updateprozess abschneidet.
Register-DeferredLocalRebootTask

Write-ScriptLog "Installation abgeschlossen."
