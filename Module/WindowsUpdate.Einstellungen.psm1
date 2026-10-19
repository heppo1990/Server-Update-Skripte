# Fachmodul: WindowsUpdate.Einstellungen
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

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
        $directory = Split-Path -Parent $Path
        $backupDirectory = Join-Path $directory 'Sicherungen'
        New-Item -Path $backupDirectory -ItemType Directory -Force | Out-Null
        $backupPath = Join-Path $backupDirectory ('{0}.bak.{1}_{2}' -f (Split-Path -Leaf $Path), (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 8)))
        Write-WindowsUpdateJsonAtomically -Path $backupPath -Value $document
        Write-WindowsUpdateJsonAtomically -Path $Path -Value $document
        Write-CommonLog $WriteLog "Mailpasswort in '$([IO.Path]::GetFileName($Path))' automatisch mit DPAPI geschützt."
    }
    # Ältere automatische Sicherungen aus früheren Skriptständen schützen,
    # falls sie noch ein Klartextpasswort enthalten. Dafür keine weitere
    # Sicherung erstellen.
    $directory = Split-Path -Parent $Path
    $leaf = Split-Path -Leaf $Path
    $backupDirectory = Join-Path $directory 'Sicherungen'
    $oldBackups = @(
        Get-ChildItem -LiteralPath $directory -Filter ($leaf + '.bak.*') -File -ErrorAction SilentlyContinue
        Get-ChildItem -LiteralPath $backupDirectory -Filter ($leaf + '.bak.*') -File -ErrorAction SilentlyContinue
    )
    foreach ($oldBackup in $oldBackups) {
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
