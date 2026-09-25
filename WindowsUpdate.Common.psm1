Set-StrictMode -Version Latest

function Write-CommonLog {
    param(
        [scriptblock]$WriteLog,
        [string]$Message
    )

    if ($WriteLog) { & $WriteLog $Message }
}

function Initialize-WindowsUpdateDpapi {
    if ('System.Security.Cryptography.ProtectedData' -as [type]) { return }
    try { Add-Type -AssemblyName System.Security.Cryptography.ProtectedData -ErrorAction Stop }
    catch { Add-Type -AssemblyName System.Security -ErrorAction Stop }
}

function Protect-WindowsUpdateMailPassword {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Password)
    Initialize-WindowsUpdateDpapi
    $plainBytes = [Text.Encoding]::UTF8.GetBytes($Password)
    try {
        $protectedBytes = [Security.Cryptography.ProtectedData]::Protect(
            $plainBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
        return 'DPAPI:' + [Convert]::ToBase64String($protectedBytes)
    }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

function Unprotect-WindowsUpdateMailPassword {
    param([Parameter(Mandatory)][string]$ProtectedPassword)
    if (-not $ProtectedPassword.StartsWith('DPAPI:', [StringComparison]::Ordinal)) {
        throw 'Das Mailpasswort liegt noch unverschlüsselt vor und konnte nicht migriert werden.'
    }
    Initialize-WindowsUpdateDpapi
    $cipherBytes = [Convert]::FromBase64String($ProtectedPassword.Substring(6))
    $plainBytes = [Security.Cryptography.ProtectedData]::Unprotect(
        $cipherBytes, $null, [Security.Cryptography.DataProtectionScope]::LocalMachine)
    try { return [Text.Encoding]::UTF8.GetString($plainBytes) }
    finally { [Array]::Clear($plainBytes, 0, $plainBytes.Length) }
}

function Write-WindowsUpdateJsonAtomically {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)]$Value)
    $temporaryPath = '{0}.{1}.tmp' -f $Path, [guid]::NewGuid().ToString('N')
    try {
        $json = ConvertTo-Json -InputObject $Value -Depth 100
        [IO.File]::WriteAllText($temporaryPath, $json, [Text.UTF8Encoding]::new($false))
        if (Test-Path -LiteralPath $Path -PathType Leaf) {
            $moveWithOverwrite = [IO.File].GetMethod('Move', [type[]]@([string], [string], [bool]))
            if ($null -ne $moveWithOverwrite) {
                # PowerShell 7/.NET Core unterstützt atomaren Austausch direkt.
                [IO.File]::Move($temporaryPath, $Path, $true)
            }
            else {
                # Windows PowerShell 5.1/.NET Framework verlangt einen Backup-Pfad.
                # Die alte Datei kann das bisherige Klartextpasswort enthalten und
                # wird nach dem atomaren Austausch sofort wieder entfernt.
                $replaceBackupPath = $temporaryPath + '.replace.bak'
                try { [IO.File]::Replace($temporaryPath, $Path, $replaceBackupPath) }
                finally {
                    if (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf) { [IO.File]::Delete($replaceBackupPath) }
                }
            }
        }
        else { [IO.File]::Move($temporaryPath, $Path) }
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath -PathType Leaf) {
            Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
        }
    }
}

function Protect-WindowsUpdateSettingsFilePassword {
    param([Parameter(Mandatory)][string]$Path, [scriptblock]$WriteLog)
    $raw = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    $document = $raw | ConvertFrom-Json -ErrorAction Stop
    $mailProperty = $document.PSObject.Properties['MailSettings']
    $passwordProperty = if ($mailProperty -and $mailProperty.Value) { $mailProperty.Value.PSObject.Properties['AuthPass'] } else { $null }
    if ($passwordProperty -and -not [string]::IsNullOrEmpty([string]$passwordProperty.Value) -and
        -not ([string]$passwordProperty.Value).StartsWith('DPAPI:', [StringComparison]::Ordinal)) {
        $protectedPassword = Protect-WindowsUpdateMailPassword -Password ([string]$passwordProperty.Value)
        Add-Member -InputObject $mailProperty.Value -NotePropertyName AuthPass -NotePropertyValue $protectedPassword -Force

        # Sicherungen bleiben gültige JSON-Dateien, enthalten aber ebenfalls nur
        # das maschinengebundene DPAPI-Geheimnis und keinen Klartext des Passworts.
        $backupPath = '{0}.bak.{1}_{2}' -f $Path, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        Write-WindowsUpdateJsonAtomically -Path $backupPath -Value $document
        Write-WindowsUpdateJsonAtomically -Path $Path -Value $document
        Write-CommonLog $WriteLog "Mailpasswort in '$([IO.Path]::GetFileName($Path))' automatisch mit DPAPI geschützt."
    }

    # Ältere automatisch erzeugte Sicherungen derselben Datei ebenfalls
    # schützen, damit nach der Migration keine Klartextkopie liegen bleibt.
    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    foreach ($oldBackup in @(Get-ChildItem -LiteralPath $directory -Filter ($leaf + '.bak.*') -File -ErrorAction SilentlyContinue)) {
        try {
            $oldDocument = Get-Content -LiteralPath $oldBackup.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            $oldMail = $oldDocument.PSObject.Properties['MailSettings']
            $oldPassword = if ($oldMail -and $oldMail.Value) { $oldMail.Value.PSObject.Properties['AuthPass'] } else { $null }
            if ($oldPassword -and -not [string]::IsNullOrEmpty([string]$oldPassword.Value) -and
                -not ([string]$oldPassword.Value).StartsWith('DPAPI:', [StringComparison]::Ordinal)) {
                $oldCipher = Protect-WindowsUpdateMailPassword -Password ([string]$oldPassword.Value)
                Add-Member -InputObject $oldMail.Value -NotePropertyName AuthPass -NotePropertyValue $oldCipher -Force
                Write-WindowsUpdateJsonAtomically -Path $oldBackup.FullName -Value $oldDocument
            }
        }
        catch { throw "Eine ältere Settings-Sicherung konnte nicht geschützt werden ('$($oldBackup.Name)'). Der Lauf wird abgebrochen, damit kein Klartextpasswort zurückbleibt." }
    }

    # Die bestehende Aufbewahrungsregel gilt auch für die Migrationssicherung.
    $allBackups = @(Get-ChildItem -LiteralPath $directory -Filter '*.json.bak.*' -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^(?:settings|.+\.settings)\.json\.bak\.\d{8}_\d{6}_\d{3}(?:_[a-f0-9]{8})?$' } |
        Sort-Object -Property LastWriteTimeUtc, Name -Descending)
    foreach ($oldBackup in @($allBackups | Select-Object -Skip 3)) {
        Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction SilentlyContinue
    }
}

function Get-WindowsUpdateSettings {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ScriptName,
        [string]$DefaultSettingsJson,
        [scriptblock]$WriteLog
    )

    if ([string]::IsNullOrWhiteSpace($DefaultSettingsJson)) {
        $defaultSettingsPath = Join-Path $ScriptRoot 'default_settings.json'
        if (Test-Path -LiteralPath $defaultSettingsPath) {
            $DefaultSettingsJson = Get-Content -LiteralPath $defaultSettingsPath -Raw -Encoding UTF8
            Write-CommonLog $WriteLog "Lese Standard-Einstellungen aus $defaultSettingsPath"
        }
        else {
            # Eine vollständige settings.json ist ausdrücklich ausreichend.
            # Die Default-Datei ist eine optionale Vorlage, keine Pflicht.
            $DefaultSettingsJson = '{}'
            Write-CommonLog $WriteLog "Keine default_settings.json vorhanden – verwende vorhandene settings.json direkt."
        }
    }

    $settings = $DefaultSettingsJson | ConvertFrom-Json
    $defaultMailSettingsProperty = $settings.PSObject.Properties['MailSettings']
    $defaultAuthPassProperty = if ($defaultMailSettingsProperty -and $defaultMailSettingsProperty.Value) { $defaultMailSettingsProperty.Value.PSObject.Properties['AuthPass'] } else { $null }
    if ($defaultAuthPassProperty -and -not [string]::IsNullOrEmpty([string]$defaultAuthPassProperty.Value) -and
        -not ([string]$defaultAuthPassProperty.Value).StartsWith('DPAPI:', [StringComparison]::Ordinal)) {
        throw 'Die Standard-Einstellungen enthalten ein Mailpasswort. Lege MailSettings.AuthPass ausschließlich in einer lokalen settings.json ab.'
    }
    $scriptSettingsPath = Join-Path $ScriptRoot "$ScriptName.settings.json"
    $generalSettingsPath = Join-Path $ScriptRoot 'settings.json'
    $settingsFromFiles = @()

    # Alle allgemeinen und skriptspezifischen Kundendateien migrieren, nicht nur
    # die gerade verwendete Datei. Versionierte Standarddateien bleiben unberührt.
    $localSettingsPaths = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf) { $localSettingsPaths.Add($generalSettingsPath) }
    foreach ($settingsFile in @(Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.settings.json' -File -ErrorAction SilentlyContinue)) {
        if (-not $localSettingsPaths.Contains($settingsFile.FullName)) { $localSettingsPaths.Add($settingsFile.FullName) }
    }
    foreach ($localSettingsPath in $localSettingsPaths) {
        if (Test-Path -LiteralPath $localSettingsPath -PathType Leaf) {
            Protect-WindowsUpdateSettingsFilePassword -Path $localSettingsPath -WriteLog $WriteLog
        }
    }

    # Allgemeine Einstellungen bilden die Basis; eine gleichnamige Skript-JSON
    # überschreibt anschließend nur ihre angegebenen Werte.
    if (Test-Path -LiteralPath $generalSettingsPath) {
        Write-CommonLog $WriteLog "Lese Einstellungen aus $generalSettingsPath"
        $settingsFromFiles += Get-Content -LiteralPath $generalSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    if (Test-Path -LiteralPath $scriptSettingsPath) {
        Write-CommonLog $WriteLog "Lese skriptspezifische Einstellungen aus $scriptSettingsPath"
        $settingsFromFiles += Get-Content -LiteralPath $scriptSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json
    }

    foreach ($settingsFromFile in $settingsFromFiles) {
        foreach ($sectionName in @('UpdateSettings', 'MailSettings', 'LinuxSettings', 'HomeAssistantSettings')) {
            $sourceProperty = $settingsFromFile.PSObject.Properties[$sectionName]
            if ($null -eq $sourceProperty) { continue }
            $sourceSection = $sourceProperty.Value
            if ($null -eq $sourceSection) { continue }

            $settingNames = @($settings.PSObject.Properties | ForEach-Object { $_.Name })
            if ($settingNames -notcontains $sectionName) {
                Add-Member -InputObject $settings -NotePropertyName $sectionName -NotePropertyValue ([PSCustomObject]@{})
            }
            $targetSection = $settings.$sectionName
            foreach ($property in $sourceSection.PSObject.Properties) {
                Add-Member -InputObject $targetSection -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force
            }
        }
    }

    $finalSettingNames = @($settings.PSObject.Properties | ForEach-Object { $_.Name })
    if ($finalSettingNames -notcontains 'UpdateSettings') {
        throw "Es wurde keine UpdateSettings-Konfiguration gefunden. Lege mindestens eine settings.json im Skriptordner ab."
    }
    if ($finalSettingNames -contains 'MailSettings') {
        $mailSettingNames = @($settings.MailSettings.PSObject.Properties | ForEach-Object { $_.Name })
        if ($mailSettingNames -notcontains 'MailCC') { Add-Member -InputObject $settings.MailSettings -NotePropertyName MailCC -NotePropertyValue $settings.MailSettings.MailTo }
        elseif ([string]::IsNullOrEmpty($settings.MailSettings.MailCC)) { $settings.MailSettings.MailCC = $settings.MailSettings.MailTo }
        if ($mailSettingNames -notcontains 'MailBCC') { Add-Member -InputObject $settings.MailSettings -NotePropertyName MailBCC -NotePropertyValue $settings.MailSettings.MailTo }
        elseif ([string]::IsNullOrEmpty($settings.MailSettings.MailBCC)) { $settings.MailSettings.MailBCC = $settings.MailSettings.MailTo }
        $mailPasswordProperty = $settings.MailSettings.PSObject.Properties['AuthPass']
        $mailPassword = if ($mailPasswordProperty) { [string]$mailPasswordProperty.Value } else { '' }
        if (-not [string]::IsNullOrEmpty($mailPassword)) {
            if (-not $mailPassword.StartsWith('DPAPI:', [StringComparison]::Ordinal)) {
                throw 'MailSettings.AuthPass ist nach der Settings-Migration noch unverschlüsselt. Prüfe, ob das Skript die lokale settings.json schreiben darf.'
            }
            $settings.MailSettings.AuthPass = Unprotect-WindowsUpdateMailPassword -ProtectedPassword $mailPassword
        }
    }
    return $settings
}

function Get-WindowsUpdateClientCertificateAuthInfo {
    param(
        [Parameter(Mandatory)]$UpdateSettings,
        [Parameter(Mandatory)][string]$TargetComputer,
        [scriptblock]$WriteLog
    )

    $thumbprint = $UpdateSettings.ClientCertThumbprint
    $certificate = $null
    if ([string]::IsNullOrWhiteSpace($thumbprint)) {
        $certificate = Get-ChildItem 'Cert:\CurrentUser\My' |
            Where-Object { $_.Subject -eq "CN=WinRM-UpdateClient-$env:COMPUTERNAME" -and $_.NotAfter -gt (Get-Date) } |
            Sort-Object NotAfter -Descending |
            Select-Object -First 1
        if ($certificate) { $thumbprint = $certificate.Thumbprint }
    }

    if (-not [string]::IsNullOrWhiteSpace($thumbprint)) {
        if ($null -eq $certificate) {
            $certificate = Get-ChildItem 'Cert:\CurrentUser\My' |
                Where-Object { $_.Thumbprint -eq $thumbprint } |
                Select-Object -First 1
        }
        if ($certificate) {
            return [PSCustomObject]@{ Type = 'Certificate'; Thumbprint = $thumbprint }
        }
        Write-CommonLog $WriteLog "WARNUNG: Zertifikat mit Thumbprint '$thumbprint' nicht gefunden."
    }

    Write-CommonLog $WriteLog "WARNUNG: Kein gültiges Client-Zertifikat für '$TargetComputer' gefunden."
    return $null
}

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
            Write-CommonLog $WriteLog "INFO: '$TargetComputer' ist Windows Server 2016/2019 außerhalb der AD – nutze Zertifikats-Standardremoting plus SYSTEM-Aufgabe statt JEA für Windows Update."
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
    foreach ($item in $Items) {
        if ($null -eq $item) { continue }
        $computerName = Get-WorkerUpdateField -Update $item -Names @('ComputerName', 'PSComputerName')
        $status = Get-WorkerUpdateField -Update $item -Names @('Status', 'Result', 'UpdateStatus')
        $kb = Get-WorkerUpdateField -Update $item -Names @('KB', 'KBArticleID', 'KBArticleIDs')
        $size = Get-WorkerUpdateField -Update $item -Names @('Size', 'MaxDownloadSize')
        $title = Get-WorkerUpdateField -Update $item -Names @('Title', 'UpdateTitle', 'Name')
        if ([string]::IsNullOrWhiteSpace([string]$status) -and
            [string]::IsNullOrWhiteSpace([string]$kb) -and
            [string]::IsNullOrWhiteSpace([string]$size) -and
            [string]::IsNullOrWhiteSpace([string]$title)) { continue }
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
        if (Get-ScheduledTask -TaskName $deferredTaskName -ErrorAction SilentlyContinue) {
            Unregister-ScheduledTask -TaskName $deferredTaskName -Confirm:$false -ErrorAction Stop
            $removed = $true
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
            # Der reine Check fragt nur ab; AcceptAll und IgnoreReboot
            # gehören in die Download-/Installationspfade, nicht in die Suche.
            'Check'    { }
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
    try { Unregister-ScheduledTask -TaskName $config.TaskName -Confirm:$false -ErrorAction SilentlyContinue } catch { }
    Remove-Item -LiteralPath $config.WorkerPath -Force -ErrorAction SilentlyContinue
}
'@
    $worker = $worker.Replace('__CONFIG__', $config64)

    $register = {
        param($Name, $WorkerPath, $ResultPath, $Worker)
        New-Item -ItemType Directory -Path (Split-Path -Parent $WorkerPath) -Force | Out-Null
        Remove-Item -LiteralPath $ResultPath -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($WorkerPath, $Worker, [Text.Encoding]::UTF8)
        $action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -File `"$WorkerPath`""
        $trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(10)
        $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        Register-ScheduledTask -TaskName $Name -Action $action -Trigger $trigger -Principal $principal -Force | Out-Null
        Start-ScheduledTask -TaskName $Name
    }
    $params = New-WindowsUpdateInvokeCommandParams -ComputerName $TargetComputer -AuthInfo $AuthInfo -OperationTimeoutSeconds $TimeoutSeconds
    $params.ScriptBlock = $register
    $params.ArgumentList = @($taskName, $workerPath, $resultPath, $worker)
    Write-CommonLog $WriteLog "Windows Update auf $TargetComputer läuft als temporäre SYSTEM-Aufgabe ($Mode)."
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
            if ($WriteLog) { & $WriteLog "$OperationName fehlgeschlagen (Versuch $attempt von $RetryCount): $($_.Exception.Message)" }
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
                if ($WriteLog) { & $WriteLog "Wiederhole $OperationName in $RetryDelaySeconds Sekunden..." }
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
    }
    throw $lastError
}

function Get-WindowsUpdateSshArguments {
    param(
        [Parameter(Mandatory)][string]$KeyPath,
        [ValidateRange(1, 300)][int]$ConnectTimeoutSeconds = 15,
        [ValidateRange(1, 65535)][int]$Port = 22,
        [switch]$BatchMode,
        [switch]$AcceptNewHostKey
    )

    $arguments = @('-i', $KeyPath, '-p', $Port, '-o', "ConnectTimeout=$ConnectTimeoutSeconds", '-o', 'ConnectionAttempts=2', '-o', 'ServerAliveInterval=15', '-o', 'ServerAliveCountMax=4')
    if ($BatchMode) { $arguments += @('-o', 'BatchMode=yes') }
    if ($AcceptNewHostKey) { $arguments += @('-o', 'StrictHostKeyChecking=accept-new') }
    return $arguments
}

function Get-WindowsUpdateTargets {
    param(
        [Parameter(Mandatory)]$UpdateSettings,
        [Parameter(Mandatory)][string]$TargetComputers,
        [int]$PowerShellMajor = $PSVersionTable.PSVersion.Major,
        [scriptblock]$WriteLog
    )

    $adComputers = @()
    $localComputer = [PSCustomObject]@{ Name = $env:COMPUTERNAME }
    $isDomainJoined = $false

    try {
        $isDomainJoined = [bool](Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop).PartOfDomain
    }
    catch {
        Write-CommonLog $WriteLog "WARNUNG: Domänenstatus konnte nicht ermittelt werden: $($_.Exception.Message)"
    }

    if ($isDomainJoined) {
        try {
            if ($PowerShellMajor -ge 7) {
                Write-CommonLog $WriteLog "PowerShell $PowerShellMajor erkannt - Verwende Windows PowerShell Compatibility für ActiveDirectory"
                Import-Module ActiveDirectory -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
                Write-CommonLog $WriteLog 'ActiveDirectory-Modul erfolgreich über Windows PowerShell Compatibility geladen'
            }
            else {
                Import-Module ActiveDirectory -ErrorAction Stop
            }

            switch ($TargetComputers) {
                'All' {
                    Write-CommonLog $WriteLog 'Ziel: Alle Windows-Computer (Server + Clients)'
                    $adComputers = @(Get-ADComputer -Filter {(OperatingSystem -like '*Windows*') -and (Enabled -eq $true)} -Properties Name,OperatingSystem | Sort-Object Name)
                }
                default {
                    Write-CommonLog $WriteLog 'Ziel: Nur Windows Server'
                    $adComputers = @(Get-ADComputer -Filter {(OperatingSystem -like '*Windows*Server*') -and (Enabled -eq $true)} -Properties Name,OperatingSystem | Sort-Object Name)
                }
            }
        }
        catch {
            Write-CommonLog $WriteLog 'WARNUNG: ActiveDirectory-Modul konnte nicht geladen werden'
            Write-CommonLog $WriteLog "Fehlerdetails: $($_.Exception.Message)"
            Write-CommonLog $WriteLog 'Verarbeite nur lokalen Rechner!'
            $adComputers = @($localComputer)
        }
    }
    else {
        $adComputers = @($localComputer)
        Write-CommonLog $WriteLog 'Computer ist nicht in einer Domäne. Verarbeite nur lokalen Rechner.'
    }

    $targets = @()
    $knownNames = @()
    foreach ($computer in $adComputers) {
        if (($null -ne $computer.Name) -and (-not ($knownNames -contains ([string]$computer.Name)))) {
            $knownNames += [string]$computer.Name
            $targetObject = New-Object PSObject
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name Name -Value ([string]$computer.Name)
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name IsAdditional -Value $false
            Add-Member -InputObject $targetObject -MemberType NoteProperty -Name IsHypervisor -Value $false
            $targets += $targetObject
        }
    }

    $adAvailable = $null -ne (Get-Command Get-ADComputer -ErrorAction SilentlyContinue)
    foreach ($groupName in @('AdditionalComputers', 'HypervisorComputers')) {
        $isHypervisorGroup = $groupName -eq 'HypervisorComputers'
        $names = @($UpdateSettings.$groupName)
        $names = @($names | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
        if ($names.Count -eq 0) { continue }
        foreach ($configuredName in $names) {
            $computerName = ([string]$configuredName).Trim()
            $isInAd = $false
            if ($adAvailable) {
                try { $null = Get-ADComputer -Identity $computerName -ErrorAction Stop; $isInAd = $true }
                catch { $isInAd = $false }
            }
            if ($knownNames -notcontains $computerName) {
                $knownNames += $computerName
                $targets += [PSCustomObject]@{ Name = $computerName; IsAdditional = ((-not $isInAd) -and (-not $isHypervisorGroup)); IsHypervisor = ((-not $isInAd) -and $isHypervisorGroup) }
            }
        }
    }

    Write-CommonLog $WriteLog "Gesamtliste nach Zusammenführung: $($targets.Count) Gerät(e)"

    return @($targets)
}

function Invoke-WindowsUpdatePackageManagers {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        $AuthInfo,
        [ValidateSet('Check', 'Install')][string]$Mode = 'Check',
        [bool]$EnableWinget = $true,
        [bool]$EnableChocolatey = $true
    )

    # Der Block läuft lokal oder innerhalb der vorhandenen WinRM-Verbindung.
    # Er gibt ausschließlich strukturierte Daten zurück; Darstellung und Bericht
    # bleiben bei den aufrufenden Skripten.
    $packageScript = {
        param([string]$ExecutionMode, [bool]$UseWinget, [bool]$UseChocolatey)

        # Winget ist eine benutzerbezogene App-Installer-Anwendung. Im
        # LocalSystem-Kontext ist es nicht zuverlässig verfügbar und darf dort
        # daher weder gesucht noch ausgeführt werden.
        $isSystemContext = [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem

        function Resolve-WingetExecutable {
            # Zuerst den für den aktuellen Benutzer registrierten Befehl
            # verwenden. Der direkte Zugriff auf Program Files\WindowsApps
            # scheitert in Remoting-Sitzungen häufig mit "Zugriff verweigert".
            $command = Get-Command winget -ErrorAction SilentlyContinue
            if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source) -and (Test-Path -LiteralPath $command.Source)) {
                return $command.Source
            }
            $patterns = @(
                "$env:LOCALAPPDATA\Microsoft\WindowsApps\winget.exe",
                'C:\Program Files\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe',
                "$env:ProgramFiles\WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe"
            )
            foreach ($pattern in $patterns) {
                $candidate = Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1
                if ($candidate) { return $candidate.FullName }
            }
            return $null
        }

        # Kein generisches .NET-List-Objekt: PowerShell 7 kann dieses beim
        # Rückgabewert einer verschachtelten ScriptBlock-Ausführung fehlerhaft
        # binden ("Argument types do not match"). Ein normales PS-Array ist
        # für die wenigen Paketmanager-Ergebnisse vollkommen ausreichend.
        $result = @()
        $chocoPath = 'C:\ProgramData\chocolatey\bin\choco.exe'
        if (-not $UseChocolatey) {
            $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$false; Success=$true; Skipped=$true; SkipReason='per Konfiguration deaktiviert'; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }
        elseif (Test-Path -LiteralPath $chocoPath) {
            try {
                $availableOutput = & $chocoPath outdated --limit-output 2>&1 | Out-String
                $packages = @($availableOutput -split "`r?`n" | Where-Object { $_ -match '^[^|]+\|[^|]+\|[^|]+' } | ForEach-Object { ($_ -split '\|')[0].Trim() } | Select-Object -Unique)
                $actionOutput = ''
                $exitCode = 0
                if ($ExecutionMode -eq 'Install' -and $packages.Count -gt 0) {
                    $actionOutput = & $chocoPath upgrade all -y 2>&1 | Out-String
                    $exitCode = $LASTEXITCODE
                }
                $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$true; Success=($exitCode -eq 0); Skipped=$false; SkipReason=''; ExitCode=$exitCode; Packages=$packages; AvailableOutput=$availableOutput; ActionOutput=$actionOutput }
            }
            catch {
                $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput=$_.Exception.Message }
            }
        }
        else {
            $result += [PSCustomObject]@{ Manager='Chocolatey'; Available=$false; Success=$true; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }

        if (-not $UseWinget) {
            $result += [PSCustomObject]@{ Manager='Winget'; Available=$false; Success=$true; Skipped=$true; SkipReason='per Konfiguration deaktiviert'; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }
        elseif ($isSystemContext) {
            $result += [PSCustomObject]@{ Manager='Winget'; Available=$false; Success=$true; Skipped=$true; SkipReason='SYSTEM-Kontext (Winget ist benutzerbezogen)'; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
        }
        else {
            $wingetPath = Resolve-WingetExecutable
            if ($wingetPath) {
                try {
                $env:PROCESSOR_ARCHITECTURE = 'AMD64'
                $availableOutput = & $wingetPath upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
                # Winget liefert eine formatierte Tabelle. Echte Upgrade-Zeilen
                # enden mit ihrer Paketquelle (winget oder msstore); Status- und
                # Lizenztexte tun dies nicht. Das bleibt auch bei langen Namen
                # stabil, welche die Spaltenausrichtung verschieben können.
                $packageLines = @($availableOutput -split "`r?`n" | Where-Object {
                    $line = $_.Trim()
                    $line -match '\s(?:winget|msstore)\s*$' -and
                    $line -notmatch '^Name\s+'
                })
                $actionOutput = ''
                $exitCode = 0
                if ($ExecutionMode -eq 'Install' -and $packageLines.Count -gt 0) {
                    $actionOutput = & $wingetPath upgrade --all --silent --accept-package-agreements --accept-source-agreements --disable-interactivity 2>&1 | Out-String
                    $exitCode = $LASTEXITCODE
                }
                $noUpdateCodes = @(-1978335188, -1978335189, -1978335192)
                    $result += [PSCustomObject]@{ Manager='Winget'; Available=$true; Success=($exitCode -eq 0 -or $exitCode -in $noUpdateCodes); Skipped=$false; SkipReason=''; ExitCode=$exitCode; Packages=$packageLines; AvailableOutput=$availableOutput; ActionOutput=$actionOutput }
                }
                catch {
                    $result += [PSCustomObject]@{ Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput=$_.Exception.Message }
                }
            }
            else {
                $result += [PSCustomObject]@{ Manager='Winget'; Available=$false; Success=$true; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
            }
        }
        return @($result)
    }

    $localNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    if ($localNames -contains $ComputerName) {
        return @(& $packageScript $Mode $EnableWinget $EnableChocolatey)
    }

    $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo
    $invokeParameters.ScriptBlock = $packageScript
    $invokeParameters.ArgumentList = @($Mode, $EnableWinget, $EnableChocolatey)
    return @(Invoke-Command @invokeParameters)
}

function Invoke-WindowsUpdateFileRetention {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][int]$KeepFiles
    )

    $keep = [Math]::Max(1, $KeepFiles)
    $files = if (Test-Path -LiteralPath $Directory) {
        @(Get-ChildItem -LiteralPath $Directory -File -Filter $Filter -ErrorAction SilentlyContinue | Sort-Object LastWriteTime)
    } else { @() }
    # PowerShell entpackt Arrays mit genau einem Element bei einer Zuweisung.
    # Deshalb niemals direkt $files.Count verwenden.
    $fileCount = @($files).Count
    $removeCount = [Math]::Max(0, $fileCount - $keep)
    $removedFiles = @()
    $failedFiles = @()
    if ($removeCount -gt 0) { foreach ($file in @($files | Select-Object -First $removeCount)) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removedFiles += $file.FullName
        }
        catch {
            $failedFiles += [PSCustomObject]@{ Path = $file.FullName; Error = $_.Exception.Message }
        }
    } }

    return [PSCustomObject]@{
        ExistingCount = $fileCount
        RemovedFiles  = @($removedFiles)
        FailedFiles   = @($failedFiles)
    }
}

function Write-WindowsUpdateLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [bool]$WriteLogFile,
        [switch]$IsDebug,
        [bool]$DebugEnabled
    )

    if ($IsDebug -and -not $DebugEnabled) { return }
    $prefix = if ($IsDebug) { '[DEBUG] ' } else { '' }
    if ($IsDebug) { Write-Host "$prefix$Message" -ForegroundColor Cyan } else { Write-Host "$Message" }
    if (-not $WriteLogFile) { return }

    $logDirectory = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $LogFile)) { "Protokolldatei vom $RunTimestamp  / $ScriptName " | Set-Content -LiteralPath $LogFile -Encoding UTF8 }
    "$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') $prefix$Message" | Add-Content -LiteralPath $LogFile -Encoding UTF8
}

function Write-WindowsUpdateConsoleSummary {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Lines,
        [Parameter(Mandatory)][scriptblock]$WriteLog
    )

    Write-CommonLog $WriteLog ''
    Write-CommonLog $WriteLog '═══════════════════════════════════════'
    Write-CommonLog $WriteLog $Title
    Write-CommonLog $WriteLog '═══════════════════════════════════════'
    foreach ($line in @($Lines)) {
        Write-CommonLog $WriteLog $line
    }
    Write-CommonLog $WriteLog '═══════════════════════════════════════'
}

function Invoke-WindowsUpdateRetentionWithLog {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][int]$KeepFiles,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$WriteLog
    )

    if ($WriteLog) { & $WriteLog "Bereinige $Description" }
    $result = Invoke-WindowsUpdateFileRetention -Directory $Directory -Filter $Filter -KeepFiles $KeepFiles
    $removedFiles = @($result.RemovedFiles)
    $failedFiles = @($result.FailedFiles)
    if ($removedFiles.Count -eq 0) {
        if ($WriteLog) { & $WriteLog 'Es sind keine Dateien zum Entfernen vorhanden.' }
    } else {
        if ($WriteLog) { & $WriteLog "Es sind $($removedFiles.Count) Datei(en) zum Entfernen vorhanden." }
        foreach ($file in $removedFiles) { if ($WriteLog) { & $WriteLog "Entferne $file ..." } }
    }
    foreach ($failed in $failedFiles) { if ($WriteLog) { & $WriteLog "WARNUNG: $($failed.Path) konnte nicht entfernt werden: $($failed.Error)" } }
    return $result
}

function ConvertTo-WindowsUpdateMailSafeString {
    param([AllowEmptyString()][string]$Text)
    $result = $Text -replace 'ä','ae' -replace 'ö','oe' -replace 'ü','ue' -replace 'Ä','Ae' -replace 'Ö','Oe' -replace 'Ü','Ue' -replace 'ß','ss'
    $result = ($result -replace '\s+','-').ToLower() -replace '[^a-z0-9\-\.]',''
    foreach ($form in @('gmbh-co-kg','gmbh-co','gmbh','mbh','ug','ag','kg','ohg','gbr','ev','inc','ltd','se')) { $result = $result -replace "-$form$",'' -replace "^$form-",'' }
    while ($result.Length -gt 40) { $firstDash = $result.IndexOf('-'); if ($firstDash -gt 0) { $result = $result.Substring($firstDash + 1) } else { $result = $result.Substring(0,40); break } }
    return $result
}

function Send-WindowsUpdateHtmlMail {
    param(
        [Parameter(Mandatory)]$MailSettings,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$HtmlBody,
        [scriptblock]$WriteLog,
        [ValidateRange(1, 10)][int]$RetryCount = 3,
        [ValidateRange(0, 300)][int]$RetryDelaySeconds = 30
    )
    if ($WriteLog) { & $WriteLog 'Starte Mailversand...' }
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $smtp = $null; $mail = $null
        try {
            $smtp = New-Object -TypeName Net.Mail.SmtpClient -ArgumentList $MailSettings.Host, ([int]$MailSettings.Port)
            $smtp.EnableSsl = [bool]$MailSettings.UseSSL
            if ($MailSettings.Auth) { $smtp.Credentials = New-Object -TypeName Net.NetworkCredential -ArgumentList $MailSettings.AuthUser, $MailSettings.AuthPass }
            $mail = New-Object -TypeName Net.Mail.MailMessage
            $mail.From = $MailSettings.Sender; $mail.To.Add($MailSettings.MailTo)
            if ($MailSettings.MailCC -and $MailSettings.MailCC -ne $MailSettings.MailTo) { $mail.CC.Add($MailSettings.MailCC) }
            if ($MailSettings.MailBCC -and $MailSettings.MailBCC -ne $MailSettings.MailTo) { $mail.Bcc.Add($MailSettings.MailBCC) }
            $mail.Subject = $Subject; $mail.Body = $HtmlBody; $mail.IsBodyHtml = $true; $mail.BodyEncoding = [Text.Encoding]::UTF8; $mail.SubjectEncoding = [Text.Encoding]::UTF8
            $smtp.Send($mail)
            if ($WriteLog) { & $WriteLog 'E-Mail erfolgreich versendet' }
            return $true
        }
        catch {
            if ($WriteLog) { & $WriteLog "Fehler beim Versenden der E-Mail (Versuch $attempt von $RetryCount): $($_.Exception.Message)" }
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
                if ($WriteLog) { & $WriteLog "Nächster Mailversuch in $RetryDelaySeconds Sekunden..." }
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
        finally { if ($mail) { $mail.Dispose() }; if ($smtp) { $smtp.Dispose() } }
    }
    return $false
}

function Add-WindowsUpdateTrustedHost {
    param([Parameter(Mandatory)][string]$ComputerName, [scriptblock]$WriteLog)
    try {
        $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        if ($current -eq "*") { return }
        $entries = @($current -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($entries -contains $ComputerName) { return }
        if ($entries.Count -gt 0) { $newValue = ($entries + $ComputerName) -join "," }
        else { $newValue = $ComputerName }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force -ErrorAction Stop
    }
    catch {
        Write-CommonLog $WriteLog "WARNUNG: TrustedHosts konnte nicht aktualisiert werden."
    }
}

Export-ModuleMember -Function Get-WindowsUpdateSettings, Get-WindowsUpdateClientCertificateAuthInfo, Get-WindowsUpdateTargets, New-WindowsUpdateInvokeCommandParams, Initialize-WindowsUpdateRemoting, Test-WindowsUpdateJeaSupported, Invoke-WindowsUpdateSystemTask, Invoke-WindowsUpdateWithRetry, Get-WindowsUpdateSshArguments, Invoke-WindowsUpdatePackageManagers, Invoke-WindowsUpdateFileRetention, Write-WindowsUpdateLog, Write-WindowsUpdateConsoleSummary, Invoke-WindowsUpdateRetentionWithLog, ConvertTo-WindowsUpdateMailSafeString, Send-WindowsUpdateHtmlMail, Add-WindowsUpdateTrustedHost
