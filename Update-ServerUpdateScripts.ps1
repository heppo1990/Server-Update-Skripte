# Aktualisiert vor dem Skriptlauf alle geänderten Programmdateien aus dem öffentlichen main-Branch.

function Get-ServerUpdateGitBlobSha1 {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $content = [IO.File]::ReadAllBytes($Path)
    $header = [Text.Encoding]::UTF8.GetBytes(('blob {0}' -f $content.Length))
    $gitObject = New-Object byte[] ($header.Length + 1 + $content.Length)
    [Array]::Copy($header, 0, $gitObject, 0, $header.Length)
    $gitObject[$header.Length] = 0
    [Array]::Copy($content, 0, $gitObject, $header.Length + 1, $content.Length)
    $sha1 = [Security.Cryptography.SHA1]::Create()
    try { return ([BitConverter]::ToString($sha1.ComputeHash($gitObject))).Replace('-', '').ToLowerInvariant() }
    finally { $sha1.Dispose() }
}

function Get-ServerUpdateConfiguration {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ScriptName
    )

    $configuration = @{
        LinuxHosts = @()
        HomeAssistantHost = ''
    }
    $configurationFiles = @(
        (Join-Path $ScriptRoot 'default_settings.json'),
        (Join-Path $ScriptRoot 'settings.json'),
        (Join-Path $ScriptRoot ($ScriptName + '.settings.json'))
    )
    $configurationFiles += @(Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.settings.json' -File -ErrorAction SilentlyContinue | ForEach-Object { $_.FullName })
    $configurationFiles = @($configurationFiles | Select-Object -Unique)

    foreach ($configurationFile in $configurationFiles) {
        if (-not (Test-Path -LiteralPath $configurationFile -PathType Leaf)) { continue }
        try {
            $settings = Get-Content -LiteralPath $configurationFile -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($settings.LinuxSettings -and $settings.LinuxSettings.PSObject.Properties['Hosts']) {
                $configuredLinuxHosts = @($settings.LinuxSettings.Hosts | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) })
                if ($configuredLinuxHosts.Count -gt 0) {
                    $configuration.LinuxHosts = @($configuration.LinuxHosts + $configuredLinuxHosts | Select-Object -Unique)
                }
            }
            if ($settings.HomeAssistantSettings -and $settings.HomeAssistantSettings.PSObject.Properties['Host']) {
                $configuredHomeAssistantHost = [string]$settings.HomeAssistantSettings.Host
                if (-not [string]::IsNullOrWhiteSpace($configuredHomeAssistantHost)) {
                    $configuration.HomeAssistantHost = $configuredHomeAssistantHost
                }
            }
        }
        catch {
            Write-Warning "Updateprüfung: Konfiguration '$([IO.Path]::GetFileName($configurationFile))' konnte nicht gelesen werden; optionale Skripte werden nicht zusätzlich geladen."
        }
    }

    return $configuration
}

function Get-ServerUpdateRequiredFiles {
    param(
        [Parameter(Mandatory)][string]$ScriptRoot,
        [Parameter(Mandatory)][string]$ScriptPath,
        [Parameter(Mandatory)][System.Collections.IDictionary]$RepositoryBlobs,
        [System.Collections.IDictionary]$BoundParameters = @{}
    )

    $scriptName = [IO.Path]::GetFileName($ScriptPath)
    $requiredFiles = [System.Collections.Generic.List[object]]::new()
    $windowsOnlyRun = $false
    if ($scriptName -eq 'Install-ServersUpdates.ps1' -or $scriptName -eq 'Verteilung_WindowsUpdateAdmConfig.ps1') {
        $targetComputerRun = (@($BoundParameters.Keys) -contains 'TargetComputer') -and @($BoundParameters['TargetComputer'] | Where-Object { $_ }).Count -gt 0
        $cleanupOnlyRun = (@($BoundParameters.Keys) -contains 'CleanupLegacyTempOnly') -and [bool]$BoundParameters['CleanupLegacyTempOnly']
        $windowsOnlyRun = $targetComputerRun -or $cleanupOnlyRun
    }

    $configuration = @{ LinuxHosts = @(); HomeAssistantHost = '' }
    if (-not $windowsOnlyRun) {
        $configuration = Get-ServerUpdateConfiguration -ScriptRoot $ScriptRoot -ScriptName $scriptName
    }

    $linuxRequired = $configuration.LinuxHosts.Count -gt 0 -or $scriptName -eq 'Install-Linux Updates.ps1'
    $homeAssistantRequired = -not [string]::IsNullOrWhiteSpace($configuration.HomeAssistantHost) -or $scriptName -eq 'Install-HomeAssistant Updates.ps1'

    foreach ($relativePath in $RepositoryBlobs.Keys) {
        if ([string]::IsNullOrWhiteSpace($relativePath) -or [IO.Path]::IsPathRooted($relativePath) -or $relativePath -match '(^|/)\.\.(/|$)') { continue }
        if ($relativePath -match '(^|/)\.git(/|$)') { continue }

        $leafName = [IO.Path]::GetFileName($relativePath)
        if ($leafName -ieq '.gitignore' -or [IO.Path]::GetExtension($leafName) -ieq '.md') { continue }
        if ($leafName -ieq 'settings.json' -or $leafName -like '*.settings.json') { continue }
        if ($leafName -match '\.(cer|pfx|p12|key)$') { continue }
        if ($leafName -match '^\.env($|\.)|(^|[._-])(secret|secrets|credential|credentials)([._-]|$)') { continue }
        if ($relativePath -match '(^|/)(Logs|Reports|Certificates|Secrets|RuntimeData)(/|$)') { continue }

        $isLinuxFile = $leafName -match '^(Install-Linux|Linux[._-])' -or $relativePath -match '(^|/)(Linux|linux)/'
        $isHomeAssistantFile = $leafName -match '^(Install-HomeAssistant|HomeAssistant[._-]|HA[._-])' -or $relativePath -match '(^|/)(HomeAssistant|HA)/'
        if ($isLinuxFile -and -not $linuxRequired) { continue }
        if ($isHomeAssistantFile -and -not $homeAssistantRequired) { continue }
        $requiredFiles.Add([PSCustomObject]@{ Path = [string]$relativePath; Sha = [string]$RepositoryBlobs[$relativePath] })
    }

    return @($requiredFiles | Sort-Object Path -Unique)
}

# Ergänzt beim Skriptupdate nur fehlende Standardwerte; vorhandene Kundenwerte bleiben erhalten.
function Copy-ServerUpdateJsonValue {
    param([AllowNull()][object]$Value)
    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $copy = [PSCustomObject]@{}
        foreach ($property in $Value.PSObject.Properties) {
            $propertyCopy = Copy-ServerUpdateJsonValue -Value $property.Value
            Add-Member -InputObject $copy -NotePropertyName $property.Name -NotePropertyValue $propertyCopy
        }
        return $copy
    }
    if ($Value -is [array]) {
        $copy = @(
            foreach ($item in $Value) { Copy-ServerUpdateJsonValue -Value $item }
        )
        return ,$copy
    }
    return $Value
}

function Add-ServerUpdateMissingJsonProperties {
    param(
        [Parameter(Mandatory)][object]$Destination,
        [Parameter(Mandatory)][object]$Defaults
    )
    # JSON-Objekte werden auf Windows PowerShell 5 und PowerShell 7 als PSCustomObject geliefert.
    # Die konkrete Parametertypbindung auf PSCustomObject kann bei PS7 trotz passendem Laufzeittyp scheitern.
    if ($Destination -isnot [System.Management.Automation.PSCustomObject] -or
        $Defaults -isnot [System.Management.Automation.PSCustomObject]) { return 0 }

    $added = 0
    foreach ($defaultProperty in $Defaults.PSObject.Properties) {
        $destinationProperty = $Destination.PSObject.Properties[$defaultProperty.Name]
        if ($null -eq $destinationProperty) {
            $defaultValue = Copy-ServerUpdateJsonValue -Value $defaultProperty.Value
            Add-Member -InputObject $Destination -NotePropertyName $defaultProperty.Name -NotePropertyValue $defaultValue
            $added++
        }
        elseif ($destinationProperty.Value -is [System.Management.Automation.PSCustomObject] -and
                $defaultProperty.Value -is [System.Management.Automation.PSCustomObject]) {
            $added += Add-ServerUpdateMissingJsonProperties -Destination $destinationProperty.Value -Defaults $defaultProperty.Value
        }
    }
    return $added
}

function Merge-ServerUpdateJsonProperties {
    param([object]$Destination, [object]$Overrides)
    if ($Destination -isnot [System.Management.Automation.PSCustomObject] -or
        $Overrides -isnot [System.Management.Automation.PSCustomObject]) { return }

    foreach ($overrideProperty in $Overrides.PSObject.Properties) {
        $destinationProperty = $Destination.PSObject.Properties[$overrideProperty.Name]
        if ($null -ne $destinationProperty -and
            $destinationProperty.Value -is [System.Management.Automation.PSCustomObject] -and
            $overrideProperty.Value -is [System.Management.Automation.PSCustomObject]) {
            Merge-ServerUpdateJsonProperties -Destination $destinationProperty.Value -Overrides $overrideProperty.Value
        }
        else {
            $overrideValue = Copy-ServerUpdateJsonValue -Value $overrideProperty.Value
            Add-Member -InputObject $Destination -NotePropertyName $overrideProperty.Name -NotePropertyValue $overrideValue -Force
        }
    }
}

function Convert-ServerUpdateJsonToDefaultOrder {
    param([AllowNull()][object]$Value, [AllowNull()][object]$Defaults)

    if ($null -eq $Value) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        $ordered = [ordered]@{}
        if ($Defaults -is [System.Management.Automation.PSCustomObject]) {
            foreach ($defaultProperty in $Defaults.PSObject.Properties) {
                $valueProperty = $Value.PSObject.Properties[$defaultProperty.Name]
                if ($null -ne $valueProperty) {
                    $ordered[$defaultProperty.Name] = Convert-ServerUpdateJsonToDefaultOrder -Value $valueProperty.Value -Defaults $defaultProperty.Value
                }
                else {
                    $ordered[$defaultProperty.Name] = Copy-ServerUpdateJsonValue -Value $defaultProperty.Value
                }
            }
        }
        foreach ($valueProperty in $Value.PSObject.Properties) {
            if ($ordered.Contains($valueProperty.Name)) { continue }
            $ordered[$valueProperty.Name] = Convert-ServerUpdateJsonToDefaultOrder -Value $valueProperty.Value -Defaults $null
        }
        return $ordered
    }
    if ($Value -is [array]) {
        $items = @(
            foreach ($item in $Value) { Convert-ServerUpdateJsonToDefaultOrder -Value $item -Defaults $null }
        )
        return ,$items
    }
    return $Value
}

function Format-ServerUpdateJsonArrays {
    param([Parameter(Mandatory)][string]$Json)
    # ConvertTo-Json formatiert je nach PowerShell-Version mit anderen
    # Leerzeichen. Für migrierte Dateien wird deshalb das JSON selbst neu
    # eingerückt: ein Tab je Verschachtelungsebene wie in default_settings.json.
    # Zeichen innerhalb von JSON-Strings (auch Leerzeichen und Escapes) bleiben unverändert.
    $builder = [System.Text.StringBuilder]::new()
    $depth = 0
    $insideString = $false
    $escaped = $false
    $needsIndent = $false
    $newline = [Environment]::NewLine

    for ($index = 0; $index -lt $Json.Length; $index++) {
        $character = $Json[$index]
        $indentWasWritten = $false
        if ($insideString) {
            [void]$builder.Append($character)
            if ($escaped) { $escaped = $false }
            elseif ($character -eq '\') { $escaped = $true }
            elseif ($character -eq '"') { $insideString = $false }
            continue
        }

        if ([char]::IsWhiteSpace($character)) { continue }
        if ($needsIndent) {
            $indentDepth = if ($character -eq ']' -or $character -eq '}') { [Math]::Max(0, $depth - 1) } else { $depth }
            for ($tab = 0; $tab -lt $indentDepth; $tab++) { [void]$builder.Append("`t") }
            $needsIndent = $false
            $indentWasWritten = $true
        }

        switch ([string]$character) {
            '"' { $insideString = $true; [void]$builder.Append($character) }
            '{' { [void]$builder.Append($character); $depth++; [void]$builder.Append($newline); $needsIndent = $true }
            '[' { [void]$builder.Append($character); $depth++; [void]$builder.Append($newline); $needsIndent = $true }
            '}' {
                if (-not $indentWasWritten) {
                    [void]$builder.Append($newline)
                    for ($tab = 0; $tab -lt [Math]::Max(0, $depth - 1); $tab++) { [void]$builder.Append("`t") }
                }
                $depth = [Math]::Max(0, $depth - 1)
                [void]$builder.Append($character)
            }
            ']' {
                if (-not $indentWasWritten) {
                    [void]$builder.Append($newline)
                    for ($tab = 0; $tab -lt [Math]::Max(0, $depth - 1); $tab++) { [void]$builder.Append("`t") }
                }
                $depth = [Math]::Max(0, $depth - 1)
                [void]$builder.Append($character)
            }
            ',' { [void]$builder.Append(','); [void]$builder.Append($newline); $needsIndent = $true }
            ':' { [void]$builder.Append(': ') }
            default { [void]$builder.Append($character) }
        }
    }
    [void]$builder.Append($newline)
    return $builder.ToString()
}
function Remove-ServerUpdateObsoleteJsonProperties {
    param([Parameter(Mandatory)][AllowNull()][object]$Value, [int]$RemovedCount = 0)
    if ($null -eq $Value) { return $RemovedCount }
    $obsoleteNames = @('DeferredUpdateDelayMinutes', 'ServiceAccountName', 'ServiceAccountPassword', 'HypervisorAccountName', 'HypervisorAccountPassword')
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($property in @($Value.PSObject.Properties)) {
            if ($property.Name -in $obsoleteNames) {
                $Value.PSObject.Properties.Remove($property.Name)
                $RemovedCount++
                continue
            }
            $RemovedCount = Remove-ServerUpdateObsoleteJsonProperties -Value $property.Value -RemovedCount $RemovedCount
        }
    }
    elseif ($Value -is [array]) {
        foreach ($item in $Value) { $RemovedCount = Remove-ServerUpdateObsoleteJsonProperties -Value $item -RemovedCount $RemovedCount }
    }
    return $RemovedCount
}

function Remove-ServerUpdateJsonProperty {
    param(
        [Parameter(Mandatory)][object]$Destination,
        [Parameter(Mandatory)][string]$PropertyName
    )
    if ($Destination -isnot [System.Management.Automation.PSCustomObject]) { return $false }
    $property = $Destination.PSObject.Properties[$PropertyName]
    if ($null -ne $property) {
        $Destination.PSObject.Properties.Remove($PropertyName)
        return $true
    }
    return $false
}

function Convert-ServerUpdateLegacySettings {
    param([Parameter(Mandatory)][object]$Settings, [Parameter(Mandatory)][string]$Path)

    if ($Settings -isnot [System.Management.Automation.PSCustomObject]) { return 0 }
    $mailProperty = @($Settings.PSObject.Properties | Where-Object { $_.Name -ieq 'MailSettings' } | Select-Object -First 1)
    if ($mailProperty.Count -eq 0 -or $mailProperty[0].Value -isnot [System.Management.Automation.PSCustomObject]) { return 0 }

    $mail = $mailProperty[0].Value
    $migrated = 0
    if (-not [string]::Equals($mailProperty[0].Name, 'MailSettings', [StringComparison]::Ordinal)) {
        $Settings.PSObject.Properties.Remove($mailProperty[0].Name)
        Add-Member -InputObject $Settings -NotePropertyName 'MailSettings' -NotePropertyValue $mail
        $migrated++
    }

    $legacySendMail = $mail.PSObject.Properties['SendMail']
    $legacySubject = $mail.PSObject.Properties['Subject']
    if (-not $legacySendMail -and -not $legacySubject) { return $migrated }

    # Nur SendMail wird anhand des Dateinamens einem Berichtslauf zugeordnet.
    # Alle übrigen Mailfelder (SMTP, Zugangsdaten, Empfänger usw.) verbleiben
    # unverändert im gemeinsamen MailSettings-Bereich.
    $actionNames = @()
    $settingsFileName = [IO.Path]::GetFileName($Path)
    if ($settingsFileName -match '(?i)^Check-ServersUpdates') { $actionNames = @('Check') }
    elseif ($settingsFileName -match '(?i)^Download-ServersUpdates') { $actionNames = @('Download') }
    elseif ($settingsFileName -match '(?i)^Install-ServersUpdates') { $actionNames = @('Install') }
    $settingsDirectory = Split-Path -Parent $Path
    $canonicalGeneralSettingsPath = Join-Path $settingsDirectory 'settings.json'
    $legacyGeneralSettingsPath = Join-Path $settingsDirectory 'default.settings.json'
    $isLegacyGeneralSettings = $settingsFileName -ieq 'default.settings.json' -and
        -not (Test-Path -LiteralPath $canonicalGeneralSettingsPath -PathType Leaf)
    $isGeneralSettings = $settingsFileName -ieq 'settings.json' -or $isLegacyGeneralSettings
    if ($isGeneralSettings) { $actionNames = @('Check', 'Download', 'Install') }
    elseif ($actionNames.Count -eq 0) { $actionNames = @() }

    # Bei einer skriptspezifischen Datei ohne allgemeine settings.json werden
    # die anderen Mailberichte ausdrücklich deaktiviert. Gibt es eine allgemeine
    # Datei, kommen deren Werte für die übrigen Läufe über fileDefaults hinzu.
    $hasGeneralSettings = (Test-Path -LiteralPath $canonicalGeneralSettingsPath -PathType Leaf) -or
        (-not (Test-Path -LiteralPath $canonicalGeneralSettingsPath -PathType Leaf) -and
            (Test-Path -LiteralPath $legacyGeneralSettingsPath -PathType Leaf))
    $actionsToInitialize = if ($isGeneralSettings -or $hasGeneralSettings) {
        $actionNames
    }
    elseif ($actionNames.Count -gt 0) {
        @('Check', 'Download', 'Install')
    }
    else { @() }

    foreach ($actionName in $actionsToInitialize) {
        $actionProperty = $mail.PSObject.Properties[$actionName]
        if (-not $actionProperty -or $null -eq $actionProperty.Value) {
            $action = [PSCustomObject]@{}
            Add-Member -InputObject $mail -NotePropertyName $actionName -NotePropertyValue $action
            $actionProperty = $mail.PSObject.Properties[$actionName]
            $migrated++
        }
        if ($actionProperty.Value -isnot [System.Management.Automation.PSCustomObject]) { continue }

        if ($legacySendMail -and ($isGeneralSettings -or $actionNames -contains $actionName)) {
            Add-Member -InputObject $actionProperty.Value -NotePropertyName 'SendMail' -NotePropertyValue $legacySendMail.Value -Force
            $migrated++
        }
        elseif ($legacySendMail -and $actionNames.Count -gt 0 -and -not $hasGeneralSettings) {
            Add-Member -InputObject $actionProperty.Value -NotePropertyName 'SendMail' -NotePropertyValue $false -Force
            $migrated++
        }
    }

    # Der frühere Betreff wird verworfen. Die aktuellen Standardbetreffe werden
    # anschließend aus default_settings.json ergänzt und beim Versand generiert.
    if ($legacySubject) { $mail.PSObject.Properties.Remove($legacySubject.Name); $migrated++ }
    if ($legacySendMail) { $mail.PSObject.Properties.Remove($legacySendMail.Name); $migrated++ }
    return $migrated
}

function Update-ServerUpdateSettingsDefaults {
    param([Parameter(Mandatory)][string]$ScriptRoot)

    $defaultsPath = Join-Path $ScriptRoot 'default_settings.json'
    if (-not (Test-Path -LiteralPath $defaultsPath -PathType Leaf)) { return }
    try {
        $defaults = Get-Content -LiteralPath $defaultsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
    }
    catch {
        Write-Warning "Standard-Einstellungen konnten nicht eingelesen werden; Kundeneinstellungen bleiben unverändert. Ursache: $($_.Exception.Message)"
        return
    }

    $modulePath = Join-Path $ScriptRoot 'WindowsUpdate.Common.psm1'
    if (-not (Test-Path -LiteralPath $modulePath -PathType Leaf)) {
        Write-Warning 'WindowsUpdate.Common.psm1 fehlt; Settings werden zur Sicherheit nicht migriert.'
        return
    }
    try {
        Import-Module -Name $modulePath -Force -ErrorAction Stop
        $settingsPasswordProtector = Get-Command -Name Protect-WindowsUpdateSettingsObjectPassword -ErrorAction Stop
    }
    catch {
        Write-Warning "DPAPI-Schutz konnte nicht geladen werden; Settings bleiben unverändert. Ursache: $($_.Exception.Message)"
        return
    }
    $generalSettingsPath = Join-Path $ScriptRoot 'settings.json'
    $legacyGeneralSettingsPath = Join-Path $ScriptRoot 'default.settings.json'
    if (-not (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf) -and
        (Test-Path -LiteralPath $legacyGeneralSettingsPath -PathType Leaf)) {
        $generalSettingsPath = $legacyGeneralSettingsPath
    }
    $settingsPaths = [System.Collections.Generic.List[string]]::new()
    if (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf) { $settingsPaths.Add($generalSettingsPath) }
    foreach ($scriptSettingsFile in @(Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.settings.json' -File -ErrorAction SilentlyContinue)) {
        if ($scriptSettingsFile.Name -ieq 'default.settings.json' -and $generalSettingsPath -ine $legacyGeneralSettingsPath) { continue }
        if (-not $settingsPaths.Contains($scriptSettingsFile.FullName)) { $settingsPaths.Add($scriptSettingsFile.FullName) }
    }

    foreach ($settingsPath in $settingsPaths) {
        $temporaryPath = $null
        try {
            $originalSettingsText = Get-Content -LiteralPath $settingsPath -Raw -Encoding UTF8
            $settings = $originalSettingsText | ConvertFrom-Json -ErrorAction Stop
            if ($settings -isnot [System.Management.Automation.PSCustomObject] -or
                $defaults -isnot [System.Management.Automation.PSCustomObject]) { continue }

            # Klartextpasswort zuerst nur im Speicher schützen. Die einzelne
            # Sicherung entsteht anschließend gemeinsam mit der Migration.
            $passwordWasProtected = [bool](& $settingsPasswordProtector -Document $settings)
            $backupSettings = Copy-ServerUpdateJsonValue -Value $settings
            # Vergleiche das Layout mit einer kanonischen Formatierung desselben
            # JSON-Objekts. So vermeiden unterschiedliche ConvertTo-Json-Ausgaben
            # in PS5/PS7 wiederholte Backups bei bereits formatierten Dateien.
            $originalCanonicalJson = Format-ServerUpdateJsonArrays -Json (ConvertTo-Json -InputObject $settings -Depth 100)
            # Skriptspezifische Dateien erhalten fehlende Werte aus der effektiven
            # gemeinsamen Konfiguration; ihre bereits gesetzten Werte bleiben maßgeblich.
            $fileDefaults = $defaults
            if ($settingsPath -ine $generalSettingsPath -and (Test-Path -LiteralPath $generalSettingsPath -PathType Leaf)) {
                $fileDefaults = Copy-ServerUpdateJsonValue -Value $defaults
                $generalSettings = Get-Content -LiteralPath $generalSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                Merge-ServerUpdateJsonProperties -Destination $fileDefaults -Overrides $generalSettings
            }

            # Veraltete Optionen und entfernte Dienstkontoangaben kommen nicht
            # in die migrierte Datei zurück.
            $removedCount = Remove-ServerUpdateObsoleteJsonProperties -Value $settings

            $legacyMigrationCount = Convert-ServerUpdateLegacySettings -Settings $settings -Path $settingsPath
            $addedCount = Add-ServerUpdateMissingJsonProperties -Destination $settings -Defaults $fileDefaults
            $orderedSettings = Convert-ServerUpdateJsonToDefaultOrder -Value $settings -Defaults $fileDefaults
            $currentCompactJson = ConvertTo-Json -InputObject $settings -Depth 100 -Compress
            $orderedCompactJson = ConvertTo-Json -InputObject $orderedSettings -Depth 100 -Compress
            $orderChanged = $currentCompactJson -cne $orderedCompactJson
            $backupJson = Format-ServerUpdateJsonArrays -Json (ConvertTo-Json -InputObject $backupSettings -Depth 100)
            $updatedJson = Format-ServerUpdateJsonArrays -Json (ConvertTo-Json -InputObject $orderedSettings -Depth 100)
            $originalFormatComparable = [regex]::Replace($originalSettingsText.TrimStart([char]0xFEFF).Replace("`r`n", "`n"), "`n+\z", '')
            $canonicalFormatComparable = [regex]::Replace($originalCanonicalJson.Replace("`r`n", "`n"), "`n+\z", '')
            $formatChanged = $originalFormatComparable -cne $canonicalFormatComparable
            if ($addedCount -eq 0 -and $removedCount -eq 0 -and $legacyMigrationCount -eq 0 -and -not $orderChanged -and -not $passwordWasProtected -and -not $formatChanged) { continue }

            # Eindeutiger Name: Auch parallele Update-Läufe überschreiben keine Sicherung.
            $backupPath = '{0}.bak.{1}_{2}' -f $settingsPath, (Get-Date -Format 'yyyyMMdd_HHmmss_fff'), ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $temporaryPath = '{0}.{1}.tmp' -f $settingsPath, [guid]::NewGuid().ToString('N')
            [System.IO.File]::WriteAllText($backupPath, $backupJson, ([System.Text.UTF8Encoding]::new($false)))
            [System.IO.File]::WriteAllText($temporaryPath, $updatedJson, ([System.Text.UTF8Encoding]::new($false)))
            # Die geschützte Sicherung wurde bereits angelegt. Der atomare
            # Austausch erzeugt keine zweite Sicherung mit Klartextpasswort.
            $moveWithOverwrite = [System.IO.File].GetMethod('Move', [type[]]@([string], [string], [bool]))
            if ($null -ne $moveWithOverwrite) { [System.IO.File]::Move($temporaryPath, $settingsPath, $true) }
            else {
                # .NET Framework (Windows PowerShell 5.1) verlangt einen
                # gültigen Sicherungspfad für File.Replace. Diese temporäre
                # Sicherung wird direkt wieder entfernt; die dauerhafte
                # Sicherung ist bereits unter $backupPath angelegt.
                $replaceBackupPath = $temporaryPath + '.replace.bak'
                try { [System.IO.File]::Replace($temporaryPath, $settingsPath, $replaceBackupPath) }
                finally {
                    if (Test-Path -LiteralPath $replaceBackupPath -PathType Leaf) {
                        [System.IO.File]::Delete($replaceBackupPath)
                    }
                }
            }
            $temporaryPath = $null
            if (-not (Test-Path -LiteralPath $backupPath -PathType Leaf) -or -not (Test-Path -LiteralPath $settingsPath -PathType Leaf)) {
                throw 'Einstellungsdatei oder Sicherung fehlt nach dem atomaren Austausch.'
            }
            if ($addedCount -eq 0 -and $removedCount -eq 0 -and $legacyMigrationCount -eq 0 -and -not $orderChanged -and -not $passwordWasProtected) {
                Write-Host "Einrückung der Settings vereinheitlicht; Sicherung: $backupPath" -ForegroundColor Cyan
            } else {
                Write-Host ("{0} fehlende Standard-Einstellung(en) ergänzt, {1} veraltete Einstellung(en) entfernt und {2} Legacy-Einstellung(en) konvertiert; Sicherung: {3}" -f $addedCount, $removedCount, $legacyMigrationCount, $backupPath) -ForegroundColor Cyan
            }
        }
        catch {
            Write-Warning "Standardwerte konnten in '$([IO.Path]::GetFileName($settingsPath))' nicht ergänzt werden. Vorhandene Einstellungen bleiben erhalten. Ursache: $($_.Exception.Message)"
        }
        finally {
            if ($temporaryPath -and (Test-Path -LiteralPath $temporaryPath -PathType Leaf)) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # Eine alleinstehende alte default.settings.json war die allgemeine
    # Kundeneinstellungsdatei. Nach erfolgreicher Migration wird sie zur heute
    # verwendeten settings.json; eine bestehende settings.json bleibt unberührt.
    if ($generalSettingsPath -ieq $legacyGeneralSettingsPath -and
        (Test-Path -LiteralPath $legacyGeneralSettingsPath -PathType Leaf) -and
        -not (Test-Path -LiteralPath (Join-Path $ScriptRoot 'settings.json') -PathType Leaf)) {
        try {
            $promotedSettings = Get-Content -LiteralPath $legacyGeneralSettingsPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
            if ($promotedSettings -isnot [System.Management.Automation.PSCustomObject] -or
                -not $promotedSettings.PSObject.Properties['UpdateSettings']) {
                throw 'Die Datei enthält keine gültige UpdateSettings-Konfiguration.'
            }
            $promotedMailProperty = $promotedSettings.PSObject.Properties['MailSettings']
            if ($promotedMailProperty -and ($promotedMailProperty.Value.PSObject.Properties['SendMail'] -or $promotedMailProperty.Value.PSObject.Properties['Subject'])) {
                throw 'Die alte Mail-Konfiguration wurde nicht vollständig migriert; die Umbenennung wird ausgelassen.'
            }
            [System.IO.File]::Move($legacyGeneralSettingsPath, (Join-Path $ScriptRoot 'settings.json'))
            Write-Host 'Die migrierte default.settings.json wurde in settings.json umbenannt.' -ForegroundColor Cyan
        }
        catch {
            Write-Warning "Die alte default.settings.json konnte nicht sicher in settings.json umbenannt werden. Sie bleibt erhalten. Ursache: $($_.Exception.Message)"
        }
    }

    # Es bleiben höchstens drei automatisch erzeugte Sicherungen im Skriptordner liegen.
    try {
        $backupFiles = @(Get-ChildItem -LiteralPath $ScriptRoot -Filter '*.json.bak.*' -File -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -match '^(?:settings|.+\.settings)\.json\.bak\.\d{8}_\d{6}_\d{3}(?:_[a-f0-9]{8})?$' } |
            Sort-Object -Property LastWriteTimeUtc, Name -Descending)
        foreach ($oldBackup in @($backupFiles | Select-Object -Skip 3)) {
            Remove-Item -LiteralPath $oldBackup.FullName -Force -ErrorAction Stop
        }
    }
    catch {
        Write-Warning "Alte Sicherungen der Einstellungen konnten nicht vollständig bereinigt werden. Ursache: $($_.Exception.Message)"
    }
}

# Schützt Klartextpasswörter vor jeder Settings-Migration, damit weder die
# geänderte Datei noch eine dabei erzeugte Sicherung ein Klartextpasswort enthält.
function Invoke-ServerUpdateScripts {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$ScriptPath,
        [System.Collections.IDictionary]$BoundParameters = @{},
        [object[]]$RemainingArguments = @()
    )

    $scriptRoot = Split-Path -Parent $ScriptPath
    $scriptName = [IO.Path]::GetFileName($ScriptPath)
    $repoOwner = 'heppo1990'
    $repoName = 'Server-Update-Skripte'
    $branch = 'main'
    $cacheDirectory = Join-Path $env:ProgramData 'ServerUpdateSkripte'
    $cachePath = Join-Path $cacheDirectory 'UpdateCache.json'
    $latestCommit = $env:SERVER_UPDATE_LATEST_COMMIT
    $restartRequired = $false

    try {
        if ($latestCommit -notmatch '^[0-9a-f]{40}$') {
            $feedUrl = "https://github.com/$repoOwner/$repoName/commits/$branch.atom"
            $feed = Invoke-ServerUpdateGitHubRequest -Description 'Commitfeed' -Request {
                Invoke-WebRequest -Uri $feedUrl -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            }
            $commitMatch = [regex]::Match([string]$feed.Content, '::Commit/([0-9a-f]{40})')
            if (-not $commitMatch.Success) { throw 'Die aktuelle Commit-ID konnte nicht aus dem GitHub-Feed gelesen werden.' }
            $latestCommit = $commitMatch.Groups[1].Value
            $env:SERVER_UPDATE_LATEST_COMMIT = $latestCommit
        }

        $manifestCommit = ''
        $repositoryBlobs = @{}
        if (Test-Path -LiteralPath $cachePath -PathType Leaf) {
            try {
                $existingCache = Get-Content -LiteralPath $cachePath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                $manifestCommit = [string]$existingCache.ManifestCommit
                if ($existingCache.RepositoryBlobs) {
                    foreach ($property in $existingCache.RepositoryBlobs.PSObject.Properties) {
                        $repositoryBlobs[$property.Name] = [string]$property.Value
                    }
                }
            }
            catch { $repositoryBlobs = @{} }
        }

        if ($manifestCommit -ne $latestCommit -or $repositoryBlobs.Count -eq 0) {
            $headers = @{ Accept = 'application/vnd.github+json'; 'User-Agent' = 'Server-Update-Skripte-Updater' }
            $treeUrl = "https://api.github.com/repos/$repoOwner/$repoName/git/trees/$latestCommit`?recursive=1"
            $treeResponse = Invoke-ServerUpdateGitHubRequest -Description 'Dateiliste' -Request {
                Invoke-RestMethod -Uri $treeUrl -Headers $headers -TimeoutSec 20 -ErrorAction Stop
            }
            if ($treeResponse.truncated) { throw 'GitHub lieferte eine unvollständige Dateiliste.' }
            $repositoryBlobs = @{}
            foreach ($item in @($treeResponse.tree | Where-Object { $_.type -eq 'blob' })) {
                $repositoryBlobs[[string]$item.path] = [string]$item.sha
            }
            if ($repositoryBlobs.Count -eq 0) { throw 'Die Dateiliste des Repositorys ist leer.' }
            $manifestCommit = $latestCommit
        }

        $requiredFiles = Get-ServerUpdateRequiredFiles -ScriptRoot $scriptRoot -ScriptPath $ScriptPath -RepositoryBlobs $repositoryBlobs -BoundParameters $BoundParameters
        $isConnectionOnlyRun = (@($BoundParameters.Keys) -contains 'ConnectionOnly') -and [bool]$BoundParameters['ConnectionOnly']

        $filesToFetch = @($requiredFiles | Where-Object {
            $localPath = Join-Path $scriptRoot $_.Path
            (Get-ServerUpdateGitBlobSha1 -Path $localPath) -ne $_.Sha
        })
        if ($filesToFetch.Count -eq 0) {
            if (-not $isConnectionOnlyRun) { Update-ServerUpdateSettingsDefaults -ScriptRoot $scriptRoot }
            try {
                New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
                [PSCustomObject]@{ ManifestCommit = $manifestCommit; RepositoryBlobs = $repositoryBlobs } |
                    ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -Encoding UTF8 -Force
            }
            catch { Write-Warning 'Update-Metadaten konnten nicht lokal gespeichert werden; beim nächsten Lauf wird erneut geprüft.' }
            if ($scriptName -eq 'Update-ServerUpdateScripts.ps1') {
                Write-Host 'Alle benötigten Skriptdateien sind bereits aktuell. Die Settings wurden geprüft und gegebenenfalls migriert.' -ForegroundColor Green
            }
            return
        }

        $temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) ('ServerUpdateSkripte-' + [guid]::NewGuid().ToString('N'))
        $stageDirectory = Join-Path $temporaryDirectory 'stage'
        $backupDirectory = Join-Path $temporaryDirectory 'backup'
        New-Item -Path $stageDirectory -ItemType Directory -Force | Out-Null
        New-Item -Path $backupDirectory -ItemType Directory -Force | Out-Null
        $changedFiles = [System.Collections.Generic.List[string]]::new()

        try {
            foreach ($file in $filesToFetch) {
                $relativePath = $file.Path
                $encodedPath = (($relativePath -split '/') | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
                $sourceUrl = "https://raw.githubusercontent.com/$repoOwner/$repoName/$latestCommit/$encodedPath"
                $stagePath = Join-Path $stageDirectory $relativePath
                $stageParent = Split-Path -Parent $stagePath
                if (-not (Test-Path -LiteralPath $stageParent -PathType Container)) {
                    New-Item -Path $stageParent -ItemType Directory -Force | Out-Null
                }
                Invoke-ServerUpdateGitHubRequest -Description "Datei '$relativePath'" -Request {
                    Invoke-WebRequest -Uri $sourceUrl -UseBasicParsing -TimeoutSec 30 -OutFile $stagePath -ErrorAction Stop
                } | Out-Null
                if (-not (Test-Path -LiteralPath $stagePath -PathType Leaf)) {
                    throw "GitHub lieferte keine gültige Datei für '$relativePath'."
                }
                if ((Get-ServerUpdateGitBlobSha1 -Path $stagePath) -ne $file.Sha) {
                    throw "Die heruntergeladene Datei '$relativePath' stimmt nicht mit dem GitHub-Hash überein."
                }

                $localPath = Join-Path $scriptRoot $relativePath
                if ((Get-ServerUpdateGitBlobSha1 -Path $localPath) -ne $file.Sha) {
                    $changedFiles.Add($relativePath)
                }
            }

            foreach ($relativePath in $changedFiles) {
                $localPath = Join-Path $scriptRoot $relativePath
                if (Test-Path -LiteralPath $localPath -PathType Leaf) {
                    $backupPath = Join-Path $backupDirectory $relativePath
                    $backupParent = Split-Path -Parent $backupPath
                    if (-not (Test-Path -LiteralPath $backupParent -PathType Container)) {
                        New-Item -Path $backupParent -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath $localPath -Destination $backupPath -Force -ErrorAction Stop
                }
            }

            try {
                foreach ($relativePath in $changedFiles) {
                    $localPath = Join-Path $scriptRoot $relativePath
                    $localDirectory = Split-Path -Parent $localPath
                    if (-not (Test-Path -LiteralPath $localDirectory -PathType Container)) {
                        New-Item -Path $localDirectory -ItemType Directory -Force | Out-Null
                    }
                    Copy-Item -LiteralPath (Join-Path $stageDirectory $relativePath) -Destination $localPath -Force -ErrorAction Stop
                }
                if (-not $isConnectionOnlyRun) { Update-ServerUpdateSettingsDefaults -ScriptRoot $scriptRoot }
            }
            catch {
                foreach ($relativePath in $changedFiles) {
                    $localPath = Join-Path $scriptRoot $relativePath
                    $backupPath = Join-Path $backupDirectory $relativePath
                    if (Test-Path -LiteralPath $backupPath -PathType Leaf) {
                        Copy-Item -LiteralPath $backupPath -Destination $localPath -Force -ErrorAction SilentlyContinue
                    }
                    elseif (Test-Path -LiteralPath $localPath -PathType Leaf) {
                        Remove-Item -LiteralPath $localPath -Force -ErrorAction SilentlyContinue
                    }
                }
                throw
            }

            try {
                New-Item -Path $cacheDirectory -ItemType Directory -Force | Out-Null
                [PSCustomObject]@{
                    ManifestCommit = $manifestCommit
                    RepositoryBlobs = $repositoryBlobs
                } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $cachePath -Encoding UTF8 -Force
            }
            catch {
                Write-Warning 'Update-Metadaten konnten nicht lokal gespeichert werden; beim nächsten Lauf wird erneut geprüft.'
            }
        }
        finally {
            Remove-Item -LiteralPath $temporaryDirectory -Recurse -Force -ErrorAction SilentlyContinue
        }

        $restartRequired = $changedFiles.Count -gt 0
    }
    catch {
        $shortCause = Get-ServerUpdateShortError -Exception $_.Exception
        Write-Warning "Automatische Skriptaktualisierung fehlgeschlagen; lokaler Stand wird verwendet. Ursache: $shortCause"
    }

    if ($restartRequired) {
        Write-Host ("Skript-Update aus GitHub übernommen ({0} benötigte Datei(en)); starte mit aktualisiertem Stand neu." -f $changedFiles.Count) -ForegroundColor Cyan
        $global:LASTEXITCODE = 0
        & $ScriptPath @BoundParameters @RemainingArguments
        $scriptExitCode = 0
        if (Test-Path variable:global:LASTEXITCODE) { $scriptExitCode = [int]$global:LASTEXITCODE }
        exit $scriptExitCode
    }

    # Nur das Installationsskript prüft PS7 über Windows PowerShell 5.1.
    # Das schützt den laufenden Updateprozess vor einem Austausch der PS7-Dateien.
    if ($scriptName -eq 'Install-ServersUpdates.ps1' -and
        $PSVersionTable.PSEdition -eq 'Core' -and
        $env:SERVER_UPDATE_POWERSHELL7_CHECKED -ne '1') {
        $windowsPowerShell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        if (Test-Path -LiteralPath $windowsPowerShell -PathType Leaf) {
            $restartArguments = [System.Collections.Generic.List[string]]::new()
            if ((@($BoundParameters.Keys) -contains 'DebugMode') -and [bool]$BoundParameters['DebugMode']) { $restartArguments.Add('-DebugMode') }
            if (@($BoundParameters.Keys) -contains 'TargetComputer') {
                $restartArguments.Add('-TargetComputer')
                foreach ($target in @($BoundParameters['TargetComputer'])) { $restartArguments.Add([string]$target) }
            }
            if ((@($BoundParameters.Keys) -contains 'TestDeferredMail') -and [bool]$BoundParameters['TestDeferredMail']) { $restartArguments.Add('-TestDeferredMail') }

            $statusPath = Join-Path ([IO.Path]::GetTempPath()) ('ServerUpdate-PowerShell7-' + [guid]::NewGuid().ToString('N') + '.json')
            $environmentNames = @(
                'SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH',
                'SERVER_UPDATE_BOOTSTRAP_STATUS_PATH',
                'SERVER_UPDATE_BOOTSTRAP_ARGUMENTS_JSON'
            )
            $previousEnvironment = @{}
            foreach ($name in $environmentNames) { $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process') }
            try {
                $env:SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH = $ScriptPath
                $env:SERVER_UPDATE_BOOTSTRAP_STATUS_PATH = $statusPath
                $env:SERVER_UPDATE_BOOTSTRAP_ARGUMENTS_JSON = ConvertTo-Json -InputObject @($restartArguments.ToArray()) -Compress

                # Der Vorlauf läuft direkt in Windows PowerShell 5.1 und liegt nicht als zusätzliche Datei im Repository.
                $bootstrapSource = @'
$ErrorActionPreference = 'Stop'
$statusPath = $env:SERVER_UPDATE_BOOTSTRAP_STATUS_PATH
$noUpdateExitCodes = @(-1978335188, -1978335189, -1978335192)
$chocoPath = 'C:\ProgramData\chocolatey\bin\choco.exe'

function Invoke-WingetRepair {
    param([string]$ServerCaption)
    if ($ServerCaption -notmatch 'Windows Server (2019|2022)') {
        throw "Die WinGet-Reparatur ist nur für Windows Server 2019 und 2022 vorgesehen (erkannt: $ServerCaption)."
    }
    $commonModule = Join-Path (Split-Path -Parent $env:SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH) 'WindowsUpdate.Common.psm1'
    if (-not (Test-Path -LiteralPath $commonModule -PathType Leaf)) { throw 'WindowsUpdate.Common.psm1 für die WinGet-Reparatur fehlt.' }
    Import-Module -Name $commonModule -Force -ErrorAction Stop
    if (-not (Update-WinGetClientModule)) { throw 'Microsoft.WinGet.Client konnte nicht installiert oder aktualisiert werden.' }
    Import-Module Microsoft.WinGet.Client -Force -ErrorAction Stop
    $null = Repair-WinGetPackageManager -Latest -Force -ErrorAction Stop
    Assert-WinGetPackageManager -ErrorAction Stop | Out-Null
    $version = [string](Get-WinGetVersion -ErrorAction Stop)
    Write-Host "WinGet über Microsoft.WinGet.Client repariert ($version)."
}

function Invoke-PowerShellWingetUpdateCheck {
    $scriptRoot = Split-Path -Parent $env:SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH
    $commonModulePath = Join-Path $scriptRoot 'WindowsUpdate.Common.psm1'
    if (-not (Test-Path -LiteralPath $commonModulePath -PathType Leaf)) { throw 'WindowsUpdate.Common.psm1 fehlt; das WinGet-Modul kann nicht verwendet werden.' }
    $commonModuleLiteral = "'" + $commonModulePath.Replace("'", "''") + "'"
    $checkSource = @(
        '$ErrorActionPreference = ''Stop'''
        '$commonModulePath = __COMMON_MODULE_PATH__'
        'Import-Module -Name $commonModulePath -Force -ErrorAction Stop'
        'if (-not (Update-WinGetClientModule)) { throw ''Microsoft.WinGet.Client konnte nicht bereitgestellt werden.'' }'
        'Import-Module Microsoft.WinGet.Client -ErrorAction Stop'
        '$updates = @(Get-WinGetPackage -Id ''Microsoft.PowerShell'' -Source winget -MatchOption EqualsCaseInsensitive -ErrorAction Stop | Where-Object { $_.IsUpdateAvailable })'
        'if ($updates.Count -eq 0) { [pscustomobject]@{ State = ''NoUpdate''; Output = ''Kein PowerShell-7-Update verfügbar.'' } | ConvertTo-Json -Compress; return }'
        '$version = [string]($updates[0].AvailableVersions | Select-Object -First 1)'
        '$updateResult = @(Update-WinGetPackage -Id ''Microsoft.PowerShell'' -Source winget -Version $version -MatchOption EqualsCaseInsensitive -Mode Silent -Confirm:$false -ErrorAction Stop)'
        'if ($updateResult.Count -eq 0 -or [string]$updateResult[-1].Status -ne ''Ok'') { throw "Update-WinGetPackage meldete keinen erfolgreichen Abschluss (Status: $([string]$updateResult[-1].Status))." }'
        '[pscustomobject]@{ State = ''Updated''; Output = "PowerShell 7 wurde auf Version $version aktualisiert." } | ConvertTo-Json -Compress'
    ) -join "`n"
    $checkSource = $checkSource.Replace('__COMMON_MODULE_PATH__', $commonModuleLiteral)
    # Microsoft.WinGet.Client benötigt hier Windows PowerShell 5.1 (WinRT/COM).
    # Eine frische PS5-Instanz ist daher auch beim normalen Update-Check Pflicht.
    $shellPath = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    if (-not (Test-Path -LiteralPath $shellPath -PathType Leaf)) {
        return [PSCustomObject]@{ ExitCode = 1; Output = 'Windows PowerShell 5.1 wurde nicht gefunden.'; State = 'Error' }
    }
    $childSource = "try {`n$checkSource`n} catch { [pscustomobject]@{ State = 'Error'; Output = (`$_.Exception.Message -replace '\s+', ' ').Trim() } | ConvertTo-Json -Compress }"
    $encodedChild = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childSource))
    $rawOutput = @(& $shellPath -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $encodedChild 2>&1)
    $jsonLine = @($rawOutput | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\s*\{.*"State"\s*:' } | Select-Object -Last 1)
    if ($jsonLine.Count -eq 0) { return [PSCustomObject]@{ ExitCode = 1; Output = (($rawOutput -join ' ') -replace '\s+', ' ').Trim(); State = 'Error' } }
    try { $result = $jsonLine[0] | ConvertFrom-Json -ErrorAction Stop }
    catch { return [PSCustomObject]@{ ExitCode = 1; Output = 'Ungültige Rückgabe von Microsoft.WinGet.Client.'; State = 'Error' } }
    $exitCode = if ($result.State -eq 'NoUpdate') { -1978335189 } elseif ($result.State -eq 'Updated') { 0 } else { 1 }
    return [PSCustomObject]@{ ExitCode = $exitCode; Output = [string]$result.Output; State = [string]$result.State }
}

try {
    $serverCaption = ''
    try { $serverCaption = [string](Get-CimInstance -ClassName Win32_OperatingSystem -ErrorAction Stop).Caption } catch { }
    $wingetRepairSupported = $serverCaption -match 'Windows Server (2019|2022)'
    Write-Host 'Prüfe mit Microsoft.WinGet.Client unter Windows PowerShell 5.1 auf ein PowerShell-7-Update ...'
    $wingetCheck = Invoke-PowerShellWingetUpdateCheck
    $packageOutput = $wingetCheck.Output
    $packageExitCode = $wingetCheck.ExitCode
    if ($packageExitCode -in $noUpdateExitCodes) { exit 0 }
    if ($packageExitCode -ne 0 -and $wingetRepairSupported) {
        Write-Warning "WinGet-Modulprüfung für PowerShell 7 fehlgeschlagen (Exitcode $packageExitCode); repariere WinGet auf $serverCaption und wiederhole die Prüfung."
        Invoke-WingetRepair -ServerCaption $serverCaption
        # Nach der Reparatur eine frische Windows-PowerShell-5.1-Instanz starten,
        # damit aktualisierte App-Installer-Registrierungen neu eingelesen werden.
        $wingetCheck = Invoke-PowerShellWingetUpdateCheck
        $packageOutput = $wingetCheck.Output
        $packageExitCode = $wingetCheck.ExitCode
        if ($packageExitCode -in $noUpdateExitCodes) { exit 0 }
    }
    if ($packageExitCode -ne 0 -and (Test-Path -LiteralPath $chocoPath -PathType Leaf)) {
        Write-Host 'Winget ist nicht installiert; prüfe mit Windows PowerShell 5.1 Chocolatey auf ein PowerShell-7-Update ...'
        $outdatedOutput = & $chocoPath outdated --limit-output 2>&1
        $chocoExitCode = $LASTEXITCODE
        if ($chocoExitCode -ne 0) {
            Write-Warning "Chocolatey konnte nicht auf veraltete Pakete prüfen (Exitcode $chocoExitCode). Der Installationslauf wird fortgesetzt. $($outdatedOutput | Out-String)"
            exit 0
        }
        $powerShellUpdateAvailable = @($outdatedOutput | Where-Object { ([string]$_).Trim() -match '^powershell-core\|' }).Count -gt 0
        if (-not $powerShellUpdateAvailable) { exit 0 }
        $packageOutput = & $chocoPath upgrade powershell-core --yes --no-progress 2>&1
        $packageExitCode = $LASTEXITCODE
        if ($packageExitCode -ne 0) {
            Write-Warning "PowerShell-7-Update mit Chocolatey fehlgeschlagen (Exitcode $packageExitCode). Der Installationslauf wird fortgesetzt. $($packageOutput | Out-String)"
            exit 0
        }
    }
    elseif ($packageExitCode -ne 0) {
        Write-Warning "PowerShell-7-Update konnte mit Microsoft.WinGet.Client nicht geprüft werden (Exitcode $packageExitCode). Der Installationslauf wird fortgesetzt. $($packageOutput | Out-String)"
        exit 0
    }

    $pwshCommand = Get-Command -Name 'pwsh.exe' -ErrorAction SilentlyContinue
    if (-not $pwshCommand) { throw 'Nach dem Paketupdate wurde pwsh.exe nicht gefunden.' }
    $scriptArguments = @(ConvertFrom-Json -InputObject $env:SERVER_UPDATE_BOOTSTRAP_ARGUMENTS_JSON -ErrorAction Stop)
    $env:SERVER_UPDATE_POWERSHELL7_CHECKED = '1'
    Write-Host 'PowerShell 7 wurde aktualisiert; starte Install-ServersUpdates.ps1 mit der aktualisierten Version neu.'
    & $pwshCommand.Source -NoLogo -NoProfile -ExecutionPolicy Bypass -File $env:SERVER_UPDATE_BOOTSTRAP_SCRIPT_PATH @scriptArguments
    $scriptExitCode = if ($null -ne $LASTEXITCODE) { [int]$LASTEXITCODE } else { 0 }
    Set-Content -LiteralPath $statusPath -Value (@{ Restarted = $true; ExitCode = $scriptExitCode } | ConvertTo-Json -Compress) -Encoding UTF8 -Force
}
catch {
    Write-Warning "PS7-Aktualisierung vor dem Installationslauf fehlgeschlagen; vorhandener Lauf wird fortgesetzt. Ursache: $($_.Exception.Message)"
}
'@
                $encodedBootstrap = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($bootstrapSource))
                & $windowsPowerShell -NoProfile -ExecutionPolicy Bypass -EncodedCommand $encodedBootstrap
                if (Test-Path -LiteralPath $statusPath -PathType Leaf) {
                    $restartStatus = Get-Content -LiteralPath $statusPath -Raw -Encoding UTF8 | ConvertFrom-Json -ErrorAction Stop
                    if ($restartStatus.Restarted) { exit ([int]$restartStatus.ExitCode) }
                }
            }
            catch {
                Write-Warning "PS7-Aktualisierungsprüfung mit Windows PowerShell 5.1 fehlgeschlagen; Installationslauf wird fortgesetzt. Ursache: $($_.Exception.Message)"
            }
            finally {
                foreach ($name in $environmentNames) { [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process') }
                Remove-Item -LiteralPath $statusPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

function Get-ServerUpdateShortError {
    param([Parameter(Mandatory)][System.Exception]$Exception)

    $message = [string]$Exception.Message
    if ($message -match '(?i)(übertragungsverbindung|remotehost geschlossen|connection.*closed|forcibly closed|unable to read data)') {
        return 'GitHub hat die Verbindung während der Übertragung geschlossen.'
    }
    if ($message -match '(?i)(timeout|zeitüberschreitung|operation has timed out)') {
        return 'Zeitüberschreitung bei der Verbindung zu GitHub.'
    }
    $message = ([string]($message -split "`r?`n")[0]).Trim()
    $message = [regex]::Replace($message, '\s+', ' ')
    if ($message.Length -gt 180) { $message = $message.Substring(0, 177) + '...' }
    if ([string]::IsNullOrWhiteSpace($message)) { return 'Unbekannter Netzwerkfehler.' }
    return $message
}

function Invoke-ServerUpdateGitHubRequest {
    param(
        [Parameter(Mandatory)][string]$Description,
        [Parameter(Mandatory)][scriptblock]$Request
    )

    for ($attempt = 1; $attempt -le 3; $attempt++) {
        try {
            return & $Request
        }
        catch {
            $shortCause = Get-ServerUpdateShortError -Exception $_.Exception
            $transient = $_.Exception.Message -match '(?i)(übertragungsverbindung|remotehost|connection|verbindung|timeout|zeitüberschreitung|temporar|429|\b5\d\d\b|unable to read data)'
            if (-not $transient -or $attempt -ge 3) {
                throw "GitHub-$Description nach $attempt Versuch(en) fehlgeschlagen: $shortCause"
            }
            Write-Warning "GitHub-${Description}: Versuch $attempt/3 fehlgeschlagen ($shortCause); nächster Versuch in 30 Sekunden."
            Start-Sleep -Seconds 30
        }
    }
}

# Direkter Aufruf synchronisiert den vollständigen für die vorhandenen Settings
# benötigten Programmstand. Als Bibliothek wird diese Datei nur dot-sourced.
if ($MyInvocation.InvocationName -ne '.') {
    Invoke-ServerUpdateScripts -ScriptPath $PSCommandPath
}
