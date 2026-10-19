# Fachmodul: WindowsUpdate.Remoting
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function New-WindowsUpdateInvokeCommandParams {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [string]$ConfigurationName,
        [ValidateRange(1, 300)][int]$OpenTimeoutSeconds = 30,
        [ValidateRange(60, 14400)][int]$OperationTimeoutSeconds = 3600
    )

    $sessionOptionParameters = @{
        OpenTimeout = ($OpenTimeoutSeconds * 1000)
        OperationTimeout = ($OperationTimeoutSeconds * 1000)
    }
    # IncludePortInSPN wird ausschließlich in den expliziten Kerberos-/
    # Negotiate-Fallbacks der aufrufenden Skripte gesetzt. Der allgemeine
    # Helfer wird auch für Zertifikats- und Paketmanager-Aufrufe verwendet;
    # dort würde ein SPN-Port die Verbindung stören.
    $parameters = @{
        ComputerName = $ComputerName
        ErrorAction = 'Stop'
        SessionOption = (New-PSSessionOption @sessionOptionParameters)
    }
    if ($ConfigurationName) { $parameters.ConfigurationName = $ConfigurationName }
    if ($AuthInfo -and $AuthInfo.Type -eq 'Certificate') {
        $parameters.UseSSL = $true
        $parameters.CertificateThumbprint = $AuthInfo.Thumbprint
    }
    return $parameters
}

function Initialize-WindowsUpdateRemoting {
    param(
        [Parameter(Mandatory)]$UpdateSettings,
        [Parameter(Mandatory)][string]$TargetComputer,
        [bool]$IsNonAdTarget,
        [scriptblock]$WriteLog
    )

    if (-not $IsNonAdTarget) {
        return [PSCustomObject]@{ AuthInfo = $null; IsNonAdTarget = $false }
    }

    Add-WindowsUpdateTrustedHost -ComputerName $TargetComputer -WriteLog $WriteLog
    $authInfo = Get-WindowsUpdateClientCertificateAuthInfo -UpdateSettings $UpdateSettings -TargetComputer $TargetComputer -WriteLog $WriteLog
    return [PSCustomObject]@{ AuthInfo = $authInfo; IsNonAdTarget = $true }
}

function Test-WindowsUpdateJeaSupported {
    param(
        [Parameter(Mandatory)][string]$TargetComputer,
        $AuthInfo,
        [bool]$IsNonAdTarget,
        [scriptblock]$WriteLog
    )

    # Windows Server 2016 und 2019 außerhalb der AD können zwar über den
    # Zertifikat-Administrator remoten, verweigern diesem Kontext aber teils
    # den JEA-Endpunkt bzw. Windows-Update-Zugriff. Die aufrufenden Skripte
    # verwenden deshalb eine kurzlebige, selbstlöschende SYSTEM-Aufgabe.
    if (-not $IsNonAdTarget -or -not $AuthInfo -or $AuthInfo.Type -ne 'Certificate') { return $true }
    try {
        $parameters = New-WindowsUpdateInvokeCommandParams -ComputerName $TargetComputer -AuthInfo $AuthInfo
        $parameters.ScriptBlock = { [int](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).BuildNumber }
        $build = [int](Invoke-Command @parameters)
        # 14393 = Server 2016, 17763 = Server 2019.
        if ($build -le 17763) {
            # Die aufrufenden Skripte protokollieren bereits die konkrete
            # SYSTEM-Aufgabe; diese reine Verfahrensinfo würde doppelt erscheinen.
            return $false
        }
    }
    catch {
        # Kann die reine Build-Abfrage nicht durchgeführt werden, bleibt JEA
        # der sichere Standard und liefert bei einem echten Fehler eine klare
        # Meldung aus dem aufrufenden Skript.
        Write-CommonLog $WriteLog "INFO: Windows-Version von '$TargetComputer' nicht ermittelbar – prüfe JEA regulär."
    }
    return $true
}

function Invoke-WindowsUpdateSystemTask {
    <#
    .SYNOPSIS
    Führt einen Windows-Update-Vorgang als kurzlebige SYSTEM-Aufgabe aus.

    .DESCRIPTION
    Windows Server 2016 außerhalb einer Domäne kann über einen gemappten
    Client-Zertifikat-Administrator remoten, verweigert diesem Kontext aber
    teilweise den Windows-Update-Zugriff. Die Aufgabe wird ausschließlich
    über die bereits geprüfte HTTPS-Zertifikatsverbindung angelegt, läuft als
    SYSTEM und entfernt sich samt Arbeitsdatei nach dem Ergebnis selbst.
    #>
    param(
        [Parameter(Mandatory)][string]$TargetComputer,
        [Parameter(Mandatory)]$AuthInfo,
        [Parameter(Mandatory)][ValidateSet('Check', 'Download', 'Install', 'RebootStatus', 'RemoveDeferredTask')][string]$Mode,
        [bool]$SearchOnline,
        [string[]]$DeferredCategories = @(),
        [string[]]$DeferredKBs = @(),
        [bool]$DeferredOnly,
        [ValidateRange(60, 14400)][int]$TimeoutSeconds = 7200,
        [ValidateRange(2, 60)][int]$PollSeconds = 10,
        [scriptblock]$WriteLog
    )

    if (-not $AuthInfo -or $AuthInfo.Type -ne 'Certificate') {
        throw "SYSTEM-Update-Aufgabe für '$TargetComputer' benötigt die Zertifikatsverbindung."
    }

    $id = [guid]::NewGuid().ToString('N')
    $taskName = "WindowsUpdateAdm-Worker-$id"
    $basePath = 'C:\ProgramData\WindowsUpdateAdm'
    $workerPath = Join-Path $basePath "$taskName.ps1"
    $resultPath = Join-Path $basePath "$taskName.json"
    $config = [ordered]@{
        TaskName = $taskName; WorkerPath = $workerPath; ResultPath = $resultPath
        Mode = $Mode; SearchOnline = $SearchOnline; DeferredCategories = @($DeferredCategories)
        DeferredKBs = @($DeferredKBs); DeferredOnly = $DeferredOnly
    }
    $config64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($config | ConvertTo-Json -Compress -Depth 4)))
$worker = @'
$ErrorActionPreference = 'Stop'
$config = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__CONFIG__')) | ConvertFrom-Json
function Get-WorkerUpdateField {
    param([object]$Update, [string[]]$Names)
    foreach ($name in $Names) {
        $property = $Update.PSObject.Properties[$name]
        if ($null -eq $property -or $null -eq $property.Value) { continue }
        $value = $property.Value
        if ($value -is [array]) { $value = @($value | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }) -join ', ' }
        if (-not [string]::IsNullOrWhiteSpace([string]$value)) { return $value }
    }
    return $null
}
function ConvertTo-WorkerUpdateRows {
    param([object[]]$Items)
    $pendingItems = [System.Collections.Generic.Queue[object]]::new()
    foreach ($inputItem in $Items) {
        if ($null -ne $inputItem) { $pendingItems.Enqueue($inputItem) }
    }

    while ($pendingItems.Count -gt 0) {
        $item = $pendingItems.Dequeue()
        if ($null -eq $item) { continue }
        $computerName = Get-WorkerUpdateField -Update $item -Names @('ComputerName', 'PSComputerName')
        $status = Get-WorkerUpdateField -Update $item -Names @('Status', 'Result', 'UpdateStatus')
        $kb = Get-WorkerUpdateField -Update $item -Names @('KB', 'KBArticleID', 'KBArticleIDs')
        $size = Get-WorkerUpdateField -Update $item -Names @('Size', 'MaxDownloadSize')
        $title = Get-WorkerUpdateField -Update $item -Names @('Title', 'UpdateTitle', 'Name')
        if ([string]::IsNullOrWhiteSpace([string]$status) -and
            [string]::IsNullOrWhiteSpace([string]$kb) -and
            [string]::IsNullOrWhiteSpace([string]$size) -and
            [string]::IsNullOrWhiteSpace([string]$title)) {
            # PSWindowsUpdate kann unter SYSTEM mehrere Updates als ein
            # verschachteltes Collection-Objekt zurückgeben. Dessen einzelne
            # Einträge müssen vor der Zeilenumwandlung aufgefächert werden.
            if ($item -is [System.Collections.IEnumerable] -and $item -isnot [string]) {
                foreach ($nestedItem in $item) {
                    if ($null -ne $nestedItem) { $pendingItems.Enqueue($nestedItem) }
                }
            }
            continue
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$kb)) {
            $kb = (@(([string]$kb -split ',\s*') | ForEach-Object { if ($_ -match '^KB') { $_ } else { "KB$_" } }) -join ', ')
        }
        if ([string]::IsNullOrWhiteSpace([string]$computerName)) { $computerName = $env:COMPUTERNAME }
        [PSCustomObject]@{ ComputerName = $computerName; Status = $status; KB = $kb; Size = $size; Title = $title }
    }
}
try {
    Import-Module PSWindowsUpdate -ErrorAction Stop
    if ($config.Mode -eq 'RemoveDeferredTask') {
        $deferredTaskName = 'WindowsUpdateAdm-DeferredUpdates'
        $removed = $false
        $scheduledTaskRemovalAvailable = (Get-Command -Name Get-ScheduledTask -ErrorAction SilentlyContinue) -and
            (Get-Command -Name Unregister-ScheduledTask -ErrorAction SilentlyContinue)
        if ($scheduledTaskRemovalAvailable) {
            if (Get-ScheduledTask -TaskName $deferredTaskName -ErrorAction SilentlyContinue) {
                Unregister-ScheduledTask -TaskName $deferredTaskName -Confirm:$false -ErrorAction Stop
                $removed = $true
            }
        } else {
            # Windows 7 kann ohne ScheduledTasks-Modul nur über schtasks.exe bereinigen.
            $schtasks = Join-Path $env:windir 'System32\schtasks.exe'
            foreach ($name in @($deferredTaskName, ($deferredTaskName + '-AtStartup'))) {
                & $schtasks /Query /TN $name *> $null
                if ($LASTEXITCODE -eq 0) {
                    & $schtasks /Delete /TN $name /F *> $null
                    if ($LASTEXITCODE -eq 0) { $removed = $true }
                }
            }
        }
        Remove-Item -LiteralPath (Join-Path (Join-Path $env:ProgramData 'WindowsUpdateAdm') 'DeferredUpdates.ps1') -Force -ErrorAction SilentlyContinue
        $updates = @([PSCustomObject]@{ Removed = $removed })
    }
    elseif ($config.Mode -eq 'RebootStatus') {
        $rebootStatus = Get-WURebootStatus -Silent -ErrorAction Stop
        $rebootRequired = if ($rebootStatus -is [bool]) { $rebootStatus } elseif ($null -ne $rebootStatus -and $null -ne $rebootStatus.PSObject.Properties['RebootRequired']) { [bool]$rebootStatus.RebootRequired } else { $false }
        $updates = @([PSCustomObject]@{ RebootRequired = [bool]$rebootRequired })
    }
    else {
        $wuParams = @{}
        switch ($config.Mode) {
            # AcceptAll bestätigt nur etwaige Rückfragen. Es löst weder einen
            # Download noch eine Installation aus und verhindert leere
            # Ergebnisse der nichtinteraktiven SYSTEM-Suche auf älteren Servern.
            'Check'    { $wuParams.AcceptAll = $true }
            'Download' { $wuParams.AcceptAll = $true; $wuParams.Download = $true }
            'Install'  { $wuParams.AcceptAll = $true; $wuParams.Install = $true; $wuParams.IgnoreReboot = $true }
        }
        if ([bool]$config.SearchOnline) { $wuParams.MicrosoftUpdate = $true }
        $categories = @($config.DeferredCategories | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        $kbs = @($config.DeferredKBs | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ([bool]$config.DeferredOnly) {
            # KBs und Kategorien werden gemeinsam geprüft. Eine konfigurierte
            # Kategorie darf nicht durch eine zusätzlich eingetragene KB-Liste
            # unterdrückt werden.
            $rawUpdates = @()
            foreach ($kb in $kbs) { $rawUpdates += @(Get-WindowsUpdate @wuParams -KBArticleID $kb) }
            foreach ($category in $categories) { $rawUpdates += @(Get-WindowsUpdate @wuParams -Category $category) }
            $updates = @(ConvertTo-WorkerUpdateRows -Items $rawUpdates)
        }
        else {
            if ($config.Mode -eq 'Install') {
                if ($categories.Count -gt 0) { $wuParams.NotCategory = $categories }
                if ($kbs.Count -gt 0) { $wuParams.NotKBArticleID = $kbs }
            }
            $rawUpdates = @(Get-WindowsUpdate @wuParams)
            $updates = @(ConvertTo-WorkerUpdateRows -Items $rawUpdates)
        }
    }
    $result = [ordered]@{ Success = $true; Error = ''; Updates = @($updates) }
}
catch {
    $result = [ordered]@{ Success = $false; Error = $_.Exception.Message; Updates = @() }
}
finally {
    New-Item -ItemType Directory -Path (Split-Path -Parent $config.ResultPath) -Force | Out-Null
    [IO.File]::WriteAllText($config.ResultPath, ($result | ConvertTo-Json -Depth 6 -Compress), [Text.Encoding]::UTF8)
    try {
        # schtasks ist auch auf Windows 7 vorhanden und entfernt die temporäre Task plattformübergreifend.
        $schtasks = Join-Path $env:windir 'System32\schtasks.exe'
        & $schtasks /Delete /TN $config.TaskName /F *> $null
    } catch { }
    Remove-Item -LiteralPath $config.WorkerPath -Force -ErrorAction SilentlyContinue
}
'@
    $worker = $worker.Replace('__CONFIG__', $config64)

    $register = {
        param($Name, $WorkerPath, $ResultPath, $Worker)
        New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerPath) -Force | Out-Null
        Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($WorkerPath, $Worker, [Text.Encoding]::UTF8)
        $scheduledTaskCmdletsAvailable = (Get-Command -Name New-ScheduledTaskAction -ErrorAction SilentlyContinue) -and
            (Get-Command -Name New-ScheduledTaskTrigger -ErrorAction SilentlyContinue) -and
            (Get-Command -Name New-ScheduledTaskPrincipal -ErrorAction SilentlyContinue) -and
            (Get-Command -Name Register-ScheduledTask -ErrorAction SilentlyContinue) -and
            (Get-Command -Name Start-ScheduledTask -ErrorAction SilentlyContinue)
        if ($scheduledTaskCmdletsAvailable) {
            $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WorkerPath`""
            $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)
            $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
            Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
            Start-ScheduledTask -TaskName $Name
        } else {
            # Auf Windows 7 die temporäre SYSTEM-Aufgabe mit schtasks.exe anlegen und starten.
            $schtasks = Join-Path $env:windir 'System32\schtasks.exe'
            $runAt = (Get-Date).AddMinutes(10)
            $date = $runAt.ToString('MM/dd/yyyy', [Globalization.CultureInfo]::InvariantCulture)
            $time = $runAt.ToString('HH:mm', [Globalization.CultureInfo]::InvariantCulture)
            $taskCommand = 'powershell.exe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}"' -f $WorkerPath
            $createOutput = & $schtasks /Create /TN $Name /SC ONCE /SD $date /ST $time /RU SYSTEM /RL HIGHEST /TR $taskCommand /F 2>&1
            if ($LASTEXITCODE -ne 0) { throw "SYSTEM-Aufgabe konnte mit schtasks.exe nicht erstellt werden: $((@($createOutput) -join ' ').Trim())" }
            $runOutput = & $schtasks /Run /TN $Name 2>&1
            if ($LASTEXITCODE -ne 0) { throw "SYSTEM-Aufgabe konnte mit schtasks.exe nicht gestartet werden: $((@($runOutput) -join ' ').Trim())" }
        }
    }
    $params = New-WindowsUpdateInvokeCommandParams -ComputerName $TargetComputer -AuthInfo $AuthInfo -OperationTimeoutSeconds $TimeoutSeconds
    $params.ScriptBlock = $register
    $params.ArgumentList = @($taskName, $workerPath, $resultPath, $worker)
    # Check, Download und Installation werden vom jeweiligen Einstiegsskript
    # angekündigt. Die generische Meldung wäre dort eine redundante Dopplung.
    if ($Mode -notin @('Check', 'Download', 'Install')) {
        Write-CommonLog $WriteLog "Windows Update auf $TargetComputer läuft als temporäre SYSTEM-Aufgabe ($Mode)."
    }
    Invoke-WindowsUpdateWithRetry -OperationName "SYSTEM-Update-Aufgabe auf $TargetComputer" -WriteLog $WriteLog -ScriptBlock { Invoke-Command @params | Out-Null }

    $reader = { param($Path) if (Test-Path -LiteralPath $Path) { Get-Content -LiteralPath $Path -Raw -Encoding UTF8 } }
    $readParams = New-WindowsUpdateInvokeCommandParams -ComputerName $TargetComputer -AuthInfo $AuthInfo -OperationTimeoutSeconds 120
    $readParams.ScriptBlock = $reader; $readParams.ArgumentList = $resultPath
    $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
    do {
        Start-Sleep -Seconds $PollSeconds
        $raw = Invoke-Command @readParams
        if (-not [string]::IsNullOrWhiteSpace([string]$raw)) {
            try { $result = ([string]$raw | ConvertFrom-Json -ErrorAction Stop) } catch { $result = $null }
            if ($result) {
                $cleanup = { param($Path) Remove-Item -LiteralPath $Path -Force -ErrorAction SilentlyContinue }
                $cleanupParams = New-WindowsUpdateInvokeCommandParams -ComputerName $TargetComputer -AuthInfo $AuthInfo
                $cleanupParams.ScriptBlock = $cleanup; $cleanupParams.ArgumentList = $resultPath
                Invoke-Command @cleanupParams | Out-Null
                if (-not [bool]$result.Success) { throw "Windows Update als SYSTEM auf $TargetComputer fehlgeschlagen: $($result.Error)" }
                return @($result.Updates)
            }
        }
    } while ((Get-Date) -lt $deadline)
    throw "Windows Update als SYSTEM auf $TargetComputer hat innerhalb von $TimeoutSeconds Sekunden kein Ergebnis geliefert. Die Aufgabe beendet und löscht sich nach Abschluss selbst."
}

function Invoke-WindowsUpdateWithRetry {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [string]$OperationName = 'Remote-Operation',
        [ValidateRange(1, 10)][int]$RetryCount = 3,
        [ValidateRange(0, 300)][int]$RetryDelaySeconds = 10,
        [scriptblock]$WriteLog
    )

    $lastError = $null
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        try {
            $result = & $ScriptBlock
            return $result
        }
        catch {
            $lastError = $_
            if ($WriteLog) {
                & $WriteLog "WARNUNG: $OperationName fehlgeschlagen (Versuch $attempt von $RetryCount); Details im Log."
                Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation $OperationName -ErrorRecord $_ -Context @("Attempt=$attempt/$RetryCount")
            }
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
                if ($WriteLog) { & $WriteLog "Wiederhole $OperationName in $RetryDelaySeconds Sekunden..." }
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }
    throw $lastError
}

function Invoke-WindowsUpdateRemoteCommandWithTimeout {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [Parameter(Mandatory)][string]$OperationName,
        [scriptblock]$WriteLog
    )

    $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo
    $invokeParameters.ScriptBlock = $ScriptBlock
    if ($ArgumentList.Count -gt 0) { $invokeParameters.ArgumentList = $ArgumentList }
    $invokeParameters.AsJob = $true
    $job = $null
    try {
        $job = Invoke-Command @invokeParameters
        $completedJob = Wait-Job -Job $job -Timeout $TimeoutSeconds
        if (-not $completedJob) {
            $timeoutDetails = [System.Collections.Generic.List[string]]::new()
            try { $null = Stop-Job -Job $job -ErrorAction Stop }
            catch { $timeoutDetails.Add("Stop-Job fehlgeschlagen: $($_.Exception.ToString())") }
            try {
                $partialOutput = (@(Receive-Job -Job $job -ErrorAction SilentlyContinue | Out-String -Width 400) -join '').Trim()
                if ($partialOutput.Length -gt 3000) { $partialOutput = $partialOutput.Substring(0, 3000) + ' … [gekürzt]' }
                if (-not [string]::IsNullOrWhiteSpace($partialOutput)) { $timeoutDetails.Add("Teilausgabe vor dem Zeitlimit: $partialOutput") }
            }
            catch { $timeoutDetails.Add("Teilausgabe konnte nicht gelesen werden: $($_.Exception.ToString())") }
            $detailText = $timeoutDetails -join [Environment]::NewLine
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation $OperationName -Target $ComputerName -DiagnosticText $detailText -Context "Zeitlimit=${TimeoutSeconds}s; JobStatus=$($job.State)"
            throw [System.TimeoutException]::new("$OperationName hat das Zeitlimit von $TimeoutSeconds Sekunden überschritten. $detailText")
        }
        if ($job.State -ne 'Completed') {
            $reason = @($job.ChildJobs | ForEach-Object { $_.JobStateInfo.Reason.Message } | Where-Object { $_ }) -join '; '
            if ([string]::IsNullOrWhiteSpace($reason)) { $reason = "Remoting-Aufgabe endete mit Status '$($job.State)'" }
            throw $reason
        }
        return @(Receive-Job -Job $job -ErrorAction Stop)
    }
    finally {
        if ($job) {
            if ($job.State -in @('Running', 'NotStarted')) {
                try { $null = Stop-Job -Job $job -ErrorAction Stop }
                catch { Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation "${OperationName}: Job stoppen" -Target $ComputerName -ErrorRecord $_ -Context "JobStatus=$($job.State)" }
            }
            try { Remove-Job -Job $job -Force -ErrorAction Stop }
            catch { Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation "${OperationName}: Job entfernen" -Target $ComputerName -ErrorRecord $_ -Context "JobStatus=$($job.State)" }
        }
    }
}

function Invoke-WindowsUpdateLocalCommandWithTimeout {
    param(
        [Parameter(Mandatory)][scriptblock]$ScriptBlock,
        [object[]]$ArgumentList = @(),
        [ValidateRange(1, 3600)][int]$TimeoutSeconds = 300,
        [switch]$NoTimeout,
        [Parameter(Mandatory)][string]$OperationName
    )

    $powerShell51 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $powerShell51 -PathType Leaf)) {
        throw 'Windows PowerShell 5.1 wurde für die lokale WinGet-Prüfung nicht gefunden.'
    }
    $temporaryRoot = Join-Path ([IO.Path]::GetTempPath()) ('ServerUpdate-WinGet-{0}' -f [guid]::NewGuid().ToString('N'))
    $payloadPath = Join-Path $temporaryRoot 'payload.json'
    $runnerPath = Join-Path $temporaryRoot 'run.ps1'
    $responsePath = Join-Path $temporaryRoot 'response.json'
    $stdoutPath = Join-Path $temporaryRoot 'stdout.log'
    $stderrPath = Join-Path $temporaryRoot 'stderr.log'
    $process = $null
    try {
        New-Item -ItemType Directory -Path $temporaryRoot -Force -ErrorAction Stop | Out-Null
        $payload = ConvertTo-Json -InputObject @{
            Script = $ScriptBlock.ToString()
            ArgumentList = @($ArgumentList)
        } -Depth 20 -Compress
        [IO.File]::WriteAllText($payloadPath, $payload, [Text.UTF8Encoding]::new($false))
        $runnerSource = @'
param([Parameter(Mandatory)][string]$PayloadPath, [Parameter(Mandatory)][string]$ResponsePath)
$ErrorActionPreference = 'Stop'
try {
    # Payload is written as UTF-8 without a BOM. Windows PowerShell 5.1 otherwise
    # reads it with the legacy ANSI code page and corrupts non-ASCII script text.
    $payload = Get-Content -LiteralPath $PayloadPath -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
    $runnerArguments = @($payload.ArgumentList)
    $items = @(& ([scriptblock]::Create([string]$payload.Script)) @runnerArguments)
    $response = @{ Success = $true; Results = @($items) }
}
catch {
    $errorRecord = $_
    $response = @{
        Success = $false
        Error = [string]$errorRecord.Exception.Message
        ErrorId = [string]$errorRecord.FullyQualifiedErrorId
        Category = [string]$errorRecord.CategoryInfo.Category
        Position = if ($errorRecord.InvocationInfo) { [string]$errorRecord.InvocationInfo.PositionMessage } else { '' }
        ScriptStackTrace = [string]$errorRecord.ScriptStackTrace
        ExceptionType = [string]$errorRecord.Exception.GetType().FullName
        Results = @()
    }
}
[IO.File]::WriteAllText($ResponsePath, (ConvertTo-Json -InputObject $response -Depth 20 -Compress), [Text.UTF8Encoding]::new($false))
'@
        [IO.File]::WriteAllText($runnerPath, $runnerSource, [Text.UTF8Encoding]::new($false))
        $processArguments = '-NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "{0}" -PayloadPath "{1}" -ResponsePath "{2}"' -f $runnerPath, $payloadPath, $responsePath
        $process = Start-Process -FilePath $powerShell51 -ArgumentList $processArguments -PassThru -WindowStyle Hidden `
            -RedirectStandardOutput $stdoutPath -RedirectStandardError $stderrPath -ErrorAction Stop
        if ($NoTimeout) {
            $process.WaitForExit()
        } elseif (-not $process.WaitForExit($TimeoutSeconds * 1000)) {
            $timeoutDetails = [System.Collections.Generic.List[string]]::new()
            try { $process.Kill() }
            catch { $timeoutDetails.Add("Prozess konnte nicht beendet werden: $($_.Exception.Message)") }
            try {
                if (-not $process.WaitForExit(10000)) { $timeoutDetails.Add('Prozess war auch 10 Sekunden nach dem Abbruch noch aktiv.') }
            }
            catch { $timeoutDetails.Add("Prozessende konnte nicht bestätigt werden: $($_.Exception.Message)") }
            foreach ($streamPath in @($stdoutPath, $stderrPath)) {
                if (-not (Test-Path -LiteralPath $streamPath -PathType Leaf)) { continue }
                try {
                    $streamText = (Get-Content -LiteralPath $streamPath -Raw -ErrorAction Stop).Trim()
                    if (-not [string]::IsNullOrWhiteSpace($streamText)) {
                        if ($streamText.Length -gt 3000) { $streamText = $streamText.Substring(0, 3000) + ' … [gekürzt]' }
                        $streamName = if ($streamPath -eq $stdoutPath) { 'Ausgabe' } else { 'Fehlerausgabe' }
                        $timeoutDetails.Add("$streamName vor dem Zeitlimit: $streamText")
                    }
                }
                catch { $timeoutDetails.Add("$streamPath konnte nach dem Zeitlimit nicht gelesen werden: $($_.Exception.Message)") }
            }
            $detailText = if ($timeoutDetails.Count -gt 0) { ' ' + ($timeoutDetails -join ' ') } else { '' }
            throw [System.TimeoutException]::new("$OperationName hat das Zeitlimit von $TimeoutSeconds Sekunden überschritten.$detailText")
        }

        if (-not (Test-Path -LiteralPath $responsePath -PathType Leaf)) {
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
            throw "$OperationName lieferte keine strukturierte Rückgabe (Exitcode $($process.ExitCode)). $stdout $stderr"
        }
        $response = Get-Content -LiteralPath $responsePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
        if (-not $response.Success) {
            $stdout = if (Test-Path -LiteralPath $stdoutPath) { (Get-Content -LiteralPath $stdoutPath -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
            $stderr = if (Test-Path -LiteralPath $stderrPath) { (Get-Content -LiteralPath $stderrPath -Raw -ErrorAction SilentlyContinue).Trim() } else { '' }
            $failureDetails = @(
                "$OperationName fehlgeschlagen. Ursache: $([string]$response.Error)"
                "Fehlertyp: $([string]$response.ExceptionType); ErrorId: $([string]$response.ErrorId); Kategorie: $([string]$response.Category)"
                "Position: $([string]$response.Position)"
                "Stacktrace: $([string]$response.ScriptStackTrace)"
                "Ausgabe: $stdout"
                "Fehlerausgabe: $stderr"
            ) -join [Environment]::NewLine
            throw $failureDetails
        }
        return @($response.Results)
    }
    finally {
        if ($process) { $process.Dispose() }
        Remove-Item -LiteralPath $temporaryRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Reset-WindowsUpdateLocalWinGetSources {
    param([ValidateRange(1, 3600)][int]$TimeoutSeconds = 300, [scriptblock]$WriteLog)
    # Quellenreset wie jede andere WinGet-Aktion im Zielkontext ausführen;
    # der lokale Start-Process-Worker löste denselben WinGet-COM-Fehler aus.
    return Reset-WindowsUpdateRemoteWinGetSources -ComputerName $env:COMPUTERNAME `
        -TimeoutSeconds $TimeoutSeconds -WriteLog $WriteLog
}
