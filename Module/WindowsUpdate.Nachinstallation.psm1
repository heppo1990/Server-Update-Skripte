# WindowsUpdate.Nachinstallation.psm1
# Eigenständige Nachinstallations- und Taskrunnerlogik. Änderungen am Hauptlauf
# sollen diesen Worker und seine Taskregistrierung nicht unbeabsichtigt verändern.

function Write-DeferredModuleLog {
  param([scriptblock]$WriteLog, [string]$Message, [switch]$LogOnly)
  if ($WriteLog) { & $WriteLog $Message ([bool]$LogOnly) }
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
    [string[]]$DeferredKBs = @(),
    [string]$ManagementComputerFQDN = '',
    [scriptblock]$WriteLog
  )

  try {
    $isLocal = $Servername -ieq $env:COMPUTERNAME -or $Servername -ieq $ManagementComputerFQDN
    $query = {
      param($Online, $Categories, $KBs)
      $wuParams = @{ AcceptAll = $true; IgnoreReboot = $true }
      if ($Online) { $wuParams.MicrosoftUpdate = $true }
      $updates = @()
      foreach ($kb in @($KBs)) { $updates += @(Get-WindowsUpdate @wuParams -KBArticleID $kb) }
      foreach ($category in @($Categories)) { $updates += @(Get-WindowsUpdate @wuParams -Category $category) }
      # Eigenschaften vor dem Remoting vereinheitlichen: JEA und PS-Remoting
      # liefern je nach PSWindowsUpdate-Version unterschiedlich serialisierte
      # Objekte. Ohne diese Normalisierung gehen KB und Titel im Bericht verloren.
      $unresolvedUpdateCount = 0
      $unresolvedDiagnostics = @()
      $pendingUpdates = [System.Collections.Generic.Queue[object]]::new()
      foreach ($update in $updates) { if ($null -ne $update) { $pendingUpdates.Enqueue($update) } }
      while ($pendingUpdates.Count -gt 0) {
        $update = $pendingUpdates.Dequeue()
        if ($null -eq $update) { continue }
        # Einige PSWindowsUpdate-Versionen liefern je Kategorie eine
        # Collection<PSObject> als einzelnes Remoting-Ergebnis. Diese Collection
        # muss vor der Metadatenprüfung indexweise entpackt werden; andernfalls
        # erscheint sie selbst fälschlich als Update ohne KB und Titel.
        if ($update -is [System.Collections.IList] -and $update -isnot [string]) {
          for ($updateIndex = 0; $updateIndex -lt $update.Count; $updateIndex++) {
            if ($null -ne $update[$updateIndex]) { $pendingUpdates.Enqueue($update[$updateIndex]) }
          }
          continue
        }
        $kbValue = ''
        foreach ($propertyName in @('KB', 'KBArticleID', 'KBArticleIDs')) {
          $property = $update.PSObject.Properties[$propertyName]
          if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $kbValue = if ($property.Value -is [array]) { @($property.Value) -join ', ' } else { [string]$property.Value }
            break
          }
        }
        if ($kbValue) {
          $kbValue = (@(($kbValue -split ',\s*') | ForEach-Object { $articleId = $_.Trim(); if ($articleId -match '^KB') { $articleId } else { "KB$articleId" } }) -join ', ')
        }
        $titleValue = ''
        foreach ($propertyName in @('Title', 'UpdateTitle', 'Name', 'Description')) {
          $property = $update.PSObject.Properties[$propertyName]
          if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) {
            $titleValue = [string]$property.Value
            break
          }
        }
        $sizeValue = ''
        foreach ($propertyName in @('Size', 'MaxDownloadSize')) {
          $property = $update.PSObject.Properties[$propertyName]
          if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $sizeValue = [string]$property.Value; break }
        }
        $statusValue = ''
        foreach ($propertyName in @('Status', 'Result', 'UpdateStatus')) {
          $property = $update.PSObject.Properties[$propertyName]
          if ($property -and $null -ne $property.Value -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { $statusValue = [string]$property.Value; break }
        }
        if ([string]::IsNullOrWhiteSpace($kbValue) -and [string]::IsNullOrWhiteSpace($titleValue) -and [string]::IsNullOrWhiteSpace($sizeValue)) {
          if ($update -is [System.Collections.IEnumerable] -and $update -isnot [string]) {
            $nestedCount = 0
            foreach ($nestedUpdate in $update) { if ($null -ne $nestedUpdate) { $pendingUpdates.Enqueue($nestedUpdate); $nestedCount++ } }
            if ($nestedCount -gt 0) { continue }
          }
          $propertyNames = @($update.PSObject.Properties | ForEach-Object { $_.Name }) -join ', '
          $typeName = if ($null -ne $update -and $update.GetType()) { $update.GetType().FullName } else { '<unbekannt>' }
          $unresolvedDiagnostics += "Typ=$typeName; Eigenschaften=[$propertyNames]"
          $unresolvedUpdateCount++
          continue
        }
        $computerValue = foreach ($propertyName in @('ComputerName', 'PSComputerName')) {
          $property = $update.PSObject.Properties[$propertyName]
          if ($property -and -not [string]::IsNullOrWhiteSpace([string]$property.Value)) { [string]$property.Value; break }
        }
        if ([string]::IsNullOrWhiteSpace([string]$computerValue)) { $computerValue = $env:COMPUTERNAME }
        [PSCustomObject]@{ ComputerName = $computerValue; Status = $statusValue; KB = $kbValue; Size = $sizeValue; Title = $titleValue }
      }
      if ($unresolvedUpdateCount -gt 0) {
        [PSCustomObject]@{
          MetadataMissing = $true
          UnresolvedCount = $unresolvedUpdateCount
          # Sort-Object ist im eingeschränkten JEA-Endpunkt nicht zwingend
          # verfügbar. Für Diagnosewerte ist die ursprüngliche Reihenfolge
          # ausreichend; daher direkt zusammenfügen.
          Diagnostic = (@($unresolvedDiagnostics) -join ' | ')
        }
      }
    }

    if ($isLocal) {
      $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message }
      if (-not $jeaSupported) { throw "WindowsUpdateAdm/JEA ist auf dem Verwaltungsserver $Servername nicht verfügbar; zurückgestellte Updates können nicht sicher lokal geprüft werden." }
      $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -ConfigurationName 'WindowsUpdateAdm'
      $params.ScriptBlock = $query
      $params.ArgumentList = @($SucheOnline, $DeferredCategories, $DeferredKBs)
      $updates = @(Invoke-WindowsUpdateWithRetry -OperationName "JEA-Prüfung zurückgestellter Updates auf $Servername" -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message } -ScriptBlock { Invoke-Command @params })
    } else {
      $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message }
      if (-not $jeaSupported -and $AuthInfo) {
        Write-DeferredModuleLog -WriteLog $WriteLog -Message "Prüfe zurückgestellte Updates als SYSTEM-Aufgabe auf $Servername..."
        $updates = @(Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode Check -SearchOnline $SucheOnline -DeferredCategories $DeferredCategories -DeferredKBs $DeferredKBs -DeferredOnly $true -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message })
      }
      else {
        $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo -ConfigurationName $(if ($jeaSupported) { 'WindowsUpdateAdm' } else { $null })
        $params.ScriptBlock = $query
        $params.ArgumentList = @($SucheOnline, $DeferredCategories, $DeferredKBs)
        $updates = @(Invoke-WindowsUpdateWithRetry -OperationName "Prüfung zurückgestellter Updates auf $Servername" -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message } -ScriptBlock { Invoke-Command @params })
      }
    }
    # Normale Updateobjekte besitzen MetadataMissing nicht. Unter StrictMode
    # darf die optionale Eigenschaft deshalb nur über PSObject.Properties gelesen werden.
    $unresolved = @($updates | Where-Object {
      if ($null -eq $_) { return $false }
      $metadataProperty = $_.PSObject.Properties['MetadataMissing']
      return ($metadataProperty -and [bool]$metadataProperty.Value)
    })
    $validUpdates = @($updates | Where-Object {
      if ($null -eq $_) { return $false }
      $metadataProperty = $_.PSObject.Properties['MetadataMissing']
      $metadataMissing = $metadataProperty -and [bool]$metadataProperty.Value
      return (-not $metadataMissing -and ($_.KB -or $_.Title -or $_.Size))
    } | Sort-Object KB, Title -Unique)
    if ($unresolved.Count -gt 0) {
      $missingCount = [int](@($unresolved | Measure-Object -Property UnresolvedCount -Sum).Sum)
      $errorMessage = "$missingCount Update-Ergebnis(se) ließen sich nicht in KB/Titel/Größe auflösen."
      $diagnosticMessages = @($unresolved | ForEach-Object {
        $diagnosticProperty = $_.PSObject.Properties['Diagnostic']
        if ($diagnosticProperty -and -not [string]::IsNullOrWhiteSpace([string]$diagnosticProperty.Value)) { [string]$diagnosticProperty.Value }
      } | Sort-Object -Unique)
      if ($diagnosticMessages.Count -gt 0) { $errorMessage += " Rückgabe: $($diagnosticMessages -join ' | ')." }
      Write-DeferredModuleLog -WriteLog $WriteLog -Message "WARNUNG: $errorMessage"
      return [PSCustomObject]@{ Success = $false; Updates = $validUpdates; Error = $errorMessage }
    }
    return [PSCustomObject]@{ Success = $true; Updates = $validUpdates; Error = '' }
  }
  catch {
    Write-DeferredModuleLog -WriteLog $WriteLog -Message "WARNUNG: Zurückgestellte Updates auf $Servername konnten nicht geprüft werden; Details im Log."
    Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message -LogOnly } -Operation 'DeferredUpdates-Check' -Target $Servername -ErrorRecord $_
    return [PSCustomObject]@{ Success = $false; Updates = @(); Error = $_.Exception.Message }
  }
}

function Remove-DeferredUpdateTask {
  param([Parameter(Mandatory)][string]$Servername, $AuthInfo = $null, [scriptblock]$WriteLog)
  $taskName = 'WindowsUpdateAdm-DeferredUpdates'
  $removeTask = {
    param($Name)
    $workerPath = Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm') 'DeferredUpdates.ps1'
    $runnerPath = Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm') 'DeferredUpdates-TaskRunner.cmd'
    $scheduledTaskRemovalAvailable = (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) -and
      (Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue)
    if ($scheduledTaskRemovalAvailable) {
      if (Get-ScheduledTask -TaskName $Name -ErrorAction SilentlyContinue) {
        Unregister-ScheduledTask -TaskName $Name -Confirm:$false -ErrorAction Stop
        $removed = $true
      } else { $removed = $false }
    } else {
      # Windows 7 ohne ScheduledTasks-Modul: beide legacy Trigger mit schtasks entfernen.
      $schtasks = Join-Path $env:WINDIR 'System32\schtasks.exe'
      $removed = $false
      foreach ($candidateName in @($Name, ($Name + '-AtStartup'))) {
        & $schtasks /Query /TN $candidateName *> $null
        if ($LASTEXITCODE -eq 0) {
          & $schtasks /Delete /TN $candidateName /F *> $null
          if ($LASTEXITCODE -eq 0) { $removed = $true }
        }
      }
    }
    Remove-Item -LiteralPath $workerPath -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $runnerPath -Force -ErrorAction SilentlyContinue
    return $removed
  }
  $jeaSupported = Test-WindowsUpdateJeaSupported -TargetComputer $Servername -AuthInfo $AuthInfo -IsNonAdTarget ([bool]$AuthInfo) -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message }
  if (-not $jeaSupported -and $AuthInfo) {
    # Auf Nicht-AD Server 2016 löscht SYSTEM die alte Aufgabe zuverlässig,
    # auch wenn der gemappte Zertifikat-Administrator dafür kein Recht hat.
    $result = @(Invoke-WindowsUpdateSystemTask -TargetComputer $Servername -AuthInfo $AuthInfo -Mode RemoveDeferredTask -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message })
    $removed = [bool]($result | Select-Object -First 1 -ExpandProperty Removed)
  } else {
    $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
    $params.ScriptBlock = $removeTask; $params.ArgumentList = $taskName
    $removed = [bool](Invoke-WindowsUpdateWithRetry -OperationName "Entfernen der Nachinstallationsaufgabe auf $Servername" -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message } -ScriptBlock { Invoke-Command @params })
  }
  if ($removed) { Write-DeferredModuleLog -WriteLog $WriteLog -Message "Keine zurückgestellten Updates auf ${Servername}: vorhandene Nachinstallationsaufgabe wurde gelöscht." }
  else { Write-DeferredModuleLog -WriteLog $WriteLog -Message "Keine zurückgestellten Updates auf ${Servername}: keine Nachinstallationsaufgabe vorhanden." }
}

function Register-OneTimeRemoteTask {
  param(
    [Parameter(Mandatory)][string]$Servername,
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][datetime]$At,
    [Parameter(Mandatory)][string]$Script,
    $AuthInfo = $null,
    [AllowEmptyString()][string]$MailPassword = '',
    [scriptblock]$WriteLog
  )
  $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($Script))
  $sb = {
    param($Name, $RunAt, $Encoded, $Password)
    if (-not [string]::IsNullOrEmpty($Password)) {
      if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
      }
      $passwordBytes = [Text.Encoding]::UTF8.GetBytes($Password)
      try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect($passwordBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $protectedPassword = [Convert]::ToBase64String($protectedBytes)
      }
      finally { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
    } else { $protectedPassword = '' }
    $Encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(
      [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Encoded)).Replace('__WINDOWSUPDATEADM_DPAPI_MAILPASS__', $protectedPassword)))
    $scheduledTaskCmdletsAvailable = (Get-Command -Name New-ScheduledTaskAction -ErrorAction SilentlyContinue) -and
      (Get-Command -Name New-ScheduledTaskTrigger -ErrorAction SilentlyContinue) -and
      (Get-Command -Name New-ScheduledTaskPrincipal -ErrorAction SilentlyContinue) -and
      (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)
    if ($scheduledTaskCmdletsAvailable) {
      $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $Encoded"
      $trigger = New-ScheduledTaskTrigger -Once -At $RunAt
      $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
      Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
    } else {
      # Einmalige SYSTEM-Aufgabe auf Windows 7 über den eingebauten Task-Scheduler-CLI anlegen.
      $schtasks = Join-Path $env:WINDIR 'System32\schtasks.exe'
      $startDate = $RunAt.ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
      $startTime = $RunAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
      $taskCommand = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand {0}' -f $Encoded
      $createOutput = & $schtasks /Create /TN $Name /SC ONCE /SD $startDate /ST $startTime /RU SYSTEM /RL HIGHEST /TR $taskCommand /F 2>&1
      if ($LASTEXITCODE -ne 0) { throw "SYSTEM-Aufgabe konnte mit schtasks.exe nicht erstellt werden: $((@($createOutput) -join ' ').Trim())" }
    }
  }
  # Keine Erweiterung der JEA-Rechte: Aufgaben werden über die normale WinRM-Verbindung
  # des ohnehin administrativen Aufrufers angelegt.
  $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
  $params.ScriptBlock = $sb; $params.ArgumentList = @($TaskName, $At, $encoded, $MailPassword)
  Invoke-WindowsUpdateWithRetry -OperationName "Remote-Aufgabe '$TaskName' auf $Servername" -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message } -ScriptBlock { Invoke-Command @params | Out-Null }
}

function Register-StartupRemoteTask {
  param(
    [Parameter(Mandatory)][string]$Servername,
    [Parameter(Mandatory)][string]$TaskName,
    [Parameter(Mandatory)][string]$Script,
    $AuthInfo = $null,
    [datetime]$At = [datetime]::MinValue,
    [AllowEmptyString()][string]$MailPassword = '',
    [AllowEmptyString()][string]$MaintenanceEndTime = '',
    [datetime]$ExpiresAt = [datetime]::MinValue,
    [scriptblock]$WriteLog
  )
  # Der Worker wird von powershell.exe (Windows PowerShell 5.1) ausgeführt;
  # seine Syntax muss daher auch mit dem Windows-PowerShell-Parser gültig sein.
  # Der vollständige Worker wird geschützt als temporäre Datei abgelegt. Ein
  # CMD-Starthelfer protokolliert Prozessstart und Fehler vor PowerShell.
  $sb = {
    param($Name, $WorkerScript, $Password, $RunAt, $WindowEndTime, $TaskExpiresAt)
    if (-not [string]::IsNullOrEmpty($Password)) {
      if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
      }
      $passwordBytes = [Text.Encoding]::UTF8.GetBytes($Password)
      try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect($passwordBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        $protectedPassword = [Convert]::ToBase64String($protectedBytes)
      }
      finally { [Array]::Clear($passwordBytes, 0, $passwordBytes.Length) }
    } else { $protectedPassword = '' }
    $WorkerScript = $WorkerScript.Replace('__WINDOWSUPDATEADM_DPAPI_MAILPASS__', $protectedPassword)
    $WorkerPath = Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm') 'DeferredUpdates.ps1'
    $RunnerPath = Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-TaskRunner.cmd'
    New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerPath) -Force | Out-Null
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-LastFailureNotice.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-FinalNotificationSent.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-Results.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-RebootPending.txt') -Force -ErrorAction SilentlyContinue
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
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  FEHLER im Task-Starthelfer: `$(`$_ | Out-String)" | Add-Content -LiteralPath `$taskLogPath -Encoding UTF8
  exit 1
}
"@
    $RunnerLogPath = Join-Path (Split-Path -Parent $WorkerPath) 'DeferredUpdates-TaskRunner.log'
    $runnerSource = @"
@echo off
echo [%date% %time%] Taskrunner gestartet.>>"$RunnerLogPath"
if not exist "$WorkerPath" (
  echo [%date% %time%] FEHLER: Workerdatei "$WorkerPath" fehlt; Nachinstallationsaufgabe muss neu eingerichtet werden.>>"$RunnerLogPath"
  exit /b 1
)
"%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$WorkerPath" >>"$RunnerLogPath" 2>&1
set "WORKER_EXIT=%ERRORLEVEL%"
echo [%date% %time%] PowerShell-Worker beendet; Exitcode %WORKER_EXIT%.>>"$RunnerLogPath"
if "%WORKER_EXIT%"=="2" exit /b 0
if "%WORKER_EXIT%"=="1" exit /b 1
del "%~f0" >nul 2>&1
exit /b %WORKER_EXIT%
"@
    [System.IO.File]::WriteAllText($RunnerPath, $runnerSource, [System.Text.Encoding]::ASCII)
    Set-Acl -LiteralPath $RunnerPath -AclObject $acl -ErrorAction Stop
    # Wiederholungen liegen im konfigurierten Wartungsfenster; der Worker prüft
    # vor jeder Installation zusätzlich, ob das Fenster tatsächlich offen ist.
    $repeatDuration = New-TimeSpan -Minutes (23 * 60 + 59)
    if ($RunAt -gt [datetime]::MinValue -and -not [string]::IsNullOrWhiteSpace($WindowEndTime)) {
      $parsedWindowEnd = [datetime]::MinValue
      if (-not [datetime]::TryParse($WindowEndTime, [ref]$parsedWindowEnd)) { throw "Ungültiges Wartungsfenster-Ende: $WindowEndTime" }
      $repeatDuration = $parsedWindowEnd.TimeOfDay - $RunAt.TimeOfDay
      if ($repeatDuration -le [TimeSpan]::Zero) { $repeatDuration = $repeatDuration.Add([TimeSpan]::FromDays(1)) }
    }
    $expiryTriggerAt = $TaskExpiresAt
    if ($TaskExpiresAt -gt [datetime]::MinValue -and
        $RunAt -gt [datetime]::MinValue -and
        -not [string]::IsNullOrWhiteSpace($WindowEndTime)) {
      $parsedWindowEnd = [datetime]::MinValue
      if (-not [datetime]::TryParse($WindowEndTime, [ref]$parsedWindowEnd)) { throw "Ungültiges Wartungsfenster-Ende: $WindowEndTime" }
      $windowStartTime = $RunAt.TimeOfDay
      $windowEndTimeOfDay = $parsedWindowEnd.TimeOfDay
      $windowStart = $TaskExpiresAt.Date.Add($windowStartTime)
      if ($TaskExpiresAt -lt $windowStart) { $windowStart = $windowStart.AddDays(-1) }
      $windowEnd = $windowStart.Date.Add($windowEndTimeOfDay)
      if ($windowEnd -le $windowStart) { $windowEnd = $windowEnd.AddDays(1) }
      $expiryIsInsideWindow = $TaskExpiresAt -ge $windowStart -and $TaskExpiresAt -lt $windowEnd
      if (-not $expiryIsInsideWindow) {
        $expiryTriggerAt = $TaskExpiresAt.Date.Add($windowStartTime)
        if ($TaskExpiresAt -ge $expiryTriggerAt) { $expiryTriggerAt = $expiryTriggerAt.AddDays(1) }
      }
    }
    $scheduledTaskCmdletsAvailable = (Get-Command -Name New-ScheduledTaskAction -ErrorAction SilentlyContinue) -and
      (Get-Command -Name New-ScheduledTaskTrigger -ErrorAction SilentlyContinue) -and
      (Get-Command -Name New-ScheduledTaskPrincipal -ErrorAction SilentlyContinue) -and
      (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue)
    if ($scheduledTaskCmdletsAvailable) {
      $action = New-ScheduledTaskAction -Execute 'cmd.exe' -Argument ('/d /c ""{0}""' -f $RunnerPath) -WorkingDirectory (Split-Path -Parent $WorkerPath)
      # RepetitionInterval/RepetitionDuration gehören beim Cmdlet zum
      # Parametersatz -Once, nicht zu -Daily. Pro möglichem Wartungstag wird
      # daher ein eigener einmaliger Wiederholungstrigger erstellt. Der Worker
      # prüft weiterhin selbst das Wartungsfenster und den Ablaufzeitpunkt.
      $triggerStarts = [System.Collections.Generic.List[datetime]]::new()
      $firstTriggerStart = if ($RunAt -gt [datetime]::MinValue) { $RunAt } else { (Get-Date).AddMinutes(1) }
      $triggerStarts.Add($firstTriggerStart)
      if ($TaskExpiresAt -gt [datetime]::MinValue) {
        $nextTriggerStart = $firstTriggerStart.Date.AddDays(1).Add($firstTriggerStart.TimeOfDay)
        while ($nextTriggerStart -lt $TaskExpiresAt) {
          $triggerStarts.Add($nextTriggerStart)
          $nextTriggerStart = $nextTriggerStart.Date.AddDays(1).Add($firstTriggerStart.TimeOfDay)
        }
      }

      $triggers = @(
        foreach ($triggerStart in $triggerStarts) {
          $triggerDuration = $repeatDuration
          if ($TaskExpiresAt -gt [datetime]::MinValue) {
            $remainingUntilExpiry = $TaskExpiresAt - $triggerStart
            if ($remainingUntilExpiry -lt $triggerDuration) { $triggerDuration = $remainingUntilExpiry }
          }
          if ($triggerDuration -gt [TimeSpan]::Zero) {
            New-ScheduledTaskTrigger -Once -At $triggerStart `
              -RepetitionInterval (New-TimeSpan -Minutes 15) `
              -RepetitionDuration $triggerDuration
          }
        }
        New-ScheduledTaskTrigger -AtStartup
      )
      if ($expiryTriggerAt -gt [datetime]::MinValue) { $triggers += New-ScheduledTaskTrigger -Once -At $expiryTriggerAt }
      $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
      $settings = New-ScheduledTaskSettingsSet -MultipleInstances IgnoreNew
      Register-ScheduledTask -TaskName $Name -Action $action -Trigger $triggers -Principal $principal -Settings $settings -Force | Out-Null
    } else {
      # schtasks unterstützt nur einen Trigger je Task; Windows 7 erhält deshalb
      # getrennte Aufgaben für Wartungsfenster und Systemstart.
      $schtasks = Join-Path $env:WINDIR 'System32\schtasks.exe'
      $taskCommand = 'cmd.exe /d /c ""{0}""' -f $RunnerPath
      $runAt = if ($RunAt -gt [datetime]::MinValue) { $RunAt } else { (Get-Date).AddMinutes(1) }
      $startDate = $runAt.ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
      $startTime = $runAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
      $repeatDurationText = '{0:D2}:{1:D2}' -f [int][Math]::Floor($repeatDuration.TotalHours), $repeatDuration.Minutes
      $windowOutput = & $schtasks /Create /TN $Name /SC DAILY /SD $startDate /ST $startTime /RI 15 /DU $repeatDurationText /RU SYSTEM /RL HIGHEST /TR $taskCommand /F 2>&1
      if ($LASTEXITCODE -ne 0) { throw "Wiederholungsaufgabe konnte mit schtasks.exe nicht erstellt werden: $((@($windowOutput) -join ' ').Trim())" }
      $startupName = $Name + '-AtStartup'
      $expiryName = $Name + '-Expiry'
      if ($expiryTriggerAt -gt [datetime]::MinValue) {
        $expiryDate = $expiryTriggerAt.ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
        $expiryTime = $expiryTriggerAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
        $expiryOutput = & $schtasks /Create /TN $expiryName /SC ONCE /SD $expiryDate /ST $expiryTime /RU SYSTEM /RL HIGHEST /TR $taskCommand /F 2>&1
        if ($LASTEXITCODE -ne 0) { & $schtasks /Delete /TN $Name /F *> $null; throw "Ablaufaufgabe konnte mit schtasks.exe nicht erstellt werden: $((@($expiryOutput) -join ' ').Trim())" }
      }
      $startupOutput = & $schtasks /Create /TN $startupName /SC ONSTART /RU SYSTEM /RL HIGHEST /TR $taskCommand /F 2>&1
      if ($LASTEXITCODE -ne 0) {
        & $schtasks /Delete /TN $Name /F *> $null
        & $schtasks /Delete /TN $expiryName /F *> $null
        throw "Systemstart-Aufgabe konnte mit schtasks.exe nicht erstellt werden: $((@($startupOutput) -join ' ').Trim())"
      }
    }
  }
  $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Servername -AuthInfo $AuthInfo
  $params.ScriptBlock = $sb; $params.ArgumentList = @($TaskName, $Script, $MailPassword, $At, $MaintenanceEndTime, $ExpiresAt)
  Invoke-WindowsUpdateWithRetry -OperationName "Remote-Startaufgabe '$TaskName' auf $Servername" -WriteLog { param($message) Write-DeferredModuleLog -WriteLog $WriteLog -Message $message } -ScriptBlock { Invoke-Command @params | Out-Null }
}

function Register-DeferredUpdateTask {
  param([string]$Servername, [string[]]$DeferredCategories, [string[]]$DeferredKBs = @(), [bool]$SucheOnline, [bool]$RebootRequired = $false, $AuthInfo = $null, [datetime]$ScheduledAt = [datetime]::MinValue, [string]$MaintenanceEndTime = '', [Parameter(Mandatory)][object]$MailSettings, [scriptblock]$WriteLog)
  # Nach einem Neustart prüft der Worker automatisch die Bereitschaft
  # des Windows-Update-Dienstes, statt eine feste Minutenfrist abzuwarten.
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
  $deferredMailPassword = [string]$deferredMailSettings.AuthPass
  # Das Passwort wird separat über WinRM übertragen und auf dem Zielrechner
  # maschinengebunden geschützt. Im Worker-JSON bleibt das Feld leer.
  Add-Member -InputObject $deferredMailSettings -NotePropertyName AuthPass -NotePropertyValue '' -Force
  if ([string]::IsNullOrWhiteSpace([string]$deferredMailSettings.Sender) -and -not [string]::IsNullOrWhiteSpace($deferredCompanyName)) {
    $deferredMailSafeName = ConvertTo-WindowsUpdateMailSafeString -Text $deferredCompanyName
    Add-Member -InputObject $deferredMailSettings -NotePropertyName 'Sender' -NotePropertyValue "Updates@$deferredMailSafeName.de" -Force
  }
  if ([string]::IsNullOrWhiteSpace([string]$deferredMailSettings.Install.Subject)) {
    Add-Member -InputObject $deferredMailSettings.Install -NotePropertyName 'Subject' -NotePropertyValue 'Server Updates installiert' -Force
  }
  $mailJson = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($deferredMailSettings | ConvertTo-Json -Depth 5 -Compress)))
  $registeredAt = [DateTime]::UtcNow.ToFileTimeUtc()
  $expiresAt = [DateTime]::FromFileTimeUtc($registeredAt).AddDays(5).ToLocalTime()
  $scheduledAtFileTime = if ($ScheduledAt -gt [datetime]::MinValue) { $ScheduledAt.ToUniversalTime().ToFileTimeUtc() } else { 0 }
  $maintenanceEndBase64 = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($MaintenanceEndTime))
  $script = @"
`$taskName = '$taskName'
`$workerFailed = `$false
`$taskExpired = `$false
`$workerPhase = 'Initialisierung'
`$removeDeferredTask = {
  param([string]`$Name)
  `$schtasks = Join-Path `$env:WINDIR 'System32\schtasks.exe'
  foreach (`$candidateName in @(`$Name, (`$Name + '-AtStartup'), (`$Name + '-Expiry'))) {
    & `$schtasks /Delete /TN `$candidateName /F *> `$null
  }
}
try {
  `$logDirectory = Join-Path `$env:ProgramData 'WindowsUpdateAdm'
  `$logFile = Join-Path `$logDirectory 'DeferredUpdates.log'
  New-Item -ItemType Directory -Path `$logDirectory -Force | Out-Null
  function Write-DeferredLog([string]`$Message) {
    "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  `$Message" | Add-Content -LiteralPath `$logFile -Encoding UTF8
  }
  function Get-DeferredMailSettings {
    `$mail = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$mailJson')) | ConvertFrom-Json
    `$protectedPassword = '__WINDOWSUPDATEADM_DPAPI_MAILPASS__'
    if (-not [string]::IsNullOrEmpty(`$protectedPassword)) {
      if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
        try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
        catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
      }
      `$cipherBytes = [Convert]::FromBase64String(`$protectedPassword)
      `$plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(`$cipherBytes, `$null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
      try { `$mail.AuthPass = [Text.Encoding]::UTF8.GetString(`$plainBytes) }
      finally { [Array]::Clear(`$plainBytes, 0, `$plainBytes.Length) }
    }
    return `$mail
  }
  function Send-DeferredFinalMail {
    param([string]`$Subject, [string]`$Body, [bool]`$IsHtml = `$false)
    `$notificationPath = Join-Path `$logDirectory 'DeferredUpdates-FinalNotificationSent.txt'
    if (Test-Path -LiteralPath `$notificationPath) {
      Write-DeferredLog 'Abschluss-E-Mail übersprungen; für diese Nachinstallation wurde bereits ein Mailversand versucht.'
      return `$true
    }
    try {
      `$mail = Get-DeferredMailSettings
      if (-not (`$mail.Install.SendMail -and `$mail.Host -and `$mail.MailTo)) {
        Write-DeferredLog 'Abschluss-E-Mail übersprungen: SendMail, SMTP-Host oder Empfänger fehlen.'
        return `$true
      }
      `$mailSubject = if (-not [string]::IsNullOrWhiteSpace([string]`$mail.Install.Subject)) { `$Subject + ' ' + [string]`$mail.Install.Subject } else { `$Subject }
      `$smtp = New-Object Net.Mail.SmtpClient(`$mail.Host, [int]`$mail.Port)
      `$smtp.EnableSsl = [bool]`$mail.UseSSL
      if (`$mail.Auth) { `$smtp.Credentials = New-Object Net.NetworkCredential(`$mail.AuthUser, `$mail.AuthPass) }
      `$message = New-Object Net.Mail.MailMessage(`$mail.Sender, `$mail.MailTo, `$mailSubject, `$Body)
      `$message.BodyEncoding = [Text.Encoding]::UTF8
      `$message.IsBodyHtml = `$IsHtml
      `$smtp.Send(`$message)
      [System.IO.File]::WriteAllText(`$notificationPath, [DateTime]::UtcNow.ToString('o'))
      Write-DeferredLog 'Abschluss-E-Mail erfolgreich versendet.'
      return `$true
    } catch {
      Write-DeferredLog "Abschluss-Mailversand fehlgeschlagen; ein weiterer Versuch bleibt möglich: `$(`$_.Exception.Message)"
      return `$false
    } finally {
      if (`$message) { `$message.Dispose() }
      if (`$smtp) { `$smtp.Dispose() }
    }
  }
  `$waitForReboot = `$false
  `$mainRunRebootRequired = $(if ($RebootRequired) { '$true' } else { '$false' })
  `$scheduledAt = if ($scheduledAtFileTime -gt 0) { [DateTime]::FromFileTimeUtc($scheduledAtFileTime) } else { [DateTime]::MinValue }
  `$maintenanceEndTime = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$maintenanceEndBase64'))
  Write-DeferredLog 'Nachinstallationsaufgabe gestartet.'
  `$workerPhase = 'Neustart- und Wartungsfensterprüfung'
  `$registeredAt = [DateTime]::FromFileTimeUtc($registeredAt)
  if ([DateTime]::UtcNow -ge `$registeredAt.AddDays(5)) {
    `$taskExpired = `$true
    `$workerPhase = 'Maximale Laufzeit erreicht'
    Write-DeferredLog 'Die Nachinstallationsaufgabe hat die maximale Laufzeit von fünf Tagen erreicht und wird beendet.'
    if (-not (Send-DeferredFinalMail -Subject 'FEHLER Nachinstallation:' -Body "Die zurückgestellten Updates auf `$env:COMPUTERNAME wurden innerhalb von fünf Tagen nicht vollständig installiert. Bitte das Protokoll DeferredUpdates.log prüfen und manuell nacharbeiten.")) {
      `$workerFailed = `$true
    }
    return
  }
  `$lastBoot = ([DateTime](Get-CimInstance Win32_OperatingSystem -ErrorAction Stop).LastBootUpTime).ToUniversalTime()
  `$rebootDetected = `$lastBoot -gt `$registeredAt
  `$windowOpen = `$true
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
    # Die Aufgabe wird täglich im Wartungsfenster gestartet. Ein Neustart
    # ist keine Voraussetzung, wenn das Fenster bereits offen ist.
    if (-not `$windowOpen) {
      `$waitForReboot = `$true
      Write-DeferredLog "Wartungsfenster ist geschlossen. Die Aufgabe wartet auf das nächste tägliche Wartungsfenster."
    } elseif (`$mainRunRebootRequired -and -not `$rebootDetected) {
      `$waitForReboot = `$true
      Write-DeferredLog 'Der Hauptlauf hat einen Neustartbedarf erkannt. Die Nachinstallation wartet auf den tatsächlichen Neustart.'
    } elseif (`$rebootDetected) {
      Write-DeferredLog 'Neustart erkannt und Wartungsfenster offen. Prüfe automatisch die Bereitschaft von Windows Update.'
    } else {
      Write-DeferredLog 'Kein Neustart erforderlich. Wartungsfenster ist offen; Nachinstallation startet direkt.'
    }
  } elseif (`$mainRunRebootRequired -and -not `$rebootDetected) {
    `$waitForReboot = `$true
    Write-DeferredLog 'Der Hauptlauf hat einen Neustartbedarf erkannt. Die Nachinstallation wartet auf den tatsächlichen Neustart.'
  } elseif (`$rebootDetected) {
    Write-DeferredLog 'Neustart erkannt. Prüfe automatisch die Bereitschaft von Windows Update.'
  } else {
    Write-DeferredLog 'Kein Neustart erforderlich. Nachinstallation startet direkt.'
  }
  `$pendingRebootPath = Join-Path `$logDirectory 'DeferredUpdates-RebootPending.txt'
  if (-not `$waitForReboot -and (Test-Path -LiteralPath `$pendingRebootPath)) {
    `$rebootRequestedAt = [DateTime]::FromFileTimeUtc([long](Get-Content -LiteralPath `$pendingRebootPath -Raw))
    if (`$lastBoot -gt `$rebootRequestedAt) {
      Remove-Item -LiteralPath `$pendingRebootPath -Force -ErrorAction Stop
      `$rebootDetected = `$true
      Write-DeferredLog 'Der für die Nachinstallation angeforderte Neustart wurde erkannt; setze mit der Restprüfung fort.'
    } else {
      `$waitForReboot = `$true
      if (`$windowOpen) {
        Write-DeferredLog 'Ein Neustart aus dem vorherigen Nachinstallationsversuch steht noch aus. Er wird jetzt innerhalb des Wartungsfensters ausgelöst.'
        shutdown.exe /r /t 0 /f | Out-Null
        if (`$LASTEXITCODE -ne 0) { throw "Geplanter Neustart konnte nicht ausgelöst werden (Exitcode `$LASTEXITCODE)." }
      } else {
        Write-DeferredLog 'Ein Neustart aus dem vorherigen Nachinstallationsversuch steht noch aus. Die Aufgabe wartet bis zum Wartungsfenster.'
      }
    }
  }
  if (-not `$waitForReboot -and `$rebootDetected) {
    # Statt einer festen Wartezeit auf eine erfolgreiche, rein lesende
    # Windows-Update-Suche warten. Eine Obergrenze verhindert endloses Warten.
    `$workerPhase = 'Windows-Update-Bereitschaft prüfen'
    Import-Module PSWindowsUpdate -ErrorAction Stop
    `$readyDeadline = (Get-Date).AddMinutes(5)
    `$readyAttempt = 0
    `$windowsUpdateReady = `$false
    while (-not `$windowsUpdateReady -and (Get-Date) -lt `$readyDeadline) {
      `$readyAttempt++
      try {
        `$null = @(Get-WindowsUpdate -AcceptAll -ErrorAction Stop)
        `$windowsUpdateReady = `$true
        Write-DeferredLog 'Windows Update antwortet auf die Bereitschaftssuche.'
      } catch {
        Write-DeferredLog "Windows Update ist noch nicht bereit (Versuch `$readyAttempt): `$(`$_.Exception.Message)"
        if ((Get-Date) -lt `$readyDeadline) { Start-Sleep -Seconds 15 }
      }
    }
    if (-not `$windowsUpdateReady) {
      `$waitForReboot = `$true
      Write-DeferredLog 'Windows Update wurde innerhalb von fünf Minuten nach dem Neustart nicht bereit. Die Aufgabe bleibt bis zum nächsten Wartungsfenster bestehen.'
    } elseif (`$scheduledAt -gt [DateTime]::MinValue -and -not [string]::IsNullOrWhiteSpace(`$maintenanceEndTime) -and (Get-Date) -ge `$windowEnd) {
      `$waitForReboot = `$true
      Write-DeferredLog 'Windows Update ist bereit, aber das Wartungsfenster ist inzwischen geschlossen. Nachinstallation wartet auf das nächste Fenster.'
    }
  }
  if (-not `$waitForReboot) {
    `$workerPhase = 'Zurückgestellte Updates installieren'
    Import-Module PSWindowsUpdate -ErrorAction Stop
    # ConvertFrom-Json kann Arrays je nach PowerShell-Version verschachtelt
    # zurückgeben. Kategorien rekursiv in einzelne Zeichenfolgen auflösen.
    function Add-DeferredCategoryValue {
      param(`$Value, [System.Collections.Generic.List[string]]`$Target)
      if (`$null -eq `$Value) { return }
      if (`$Value -is [string]) {
        if (-not [string]::IsNullOrWhiteSpace(`$Value)) { `$Target.Add(`$Value.Trim()) }
        return
      }
      if (`$Value -is [System.Collections.IEnumerable]) {
        foreach (`$item in `$Value) { Add-DeferredCategoryValue -Value `$item -Target `$Target }
        return
      }
      `$text = [string]`$Value
      if (-not [string]::IsNullOrWhiteSpace(`$text)) { `$Target.Add(`$text.Trim()) }
    }
    `$parsedCategories = ConvertFrom-Json -InputObject '$categories'
    `$categoryValues = New-Object 'System.Collections.Generic.List[string]'
    Add-DeferredCategoryValue -Value `$parsedCategories -Target `$categoryValues
    `$categories = `$categoryValues.ToArray()
    `$deferredKBs = @('$deferredKBsJson' | ConvertFrom-Json | Where-Object { -not [string]::IsNullOrWhiteSpace([string]`$_) })
    if (`$deferredKBs.Count -eq 0 -and `$categories.Count -eq 0) {
      throw 'Für die Nachinstallation wurden keine KBs oder Kategorien gespeichert. Aufgabe bleibt zur Diagnose bestehen; sie wird nicht als abgeschlossen entfernt.'
    }
    Write-DeferredLog "Gespeicherte Auswahl geladen: KBs=`$(`$deferredKBs.Count), Kategorien=`$(`$categories.Count)."
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
    # Ein Update kann mehreren ausgewählten Kategorien zugeordnet sein.
    # Doppelte Rückgabeobjekte dürfen weder mehrfach in der Mail erscheinen
    # noch die angezeigte Installationsanzahl erhöhen.
    `$resultsStatePath = Join-Path `$logDirectory 'DeferredUpdates-Results.json'
    `$previousResults = @()
    if (Test-Path -LiteralPath `$resultsStatePath) {
      try { `$previousResults = @(Get-Content -LiteralPath `$resultsStatePath -Raw | ConvertFrom-Json -ErrorAction Stop) }
      catch { throw "Gespeicherte Installationsresultate konnten nicht gelesen werden: `$(`$_.Exception.Message)" }
    }
    `$results = @(`$previousResults) + @(`$results)
    # Ein Update kann vor dem Neustart installiert worden sein, bevor der
    # Worker seine Installationsresultate dauerhaft speichern konnte. Ergänze
    # deshalb erfolgreiche, passende Einträge aus dem Verlauf seit Aufgabenanlage.
    try {
      `$historyEntries = @(Get-WUHistory -ErrorAction Stop)
      `$historyResults = foreach (`$entry in `$historyEntries) {
        if (`$null -eq `$entry.PSObject.Properties['Date']) { continue }
        try { `$historyDate = [DateTime]`$entry.Date } catch { continue }
        if (`$historyDate -lt `$registeredAt.ToLocalTime()) { continue }

        `$historyResult = [string]`$entry.Result
        if ([string]::IsNullOrWhiteSpace(`$historyResult) -and `$entry.PSObject.Properties['ResultCode']) {
          `$historyResult = switch ([int]`$entry.ResultCode) {
            2 { 'Succeeded' }
            3 { 'Succeeded With Errors' }
            default { [string]`$entry.ResultCode }
          }
        }
        if (`$historyResult -notmatch '^(Succeeded|Erfolgreich)$') { continue }

        `$historyKB = [string]`$entry.KB
        `$historyTitle = [string]`$entry.Title
        `$historyCategoryText = @(`$entry.Categories | ForEach-Object { [string]`$_ }) -join '; '
        `$matchesDeferredSelection = `$false
        foreach (`$deferredKB in `$deferredKBs) {
          if (-not [string]::IsNullOrWhiteSpace(`$historyKB) -and
              (`$historyKB -split '[,;\s]+' | Where-Object { `$_.Trim() -eq `$deferredKB.Trim() })) {
            `$matchesDeferredSelection = `$true
            break
          }
        }
        if (-not `$matchesDeferredSelection) {
          foreach (`$deferredCategory in `$categories) {
            if (-not [string]::IsNullOrWhiteSpace(`$deferredCategory) -and
                (`$historyCategoryText -like "*`$deferredCategory*" -or `$historyTitle -like "*`$deferredCategory*")) {
              `$matchesDeferredSelection = `$true
              break
            }
          }
        }
        if (-not `$matchesDeferredSelection) { continue }

        [pscustomobject]@{
          ComputerName = if (`$entry.PSObject.Properties['ComputerName']) { [string]`$entry.ComputerName } else { [string]`$env:COMPUTERNAME }
          Status = 'Succeeded'
          Result = 'Succeeded'
          KB = `$historyKB
          Size = if (`$entry.PSObject.Properties['Size']) { [string]`$entry.Size } else { '' }
          Title = `$historyTitle
          UpdateID = if (`$entry.PSObject.Properties['UpdateID']) { [string]`$entry.UpdateID } else { '' }
        }
      }
      if (`$historyResults) {
        Write-DeferredLog "Ergänze `$(@(`$historyResults).Count) erfolgreiche zurückgestellte Installation(en) aus dem Updateverlauf seit Aufgabenanlage."
        # Verlaufsresultate stehen vorn, damit bei Duplikaten der bestätigte
        # Erfolgsstatus statt eines früheren Accepted-/Download-Status bleibt.
        `$results = @(`$historyResults) + @(`$results)
      }
    } catch {
      Write-DeferredLog "WARNUNG: Erfolgreiche Installationen konnten nicht aus dem Windows-Updateverlauf ergänzt werden: `$(`$_.Exception.Message)"
    }
    `$seenUpdateKeys = @{}
    `$results = @(`$results | Where-Object {
      `$updateKB = [string]`$_.KB
      `$updateTitle = [string]`$_.Title
      `$updateID = [string]`$_.UpdateID
      if ([string]::IsNullOrWhiteSpace(`$updateKB) -and [string]::IsNullOrWhiteSpace(`$updateTitle) -and [string]::IsNullOrWhiteSpace(`$updateID)) { `$false; return }
      `$updateKey = if (-not [string]::IsNullOrWhiteSpace(`$updateKB) -or -not [string]::IsNullOrWhiteSpace(`$updateTitle)) { `$updateKB + '|' + `$updateTitle } else { `$updateID }
      if (`$seenUpdateKeys.ContainsKey(`$updateKey)) { `$false }
      else { `$seenUpdateKeys[`$updateKey] = `$true; `$true }
    })
    ConvertTo-Json -InputObject @(`$results) -Depth 6 | Set-Content -LiteralPath `$resultsStatePath -Encoding UTF8
    `$selection = `$selectionParts -join '; '
    function Get-DeferredUpdateField {
      param([object]`$Update, [string[]]`$Names)
      foreach (`$name in `$Names) {
        `$property = `$Update.PSObject.Properties[`$name]
        if (`$null -eq `$property -or `$null -eq `$property.Value) { continue }
        `$value = `$property.Value
        if (`$value -is [array]) { `$value = @(`$value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]`$_) }) -join ', ' }
        if (-not [string]::IsNullOrWhiteSpace([string]`$value)) { return [string]`$value }
      }
      return ''
    }
    `$rows = foreach (`$result in @(`$results)) {
      `$computerValue = Get-DeferredUpdateField -Update `$result -Names @('ComputerName', 'PSComputerName')
      if ([string]::IsNullOrWhiteSpace(`$computerValue)) { `$computerValue = [string]`$env:COMPUTERNAME }
      `$statusValue = Get-DeferredUpdateField -Update `$result -Names @('Status', 'Result', 'UpdateStatus')
      `$kbValue = Get-DeferredUpdateField -Update `$result -Names @('KB', 'KBArticleID', 'KBArticleIDs')
      if (-not [string]::IsNullOrWhiteSpace(`$kbValue)) {
        `$kbValue = (@(([string]`$kbValue -split ',\s*') | ForEach-Object { if (`$_ -match '^KB') { `$_ } else { "KB`$_" } }) -join ', ')
      }
      `$sizeValue = Get-DeferredUpdateField -Update `$result -Names @('Size', 'MaxDownloadSize')
      `$titleValue = Get-DeferredUpdateField -Update `$result -Names @('Title', 'UpdateTitle', 'Name')
      `$computerName = [System.Net.WebUtility]::HtmlEncode(`$computerValue)
      `$status = [System.Net.WebUtility]::HtmlEncode(`$statusValue)
      `$kb = [System.Net.WebUtility]::HtmlEncode(`$kbValue)
      `$size = [System.Net.WebUtility]::HtmlEncode(`$sizeValue)
      `$title = [System.Net.WebUtility]::HtmlEncode(`$titleValue)
      "<tr><td>`$computerName</td><td>`$status</td><td>`$kb</td><td>`$size</td><td>`$title</td></tr>"
    }
    if (-not `$rows) { `$rows = '<tr><td colspan="5">Keine zurückgestellten Updates waren mehr verfügbar.</td></tr>' }
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
<table><tr><th>ComputerName</th><th>Status</th><th>KB</th><th>Size</th><th>Title</th></tr>{{rows}}</table>
<div class="summary"><strong>Ergebnis:</strong> Die Nachinstallation wurde abgeschlossen. Installierte Updates: {{count}}.</div>
</body></html>
'@
    `$body = `$body.Replace('{{computer}}', [System.Net.WebUtility]::HtmlEncode(`$env:COMPUTERNAME)).Replace('{{date}}', (Get-Date -Format 'dd.MM.yyyy HH:mm:ss')).Replace('{{selection}}', `$safeSelection).Replace('{{rows}}', (`$rows -join '')).Replace('{{count}}', [string]`$(@(`$results).Count))
    `$workerPhase = 'Neustartbedarf prüfen'
    `$rebootStatus = Get-WURebootStatus -Silent -ErrorAction Stop
    `$rebootRequired = if (`$rebootStatus -is [bool]) { `$rebootStatus } elseif (`$null -ne `$rebootStatus -and `$null -ne `$rebootStatus.PSObject.Properties['RebootRequired']) { [bool]`$rebootStatus.RebootRequired } else { `$false }
    Write-DeferredLog "Get-WURebootStatus meldet RebootRequired = `$rebootRequired."
    if (`$rebootRequired) {
      `$waitForReboot = `$true
      [System.IO.File]::WriteAllText(`$pendingRebootPath, [DateTime]::UtcNow.ToFileTimeUtc().ToString())
      if (`$scheduledAt -gt [DateTime]::MinValue -and -not [string]::IsNullOrWhiteSpace(`$maintenanceEndTime) -and (Get-Date) -ge `$windowEnd) {
        Write-DeferredLog 'Neustart erforderlich, aber das Wartungsfenster ist geschlossen. Neustart wird bis zum nächsten Wartungsfenster zurückgestellt.'
      } else {
        Write-DeferredLog 'Neustart erforderlich. Die Aufgabe bleibt bestehen und wird nach dem Neustart im Wartungsfenster fortgesetzt.'
        shutdown.exe /r /t 0 /f | Out-Null
        if (`$LASTEXITCODE -ne 0) { throw "Geplanter Neustart konnte nicht ausgelöst werden (Exitcode `$LASTEXITCODE)." }
      }
    } else {
      `$workerPhase = 'Verbleibende zurückgestellte Updates prüfen'
      function Add-DeferredUpdateCandidate {
        param([object]`$Candidate, [System.Collections.Generic.List[object]]`$Target)
        if (`$null -eq `$Candidate) { return }
        if (`$Candidate -is [System.Collections.IEnumerable] -and
            `$Candidate -isnot [string] -and
            `$Candidate -isnot [System.Collections.IDictionary]) {
          foreach (`$nestedCandidate in `$Candidate) {
            Add-DeferredUpdateCandidate -Candidate `$nestedCandidate -Target `$Target
          }
          return
        }
        if (`$Candidate -is [string] -and [string]::IsNullOrWhiteSpace(`$Candidate)) { return }
        `$identityFound = `$false
        foreach (`$fieldName in @('KB', 'KBArticleID', 'KBArticleIDs', 'Title', 'UpdateTitle', 'Name', 'UpdateID', 'UpdateIdentity', 'Identity', 'Size', 'MaxDownloadSize')) {
          `$field = `$Candidate.PSObject.Properties[`$fieldName]
          if (`$field -and `$null -ne `$field.Value -and -not [string]::IsNullOrWhiteSpace([string]`$field.Value)) {
            `$identityFound = `$true
            break
          }
        }
        if (-not `$identityFound) {
          `$candidateType = `$Candidate.GetType().FullName
          `$candidateProperties = @(`$Candidate.PSObject.Properties | ForEach-Object { `$_.Name }) -join ', '
          throw "Die Restprüfung lieferte ein nicht identifizierbares Ergebnis (Typ=`$candidateType; Eigenschaften=[`$candidateProperties])."
        }
        `$Target.Add(`$Candidate)
      }
      `$remainingUpdateList = [System.Collections.Generic.List[object]]::new()
      foreach (`$kb in `$deferredKBs) {
        foreach (`$candidate in @(Get-WindowsUpdate -KBArticleID `$kb -ErrorAction Stop)) {
          Add-DeferredUpdateCandidate -Candidate `$candidate -Target `$remainingUpdateList
        }
      }
      foreach (`$category in `$categories) {
        foreach (`$candidate in @(Get-WindowsUpdate -Category `$category -ErrorAction Stop)) {
          Add-DeferredUpdateCandidate -Candidate `$candidate -Target `$remainingUpdateList
        }
      }
      `$remainingUpdates = @(`$remainingUpdateList.ToArray())
      # Ein Update kann mehreren zurückgestellten Kategorien angehören.
      `$seenRemainingUpdates = @{}
      `$remainingUpdates = @(`$remainingUpdates | Where-Object {
        `$identity = Get-DeferredUpdateField -Update `$_ -Names @('KB', 'KBArticleID', 'KBArticleIDs', 'UpdateID', 'UpdateIdentity', 'Identity', 'Title', 'UpdateTitle', 'Name')
        if ([string]::IsNullOrWhiteSpace([string]`$identity)) { throw 'Ein verbliebenes Update besitzt keine auswertbare Identität.' }
        if (`$seenRemainingUpdates.ContainsKey([string]`$identity)) { `$false }
        else { `$seenRemainingUpdates[[string]`$identity] = `$true; `$true }
      })
      if (`$remainingUpdates.Count -gt 0) {
        `$waitForReboot = `$true
        `$remainingTitles = @(`$remainingUpdates | ForEach-Object { if (`$_.Title) { [string]`$_.Title } else { [string]`$_.KB } } | Where-Object { -not [string]::IsNullOrWhiteSpace(`$_) } | Select-Object -Unique)
        Write-DeferredLog "Zurückgestellte Updates sind noch verfügbar (`$(`$remainingUpdates.Count)); nächster Installationsversuch im Wartungsfenster. Verbleibend: `$(`$remainingTitles -join '; ')"
      } else {
        `$workerPhase = 'Abschluss-E-Mail senden'
        if (-not (Send-DeferredFinalMail -Subject 'Nachinstallation:' -Body `$body -IsHtml `$true)) {
          `$workerFailed = `$true
        }
      }
    }
    `$workerPhase = 'Abgeschlossen'
  }
} catch {
  `$workerFailed = `$true
  `$failureMessage = `$_.Exception.Message
  `$failureDetails = `$_.Exception.ToString()
  try {
    Write-DeferredLog "FEHLER in Phase '`$workerPhase': `$failureMessage"
    Write-DeferredLog "Fehlerdetails: `$failureDetails"
  } catch { }
  # Während der Wiederholungsphase wird nicht gemailt. Das Ergebnis wird erst
  # bei Erfolg oder nach Ablauf der Fünf-Tage-Frist einmalig versendet.
} finally {
  # Fehler und Wartephasen behalten Aufgabe, Worker und Starthelfer für den nächsten Versuch.
  if (-not `$waitForReboot -and -not `$workerFailed) {
    if (`$taskExpired) {
      Write-DeferredLog 'Fünf-Tage-Frist abgelaufen. Aufgabe wird entfernt.'
    } else {
      Write-DeferredLog 'Nachinstallation abgeschlossen. Aufgabe wird entfernt.'
    }
    & `$removeDeferredTask `$taskName
    Remove-Item -LiteralPath (Join-Path `$logDirectory 'DeferredUpdates.ps1') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path `$logDirectory 'DeferredUpdates-LastFailureNotice.txt') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path `$logDirectory 'DeferredUpdates-Results.json') -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path `$logDirectory 'DeferredUpdates-RebootPending.txt') -Force -ErrorAction SilentlyContinue
  } elseif (`$workerFailed) {
    try { Write-DeferredLog "Aufgabe bleibt nach Fehler in Phase '`$workerPhase' für einen erneuten Versuch bestehen." } catch { }
  }
}

# Exitcodes halten die wiederkehrende Startaufgabe bei Wartephasen am Leben
# und melden echte Worker-Fehler an den CMD-Starthelfer zurück.
if (`$workerFailed) { exit 1 }
if (`$waitForReboot) { exit 2 }

"@
  Register-StartupRemoteTask -Servername $Servername -TaskName $taskName -Script $script -AuthInfo $AuthInfo -At $ScheduledAt -MailPassword $deferredMailPassword -MaintenanceEndTime $MaintenanceEndTime -ExpiresAt $expiresAt -WriteLog $WriteLog
  $selectionText = @(
    if ($DeferredKBs.Count -gt 0) { "KBs: $($DeferredKBs -join ', ')" }
    if ($DeferredCategories.Count -gt 0) { "Kategorien: $($DeferredCategories -join ', ')" }
  ) -join '; '
  $activationText = if ($ScheduledAt -gt [datetime]::MinValue) { "im Wartungsfenster $($ScheduledAt.ToString('dd.MM.yyyy HH:mm'))" } else { 'beim nächsten Neustart' }
  Write-DeferredModuleLog -WriteLog $WriteLog -Message "Nachinstallation auf $Servername wird $activationText aktiviert; nach einem Neustart wartet sie automatisch auf die Bereitschaft von Windows Update ($selectionText; selbstlöschend)."
}

function Register-DeferredMailTestTask {
  param([string]$Servername, $AuthInfo = $null, [Parameter(Mandatory)][object]$MailSettings, [scriptblock]$WriteLog)

  $taskName = 'WindowsUpdateAdm-TestDeferredMail'
  $testMailPassword = [string]$MailSettings.AuthPass
  $testMailSettings = $MailSettings | ConvertTo-Json -Depth 5 -Compress | ConvertFrom-Json
  Add-Member -InputObject $testMailSettings -NotePropertyName AuthPass -NotePropertyValue '' -Force
  $mailJson = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes(($testMailSettings | ConvertTo-Json -Depth 5 -Compress)))
  $script = @"
`$taskName = '$taskName'
`$logDirectory = Join-Path `$env:ProgramData 'WindowsUpdateAdm'
`$logFile = Join-Path `$logDirectory 'DeferredUpdates.log'
New-Item -ItemType Directory -Path `$logDirectory -Force | Out-Null
function Write-TestMailLog([string]`$Message) {
  "`$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')  TESTMAIL: `$Message" | Add-Content -LiteralPath `$logFile -Encoding UTF8
}
function Get-TestMailSettings {
  `$mail = [Text.Encoding]::Unicode.GetString([Convert]::FromBase64String('$mailJson')) | ConvertFrom-Json
  `$protectedPassword = '__WINDOWSUPDATEADM_DPAPI_MAILPASS__'
  if (-not [string]::IsNullOrEmpty(`$protectedPassword)) {
    if (-not ('System.Security.Cryptography.ProtectedData' -as [type])) {
      try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
      catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
    }
    `$cipherBytes = [Convert]::FromBase64String(`$protectedPassword)
    `$plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(`$cipherBytes, `$null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { `$mail.AuthPass = [Text.Encoding]::UTF8.GetString(`$plainBytes) }
    finally { [Array]::Clear(`$plainBytes, 0, `$plainBytes.Length) }
  }
  return `$mail
}
try {
  Write-TestMailLog 'Testmail-Aufgabe gestartet.'
  `$mail = Get-TestMailSettings
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
  & (Join-Path `$env:WINDIR 'System32\schtasks.exe') /Delete /TN `$taskName /F *> `$null
}
"@
  # Kurzer Abstand lässt den Aufruf sauber enden und prüft den echten SYSTEM-Kontext.
  Register-OneTimeRemoteTask -Servername $Servername -TaskName $taskName -At (Get-Date).AddMinutes(1) -Script $script -AuthInfo $AuthInfo -MailPassword $testMailPassword -WriteLog $WriteLog
  Write-DeferredModuleLog -WriteLog $WriteLog -Message "Testmail-Aufgabe auf $Servername geplant (Start in etwa einer Minute; selbstlöschend)."
}

############################################################################################################################################################################
