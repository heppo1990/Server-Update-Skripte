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
    [switch]$TestDeferredMail,
    # Interne Parameter für die Fortsetzung nach einem PowerShell-7-Update.
    [switch]$ManagementPowerShellResume,
    [string]$ManagementPowerShellStatePath,
    [string]$ManagementPowerShellRunLogPath,
    [string]$ManagementPowerShellRunTimestamp
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
if ($scriptUpdateLoaded) {
    Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath -BoundParameters $PSBoundParameters -RemainingArguments $args
}



Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Module\WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

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
$WindowsUnreachableHosts = 0
$WindowsUpdateDetails = @()
$PackageUpdateDetails = @()
$PackageUpdateCount = 0
$WingetUpdateCount = 0
$ChocolateyUpdateCount = 0
$LinuxUpdateDetails = @()
$HAUpdateDetails = @()
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
if (-not [string]::IsNullOrWhiteSpace($ManagementPowerShellRunTimestamp)) { $TimeStamp = $ManagementPowerShellRunTimestamp }
if (-not [string]::IsNullOrWhiteSpace($ManagementPowerShellRunLogPath)) { $LogFileName = $ManagementPowerShellRunLogPath }
$ReportFileName = Join-Path -Path ($PSScriptRoot + "/Logs") -ChildPath "${ScriptName}_Report_${TimeStamp}.html"
$script:ManagementPowerShellUpdateState = $null
$script:ManagementPowerShellUpdateExcludeId = @()
$script:ManagementPowerShellUpdateExcludeChocolateyId = @()
$script:ManagementPowerShellPreflightFailure = ''

############################################################################################################################################################################
# Funktionen
############################################################################################################################################################################

function Write-ScriptLog {
  param(
    [Parameter(Mandatory=$false)]
    [AllowEmptyString()]
    [string]$Message = "",
    
    [Parameter(Mandatory=$false)]
    [switch]$IsDebug,

    [Parameter(Mandatory=$false)]
    [switch]$LogOnly
  )
  
  Write-WindowsUpdateLog -Message $Message -LogFile $LogFileName -ScriptName $ScriptName -RunTimestamp $TimeStamp -WriteLogFile ([bool]($null -ne $UpdateSettings -and $UpdateSettings.WriteLogFile)) -IsDebug:$IsDebug -LogOnly:$LogOnly -DebugEnabled ([bool]$DebugMode)
}

function Invoke-PackageManagerUpdates {
  param(
    [Parameter(Mandatory)][string]$Servername,
    $AuthInfo = $null,
    [string[]]$ExcludeWinGetIds = @(),
    [string[]]$ExcludeChocolateyIds = @()
  )

  try {
    $enableWinget = if ($UpdateSettings.PSObject.Properties['EnableWingetUpdates']) { [bool]$UpdateSettings.EnableWingetUpdates } else { $true }
    $enableChocolatey = if ($UpdateSettings.PSObject.Properties['EnableChocolateyUpdates']) { [bool]$UpdateSettings.EnableChocolateyUpdates } else { $true }
    $wingetSkipReason = ''
    if ($enableWinget) {
      try {
        $targetOsInfo = Get-WindowsUpdateTargetOperatingSystem -ComputerName $Servername -AuthInfo $AuthInfo -TimeoutSeconds 60 `
          -WriteLog { param($message) Write-ScriptLog $message -LogOnly }
        Write-ScriptLog "Betriebssystem auf $Servername erkannt: $($targetOsInfo.Caption); Version $($targetOsInfo.Version); Build $($targetOsInfo.BuildNumber); ProductType $($targetOsInfo.ProductType)." -LogOnly
        if ([int]$targetOsInfo.ProductType -in @(2, 3) -and [int]$targetOsInfo.BuildNumber -lt 17763) {
          $enableWinget = $false
          $wingetSkipReason = "Windows-Server-Build $($targetOsInfo.BuildNumber) liegt vor Server 2019"
          Write-ScriptLog "WinGet auf $Servername übersprungen: $wingetSkipReason; Chocolatey und Windows Update laufen weiter."
        }
      }
      catch {
        $enableWinget = $false
        $wingetSkipReason = 'Betriebssystem nicht ermittelbar; WinGet wird vorsorglich übersprungen'
        Write-ScriptLog "WARNUNG: Betriebssystem von $Servername nicht ermittelbar; WinGet wird vorsorglich übersprungen."
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Betriebssystem vor Paketinstallation ermitteln' -Target $Servername -ErrorRecord $_ -Context @('Fallback=WinGet übersprungen')
      }
    }
    if ($enableWinget) {
      $null = Update-WinGetClientModule -ComputerName $Servername -AuthInfo $AuthInfo -WriteLog { param($message, $level) Write-ScriptLog "[$level] $message" }
    }
    $results = @(Invoke-WindowsUpdatePackageManagers -ComputerName $Servername -AuthInfo $AuthInfo -Mode Install -EnableWinget $enableWinget -EnableChocolatey $enableChocolatey -ExcludeWinGetIds $ExcludeWinGetIds -ExcludeChocolateyIds $ExcludeChocolateyIds -WriteLog { param($message, $logOnly = $false) Write-ScriptLog $message -LogOnly:([bool]$logOnly) })
    if ($wingetSkipReason) {
      foreach ($wingetResult in @($results | Where-Object { $_.Manager -eq 'Winget' -and $_.Skipped })) {
        $wingetResult.SkipReason = $wingetSkipReason
      }
    }
    # Erfolgreiche Pakete erst sammeln und danach je Manager kompakt ausgeben.
    $successfulPackagesByManager = @{}
    $manualPackageCount = 0
    $manualPackageActions = [System.Collections.Generic.List[object]]::new()
    $noUpdatesFoundByManager = @{}
    $managerHadFailure = @{}
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
        $managerHadFailure[[string]$result.Manager] = $true
        $manualActionProperty = $result.PSObject.Properties['RequiresManualAction']
        $requiresManualAction = $manualActionProperty -and [bool]$manualActionProperty.Value
        if ($requiresManualAction) {
          $failedPackageCount = @($result.Packages).Count
          $manualPackageCount += [Math]::Max(1, $failedPackageCount)
        }
        $manualTextProperty = $result.PSObject.Properties['ManualActionText']
        $errorSummaryProperty = $result.PSObject.Properties['ErrorSummary']
        $errorSummary = if ($manualTextProperty -and -not [string]::IsNullOrWhiteSpace([string]$manualTextProperty.Value)) {
          [string]$manualTextProperty.Value
        } elseif ($errorSummaryProperty -and -not [string]::IsNullOrWhiteSpace([string]$errorSummaryProperty.Value)) {
          [string]$errorSummaryProperty.Value
        } else {
          [string]$result.ActionOutput
        }
        if ([string]::IsNullOrWhiteSpace($errorSummary)) {
          $errorSummary = "Update konnte nicht automatisch abgeschlossen werden (Exitcode: $($result.ExitCode)). Details im Laufprotokoll."
        }
        if ($requiresManualAction) {
          $manualPackageActions.Add([pscustomobject]@{
            Manager = [string]$result.Manager
            Packages = @($result.Packages)
            Text = $errorSummary
          })
        } else {
          Write-ScriptLog "Fehler bei $($result.Manager) auf ${Servername}: $errorSummary"
        }
        $diagnosticProperty = $result.PSObject.Properties['DiagnosticOutput']
        $debugActionOutput = if ($diagnosticProperty) { [string]$diagnosticProperty.Value } else { [string]$result.ActionOutput }
        if ($DebugMode -and -not [string]::IsNullOrWhiteSpace($debugActionOutput)) {
          Write-ScriptLog "Vollständiger $($result.Manager)-Output von ${Servername}:" -IsDebug
          $debugActionOutput -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-ScriptLog "  $_" -IsDebug }
        }
        continue
      }

      $packageCount = @($result.Packages).Count
      if ($packageCount -eq 0) {
        if ($result.Available -and $result.Success) { $noUpdatesFoundByManager[[string]$result.Manager] = $true }
        continue
      }

      if (-not $successfulPackagesByManager.ContainsKey([string]$result.Manager)) { $successfulPackagesByManager[[string]$result.Manager] = @() }
      $successfulPackagesByManager[[string]$result.Manager] += @($result.Packages)
      $diagnosticProperty = $result.PSObject.Properties['DiagnosticOutput']
      $debugActionOutput = if ($diagnosticProperty) { [string]$diagnosticProperty.Value } else { [string]$result.ActionOutput }
      if ($DebugMode -and -not [string]::IsNullOrWhiteSpace($debugActionOutput)) {
        Write-ScriptLog "Vollständiger $($result.Manager)-Output von ${Servername}:" -IsDebug
        $debugActionOutput -split "`n" | Where-Object { $_.Trim() } | ForEach-Object { Write-ScriptLog "  $_" -IsDebug }
      }
    }
    foreach ($manager in @($noUpdatesFoundByManager.Keys | Sort-Object)) {
      if (-not $managerHadFailure.ContainsKey([string]$manager) -and -not $successfulPackagesByManager.ContainsKey([string]$manager)) {
        Write-ScriptLog "$manager auf ${Servername}: keine Paketupdates verfügbar."
      }
    }
    $managerOutputWritten = $false
    foreach ($manager in $successfulPackagesByManager.Keys) {
      if ($managerOutputWritten) { Write-ScriptLog '' }
      $managerOutputWritten = $true
      $managerPackages = @($successfulPackagesByManager[$manager])
      $installedPackageCount = $managerPackages.Count
      if ($manager -eq 'Winget') {
        $normalizedRows = @(ConvertTo-WindowsUpdatePackageRows -ComputerName $Servername -Manager Winget -Packages $managerPackages)
        $packageGroups = @($normalizedRows | Group-Object -Property { ('{0}|{1}' -f [string]$_.Id, [string]$_.Source).ToLowerInvariant() })
        $managerPackages = @(
          foreach ($packageGroup in $packageGroups) {
            $groupRows = @($packageGroup.Group)
            $baseRow = $groupRows[0]
            $packageName = [string]$baseRow.Name
            $scopes = @(
              foreach ($row in $groupRows) {
                $userMatch = [regex]::Match([string]$row.Name, '^\[(?<User>[^\]]+)\]\s*(?<Name>.*)$')
                if ($userMatch.Success) {
                  $row.Name = [string]$userMatch.Groups['Name'].Value
                  "Benutzer $($userMatch.Groups['User'].Value)"
                } else { 'ausführender Kontext' }
              }
            ) | Select-Object -Unique
            if ($groupRows.Count -gt 1) {
              $packageName = [string]$groupRows[0].Name
              $scopeText = @($scopes) -join ' + '
              $packageName = "$packageName [$scopeText]"
            }
            [pscustomobject]@{
              Name = $packageName; Id = [string]$baseRow.Id
              InstalledVersion = [string]$baseRow.InstalledVersion
              AvailableVersion = [string]$baseRow.AvailableVersion
              Source = [string]$baseRow.Source
            }
          }
        )
        if ($managerPackages.Count -lt $installedPackageCount) {
          Write-ScriptLog "$manager auf ${Servername}: $installedPackageCount Paketupdates installiert; $($managerPackages.Count) eindeutige Paket-ID(s), Mehrfachtreffer aus Benutzerkontexten zusammengeführt."
        } else {
          Write-ScriptLog "$manager auf ${Servername}: $installedPackageCount Paketupdates installiert"
        }
      } else {
        Write-ScriptLog "$manager auf ${Servername}: $installedPackageCount Paketupdates installiert"
      }
      $packageTable = Format-WindowsUpdatePackageConsoleTable -ComputerName $Servername -Manager $manager -Packages $managerPackages
      foreach ($tableLine in ($packageTable -split "`r?`n")) {
        if (-not $tableLine) { continue }
        Write-ScriptLog $tableLine -LogOnly
        Write-WindowsUpdateConsoleLine -Message $tableLine -AlreadyFiltered
      }
    }
    if ($successfulPackagesByManager.Count -eq 0 -and $manualPackageCount -eq 0) { Write-ScriptLog '' }
    if ($manualPackageCount -gt 0) {
      $manualPackageLabel = if ($manualPackageCount -eq 1) { 'Paket' } else { 'Pakete' }
      Write-ScriptLog "Manuelle Aktion erforderlich: $manualPackageCount $manualPackageLabel auf ${Servername}."
      foreach ($manualAction in $manualPackageActions) {
        $manualRows = @($manualAction.Packages)
        $manualPackageName = ''
        if ($manualRows.Count -gt 0) {
          $firstManualRow = $manualRows[0]
          if ($firstManualRow -is [string]) {
            $manualRowMatch = [regex]::Match(
              [string]$firstManualRow,
              '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<InstalledVersion>\S+)\s+(?<AvailableVersion>\S+)\s+(?<Source>[^\s]+)\s*$',
              [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
            )
            $manualPackageName = if ($manualRowMatch.Success) { $manualRowMatch.Groups['Name'].Value.Trim() } else { ([string]$firstManualRow).Trim() }
          } elseif ($null -ne $firstManualRow) {
            $nameProperty = $firstManualRow.PSObject.Properties['Name']
            $idProperty = $firstManualRow.PSObject.Properties['Id']
            if ($nameProperty) { $manualPackageName = [string]$nameProperty.Value }
            if ([string]::IsNullOrWhiteSpace($manualPackageName) -and $idProperty) { $manualPackageName = [string]$idProperty.Value }
          }
        }
        if ([string]::IsNullOrWhiteSpace($manualPackageName)) { $manualPackageName = [string]$manualAction.Manager }
        Write-ScriptLog "  $manualPackageName`: $($manualAction.Text)"
      }
      Write-ScriptLog ''
    }
    # Die Konsolenausgabe wird aus den bestätigten Einzelergebnissen aufgebaut.
    # Dieselben Zähler geben wir explizit zurück, damit die Gesamtsumme nicht
    # von der Enumeration/Serialisierung einzelner Remoting-Objekte abhängt.
    $installedCounts = @{}
    foreach ($manager in $successfulPackagesByManager.Keys) {
      $installedCounts[[string]$manager] = @($successfulPackagesByManager[$manager]).Count
    }
    $results += [pscustomobject]@{
      Manager = '__InstallSummary'
      Available = $false
      Success = $true
      Skipped = $true
      SkipReason = 'Interne Zählzusammenfassung'
      Packages = @()
      InstalledCounts = $installedCounts
    }
    return $results
  }
  catch {
    Write-ScriptLog "WARNUNG: Package-Manager-Updates auf ${Servername} fehlgeschlagen; Details im Log."
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'PackageManager-Install' -Target $Servername -ErrorRecord $_
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
      # Auch der Verwaltungsserver verwendet zuerst denselben eingeschränkten
      # WindowsUpdateAdm-Endpunkt wie entfernte Ziele und der Download-Lauf.
      $localJeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -WriteLog { param($message) Write-ScriptLog $message }
      if ($localJeaSupported) {
        try {
          $jeaTestParams = @{
            ComputerName      = $Servername
            ConfigurationName = 'WindowsUpdateAdm'
            ScriptBlock       = { 1 }
            ErrorAction       = 'Stop'
          }
          $null = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Verbindungstest auf Verwaltungsserver $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @jeaTestParams }
          Write-ScriptLog "Windows-Update-Installation auf dem Verwaltungsserver via WindowsUpdateAdm/JEA: $Servername..."
          $localJeaParams = @{
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
          $UpdResult = Invoke-WindowsUpdateWithRetry -OperationName "JEA-Update-Installation auf Verwaltungsserver $Servername" -WriteLog { param($message) Write-ScriptLog $message } -ScriptBlock { Invoke-Command @localJeaParams }
        }
        catch {
          Write-ScriptLog "FEHLER: WindowsUpdateAdm auf dem Verwaltungsserver $Servername ist fehlgeschlagen; der abweichende Loopback-Pfad wird nicht verwendet. Details im Log."
          Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'JEA-Update-Installation-Verwaltungsserver' -Target $Servername -ErrorRecord $_ -Context @('Fallback=keiner; Verwaltungsserver muss denselben WindowsUpdateAdm-Endpunkt wie der Download verwenden')
          throw
        }
      } else {
        throw "WindowsUpdateAdm/JEA ist auf dem Verwaltungsserver $Servername nicht verfügbar. Lokale Updateinstallationen werden nicht direkt oder über einen uneingeschränkten Loopback-Fallback ausgeführt; bitte WindowsUpdateAdm-Verteilung prüfen."
      }
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
        Write-ScriptLog "INFO: WindowsUpdateAdm nicht verfügbar auf ${Servername}; nutze Standard-Remoting. Details im Log." -IsDebug
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'JEA-Verbindungstest' -Target $Servername -ErrorRecord $_ -Context @('Fallback=Standard-Remoting')
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
            Write-ScriptLog "WARNUNG: Client-Zertifikat-Verbindung zu $Servername fehlgeschlagen; Details im Log."
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'WinRM-Install-Certificate' -Target $Servername -ErrorRecord $_
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
    }
    
    return @(,$UpdResult)
  }
  catch {
    Write-ScriptLog "WARNUNG: Windows-Updates auf ${Servername} fehlgeschlagen; Details im Log."
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'WindowsUpdate-Install' -Target $Servername -ErrorRecord $_
    return @()
  }
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
  Register-WindowsUpdateRebootTask -Servername $Servername -RebootTime $RebootTime -LatestRebootTime $LatestRebootTime -DelayMinutes $DelayMinutes -NotBefore $NotBefore -Immediately:$Immediately -AuthInfo $AuthInfo -WriteLog { param($message) Write-ScriptLog $message }
}

function Register-DeferredLocalRebootTask {
  if ($null -eq $script:DeferredLocalReboot) { return }
  $request = $script:DeferredLocalReboot
  Write-ScriptLog "Alle Zielserver sind verarbeitet – plane nun den Neustart des Verwaltungsservers $($request.Servername)."
  Register-WindowsUpdateRebootTask -Servername $request.Servername -RebootTime $request.RebootTime -LatestRebootTime $request.LatestRebootTime -DelayMinutes $request.DelayMinutes -NotBefore $request.NotBefore -Immediately:$request.Immediately -AuthInfo $request.AuthInfo -WriteLog { param($message) Write-ScriptLog $message }
  $script:DeferredLocalReboot = $null
}

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

Write-Host ''
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "PowerShell Version: $($PSVersionTable.PSVersion)" -ForegroundColor Gray
Write-Host "Betriebssystem: $([System.Environment]::OSVersion.VersionString)" -ForegroundColor Gray
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ''

$Settings = Get-InstallSettingsFromCommon
$linuxSettings = if ($Settings.PSObject.Properties['LinuxSettings']) { $Settings.LinuxSettings } else { $null }
$haSettings = if ($Settings.PSObject.Properties['HomeAssistantSettings']) { $Settings.HomeAssistantSettings } else { $null }
$LinuxConfigured = $null -ne $linuxSettings -and $linuxSettings.PSObject.Properties['Hosts'] -and @($linuxSettings.Hosts | Where-Object { $_ }).Count -gt 0
$HAConfigured = $null -ne $haSettings -and $haSettings.PSObject.Properties['Host'] -and -not [string]::IsNullOrWhiteSpace([string]$haSettings.Host)
$LinuxConfiguredHostCount = if ($LinuxConfigured) { @($linuxSettings.Hosts | Where-Object { $_ }).Count } else { 0 }
$UpdateSettings = $Settings.UpdateSettings
$MailSettings = $Settings.MailSettings

# PowerShell 7 darf sich auf dem Verwaltungsserver nicht selbst aktualisieren:
# WinGet oder Chocolatey können den laufenden pwsh-Prozess beim Austausch beenden.
# PS 5.1 bleibt als unabhängiger Prozess bestehen und startet den Lauf anschließend neu.
$shouldPreflightManagementPowerShell = $PSVersionTable.PSEdition -eq 'Core' -and
  $PSVersionTable.PSVersion.Major -ge 7 -and -not $TestDeferredMail
if ($TargetComputer -and $TargetComputer.Count -gt 0) {
  $localManagementNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName())
  if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { $localManagementNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
  $shouldPreflightManagementPowerShell = $shouldPreflightManagementPowerShell -and
    @($TargetComputer | Where-Object { $localManagementNames -contains $_ }).Count -gt 0
}
$wingetEnabledForManagement = -not $UpdateSettings.PSObject.Properties['EnableWingetUpdates'] -or [bool]$UpdateSettings.EnableWingetUpdates
$chocolateyEnabledForManagement = -not $UpdateSettings.PSObject.Properties['EnableChocolateyUpdates'] -or [bool]$UpdateSettings.EnableChocolateyUpdates
if ($wingetEnabledForManagement) {
  try {
    $localOsInfo = Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop
    Write-ScriptLog "Betriebssystem des Verwaltungsservers erkannt: $($localOsInfo.Caption); Version $($localOsInfo.Version); Build $($localOsInfo.BuildNumber); ProductType $($localOsInfo.ProductType)." -LogOnly
    if ([int]$localOsInfo.ProductType -in @(2, 3) -and [int]$localOsInfo.BuildNumber -lt 17763) {
      $wingetEnabledForManagement = $false
      Write-ScriptLog "WinGet auf Verwaltungsserver $env:COMPUTERNAME übersprungen: Windows-Server-Build $($localOsInfo.BuildNumber) liegt vor Server 2019."
    }
  }
  catch {
    $wingetEnabledForManagement = $false
    Write-ScriptLog 'WARNUNG: Betriebssystem des Verwaltungsservers nicht ermittelbar; WinGet-Vorabprüfung wird vorsorglich übersprungen.'
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Betriebssystem des Verwaltungsservers ermitteln' -Target $env:COMPUTERNAME -ErrorRecord $_ -Context @('Fallback=WinGet-Vorabprüfung übersprungen')
  }
}

if ($ManagementPowerShellResume) {
  if ([string]::IsNullOrWhiteSpace($ManagementPowerShellStatePath) -or -not (Test-Path -LiteralPath $ManagementPowerShellStatePath -PathType Leaf)) {
    Write-ScriptLog 'FEHLER: Fortsetzungsstatus des Verwaltungsserver-PowerShell-Updates fehlt; der Lauf wird abgebrochen.'
    throw 'Fortsetzungsstatus des Verwaltungsserver-PowerShell-Updates wurde nicht gefunden.'
  }
  # Der PS5.1-Übergabeprozess wartet auf diese Fortsetzung und liest danach
  # denselben Status. Erst der übergeordnete PS5.1-Prozess darf ihn löschen.
  $script:ManagementPowerShellUpdateState = Get-Content -LiteralPath $ManagementPowerShellStatePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
  $resumedPowerShellManager = if ($script:ManagementPowerShellUpdateState.PSObject.Properties['Manager'] -and
    -not [string]::IsNullOrWhiteSpace([string]$script:ManagementPowerShellUpdateState.Manager)) {
    [string]$script:ManagementPowerShellUpdateState.Manager
  } else { 'Winget' }
  $script:ManagementPowerShellUpdateExcludeId = @('Microsoft.PowerShell')
  $script:ManagementPowerShellUpdateExcludeChocolateyId = @('powershell-core')
  if ([bool]$script:ManagementPowerShellUpdateState.Success) {
    try {
      $targetPowerShellVersion = [version]::Parse([string]$script:ManagementPowerShellUpdateState.AvailableVersion)
      $currentPowerShellVersion = [version]::Parse([string]$PSVersionTable.PSVersion)
    }
    catch {
      throw "PowerShell-Versionen für die Fortsetzungsprüfung sind ungültig (aktuell='$($PSVersionTable.PSVersion)', erwartet='$($script:ManagementPowerShellUpdateState.AvailableVersion)')."
    }
    $currentComparableVersion = [version]::new($currentPowerShellVersion.Major, $currentPowerShellVersion.Minor, [Math]::Max(0, $currentPowerShellVersion.Build))
    $targetComparableVersion = [version]::new($targetPowerShellVersion.Major, $targetPowerShellVersion.Minor, [Math]::Max(0, $targetPowerShellVersion.Build))
    if ($currentComparableVersion -lt $targetComparableVersion) {
      Write-ScriptLog "FEHLER: Verwaltungsserver wurde mit PowerShell $($PSVersionTable.PSVersion) statt der erwarteten Version $($script:ManagementPowerShellUpdateState.AvailableVersion) fortgesetzt."
      throw 'Das PowerShell-7-Update wurde nicht wirksam; der Lauf wird nicht mit der alten Version fortgesetzt.'
    }
    $managementPowerShellPackage = [PSCustomObject]@{
      Name = [string]$script:ManagementPowerShellUpdateState.Name
      Id = [string]$script:ManagementPowerShellUpdateState.Id
      InstalledVersion = [string]$script:ManagementPowerShellUpdateState.InstalledVersion
      AvailableVersion = [string]$script:ManagementPowerShellUpdateState.AvailableVersion
      Source = [string]$script:ManagementPowerShellUpdateState.Source
    }
    $PackageUpdateCount++
    if ($resumedPowerShellManager -eq 'Chocolatey') { $ChocolateyUpdateCount++ } else { $WingetUpdateCount++ }
    $PackageUpdateDetails += [PSCustomObject]@{ Server=$env:COMPUTERNAME; Manager=$resumedPowerShellManager; Packages=@($managementPowerShellPackage); Success=$true }
    Write-ScriptLog "Verwaltungsserver-Update in PowerShell $($PSVersionTable.PSVersion) fortgesetzt; PowerShell $($managementPowerShellPackage.InstalledVersion) → $($managementPowerShellPackage.AvailableVersion) wird als $resumedPowerShellManager-Update gezählt."
    $managementPowerShellTable = Format-WindowsUpdatePackageConsoleTable -ComputerName $env:COMPUTERNAME -Manager $resumedPowerShellManager -Packages @($managementPowerShellPackage)
    foreach ($tableLine in ($managementPowerShellTable -split "`r?`n")) {
      if (-not $tableLine) { continue }
      Write-ScriptLog $tableLine -LogOnly
      Write-WindowsUpdateConsoleLine -Message $tableLine -AlreadyFiltered
    }
  }
  else {
    $script:ManagementPowerShellPreflightFailure = [string]$script:ManagementPowerShellUpdateState.Error
    if ([string]::IsNullOrWhiteSpace($script:ManagementPowerShellPreflightFailure)) { $script:ManagementPowerShellPreflightFailure = 'Der Paketmanager konnte PowerShell 7 auf dem Verwaltungsserver nicht aktualisieren.' }
    Write-ScriptLog "WARNUNG: $script:ManagementPowerShellPreflightFailure"
    if (-not [string]::IsNullOrWhiteSpace([string]$script:ManagementPowerShellUpdateState.Id)) {
      $failedManagementPackage = [PSCustomObject]@{
        Name = [string]$script:ManagementPowerShellUpdateState.Name
        Id = [string]$script:ManagementPowerShellUpdateState.Id
        InstalledVersion = [string]$script:ManagementPowerShellUpdateState.InstalledVersion
        AvailableVersion = [string]$script:ManagementPowerShellUpdateState.AvailableVersion
        Source = [string]$script:ManagementPowerShellUpdateState.Source
      }
      $failedManager = if ($script:ManagementPowerShellUpdateState.PSObject.Properties['Manager'] -and $script:ManagementPowerShellUpdateState.Manager) { [string]$script:ManagementPowerShellUpdateState.Manager } else { 'Winget' }
      $PackageUpdateDetails += [PSCustomObject]@{ Server=$env:COMPUTERNAME; Manager=$failedManager; Packages=@($failedManagementPackage); Success=$false }
    }
  }
}
elseif ($shouldPreflightManagementPowerShell -and ($wingetEnabledForManagement -or $chocolateyEnabledForManagement)) {
  Write-ScriptLog "Prüfe vorab auf ein PowerShell-7-Update für den Verwaltungsserver $env:COMPUTERNAME..."
  $managementPowerShellHandoffStarted = $false
  try {
    $managementPreflightResults = @(Invoke-WindowsUpdatePackageManagers -ComputerName $env:COMPUTERNAME -Mode Check -EnableWinget $wingetEnabledForManagement -EnableChocolatey $chocolateyEnabledForManagement -WriteLog { param($message, $logOnly = $false) Write-ScriptLog $message -LogOnly:([bool]$logOnly) })
    $managementPowerShellCandidates = @()
    $managementPreflightFailures = @()
    foreach ($managerName in @('Winget', 'Chocolatey')) {
      $managerEnabled = if ($managerName -eq 'Winget') { $wingetEnabledForManagement } else { $chocolateyEnabledForManagement }
      if (-not $managerEnabled) { continue }
      $managerCheck = @($managementPreflightResults | Where-Object { $_.Manager -eq $managerName } | Select-Object -Last 1)
      if ($managerCheck.Count -eq 0 -or -not [bool]$managerCheck[0].Success) {
        $detail = if ($managerCheck.Count -gt 0) {
          $diagnosticProperty = $managerCheck[0].PSObject.Properties['DiagnosticOutput']
          if ($diagnosticProperty -and -not [string]::IsNullOrWhiteSpace([string]$diagnosticProperty.Value)) { [string]$diagnosticProperty.Value } else { [string]$managerCheck[0].ActionOutput }
        } else { 'Der Paketmanager lieferte kein Prüfergebnis.' }
        $managementPreflightFailures += [PSCustomObject]@{ Manager=$managerName; Detail=$detail }
        continue
      }
      $managerRows = @(ConvertTo-WindowsUpdatePackageRows -ComputerName $env:COMPUTERNAME -Manager $managerName -Packages @($managerCheck[0].Packages))
      # Eine if-Expression entpackt ein einzelnes Array-Element in PowerShell.
      # Danach ist .Count unter StrictMode nicht zuverlässig verfügbar.
      [object[]]$candidate = @()
      if ($managerName -eq 'Winget') {
        $candidate = @($managerRows | Where-Object { $_.Id -ieq 'Microsoft.PowerShell' -and $_.Source -ieq 'winget' } | Select-Object -First 1)
      } else {
        $candidate = @($managerRows | Where-Object { $_.Id -ieq 'powershell-core' } | Select-Object -First 1)
      }
      if ($candidate.Count -gt 0) {
        $candidate[0] | Add-Member -NotePropertyName Manager -NotePropertyValue $managerName -Force
        $managementPowerShellCandidates += $candidate[0]
      }
    }
    $managementPowerShellUpdate = @($managementPowerShellCandidates | Sort-Object { if ($_.Manager -eq 'Winget') { 0 } else { 1 } } | Select-Object -First 1)
    if ($managementPowerShellUpdate.Count -eq 0 -and $managementPreflightFailures.Count -gt 0) {
      $script:ManagementPowerShellPreflightFailure = 'PowerShell-7-Update auf dem Verwaltungsserver konnte mit den aktivierten Paketmanagern nicht zuverlässig geprüft werden.'
      $script:ManagementPowerShellUpdateExcludeId = @('Microsoft.PowerShell')
      $script:ManagementPowerShellUpdateExcludeChocolateyId = @('powershell-core')
      Write-ScriptLog "WARNUNG: $script:ManagementPowerShellPreflightFailure Das PowerShell-Paket wird in diesem Lauf nicht erneut automatisch gestartet."
      foreach ($failure in $managementPreflightFailures) {
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation "Verwaltungsserver-PowerShell-Vorabprüfung-$($failure.Manager)" -Target $env:COMPUTERNAME -DiagnosticText ([string]$failure.Detail)
      }
    }
    elseif ($managementPowerShellUpdate.Count -eq 0) {
      Write-ScriptLog "Kein PowerShell-7-Update für den Verwaltungsserver $env:COMPUTERNAME verfügbar."
    }
    else {
        $managementPowerShellUpdate = $managementPowerShellUpdate[0]
        $managementPowerShellManager = [string]$managementPowerShellUpdate.Manager
        Write-ScriptLog "PowerShell-7-Update für den Verwaltungsserver gefunden: $($managementPowerShellUpdate.InstalledVersion) → $($managementPowerShellUpdate.AvailableVersion) ($managementPowerShellManager). Starte die Installation über Windows PowerShell 5.1."
        $windowsPowerShell51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $pwshExecutable = Join-Path $PSHOME 'pwsh.exe'
        $wingetExecutable = $null
        $chocolateyExecutable = $null
        if ($managementPowerShellManager -eq 'Winget') {
          if ($localOsInfo -and [int]$localOsInfo.ProductType -gt 1 -and [int]$localOsInfo.BuildNumber -eq 17763 -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $portableCacheRoot = Join-Path $env:LOCALAPPDATA 'WindowsUpdateAdm\WinGetPortable'
            if (Test-Path -LiteralPath $portableCacheRoot -PathType Container) {
              $portableCandidates = @(Get-ChildItem -LiteralPath $portableCacheRoot -Filter winget.exe -File -Recurse -ErrorAction SilentlyContinue | ForEach-Object {
                $versionMatch = [regex]::Match($_.FullName, '\\WinGetPortable\\v?(?<Version>\d+(?:\.\d+){1,3})(?:\\|$)', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($versionMatch.Success) {
                  try { [pscustomobject]@{ Path=$_.FullName; Version=[version]$versionMatch.Groups['Version'].Value } } catch { }
                }
              } | Sort-Object Version -Descending)
              if ($portableCandidates.Count -gt 0) {
                $wingetExecutable = [string]$portableCandidates[0].Path
                Write-ScriptLog "Server 2019: verwende die portable WinGet-CLI aus dem lokalen Cache ($($portableCandidates[0].Version)); AppX wird in PowerShell 7 nicht geladen." -LogOnly
              }
            }
          }
          $appInstallerPackages = @()
          if ([string]::IsNullOrWhiteSpace($wingetExecutable)) {
            try {
              $appInstallerPackages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop | Sort-Object { try { [version]$_.Version } catch { [version]'0.0' } } -Descending)
            }
            catch {
              Write-ScriptLog "AppX-Abfrage für WinGet auf dem Verwaltungsserver nicht verfügbar; prüfe die installierten Paketpfade und den Benutzeralias weiter. Ursache: $($_.Exception.Message)" -LogOnly
            }
          }
          foreach ($appInstallerPackage in $appInstallerPackages) {
            $candidateWinget = Join-Path ([string]$appInstallerPackage.InstallLocation) 'winget.exe'
            if (Test-Path -LiteralPath $candidateWinget -PathType Leaf) { $wingetExecutable = $candidateWinget; break }
          }
          if ([string]::IsNullOrWhiteSpace($wingetExecutable)) {
            $appInstallerPaths = @(Get-ChildItem -Path (Join-Path $env:ProgramFiles 'WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe') -ErrorAction SilentlyContinue |
              Sort-Object { if ($_.FullName -match 'Microsoft\.DesktopAppInstaller_(\d+(?:\.\d+){1,3})_') { [version]$Matches[1] } else { [version]'0.0' } } -Descending)
            if ($appInstallerPaths.Count -gt 0) { $wingetExecutable = [string]$appInstallerPaths[0].FullName }
          }
          if ([string]::IsNullOrWhiteSpace($wingetExecutable) -and -not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
            $wingetAliasPath = Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe'
            if (Test-Path -LiteralPath $wingetAliasPath -PathType Leaf) { $wingetExecutable = $wingetAliasPath }
          }
        } else {
          $chocolateyExecutable = 'C:\ProgramData\chocolatey\bin\choco.exe'
          if (-not (Test-Path -LiteralPath $chocolateyExecutable -PathType Leaf)) {
            $chocoCommand = Get-Command -Name choco.exe, choco -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($chocoCommand) { $chocolateyExecutable = [string]$chocoCommand.Source }
          }
        }
        if (-not (Test-Path -LiteralPath $windowsPowerShell51 -PathType Leaf)) { throw 'Windows PowerShell 5.1 wurde nicht gefunden.' }
        if (-not (Test-Path -LiteralPath $pwshExecutable -PathType Leaf)) { throw "PowerShell-7-Executable wurde nicht gefunden: $pwshExecutable" }
        if ($managementPowerShellManager -eq 'Winget' -and -not (Test-Path -LiteralPath $wingetExecutable -PathType Leaf)) { throw 'winget.exe wurde auf dem Verwaltungsserver nicht gefunden.' }
        if ($managementPowerShellManager -eq 'Chocolatey' -and -not (Test-Path -LiteralPath $chocolateyExecutable -PathType Leaf)) { throw 'choco.exe wurde auf dem Verwaltungsserver nicht gefunden.' }

        $statePath = Join-Path ([IO.Path]::GetTempPath()) ("ServerUpdate-ManagementPowerShell-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $runParameters = @{}
        foreach ($parameterName in $PSBoundParameters.Keys) {
          if ($parameterName -notin @('ManagementPowerShellResume','ManagementPowerShellStatePath','ManagementPowerShellRunLogPath','ManagementPowerShellRunTimestamp')) {
            $runParameters[$parameterName] = $PSBoundParameters[$parameterName]
          }
        }
        $workerConfiguration = [ordered]@{
          ScriptPath = $PSCommandPath
          PwshPath = $pwshExecutable
          Manager = $managementPowerShellManager
          WingetPath = $wingetExecutable
          ChocolateyPath = $chocolateyExecutable
          StatePath = $statePath
          LogPath = $LogFileName
          RunTimestamp = $TimeStamp
          TargetVersion = [string]$managementPowerShellUpdate.AvailableVersion
          Package = $managementPowerShellUpdate
          Parameters = $runParameters
        }
        $continuationConfiguration = [ordered]@{
          ScriptPath = [string]$PSCommandPath
          StatePath = $statePath
          LogPath = $LogFileName
          RunTimestamp = $TimeStamp
          Parameters = $runParameters
        }
        $continuationConfigurationJson = ConvertTo-Json -InputObject $continuationConfiguration -Depth 8 -Compress
        $continuationConfigurationBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($continuationConfigurationJson))
        $continuationScript = @'
$configuration = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONTINUATION__')) | ConvertFrom-Json
$parameters = @{}
foreach ($property in $configuration.Parameters.PSObject.Properties) { $parameters[$property.Name] = $property.Value }
$parameters['ManagementPowerShellResume'] = $true
$parameters['ManagementPowerShellStatePath'] = [string]$configuration.StatePath
$parameters['ManagementPowerShellRunLogPath'] = [string]$configuration.LogPath
$parameters['ManagementPowerShellRunTimestamp'] = [string]$configuration.RunTimestamp
& ([string]$configuration.ScriptPath) @parameters
exit 0
'@.Replace('__CONTINUATION__',$continuationConfigurationBase64)
        $continuationEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($continuationScript))
        $workerConfiguration.ContinuationEncoded = $continuationEncoded
        $workerConfigurationJson = ConvertTo-Json -InputObject $workerConfiguration -Depth 8 -Compress
        $workerConfigurationBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($workerConfigurationJson))
        $workerScript = @'
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$configuration = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIGURATION__')) | ConvertFrom-Json
function Write-HandoffLog {
    param([string]$Message, [string]$Level = 'INFO')
    $line = "$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') [$Level] [PowerShell-Update-Verwaltung] $Message"
    [IO.File]::AppendAllText([string]$configuration.LogPath, $line + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    Write-Host $line
}
$exitCode = 1
$updateOutput = @()
$errorMessage = ''
try {
    Write-HandoffLog "Windows PowerShell 5.1 übernimmt PowerShell $($configuration.TargetVersion); $($configuration.Manager) wird aufgerufen."
    if ([string]$configuration.Manager -eq 'Chocolatey') {
        $chocolateyArguments = @('upgrade','powershell-core','--version',[string]$configuration.TargetVersion,'--yes','--limit-output')
        $updateOutput = @(& ([string]$configuration.ChocolateyPath) @chocolateyArguments 2>&1)
    } else {
        $wingetArguments = @('upgrade','--id','Microsoft.PowerShell','--exact','--source','winget','--version',[string]$configuration.TargetVersion,'--silent','--accept-package-agreements','--accept-source-agreements','--disable-interactivity')
        $updateOutput = @(& ([string]$configuration.WingetPath) @wingetArguments 2>&1)
    }
    $exitCode = $LASTEXITCODE
    foreach ($line in $updateOutput) {
        $text = ([string]$line).TrimEnd()
        if ($text) { Write-HandoffLog $text }
    }
    if ($exitCode -ne 0) { $errorMessage = "$($configuration.Manager) konnte PowerShell $($configuration.TargetVersion) nicht installieren (Exitcode $exitCode)." }
} catch {
    $errorMessage = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
    $exitCode = 1
    Write-HandoffLog "PowerShell-Update fehlgeschlagen: $errorMessage" 'ERROR'
}
$state = [ordered]@{
    Success = ($exitCode -eq 0)
    ExitCode = $exitCode
    Name = [string]$configuration.Package.Name
    Id = [string]$configuration.Package.Id
    InstalledVersion = [string]$configuration.Package.InstalledVersion
    AvailableVersion = [string]$configuration.Package.AvailableVersion
    Source = [string]$configuration.Package.Source
    Manager = [string]$configuration.Manager
    Error = $errorMessage
}
[IO.File]::WriteAllText([string]$configuration.StatePath, (ConvertTo-Json -InputObject $state -Depth 5), [Text.UTF8Encoding]::new($false))
if ($exitCode -eq 0) { Write-HandoffLog "$($configuration.Manager) meldet PowerShell-Update erfolgreich; starte den Installationslauf in PowerShell 7 neu." 'SUCCESS' }
else { Write-HandoffLog 'Der Installationslauf wird in PowerShell 7 fortgesetzt; das PowerShell-Paket wird nicht erneut installiert.' 'WARNING' }
try {
    Write-HandoffLog "Starte die Installationsfortsetzung sichtbar in PowerShell 7: $($configuration.PwshPath)"
    $resumeProcess = Start-Process -FilePath ([string]$configuration.PwshPath) -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',[string]$configuration.ContinuationEncoded) -PassThru -Wait -WindowStyle Normal
    Write-HandoffLog "PowerShell-7-Fortsetzung beendet (Prozess-Exitcode $($resumeProcess.ExitCode))." 'INFO'
    exit $resumeProcess.ExitCode
} catch {
    $resumeError = ([string]$_.Exception.Message -replace '\s+', ' ').Trim()
    Write-HandoffLog "FEHLER: Sichtbare PowerShell-7-Fortsetzung konnte nicht gestartet oder überwacht werden: $resumeError" 'ERROR'
    exit 31
}
'@.Replace('__CONFIGURATION__',$workerConfigurationBase64)
        $workerEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($workerScript))
        Write-ScriptLog "Starte den PS5.1-Übergabeprozess unabhängig von der aktuellen Konsole. Nach dem $managementPowerShellManager-Update öffnet er die Installationsfortsetzung sichtbar in PowerShell 7."
        $managementPowerShellHandoffStarted = $true
        $workerProcess = Start-Process -FilePath $windowsPowerShell51 -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$workerEncoded) -PassThru -Wait -WindowStyle Hidden
        if ($workerProcess.ExitCode -ne 0) {
          Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
          Write-ScriptLog "FEHLER: PS7-Fortsetzung wurde mit Exitcode $($workerProcess.ExitCode) beendet. Der ursprüngliche Lauf wird nicht parallel fortgeführt."
          return
        }
        if (-not (Test-Path -LiteralPath $statePath -PathType Leaf)) { throw "PS5.1-Übergabeprozess lieferte keinen Fortsetzungsstatus (Exitcode $($workerProcess.ExitCode))." }
        try {
          $handoffState = Get-Content -LiteralPath $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
          if ($null -eq $handoffState -or $null -eq $handoffState.PSObject.Properties['Success']) {
            throw 'Fortsetzungsstatus enthält kein Success-Feld.'
          }
        }
        catch {
          throw "Fortsetzungsstatus des Verwaltungsserver-PowerShell-Updates ist ungültig: $($_.Exception.Message)"
        }
        finally {
          Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue
        }
        if ([bool]$handoffState.Success) {
          Write-ScriptLog "PS5.1-Übergabeprozess abgeschlossen (Exitcode $($workerProcess.ExitCode)); der Paketmanager meldet das PowerShell-Update als erfolgreich und der fortgesetzte Installationslauf wurde übernommen."
        } else {
          $handoffError = if ($handoffState.PSObject.Properties['Error']) { [string]$handoffState.Error } else { 'Paketmanager meldete keinen erfolgreichen PowerShell-Updateabschluss.' }
          Write-ScriptLog "PS5.1-Übergabeprozess abgeschlossen (Exitcode $($workerProcess.ExitCode)); PowerShell-Update nicht erfolgreich: $handoffError Der fortgesetzte Installationslauf wurde dennoch übernommen."
        }
        return
      }
  }
  catch {
    if ($managementPowerShellHandoffStarted -and $statePath) { Remove-Item -LiteralPath $statePath -Force -ErrorAction SilentlyContinue }
    $script:ManagementPowerShellUpdateExcludeId = @('Microsoft.PowerShell')
    $script:ManagementPowerShellUpdateExcludeChocolateyId = @('powershell-core')
    $script:ManagementPowerShellPreflightFailure = "PowerShell-7-Vorabaktualisierung auf dem Verwaltungsserver fehlgeschlagen: $($_.Exception.Message)"
    Write-ScriptLog "WARNUNG: $script:ManagementPowerShellPreflightFailure Das PowerShell-Paket wird auf diesem Server in diesem Lauf nicht erneut gestartet."
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Verwaltungsserver-PowerShell-Update' -Target $env:COMPUTERNAME -ErrorRecord $_
    if ($managementPowerShellHandoffStarted) { throw }
  }
}

# Zurückstellungen einmalig und nur für tatsächlich konfigurierte Auswahlwerte anzeigen.
$configuredDeferredCategories = @($UpdateSettings.DeferredUpdateCategories | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
$configuredDeferredKBs = @($UpdateSettings.DeferredUpdateKBs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
if ($configuredDeferredCategories.Count -gt 0) { Write-ScriptLog "Zurückgestellte Kategorien: $($configuredDeferredCategories -join ', ')" }
if ($configuredDeferredKBs.Count -gt 0) { Write-ScriptLog "Zurückgestellte KBs: $($configuredDeferredKBs -join ', ')" }
if ([bool]$UpdateSettings.InstallDeferredUpdates) { Write-ScriptLog 'Nachinstallation aktiviert' }
$TargetComputers = $UpdateSettings.TargetComputers
if ([string]::IsNullOrWhiteSpace($TargetComputers)) {
    $TargetComputers = "Server"
}

# Zähler initialisieren
$LinuxServerCount = 0
$HAServerCount = 0
$LinuxUpdatesInstalled = 0
$LinuxUpdatesFailed = 0
$LinuxRebootScheduleFailures = 0
$HAUpdatesInstalled = 0
$HAUpdatesFailed = 0
$HASkippedHosts = 0
$LinuxScriptExecuted = $false
$HAScriptExecuted = $false
$IsWindowsOnlyRun = $TargetComputer -and $TargetComputer.Count -gt 0

# Zielübersicht vor den plattformspezifischen Läufen ausgeben. So steht die
# Gesamtliste als gemeinsame Überschrift über Linux-, HA- und Windows-Ausgaben.
$ServerADList = Get-WindowsUpdateTargets `
  -UpdateSettings $UpdateSettings `
  -TargetComputers $TargetComputers `
  -PowerShellMajor $psVersion `
  -LinuxTargetCount $(if ($IsWindowsOnlyRun) { 0 } else { $LinuxConfiguredHostCount }) `
  -HomeAssistantTargetCount $(if ($IsWindowsOnlyRun -or -not $HAConfigured) { 0 } else { 1 }) `
  -IncludeAdditionalTargetCounts `
  -WriteLog { param($message) Write-ScriptLog $message }

# Linux-Updates Skript
$LinuxUpdateScript = Join-Path -Path $PSScriptRoot -ChildPath "Komponenten\Install-Linux Updates.ps1"
$LinuxStatsFile = Join-Path (Join-Path $PSScriptRoot 'Logs') "linux_update_stats.json"
if (-not $IsWindowsOnlyRun) {
  # Im Gesamtlauf zählen konfigurierte Linux- und HA-Ziele auch bei fehlender Statistikdatei.
  $LinuxServerCount = $LinuxConfiguredHostCount
  $HAServerCount = if ($HAConfigured) { 1 } else { 0 }
}

if ($IsWindowsOnlyRun) {
  if ($LinuxConfigured) { Write-ScriptLog "Eingeschränkter Windows-Testlauf: Linux-Updates werden übersprungen." }
} elseif ($LinuxConfigured -and (Test-Path $LinuxUpdateScript)) {
  $LinuxScriptExecuted = $true
  Write-ScriptLog ''
  Write-ScriptLog "Führe Linux-Updates Skript aus: $LinuxUpdateScript"
  try {
    & $LinuxUpdateScript -VMRebootIndexStart $script:VMRebootIndex -DeferPhysicalReboots
    Write-ScriptLog "Linux-Updates Skript erfolgreich ausgeführt."
    
    if (Test-Path $LinuxStatsFile) {
        $LinuxStats = Get-Content $LinuxStatsFile | ConvertFrom-Json
      if ($LinuxStats.PSObject.Properties.Name -contains 'PendingPhysicalReboots') {
        foreach ($pendingLinuxReboot in @($LinuxStats.PendingPhysicalReboots)) { $script:PendingLinuxPhysicalReboots.Add($pendingLinuxReboot) }
      }
      $LinuxServerCount = [math]::Max($LinuxServerCount, [int]$LinuxStats.TotalHosts)
      
      if ($LinuxStats.PSObject.Properties.Name -contains 'UpdatesInstalled') {
        $LinuxUpdatesInstalled = $LinuxStats.UpdatesInstalled
        $LinuxUpdatesFailed = if ($LinuxStats.PSObject.Properties.Name -contains 'FailedHosts') { $LinuxStats.FailedHosts } else { 0 }
        $LinuxRebootScheduleFailures = if ($LinuxStats.PSObject.Properties.Name -contains 'RebootScheduleFailedHosts') { [int]$LinuxStats.RebootScheduleFailedHosts } else { 0 }
        
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
    Write-ScriptLog 'WARNUNG: Linux-Update-Skript fehlgeschlagen; Details im Log.'
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Linux-Install' -Target 'Linux' -ErrorRecord $_
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
$HAUpdateScript = Join-Path -Path $PSScriptRoot -ChildPath "Komponenten\Install-HomeAssistant Updates.ps1"
$HAStatsFile = Join-Path (Join-Path $PSScriptRoot 'Logs') "ha_update_stats.json"

if ($IsWindowsOnlyRun) {
  if ($HAConfigured) { Write-ScriptLog "Eingeschränkter Windows-Testlauf: Home-Assistant-Updates werden übersprungen." }
} elseif ($HAConfigured -and (Test-Path $HAUpdateScript)) {
  $HAScriptExecuted = $true
  Write-ScriptLog ''
  Write-ScriptLog "Führe Home Assistant-Updates Skript aus: $HAUpdateScript"
  try {
    & $HAUpdateScript -VMRebootIndexStart $script:VMRebootIndex -DeferPhysicalReboots
    Write-ScriptLog "Home Assistant-Updates Skript erfolgreich ausgeführt."
    
    if (Test-Path $HAStatsFile) {
      $HAStats = Get-Content $HAStatsFile | ConvertFrom-Json
      if ($HAStats.PSObject.Properties.Name -contains 'PendingPhysicalReboot' -and $null -ne $HAStats.PendingPhysicalReboot) {
        $script:PendingHAPhysicalReboots.Add($HAStats.PendingPhysicalReboot)
      }
      $HAServerCount = [math]::Max($HAServerCount, [int]$HAStats.TotalHosts)
      
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
      if ($HAStats.PSObject.Properties.Name -contains 'SkippedHosts') {
        $HASkippedHosts = [int]$HAStats.SkippedHosts
      }
      
      if ($HAStats.PSObject.Properties.Name -contains 'HostStatus') {
        $HAUpdateDetails = $HAStats.HostStatus
      } elseif ($HAStats.PSObject.Properties.Name -contains 'UpdateDetails') {
        $HAUpdateDetails = $HAStats.UpdateDetails
      }
      if ($HAStats.PSObject.Properties.Name -contains 'VMRebootsScheduled') {
        $script:VMRebootIndex += [int]$HAStats.VMRebootsScheduled
      }
      
      Write-ScriptLog "HA-Stats: $HAServerCount Instanz(en), $HAUpdatesInstalled Update(s) installiert, $HAUpdatesFailed fehlgeschlagen, $HASkippedHosts übersprungen"
      
      Remove-Item $HAStatsFile -Force -ErrorAction SilentlyContinue
      Write-ScriptLog "HA-Stats-Datei gelöscht: $HAStatsFile"
    }
  }
  catch {
    Write-ScriptLog 'WARNUNG: Home-Assistant-Update-Skript fehlgeschlagen; Details im Log.'
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'HomeAssistant-Install' -Target 'Home Assistant' -ErrorRecord $_
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
    Register-DeferredMailTestTask -Servername $server.Name -AuthInfo $testAuthInfo -MailSettings $MailSettings -WriteLog { param($message, $logOnly) if ($logOnly) { Write-ScriptLog $message -LogOnly } else { Write-ScriptLog $message } }
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
$DeferredUpdatesPlanned = 0
$ManualActions = @()
if (-not [string]::IsNullOrWhiteSpace($script:ManagementPowerShellPreflightFailure)) {
  $manualPowerShellPackages = @()
  $manualPowerShellManager = if ($script:ManagementPowerShellUpdateState -and $script:ManagementPowerShellUpdateState.PSObject.Properties['Manager']) {
    [string]$script:ManagementPowerShellUpdateState.Manager
  } else { 'Paketmanager' }
  if ($script:ManagementPowerShellUpdateState -and -not [string]::IsNullOrWhiteSpace([string]$script:ManagementPowerShellUpdateState.Id)) {
    $manualPowerShellPackages = @([PSCustomObject]@{
      Name = [string]$script:ManagementPowerShellUpdateState.Name
      Id = [string]$script:ManagementPowerShellUpdateState.Id
      InstalledVersion = [string]$script:ManagementPowerShellUpdateState.InstalledVersion
      AvailableVersion = [string]$script:ManagementPowerShellUpdateState.AvailableVersion
      Source = [string]$script:ManagementPowerShellUpdateState.Source
    })
  }
  $ManualActions += [PSCustomObject]@{
    Server = $env:COMPUTERNAME
    Manager = $manualPowerShellManager
    Packages = $manualPowerShellPackages
    Text = "$($script:ManagementPowerShellPreflightFailure) Das PowerShell-Paket wurde zur Vermeidung eines erneuten Abbruchs auf dem Verwaltungsserver nicht erneut automatisch gestartet. Bitte den Update-Status prüfen."
  }
}
foreach ($linuxHost in @($LinuxUpdateDetails | Where-Object { $_.Status -eq 'Updates installiert; Neustartplanung fehlgeschlagen' })) {
  $ManualActions += [PSCustomObject]@{
    Server = [string]$linuxHost.Host
    Manager = 'Linux-Neustart'
    Packages = @()
    Text = 'Updates wurden installiert, aber der erforderliche Neustart konnte nicht geplant werden. Bitte den Server manuell neu starten. Details stehen im Linux-Laufprotokoll.'
  }
}

if ($ServerADList -ne $null) {
  Write-ScriptLog ''
  Write-ScriptLog "Verarbeite AD-Serverliste..."
  Write-ScriptLog ''
  
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
        if ($index -gt 1) {
          Write-ScriptLog ''
          Write-ScriptLog ''
        }
        Write-ScriptLog "Starte Update-Installation auf AD-Server $Servername..."
        $RepBody += "<div class='server-title'>Server: ${Servername}</div>"

        $winRmProbe = Test-WindowsUpdateWinRmPorts -ComputerName $Servername -Ports @(5985, 5986) -TimeoutMilliseconds 1500
        if (-not $winRmProbe.Reachable) {
          $WindowsUnreachableHosts++
          $skipMessage = "WinRM über HTTP (5985) und HTTPS (5986) ist nach $($winRmProbe.AttemptsPerformed) Prüfversuch(en) nicht erreichbar; Ziel wird in diesem Lauf übersprungen."
          Write-ScriptLog "HINWEIS: $Servername – $skipMessage"
          Write-WindowsUpdateConsoleLine -Message "  [Übersprungen] WinRM-Ports 5985/5986 auch nach $($winRmProbe.AttemptsPerformed) Prüfversuchen nicht erreichbar." -AlreadyFiltered
          $serverHtml = [System.Net.WebUtility]::HtmlEncode([string]$Servername)
          $skipHtml = [System.Net.WebUtility]::HtmlEncode($skipMessage)
          $RepBody += "<div class='warning-box'><strong>Installation auf $serverHtml übersprungen.</strong> $skipHtml</div>"
          continue
        }
        Write-ScriptLog -Message "WinRM-Portprüfung auf ${Servername}: 5985=$(if (5985 -in $winRmProbe.OpenPorts) { 'offen' } else { 'geschlossen' }); 5986=$(if (5986 -in $winRmProbe.OpenPorts) { 'offen' } else { 'geschlossen' }); erfolgreich nach $($winRmProbe.AttemptsPerformed) Prüfversuch(en)." -LogOnly

        # Nicht-AD-Ziele erhalten TrustedHosts und Zertifikatsauthentifizierung
        # zentral; AD-Ziele bleiben bei Kerberos ohne Zertifikat.
        $remoting = Initialize-WindowsUpdateRemoting -UpdateSettings $UpdateSettings -TargetComputer $Servername -IsNonAdTarget ([bool]($Server.IsAdditional -or $Server.IsHypervisor)) -WriteLog { param($message) Write-ScriptLog $message }
        $svcCredential = $remoting.AuthInfo

        # Package-Manager-Updates
        $localManagementTargets = @($env:COMPUTERNAME, $ComputerFQDN, [System.Net.Dns]::GetHostName())
        $excludedWinGetIds = if ($localManagementTargets -contains $Servername) { @($script:ManagementPowerShellUpdateExcludeId) } else { @() }
        $excludedChocolateyIds = if ($localManagementTargets -contains $Servername) { @($script:ManagementPowerShellUpdateExcludeChocolateyId) } else { @() }
        $packageResults = @(Invoke-PackageManagerUpdates -Servername $Servername -AuthInfo $svcCredential -ExcludeWinGetIds $excludedWinGetIds -ExcludeChocolateyIds $excludedChocolateyIds)
        foreach ($packageResult in $packageResults) {
          if ([string]$packageResult.Manager -eq '__InstallSummary') {
            $installedCountsProperty = $packageResult.PSObject.Properties['InstalledCounts']
            if ($installedCountsProperty -and $installedCountsProperty.Value -is [System.Collections.IDictionary]) {
              foreach ($managerName in $installedCountsProperty.Value.Keys) {
                $installedCount = [int]$installedCountsProperty.Value[$managerName]
                $PackageUpdateCount += $installedCount
                if ([string]$managerName -eq 'Winget') { $WingetUpdateCount += $installedCount }
                if ([string]$managerName -eq 'Chocolatey') { $ChocolateyUpdateCount += $installedCount }
              }
            }
            continue
          }
          $packages = @($packageResult.Packages)
          # Auch gefundene Pakete aus fehlgeschlagenen Installationen in den
          # Mailbericht aufnehmen. Bisher landeten hier nur erfolgreiche Updates;
          # dadurch fehlten erkannte WinGet-Pakete in der Paketübersicht.
          if ($packageResult.Available -and $packages.Count -gt 0) {
            $existingPackageInfo = @($PackageUpdateDetails | Where-Object { $_.Server -ieq $Servername -and $_.Manager -ieq [string]$packageResult.Manager } | Select-Object -First 1)
            if ($existingPackageInfo.Count -gt 0) {
              $existingPackageInfo[0].Packages = @($existingPackageInfo[0].Packages) + $packages
              if (-not $packageResult.Success) { $existingPackageInfo[0].Success = $false }
            } else {
              $PackageUpdateDetails += [PSCustomObject]@{
                Server = $Servername
                Manager = [string]$packageResult.Manager
                Packages = @($packages)
                Success = [bool]$packageResult.Success
              }
            }
          }
          $manualActionProperty = $packageResult.PSObject.Properties['RequiresManualAction']
          $requiresManualAction = $manualActionProperty -and [bool]$manualActionProperty.Value
          $requiresManualReview = $packageResult.Available -and -not $packageResult.Success -and -not $packageResult.Skipped
          if ($requiresManualAction -or $requiresManualReview) {
            $manualTextProperty = $packageResult.PSObject.Properties['ManualActionText']
            $manualText = if ($manualTextProperty -and -not [string]::IsNullOrWhiteSpace([string]$manualTextProperty.Value)) {
              [string]$manualTextProperty.Value
            } elseif (-not [string]::IsNullOrWhiteSpace([string]$packageResult.SkipReason)) {
              [string]$packageResult.SkipReason
            } else {
              "$($packageResult.Manager)-Update konnte nicht automatisch abgeschlossen werden (Exitcode: $($packageResult.ExitCode)). Bitte das Laufprotokoll prüfen und das Update bei Bedarf manuell nacharbeiten."
            }
            $ManualActions += [PSCustomObject]@{
              Server = $Servername
              Manager = [string]$packageResult.Manager
              Packages = @($packageResult.Packages)
              Text = $manualText
            }
          }
          if ($packageResult.Skipped) { continue }
          if (-not $packageResult.Available -or -not $packageResult.Success) { continue }
          $packages = @($packageResult.Packages)
          if ($packages.Count -eq 0) { continue }
        }

        # Zurückgestellte Kategorien + Zeitpunkte aus Settings lesen
        $deferredCategories  = @()
        $deferredKBs         = @()
        $physicalRebootTime  = [string]$UpdateSettings.PhysicalRebootTime
        $physicalRebootWindowEndTime = [string]$UpdateSettings.PhysicalRebootWindowEndTime
        $vmRebootStartTime   = [string]$UpdateSettings.VMRebootStartTime
        $vmRebootWindowEndTime = [string]$UpdateSettings.VMRebootWindowEndTime
        $vmRebootImmediately = [bool]$UpdateSettings.VMRebootImmediately
        $installDeferred     = [bool]$UpdateSettings.InstallDeferredUpdates
        if ($UpdateSettings.DeferredUpdateCategories -and $UpdateSettings.DeferredUpdateCategories.Count -gt 0) {
          $deferredCategories = [string[]]$UpdateSettings.DeferredUpdateCategories
        }
        if ($UpdateSettings.DeferredUpdateKBs -and $UpdateSettings.DeferredUpdateKBs.Count -gt 0) {
          $deferredKBs = [string[]]$UpdateSettings.DeferredUpdateKBs
        }
        # Windows-Updates installieren (ohne zurückgestellte Kategorien)
        $UpdResult = Invoke-WindowsUpdates -Servername $Servername -SucheOnline $SucheOnline -AuthInfo $svcCredential -DeferredCategories $deferredCategories -DeferredKBs $deferredKBs -DeferredOnly $false

        # Ohne installierte Hauptupdates gibt es keinen durch diesen Lauf
        # verursachten Neustartbedarf. Insbesondere auf Server 2016 vermeiden
        # wir damit eine unnötige privilegierte Statusabfrage.
        $mainUpdateCount = @($UpdResult | Where-Object { $_ -and ($_.KB -or $_.Title) }).Count
        if ($mainUpdateCount -gt 0) {
          # PSWindowsUpdate kennt den tatsächlichen Neustartbedarf zuverlässiger
          # als eine Prüfung einzelner Registry-Schlüssel.
          $rebootRequired = Test-WindowsUpdateRebootRequired -Servername $Servername -ComputerFQDN $ComputerFQDN -AuthInfo $svcCredential -WriteLog { param($message) Write-ScriptLog $message }
          Write-ScriptLog "Get-WURebootStatus auf $($Servername): RebootRequired = $rebootRequired"
        }
        else {
          $rebootRequired = $false
          Write-ScriptLog "Kein Neustartstatus für $Servername abgefragt: In diesem Hauptlauf wurden keine Windows-Updates installiert."
        }
        if ($rebootRequired) {
          $isVirtual = Test-ServerIsVirtual -Servername $Servername -ComputerFQDN $ComputerFQDN -AuthInfo $svcCredential -WriteLog { param($message) Write-ScriptLog $message }
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
          $deferredCheck = Get-DeferredWindowsUpdates -Servername $Servername -SucheOnline $SucheOnline -AuthInfo $svcCredential -DeferredCategories $deferredCategories -DeferredKBs $deferredKBs -ManagementComputerFQDN $ComputerFQDN -WriteLog { param($message, $logOnly) if ($logOnly) { Write-ScriptLog $message -LogOnly } else { Write-ScriptLog $message } }
          if ($deferredCheck.Success -and @($deferredCheck.Updates).Count -gt 0) {
            Write-ScriptLog "Zurückgestellte Updates auf $Servername verfügbar: $(@($deferredCheck.Updates).Count)."
            $isVirtualForDeferred = Test-ServerIsVirtual -Servername $Servername -ComputerFQDN $ComputerFQDN -AuthInfo $svcCredential -WriteLog { param($message) Write-ScriptLog $message }
            $deferredMaintenanceTime = if ($isVirtualForDeferred) { $vmRebootStartTime } else { $physicalRebootTime }
            $deferredMaintenanceEndTime = if ($isVirtualForDeferred) { [string]$UpdateSettings.VMRebootWindowEndTime } else { [string]$UpdateSettings.PhysicalRebootWindowEndTime }
            $deferredScheduledAt = if (-not [string]::IsNullOrWhiteSpace($deferredMaintenanceTime)) { Get-NextScheduledTime $deferredMaintenanceTime } else { [datetime]::MinValue }
            if ($deferredScheduledAt -gt [datetime]::MinValue) {
              Write-ScriptLog "Nachinstallation auf $Servername für das Wartungsfenster $($deferredScheduledAt.ToString('dd.MM.yyyy HH:mm')) geplant ($([string]$(if ($isVirtualForDeferred) { 'VM' } else { 'physisch' })))."
            } else {
              Write-ScriptLog "WARNUNG: Für $Servername ist kein Wartungszeitpunkt konfiguriert; Nachinstallation wartet auf den nächsten Neustart."
            }
            $DeferredUpdatesPlanned += @($deferredCheck.Updates).Count
            Register-DeferredUpdateTask `
              -Servername          $Servername `
              -DeferredCategories  $deferredCategories `
              -DeferredKBs         $deferredKBs `
              -SucheOnline         $SucheOnline `
              -RebootRequired      $rebootRequired `
              -AuthInfo            $svcCredential `
              -ScheduledAt         $deferredScheduledAt `
              -MaintenanceEndTime  $deferredMaintenanceEndTime `
              -MailSettings        $MailSettings `
              -WriteLog            { param($message, $logOnly) if ($logOnly) { Write-ScriptLog $message -LogOnly } else { Write-ScriptLog $message } }

            # Der Report nennt den Aktivierungszeitpunkt und die automatische
            # Bereitschaftsprüfung nach einem Neustart direkt beim Zielserver.
            $deferredSelection = @(
              if ($deferredKBs.Count -gt 0) { "KBs: $($deferredKBs -join ', ')" }
              if ($deferredCategories.Count -gt 0) { "Kategorien: $($deferredCategories -join ', ')" }
            ) -join '; '
            $deferredSelectionHtml = [System.Net.WebUtility]::HtmlEncode($deferredSelection)
            # Wie in den übrigen Update-Berichten die konkreten Felder tabellarisch anzeigen.
            $deferredUpdatesHtml = "<br><strong>Für die Nachinstallation vorgesehene Updates:</strong><table><tr><th>ComputerName</th><th>Status</th><th>KB</th><th>Size</th><th>Title</th></tr>"
            foreach ($deferredUpdate in @($deferredCheck.Updates)) {
              $deferredUpdatesHtml += '<tr>'
              foreach ($fieldName in @('ComputerName', 'Status', 'KB', 'Size', 'Title')) {
                $property = $deferredUpdate.PSObject.Properties[$fieldName]
                $fieldValue = if ($property) { [string]$property.Value } else { '' }
                $deferredUpdatesHtml += '<td>' + [System.Net.WebUtility]::HtmlEncode($fieldValue) + '</td>'
              }
              $deferredUpdatesHtml += '</tr>'
            }
            $deferredUpdatesHtml += '</table>'
            $deferredReadinessText = 'Nach einem Neustart startet die Installation, sobald Windows Update antwortet und das Wartungsfenster offen ist.'
            if ($deferredScheduledAt -gt [datetime]::MinValue) {
              $deferredPlanText = "Nachinstallation eingeplant: ab Wartungsfenster $($deferredScheduledAt.ToString('dd.MM.yyyy HH:mm')) ($([string]$(if ($isVirtualForDeferred) { 'VM' } else { 'physisch' }))). $deferredReadinessText"
            } else {
              $deferredPlanText = "Nachinstallation eingeplant: beim nächsten Neustart. $deferredReadinessText"
            }
            $deferredPlanHtml = [System.Net.WebUtility]::HtmlEncode($deferredPlanText)
            $RepBody += "<div class='warning-box'><strong>$deferredPlanHtml</strong><br>Zurückgestellt: $deferredSelectionHtml$deferredUpdatesHtml</div>"
          }
          elseif ($deferredCheck.Success) {
            Remove-DeferredUpdateTask -Servername $Servername -AuthInfo $svcCredential -WriteLog { param($message, $logOnly) if ($logOnly) { Write-ScriptLog $message -LogOnly } else { Write-ScriptLog $message } }
          }
          else {
            Write-ScriptLog "WARNUNG: Nachinstallationsaufgabe auf $Servername wird wegen fehlgeschlagener Update-Prüfung nicht verändert."
            $deferredErrorHtml = [System.Net.WebUtility]::HtmlEncode([string]$deferredCheck.Error)
            $RepBody += "<div class='warning-box'><strong>Nachinstallationsprüfung auf $([System.Net.WebUtility]::HtmlEncode([string]$Servername)) fehlgeschlagen.</strong><br>$deferredErrorHtml</div>"
          }
        }
        else {
          # Auch wenn die Nachinstallation global ausgeschaltet wurde oder
          # keine Auswahl mehr konfiguriert ist, darf ein alter Task nicht
          # später noch einen sinnlosen Neustart auslösen.
          Remove-DeferredUpdateTask -Servername $Servername -AuthInfo $svcCredential -WriteLog { param($message, $logOnly) if ($logOnly) { Write-ScriptLog $message -LogOnly } else { Write-ScriptLog $message } }
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
            Write-ScriptLog "Keine Windows-Updates installiert auf ${Servername}."
            $RepBody += "<div class='no-updates'>Keine Updates installiert.</div>"
          }
        } else {
          Write-ScriptLog "Keine Windows-Updates installiert auf ${Servername}."
          $RepBody += "<div class='no-updates'>Keine Updates installiert.</div>"
        }
      }
      Catch {
        Write-ScriptLog ("Es ist ein Fehler bei Server " + $Servername + " aufgetreten!")
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Server-Update-Install' -Target $Servername -ErrorRecord $_
        $RepBody += "<div class='warning-box'><strong>Fehler aufgetreten!</strong><br>Details stehen im Laufprotokoll.</div>"
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
  catch {
    Write-ScriptLog "WARNUNG: Physischer Linux-Neustart auf $($pendingLinuxReboot.Host) konnte nicht eingeplant werden; Details im Log."
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Linux-Neustart planen' -Target ([string]$pendingLinuxReboot.Host) -ErrorRecord $_
  }
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
  catch {
    Write-ScriptLog "WARNUNG: Physischer Home-Assistant-Neustart auf $($pendingHAReboot.Host) konnte nicht eingeplant werden; Details im Log."
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-ScriptLog $message -LogOnly } -Operation 'Home-Assistant-Neustart planen' -Target ([string]$pendingHAReboot.Host) -ErrorRecord $_
  }
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
    $packageServerHtml = [System.Net.WebUtility]::HtmlEncode([string]$packageInfo.Server)
    $packageManagerHtml = [System.Net.WebUtility]::HtmlEncode([string]$packageInfo.Manager)
    $RepBody += "<div class='server-title'>Server: $packageServerHtml – $packageManagerHtml</div>"
    $packageLabel = if ($packageInfo.Success) { 'Aktualisierte Pakete' } else { 'Gefundene Pakete (nicht vollständig aktualisiert)' }
    $RepBody += "<div class='linux-package-list'><strong>${packageLabel} ($(@($packageInfo.Packages).Count)):</strong>"
    $RepBody += ConvertTo-WindowsUpdatePackageHtmlTable -ComputerName $packageInfo.Server -Manager $packageInfo.Manager -Packages $packageInfo.Packages
    $RepBody += '</div>'
  }
}

# Linux-Updates in Report einfügen
if ($LinuxScriptExecuted) {
  $RepBody += "<div class='section-title'>🐧 Linux-Server Updates</div>"
  
  if ($LinuxUpdateDetails -and @($LinuxUpdateDetails).Count -gt 0) {
    foreach ($hostInfo in $LinuxUpdateDetails) {
      $RepBody += "<div class='server-title'>Server: $($hostInfo.Host)</div>"
      if ($hostInfo.Status -eq 'Updates installiert; Neustartplanung fehlgeschlagen') {
        $RepBody += "<div class='warning-box'><strong>Neustart erforderlich:</strong> Die Neustartplanung ist fehlgeschlagen. Bitte den Server manuell neu starten; Details stehen im Laufprotokoll.</div>"
      }
      
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

      if ($hostInfo.Status -eq 'Übersprungen') {
        $skipDetailsHtml = [System.Net.WebUtility]::HtmlEncode([string]$hostInfo.Details)
        $RepBody += "<div class='info-box'><p><strong>Status:</strong> Übersprungen</p><p>$skipDetailsHtml</p></div>"
      } elseif ($hostInfo.UpdateCount -gt 0 -or $hostInfo.Status -eq "Erfolgreich") {
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

# Linux- und Home-Assistant-Updates wie Windows-/Paketupdates auch vor der
# Gesamtsumme je Ziel mit Namen und Versionen ausgeben.
foreach ($hostInfo in @($LinuxUpdateDetails)) {
  if ($hostInfo.Status -eq 'Fehler') {
    Write-ScriptLog "WARNUNG: Linux auf $($hostInfo.Host) fehlgeschlagen; Details im Log."
    continue
  }
  if ($hostInfo.Status -eq 'Updates installiert; Neustartplanung fehlgeschlagen') {
    Write-ScriptLog "WARNUNG: Linux-Updates auf $($hostInfo.Host) wurden installiert; Neustartplanung fehlgeschlagen. Manuelles Eingreifen erforderlich."
  }
  if ([int]$hostInfo.UpdateCount -le 0) { continue }
  Write-ScriptLog "Linux auf $($hostInfo.Host): $($hostInfo.UpdateCount) Paketupdates installiert."
  $packageList = if ($hostInfo.PSObject.Properties['PackageList']) { @($hostInfo.PackageList) } else { @(([string]$hostInfo.Packages -split ',\s*') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }) }
  foreach ($package in $packageList) { Write-ScriptLog "  $($hostInfo.Host): $package" }
  Write-ScriptLog ''
}
foreach ($hostInfo in @($HAUpdateDetails)) {
  if ($hostInfo.Status -eq 'Fehler') {
    Write-ScriptLog "WARNUNG: Home Assistant auf $($hostInfo.Host) fehlgeschlagen; Details im Log."
    continue
  }
  if ([int]$hostInfo.UpdateCount -le 0) { continue }
  Write-ScriptLog "Home Assistant auf $($hostInfo.Host): $($hostInfo.UpdateCount) Update(s) installiert."
  foreach ($detail in ([string]$hostInfo.Details -split '<br>' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) -and $_ -ne 'Keine Updates' })) {
    Write-ScriptLog "  $detail"
  }
  Write-ScriptLog ''
}

if (@($ManualActions).Count -gt 0) {
  $RepBody += "<div class='warning-box'><h2>Manuelle Prüfung/Aktion erforderlich</h2><ul>"
  foreach ($manualAction in @($ManualActions)) {
    $manualServerHtml = [System.Net.WebUtility]::HtmlEncode([string]$manualAction.Server)
    $manualManagerHtml = [System.Net.WebUtility]::HtmlEncode([string]$manualAction.Manager)
    $manualPackages = ''
    $manualPackageRows = @($manualAction.Packages)
    if ($manualAction.Manager -in @('Winget', 'Chocolatey') -and $manualPackageRows.Count -gt 0) {
      $manualPackages = ConvertTo-WindowsUpdatePackageHtmlTable -ComputerName $manualAction.Server -Manager $manualAction.Manager -Packages $manualPackageRows
    }
    $manualTextHtml = [System.Net.WebUtility]::HtmlEncode([string]$manualAction.Text) -replace "`r?`n", '<br>'
    $RepBody += "<li><strong>$manualServerHtml ($manualManagerHtml)</strong>"
    if ($manualPackages) { $RepBody += $manualPackages }
    $RepBody += "<br>$manualTextHtml</li>"
  }
  $RepBody += "</ul></div>"
}

if ($TotalUpdatesInstalled -eq 0 -and $DeferredUpdatesPlanned -gt 0) {
  $RepBody += @"
<div class="summary warning">
    <p><strong>✅ Im Hauptlauf wurden keine Updates installiert.</strong></p>
    <p>$DeferredUpdatesPlanned zurückgestellte Update(s) sind zur Nachinstallation eingeplant.</p>
</div>
"@
} elseif ($TotalUpdatesInstalled -eq 0 -and ($HASkippedHosts -gt 0 -or $WindowsUnreachableHosts -gt 0)) {
  $skippedDetails = @()
  if ($HASkippedHosts -gt 0) { $skippedDetails += "$HASkippedHosts Home-Assistant-Instanz(en) wegen nicht erreichbarem SSH" }
  if ($WindowsUnreachableHosts -gt 0) { $skippedDetails += "$WindowsUnreachableHosts Windows-Ziel(e) wegen nicht erreichbarem WinRM" }
  $RepBody += @"
<div class="summary warning">
    <p><strong>Es wurden keine Updates installiert.</strong></p>
    <p>Übersprungen: $($skippedDetails -join '; '). Diese Systeme wurden nicht auf Updates geprüft.</p>
</div>
"@
} elseif ($TotalUpdatesInstalled -eq 0) {
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
"@

if ($WindowsAdCount -gt 0) { $RepBody += "        <li>Windows-Server (AD): $WindowsAdCount</li>`n" }
if ($WindowsNonAdCount -gt 0) { $RepBody += "        <li>Windows-Server (Nicht-AD): $WindowsNonAdCount</li>`n" }
if ($WindowsUnreachableHosts -gt 0) { $RepBody += "        <li>Windows-Ziele nicht erreichbar/übersprungen: $WindowsUnreachableHosts</li>`n" }

if ($LinuxServerCount -gt 0) {
  $RepBody += "        <li>Linux-Server: $LinuxServerCount</li>`n"
}

if ($HAServerCount -gt 0) {
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
$RepBody += "        <li>Für die Nachinstallation eingeplant: $DeferredUpdatesPlanned</li>`n"
if ($LinuxScriptExecuted) {
  $RepBody += "        <li>Linux-Updates: $LinuxUpdatesInstalled</li>`n"
  if ($LinuxRebootScheduleFailures -gt 0) { $RepBody += "        <li>Linux-Neustartplanung offen: $LinuxRebootScheduleFailures</li>`n" }
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
  "Gesamtanzahl Server: $TotalServerCount"
)
if ($WindowsAdCount -gt 0) { $summaryLines += "  • Windows-Server (AD): $WindowsAdCount" }
if ($WindowsNonAdCount -gt 0) { $summaryLines += "  • Windows-Server (Nicht-AD): $WindowsNonAdCount" }
if ($LinuxServerCount -gt 0) { $summaryLines += "  • Linux-Server: $LinuxServerCount" }
if ($HAServerCount -gt 0) { $summaryLines += "  • Home Assistant: $HAServerCount" }
$summaryLines += @('', "Updates installiert: $TotalUpdatesInstalled", "  • Windows: $UpdCount")
if ($PackageUpdateCount -gt 0) { $summaryLines += "  • Anwendungen: $PackageUpdateCount (Winget: $WingetUpdateCount, Chocolatey: $ChocolateyUpdateCount)" }
if ($LinuxScriptExecuted) { $summaryLines += "  • Linux: $LinuxUpdatesInstalled" }
if ($HAScriptExecuted) { $summaryLines += "  • Home Assistant: $HAUpdatesInstalled" }
if ($HASkippedHosts -gt 0) { $summaryLines += "  • Home Assistant übersprungen: $HASkippedHosts (SSH nicht erreichbar; nicht auf Updates geprüft)" }
if ($WindowsUnreachableHosts -gt 0) { $summaryLines += "  • Windows übersprungen: $WindowsUnreachableHosts (WinRM-Ports 5985/5986 nicht erreichbar; nicht auf Updates geprüft)" }
$summaryLines += @('', "Fehler: $TotalUpdatesFailed", "  • Windows: $ErrorCount")
if (@($ManualActions).Count -gt 0) { $summaryLines += "Manuelle Prüfung/Aktion erforderlich: $(@($ManualActions).Count)" }
if ($LinuxScriptExecuted) { $summaryLines += "  • Linux: $LinuxUpdatesFailed" }
if ($LinuxRebootScheduleFailures -gt 0) { $summaryLines += "  • Linux-Neustartplanung offen: $LinuxRebootScheduleFailures" }
if ($HAScriptExecuted) { $summaryLines += "  • Home Assistant: $HAUpdatesFailed" }
$summaryLines += @('', "Dauer: $ScriptDuration Minuten")
foreach ($manualAction in @($ManualActions)) {
  $manualPackages = @($manualAction.Packages | ForEach-Object {
    if ($null -eq $_) { continue }
    $packageName = ''
    if ($_ -is [string]) {
      $manualRowMatch = [regex]::Match(
        [string]$_,
        '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<InstalledVersion>\S+)\s+(?<AvailableVersion>\S+)\s+(?<Source>[^\s]+)\s*$',
        [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
      )
      $packageName = if ($manualRowMatch.Success) { $manualRowMatch.Groups['Name'].Value.Trim() } else { ([string]$_).Trim() }
    } else {
      $nameProperty = $_.PSObject.Properties['Name']
      $idProperty = $_.PSObject.Properties['Id']
      if ($nameProperty) { $packageName = [string]$nameProperty.Value }
      if ([string]::IsNullOrWhiteSpace($packageName) -and $idProperty) { $packageName = [string]$idProperty.Value }
    }
    if (-not [string]::IsNullOrWhiteSpace($packageName)) { $packageName }
  } | Select-Object -Unique)
  $packageLabel = if ($manualPackages.Count -gt 0) { $manualPackages -join ', ' } else { 'Paket nicht eindeutig ermittelt' }
  $reasonLines = @([string]$manualAction.Text -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object {
    $_ -match '(?i)(hash|fehlgeschlagen|abgebrochen|abbruch|verwendet|zugriff verweigert|nicht unterstützt|nicht gefunden|error|failed|canceled|cancelled)'
  } | Select-Object -Unique | Select-Object -First 2)
  $reason = if ($reasonLines.Count -gt 0) { $reasonLines -join ' ' } else { 'Update bitte manuell prüfen; Details stehen in der Warnung bzw. im Laufprotokoll.' }
  $summaryLines += "  • $($manualAction.Server) / $($manualAction.Manager) / $packageLabel — $reason"
}
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
