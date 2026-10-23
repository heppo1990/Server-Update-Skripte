# Fachmodul: WindowsUpdate.PSWindowsUpdate
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

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

    # Windows PowerShell 5.1 verwendet ohne explizite Vorgabe häufig TLS 1.0.
    # PSGallery und die Provider-Feeds benötigen mindestens TLS 1.2.
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not [string]::IsNullOrWhiteSpace($ComputerName) -and $ComputerName -ine $env:COMPUTERNAME) {
        if (-not $Force) {
            $galleryVersion = Get-WindowsUpdateGalleryModuleVersion -Name 'PSWindowsUpdate'
            if ($galleryVersion) {
                $versionSession = $null
                try {
                    $sessionParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo -OperationTimeoutSeconds 1800
                    $versionSession = New-PSSession @sessionParameters
                    $targetVersions = Invoke-Command -Session $versionSession -ScriptBlock {
                        $roots = @(
                            (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate'),
                            (Join-Path $env:ProgramFiles 'PowerShell\Modules\PSWindowsUpdate')
                        )
                        $versions = foreach ($root in $roots) {
                            $version = Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
                                Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
                            [string]$version
                        }
                        [pscustomobject]@{ WindowsPowerShell = $versions[0]; PowerShell7 = $versions[1] }
                    } -ErrorAction Stop
                    if ($targetVersions -and $targetVersions.WindowsPowerShell -and $targetVersions.PowerShell7 -and
                        [version]$targetVersions.WindowsPowerShell -ge $galleryVersion -and
                        [version]$targetVersions.PowerShell7 -ge $galleryVersion) {
                        Write-PSWindowsUpdateModuleLog $WriteLog "[$ComputerName] PSWindowsUpdate ist aktuell (Version $galleryVersion); kein Pakettransfer erforderlich." 'SUCCESS'
                        return $true
                    }
                } catch {
                    Write-PSWindowsUpdateModuleLog $WriteLog "[$ComputerName] Versionsprüfung vor dem Pakettransfer nicht möglich; führe vollständige Modulprüfung aus. Ursache: $($_.Exception.Message)" 'INFO'
                } finally {
                    if ($versionSession) { Remove-PSSession -Session $versionSession -ErrorAction SilentlyContinue }
                }
            }
        }
        $session = $null
        $modulePayload = $null
        $remotePayloadPath = $null
        try {
            $modulePayload = New-WindowsUpdateModulePayload -ModuleName 'PSWindowsUpdate' `
                -OfflineModulePath $OfflineModulePath -WriteLog $WriteLog
            $sessionParameters = New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $AuthInfo -OperationTimeoutSeconds 1800
            $session = New-PSSession @sessionParameters
            $remotePayloadPath = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-ModulePayload-{0}' -f [guid]::NewGuid().ToString('N'))
            Invoke-Command -Session $session -ScriptBlock {
                param($Path)
                New-Item -ItemType Directory -Path $Path -Force -ErrorAction Stop | Out-Null
            } -ArgumentList $remotePayloadPath -ErrorAction Stop
            Copy-Item -Path (Join-Path $modulePayload.Root '*') `
                -Destination $remotePayloadPath -ToSession $session -Recurse -Force -ErrorAction Stop
            $updateDefinition = (Get-Command -Name Update-PSWindowsUpdateModule -CommandType Function).Definition
            $logDefinition = (Get-Command -Name Write-PSWindowsUpdateModuleLog -CommandType Function).Definition
            $remoteWorker = {
                param($UpdaterText, $LoggerText, $ForceUpdate, $OfflineModulePath)
                [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
                $windowsPowerShellModulePaths = @(
                    (Join-Path $HOME 'Documents\WindowsPowerShell\Modules'),
                    (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'),
                    (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\Modules')
                )
                if (-not [string]::IsNullOrWhiteSpace(${env:ProgramFiles(x86)})) {
                    $windowsPowerShellModulePaths += Join-Path ${env:ProgramFiles(x86)} 'WindowsPowerShell\Modules'
                }
                $env:PSModulePath = ($windowsPowerShellModulePaths | Where-Object { Test-Path -LiteralPath $_ -PathType Container }) -join ';'
                try {
                    Set-Item -Path Function:\Write-PSWindowsUpdateModuleLog -Value ([scriptblock]::Create($LoggerText))
                    Set-Item -Path Function:\Update-PSWindowsUpdateModule -Value ([scriptblock]::Create($UpdaterText))
                    $remoteLogger = { param($Message, $Level) [pscustomobject]@{ Type = 'ModuleLog'; Message = $Message; Level = $Level } }
                    # ArgumentList-Werte können bei älteren Remoting-Endpunkten als
                    # String zurückkommen. Switches deshalb nur als echte Switch-
                    # Parameter über eine Splat-Hashtable weitergeben.
                    $forceEnabled = $false
                    if ($ForceUpdate -is [bool]) {
                        $forceEnabled = $ForceUpdate
                    } elseif ($ForceUpdate -is [string]) {
                        $parsedForce = $false
                        if ([bool]::TryParse($ForceUpdate, [ref]$parsedForce)) { $forceEnabled = $parsedForce }
                    } elseif ($null -ne $ForceUpdate) {
                        $forceEnabled = [bool]$ForceUpdate
                    }
                    if ($ForceUpdate -isnot [bool] -and $null -ne $ForceUpdate) {
                        [pscustomobject]@{ Type = 'ModuleLog'; Message = "Force-Argument remote als $($ForceUpdate.GetType().FullName) empfangen; sicher normalisiert."; Level = 'INFO' }
                    }
                    $updateParameters = @{ WriteLog = $remoteLogger; OfflineModulePath = $OfflineModulePath }
                    if ($forceEnabled) { $updateParameters.Force = $true }
                    $updateOutput = @(Update-PSWindowsUpdateModule @updateParameters)
                    foreach ($entry in $updateOutput) {
                        if ($entry -and $entry.PSObject.Properties['Type'] -and $entry.Type -eq 'ModuleLog') {
                            [pscustomobject]@{ Type = 'ModuleLog'; Message = [string]$entry.Message; Level = [string]$entry.Level }
                        } elseif ($entry -is [bool]) {
                            [pscustomobject]@{ Type = 'ModuleResult'; Success = $entry }
                        }
                    }
                }
                finally {
                    if ($OfflineModulePath) {
                        Remove-Item -LiteralPath $OfflineModulePath -Recurse -Force -ErrorAction SilentlyContinue
                    }
                }
            }
            $remoteModulePath = Join-Path $remotePayloadPath 'PSWindowsUpdate'
            $remoteResults = @(Invoke-Command -Session $session -ScriptBlock $remoteWorker -ArgumentList $updateDefinition, $logDefinition, [bool]$Force, $remoteModulePath -ErrorAction Stop)
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
        finally {
            if ($session -and $remotePayloadPath) {
                Invoke-Command -Session $session -ScriptBlock {
                    param($Path)
                    Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue
                } -ArgumentList $remotePayloadPath -ErrorAction SilentlyContinue
            }
            if ($session) { Remove-PSSession -Session $session -ErrorAction SilentlyContinue }
            if ($modulePayload -and $modulePayload.Root) {
                Remove-Item -LiteralPath $modulePayload.Root -Recurse -Force -ErrorAction SilentlyContinue
            }
        }
    }

    if (-not $Force) {
        $galleryVersion = Get-WindowsUpdateGalleryModuleVersion -Name 'PSWindowsUpdate'
        if ($galleryVersion) {
            $targetRoots = @(
                (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\PSWindowsUpdate'),
                (Join-Path $env:ProgramFiles 'PowerShell\Modules\PSWindowsUpdate')
            )
            $targetVersions = @(
                foreach ($root in $targetRoots) {
                    Get-ChildItem -LiteralPath $root -Directory -ErrorAction SilentlyContinue |
                        Where-Object { $_.Name -match '^\d+(\.\d+){1,3}$' } |
                        Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1 -ExpandProperty Name
                }
            )
            if ($targetVersions.Count -eq 2 -and
                @($targetVersions | Where-Object { [version]$_ -lt $galleryVersion }).Count -eq 0) {
                Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate ist aktuell (Version $galleryVersion); kein Paketdownload erforderlich." 'SUCCESS'
                return $true
            }
        }
    }

    $modulePayload = $null
    # In Windows PowerShell 5.1 kann eine einzelne zurückgegebene Version
    # beim Zuweisen aus einem if-Ausdruck zu einem skalaren DirectoryInfo
    # entpackt werden. Die explizite Arrayinitialisierung hält .Count stabil.
    $availableOfflineVersions = @()
    if ($OfflineModulePath -and (Test-Path -LiteralPath $OfflineModulePath -PathType Container)) {
        $availableOfflineVersions = @(
            Get-ChildItem -LiteralPath $OfflineModulePath -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -match '^\d+(\.\d+)*$' }
        )
    }
    if (@($availableOfflineVersions).Count -eq 0) {
        try {
            $modulePayload = New-WindowsUpdateModulePayload -ModuleName 'PSWindowsUpdate' `
                -OfflineModulePath $OfflineModulePath -WriteLog $WriteLog
            $OfflineModulePath = Join-Path $modulePayload.Root 'PSWindowsUpdate'
        }
        catch {
            Write-PSWindowsUpdateModuleLog $WriteLog "Aktuelles PSWindowsUpdate-Paket konnte nicht online beschafft werden; Offline-/Installationsprüfung fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
            return $false
        }
    }

    $installedModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
        Sort-Object Version -Descending | Select-Object -First 1
    $offlineVersions = @(Get-ChildItem -LiteralPath $OfflineModulePath -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^\d+(\.\d+)*$' } |
        Sort-Object { [version]$_.Name } -Descending)
    if ($offlineVersions.Count -eq 0) {
        Write-PSWindowsUpdateModuleLog $WriteLog "Kein verwendbares PSWindowsUpdate-Offlinepaket in '$OfflineModulePath' gefunden." 'ERROR'
        if ($modulePayload -and $modulePayload.Root) {
            Remove-Item -LiteralPath $modulePayload.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
        return $false
    }

    $offlineVersion = [version]$offlineVersions[0].Name
    if (-not $installedModule -or $offlineVersion -gt $installedModule.Version -or $Force) {
        try {
            $offlineTarget = Join-Path (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules') 'PSWindowsUpdate'
            $offlineTargetVersion = Join-Path $offlineTarget ([string]$offlineVersion)
            New-Item -ItemType Directory -Path $offlineTarget -Force -ErrorAction Stop | Out-Null
            if (Test-Path -LiteralPath $offlineTargetVersion) {
                Remove-Item -LiteralPath $offlineTargetVersion -Recurse -Force -ErrorAction Stop
            }
            Copy-Item -LiteralPath $offlineVersions[0].FullName -Destination $offlineTargetVersion -Recurse -Force -ErrorAction Stop
            $installedModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
                Sort-Object Version -Descending | Select-Object -First 1
            if (-not $installedModule -or $installedModule.Version -lt $offlineVersion) {
                throw "PSWindowsUpdate $offlineVersion wurde aus dem Offlinepaket nicht gefunden."
            }
            Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate aus dem zentral bereitgestellten Offlinepaket eingerichtet (Version $($installedModule.Version)); NuGet auf dem Ziel war nicht erforderlich." 'SUCCESS'
        }
        catch {
            Write-PSWindowsUpdateModuleLog $WriteLog "Offline-Bereitstellung von PSWindowsUpdate fehlgeschlagen: $($_.Exception.Message)" 'ERROR'
        }
    } else {
        Write-PSWindowsUpdateModuleLog $WriteLog "PSWindowsUpdate-Paket $offlineVersion geprüft; installierte neuere Version $($installedModule.Version) bleibt erhalten." 'SUCCESS'
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
        if ($modulePayload -and $modulePayload.Root) {
            Remove-Item -LiteralPath $modulePayload.Root -Recurse -Force -ErrorAction SilentlyContinue
        }
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
    if ($modulePayload -and $modulePayload.Root) {
        Remove-Item -LiteralPath $modulePayload.Root -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $true
}

function Import-WindowsUpdatePSWindowsUpdateModule {
    param(
        [Parameter(Mandatory)][scriptblock]$WriteLog,
        [switch]$LocalSystemRun
    )

    & $WriteLog 'Versuche PSWindowsUpdate-Modul zu laden...'
    if ($LocalSystemRun) {
        $installedModule = Get-Module -ListAvailable -Name PSWindowsUpdate -ErrorAction SilentlyContinue |
            Sort-Object Version -Descending |
            Select-Object -First 1
        if (-not $installedModule) {
            & $WriteLog 'KRITISCHER FEHLER: PSWindowsUpdate ist maschinenweit nicht installiert; der SYSTEM-Aufgabenlauf kann das Modul nicht aktualisieren.'
            return $false
        }
        try {
            Import-Module -Name $installedModule.Path -ErrorAction Stop
            & $WriteLog "PSWindowsUpdate $($installedModule.Version) aus dem maschinenweiten Modulpfad geladen; Onlineaktualisierung im SYSTEM-Aufgabenlauf übersprungen."
            return $true
        }
        catch {
            & $WriteLog "KRITISCHER FEHLER: PSWindowsUpdate $($installedModule.Version) konnte im SYSTEM-Aufgabenlauf nicht geladen werden: $($_.Exception.Message)"
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'PSWindowsUpdate-Import-SYSTEM' -ErrorRecord $_
            return $false
        }
    }

    # Den übergeordneten Logger vor dem Aufruf explizit schließen. Ohne
    # GetNewClosure() kann PowerShell innerhalb von Update-PSWindowsUpdateModule
    # dessen gleichnamigen Parameter $WriteLog auflösen und den Callback
    # rekursiv aufrufen, bis die Aufruftiefe überschritten ist.
    $parentWriteLog = $WriteLog
    $moduleWriteLog = {
        param($message, $level)
        & $parentWriteLog "[$level] $message"
    }.GetNewClosure()
    $moduleReady = Update-PSWindowsUpdateModule -WriteLog $moduleWriteLog
    if (-not $moduleReady) { return $false }
    if (Get-Module -Name PSWindowsUpdate) {
        & $WriteLog 'PSWindowsUpdate ist bereits geladen.'
        return $true
    }
    try {
        Import-Module PSWindowsUpdate -ErrorAction Stop
        & $WriteLog 'PSWindowsUpdate erfolgreich geladen (Standard-Pfad).'
        return $true
    }
    catch {
        & $WriteLog 'Standard-Import von PSWindowsUpdate fehlgeschlagen; prüfe alternative Modulpfade.'
        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'PSWindowsUpdate-Import Standardpfad' -ErrorRecord $_
    }

    $possiblePaths = @(
        "$env:ProgramFiles\WindowsPowerShell\Modules\PSWindowsUpdate",
        "${env:ProgramFiles(x86)}\WindowsPowerShell\Modules\PSWindowsUpdate",
        "$env:SystemRoot\System32\WindowsPowerShell\v1.0\Modules\PSWindowsUpdate",
        'C:\Program Files\WindowsPowerShell\Modules\PSWindowsUpdate'
    )
    foreach ($path in $possiblePaths) {
        if (-not (Test-Path -LiteralPath $path)) { continue }
        & $WriteLog "Gefunden in: $path"
        try {
            Import-Module $path -ErrorAction Stop
            & $WriteLog "PSWindowsUpdate erfolgreich geladen aus: $path"
            return $true
        }
        catch {
            & $WriteLog "Import aus '$path' fehlgeschlagen; Details im Log."
            Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'PSWindowsUpdate-Import Alternativpfad' -Target $path -ErrorRecord $_
        }
    }

    & $WriteLog 'FEHLER: PSWindowsUpdate konnte nicht gefunden/geladen werden!'
    & $WriteLog 'Bitte installieren Sie das Modul mit: Install-Module PSWindowsUpdate -Force'
    return $false
}

Export-ModuleMember -Function Update-PSWindowsUpdateModule, Import-WindowsUpdatePSWindowsUpdateModule
