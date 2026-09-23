[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$CheckOnly,
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

$commonModulePath = Join-Path -Path $PSScriptRoot -ChildPath 'WindowsUpdate.Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

$settings = Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName ([IO.Path]::GetFileNameWithoutExtension($PSCommandPath))
$linuxSettings = if ($settings.PSObject.Properties['LinuxSettings']) { $settings.LinuxSettings } else { $null }
if ($null -eq $linuxSettings -or -not $linuxSettings.PSObject.Properties['Hosts'] -or @($linuxSettings.Hosts | Where-Object { $_ }).Count -eq 0) {
    return
}
$configuredKeyPath = if ($linuxSettings.PSObject.Properties['KeyPath']) { [string]$linuxSettings.KeyPath } else { '' }
$configuredSSHPath = if ($linuxSettings.PSObject.Properties['SSHPath']) { [string]$linuxSettings.SSHPath } else { '' }

if (-not $PSBoundParameters.ContainsKey('KeyPath')) {
    $KeyPath = if ([string]::IsNullOrWhiteSpace($configuredKeyPath)) { Join-Path $env:USERPROFILE '.ssh\id_rsa_linux' } else { $configuredKeyPath }
}
if (-not $PSBoundParameters.ContainsKey('SSHPath')) {
    $SSHPath = if ([string]::IsNullOrWhiteSpace($configuredSSHPath)) {
        $sshCommand = Get-Command -Name 'ssh.exe', 'ssh' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sshCommand) { $sshCommand.Path } else { Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' }
    } else { $configuredSSHPath }
}

$script:SSHPath = $SSHPath
$scpCommand = Get-Command -Name 'scp.exe', 'scp' -ErrorAction SilentlyContinue | Select-Object -First 1
$script:SCPPath = if ($scpCommand) { $scpCommand.Path } else { Join-Path (Split-Path -Path $script:SSHPath -Parent) 'scp.exe' }
$script:ConnectTimeoutSeconds = if ([int]$linuxSettings.ConnectTimeoutSeconds -gt 0) { [int]$linuxSettings.ConnectTimeoutSeconds } else { 15 }
$script:LockWaitIntervals = if ([int]$linuxSettings.LockWaitMinutes -gt 0) { [int]$linuxSettings.LockWaitMinutes * 2 } else { 10 }
$script:LogDirectory = Join-Path $PSScriptRoot 'Logs'
$script:WriteExecutionLog = -not $CheckOnly
$script:VMRebootIndex = $VMRebootIndexStart

function Write-LinuxLog {
    param([Parameter(Mandatory)][string]$Message, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile, [ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info')
    $color = @{ Info='White'; Success='Green'; Warning='Yellow'; Error='Red' }[$Level]
    Write-Host $Message -ForegroundColor $color
    if ($script:WriteExecutionLog) {
        [IO.File]::AppendAllText($LogFile, $Message + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
}

function Invoke-LinuxLogRetention {
    param([Parameter(Mandatory)][string]$RemoteHost)
    if (-not $script:WriteExecutionLog) { return }
    $keepLogFiles = if ($settings.UpdateSettings.PSObject.Properties['KeepLogFiles']) { [int]$settings.UpdateSettings.KeepLogFiles } else { 5 }
    $retention = Invoke-WindowsUpdateFileRetention -Directory $script:LogDirectory -Filter ("{0}_*.log" -f $RemoteHost) -KeepFiles $keepLogFiles
    foreach ($removedFile in @($retention.RemovedFiles)) {
        Write-Host "Bereinige altes Linux-Log: $removedFile" -ForegroundColor DarkGray
    }
    foreach ($failedFile in @($retention.FailedFiles)) {
        Write-Warning "Linux-Log konnte nicht entfernt werden ($($failedFile.Path)): $($failedFile.Error)"
    }
}

function Get-LinuxSshArguments {
    param([Parameter(Mandatory)][string]$KeyPath, [switch]$BatchMode, [switch]$AcceptNewHostKey)
    return Get-WindowsUpdateSshArguments -KeyPath $KeyPath -ConnectTimeoutSeconds $script:ConnectTimeoutSeconds -BatchMode:$BatchMode -AcceptNewHostKey:$AcceptNewHostKey
}

function Get-NextLinuxScheduledTime {
    param([Parameter(Mandatory)][string]$Time)
    $parsed = [datetime]::MinValue
    if (-not [datetime]::TryParse($Time, [ref]$parsed)) { throw "Ungültige Neustartzeit: $Time" }
    $scheduled = (Get-Date).Date.Add($parsed.TimeOfDay)
    if ($scheduled -le (Get-Date)) { $scheduled = $scheduled.AddDays(1) }
    return $scheduled
}

function Test-LinuxHostIsVirtual {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath)
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", 'systemd-detect-virt --vm 2>/dev/null || true'
    $output = & $script:SSHPath @arguments 2>&1
    return -not [string]::IsNullOrWhiteSpace(($output -join '').Trim())
}

function Register-LinuxReboot {
    param(
        [Parameter(Mandatory)][string]$RemoteHost,
        [Parameter(Mandatory)][string]$RemoteUser,
        [Parameter(Mandatory)][string]$KeyPath,
        [Parameter(Mandatory)][bool]$IsVirtual,
        [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile
    )
    $physicalTime = [string]$settings.UpdateSettings.PhysicalRebootTime
    $vmStartTime = [string]$settings.UpdateSettings.VMRebootStartTime
    $vmImmediately = [bool]$settings.UpdateSettings.VMRebootImmediately
    $interval = if ([int]$settings.UpdateSettings.VMRebootIntervalMinutes -gt 0) { [int]$settings.UpdateSettings.VMRebootIntervalMinutes } else { 30 }
    $scheduled = $null
    if ($IsVirtual -and $vmImmediately) { $scheduled = (Get-Date).AddMinutes(1) }
    elseif ($IsVirtual -and -not [string]::IsNullOrWhiteSpace($vmStartTime)) { $scheduled = (Get-NextLinuxScheduledTime $vmStartTime).AddMinutes($script:VMRebootIndex * $interval); $script:VMRebootIndex++ }
    elseif (-not $IsVirtual -and -not [string]::IsNullOrWhiteSpace($physicalTime)) { $scheduled = Get-NextLinuxScheduledTime $physicalTime }
    if ($null -eq $scheduled) { Write-LinuxLog -Message "Kein automatischer Neustart für $RemoteHost konfiguriert." -LogFile $LogFile; return $false }
    $delayMinutes = [Math]::Max(1, [int][Math]::Ceiling(($scheduled - (Get-Date)).TotalMinutes))
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", "sudo /sbin/shutdown -r +$delayMinutes"
    & $script:SSHPath @arguments 2>&1 | ForEach-Object { if ($_){ Write-LinuxLog -Message ([string]$_) -LogFile $LogFile } }
    if ($LASTEXITCODE -ne 0) { throw "Linux-Neustart auf $RemoteHost konnte nicht geplant werden." }
    Write-LinuxLog -Message "Neustart auf $RemoteHost geplant für $($scheduled.ToString('dd.MM.yyyy HH:mm')) (manueller Neustart hebt ihn auf)." -LogFile $LogFile -Level Warning
    return $true
}

function Ensure-LinuxSSHKey {
    param([Parameter(Mandatory)][string]$KeyPath)
    $keyDirectory = Split-Path $KeyPath -Parent
    if (-not (Test-Path -LiteralPath $keyDirectory)) { New-Item -Path $keyDirectory -ItemType Directory -Force | Out-Null }
    $keygen = Get-Command -Name 'ssh-keygen.exe','ssh-keygen' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $keygen) { throw 'OpenSSH-Keygen (ssh-keygen) wurde nicht gefunden.' }
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        & $keygen.Path -t ed25519 -f $KeyPath -N '' | Out-Null
        if ($LASTEXITCODE -ne 0) { throw "SSH-Schlüssel konnte nicht erstellt werden: $KeyPath" }
        Write-Host "Neuer ED25519-SSH-Schlüssel erstellt: $KeyPath" -ForegroundColor Green
    }
    if (-not (Test-Path -LiteralPath "$KeyPath.pub")) {
        & $keygen.Path -y -f $KeyPath | Set-Content -LiteralPath "$KeyPath.pub" -Encoding utf8
        if ($LASTEXITCODE -ne 0) { throw "Öffentlicher SSH-Schlüssel konnte nicht erstellt werden: $KeyPath.pub" }
    }
}

function Test-LinuxKeyLogin {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath)
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", 'printf OK'
    $result = & $script:SSHPath @arguments 2>&1
    return ($LASTEXITCODE -eq 0 -and (($result -join "`n") -match 'OK'))
}

function Install-LinuxPublicKey {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile)
    $publicKey = (Get-Content -LiteralPath "$KeyPath.pub" -Raw -Encoding utf8).Trim()
    $encodedKey = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($publicKey))
    $remoteCommand = "umask 077; mkdir -p ~/.ssh; chmod 700 ~/.ssh; touch ~/.ssh/authorized_keys; chmod 600 ~/.ssh/authorized_keys; key=`$(printf '%s' '$encodedKey' | base64 -d); grep -qxF `"`$key`" ~/.ssh/authorized_keys || printf '%s\n' `"`$key`" >> ~/.ssh/authorized_keys"
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -AcceptNewHostKey
    $arguments += @('-o','PreferredAuthentications=password,keyboard-interactive','-o','PubkeyAuthentication=no',"${RemoteUser}@${RemoteHost}",$remoteCommand)
    Write-LinuxLog -Message "SSH-Schlüssel auf $RemoteHost fehlt. Bitte das SSH-Passwort einmal eingeben ..." -LogFile $LogFile -Level Warning
    & $script:SSHPath @arguments 2>&1 | ForEach-Object { if ($_){ Write-LinuxLog -Message ([string]$_) -LogFile $LogFile } }
    if ($LASTEXITCODE -ne 0 -or -not (Test-LinuxKeyLogin -RemoteHost $RemoteHost -RemoteUser $RemoteUser -KeyPath $KeyPath)) { throw "SSH-Schlüssel konnte auf $RemoteHost nicht eingerichtet oder geprüft werden." }
    Write-LinuxLog -Message "SSH-Schlüssel-Login für $RemoteHost ist eingerichtet." -LogFile $LogFile -Level Success
}

function Test-LinuxUpdateSudo {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath)
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", 'sudo -n /usr/bin/true >/dev/null 2>&1'
    & $script:SSHPath @arguments 2>$null | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Set-LinuxUpdateSudo {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile)
    if (Test-LinuxUpdateSudo -RemoteHost $RemoteHost -RemoteUser $RemoteUser -KeyPath $KeyPath) {
        Write-LinuxLog -Message "NOPASSWD für Updates ist auf $RemoteHost bereits eingerichtet." -LogFile $LogFile -Level Success
        return
    }
    $safeUser = $RemoteUser -replace '[^a-zA-Z0-9_-]', ''
    if ([string]::IsNullOrWhiteSpace($safeUser)) { throw "Ungültiger Linux-Benutzername: $RemoteUser" }
    $remoteSudoers = "/etc/sudoers.d/${safeUser}_update_nopasswd"
    $sudoersContent = @"
# Verwaltet durch Install-Linux Updates.ps1; nur Update- und Reboot-Befehle.
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/true
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/apt-get update
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/apt-get -s upgrade
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/apt-get upgrade -y
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/apt-get autoremove -y
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/apt-get clean -y
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/apt-get autoclean -y
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/dnf -y upgrade --refresh
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/yum -y update
$RemoteUser ALL=(ALL) NOPASSWD: /usr/bin/fuser
$RemoteUser ALL=(ALL) NOPASSWD: /bin/fuser
$RemoteUser ALL=(ALL) NOPASSWD: /usr/sbin/reboot
$RemoteUser ALL=(ALL) NOPASSWD: /sbin/reboot
$RemoteUser ALL=(ALL) NOPASSWD: /usr/sbin/shutdown
$RemoteUser ALL=(ALL) NOPASSWD: /sbin/shutdown
"@
    $encodedSudoers = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sudoersContent))
    $remoteScript = "/tmp/configure_update_sudo_${safeUser}.sh"
    $bootstrapScript = @'
#!/bin/sh
set -eu
sudo -S -p '' /bin/sh -c 'printf %s "$1" | base64 -d > "$2" && chmod 440 "$2" && chown root:root "$2" && visudo -c -f "$2" >/dev/null' -- '__SUDOERS_B64__' '__SUDOERS_PATH__'
echo SUDOERS_CONFIGURED
'@.Replace('__SUDOERS_B64__',$encodedSudoers).Replace('__SUDOERS_PATH__',$remoteSudoers)
    $localScript = Join-Path ([IO.Path]::GetTempPath()) ("configure_update_sudo_{0}_{1}.sh" -f $safeUser,[guid]::NewGuid().ToString('N'))
    $localPassword = Join-Path ([IO.Path]::GetTempPath()) ("sudo_password_{0}_{1}.txt" -f $safeUser,[guid]::NewGuid().ToString('N'))
    $bstr = [IntPtr]::Zero
    try {
        [IO.File]::WriteAllText($localScript,($bootstrapScript -replace "`r`n","`n"),[Text.UTF8Encoding]::new($false))
        $scpArguments = @('-i',$KeyPath,'-o',"ConnectTimeout=$script:ConnectTimeoutSeconds",$localScript,"${RemoteUser}@${RemoteHost}:$remoteScript")
        & $script:SCPPath @scpArguments 2>&1 | ForEach-Object { if ($_){ Write-LinuxLog -Message ([string]$_) -LogFile $LogFile } }
        if ($LASTEXITCODE -ne 0) { throw "Bootstrap-Skript konnte nicht nach $RemoteHost kopiert werden." }
        Write-LinuxLog -Message "NOPASSWD wird auf $RemoteHost eingerichtet. Bitte das sudo-Passwort einmal eingeben ..." -LogFile $LogFile -Level Warning
        $securePassword = Read-Host -Prompt "sudo-Passwort für $RemoteUser@$RemoteHost" -AsSecureString
        $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($securePassword)
        $plainPassword = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($bstr)
        if ([string]::IsNullOrEmpty($plainPassword)) { throw 'Es wurde kein sudo-Passwort eingegeben.' }
        [IO.File]::WriteAllText($localPassword,$plainPassword + [Environment]::NewLine,[Text.UTF8Encoding]::new($false))
        $stdoutFile = "$localScript.stdout"; $stderrFile = "$localScript.stderr"
        $argumentLine = "-T -i `"$KeyPath`" -o BatchMode=yes -o ConnectTimeout=$script:ConnectTimeoutSeconds ${RemoteUser}@${RemoteHost} sh $remoteScript"
        $process = Start-Process -FilePath $script:SSHPath -ArgumentList $argumentLine -RedirectStandardInput $localPassword -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile -PassThru -Wait -NoNewWindow
        $setupOutput = @()
        if (Test-Path -LiteralPath $stdoutFile) { $setupOutput += Get-Content -LiteralPath $stdoutFile }
        if (Test-Path -LiteralPath $stderrFile) { $setupOutput += Get-Content -LiteralPath $stderrFile }
        $setupOutput | ForEach-Object { if ($_){ Write-LinuxLog -Message ([string]$_) -LogFile $LogFile } }
        Remove-Item -LiteralPath $stdoutFile,$stderrFile -Force -ErrorAction SilentlyContinue
        if ($process.ExitCode -ne 0 -or -not ($setupOutput -match 'SUDOERS_CONFIGURED')) { throw 'NOPASSWD-Konfiguration wurde vom Linux-Server abgelehnt.' }
    }
    finally {
        if ($bstr -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
        Remove-Item -LiteralPath $localScript,$localPassword -Force -ErrorAction SilentlyContinue
        $cleanupArguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
        $cleanupArguments += "${RemoteUser}@${RemoteHost}", "rm -f $remoteScript"
        & $script:SSHPath @cleanupArguments 2>$null | Out-Null
    }
    if (-not (Test-LinuxUpdateSudo -RemoteHost $RemoteHost -RemoteUser $RemoteUser -KeyPath $KeyPath)) { throw 'NOPASSWD konnte nicht verifiziert werden.' }
    Write-LinuxLog -Message "NOPASSWD für Updates wurde auf $RemoteHost eingerichtet und geprüft." -LogFile $LogFile -Level Success
}

function Invoke-LinuxUpdate {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile, [switch]$DryRun)
    $remoteScript = "/tmp/run_linux_update_$([guid]::NewGuid().ToString('N')).sh"
    $scriptContent = @'
#!/bin/sh
set -u
export DEBIAN_FRONTEND=noninteractive
CHECK_ONLY="${1:-0}"
UPDATE_COUNT=0
UPDATED_PACKAGES=""
wait_for_locks() {
    maximum=__LOCK_WAIT_INTERVALS__
    elapsed=0
    while [ "$elapsed" -lt "$maximum" ]; do
        if ! sudo -n fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; then return 0; fi
        echo "Paketverwaltung ist gesperrt; warte noch ..."
        sleep 30
        elapsed=$((elapsed + 1))
    done
    echo 'ERROR: Paketverwaltung bleibt gesperrt; kein automatischer Neustart.'
    return 1
}
if ! wait_for_locks; then echo 'UPDATE_COUNT=0'; exit 1; fi
if command -v apt-get >/dev/null 2>&1; then
    if [ "$CHECK_ONLY" = '1' ]; then
        echo 'Prüfe verfügbare APT-Updates (ohne Paketlisten-Aktualisierung) ...'
    else
        echo 'Aktualisiere APT-Paketlisten ...'
        sudo -n /usr/bin/apt-get update
    fi
    PLAN=$(sudo -n /usr/bin/apt-get -s upgrade) || exit 1
    UPDATE_COUNT=$(printf '%s\n' "$PLAN" | grep -c '^Inst ' || true)
    UPDATED_PACKAGES=$(printf '%s\n' "$PLAN" | awk '/^Inst / {print $2}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ "$CHECK_ONLY" = '1' ]; then
        if [ "$UPDATE_COUNT" -gt 0 ]; then echo "$UPDATE_COUNT APT-Update(s) verfügbar: $UPDATED_PACKAGES"; else echo 'Keine APT-Updates verfügbar.'; fi
    else
        if [ "$UPDATE_COUNT" -gt 0 ]; then echo "Installiere $UPDATE_COUNT APT-Update(s) ..."; sudo -n /usr/bin/apt-get upgrade -y; else echo 'Keine APT-Updates verfügbar.'; fi
        sudo -n /usr/bin/apt-get autoremove -y
        sudo -n /usr/bin/apt-get clean -y
        sudo -n /usr/bin/apt-get autoclean -y
    fi
elif command -v dnf >/dev/null 2>&1; then
    if [ "$CHECK_ONLY" = '1' ]; then
        echo 'Prüfe verfügbare DNF-Updates ...'
        PLAN=$(sudo -n /usr/bin/dnf -q check-update || test $? -eq 100) || exit 1
        UPDATED_PACKAGES=$(printf '%s\n' "$PLAN" | awk 'NF >= 2 && $1 !~ /^(Last|Obsoleting)/ {print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        UPDATE_COUNT=$(printf '%s\n' "$UPDATED_PACKAGES" | awk '{print NF}')
    else
        echo 'Installiere DNF-Updates ...'; sudo -n /usr/bin/dnf -y upgrade --refresh
    fi
elif command -v yum >/dev/null 2>&1; then
    if [ "$CHECK_ONLY" = '1' ]; then
        echo 'Prüfe verfügbare YUM-Updates ...'
        PLAN=$(sudo -n /usr/bin/yum -q check-update || test $? -eq 100) || exit 1
        UPDATED_PACKAGES=$(printf '%s\n' "$PLAN" | awk 'NF >= 2 && $1 !~ /^(Loaded|Obsoleting)/ {print $1}' | tr '\n' ' ' | sed 's/[[:space:]]*$//')
        UPDATE_COUNT=$(printf '%s\n' "$UPDATED_PACKAGES" | awk '{print NF}')
    else
        echo 'Installiere YUM-Updates ...'; sudo -n /usr/bin/yum -y update
    fi
else
    echo 'ERROR: Keine unterstützte Paketverwaltung gefunden.'; exit 1
fi
if [ -f /var/run/reboot-required ]; then echo 'REBOOT_REQUIRED=1'; fi
echo "UPDATE_COUNT=$UPDATE_COUNT"
if [ -n "$UPDATED_PACKAGES" ]; then echo "UPDATED_PACKAGES=$UPDATED_PACKAGES"; fi
if [ "$CHECK_ONLY" = '1' ]; then echo 'Linux-Update-Pruefung abgeschlossen.'; else echo 'Linux-Update abgeschlossen.'; fi
'@.Replace('__LOCK_WAIT_INTERVALS__',[string]$script:LockWaitIntervals)
    $localScript = Join-Path ([IO.Path]::GetTempPath()) ("run_linux_update_{0}.sh" -f [guid]::NewGuid().ToString('N'))
    try {
        [IO.File]::WriteAllText($localScript,($scriptContent -replace "`r`n","`n"),[Text.UTF8Encoding]::new($false))
        Write-LinuxLog -Message "Hochladen des Linux-Update-Skripts auf $RemoteHost ..." -LogFile $LogFile
        $scpArguments = @('-i',$KeyPath,'-o',"ConnectTimeout=$script:ConnectTimeoutSeconds",$localScript,"${RemoteUser}@${RemoteHost}:$remoteScript")
        & $script:SCPPath @scpArguments 2>&1 | ForEach-Object { if ($_){ Write-LinuxLog -Message ([string]$_) -LogFile $LogFile } }
        if ($LASTEXITCODE -ne 0) { throw 'Upload des Linux-Update-Skripts fehlgeschlagen.' }
        if ($DryRun) {
            Write-LinuxLog -Message "Dry-Run: Ermittle verfügbare Updates auf $RemoteHost (ohne Installation) ..." -LogFile $LogFile -Level Warning
        }
        else {
            Write-LinuxLog -Message "Führe Linux-Updates auf $RemoteHost aus (Ausgabe läuft mit) ..." -LogFile $LogFile
        }
        $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
        $checkOnlyArgument = if ($DryRun) { '1' } else { '0' }
        $arguments += "${RemoteUser}@${RemoteHost}", "sh $remoteScript $checkOnlyArgument; result=`$?; rm -f $remoteScript; exit `$result"
        $updateCount = 0; $updatedPackages = @(); $rebootRequired = $false
        & $script:SSHPath @arguments 2>&1 | ForEach-Object {
            $line = [string]$_
            if ([string]::IsNullOrWhiteSpace($line)) { return }
            if ($line -match '^UPDATE_COUNT=(\d+)$') { $updateCount = [int]$matches[1] }
            if ($line -match '^UPDATED_PACKAGES=(.+)$') { $updatedPackages = $matches[1] -split '\s+' | Where-Object { $_ } | Select-Object -Unique }
            if ($line -match '^REBOOT_REQUIRED=1$') { $rebootRequired = $true }
            if ($line -notmatch '^(UPDATE_COUNT=|UPDATED_PACKAGES=|REBOOT_REQUIRED=)') {
                Write-LinuxLog -Message $line -LogFile $LogFile
            }
        }
        if ($LASTEXITCODE -ne 0) { throw "Linux-Update auf $RemoteHost wurde mit Exit-Code $LASTEXITCODE beendet." }
        return [PSCustomObject]@{ Success=$true; UpdateCount=$updateCount; UpdatedPackages=$updatedPackages; RebootRequired=$rebootRequired }
    }
    finally { Remove-Item -LiteralPath $localScript -Force -ErrorAction SilentlyContinue }
}

if (-not (Test-Path -LiteralPath $script:SSHPath)) { throw "OpenSSH-Client (ssh.exe) nicht gefunden: $script:SSHPath" }
if (-not (Test-Path -LiteralPath $script:SCPPath)) { throw "OpenSSH-Kopierprogramm (scp.exe) nicht gefunden: $script:SCPPath" }
if ($CheckOnly) { $DryRun = $true }
# CheckOnly unterbindet ausschließlich Paketinstallation und Neustart. Die
# Ersteinrichtung (lokaler Schlüssel, Schlüssel-Login, NOPASSWD) muss bei jedem
# ersten Aufruf erfolgen können, auch wenn dieser von Check oder Download kommt.
Ensure-LinuxSSHKey -KeyPath $KeyPath
if ($script:WriteExecutionLog -and -not (Test-Path -LiteralPath $script:LogDirectory)) { New-Item -Path $script:LogDirectory -ItemType Directory -Force | Out-Null }
$hostEntries = @(
    foreach ($entry in @($linuxSettings.Hosts)) {
        if ($null -eq $entry) { continue }
        if ($entry -is [string]) {
            if (-not [string]::IsNullOrWhiteSpace($entry)) { $entry }
            continue
        }
        $properties = $entry.PSObject.Properties
        $hostValue = if ($properties['Host']) { [string]$properties['Host'].Value } elseif ($properties['Name']) { [string]$properties['Name'].Value } else { '' }
        $userValue = if ($properties['User']) { [string]$properties['User'].Value } else { '' }
        # Leere JSON-Platzhalter ({}) ignorieren; unvollständige echte Einträge
        # werden unten weiterhin mit einer aussagekräftigen Warnung gemeldet.
        if (-not [string]::IsNullOrWhiteSpace($hostValue) -or -not [string]::IsNullOrWhiteSpace($userValue)) { $entry }
    }
)
$hostStatus = @(); $updateDetails = @(); $totalUpdatesInstalled = 0; $vmRebootsScheduled = 0
if (@($hostEntries).Count -eq 0) { Write-Host 'Keine Linux-Hosts konfiguriert – Linux-Updates werden übersprungen.' -ForegroundColor Yellow }
foreach ($entry in $hostEntries) {
    $properties = $entry.PSObject.Properties
    $remoteHost = if ($properties['Host']) { [string]$properties['Host'].Value } elseif ($properties['Name']) { [string]$properties['Name'].Value } else { '' }
    $remoteUser = if ($properties['User']) { [string]$properties['User'].Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($remoteHost) -or [string]::IsNullOrWhiteSpace($remoteUser)) { Write-Warning 'Ungültiger Eintrag in LinuxSettings.Hosts (Host/Name und User sind Pflicht).'; continue }
    $logFile = if ($script:WriteExecutionLog) { Join-Path $script:LogDirectory ("{0}_{1}.log" -f $remoteHost,(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')) } else { '' }
    try {
        if (-not (Test-LinuxKeyLogin -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath)) {
            Install-LinuxPublicKey -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile
        } else {
            Write-LinuxLog -Message "SSH-Schlüssel-Login für $remoteHost funktioniert bereits." -LogFile $logFile -Level Success
        }
        Set-LinuxUpdateSudo -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile
        $result = Invoke-LinuxUpdate -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile -DryRun:$DryRun
        $totalUpdatesInstalled += $result.UpdateCount
        $isVirtual = $false; $rebootScheduled = $false
        if (-not $DryRun -and $result.RebootRequired) {
            $isVirtual = Test-LinuxHostIsVirtual -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath
            $rebootScheduled = Register-LinuxReboot -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -IsVirtual $isVirtual -LogFile $logFile
            if ($rebootScheduled -and $isVirtual) { $vmRebootsScheduled++ }
        }
        if ($result.UpdateCount -gt 0) { $updateDetails += [PSCustomObject]@{ Host=$remoteHost; UpdateCount=$result.UpdateCount; Packages=$result.UpdatedPackages } }
        $statusText = if ($result.RebootRequired) { 'Erfolgreich (Neustart erforderlich)' } else { 'Erfolgreich' }
        $hostStatus += [PSCustomObject]@{ Host=$remoteHost; Status=$statusText; UpdateCount=$result.UpdateCount; Packages=($result.UpdatedPackages -join ', '); IsVirtual=$isVirtual; RebootScheduled=$rebootScheduled; LogFile=$logFile }
        $completionText = if ($DryRun) {
            "Linux-Update-Prüfung auf $remoteHost abgeschlossen: $($result.UpdateCount) Update(s) verfügbar."
        }
        else {
            "Linux-Update auf $remoteHost abgeschlossen: $($result.UpdateCount) Update(s) installiert."
        }
        Write-LinuxLog -Message $completionText -LogFile $logFile -Level Success
    } catch {
        $hostStatus += [PSCustomObject]@{ Host=$remoteHost; Status='Fehler'; UpdateCount=0; Packages=''; LogFile=$logFile }
        Write-LinuxLog -Message "Fehler bei ${remoteHost}: $($_.Exception.Message)" -LogFile $logFile -Level Error
    } finally {
        Invoke-LinuxLogRetention -RemoteHost $remoteHost
    }
}
$linuxStats = [PSCustomObject]@{ TotalHosts=@($hostEntries).Count; HostsProcessed=@($hostStatus | Where-Object { $_.Status -ne 'Fehler' }).Count; UpdatesInstalled=$totalUpdatesInstalled; FailedHosts=@($hostStatus | Where-Object { $_.Status -eq 'Fehler' }).Count; VMRebootsScheduled=$vmRebootsScheduled; UpdateDetails=@($updateDetails); HostStatus=@($hostStatus) }
$statsFile = Join-Path $PSScriptRoot $(if ($CheckOnly) { 'linux_update_check_stats.json' } else { 'linux_update_stats.json' })
$linuxStats | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statsFile -Encoding utf8
$summaryVerb = if ($DryRun) { 'verfügbar' } else { 'installiert' }
$summaryLabel = if ($CheckOnly) { 'Linux-Check' } else { 'Linux-Zusammenfassung' }
Write-Host "${summaryLabel}: $($linuxStats.HostsProcessed)/$($linuxStats.TotalHosts) erfolgreich, $totalUpdatesInstalled Update(s) $summaryVerb, $($linuxStats.FailedHosts) Fehler." -ForegroundColor Cyan
