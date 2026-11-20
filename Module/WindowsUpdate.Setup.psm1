function New-WindowsUpdateAdmDeploymentStatusModuleSource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [ValidatePattern('^[0-9]+(?:\.[0-9]+)*$')]
        [string]$Version,
        [bool]$WinGetUpdateOnly = $false,
        [bool]$ChocolateyUpdateOnly = $true,
        [bool]$WinGetMaintenanceOnly = $false,
        [bool]$ChocolateyMaintenanceOnly = $true,
        [bool]$ServerCore = $false,
        [bool]$CertificateRunAsCompatibility = $false
    )

    $moduleSource = @'
function Get-WindowsUpdateAdmDeploymentStatus {
        $isVirtual = $null
    try {
        $cs = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
        $bios = Get-CimInstance -ClassName Win32_BIOS -ErrorAction Stop
        if ([string]::IsNullOrWhiteSpace([string]$cs.Model)) { throw 'Hardwaremodell fehlt.' }
        $isVirtual = (($cs.Manufacturer+' '+$cs.Model+' '+$bios.Manufacturer) -match 'VMware|VirtualBox|Virtual Machine|KVM|QEMU|Xen|Bochs|Parallels|bhyve|HVM domU')
    } catch { }
    [PSCustomObject]@{ IsVirtual = $isVirtual; Version = '__VERSION__'; TargetBuild = [Environment]::OSVersion.Version.Build; ServerCore = __SERVER_CORE__; CertificateRunAsCompatibility = __CERTIFICATE_RUNAS_COMPATIBILITY__; CacheTransferSupported = __WINGET_MAINTENANCE_ONLY__; MaintenanceRevision = '6'; MaintenanceFunctionsPresent = [bool]((Get-Command -Name Get-WindowsUpdateAdmChocolateyOutdated -CommandType Function -ErrorAction SilentlyContinue) -and (Get-Command -Name Invoke-WindowsUpdateAdmWinGetMaintenance -CommandType Function -ErrorAction SilentlyContinue)); WinGetSystemWorker = __WINGET_UPDATE_ONLY__; WinGetUpdateOnly = __WINGET_UPDATE_ONLY__; ChocolateyUpdateOnly = __CHOCO_UPDATE_ONLY__; WinGetMaintenanceOnly = __WINGET_MAINTENANCE_ONLY__; ChocolateyMaintenanceOnly = __CHOCO_MAINTENANCE_ONLY__ }
}
function Update-WindowsUpdateAdmWinGetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z')][string]$Id,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')][string]$Source
    )

    if (__SERVER_CORE__) { throw 'WinGet-Updates sind auf Server Core in dieser Konfiguration nicht freigegeben.' }
    if ([Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) {
        return Invoke-WindowsUpdateAdmWinGetPackageCore -Id $Id -Source $Source
    }
    # Aufrufer behalten ihren Kerberos-/Zertifikats-JEA-Zugang. Nur der feste
    # Updatevorgang wird wegen inkompatibler Installer als SYSTEM ausgeführt.
    Invoke-WindowsUpdateAdmWinGetSystemWorker -Id $Id -Source $Source
}
function Invoke-WindowsUpdateAdmWinGetPackageCore {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z')][string]$Id,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')][string]$Source
    )
    # Ausschließlich upgrade: kein install/uninstall, keine freien CLI-Argumente.
    $portableRoot = Join-Path $PSScriptRoot 'WinGetPortable'
    $candidates = @(Get-ChildItem -LiteralPath $portableRoot -Filter winget.exe -Recurse -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
    if ($candidates.Count -eq 0) { throw 'WinGet-Modul fehlgeschlagen; geprüfte portable CLI im JEA-Wartungsverzeichnis fehlt. Clientreparatur erforderlich.' }
    $exe = $candidates[0].FullName
    $signature = Get-AuthenticodeSignature -FilePath $exe -ErrorAction Stop
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Portable CLI hat keine gültige Microsoft-Signatur.' }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $exe
    $start.WorkingDirectory = Split-Path -Parent $exe
    $start.EnvironmentVariables['PATH'] = $start.WorkingDirectory + ';' + $env:PATH
    $start.Arguments = 'upgrade --id ' + $Id + ' --exact --source ' + $Source + ' --scope machine --silent --accept-package-agreements --accept-source-agreements --disable-interactivity'
    $start.UseShellExecute = $false; $start.CreateNoWindow = $true
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'WinGet-Updateprozess konnte nicht gestartet werden.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(1800000)) { try { $process.Kill() } catch {}; throw [TimeoutException]::new('WinGet-Update überschritt 30 Minuten; Zustand möglicher Installer-Unterprozesse manuell prüfen.') }
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $stderr.GetAwaiter().GetResult()
        $code = [int]$process.ExitCode
        [PSCustomObject]@{ Id=$Id; Status=$(if ($code -in @(0,3010)) {'Ok'} else {'Failed'}); InstallerErrorCode=$(if ($code -eq 3010) {'0'} else {[string]$code}); ExtendedErrorCode=''; RebootRequired=($code -eq 3010); Output=$output }
    } finally { $process.Dispose() }
}
function Invoke-WindowsUpdateAdmWinGetSystemWorker {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}\z')][string]$Id,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z')][string]$Source
    )
    $ErrorActionPreference='Stop'
    $root=Join-Path $PSScriptRoot 'WinGetUpdateJobs'
    $acl=New-Object Security.AccessControl.DirectorySecurity
    $acl.SetSecurityDescriptorSddlForm('D:P(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)')
    if (Test-Path -LiteralPath $root) {
        if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'WinGet-Aufgabenverzeichnis darf kein Verweis sein.' }
        Set-Acl -LiteralPath $root -AclObject $acl
    } else { $null=[IO.Directory]::CreateDirectory($root,$acl) }
    $lock=$null; $folder=''; $taskName=''; $registered=$false; $completed=$false
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try {
        try { $lock=[IO.File]::Open((Join-Path $root 'update.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
        catch { throw 'Auf diesem Ziel läuft bereits ein WinGet-Update; kein zweites Paket parallel starten.' }
        if (Test-Path -LiteralPath (Join-Path $root 'uncertain.json')) { throw 'Vorheriges WinGet-Update hat keinen sicheren Abschluss. Installerzustand und WinGetUpdateJobs\uncertain.json vor weiteren Updates manuell prüfen.' }
        $pending=@(Get-ScheduledTask -TaskName 'WindowsUpdateAdm-WinGetUpdate-*' -ErrorAction SilentlyContinue)
        if ($pending.Count -gt 0) { throw 'Eine vorherige WinGet-Aufgabe ist noch vorhanden; Zustand vor einem erneuten Update prüfen.' }
        $jobId=[guid]::NewGuid().ToString('N')
        $taskName='WindowsUpdateAdm-WinGetUpdate-'+$jobId
        $folder=Join-Path $root $jobId
        $null=[IO.Directory]::CreateDirectory($folder,$acl)
        $workerPath=Join-Path $folder 'worker.ps1'
        $resultPath=Join-Path $folder 'result.xml'
        $modulePath=$ExecutionContext.SessionState.Module.Path
        @{Id=$Id;Source=$Source;ModulePath=$modulePath;TaskName=$taskName} | ConvertTo-Json -Compress | Set-Content -LiteralPath (Join-Path $folder 'request.json') -Encoding UTF8
        $worker={
            $ErrorActionPreference='Stop'
            $started=[DateTime]::UtcNow
            $configuration=$null
            $result=$null
            $log=Join-Path $PSScriptRoot 'worker.log'
            $logLines=[Collections.Generic.List[string]]::new()
            try {
                $configuration=Get-Content -LiteralPath (Join-Path $PSScriptRoot 'request.json') -Raw | ConvertFrom-Json
                $logLines.Add(('[{0:o}] SYSTEM-Update gestartet: {1}; Quelle={2}; Identität={3}' -f $started,$configuration.Id,$configuration.Source,[Security.Principal.WindowsIdentity]::GetCurrent().Name))
                if (-not [Security.Principal.WindowsIdentity]::GetCurrent().IsSystem) { throw 'Updateworker läuft nicht als SYSTEM.' }
                Import-Module -Name $configuration.ModulePath -ErrorAction Stop
                $items=@(Update-WindowsUpdateAdmWinGetPackage -Id $configuration.Id -Source $configuration.Source -ErrorAction Stop)
                if ($items.Count -ne 1) { throw 'Paketupdate lieferte kein eindeutiges Ergebnis.' }
                $result=$items[0]
            } catch {
                $result=[pscustomobject]@{Id=$(if($configuration){$configuration.Id}else{''});Status='Failed';InstallerErrorCode='';ExtendedErrorCode='';RebootRequired=$false;Output=$_.Exception.ToString()}
                Add-Member -InputObject $result -NotePropertyName Uncertain -NotePropertyValue ($_.Exception -is [TimeoutException] -or $_.Exception.InnerException -is [TimeoutException])
            } finally {
                try {
                    $logLines.Add(('[{0:o}] SYSTEM-Update beendet: Status={1}; InstallerErrorCode={2}' -f [DateTime]::UtcNow,$result.Status,$result.InstallerErrorCode))
                    $workerLog=$logLines -join [Environment]::NewLine
                    # Eine durch Virenscanner gesperrte Textdatei darf das
                    # Installationsergebnis nicht vernichten; Log zusätzlich im Ergebnis.
                    try { [IO.File]::WriteAllText($log,$workerLog,[Text.UTF8Encoding]::new($true)) }
                    catch { $workerLog += [Environment]::NewLine+'Lokale Textprotokolldatei konnte nicht geschrieben werden: '+$_.Exception.Message }
                    Add-Member -InputObject $result -NotePropertyName ExecutionContext -NotePropertyValue 'SYSTEM' -Force
                    Add-Member -InputObject $result -NotePropertyName ElapsedSeconds -NotePropertyValue ([Math]::Round(([DateTime]::UtcNow-$started).TotalSeconds,1)) -Force
                    Add-Member -InputObject $result -NotePropertyName WorkerLog -NotePropertyValue $workerLog -Force
                    for($attempt=1;$attempt -le 4;$attempt++) {
                        try {
                            $result | Export-Clixml -LiteralPath (Join-Path $PSScriptRoot 'result.tmp') -Depth 8
                            Move-Item -LiteralPath (Join-Path $PSScriptRoot 'result.tmp') -Destination (Join-Path $PSScriptRoot 'result.xml') -Force
                            break
                        } catch { if($attempt -eq 4){throw}; Start-Sleep -Milliseconds 500 }
                    }
                } finally {
                    # Auch bei verlorener Remotesitzung bleibt keine geplante Aufgabe zurück.
                    if ($configuration) { Unregister-ScheduledTask -TaskName $configuration.TaskName -Confirm:$false -ErrorAction SilentlyContinue }
                }
            }
        }.ToString()
        [IO.File]::WriteAllText($workerPath,$worker,[Text.UTF8Encoding]::new($true))
        $action=New-ScheduledTaskAction -Execute (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -Argument ('-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$workerPath+'"')
        $principal=New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
        $settings=New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 32) -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable
        $null=Register-ScheduledTask -TaskName $taskName -Action $action -Principal $principal -Settings $settings
        $registered=$true
        Start-ScheduledTask -TaskName $taskName
        $deadline=[DateTime]::UtcNow.AddMinutes(31)
        while (-not (Test-Path -LiteralPath $resultPath -PathType Leaf)) {
            if ([DateTime]::UtcNow -gt $deadline) { throw 'SYSTEM-Update lieferte innerhalb von 31 Minuten kein Ergebnis. Aufgabe und Arbeitsdaten zur Prüfung behalten; kein automatischer zweiter Versuch.' }
            $task=Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
            if (-not $task) {
                if (Test-Path -LiteralPath $resultPath -PathType Leaf) { break }
                throw 'SYSTEM-Updateaufgabe wurde ohne Ergebnis beendet.'
            }
            $info=Get-ScheduledTaskInfo -TaskName $taskName -ErrorAction SilentlyContinue
            if ($info -and [string]$task.State -ne 'Running' -and [int64]$info.LastTaskResult -notin @(0,267009,267011) -and $info.LastRunTime -gt (Get-Date).AddMinutes(-2)) {
                throw "SYSTEM-Updateworker konnte nicht abgeschlossen werden; Aufgaben-Exitcode: $($info.LastTaskResult)."
            }
            Start-Sleep -Seconds 2
        }
        $result=Import-Clixml -LiteralPath $resultPath
        if ([string]$result.Id -ne $Id -or [string]$result.Status -notin @('Ok','Failed') -or -not $result.PSObject.Properties['Output']) { throw 'SYSTEM-Update lieferte ein ungültiges Ergebnis.' }
        if ($result.PSObject.Properties['Uncertain'] -and $result.Uncertain) {
            @{Id=$Id;TaskName=$taskName;CreatedUtc=[DateTime]::UtcNow.ToString('o');Reason=$result.Output} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'uncertain.json') -Encoding UTF8
        }
        $completed=$true
        $result
    } catch {
        $failure=$_
        if ($registered -and -not $completed) {
            try { @{Id=$Id;TaskName=$taskName;CreatedUtc=[DateTime]::UtcNow.ToString('o');Reason=$failure.Exception.Message} | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $root 'uncertain.json') -Encoding UTF8 } catch { }
        }
        [pscustomobject]@{Id=$Id;Status='Failed';InstallerErrorCode='';ExtendedErrorCode='';RebootRequired=$false;Output=$failure.Exception.ToString();ExecutionContext='SYSTEM-Worker';ElapsedSeconds=[Math]::Round($timer.Elapsed.TotalSeconds,1);WorkerLog=''}
    } finally {
        if ($completed -or (-not $registered -and $folder)) {
            if ($taskName) { Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue }
            if ($folder) { Remove-Item -LiteralPath $folder -Recurse -Force -ErrorAction SilentlyContinue }
        }
        if ($lock) { $lock.Dispose() }
    }
}
function Update-WindowsUpdateAdmChocolateyPackages {
    [CmdletBinding()]
    param()
    $wrapper = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\Update-ChocolateyPackages.cmd'
    if (-not (Test-Path -LiteralPath $wrapper -PathType Leaf)) { throw 'Der feste Chocolatey-Updatewrapper fehlt.' }
    $output = & $wrapper 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [PSCustomObject]@{ ExitCode = [int]$exitCode; Output = [string]$output }
}
function Get-WindowsUpdateAdmChocolateyOutdated {
    [CmdletBinding()]
    param()
    $wrapper = Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates\List-ChocolateyOutdated.cmd'
    $output = & $wrapper 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [PSCustomObject]@{ Success = ([int]$exitCode -in @(0,2)); ExitCode = [int]$exitCode; Output = [string]$output }
}
function Invoke-WindowsUpdateAdmWinGetMaintenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('SourceList','SourceUpdate','SourceReset','ClientRepair')][string]$Action
    )
    $wrapperName = switch ($Action) {
        'SourceList' { 'WindowsUpdateAdm-WinGet-SourceList.cmd' }
        'SourceUpdate' { 'WindowsUpdateAdm-WinGet-SourceUpdate.cmd' }
        'SourceReset' { 'WindowsUpdateAdm-WinGet-SourceReset.cmd' }
        'ClientRepair' { 'WindowsUpdateAdm-WinGet-ClientRepair.cmd' }
    }
    $wrapper = Join-Path $env:ProgramFiles ('WindowsPowerShell\Modules\JEA_Updates\' + $wrapperName)
    $output = & $wrapper 2>&1 | Out-String
    $exitCode = $LASTEXITCODE
    [PSCustomObject]@{ Action = $Action; Success = ([int]$exitCode -eq 0); ExitCode = [int]$exitCode; Output = [string]$output }
}
function Receive-WindowsUpdateAdmWinGetCache {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Probe','Start','Append','Complete')][string]$Action,
        [Parameter(Mandatory)][ValidatePattern('^https://github\.com/microsoft/winget-cli/releases/download/v[0-9][A-Za-z0-9._-]*/(?:Microsoft\.DesktopAppInstaller_8wekyb3d8bbwe\.msixbundle|DesktopAppInstaller_Dependencies\.zip)$')][string]$Uri,
        [Parameter(Mandatory)][ValidateRange(1,1073741824)][long]$Bytes,
        [Parameter(Mandatory)][ValidatePattern('^[a-fA-F0-9]{64}$')][string]$Sha256,
        [ValidatePattern('^[a-f0-9]{32}$')][string]$UploadId,
        [ValidateRange(0,1073741824)][long]$Offset = 0,
        [ValidateLength(0,90000)][string]$Data = ''
    )
    $ErrorActionPreference = 'Stop'
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($Uri))).Replace('-','').ToLowerInvariant() } finally { $sha.Dispose() }
    $root = Join-Path $env:ProgramData 'WindowsUpdateAdm\DownloadCache'
    $folder = Join-Path $root $key
    foreach ($directory in @($root,$folder)) {
        if (Test-Path -LiteralPath $directory) {
            if ((Get-Item -LiteralPath $directory).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cacheverzeichnis darf kein Verweis sein.' }
        } else { [void][IO.Directory]::CreateDirectory($directory) }
    }
    $file = Join-Path $folder 'payload.bin'
    $metadata = Join-Path $folder 'payload.json'
    $partial = Join-Path $folder 'transfer.part'
    $statePath = Join-Path $folder 'transfer.json'
    $lock = [IO.File]::Open((Join-Path $folder 'download.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    try {
        foreach ($path in @($file,$metadata,$partial,$statePath)) {
            if ((Test-Path -LiteralPath $path) -and ((Get-Item -LiteralPath $path).Attributes -band [IO.FileAttributes]::ReparsePoint)) { throw 'Cachedatei darf kein Verweis sein.' }
        }
        if ($Action -eq 'Probe') {
            $valid = (Test-Path -LiteralPath $file) -and (Test-Path -LiteralPath $metadata)
            if ($valid) {
                try {
                    $saved = [IO.File]::ReadAllText($metadata) | ConvertFrom-Json
                    $valid = (Get-Item -LiteralPath $file).Length -eq $Bytes -and $saved.Bytes -eq $Bytes -and $saved.Sha256 -eq $Sha256 -and (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash -eq $Sha256
                } catch { $valid = $false }
            }
            return [pscustomobject]@{Present=[bool]$valid;Offset=0}
        }
        if (-not $UploadId) { throw 'Übertragungskennung fehlt.' }
        if ($Action -eq 'Start') {
            # Der Aufrufer darf keinen selbst gewählten Hash als Vertrauen
            # einschleusen: Digest und Größe unabhängig beim offiziellen Release prüfen.
            $assetUri = [uri]$Uri
            $segments = $assetUri.AbsolutePath.Split('/')
            $tag = $segments[$segments.Length-2]
            $assetName = $segments[$segments.Length-1]
            $release = Invoke-RestMethod -Uri ('https://api.github.com/repos/microsoft/winget-cli/releases/tags/'+$tag) -Headers @{'User-Agent'='WindowsUpdateAdm-CacheValidation'} -UseBasicParsing -TimeoutSec 20 -ErrorAction Stop
            $officialAssets = @($release.assets | Where-Object { $_.name -ceq $assetName -and $_.browser_download_url -ceq $Uri })
            if ($officialAssets.Count -ne 1 -or -not $officialAssets[0].PSObject.Properties['digest']) { throw 'Offizielle SHA256-Metadaten fehlen; Cacheübernahme abgelehnt.' }
            $officialHash = [string]$officialAssets[0].digest -replace '^sha256:',''
            if ($officialHash -notmatch '^[a-fA-F0-9]{64}$' -or $officialHash -ine $Sha256 -or [long]$officialAssets[0].size -ne $Bytes) { throw 'Cachedatei entspricht nicht dem offiziellen WinGet-Release.' }
            if (Test-Path -LiteralPath $statePath) {
                $prior = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
                if (([DateTime]::UtcNow - [datetime]$prior.UpdatedUtc).TotalMinutes -lt 30 -and $prior.UploadId -ne $UploadId) { throw 'Cacheübertragung ist bereits aktiv.' }
            }
            [IO.File]::WriteAllBytes($partial, [byte[]]@())
            @{UploadId=$UploadId;Bytes=$Bytes;Sha256=$Sha256;UpdatedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
            return [pscustomobject]@{Offset=0}
        }
        $state = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json
        if ($state.UploadId -ne $UploadId -or $state.Bytes -ne $Bytes -or $state.Sha256 -ne $Sha256) { throw 'Übertragungskennung oder Metadaten stimmen nicht.' }
        $length = (Get-Item -LiteralPath $partial).Length
        if ($length -ne $Offset) { throw 'Unerwartete Übertragungsposition.' }
        if ($Action -eq 'Append') {
            $chunk = [Convert]::FromBase64String($Data)
            if ($chunk.Length -lt 1 -or $chunk.Length -gt 65536 -or $length + $chunk.Length -gt $Bytes) { throw 'Ungültige Blockgröße.' }
            $stream = [IO.File]::Open($partial,[IO.FileMode]::Append,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.Write($chunk,0,$chunk.Length) } finally { $stream.Dispose() }
            $state.UpdatedUtc = [DateTime]::UtcNow.ToString('o')
            $state | ConvertTo-Json | Set-Content -LiteralPath $statePath -Encoding UTF8
            return [pscustomobject]@{Offset=($length+$chunk.Length)}
        }
        if ($length -ne $Bytes -or (Get-FileHash -LiteralPath $partial -Algorithm SHA256).Hash -ne $Sha256) { throw 'Cacheübertragung unvollständig oder SHA256 falsch.' }
        if (Test-Path -LiteralPath $file) { [IO.File]::Replace($partial,$file,$null) } else { [IO.File]::Move($partial,$file) }
        @{Bytes=$Bytes;Sha256=$Sha256;CompletedUtc=[DateTime]::UtcNow.ToString('o')} | ConvertTo-Json | Set-Content -LiteralPath $metadata -Encoding UTF8
        Remove-Item -LiteralPath $statePath -Force
        [pscustomobject]@{Present=$true;Offset=$Bytes}
    } finally { $lock.Dispose() }
}
Export-ModuleMember -Function Receive-WindowsUpdateAdmWinGetCache, Get-WindowsUpdateAdmDeploymentStatus, Update-WindowsUpdateAdmWinGetPackage, Get-WindowsUpdateAdmChocolateyOutdated, Update-WindowsUpdateAdmChocolateyPackages, Invoke-WindowsUpdateAdmWinGetMaintenance
'@
    $moduleSource = $moduleSource.Replace('__VERSION__', $Version).Replace('__SERVER_CORE__', ('$' + $ServerCore.ToString().ToLowerInvariant())).
        Replace('__CERTIFICATE_RUNAS_COMPATIBILITY__', ('$' + $CertificateRunAsCompatibility.ToString().ToLowerInvariant())).
        Replace('__WINGET_UPDATE_ONLY__', ('$' + $WinGetUpdateOnly.ToString().ToLowerInvariant())).
        Replace('__CHOCO_UPDATE_ONLY__', ('$' + $ChocolateyUpdateOnly.ToString().ToLowerInvariant())).
        Replace('__WINGET_MAINTENANCE_ONLY__', ('$' + $WinGetMaintenanceOnly.ToString().ToLowerInvariant())).
        Replace('__CHOCO_MAINTENANCE_ONLY__', ('$' + $ChocolateyMaintenanceOnly.ToString().ToLowerInvariant()))
    return $moduleSource
}

function Write-WindowsUpdateSetupLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [ValidateSet('INFO','WARN','ERROR','SUCCESS','UPDATE')][string]$Level = 'INFO',
        [AllowEmptyString()][string]$LogPath,
        [switch]$LogOnly
    )

    $entry = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
    if (-not [string]::IsNullOrWhiteSpace($LogPath)) {
        try { Add-Content -LiteralPath $LogPath -Value $entry -Encoding UTF8 -ErrorAction Stop }
        catch { Write-Verbose "Setup-Protokoll konnte nicht geschrieben werden: $($_.Exception.Message)" }
    }
    if ($LogOnly) { return }

    $supportsColor = $false
    try {
        $null = $Host.UI.RawUI.ForegroundColor
        $supportsColor = ($Host.Name -eq 'ConsoleHost') -and (-not [Console]::IsOutputRedirected)
    } catch { }
    if (-not $supportsColor) { Write-Host $entry; return }

    $color = switch ($Level) {
        'ERROR' { 'Red' }
        'WARN' { 'Yellow' }
        'SUCCESS' { 'Green' }
        'UPDATE' { 'Cyan' }
        default { $null }
    }
    if ($color) { Write-Host $entry -ForegroundColor $color } else { Write-Host $entry }
}

function Write-WindowsUpdateSetupDiagnostic {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string]$Operation,
        [Parameter(Mandatory)][System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowEmptyString()][string]$LogPath,
        [string]$TargetComputer = $env:COMPUTERNAME,
        [string[]]$Context = @()
    )

    if ([string]::IsNullOrWhiteSpace($LogPath)) { return }
    $details = [System.Collections.Generic.List[string]]::new()
    $details.Add("[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [DIAG] Operation=$Operation")
    $details.Add("[DIAG] Target=$TargetComputer")
    foreach ($item in $Context) { if (-not [string]::IsNullOrWhiteSpace($item)) { $details.Add("[DIAG] Context=$item") } }
    $details.Add("[DIAG] ErrorId=$($ErrorRecord.FullyQualifiedErrorId)")
    $details.Add("[DIAG] Category=$($ErrorRecord.CategoryInfo.Category)")
    if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
        $details.Add("[DIAG] Position=$($ErrorRecord.InvocationInfo.PositionMessage.Trim())")
    }
    if ($ErrorRecord.ScriptStackTrace) { $details.Add("[DIAG] ScriptStackTrace=$($ErrorRecord.ScriptStackTrace)") }
    foreach ($line in ($ErrorRecord.Exception.ToString() -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $details.Add("[DIAG] $($line.TrimEnd())") }
    }
    try { Add-Content -LiteralPath $LogPath -Value $details.ToArray() -Encoding UTF8 -ErrorAction Stop }
    catch { Write-Verbose "Setup-Diagnose konnte nicht geschrieben werden: $($_.Exception.Message)" }
}

Export-ModuleMember -Function New-WindowsUpdateAdmDeploymentStatusModuleSource, Write-WindowsUpdateSetupLog, Write-WindowsUpdateSetupDiagnostic
