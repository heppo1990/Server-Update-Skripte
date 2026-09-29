Set-StrictMode -Version Latest

function Write-CommonLog {
    param(
        [scriptblock]$WriteLog,
        [string]$Message
    )

    if ($WriteLog) { & $WriteLog $Message }
}

function Write-PSWindowsUpdateModuleLog {
    param([scriptblock]$WriteLog, [string]$Message, [string]$Level = 'INFO')
    if ($WriteLog) { & $WriteLog $Message $Level; return }
    if ($Level -eq 'WARN') { Write-Warning $Message } else { Write-Verbose $Message }
}

function Update-PSWindowsUpdateModule {
    <#
    .SYNOPSIS
    Prüft und aktualisiert PSWindowsUpdate auf dem aktuellen Rechner.

    .DESCRIPTION
    Gemeinsame Modulpflege für das Check-Skript und das WindowsUpdateAdm-Setup.
    Die bereitgestellte Version wird in die maschinenweiten Modulpfade für
    Windows PowerShell 5.1 und PowerShell 7 synchronisiert.
    #>
    param(
        [switch]$Force,
        [string]$OfflineModulePath,
        [scriptblock]$WriteLog,
        [string]$ComputerName,
        $AuthInfo
    )

    if (-not [string]::IsNullOrWhiteSpace($ComputerName) -and $ComputerName -ine $env:COMPUTERNAME) {
        $session = $null
        try {
            $sessionParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo -OperationTimeoutSeconds 1800
            if (-not $AuthInfo) { $sessionParameters.SessionOption = New-PSSessionOption -IncludePortInSPN }
            $session = New-PSSession @sessionParameters
            $updateDefinition = (Get-Command -Name Update-PSWindowsUpdateModule -CommandType Function).Definition
            $logDefinition = (Get-Command -Name Write-PSWindowsUpdateModuleLog -CommandType Function).Definition
            $remoteWorker = {
                param($UpdaterText, $LoggerText, $ForceUpdate)
                Set-Item -Path Function:\Write-PSWindowsUpdateModuleLog -Value ([scriptblock]::Create($LoggerText))
                Set-Item -Path Function:\Update-PSWindowsUpdateModule -Value ([scriptblock]::Create($UpdaterText))
                $remoteLogger = { param($Message, $Level) [pscustomobject]@{ Type = 'ModuleLog'; Message = $Message; Level = $Level } }
                $updateOutput = @(Update-PSWindowsUpdateModule -Force:$ForceUpdate -WriteLog $remoteLogger)
                foreach ($entry in $updateOutput) {
                    if ($entry -and $entry.PSObject.Properties['Type'] -and $entry.Type -eq 'ModuleLog') {
                        [pscustomobject]@{ Type = 'ModuleLog'; Message = [string]$entry.Message; Level = [string]$entry.Level }
                    } elseif ($entry -is [bool]) {
                        [pscustomobject]@{ Type = 'ModuleResult'; Success = $entry }
                    }
                }
            }
            $remoteResults = @(Invoke-Command -Session $session -ScriptBlock $remoteWorker -ArgumentList $updateDefinition, $logDefinition, [bool]$Force -ErrorAction Stop)
            $success = $false
            foreach ($entry in $remoteResults) {
                if ($entry.Type -eq 'ModuleLog') { Write-PSWindowsUpdateModuleLog $WriteLog "[$ComputerName] $($entry.Message)" $entry.Level }
                elseif ($entry.Type -eq 'ModuleResult') { $success = [bool]$entry.Success }
            }
            if (-not $success) { throw "PSWindowsUpdate konnte auf '$ComputerName' nicht bereitgestellt werden." }
            return $true
        }
        catch {
            Write-PSWindowsUpdateModuleLog $WriteLog "WARNUNG: PSWindowsUpdate konnte auf '$ComputerName' nicht aktualisiert werden; vorhandene Version wird verwendet. Ursache: $($_.Exception.Message)" 'WARN'
            return $false
        }
        finally { if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue } }
    }

    $installedModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    $galleryVersion = $null

    try {
        $nugetProvider = Get-PackageProvider -Name NuGet -ListAvailable -ErrorAction SilentlyContinue |
            Where-Object { $_.Version -ge [version]'2.8.5.201' } |
            Sort-Object Version -Descending | Select-Object -First 1
        if (-not $nugetProvider) {
            Install-PackageProvider -Name NuGet -MinimumVersion '2.8.5.201' -Scope AllUsers `
                -Force -ForceBootstrap -Confirm:$false -ErrorAction Stop | Out-Null
        }

        $galleryModule = Find-Module -Name PSWindowsUpdate -Repository PSGallery -ErrorAction Stop
        $galleryVersion = [version]$galleryModule.Version
        if (-not $installedModule -or $installedModule.Version -lt $galleryVersion -or $Force) {
            $oldVersion = if ($installedModule) { [string]$installedModule.Version } else { 'nicht installiert' }
            $action = if ($Force) { 'erzwungen aktualisiert' } elseif ($installedModule) { 'aktualisiert' } else { 'installiert' }
            Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate wird ${action}: $oldVersion -> $galleryVersion." 'UPDATE'

            $installSucceeded = $false
            for ($attempt = 1; $attempt -le 3 -and -not $installSucceeded; $attempt++) {
                try {
                    if ($attempt -eq 2) {
                        Write-PSWindowsUpdateModuleLog $WriteLog 'PSWindowsUpdate-Installation wird erneut versucht.' 'WARN'
                    }
                    Install-Module -Name PSWindowsUpdate -Repository PSGallery -Scope AllUsers `
                        -Force -AllowClobber -SkipPublisherCheck -Confirm:$false -ErrorAction Stop
                    $installSucceeded = $true
                }
                catch {
                    Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate-Installationsversuch $attempt/3 fehlgeschlagen: $($_.Exception.Message)" 'WARN'
                    if ($attempt -lt 3) { Start-Sleep -Seconds 5 }
                }
            }
            if (-not $installSucceeded) { throw "PSWindowsUpdate konnte nach drei Versuchen nicht von PSGallery installiert werden." }
        }
        else {
            Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate ist aktuell (Version $($installedModule.Version))." 'SUCCESS'
        }
    }
    catch {
        Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate-Onlineprüfung fehlgeschlagen: $($_.Exception.Message)" 'WARN'
    }

    $sourceModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    if (-not $sourceModule) {
        $fallbackModulePaths = @(
            (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate'),
            (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\Modules\PSWindowsUpdate'),
            (Join-Path $env:ProgramFiles 'PowerShell\Modules\PSWindowsUpdate')
        )
        if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
            $fallbackModulePaths += Join-Path ${env:ProgramFiles(x86)} 'WindowsPowerShell\Modules\PSWindowsUpdate'
        }
        foreach ($fallbackPath in $fallbackModulePaths) {
            if (-not (Test-Path -LiteralPath $fallbackPath -PathType Container)) { continue }
            try {
                Import-Module $fallbackPath -ErrorAction Stop
                $sourceModule = Get-Module -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
                    Sort-Object Version -Descending | Select-Object -First 1
                if ($sourceModule) { break }
            }
            catch { Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate konnte nicht aus '$fallbackPath' geladen werden: $($_.Exception.Message)" 'WARN' }
        }
    }

    if (-not $sourceModule -and $OfflineModulePath -and (Test-Path -LiteralPath $OfflineModulePath -PathType Container)) {
        try {
            $offlineVersions = @(Get-ChildItem -LiteralPath $OfflineModulePath -Directory -ErrorAction SilentlyContinue)
            $targetRoot = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate'
            New-Item -ItemType Directory -Path $targetRoot -Force -ErrorAction Stop | Out-Null
            if ($offlineVersions.Count -gt 0) {
                foreach ($version in $offlineVersions) {
                    Copy-Item -LiteralPath $version.FullName -Destination (Join-Path $targetRoot $version.Name) -Recurse -Force -ErrorAction Stop
                }
            }
            else {
                Copy-Item -LiteralPath $OfflineModulePath -Destination $targetRoot -Recurse -Force -ErrorAction Stop
            }
            $sourceModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
            if ($sourceModule) { Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate wurde aus dem lokalen Offline-Paket bereitgestellt ($($sourceModule.Version))." 'SUCCESS' }
        }
        catch { Write-PSWindowsUpdateModuleLog $WriteLog "Offline-Bereitstellung von PSWindowsUpdate fehlgeschlagen: $($_.Exception.Message)" 'WARN' }
    }

    if (-not $sourceModule) {
        Write-PSWindowsUpdateModuleLog $WriteLog 'PSWindowsUpdate ist nicht installiert und konnte nicht aktualisiert werden.' 'ERROR'
        return $false
    }

    $moduleTargets = @(
        [pscustomobject]@{ Name = 'Windows PowerShell 5.1'; Path = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate' },
        [pscustomobject]@{ Name = 'PowerShell 7'; Path = Join-Path $env:ProgramFiles 'PowerShell\Modules\PSWindowsUpdate' }
    )
    foreach ($target in $moduleTargets) {
        try {
            $versionPath = Join-Path $target.Path ([string]$sourceModule.Version)
            if (-not (Test-Path -LiteralPath $versionPath -PathType Container)) {
                New-Item -ItemType Directory -Path $target.Path -Force -ErrorAction Stop | Out-Null
                Copy-Item -LiteralPath $sourceModule.ModuleBase -Destination $versionPath -Recurse -Force -ErrorAction Stop
                Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate $($sourceModule.Version) nach $($target.Name) kopiert." 'INFO'
            }
            Get-ChildItem -LiteralPath $target.Path -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -ne [string]$sourceModule.Version } |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction Stop }
        }
        catch { Write-PSWindowsUpdateModuleLog $WriteLog "Modulpfad '$($target.Path)' konnte nicht synchronisiert werden: $($_.Exception.Message)" 'WARN' }
    }

    Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate bereit; verfügbare Version: $($sourceModule.Version)." 'SUCCESS'
    return $true
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

function Protect-WindowsUpdateSettingsObjectPassword {
    param([Parameter(Mandatory)][object]$Document)
    if ($Document -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $mailProperty = @($Document.PSObject.Properties | Where-Object { $_.Name -ieq 'MailSettings' } | Select-Object -First 1)
    if ($mailProperty.Count -eq 0 -or $null -eq $mailProperty[0].Value) { return $false }
    $passwordProperty = $mailProperty[0].Value.PSObject.Properties['AuthPass']
    if (-not $passwordProperty -or [string]::IsNullOrEmpty([string]$passwordProperty.Value) -or
        ([string]$passwordProperty.Value).StartsWith('DPAPI:', [StringComparison]::Ordinal)) { return $false }
    $protectedPassword = Protect-WindowsUpdateMailPassword -Password ([string]$passwordProperty.Value)
    Add-Member -InputObject $mailProperty[0].Value -NotePropertyName AuthPass -NotePropertyValue $protectedPassword -Force
    return $true
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
    $document = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    if (Protect-WindowsUpdateSettingsObjectPassword -Document $document) {
        # Ein direkter Settings-Aufruf ohne Updater erhält ebenfalls eine
        # geschützte Sicherung; im regulären Update erledigt dies der gemeinsame
        # Migrationsschritt, sodass nur eine Sicherung pro Änderung entsteht.
        $backupPath = '{0}.bak.{1}_{2}' -f $Path, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
        Write-WindowsUpdateJsonAtomically -Path $backupPath -Value $document
        Write-WindowsUpdateJsonAtomically -Path $Path -Value $document
        Write-CommonLog $WriteLog "Mailpasswort in '$([IO.Path]::GetFileName($Path))' automatisch mit DPAPI geschützt."
    }
    # Ältere automatische Sicherungen aus früheren Skriptständen schützen,
    # falls sie noch ein Klartextpasswort enthalten. Dafür keine weitere
    # Sicherung erstellen.
    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    foreach ($oldBackup in @(Get-ChildItem -LiteralPath $directory -Filter ($leaf + '.bak.*') -File -ErrorAction SilentlyContinue)) {
        try {
            $oldDocument = Get-Content -LiteralPath $oldBackup.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if (Protect-WindowsUpdateSettingsObjectPassword -Document $oldDocument) {
                Write-WindowsUpdateJsonAtomically -Path $oldBackup.FullName -Value $oldDocument
            }
        }
        catch { throw "Eine ältere Settings-Sicherung konnte nicht geschützt werden ('$($oldBackup.Name)'). Der Lauf wird abgebrochen, damit kein Klartextpasswort zurückbleibt." }
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
    $legacyGeneralSettingsPath = Join-Path $ScriptRoot 'default.settings.json'
    if (-not (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf) -and
        (Test-Path -LiteralPath $legacyGeneralSettingsPath -PathType Leaf)) {
        $generalSettingsPath = $legacyGeneralSettingsPath
    }
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
    if (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf) {
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
        [bool]$EnableChocolatey = $true,
        [scriptblock]$WriteLog
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
            # WinGet kann nach einer Installation in derselben Sitzung noch
            # ohne App-Ausführungsalias im PATH liegen. Deshalb zusätzlich
            # den tatsächlich installierten Paketpfad durchsuchen.
            $command = Get-Command winget -ErrorAction SilentlyContinue
            $patterns = @()
            if ($command -and -not [string]::IsNullOrWhiteSpace([string]$command.Source)) { $patterns += [string]$command.Source }
            if (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) { $patterns += Join-Path $env:LOCALAPPDATA 'Microsoft\WindowsApps\winget.exe' }
            $programFilesRoots = @('C:\Program Files', $env:ProgramFiles) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
            foreach ($programFilesRoot in $programFilesRoots) {
                $patterns += Join-Path $programFilesRoot 'WindowsApps\Microsoft.DesktopAppInstaller_*_x64__8wekyb3d8bbwe\winget.exe'
                # Neuere bzw. paketierte Layouts verwenden Unterordner für Version und Architektur.
                $patterns += Join-Path $programFilesRoot 'WindowsApps\Microsoft.DesktopAppInstaller\*\winget.exe'
                $patterns += Join-Path $programFilesRoot 'WindowsApps\Microsoft.DesktopAppInstaller\*\*\winget.exe'
            }
            $candidates = @()
            foreach ($pattern in $patterns) {
                if ($pattern -match '[*?]') {
                    $candidates += Get-ChildItem -Path $pattern -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName }
                } elseif (Test-Path -LiteralPath $pattern -PathType Leaf -ErrorAction SilentlyContinue) {
                    $candidates += $pattern
                }
            }
            foreach ($candidatePath in @($candidates | Select-Object -Unique)) {
                # Nicht nur den Alias finden: eine funktionsfähige EXE bevorzugen.
                $health = Test-WingetExecutable -Path $candidatePath
                if ($health.Works) { return $candidatePath }
            }
            return $null
        }

        function Test-WingetExecutable {
            param([string]$Path, [switch]$FreshPowerShell)
            if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path -PathType Leaf)) {
                return [PSCustomObject]@{ Works = $false; Output = 'winget.exe wurde nicht gefunden.' }
            }
            try {
                if ($FreshPowerShell) {
                    # Ein Kindprozess liest nach einer Reparatur die aktualisierte
                    # Umgebung neu ein; der Pfad wird dabei trotzdem explizit übergeben.
                    $shellPath = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
                    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject @{ Path = $Path } -Compress)))
                    $childSource = @'
$data = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__PAYLOAD__')) | ConvertFrom-Json
$wingetArguments = @($data.Arguments)
& $data.Path --version 2>&1
exit $LASTEXITCODE
'@ -replace '__PAYLOAD__', $payload
                    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
                    $output = (& $shellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedChild 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
                } else {
                    $output = (& $Path --version 2>&1 | Out-String -Width 300).Trim()
                    $exitCode = $LASTEXITCODE
                }
                $works = $exitCode -eq 0 -and $output -match '(?m)^\s*v?\d+\.\d+'
                if ($works) { return [PSCustomObject]@{ Works = $true; Output = "ExitCode=$exitCode; Ausgabe=$output" } }
                $failureSummary = if ($output -match '(?i)(Zugriff verweigert|Access is denied|access denied)') {
                    'Zugriff auf winget.exe verweigert.'
                } else {
                    @($output -split "`r?`n" | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -First 1) -join ''
                }
                if ([string]::IsNullOrWhiteSpace($failureSummary)) { $failureSummary = "ExitCode=$exitCode; keine Versionsausgabe erhalten." }
                if ($failureSummary.Length -gt 200) { $failureSummary = $failureSummary.Substring(0, 197) + '...' }
                return [PSCustomObject]@{ Works = $false; Output = "ExitCode=$exitCode; $failureSummary"; DiagnosticOutput = $output }
            }
            catch {
                $diagnostic = $_.Exception.ToString()
                $failureSummary = if ($_.Exception.Message -match '(?i)(Zugriff verweigert|Access is denied|access denied)') {
                    'Zugriff auf winget.exe verweigert.'
                } else {
                    ([string]$_.Exception.Message -split "`r?`n")[0].Trim()
                }
                if ([string]::IsNullOrWhiteSpace($failureSummary)) { $failureSummary = 'WinGet-Versionsprüfung fehlgeschlagen.' }
                if ($failureSummary.Length -gt 200) { $failureSummary = $failureSummary.Substring(0, 197) + '...' }
                return [PSCustomObject]@{ Works = $false; Output = $failureSummary; DiagnosticOutput = $diagnostic }
            }
        }

        function Test-WingetSourceFailureLine {
            param([string]$Line)
            return $Line -match '(?i)(Fehler beim Durchsuchen der Quelle|Fehler beim Versuch, die Quelle zu aktualisieren|An error occurred while searching the source|Failed when searching (?:the )?source|Failed in attempting to update the source)'
        }

        function Get-WingetUpgradeLines {
            param([string]$Output)
            return @($Output -split "`r?`n" | Where-Object {
                $line = $_.Trim()
                $line -match '\s(?:winget|msstore)\s*$' -and
                $line -notmatch '^Name\s+' -and
                -not (Test-WingetSourceFailureLine -Line $line)
            })
        }

        function Get-WingetSourceResetState {
            $sourceStateRoot = if (-not [string]::IsNullOrWhiteSpace($env:ProgramData)) {
                $env:ProgramData
            } elseif (-not [string]::IsNullOrWhiteSpace($env:LOCALAPPDATA)) {
                $env:LOCALAPPDATA
            } else {
                $env:USERPROFILE
            }
            $sourceStateDirectory = Join-Path $sourceStateRoot 'ServerUpdateSkripte'
            # Neuer Markername: ältere Skriptstände haben Standardquellen
            # einzeln zurückgesetzt. Deren Zeitmarke darf den ersten vollständigen
            # Quellenreset nach diesem Fix nicht unterdrücken.
            $markerPath = Join-Path $sourceStateDirectory 'WingetAllSourcesResetUtc.txt'
            $allowed = $true
            try {
                if (Test-Path -LiteralPath $markerPath -PathType Leaf) {
                    $lastResetUtc = [DateTime]::MinValue
                    $markerText = Get-Content -LiteralPath $markerPath -Raw -ErrorAction Stop
                    if ([DateTime]::TryParse($markerText, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref]$lastResetUtc) -and
                        ([DateTime]::UtcNow - $lastResetUtc.ToUniversalTime()).TotalHours -lt 24) {
                        $allowed = $false
                    }
                }
            }
            catch {
                # Ein nicht lesbarer Marker darf eine notwendige Reparatur
                # nicht verhindern; der Fehler wird beim Speichern protokolliert.
                $allowed = $true
            }
            return [PSCustomObject]@{ Allowed = $allowed; Directory = $sourceStateDirectory; MarkerPath = $markerPath }
        }

        function Get-WingetCompactOutput {
            param([AllowNull()][string]$Text, [int]$MaximumLength = 500)
            if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
            $clean = [regex]::Replace($Text, '\x1B\[[0-?]*[ -/]*[@-~]', '')
            $lines = @($clean -split "`r?`n" | ForEach-Object { ([string]$_).Trim() } | Where-Object {
                $_ -and
                $_ -notmatch '[\u2580-\u259F]' -and
                $_ -notmatch '\u00e2\u2013' -and
                $_ -notmatch '^[-\\|/](?:\s*[-\\|/]){2,}' -and
                $_ -notmatch '(?i)\d+(?:\.\d+)?\s*(?:KB|MB|GB)\s*/\s*\d+(?:\.\d+)?\s*(?:KB|MB|GB)'
            })
            $summary = $lines -join ' '
            if ($summary.Length -gt $MaximumLength) { $summary = $summary.Substring(0, $MaximumLength - 3) + '...' }
            return $summary
        }
        function Reset-WingetDefaultSources {
            param([Parameter(Mandatory)][string]$WingetPath)
            # Der vollständige Reset hat sich als notwendig erwiesen. Vorher
            # prüfen, ob kundeneigene Quellen vorhanden sind, da WinGet sie bei
            # einem globalen Reset entfernt.
            $sourceListOutput = & $WingetPath source list --disable-interactivity 2>&1 | Out-String
            $sourceListExitCode = $LASTEXITCODE
            if ($sourceListExitCode -ne 0) {
                throw "WinGet-Quellen konnten vor dem Reset nicht aufgelistet werden (Exitcode $sourceListExitCode)."
            }
            $defaultSources = @('msstore', 'winget', 'winget-font')
            $configuredSources = @($sourceListOutput -split "`r?`n" | ForEach-Object {
                $line = [string]$_
                # Nur der Quellname entscheidet. URLs variieren je nach
                # WinGet-Version und gehören nicht in Fehlermeldungen.
                if ($line -match '^\s*(?<Name>msstore|winget-font|winget)(?=\s|$)') { $Matches.Name }
                elseif ($line -match '^\s*(?<Name>[^\s]+)\s+') {
                    $name = $Matches.Name.Trim()
                    if ($name -and $name -notmatch '^(Name|[-=]+)$') { $name }
                }
            })
            $customSources = @($configuredSources | Where-Object { $_ -notin $defaultSources } | Select-Object -Unique)
            if ($configuredSources.Count -eq 0) {
                throw 'WinGet-Quellenliste war leer oder konnte nicht ausgewertet werden; vollständiger Reset aus Sicherheitsgründen abgebrochen.'
            }
            if ($customSources.Count -gt 0) {
                throw "Kundeneigene WinGet-Quelle(n) erkannt ($($customSources -join ', ')); vollständiger Reset wurde aus Sicherheitsgründen abgebrochen, damit diese Quellen erhalten bleiben."
            }

            $resetOutput = & $WingetPath source reset --force --disable-interactivity 2>&1 | Out-String
            $resetExitCode = $LASTEXITCODE
            if ($resetExitCode -ne 0) {
                throw "Vollständiger WinGet-Quellenreset fehlgeschlagen (Exitcode $resetExitCode)."
            }
        }

        function Save-WingetSourceResetState {
            param([Parameter(Mandatory)]$State)
            if (-not (Test-Path -LiteralPath $State.Directory -PathType Container)) {
                New-Item -Path $State.Directory -ItemType Directory -Force -ErrorAction Stop | Out-Null
            }
            [IO.File]::WriteAllText($State.MarkerPath, [DateTime]::UtcNow.ToString('o'), [Text.UTF8Encoding]::new($false))
        }

        function Get-WingetTempDirectory {
            $candidates = @($env:TEMP, $env:TMP, (Join-Path $env:windir 'Temp')) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) } | Select-Object -Unique
            foreach ($candidate in $candidates) {
                $probePath = $null
                $stream = $null
                try {
                    if (-not (Test-Path -LiteralPath $candidate -PathType Container -ErrorAction SilentlyContinue)) { continue }
                    $probePath = Join-Path $candidate ('winget-temp-check-{0}.tmp' -f [guid]::NewGuid().ToString('N'))
                    $stream = [IO.File]::Open($probePath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                    $stream.Dispose(); $stream = $null
                    Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue
                    return $candidate
                }
                catch {
                    if ($stream) { $stream.Dispose() }
                    if ($probePath) { Remove-Item -LiteralPath $probePath -Force -ErrorAction SilentlyContinue }
                }
            }
            throw 'Kein gültiger beschreibbarer temporärer Ordner für die WinGet-Reparatur gefunden.'
        }
        function Find-WingetInstallScript {
            $command = Get-Command winget-install.ps1 -ErrorAction SilentlyContinue | Select-Object -First 1
            if ($command -and $command.Source -and (Test-Path -LiteralPath $command.Source -PathType Leaf)) { return $command.Source }
            $candidates = @()
            if ($env:USERPROFILE -and (Test-Path -LiteralPath $env:USERPROFILE -PathType Container -ErrorAction SilentlyContinue)) {
                $candidates += Join-Path $env:USERPROFILE 'Documents\WindowsPowerShell\Scripts\winget-install.ps1'
            }
            if ($env:ProgramFiles) { $candidates += Join-Path $env:ProgramFiles 'WindowsPowerShell\Scripts\winget-install.ps1' }
            foreach ($candidate in $candidates) {
                if (Test-Path -LiteralPath $candidate -PathType Leaf) { return $candidate }
            }
            return $null
        }
        function Invoke-WingetInstallScript {
            param([string]$Path, [string[]]$InstallerArguments)
            $powerShell51 = Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\powershell.exe'
            if (-not (Test-Path -LiteralPath $powerShell51 -PathType Leaf)) { throw 'Windows PowerShell 5.1 wurde nicht gefunden.' }
            $rawOutput = (& $powerShell51 -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $Path @InstallerArguments 2>&1 | Out-String -Width 300)
            $output = Get-WingetCompactOutput -Text $rawOutput
            $exitCode = $LASTEXITCODE
            return [PSCustomObject]@{ ExitCode = $exitCode; Output = $output.Trim() }
        }

        function Test-WingetInstallScriptSignature {
            param([string]$Path)
            $signature = Get-AuthenticodeSignature -LiteralPath $Path
            return $signature.Status -eq 'Valid'
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
            $wingetBootstrapMessage = ''
            $wingetPreparationSucceeded = $true
            $serverCaption = ''
            try { $serverCaption = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
            if ($serverCaption -match 'Windows Server (2019|2022)') {
                $wingetHealth = Test-WingetExecutable -Path $wingetPath
                if (-not $wingetHealth.Works) {
                    $wingetBootstrapMessage = "WinGet auf $serverCaption fehlt oder ist nicht funktionsfähig ($($wingetHealth.Output)); starte Reparatur."
                    $installerPath = Find-WingetInstallScript
                    $temporaryInstallerPath = $null
                    try {
                        if ($installerPath) {
                            if (-not (Test-WingetInstallScriptSignature -Path $installerPath)) {
                                throw "Die vorhandene winget-install-Datei hat keine gültige Authenticode-Signatur: $installerPath"
                            }
                            $updateResult = Invoke-WingetInstallScript -Path $installerPath -InstallerArguments @('-UpdateSelf')
                            $wingetBootstrapMessage += " UpdateSelf ExitCode=$($updateResult.ExitCode)."
                            if (-not [string]::IsNullOrWhiteSpace($updateResult.Output)) { $wingetBootstrapMessage += " $($updateResult.Output)" }
                            if ($updateResult.ExitCode -ne 0) { throw "winget-install -UpdateSelf endete mit ExitCode $($updateResult.ExitCode)." }
                            $installerPath = Find-WingetInstallScript
                        }
                        else {
                            # Skript aus PSGallery installieren; bei Galerieproblemen
                            # auf die signierte GitHub-Release-Datei ausweichen.
                            $bootstrapPath = Join-Path (Get-WingetTempDirectory) ("winget-install-bootstrap-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
                            $bootstrapScript = @'
$ErrorActionPreference = 'Stop'
try {
    Install-Script -Name winget-install -Repository PSGallery -Scope CurrentUser -Force -Confirm:$false -ErrorAction Stop
    exit 0
}
catch {
    Write-Error $_
    exit 1
}
'@
                            [IO.File]::WriteAllText($bootstrapPath, $bootstrapScript, [Text.Encoding]::UTF8)
                            try { $galleryResult = Invoke-WingetInstallScript -Path $bootstrapPath -InstallerArguments @() }
                            finally { Remove-Item -LiteralPath $bootstrapPath -Force -ErrorAction SilentlyContinue }
                            $installerPath = Find-WingetInstallScript
                            if ($galleryResult.ExitCode -ne 0 -or -not $installerPath) {
                                $temporaryInstallerPath = Join-Path (Get-WingetTempDirectory) ("winget-install-{0}.ps1" -f [guid]::NewGuid().ToString('N'))
                                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                                Invoke-WebRequest -Uri 'https://github.com/asheroto/winget-install/releases/latest/download/winget-install.ps1' -UseBasicParsing -TimeoutSec 90 -OutFile $temporaryInstallerPath -ErrorAction Stop
                                $installerPath = $temporaryInstallerPath
                            }
                            $wingetBootstrapMessage += ' winget-install wurde bereitgestellt.'
                        }

                        if (-not $installerPath -or -not (Test-WingetInstallScriptSignature -Path $installerPath)) {
                            throw 'Die winget-install-Datei hat keine gültige Authenticode-Signatur.'
                        }
                        $repairResult = Invoke-WingetInstallScript -Path $installerPath -InstallerArguments @('-Force')
                        if ($repairResult.ExitCode -ne 0) {
                            throw "winget-install -Force endete mit ExitCode $($repairResult.ExitCode): $($repairResult.Output)"
                        }
                        $env:PATH = @([Environment]::GetEnvironmentVariable('Path', 'Machine'), [Environment]::GetEnvironmentVariable('Path', 'User')) -join ';'
                        $wingetPath = Resolve-WingetExecutable
                        $wingetHealth = Test-WingetExecutable -Path $wingetPath -FreshPowerShell
                        if (-not $wingetHealth.Works) { throw "WinGet ist nach der Reparatur weiterhin nicht funktionsfähig: $($wingetHealth.Output)" }
                        $wingetBootstrapMessage += " Reparatur erfolgreich; $($wingetHealth.Output)"
                    }
                    catch {
                        $wingetPreparationSucceeded = $false
                        $wingetBootstrapMessage += " Reparatur fehlgeschlagen: $($_.Exception.Message)"
                    }
                    finally {
                        if ($temporaryInstallerPath -and (Test-Path -LiteralPath $temporaryInstallerPath -PathType Leaf)) {
                            Remove-Item -LiteralPath $temporaryInstallerPath -Force -ErrorAction SilentlyContinue
                        }
                    }
                }
            }

            if (-not $wingetPreparationSucceeded) {
                $result += [PSCustomObject]@{ Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput=$wingetBootstrapMessage; BootstrapMessage=$wingetBootstrapMessage }
            }
            elseif ($wingetPath) {
                try {
                $env:PROCESSOR_ARCHITECTURE = 'AMD64'
                $availableOutput = & $wingetPath upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
                $sourceFailureLines = @($availableOutput -split "`r?`n" | Where-Object {
                    Test-WingetSourceFailureLine -Line ([string]$_)
                })
                $wingetSourceRefreshOutput = ''
                $sourceResetPerformed = $false
                if ($sourceFailureLines.Count -gt 0) {
                    # WinGet kann bei veraltetem oder kurzfristig nicht erreichbarem
                    # Quellcache eine Fehlermeldung ausgeben, obwohl die Quelle danach
                    # wieder funktioniert. Quelle einmal gezielt aktualisieren und
                    # die Suche wiederholen, bevor der Lauf einen Fehler meldet.
                    $wingetSourceRefreshOutput = & $wingetPath source update --name winget --disable-interactivity 2>&1 | Out-String
                    $sourceRefreshExitCode = $LASTEXITCODE
                    if ($sourceRefreshExitCode -eq 0) {
                        $wingetBootstrapMessage += ' WinGet-Quelle winget wurde aktualisiert; die Paketabfrage wird wiederholt.'
                        $availableOutput = & $wingetPath upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
                        $sourceFailureLines = @($availableOutput -split "`r?`n" | Where-Object {
                            Test-WingetSourceFailureLine -Line ([string]$_)
                        })
                    }
                    else {
                        $refreshSummary = Get-WingetCompactOutput -Text $wingetSourceRefreshOutput
                        $refreshDetail = if ($refreshSummary) { ": $refreshSummary" } else { '' }
                        $sourceFailureLines += "Aktualisieren der WinGet-Quelle winget fehlgeschlagen (ExitCode $sourceRefreshExitCode)$refreshDetail"
                    }
                    if ($sourceFailureLines.Count -gt 0) {
                        $sourceResetState = Get-WingetSourceResetState
                        if ($sourceResetState.Allowed) {
                            try {
                                Reset-WingetDefaultSources -WingetPath $wingetPath
                                $sourceResetPerformed = $true
                                try { Save-WingetSourceResetState -State $sourceResetState }
                                catch { $wingetBootstrapMessage += " Warnung: Die 24-Stunden-Sperre für Quellenresets konnte nicht gespeichert werden: $($_.Exception.Message)" }
                                $wingetBootstrapMessage += ' WinGet-Standardquellen wurden zurückgesetzt; die Paketabfrage wird wiederholt.'
                                $availableOutput = & $wingetPath upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
                                $sourceFailureLines = @($availableOutput -split "`r?`n" | Where-Object {
                                    Test-WingetSourceFailureLine -Line ([string]$_)
                                })
                            }
                            catch {
                                $wingetBootstrapMessage += " Zurücksetzen der WinGet-Standardquellen fehlgeschlagen: $($_.Exception.Message)"
                            }
                        }
                        else {
                            $wingetBootstrapMessage += ' Der Quellenreset wurde übersprungen, da auf diesem Zielsystem innerhalb der letzten 24 Stunden bereits ein Reset ausgeführt wurde.'
                        }
                    }
                }
                # Winget liefert eine formatierte Tabelle. Echte Upgrade-Zeilen
                # enden mit ihrer Paketquelle (winget oder msstore); Status- und
                # Lizenztexte tun dies nicht. Quellenfehler können ebenfalls
                # mit "winget" enden und dürfen daher nicht als Paket gelten.
                $packageLines = @(Get-WingetUpgradeLines -Output $availableOutput)
                if ($packageLines.Count -eq 0 -and $sourceFailureLines.Count -eq 0 -and -not $sourceResetPerformed) {
                    # Ein erfolgreicher, aber leerer Suchlauf kann auf einen
                    # beschädigten lokalen Quellenzustand hindeuten. Der nötige
                    # vollständige Reset erfolgt nur, wenn keine kundeneigenen
                    # Quellen vorhanden sind.
                    $sourceResetState = Get-WingetSourceResetState
                    if ($sourceResetState.Allowed) {
                        try {
                            Reset-WingetDefaultSources -WingetPath $wingetPath
                            $sourceResetPerformed = $true
                            try { Save-WingetSourceResetState -State $sourceResetState }
                            catch { $wingetBootstrapMessage += " Warnung: Die 24-Stunden-Sperre für Quellenresets konnte nicht gespeichert werden: $($_.Exception.Message)" }
                            $wingetBootstrapMessage += ' Die WinGet-Suche war leer; die Standardquellen wurden gezielt zurückgesetzt und die Suche einmal wiederholt.'
                            $availableOutput = & $wingetPath upgrade --accept-source-agreements --disable-interactivity 2>&1 | Out-String
                            $sourceFailureLines = @($availableOutput -split "`r?`n" | Where-Object {
                                Test-WingetSourceFailureLine -Line ([string]$_)
                            })
                            $packageLines = @(Get-WingetUpgradeLines -Output $availableOutput)
                        }
                        catch {
                            $wingetBootstrapMessage += " Zurücksetzen der WinGet-Standardquellen fehlgeschlagen: $($_.Exception.Message)"
                        }
                    }
                    else {
                        $wingetBootstrapMessage += " Die WinGet-Suche war leer; ein Quellenreset wurde übersprungen, da auf diesem Zielsystem innerhalb der letzten 24 Stunden bereits einer ausgeführt wurde."
                    }
                }
                $actionOutput = ''
                $exitCode = 0
                if ($ExecutionMode -eq 'Install' -and $packageLines.Count -gt 0) {
                    # Pakete einzeln ausführen, damit ein Installationsart-Konflikt
                    # ein anderes Paket nicht am Aktualisieren hindert. Es wird
                    # bewusst kein --installer-type erzwungen und nichts entfernt.
                    $noUpdateCodes = @(-1978335188, -1978335189, -1978335192)
                    foreach ($packageLine in $packageLines) {
                        # WinGet richtet Tabellen je nach Terminalbreite und
                        # Ausgabeumleitung unterschiedlich aus. Paketname und ID
                        # sind deshalb nicht zuverlässig durch mehrere Leerzeichen
                        # getrennt. Die letzten vier Spalten (ID, installierte
                        # Version, verfügbare Version, Quelle) werden von rechts
                        # erkannt; so wird eine Versionsnummer nie als Paket-ID
                        # fehlinterpretiert.
                        $packageMatch = [regex]::Match(
                            [string]$packageLine,
                            '^\s*(?<Name>.+?)\s+(?<Id>(?=[A-Za-z0-9._+-]*[A-Za-z])[A-Za-z0-9][A-Za-z0-9._+-]*)\s+(?<InstalledVersion>\S+)\s+(?<AvailableVersion>\S+)\s+(?<Source>winget|msstore)\s*$',
                            [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
                        )
                        if (-not $packageMatch.Success) {
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$false; Skipped=$true
                                SkipReason="Paket-ID konnte nicht sicher aus der WinGet-Liste gelesen werden: $($packageLine.Trim())"
                                ExitCode=$null; Packages=@(); AvailableOutput=$availableOutput; ActionOutput=''
                                RequiresManualAction=$true; ManualActionText="Paketzeile konnte nicht automatisch zugeordnet werden: $($packageLine.Trim()). Bitte dieses WinGet-Update manuell prüfen."
                            }
                            continue
                        }

                        $packageId = $packageMatch.Groups['Id'].Value
                        $packageName = $packageMatch.Groups['Name'].Value.Trim()
                        $packageSource = $packageMatch.Groups['Source'].Value
                        try {
                            $packageArguments = @('upgrade', '--id', $packageId, '--exact')
                            if (-not [string]::IsNullOrWhiteSpace($packageSource)) { $packageArguments += @('--source', $packageSource) }
                            $packageArguments += @('--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                            $packageActionOutput = & $wingetPath @packageArguments 2>&1 | Out-String
                            $packageExitCode = $LASTEXITCODE
                            $noInstalledPackage = $packageActionOutput -match '(?i)(kein installiertes Paket gefunden|no installed package found)'
                            if ($noInstalledPackage) {
                                # Manche WinGet-Versionen zeigen ein Upgrade in der
                                # Gesamtliste, finden es beim exakten ID-Aufruf aber
                                # nicht wieder. Dann dieselbe Quelle mit dem exakten
                                # Anzeigenamen aus der Liste ansprechen.
                                $fallbackArguments = @('upgrade', '--name', $packageName, '--exact')
                                if (-not [string]::IsNullOrWhiteSpace($packageSource)) { $fallbackArguments += @('--source', $packageSource) }
                                $fallbackArguments += @('--silent', '--accept-package-agreements', '--accept-source-agreements', '--disable-interactivity')
                                $fallbackOutput = & $wingetPath @fallbackArguments 2>&1 | Out-String
                                $fallbackExitCode = $LASTEXITCODE
                                $packageActionOutput += "`nFallback mit exaktem Paketnamen '$packageName':`n$($fallbackOutput.Trim())"
                                $packageExitCode = $fallbackExitCode
                                $noInstalledPackage = $fallbackOutput -match '(?i)(kein installiertes Paket gefunden|no installed package found)'
                            }
                            $technologyMismatch = $packageActionOutput -match '(?i)(Installationstechnologie unterscheidet sich|installation technology (?:is|differs from|does not match)|technology.*different from the current installed)'
                            $appxSessionFailure = $packageActionOutput -match '(?i)(0x80073D19|2147958041|Fehler aufgrund der Abmeldung eines Benutzers|An error occurred because a user was logged off)'
                            $appxRegistrationFailure = $packageActionOutput -match '(?i)(0x80070002|2147942402)' -and
                                $packageActionOutput -match '(?i)(RegisterByPackageFullName|RegisterPackageByFullName|im Repository nicht gefunden werden konnte|could not be found in the repository)'
                            if ($technologyMismatch) {
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=$false; Skipped=$true
                                    SkipReason="Paket '$packageName' [$packageId]: WinGet meldet einen Konflikt der Installationstechnologie. Es wurde nichts deinstalliert."
                                    ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$packageActionOutput
                                    RequiresManualAction=$true; ManualActionText="Paket '$packageName' [$packageId] konnte wegen eines Konflikts der Installationstechnologie nicht automatisch aktualisiert werden. Bitte Installationsart manuell prüfen und das Paket aktualisieren."
                                }
                            }
                            elseif ($appxSessionFailure -or $appxRegistrationFailure) {
                                $manualCommand = "winget upgrade --id $packageId --exact --source $packageSource --accept-package-agreements --accept-source-agreements"
                                $failureReason = if ($appxSessionFailure) {
                                    'Windows meldet 0x80073D19 (Benutzer abgemeldet), während WinGet eine AppX-Abhängigkeit bereitstellt.'
                                } else {
                                    'WinGet konnte das AppX-Paket nach der Bereitstellung nicht im Paketrepository registrieren (0x80070002).'
                                }
                                $manualHint = "Paket '$packageName' [$packageId] konnte über WinRM nicht abgeschlossen werden. $failureReason Dieses AppX-Update muss direkt auf dem Zielsystem in einer angemeldeten PowerShell-Sitzung ausgeführt werden: $manualCommand"
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''
                                    ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput
                                    ActionOutput=$manualHint; DiagnosticOutput=$packageActionOutput
                                    RequiresManualAction=$true; ManualActionText=$manualHint
                                }
                            }
                            elseif ($noInstalledPackage) {
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=$false; Skipped=$true
                                    SkipReason="Paket '$packageName' [$packageId] steht in der Upgrade-Liste, konnte aber per ID und exaktem Namen nicht als installiertes Paket aufgelöst werden. Es wurde übersprungen."
                                    ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$packageActionOutput
                                    RequiresManualAction=$true; ManualActionText="Paket '$packageName' [$packageId] steht in der WinGet-Upgrade-Liste, wurde lokal aber nicht als installiert erkannt. Bitte Installation und Paket-ID manuell prüfen."
                                }
                            }
                            else {
                                $installerErrorCode = [regex]::Match($packageActionOutput, '(?i)0x[0-9a-f]{8}').Value
                                $packageErrorSummary = "Paket '$packageName' [$packageId] konnte nicht automatisch aktualisiert werden"
                                if ($installerErrorCode) { $packageErrorSummary += " ($installerErrorCode)" }
                                elseif ($null -ne $packageExitCode) { $packageErrorSummary += " (Exitcode $packageExitCode)" }
                                $packageErrorSummary += '; manuelle Prüfung erforderlich.'
                                $result += [PSCustomObject]@{
                                    Manager='Winget'; Available=$true; Success=($packageExitCode -eq 0 -or $packageExitCode -in $noUpdateCodes); Skipped=$false
                                    SkipReason=''; ExitCode=$packageExitCode; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$packageActionOutput
                                    ErrorSummary=$packageErrorSummary; DiagnosticOutput=$packageActionOutput; RequiresManualAction=($packageExitCode -ne 0 -and $packageExitCode -notin $noUpdateCodes)
                                }
                            }
                        }
                        catch {
                            $packageException = $_.Exception.Message
                            if ($packageException.Length -gt 240) { $packageException = $packageException.Substring(0, 237) + '...' }
                            $result += [PSCustomObject]@{
                                Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''
                                ExitCode=$null; Packages=@($packageLine); AvailableOutput=$availableOutput; ActionOutput=$_.Exception.Message
                                ErrorSummary="Paket '$packageName' [$packageId] konnte nicht automatisch aktualisiert werden; manuelle Prüfung erforderlich. $packageException"
                                DiagnosticOutput=$_.Exception.ToString(); RequiresManualAction=$true
                            }
                        }
                    }
                }
                    else {
                    if ($sourceFailureLines.Count -gt 0) {
                        $wingetFailureDetails = @()
                        if (-not [string]::IsNullOrWhiteSpace($wingetBootstrapMessage)) { $wingetFailureDetails += $wingetBootstrapMessage.Trim() }
                        foreach ($failureLine in $sourceFailureLines) {
                            $compactFailure = Get-WingetCompactOutput -Text ([string]$failureLine)
                            if ($compactFailure -and $wingetFailureDetails -notcontains $compactFailure) { $wingetFailureDetails += $compactFailure }
                        }
                        $actionOutput = $wingetFailureDetails -join ' '
                    }
                    $result += [PSCustomObject]@{ Manager='Winget'; Available=$true; Success=($sourceFailureLines.Count -eq 0); Skipped=$false; SkipReason=''; ExitCode=$(if ($sourceFailureLines.Count -gt 0) { 1 } else { 0 }); Packages=$packageLines; AvailableOutput=$availableOutput; ActionOutput=$actionOutput }
                }
                }
                catch {
                    $result += [PSCustomObject]@{ Manager='Winget'; Available=$true; Success=$false; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput=$_.Exception.Message }
                }
            }
            else {
                $result += [PSCustomObject]@{ Manager='Winget'; Available=$false; Success=$true; Skipped=$false; SkipReason=''; ExitCode=$null; Packages=@(); AvailableOutput=''; ActionOutput='' }
            }
            if (-not [string]::IsNullOrWhiteSpace($wingetBootstrapMessage)) {
                foreach ($wingetResult in @($result | Where-Object { $_.Manager -eq 'Winget' })) {
                    Add-Member -InputObject $wingetResult -NotePropertyName BootstrapMessage -NotePropertyValue $wingetBootstrapMessage -Force
                }
            }
        }
        return @($result)
    }

    $localNames = @($env:COMPUTERNAME, [System.Net.Dns]::GetHostName()) | Where-Object { $_ }
    if (-not [string]::IsNullOrWhiteSpace($env:USERDNSDOMAIN)) { $localNames += "$env:COMPUTERNAME.$env:USERDNSDOMAIN" }
    if ($localNames -contains $ComputerName) {
        $packageResults = @(& $packageScript $Mode $EnableWinget $EnableChocolatey)
    }
    else {
        $invokeParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo
        $invokeParameters.ScriptBlock = $packageScript
        $invokeParameters.ArgumentList = @($Mode, $EnableWinget, $EnableChocolatey)
        $packageResults = @(Invoke-Command @invokeParameters)
    }
    foreach ($packageResult in $packageResults) {
        $bootstrapMessageProperty = $packageResult.PSObject.Properties['BootstrapMessage']
        if ($packageResult.Manager -eq 'Winget' -and $bootstrapMessageProperty -and -not [string]::IsNullOrWhiteSpace([string]$bootstrapMessageProperty.Value)) {
            Write-CommonLog $WriteLog ([string]$bootstrapMessageProperty.Value)
        }
    }
    return @($packageResults)
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

Export-ModuleMember -Function Get-WindowsUpdateSettings, Protect-WindowsUpdateSettingsFilePassword, Protect-WindowsUpdateSettingsObjectPassword, Get-WindowsUpdateClientCertificateAuthInfo, Get-WindowsUpdateTargets, New-WindowsUpdateInvokeCommandParams, Initialize-WindowsUpdateRemoting, Test-WindowsUpdateJeaSupported, Invoke-WindowsUpdateSystemTask, Invoke-WindowsUpdateWithRetry, Get-WindowsUpdateSshArguments, Invoke-WindowsUpdatePackageManagers, Invoke-WindowsUpdateFileRetention, Write-WindowsUpdateLog, Write-WindowsUpdateConsoleSummary, Invoke-WindowsUpdateRetentionWithLog, ConvertTo-WindowsUpdateMailSafeString, Send-WindowsUpdateHtmlMail, Add-WindowsUpdateTrustedHost, Update-PSWindowsUpdateModule
