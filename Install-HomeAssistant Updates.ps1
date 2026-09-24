param(
    [switch]$CheckOnly,
    [switch]$DeferPhysicalReboots,
    [string]$HAHost,
    [string]$User,
    [ValidateRange(1, 65535)]
    [int]$Port,
    [string]$KeyPath,
    [string]$SSHPath,
    [ValidateRange(0, 1000)]
    [int]$VMRebootIndexStart = 0
)
# GitHub-Update beim Start: Die eingebundene Routine lädt nur benötigte Skriptdateien.
$scriptUpdatePath = Join-Path $PSScriptRoot 'Update-ServerUpdateScripts.ps1'
if (-not (Test-Path -LiteralPath $scriptUpdatePath -PathType Leaf)) {
    try {
        $scriptUpdateTemporaryPath = $scriptUpdatePath + '.download'
        Invoke-WebRequest -Uri 'https://raw.githubusercontent.com/heppo1990/Server-Update-Skripte/main/Update-ServerUpdateScripts.ps1' -UseBasicParsing -TimeoutSec 20 -OutFile $scriptUpdateTemporaryPath -ErrorAction Stop
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

# Home-Assistant-Verbindung aus der Skript- oder allgemeinen settings.json laden.
# Explizit übergebene Parameter haben immer Vorrang.
$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'WindowsUpdate.Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

$settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName ([System.IO.Path]::GetFileNameWithoutExtension($PSCommandPath))
$haSettings = if ($settings.PSObject.Properties['HomeAssistantSettings']) { $settings.HomeAssistantSettings } else { $null }
if ($null -eq $haSettings -or -not $haSettings.PSObject.Properties['Host'] -or [string]::IsNullOrWhiteSpace([string]$haSettings.Host)) {
    return
}
$configuredKeyPath = if ($haSettings.PSObject.Properties['KeyPath']) { [string]$haSettings.KeyPath } else { '' }
$configuredSSHPath = if ($haSettings.PSObject.Properties['SSHPath']) { [string]$haSettings.SSHPath } else { '' }
$script:HACommandTimeoutSeconds = if ($haSettings.PSObject.Properties['CommandTimeoutSeconds'] -and [int]$haSettings.CommandTimeoutSeconds -gt 0) { [int]$haSettings.CommandTimeoutSeconds } else { 300 }
$script:HARebootWaitSeconds = if ($haSettings.PSObject.Properties['RebootWaitSeconds'] -and [int]$haSettings.RebootWaitSeconds -gt 0) { [int]$haSettings.RebootWaitSeconds } else { 300 }

if (-not $PSBoundParameters.ContainsKey('HAHost')) { $HAHost = [string]$haSettings.Host }
if (-not $PSBoundParameters.ContainsKey('User'))   { $User = [string]$haSettings.User }
if (-not $PSBoundParameters.ContainsKey('Port'))   { $Port = [int]$haSettings.Port }
if (-not $PSBoundParameters.ContainsKey('KeyPath')) {
    $KeyPath = if ([string]::IsNullOrWhiteSpace($configuredKeyPath)) {
        Join-Path -Path $env:USERPROFILE -ChildPath '.ssh\id_rsa_linux'
    } else {
        $configuredKeyPath
    }
}
if (-not $PSBoundParameters.ContainsKey('SSHPath')) {
    $SSHPath = if ([string]::IsNullOrWhiteSpace($configuredSSHPath)) {
        $sshCommand = Get-Command -Name 'ssh.exe' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sshCommand) { $sshCommand.Source } else { Join-Path -Path $env:SystemRoot -ChildPath 'System32\OpenSSH\ssh.exe' }
    } else {
        $configuredSSHPath
    }
}

# ----------------------------
# Logging vorbereiten
# ----------------------------
$script:WriteExecutionLog = -not $CheckOnly
$LogDir = Join-Path $PSScriptRoot "Logs"
if ($script:WriteExecutionLog -and -not (Test-Path $LogDir)) {
    New-Item -Path $LogDir -ItemType Directory | Out-Null
}

$LogFile = if ($script:WriteExecutionLog) { Join-Path $LogDir ("{0}_{1}.log" -f $HAHost, (Get-Date -Format 'yyyyMMdd-HHmm')) } else { '' }

# Statistik-Tracking
$Script:UpdateStats = @{
    CoreUpdated = $false
    CoreVersionOld = ""
    CoreVersionNew = ""
    SupervisorUpdated = $false
    SupervisorVersionOld = ""
    SupervisorVersionNew = ""
    OSUpdated = $false
    OSVersionOld = ""
    OSVersionNew = ""
    AddonsUpdated = 0
    AddonsUpdateList = @()
    BackupCreated = $false
    RebootPerformed = $false
    RebootScheduled = $false
    RebootStartsImmediately = $false
    IsVirtual = $false
    ErrorCount = 0
    PendingPhysicalReboot = $null
}

function Write-HostLog {
    param(
        [Parameter(Mandatory=$true)][string]$Message,
        [Parameter(Mandatory=$true)][string]$RemoteHost,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$LogFile,
        [ValidateSet("Info","Success","Warning","Error")]
        [string]$Level = "Info"
    )

    $colorMap = @{
        "Info"    = "White"
        "Success" = "Green"
        "Warning" = "Yellow"
        "Error"   = "Red"
    }

    $fgColor = $colorMap[$Level]

    try {
        [Console]::OutputEncoding = [System.Text.Encoding]::UTF8
        $script:OutputEncoding    = [System.Text.Encoding]::UTF8
    } catch { }

    Write-Host $Message -ForegroundColor $fgColor
    if ($script:WriteExecutionLog) {
        Add-Content -LiteralPath $LogFile -Value $Message -Encoding utf8
    }
    
    # Fehler-Tracking
    if ($Level -eq "Error") {
        $Script:UpdateStats.ErrorCount++
    }
}

function Get-NextHARebootTime {
    param([Parameter(Mandatory)][string]$Time, [string]$LatestTime = '', [int]$DelayMinutes = 0, [switch]$PreferImmediate)
    if ($PreferImmediate) {
        $now = Get-Date
        $immediateAt = $now.AddMinutes(1 + $DelayMinutes)
        if ([string]::IsNullOrWhiteSpace($LatestTime) -or [string]::IsNullOrWhiteSpace($Time)) { return $immediateAt }
        $startParsed = [datetime]::MinValue
        $latestParsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($Time, [ref]$startParsed) -or -not [datetime]::TryParse($LatestTime, [ref]$latestParsed)) { throw 'Ungültige VM-Wartungsfenster-Uhrzeit.' }
        $windowStart = $now.Date.Add($startParsed.TimeOfDay)
        if ($now -lt $windowStart) { $windowStart = $windowStart.AddDays(-1) }
        $windowEnd = $windowStart.Date.Add($latestParsed.TimeOfDay)
        if ($windowEnd -le $windowStart) { $windowEnd = $windowEnd.AddDays(1) }
        if ($now -ge $windowStart -and $immediateAt -le $windowEnd) { return $immediateAt }
    }
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Time, [ref]$parsed)) { throw "Ungültige Neustartzeit: $Time" }
    $scheduled = (Get-Date).Date.Add($parsed.TimeOfDay)
    if ($scheduled -le (Get-Date)) { $scheduled = $scheduled.AddDays(1) }
    $windowStart = $scheduled
    $scheduled = $scheduled.AddMinutes($DelayMinutes)
    if (-not [string]::IsNullOrWhiteSpace($LatestTime)) {
        $latestParsed = [datetime]::MinValue
        if (-not [datetime]::TryParse($LatestTime, [ref]$latestParsed)) { throw "Ungültige späteste Neustartzeit: $LatestTime" }
        $latest = $windowStart.Date.Add($latestParsed.TimeOfDay)
        if ($latest -lt $windowStart) { $latest = $latest.AddDays(1) }
        if ($scheduled -gt $latest) {
            $windowStart = $windowStart.AddDays(1)
            $scheduled = $windowStart.AddMinutes($DelayMinutes)
            $latest = $latest.AddDays(1)
        }
        if ($scheduled -gt $latest) { throw "VM-Neustartversatz von $DelayMinutes Minute(n) liegt außerhalb des Wartungsfensters." }
    }
    return $scheduled
}

function Test-HAIsVirtual {
    $output = Invoke-HA -Command 'systemd-detect-virt --vm 2>/dev/null || true' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
    $virtualization = ($output -join '').Trim()
    return $virtualization -match '^(kvm|vmware|oracle|microsoft|qemu|xen|bhyve|zvm|apple)$'
}

function Register-HAReboot {
    param([Parameter(Mandatory)][bool]$IsVirtual)
    $physicalTime = [string]$settings.UpdateSettings.PhysicalRebootTime
    $vmStartTime = [string]$settings.UpdateSettings.VMRebootStartTime
    $vmImmediately = [bool]$settings.UpdateSettings.VMRebootImmediately
    $interval = [Math]::Max(0, [int]$settings.UpdateSettings.VMRebootIntervalMinutes)
    $vmOffset = $VMRebootIndexStart * $interval
    $scheduled = $null
    if ($IsVirtual -and $vmImmediately) {
        $scheduled = if (-not [string]::IsNullOrWhiteSpace($vmStartTime)) { Get-NextHARebootTime $vmStartTime ([string]$settings.UpdateSettings.VMRebootWindowEndTime) $vmOffset -PreferImmediate } else { (Get-Date).AddMinutes(1 + $vmOffset) }
    }
    elseif ($IsVirtual -and -not [string]::IsNullOrWhiteSpace($vmStartTime)) { $scheduled = Get-NextHARebootTime $vmStartTime ([string]$settings.UpdateSettings.VMRebootWindowEndTime) $vmOffset }
    elseif (-not $IsVirtual -and -not [string]::IsNullOrWhiteSpace($physicalTime)) {
        if ($DeferPhysicalReboots) {
            $Script:UpdateStats.PendingPhysicalReboot = [PSCustomObject]@{
                Host = $HAHost; User = $User; Port = $Port; KeyPath = $KeyPath; SSHPath = $SSHPath
                RebootTime = $physicalTime; LatestRebootTime = [string]$settings.UpdateSettings.PhysicalRebootWindowEndTime
            }
            Write-HostLog -Message 'Physischer Home-Assistant-Neustart wird bis nach dem gemeinsamen VM-Neustartblock zurückgestellt.' -RemoteHost $HAHost -LogFile $LogFile -Level Warning
            return $true
        }
        $scheduled = Get-NextHARebootTime $physicalTime ([string]$settings.UpdateSettings.PhysicalRebootWindowEndTime)
    }
    if ($null -eq $scheduled) { Write-HostLog -Message 'Kein automatischer Neustart für Home Assistant konfiguriert.' -RemoteHost $HAHost -LogFile $LogFile; return $false }
    $delayMinutes = [Math]::Max(1, [int][Math]::Ceiling(($scheduled - (Get-Date)).TotalMinutes))
    $Script:UpdateStats.RebootStartsImmediately = ($delayMinutes -le 1)
    Write-HostLog -Message "Home-Assistant-Neustart geplant für $($scheduled.ToString('dd.MM.yyyy HH:mm')) (manueller Neustart hebt ihn auf)." -RemoteHost $HAHost -LogFile $LogFile -Level Warning
    # Home Assistant OS kennt den dokumentierten Neustart über die ha-CLI.
    # Ein manueller Neustart beendet einen eventuell wartenden Hintergrundprozess.
    if ($delayMinutes -le 1) {
        Invoke-HA -Command 'ha host reboot' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile | Out-Null
    } else {
        Invoke-HA -Command ("nohup sh -c 'sleep {0}; ha host reboot' >/dev/null 2>&1 &" -f ($delayMinutes * 60)) -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile | Out-Null
    }
    return $true
}

# Die Aufbewahrung wird einmal zu Beginn erledigt, nicht für jede Logzeile.
if ($script:WriteExecutionLog) {
    New-Item -ItemType File -Path $LogFile -Force | Out-Null
    $keepLogFiles = if ($settings.UpdateSettings.PSObject.Properties['KeepLogFiles']) { [int]$settings.UpdateSettings.KeepLogFiles } else { 5 }
    $haLogCleanup = Invoke-WindowsUpdateFileRetention -Directory $LogDir -Filter ("{0}_*.log" -f $HAHost) -KeepFiles $keepLogFiles
    if ($haLogCleanup.RemovedFiles.Count -gt 0) {
        Write-Host "Bereinige $($haLogCleanup.RemovedFiles.Count) alte Home-Assistant-Logdatei(en)." -ForegroundColor DarkGray
    }
    foreach ($failedFile in $haLogCleanup.FailedFiles) {
        Write-Host "WARNUNG: Alte Home-Assistant-Logdatei konnte nicht entfernt werden: $($failedFile.Path)" -ForegroundColor Yellow
    }
}

# ----------------------------
# Sicherstellen, dass SSH und Key da sind
# ----------------------------
if (-not (Test-Path $SSHPath)) {
    Write-HostLog -Message ("ssh.exe nicht gefunden unter '{0}'." -f $SSHPath) -RemoteHost $HAHost -LogFile $LogFile -Level Error
    throw "OpenSSH-Client (ssh.exe) nicht gefunden."
}

function Ensure-SSHKeyExists {
    param(
        [string]$KeyPath,
        [string]$RemoteHost,
        [AllowEmptyString()][string]$LogFile
    )

    if (-not (Test-Path $KeyPath)) {
        Write-HostLog -Message ("SSH-Key '{0}' existiert nicht - erstelle ED25519-Key..." -f $KeyPath) -RemoteHost $RemoteHost -LogFile $LogFile -Level Warning
        ssh-keygen -t ed25519 -f $KeyPath -N "" | Out-Null
        Write-HostLog -Message ("Neuer ED25519-Key erstellt: {0}" -f $KeyPath) -RemoteHost $RemoteHost -LogFile $LogFile -Level Success
    } else {
        Write-HostLog -Message ("SSH-Key '{0}' bereits vorhanden." -f $KeyPath) -RemoteHost $RemoteHost -LogFile $LogFile -Level Info
    }

    $pubPath = "$KeyPath.pub"
    if (-not (Test-Path $pubPath)) {
        Write-HostLog -Message ("Public Key '{0}' fehlt - generiere aus Private Key..." -f $pubPath) -RemoteHost $RemoteHost -LogFile $LogFile -Level Warning
        ssh-keygen -y -f $KeyPath > $pubPath
        Write-HostLog -Message ("Public Key erzeugt: {0}" -f $pubPath) -RemoteHost $RemoteHost -LogFile $LogFile -Level Success
    }
}

Ensure-SSHKeyExists -KeyPath $KeyPath -RemoteHost $HAHost -LogFile $LogFile

# ----------------------------
# SSH-Key auf HA installieren (1 Passwortrunde)
# ----------------------------
function Ensure-SSHKeyOnHA {
    param(
        [string]$RemoteHost,
        [string]$User,
        [int]$Port,
        [string]$KeyPath,
        [string]$SSHPath,
        [AllowEmptyString()][string]$LogFile
    )

    $target = "$User@$RemoteHost"

    Write-HostLog -Message ("Teste SSH-Key-Login zu {0} (BatchMode)..." -f $target) -RemoteHost $RemoteHost -LogFile $LogFile -Level Info
    $test = & $SSHPath -i $KeyPath -p $Port -o BatchMode=yes $target "echo OK" 2>$null

    if ($test -eq "OK") {
        Write-HostLog -Message "SSH-Key-Login funktioniert bereits - keine Passwortabfrage noetig." -RemoteHost $RemoteHost -LogFile $LogFile -Level Success
        return
    }

    Write-HostLog -Message "SSH-Key-Login funktioniert noch nicht - einmalige Passwortabfrage folgt." -RemoteHost $RemoteHost -LogFile $LogFile -Level Warning
    Write-HostLog -Message ("Bitte Passwort fuer {0} in der folgenden SSH-Abfrage eingeben." -f $target) -RemoteHost $RemoteHost -LogFile $LogFile -Level Info

    $pubPath    = "$KeyPath.pub"
    $pubKeyRaw  = Get-Content $pubPath -Raw
    $pubKeyLine = $pubKeyRaw -replace "(\r?\n)+$", ""

    $remoteCmd = "mkdir -p ~/.ssh; chmod 700 ~/.ssh; " +
                 "touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; " +
                 "if ! grep -qxF '" + $pubKeyLine + "' ~/.ssh/authorized_keys 2>/dev/null; then printf '%s`n' '" + $pubKeyLine + "' >> ~/.ssh/authorized_keys; fi"

    & $SSHPath -p $Port -o StrictHostKeyChecking=accept-new $target $remoteCmd

    $test2 = & $SSHPath -i $KeyPath -p $Port -o BatchMode=yes $target "echo OK" 2>$null

    if ($test2 -eq "OK") {
        Write-HostLog -Message "SSH-Key auf Host installiert und erfolgreich getestet - zukuenftige Logins sind passwortlos." -RemoteHost $RemoteHost -LogFile $LogFile -Level Success
    } else {
        Write-HostLog -Message "Fehler: SSH-Key wurde installiert, aber Login mit Key funktioniert trotzdem nicht." -RemoteHost $RemoteHost -LogFile $LogFile -Level Error
        throw "SSH-Key-Login fehlgeschlagen."
    }
}

Ensure-SSHKeyOnHA -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile

# ----------------------------
# Funktionen fuer HA-Befehle
# ----------------------------
function Invoke-HA {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$RemoteHost,
        [Parameter(Mandatory=$true)][string]$User,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$KeyPath,
        [Parameter(Mandatory=$true)][string]$SSHPath,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$LogFile
    )

    $sshArguments = @(Get-WindowsUpdateSshArguments -KeyPath $KeyPath -Port $Port -BatchMode -AcceptNewHostKey)
    $sshArguments += ("{0}@{1}" -f $User, $RemoteHost), $Command

    $pinfo = New-Object System.Diagnostics.ProcessStartInfo
    $pinfo.FileName               = $SSHPath
    $pinfo.Arguments              = ($sshArguments -join " ")
    $pinfo.RedirectStandardError  = $true
    $pinfo.RedirectStandardOutput = $true
    $pinfo.UseShellExecute        = $false
    $pinfo.CreateNoWindow         = $true

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $pinfo
    $proc.Start() | Out-Null

    $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
    $stderrTask = $proc.StandardError.ReadToEndAsync()
    if (-not $proc.WaitForExit($script:HACommandTimeoutSeconds * 1000)) {
        try { $proc.Kill($true) } catch { }
        throw "HA-Befehl '$Command' hat das Zeitlimit von $script:HACommandTimeoutSeconds Sekunden überschritten."
    }
    $stdout = $stdoutTask.GetAwaiter().GetResult()
    $stderr = $stderrTask.GetAwaiter().GetResult()
    $exit = $proc.ExitCode

    $outText = ($stdout + "`n" + $stderr).Trim()

    # ---------------------------
    # Schöne Ausgaben ohne "Pseudo-Fehler"
    # ---------------------------

    # Core schon aktuell
    if ($Command -like "ha core update*" -and $outText -match "already installed") {
        Write-HostLog -Message "Home Assistant Core ist bereits auf der neuesten Version." `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Info
        return $stdout
    }

    # Supervisor schon aktuell
    if ($Command -like "ha supervisor update*" -and $outText -match "No supervisor update available") {
        Write-HostLog -Message "Supervisor ist bereits aktuell. Kein Update erforderlich." `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Info
        return $stdout
    }

    # OS schon aktuell
    if ($Command -like "ha os update*" -and $outText -match "already installed") {
        Write-HostLog -Message "Home Assistant OS ist bereits auf der neuesten Version." `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Info
        return $stdout
    }

    # Reboot trennt Verbindung -> OK, kein Fehler
    if (($Command -eq 'reboot' -or $Command -eq 'ha host reboot') -and $outText -match "Connection .* closed") {
        Write-HostLog -Message "Reboot ausgeloest, Verbindung wurde erwartungsgemaess beendet." `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Warning
        $Script:UpdateStats.RebootPerformed = $true
        return $stdout
    }

    # ---------------------------
    # Update-Tracking
    # ---------------------------
    if ($exit -eq 0 -and $outText -notmatch "already installed|No .* update available") {
        if ($Command -like "ha core update*") {
            $Script:UpdateStats.CoreUpdated = $true
        }
        elseif ($Command -like "ha supervisor update*") {
            $Script:UpdateStats.SupervisorUpdated = $true
        }
        elseif ($Command -like "ha os update*") {
            $Script:UpdateStats.OSUpdated = $true
        }
        elseif ($Command -like "ha addons update*") {
            $Script:UpdateStats.AddonsUpdated++
        }
    }

    # ---------------------------
    # Wirklicher Fehler
    # ---------------------------
    if ($exit -ne 0) {
        Write-HostLog -Message ("Fehler bei HA-Befehl '{0}' (ExitCode {1}): {2}" -f $Command, $exit, $outText) `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Error
    }

    return $stdout
}

function Invoke-HAJson {
    param(
        [Parameter(Mandatory=$true)][string]$Command,
        [Parameter(Mandatory=$true)][string]$RemoteHost,
        [Parameter(Mandatory=$true)][string]$User,
        [Parameter(Mandatory=$true)][int]$Port,
        [Parameter(Mandatory=$true)][string]$KeyPath,
        [Parameter(Mandatory=$true)][string]$SSHPath,
        [Parameter(Mandatory=$true)][AllowEmptyString()][string]$LogFile
    )

    $raw    = Invoke-HA -Command $Command -RemoteHost $RemoteHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
    $joined = ($raw -join [Environment]::NewLine)

    try {
        return $joined | ConvertFrom-Json
    } catch {
        Write-HostLog -Message ("Fehler beim Parsen der JSON-Antwort auf '{0}': {1}" -f $Command, $_.Exception.Message) `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Error
        Write-HostLog -Message ("Antwort war: {0}" -f $joined) `
            -RemoteHost $RemoteHost -LogFile $LogFile -Level Error
        throw
    }
}

function Wait-HAAfterReboot {
    Write-HostLog -Message "Warte maximal $script:HARebootWaitSeconds Sekunden auf Home Assistant nach dem Neustart ..." -RemoteHost $HAHost -LogFile $LogFile -Level Info
    Start-Sleep -Seconds 15
    $deadline = (Get-Date).AddSeconds($script:HARebootWaitSeconds)
    do {
        $arguments = @(Get-WindowsUpdateSshArguments -KeyPath $KeyPath -Port $Port -BatchMode -AcceptNewHostKey)
        $arguments += ("{0}@{1}" -f $User, $HAHost), 'ha core info --raw-json'
        $response = & $SSHPath @arguments 2>$null
        if ($LASTEXITCODE -eq 0 -and (($response -join [Environment]::NewLine) -match '"version"')) {
            Write-HostLog -Message 'Home Assistant ist nach dem Neustart wieder erreichbar.' -RemoteHost $HAHost -LogFile $LogFile -Level Success
            return
        }
        Start-Sleep -Seconds 10
    } while ((Get-Date) -lt $deadline)
    throw "Home Assistant war nach $script:HARebootWaitSeconds Sekunden noch nicht wieder bereit."
}

function Invoke-HAAddOnUpdates {
    Write-HostLog -Message '=== Update Home Assistant Add-ons ===' -RemoteHost $HAHost -LogFile $LogFile -Level Info
    $addonsJson = Invoke-HAJson -Command 'ha addons list --raw-json' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
    if ($addonsJson.data -and $addonsJson.data.addons) { $addons = $addonsJson.data.addons }
    elseif ($addonsJson.addons) { $addons = $addonsJson.addons }
    else { $addons = $addonsJson }
    if (-not $addons) {
        Write-HostLog -Message 'Keine Add-ons gefunden (oder JSON-Struktur unerwartet).' -RemoteHost $HAHost -LogFile $LogFile -Level Warning
        return
    }
    foreach ($addon in $addons) {
        if (-not $addon.update_available) { continue }
        $addonName = if ($addon.name) { $addon.name } else { $addon.slug }
        $addonVersionOld = if ($addon.version) { $addon.version } else { '?' }
        $addonVersionNew = if ($addon.version_latest) { $addon.version_latest } else { '?' }
        Write-HostLog -Message ("Update Add-on: {0} ({1} -> {2})" -f $addonName, $addonVersionOld, $addonVersionNew) -RemoteHost $HAHost -LogFile $LogFile -Level Info
        Invoke-HA -Command ("ha addons update {0}" -f $addon.slug) -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        $Script:UpdateStats.AddonsUpdateList += [PSCustomObject]@{ Name = $addonName; VersionOld = $addonVersionOld; VersionNew = $addonVersionNew }
    }
}

# ----------------------------
# Reiner Update-Check (kein Backup, kein Update, kein Neustart)
# ----------------------------
if ($CheckOnly) {
    Write-HostLog -Message '=== Prüfe verfügbare Home-Assistant-Updates (nur lesend) ===' -RemoteHost $HAHost -LogFile $LogFile -Level Info
    $details = @()
    try {
        $coreInfo = Invoke-HAJson -Command 'ha core info --raw-json' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        if ($coreInfo.data.update_available) {
            $details += [PSCustomObject]@{ Component='Core'; Current=[string]$coreInfo.data.version; Available=[string]$coreInfo.data.version_latest }
        }
        $supervisorInfo = Invoke-HAJson -Command 'ha supervisor info --raw-json' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        if ($supervisorInfo.data.update_available) {
            $details += [PSCustomObject]@{ Component='Supervisor'; Current=[string]$supervisorInfo.data.version; Available=[string]$supervisorInfo.data.version_latest }
        }
        $osInfo = Invoke-HAJson -Command 'ha os info --raw-json' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        if ($osInfo.data.update_available) {
            $details += [PSCustomObject]@{ Component='OS'; Current=[string]$osInfo.data.version; Available=[string]$osInfo.data.version_latest }
        }
        $addonsJson = Invoke-HAJson -Command 'ha addons list --raw-json' -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        $addons = if ($addonsJson.data -and $addonsJson.data.addons) { @($addonsJson.data.addons) } elseif ($addonsJson.addons) { @($addonsJson.addons) } else { @($addonsJson) }
        foreach ($addon in $addons | Where-Object { $_.update_available }) {
            $details += [PSCustomObject]@{ Component=(if ($addon.name) { "Add-on: $($addon.name)" } else { "Add-on: $($addon.slug)" }); Current=[string]$addon.version; Available=[string]$addon.version_latest }
        }
        foreach ($detail in $details) {
            Write-HostLog -Message ("Update verfügbar: {0} ({1} -> {2})" -f $detail.Component, $detail.Current, $detail.Available) -RemoteHost $HAHost -LogFile $LogFile -Level Warning
        }
        $checkStats = [PSCustomObject]@{ Host=$HAHost; Success=$true; AvailableUpdates=$details.Count; UpdateDetails=$details; Error=''; LogFile=$LogFile }
    }
    catch {
        Write-HostLog -Message "Home-Assistant-Check fehlgeschlagen: $($_.Exception.Message)" -RemoteHost $HAHost -LogFile $LogFile -Level Error
        $checkStats = [PSCustomObject]@{ Host=$HAHost; Success=$false; AvailableUpdates=0; UpdateDetails=@(); Error=$_.Exception.Message; LogFile=$LogFile }
    }
    $checkStats | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'ha_update_check_stats.json') -Encoding utf8
    Write-Host "Home-Assistant-Check: $($checkStats.AvailableUpdates) Update(s) verfügbar." -ForegroundColor Cyan
    exit $(if ($checkStats.Success) { 0 } else { 1 })
}

# ----------------------------
# Neues Backup erstellen
# ----------------------------
$timestamp      = Get-Date -Format "yyyyMMdd-HHmm"
$NewBackupName  = "PreUpdate_$timestamp"
$NewBackupFile  = "$NewBackupName.tar"

Write-HostLog -Message ("=== Erstelle neues Backup: {0} ===" -f $NewBackupName) -RemoteHost $HAHost -LogFile $LogFile -Level Info

$backupCmd = ('ha backups new --name "{0}" --filename "{1}"' -f $NewBackupName, $NewBackupFile)
Invoke-HA -Command $backupCmd -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile | Out-Null

Start-Sleep -Seconds 5

$backupsJson = Invoke-HAJson -Command "ha backups list --raw-json" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
$backups     = $backupsJson.data.backups

$currentBackup = $backups |
    Where-Object { $_.name -eq $NewBackupName } |
    Sort-Object {[datetime]$_.date} -Descending |
    Select-Object -First 1

if (-not $currentBackup) {
    Write-HostLog -Message "Backup konnte nicht gefunden werden!" -RemoteHost $HAHost -LogFile $LogFile -Level Error
    throw "Backup nicht gefunden."
}

$NewBackupSlug = $currentBackup.slug
Write-HostLog -Message ("Backup abgeschlossen: {0} (Slug: {1})" -f $NewBackupName, $NewBackupSlug) -RemoteHost $HAHost -LogFile $LogFile -Level Success
$Script:UpdateStats.BackupCreated = $true

# ----------------------------
# Maximal 3 Backups auf NAS behalten
# ----------------------------
$allBackups = $backups |
    Where-Object { $_.location -eq "NAS" -and $_.type -in @("full","partial") } |
    Sort-Object {[datetime]$_.date} -Descending

if ($allBackups.Count -gt 3) {
    $toDelete = $allBackups | Select-Object -Skip 3
    foreach ($old in $toDelete) {
        if ($old.protected) {
            Write-HostLog -Message ("Entferne Schutz von Backup: {0} ({1})" -f $old.name, $old.slug) -RemoteHost $HAHost -LogFile $LogFile -Level Warning
            Invoke-HA -Command ("ha backups unprotect {0}" -f $old.slug) -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile | Out-Null
            Start-Sleep -Seconds 2
        }
        Write-HostLog -Message ("Loesche altes Backup vom NAS: {0} ({1})" -f $old.name, $old.slug) -RemoteHost $HAHost -LogFile $LogFile -Level Info
        Invoke-HA -Command ("ha backups remove {0}" -f $old.slug) -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile | Out-Null
    }
} else {
    Write-HostLog -Message ("Es sind nur {0} Backups auf dem NAS vorhanden - nichts zu loeschen." -f $allBackups.Count) -RemoteHost $HAHost -LogFile $LogFile -Level Info
}

# ----------------------------
# Updates installieren
# ----------------------------

# Hole aktuelle Versionen VOR den Updates
Write-HostLog -Message "=== Ermittle aktuelle Versionen ===" -RemoteHost $HAHost -LogFile $LogFile -Level Info

try {
    $coreInfo = Invoke-HAJson -Command "ha core info --raw-json" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
    if ($coreInfo.data.version) {
        $Script:UpdateStats.CoreVersionOld = $coreInfo.data.version
    }
} catch {
    Write-HostLog -Message "Konnte Core-Version nicht ermitteln" -RemoteHost $HAHost -LogFile $LogFile -Level Warning
}

try {
    $supervisorInfo = Invoke-HAJson -Command "ha supervisor info --raw-json" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
    if ($supervisorInfo.data.version) {
        $Script:UpdateStats.SupervisorVersionOld = $supervisorInfo.data.version
    }
} catch {
    Write-HostLog -Message "Konnte Supervisor-Version nicht ermitteln" -RemoteHost $HAHost -LogFile $LogFile -Level Warning
}

try {
    $osInfo = Invoke-HAJson -Command "ha os info --raw-json" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
    if ($osInfo.data.version) {
        $Script:UpdateStats.OSVersionOld = $osInfo.data.version
    }
} catch {
    Write-HostLog -Message "Konnte OS-Version nicht ermitteln" -RemoteHost $HAHost -LogFile $LogFile -Level Warning
}

Write-HostLog -Message "=== Update Home Assistant Core ===" -RemoteHost $HAHost -LogFile $LogFile -Level Info
Invoke-HA -Command "ha core update" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile

# Hole neue Core-Version falls aktualisiert
if ($Script:UpdateStats.CoreUpdated) {
    Start-Sleep -Seconds 5
    try {
        $coreInfoNew = Invoke-HAJson -Command "ha core info --raw-json" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        if ($coreInfoNew.data.version) {
            $Script:UpdateStats.CoreVersionNew = $coreInfoNew.data.version
        }
    } catch { }
}

Write-HostLog -Message "=== Update Home Assistant Supervisor ===" -RemoteHost $HAHost -LogFile $LogFile -Level Info
Invoke-HA -Command "ha supervisor update" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile

# Hole neue Supervisor-Version falls aktualisiert
if ($Script:UpdateStats.SupervisorUpdated) {
    Start-Sleep -Seconds 5
    try {
        $supervisorInfoNew = Invoke-HAJson -Command "ha supervisor info --raw-json" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile
        if ($supervisorInfoNew.data.version) {
            $Script:UpdateStats.SupervisorVersionNew = $supervisorInfoNew.data.version
        }
    } catch { }
}

Write-HostLog -Message "=== Update Home Assistant OS ===" -RemoteHost $HAHost -LogFile $LogFile -Level Info
$Script:UpdateStats.IsVirtual = Test-HAIsVirtual
Invoke-HA -Command "ha os update" -RemoteHost $HAHost -User $User -Port $Port -KeyPath $KeyPath -SSHPath $SSHPath -LogFile $LogFile

# Nach einem OS-Update ist vor dem geforderten Neustart kein verlässlicher
# Supervisor-Zugriff garantiert. Die neue Versionsnummer wird daher bewusst
# erst beim späteren Check bzw. Installationslauf abgefragt.
if ($Script:UpdateStats.OSUpdated) {
    Write-HostLog -Message 'HA-OS-Version wird nach dem Neustart erneut geprüft.' -RemoteHost $HAHost -LogFile $LogFile -Level Info
}

if ($Script:UpdateStats.OSUpdated) {
    # Nach einem HA-OS-Update darf erst nach dem Reboot wieder auf den
    # Supervisor zugegriffen werden. Bei einem sofortigen VM-Reboot wartet der
    # Installationslauf auf die Rückkehr und fährt danach mit den Add-ons fort.
    $Script:UpdateStats.RebootScheduled = Register-HAReboot -IsVirtual $Script:UpdateStats.IsVirtual
    if ($Script:UpdateStats.RebootScheduled -and $Script:UpdateStats.RebootStartsImmediately) {
        Wait-HAAfterReboot
        Invoke-HAAddOnUpdates
    } elseif ($Script:UpdateStats.RebootScheduled) {
        Write-HostLog -Message 'HA-OS wurde aktualisiert; Add-on-Updates folgen nach dem geplanten Neustart im nächsten Installationslauf.' -RemoteHost $HAHost -LogFile $LogFile -Level Warning
    } else {
        Write-HostLog -Message 'HA-OS wurde aktualisiert, aber kein automatischer Neustart ist konfiguriert. Add-on-Updates werden nicht vor dem manuellen Neustart ausgeführt.' -RemoteHost $HAHost -LogFile $LogFile -Level Warning
    }
} else {
    Invoke-HAAddOnUpdates

    $hasUpdates = $Script:UpdateStats.CoreUpdated -or $Script:UpdateStats.SupervisorUpdated -or ($Script:UpdateStats.AddonsUpdated -gt 0)
    if ($hasUpdates) {
        $Script:UpdateStats.IsVirtual = Test-HAIsVirtual
        $Script:UpdateStats.RebootScheduled = Register-HAReboot -IsVirtual $Script:UpdateStats.IsVirtual
    } else {
        Write-HostLog -Message 'Kein Home-Assistant-Neustart: Es wurden keine Updates installiert.' -RemoteHost $HAHost -LogFile $LogFile
    }
}

Write-HostLog -Message "=== Alle Updates abgeschlossen ===" -RemoteHost $HAHost -LogFile $LogFile -Level Success
Write-Host ("Logdatei: {0}" -f $LogFile)

# ============================================
# Statistiken für Hauptskript exportieren (MIT HostStatus und Details)
# ============================================
$TotalUpdates = 0
if ($Script:UpdateStats.CoreUpdated) { $TotalUpdates++ }
if ($Script:UpdateStats.SupervisorUpdated) { $TotalUpdates++ }
if ($Script:UpdateStats.OSUpdated) { $TotalUpdates++ }
$TotalUpdates += $Script:UpdateStats.AddonsUpdated

# Erstelle detaillierte Update-Liste
$updateDetailsList = @()

if ($Script:UpdateStats.CoreUpdated) {
    $versionInfo = if ($Script:UpdateStats.CoreVersionNew) {
        "$($Script:UpdateStats.CoreVersionOld) → $($Script:UpdateStats.CoreVersionNew)"
    } else {
        "aktualisiert"
    }
    $updateDetailsList += "Core ($versionInfo)"
}

if ($Script:UpdateStats.SupervisorUpdated) {
    $versionInfo = if ($Script:UpdateStats.SupervisorVersionNew) {
        "$($Script:UpdateStats.SupervisorVersionOld) → $($Script:UpdateStats.SupervisorVersionNew)"
    } else {
        "aktualisiert"
    }
    $updateDetailsList += "Supervisor ($versionInfo)"
}

if ($Script:UpdateStats.OSUpdated) {
    $versionInfo = if ($Script:UpdateStats.OSVersionNew) {
        "$($Script:UpdateStats.OSVersionOld) → $($Script:UpdateStats.OSVersionNew)"
    } else {
        "aktualisiert"
    }
    $updateDetailsList += "OS ($versionInfo)"
}

if ($Script:UpdateStats.AddonsUpdated -gt 0) {
    if ($Script:UpdateStats.AddonsUpdateList.Count -gt 0) {
        foreach ($addon in $Script:UpdateStats.AddonsUpdateList) {
            $updateDetailsList += "Add-on: $($addon.Name) ($($addon.VersionOld) → $($addon.VersionNew))"
        }
    } else {
        $updateDetailsList += "$($Script:UpdateStats.AddonsUpdated) Add-on(s) aktualisiert"
    }
}

$detailsString = if ($updateDetailsList.Count -gt 0) {
    $updateDetailsList -join "<br>"
} else {
    "Keine Updates"
}

# Kurz-Zusammenfassung für Summary
$summaryItems = @()
if ($Script:UpdateStats.CoreUpdated) { $summaryItems += "Core" }
if ($Script:UpdateStats.SupervisorUpdated) { $summaryItems += "Supervisor" }
if ($Script:UpdateStats.OSUpdated) { $summaryItems += "OS" }
if ($Script:UpdateStats.AddonsUpdated -gt 0) { $summaryItems += "$($Script:UpdateStats.AddonsUpdated) Add-on(s)" }
$summaryString = if ($summaryItems.Count -gt 0) { $summaryItems -join ", " } else { "Keine Updates" }

# HostStatus (wie Linux-Skript)
$HostStatus = [PSCustomObject]@{
    Host = $HAHost
    Status = if ($Script:UpdateStats.ErrorCount -eq 0) { "Erfolgreich" } else { "Fehler" }
    UpdateCount = $TotalUpdates
    Summary = $summaryString
    Details = $detailsString
    LogFile = $LogFile
}

$HAStats = @{
    TotalHosts = 1
    SuccessfulUpdates = if ($Script:UpdateStats.ErrorCount -eq 0) { $TotalUpdates } else { 0 }
    FailedUpdates = if ($Script:UpdateStats.ErrorCount -gt 0) { 1 } else { 0 }
    ComponentsUpdated = @{
        Core = $Script:UpdateStats.CoreUpdated
        Supervisor = $Script:UpdateStats.SupervisorUpdated
        OS = $Script:UpdateStats.OSUpdated
        Addons = $Script:UpdateStats.AddonsUpdated
    }
    TotalComponentsUpdated = $TotalUpdates
    BackupCreated = $Script:UpdateStats.BackupCreated
    RebootPerformed = $Script:UpdateStats.RebootPerformed
    RebootScheduled = $Script:UpdateStats.RebootScheduled
    VMRebootsScheduled = if ($Script:UpdateStats.RebootScheduled -and $Script:UpdateStats.IsVirtual) { 1 } else { 0 }
    PendingPhysicalReboot = $Script:UpdateStats.PendingPhysicalReboot
    ErrorCount = $Script:UpdateStats.ErrorCount
    HostStatus = @($HostStatus)  # Array für Konsistenz mit Linux-Skript
}

$StatsFile = Join-Path $PSScriptRoot "ha_update_stats.json"
$HAStats | ConvertTo-Json -Depth 5 | Set-Content $StatsFile

Write-Host "`n📊 Statistiken gespeichert: $StatsFile"
Write-Host "   • Home Assistant Host: $HAHost"
Write-Host "   • Status: $($HostStatus.Status)"
Write-Host "   • Komponenten aktualisiert: $TotalUpdates"
Write-Host "     - Core: $($Script:UpdateStats.CoreUpdated) $(if($Script:UpdateStats.CoreVersionNew){"($($Script:UpdateStats.CoreVersionOld) → $($Script:UpdateStats.CoreVersionNew))"})"
Write-Host "     - Supervisor: $($Script:UpdateStats.SupervisorUpdated) $(if($Script:UpdateStats.SupervisorVersionNew){"($($Script:UpdateStats.SupervisorVersionOld) → $($Script:UpdateStats.SupervisorVersionNew))"})"
Write-Host "     - OS: $($Script:UpdateStats.OSUpdated) $(if($Script:UpdateStats.OSVersionNew){"($($Script:UpdateStats.OSVersionOld) → $($Script:UpdateStats.OSVersionNew))"})"
Write-Host "     - Add-ons: $($Script:UpdateStats.AddonsUpdated)"
if ($Script:UpdateStats.AddonsUpdateList.Count -gt 0) {
    foreach ($addon in $Script:UpdateStats.AddonsUpdateList) {
        Write-Host "       * $($addon.Name): $($addon.VersionOld) → $($addon.VersionNew)"
    }
}
Write-Host "   • Backup erstellt: $($Script:UpdateStats.BackupCreated)"
Write-Host "   • Fehler: $($Script:UpdateStats.ErrorCount)"
