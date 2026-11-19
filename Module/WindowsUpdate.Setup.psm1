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
    [PSCustomObject]@{ IsVirtual = $isVirtual; Version = '__VERSION__'; TargetBuild = [Environment]::OSVersion.Version.Build; ServerCore = __SERVER_CORE__; CertificateRunAsCompatibility = __CERTIFICATE_RUNAS_COMPATIBILITY__; CacheTransferSupported = __WINGET_MAINTENANCE_ONLY__; MaintenanceRevision = '6'; MaintenanceFunctionsPresent = [bool]((Get-Command -Name Get-WindowsUpdateAdmChocolateyOutdated -CommandType Function -ErrorAction SilentlyContinue) -and (Get-Command -Name Invoke-WindowsUpdateAdmWinGetMaintenance -CommandType Function -ErrorAction SilentlyContinue)); WinGetUpdateOnly = __WINGET_UPDATE_ONLY__; ChocolateyUpdateOnly = __CHOCO_UPDATE_ONLY__; WinGetMaintenanceOnly = __WINGET_MAINTENANCE_ONLY__; ChocolateyMaintenanceOnly = __CHOCO_MAINTENANCE_ONLY__ }
}
function Update-WindowsUpdateAdmWinGetPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$')][string]$Id,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$')][string]$Source
    )

    # JEA veröffentlicht ausschließlich diesen validierten Paket-Update-Aufruf.
    # Install-, Uninstall- und generische Prozessbefehle sind nicht Teil der Rolle.
    try {
        $updates = @(Update-WinGetPackage -Id $Id -Source $Source -MatchOption EqualsCaseInsensitive -Mode Silent -Confirm:$false -ErrorAction Stop)
        if ($updates.Count -gt 0 -and [string]$updates[-1].Status -eq 'Ok') {
            $last = $updates[-1]
            return [PSCustomObject]@{ Id=$Id; Status=[string]$last.Status; InstallerErrorCode=[string]$last.InstallerErrorCode; ExtendedErrorCode=[string]$last.ExtendedErrorCode; RebootRequired=[bool]$last.RebootRequired }
        }
    } catch { }
    # Fester Update-only-Rückfall: kein Install/Uninstall und keine freien Argumente.
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
        if (-not $process.WaitForExit(1800000)) { try { $process.Kill() } catch {}; throw 'WinGet-Update überschritt 30 Minuten.' }
        $process.WaitForExit()
        $output = $stdout.GetAwaiter().GetResult() + [Environment]::NewLine + $stderr.GetAwaiter().GetResult()
        $code = [int]$process.ExitCode
        [PSCustomObject]@{ Id=$Id; Status=$(if ($code -in @(0,3010)) {'Ok'} else {'Failed'}); InstallerErrorCode=$(if ($code -eq 3010) {'0'} else {[string]$code}); ExtendedErrorCode=''; RebootRequired=($code -eq 3010); Output=$output }
    } finally { $process.Dispose() }
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
