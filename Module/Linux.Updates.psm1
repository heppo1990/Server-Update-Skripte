Set-StrictMode -Version Latest

function Invoke-LinuxServerUpdates {
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$CheckOnly,
    [switch]$ConnectionOnly,
    [switch]$Quiet,
    [switch]$DeferPhysicalReboots,
    [string]$KeyPath,
    [string]$SSHPath,
    [ValidateRange(0, 1000)][int]$VMRebootIndexStart = 0
)

    $repositoryRoot = Split-Path -Parent $PSScriptRoot

Set-StrictMode -Version Latest

$commonModulePath = Join-Path $repositoryRoot 'Module\WindowsUpdate.Common.psm1'
Import-Module -Name $commonModulePath -Force -ErrorAction Stop

$settings = Get-WindowsUpdateSettings -ScriptRoot $repositoryRoot -ScriptName ([IO.Path]::GetFileNameWithoutExtension('Install-Linux Updates.ps1'))
$linuxSettings = if ($settings.PSObject.Properties['LinuxSettings']) { $settings.LinuxSettings } else { $null }
if ($null -eq $linuxSettings -or -not $linuxSettings.PSObject.Properties['Hosts'] -or @($linuxSettings.Hosts | Where-Object { $_ }).Count -eq 0) {
    return
}
$configuredKeyPath = if ($linuxSettings.PSObject.Properties['KeyPath']) { [string]$linuxSettings.KeyPath } else { '' }
$configuredSSHPath = if ($linuxSettings.PSObject.Properties['SSHPath']) { [string]$linuxSettings.SSHPath } else { '' }

if (-not $PSBoundParameters.ContainsKey('KeyPath') -or [string]::IsNullOrWhiteSpace($KeyPath)) {
    $KeyPath = if ([string]::IsNullOrWhiteSpace($configuredKeyPath)) { Join-Path $env:USERPROFILE '.ssh\id_rsa_linux' } else { $configuredKeyPath }
}
if (-not $PSBoundParameters.ContainsKey('SSHPath')) {
    $SSHPath = if ([string]::IsNullOrWhiteSpace($configuredSSHPath)) {
        $sshCommand = Get-Command -Name 'ssh.exe', 'ssh' -ErrorAction SilentlyContinue | Select-Object -First 1
        if ($sshCommand) { $sshCommand.Path } else { Join-Path $env:SystemRoot 'System32\OpenSSH\ssh.exe' }
    } else { $configuredSSHPath }
}

$script:SSHPath = $SSHPath
$script:QuietMode = $Quiet
$scpCommand = Get-Command -Name 'scp.exe', 'scp' -ErrorAction SilentlyContinue | Select-Object -First 1
$script:SCPPath = if ($scpCommand) { $scpCommand.Path } else { Join-Path (Split-Path -Path $script:SSHPath -Parent) 'scp.exe' }
$script:ConnectTimeoutSeconds = if ([int]$linuxSettings.ConnectTimeoutSeconds -gt 0) { [int]$linuxSettings.ConnectTimeoutSeconds } else { 15 }
$script:LinuxSudoSetupVersion = '1'
$script:LockWaitIntervals = if ([int]$linuxSettings.LockWaitMinutes -gt 0) { [int]$linuxSettings.LockWaitMinutes * 2 } else { 10 }
$script:LogDirectory = Join-Path $repositoryRoot 'Logs'
$script:WriteExecutionLog = $null -ne $settings.UpdateSettings -and
    $settings.UpdateSettings.PSObject.Properties['WriteLogFile'] -and
    [bool]$settings.UpdateSettings.WriteLogFile
$script:VMRebootIndex = $VMRebootIndexStart
$script:PendingPhysicalReboots = [System.Collections.Generic.List[object]]::new()

function Write-LinuxLog {
    param([Parameter(Mandatory)][AllowEmptyString()][string]$Message, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile, [ValidateSet('Info','Success','Warning','Error')][string]$Level = 'Info', [switch]$ConsoleWhenQuiet)
    $color = @{ Info='White'; Success='Green'; Warning='Yellow'; Error='Red' }[$Level]
    # Detailmeldungen bleiben im Protokoll; die Konsole zeigt nur wichtige Statuszeilen.
    if ((-not $script:QuietMode -or $ConsoleWhenQuiet) -and $Message -notmatch '^\[DIAG\]') { Write-WindowsUpdateConsoleLine -Message $Message -ForegroundColor $color }
    if ($script:WriteExecutionLog) {
        [IO.File]::AppendAllText($LogFile, $Message + [Environment]::NewLine, [Text.UTF8Encoding]::new($false))
    }
}

function Invoke-LinuxLogRetention {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile)
    if (-not $script:WriteExecutionLog) { return }
    $keepLogFiles = if ($settings.UpdateSettings.PSObject.Properties['KeepLogFiles']) { [int]$settings.UpdateSettings.KeepLogFiles } else { 5 }
    $retention = Invoke-WindowsUpdateFileRetention -Directory $script:LogDirectory -Filter ("{0}_*.log" -f $RemoteHost) -KeepFiles $keepLogFiles
    foreach ($removedFile in @($retention.RemovedFiles)) {
        if (-not $script:QuietMode) { Write-Host "Bereinige altes Linux-Log: $removedFile" -ForegroundColor DarkGray }
    }
    foreach ($failedFile in @($retention.FailedFiles)) {
        Write-LinuxLog -Message 'WARNUNG: Eine alte Linux-Protokolldatei konnte nicht entfernt werden; Details im Laufprotokoll.' -LogFile $LogFile -Level Warning
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Linux-Logdatei entfernen' -Target ([string]$failedFile.Path) -DiagnosticText ([string]$failedFile.Diagnostic)
    }
    if ($retention.EnumerationError) {
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Linux-Logdateien auflisten' -Target $script:LogDirectory -DiagnosticText ([string]$retention.EnumerationError)
    }
}

function Get-LinuxSshArguments {
    param([Parameter(Mandatory)][string]$KeyPath, [switch]$BatchMode, [switch]$AcceptNewHostKey)
    return Get-WindowsUpdateSshArguments -KeyPath $KeyPath -ConnectTimeoutSeconds $script:ConnectTimeoutSeconds -BatchMode:$BatchMode -AcceptNewHostKey:$AcceptNewHostKey
}

function Get-NextLinuxScheduledTime {
    param([Parameter(Mandatory)][string]$Time, [string]$LatestTime = '', [int]$DelayMinutes = 0, [switch]$PreferImmediate)
    if ($PreferImmediate) {
        # VMRebootImmediately übersteuert Startzeit und Wartungsfenster. Die
        # Sicherheitsminute und der konfigurierte Abstand zwischen VMs bleiben.
        return (Get-Date).AddMinutes(1 + $DelayMinutes)
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

function Test-LinuxHostIsVirtual {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile)
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", 'systemd-detect-virt --vm 2>/dev/null; result=$?; if [ "$result" -eq 1 ]; then exit 0; fi; exit "$result"'
    $output = & $script:SSHPath @arguments 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Linux-Virtualisierung vor Neustart bestimmen' -Target $RemoteHost -DiagnosticText ($output -join [Environment]::NewLine) -Context @("User=$RemoteUser", "SSHPath=$script:SSHPath", "ExitCode=$exitCode")
        throw "Virtualisierungstyp auf $RemoteHost konnte nicht sicher bestimmt werden (SSH-Exitcode $exitCode)."
    }
    $virtualizationType = ($output -join '').Trim()
    $isVirtual = -not [string]::IsNullOrWhiteSpace($virtualizationType)
    $decision = if ($isVirtual) { "Linux-Host $RemoteHost als virtuelle Maschine erkannt ($virtualizationType)." } else { "Linux-Host $RemoteHost als physischer Computer erkannt." }
    Write-LinuxLog -Message $decision -LogFile $LogFile
    return $isVirtual
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
    $interval = [Math]::Max(0, [int]$settings.UpdateSettings.VMRebootIntervalMinutes)
    $vmOffset = if ($IsVirtual) { $script:VMRebootIndex * $interval } else { 0 }
    $scheduled = $null
    if ($IsVirtual -and $vmImmediately) {
        $scheduled = if (-not [string]::IsNullOrWhiteSpace($vmStartTime)) { Get-NextLinuxScheduledTime $vmStartTime ([string]$settings.UpdateSettings.VMRebootWindowEndTime) $vmOffset -PreferImmediate } else { (Get-Date).AddMinutes(1 + $vmOffset) }
        $script:VMRebootIndex++
    }
    elseif ($IsVirtual -and -not [string]::IsNullOrWhiteSpace($vmStartTime)) { $scheduled = Get-NextLinuxScheduledTime $vmStartTime ([string]$settings.UpdateSettings.VMRebootWindowEndTime) $vmOffset; $script:VMRebootIndex++ }
    elseif (-not $IsVirtual -and -not [string]::IsNullOrWhiteSpace($physicalTime)) {
        if ($DeferPhysicalReboots) {
            $script:PendingPhysicalReboots.Add([PSCustomObject]@{
                Host = $RemoteHost; User = $RemoteUser; KeyPath = $KeyPath; SSHPath = $script:SSHPath
                RebootTime = $physicalTime; LatestRebootTime = [string]$settings.UpdateSettings.PhysicalRebootWindowEndTime
            })
            Write-LinuxLog -Message "Physischer Neustart auf $RemoteHost wird bis nach dem gemeinsamen VM-Neustartblock zurückgestellt." -LogFile $LogFile -Level Warning
            return $true
        }
        $scheduled = Get-NextLinuxScheduledTime $physicalTime ([string]$settings.UpdateSettings.PhysicalRebootWindowEndTime)
    }
    if ($null -eq $scheduled) { Write-LinuxLog -Message "Kein automatischer Neustart für $RemoteHost konfiguriert." -LogFile $LogFile; return $false }
    $delayMinutes = [Math]::Max(1, [int][Math]::Ceiling(($scheduled - (Get-Date)).TotalMinutes))
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", "sudo -n /usr/local/sbin/windowsupdateadm-schedule-reboot $delayMinutes"
    & $script:SSHPath @arguments 2>&1 | ForEach-Object { if ($_){ Write-LinuxLog -Message ([string]$_) -LogFile $LogFile } }
    if ($LASTEXITCODE -ne 0) { throw "Linux-Neustart auf $RemoteHost konnte nicht geplant werden." }
    Write-LinuxLog -Message "Neustart auf $RemoteHost geplant: $($scheduled.ToString('dd.MM.yyyy HH:mm'))" -LogFile $LogFile -Level Warning
    return $true
}

function Ensure-LinuxSSHKey {
    param([Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile)
    $keyDirectory = Split-Path $KeyPath -Parent
    if (-not (Test-Path -LiteralPath $keyDirectory)) { New-Item -Path $keyDirectory -ItemType Directory -Force | Out-Null }
    $keygen = Get-Command -Name 'ssh-keygen.exe','ssh-keygen' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $keygen) { throw 'OpenSSH-Keygen (ssh-keygen) wurde nicht gefunden.' }
    if (-not (Test-Path -LiteralPath $KeyPath)) {
        $keygenOutput = @(& $keygen.Path -t ed25519 -f $KeyPath -N '' 2>&1)
        $keygenExitCode = $LASTEXITCODE
        if ($keygenExitCode -ne 0) {
            $safeOutput = ($keygenOutput -join [Environment]::NewLine) -replace '(?m)^\s*(ssh-(?:rsa|ed25519)|ecdsa-sha2-\S+)\s+\S+.*$', '[öffentlicher Schlüssel ausgelassen]'
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Lokalen Linux-SSH-Schlüssel erstellen' -Target $KeyPath -DiagnosticText $safeOutput -Context "ssh-keygen=$($keygen.Path); ExitCode=$keygenExitCode"
            throw "SSH-Schlüssel konnte nicht erstellt werden (Exitcode $keygenExitCode); Details stehen im Linux-Protokoll."
        }
        if (-not $script:QuietMode) { Write-Host "Neuer ED25519-SSH-Schlüssel erstellt: $KeyPath" -ForegroundColor Green }
    }
    if (-not (Test-Path -LiteralPath "$KeyPath.pub")) {
        $publicKeyOutput = @(& $keygen.Path -y -P '' -f $KeyPath 2>&1)
        $keygenExitCode = $LASTEXITCODE
        if ($keygenExitCode -ne 0) {
            $safeOutput = ($publicKeyOutput -join [Environment]::NewLine) -replace '(?m)^\s*(ssh-(?:rsa|ed25519)|ecdsa-sha2-\S+)\s+\S+.*$', '[öffentlicher Schlüssel ausgelassen]'
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Öffentlichen Linux-SSH-Schlüssel ableiten' -Target $KeyPath -DiagnosticText $safeOutput -Context "ssh-keygen=$($keygen.Path); ExitCode=$keygenExitCode"
            throw "Öffentlicher SSH-Schlüssel konnte nicht erstellt werden (Exitcode $keygenExitCode); Details stehen im Linux-Protokoll."
        }
        $publicKey = ($publicKeyOutput | ForEach-Object { [string]$_ } | Where-Object { $_ -match '^\s*(ssh-(?:rsa|ed25519)|ecdsa-sha2-\S+)\s+\S+' } | Select-Object -First 1)
        if ([string]::IsNullOrWhiteSpace($publicKey)) { throw "ssh-keygen lieferte keinen gültigen öffentlichen Schlüssel für $KeyPath." }
        Set-Content -LiteralPath "$KeyPath.pub" -Value $publicKey.Trim() -Encoding utf8 -ErrorAction Stop
    }
}

function Test-LinuxKeyLogin {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [AllowEmptyString()][string]$LogFile = '')
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $arguments += "${RemoteUser}@${RemoteHost}", 'printf OK'
    $result = & $script:SSHPath @arguments 2>&1
    $exitCode = $LASTEXITCODE
    $success = ($exitCode -eq 0 -and (($result -join "`n") -match '(?m)^OK\s*$'))
    if (-not $success -and $LogFile) {
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Linux-SSH-Schlüsselverbindung prüfen' -Target $RemoteHost -DiagnosticText ($result -join [Environment]::NewLine) -Context @("User=$RemoteUser", "SSHPath=$script:SSHPath", "ExitCode=$exitCode")
    }
    return $success
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
    $installExitCode = $LASTEXITCODE
    if ($installExitCode -ne 0) {
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Linux-SSH-Schlüssel installieren' -Target $RemoteHost -Context @("User=$RemoteUser", "SSHPath=$script:SSHPath", 'Authentication=interaktiv', "ExitCode=$installExitCode")
        throw "SSH-Schlüsselinstallation auf $RemoteHost fehlgeschlagen (Exitcode $installExitCode)."
    }
    if (-not (Test-LinuxKeyLogin -RemoteHost $RemoteHost -RemoteUser $RemoteUser -KeyPath $KeyPath -LogFile $LogFile)) { throw "SSH-Schlüssel konnte auf $RemoteHost nicht geprüft werden." }
    Write-LinuxLog -Message "SSH-Schlüssel-Login für $RemoteHost ist eingerichtet." -LogFile $LogFile -Level Success
}

function Test-LinuxUpdateSudo {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [AllowEmptyString()][string]$LogFile = '')
    $arguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
    $remoteCommand = 'version=$(sudo -n /usr/local/sbin/windowsupdateadm-schedule-reboot --version) || { echo "SUDO_VERSION_CHECK_FAILED"; exit 41; }; [ "$version" = "' + $script:LinuxSudoSetupVersion + '" ] || { echo "SUDO_VERSION_MISMATCH:$version"; exit 42; }; sudo -n /usr/local/sbin/windowsupdateadm-schedule-reboot --check'
    $arguments += "${RemoteUser}@${RemoteHost}", $remoteCommand
    $result = @(& $script:SSHPath @arguments 2>&1)
    $exitCode = $LASTEXITCODE
    $success = ($exitCode -eq 0)
    if (-not $success -and $LogFile) {
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Linux-NOPASSWD-Updateeinrichtung prüfen' -Target $RemoteHost -DiagnosticText ($result -join [Environment]::NewLine) -Context @("User=$RemoteUser", "SSHPath=$script:SSHPath", "ExpectedVersion=$script:LinuxSudoSetupVersion", "ExitCode=$exitCode")
    }
    return $success
}

function Set-LinuxUpdateSudo {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile)
    if (Test-LinuxUpdateSudo -RemoteHost $RemoteHost -RemoteUser $RemoteUser -KeyPath $KeyPath -LogFile $LogFile) {
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
$RemoteUser ALL=(ALL) NOPASSWD: /usr/local/sbin/windowsupdateadm-schedule-reboot
"@
    $encodedSudoers = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($sudoersContent))
    $rebootHelperContent = @'
#!/bin/sh
set -eu
if [ "$#" -eq 1 ] && [ "$1" = "--check" ]; then
    exit 0
fi
if [ "$#" -eq 1 ] && [ "$1" = "--version" ]; then
    printf '%s\n' '__SETUP_VERSION__'
    exit 0
fi
if [ "$#" -ne 1 ]; then
    echo 'Expected exactly one delay in minutes.' >&2
    exit 2
fi
case "$1" in
    ''|*[!0-9]*) echo 'Delay must be a positive integer.' >&2; exit 2 ;;
esac
if [ "$1" -lt 1 ] || [ "$1" -gt 10080 ]; then
    echo 'Delay must be between 1 and 10080 minutes.' >&2
    exit 2
fi
if [ -x /usr/sbin/shutdown ]; then
    exec /usr/sbin/shutdown -r "+$1"
fi
exec /sbin/shutdown -r "+$1"
'@
    $rebootHelperContent = $rebootHelperContent.Replace('__SETUP_VERSION__', $script:LinuxSudoSetupVersion)
    $encodedRebootHelper = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($rebootHelperContent))
    $remoteScript = "/tmp/configure_update_sudo_${safeUser}.sh"
    $bootstrapScript = @'
#!/bin/sh
set -eu
# Das kurzlebige Setup-Skript entfernt sich auch bei einem abgebrochenen SSH-Aufruf.
trap 'rm -f "$0"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
sudo -S -p '' /bin/sh -c 'printf %s "$1" | base64 -d > "$2" && printf %s "$3" | base64 -d > "$4" && chmod 755 "$4" && chown root:root "$4" && chmod 440 "$2" && chown root:root "$2" && visudo -c -f "$2" >/dev/null' -- '__SUDOERS_B64__' '__SUDOERS_PATH__' '__REBOOT_HELPER_B64__' '/usr/local/sbin/windowsupdateadm-schedule-reboot'
echo SUDOERS_CONFIGURED
'@.Replace('__SUDOERS_B64__',$encodedSudoers).Replace('__SUDOERS_PATH__',$remoteSudoers).Replace('__REBOOT_HELPER_B64__',$encodedRebootHelper)
    $localScript = Join-Path ([IO.Path]::GetTempPath()) ("configure_update_sudo_{0}_{1}.sh" -f $safeUser,[guid]::NewGuid().ToString('N'))
    $localPassword = Join-Path ([IO.Path]::GetTempPath()) ("sudo_password_{0}_{1}.txt" -f $safeUser,[guid]::NewGuid().ToString('N'))
    $stdoutFile = $null; $stderrFile = $null; $credentialCleanupFailed = $false
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
        foreach ($temporaryFile in @($localPassword, $localScript, $stdoutFile, $stderrFile)) {
            if ([string]::IsNullOrWhiteSpace([string]$temporaryFile) -or -not (Test-Path -LiteralPath $temporaryFile -PathType Leaf)) { continue }
            try { Remove-Item -LiteralPath $temporaryFile -Force -ErrorAction Stop }
            catch {
                $isCredentialFile = $temporaryFile -eq $localPassword
                $operation = if ($isCredentialFile) { 'Lokale temporäre Passwortdatei entfernen' } else { 'Temporäre Linux-Setupdatei entfernen' }
                Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation $operation -Target $temporaryFile -ErrorRecord $_ -Context "RemoteHost=$RemoteHost; Kennwortinhalt wird nicht protokolliert; Passwortdatei=$isCredentialFile"
                if ($isCredentialFile) { $credentialCleanupFailed = $true }
            }
        }
        try {
            $cleanupArguments = Get-LinuxSshArguments -KeyPath $KeyPath -BatchMode
            $cleanupArguments += "${RemoteUser}@${RemoteHost}", "rm -f $remoteScript"
            $cleanupOutput = @(& $script:SSHPath @cleanupArguments 2>&1)
            $cleanupExitCode = $LASTEXITCODE
            if ($cleanupExitCode -ne 0) {
                Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Temporäres Linux-Setupskript entfernen' -Target $RemoteHost -DiagnosticText ($cleanupOutput -join [Environment]::NewLine) -Context "User=$RemoteUser; SSHPath=$script:SSHPath; ExitCode=$cleanupExitCode; RemotePath=$remoteScript"
            }
        }
        catch {
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Temporäres Linux-Setupskript entfernen' -Target $RemoteHost -ErrorRecord $_ -Context "User=$RemoteUser; RemotePath=$remoteScript"
        }
        if ($credentialCleanupFailed) { throw 'Temporäre sudo-Passwortdatei konnte nicht entfernt werden; Details stehen im Linux-Protokoll.' }
    }
    if (-not (Test-LinuxUpdateSudo -RemoteHost $RemoteHost -RemoteUser $RemoteUser -KeyPath $KeyPath -LogFile $LogFile)) { throw 'NOPASSWD konnte nicht verifiziert werden.' }
    Write-LinuxLog -Message "NOPASSWD für Updates wurde auf $RemoteHost eingerichtet und geprüft." -LogFile $LogFile -Level Success
}

function Invoke-LinuxUpdate {
    param([Parameter(Mandatory)][string]$RemoteHost, [Parameter(Mandatory)][string]$RemoteUser, [Parameter(Mandatory)][string]$KeyPath, [Parameter(Mandatory)][AllowEmptyString()][string]$LogFile, [switch]$DryRun)
    $remoteScript = "/tmp/run_linux_update_$([guid]::NewGuid().ToString('N')).sh"
    $scriptContent = @'
#!/bin/sh
set -u
# Das kurzlebige Update-Skript entfernt sich auch bei einem abgebrochenen SSH-Aufruf.
trap 'rm -f "$0"' EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
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
        $resultHeading = if ($DryRun) { "Ergebnis der Update-Suche auf Linux-Server ${RemoteHost}:" } else { "Ergebnis der Installation auf Linux-Server ${RemoteHost}:" }
        Write-LinuxLog -Message $resultHeading -LogFile $LogFile
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
    finally {
        try { Remove-Item -LiteralPath $localScript -Force -ErrorAction Stop }
        catch {
            Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $LogFile } -Operation 'Lokales Linux-Update-Temporärskript entfernen' -Target $RemoteHost -ErrorRecord $_ -Context "Pfad=$localScript"
            Write-LinuxLog -Message "WARNUNG: Temporäres Linux-Update-Skript konnte lokal nicht entfernt werden; Details stehen im Protokoll." -LogFile $LogFile -Level Warning
        }
    }
}

if (-not (Test-Path -LiteralPath $script:SSHPath)) { throw "OpenSSH-Client (ssh.exe) nicht gefunden: $script:SSHPath" }
if (-not (Test-Path -LiteralPath $script:SCPPath)) { throw "OpenSSH-Kopierprogramm (scp.exe) nicht gefunden: $script:SCPPath" }
if ($CheckOnly) { $DryRun = $true }
# Der Check ermittelt den Einrichtungsstatus nur lesend. Schlüssel und sudo-Regeln
# werden ausschließlich durch Download/Installation bzw. die Verteilung eingerichtet.
if (-not (Test-Path -LiteralPath $script:LogDirectory)) { New-Item -Path $script:LogDirectory -ItemType Directory -Force | Out-Null }
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
$hostStatus = @(); $updateDetails = @(); $totalUpdatesInstalled = 0; $vmRebootsScheduled = 0; $rebootScheduleFailures = 0
foreach ($entry in $hostEntries) {
    $properties = $entry.PSObject.Properties
    $remoteHost = if ($properties['Host']) { [string]$properties['Host'].Value } elseif ($properties['Name']) { [string]$properties['Name'].Value } else { '' }
    $remoteUser = if ($properties['User']) { [string]$properties['User'].Value } else { '' }
    if ([string]::IsNullOrWhiteSpace($remoteHost) -or [string]::IsNullOrWhiteSpace($remoteUser)) { Write-Warning 'Ungültiger Eintrag in LinuxSettings.Hosts (Host/Name und User sind Pflicht).'; continue }
    $logFile = if ($script:WriteExecutionLog) { Join-Path $script:LogDirectory ("{0}_{1}.log" -f $remoteHost,(Get-Date -Format 'yyyy-MM-dd_HH-mm-ss')) } else { '' }
    Write-LinuxLog -Message '' -LogFile $logFile
    $actionHeading = if ($CheckOnly -or $DryRun) { "Starte Update-Check auf Linux-Server $remoteHost..." } elseif ($ConnectionOnly) { "Prüfe Verbindung zu Linux-Server $remoteHost..." } else { "Starte Update-Installation auf Linux-Server $remoteHost..." }
    Write-LinuxLog -Message $actionHeading -LogFile $logFile -ConsoleWhenQuiet
    $setupIssue = ''
    try {
        if (-not $CheckOnly) { Ensure-LinuxSSHKey -KeyPath $KeyPath -LogFile $logFile }
        if ($CheckOnly) {
            if (-not (Test-Path -LiteralPath $KeyPath -PathType Leaf)) {
                $setupIssue = 'Lokaler SSH-Privatschlüssel fehlt; Linux-Verteilung erforderlich.'
                throw $setupIssue
            }
            Write-LinuxLog -Message "Prüfe SSH-Schlüsselverbindung zu Linux-Server $remoteHost ..." -LogFile $logFile -ConsoleWhenQuiet
            if (-not (Test-LinuxKeyLogin -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile)) {
                $setupIssue = 'SSH-Schlüsselverbindung nicht bestätigt; Linux-Verteilung und Verbindung prüfen.'
                throw $setupIssue
            }
            Write-LinuxLog -Message "Prüfe Updateberechtigung auf Linux-Server $remoteHost ..." -LogFile $logFile -ConsoleWhenQuiet
            if (-not (Test-LinuxUpdateSudo -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile)) {
                $setupIssue = "Linux-Updateeinrichtung fehlt oder ist veraltet (erwartete Version $script:LinuxSudoSetupVersion); Verteilung erforderlich."
                Write-LinuxLog -Message "$setupIssue Die lesende Update-Suche wird trotzdem versucht." -LogFile $logFile -Level Warning
            }
        } elseif (-not (Test-LinuxKeyLogin -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile)) {
            Install-LinuxPublicKey -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile
        } else {
            Write-LinuxLog -Message "SSH-Schlüssel-Login für $remoteHost funktioniert bereits." -LogFile $logFile -Level Success
        }
        if (-not $CheckOnly) { Set-LinuxUpdateSudo -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile }
        if ($ConnectionOnly) {
            $hostStatus += [PSCustomObject]@{ Host=$remoteHost; Status='Erfolgreich'; SetupReady=$true; SetupIssue=''; UpdateCount=0; Packages=''; PackageList=@(); LogFile=$logFile }
            Write-LinuxLog -Message "SSH-Schlüssel und Verbindung zu $remoteHost funktionieren." -LogFile $logFile -Level Success
            continue
        }
        $result = $null
        $rebootError = $null
        $isVirtual = $false; $rebootScheduled = $false
        if ($CheckOnly -or $DryRun) { Write-LinuxLog -Message "Frage verfügbare Linux-Paketupdates auf $remoteHost ab ..." -LogFile $logFile -ConsoleWhenQuiet }
        $result = Invoke-LinuxUpdate -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile -DryRun:$DryRun
        $totalUpdatesInstalled += $result.UpdateCount
        if (-not $DryRun -and $result.RebootRequired) {
            try {
                $isVirtual = Test-LinuxHostIsVirtual -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -LogFile $logFile
                $rebootScheduled = Register-LinuxReboot -RemoteHost $remoteHost -RemoteUser $remoteUser -KeyPath $KeyPath -IsVirtual $isVirtual -LogFile $logFile
            } catch {
                $rebootError = $_
                $rebootScheduleFailures++
                Write-LinuxLog -Message "WARNUNG: Updates auf $remoteHost wurden installiert, aber der erforderliche Neustart konnte nicht geplant werden. Manuelles Eingreifen erforderlich." -LogFile $logFile -Level Warning
                Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $logFile } -Operation 'Linux-Neustart planen' -Target $remoteHost -ErrorRecord $_
            }
            if ($rebootScheduled -and $isVirtual) { $vmRebootsScheduled++ }
        }
        if ($result.UpdateCount -gt 0) { $updateDetails += [PSCustomObject]@{ Host=$remoteHost; UpdateCount=$result.UpdateCount; Packages=$result.UpdatedPackages } }
        $statusText = if ($rebootError) { 'Updates installiert; Neustartplanung fehlgeschlagen' } elseif ($result.RebootRequired) { 'Erfolgreich (Neustart erforderlich)' } else { 'Erfolgreich' }
        $rebootErrorText = if ($rebootError) { 'Details im Laufprotokoll' } else { '' }
        $hostStatus += [PSCustomObject]@{ Host=$remoteHost; Status=$statusText; SetupReady=[string]::IsNullOrWhiteSpace($setupIssue); SetupIssue=$setupIssue; UpdateCount=$result.UpdateCount; Packages=($result.UpdatedPackages -join ', '); PackageList=@($result.UpdatedPackages); IsVirtual=$isVirtual; RebootScheduled=$rebootScheduled; RebootError=$rebootErrorText; LogFile=$logFile }
        $completionText = if ($DryRun) {
            "Linux-Update-Prüfung auf $remoteHost abgeschlossen: $($result.UpdateCount) Update(s) verfügbar."
        }
        else {
            "Linux-Update auf $remoteHost abgeschlossen: $($result.UpdateCount) Update(s) installiert."
        }
        if ($result.UpdateCount -gt 0) { Write-LinuxLog -Message $completionText -LogFile $logFile -Level Success }
    } catch {
        $hostStatus += [PSCustomObject]@{ Host=$remoteHost; Status='Fehler'; SetupReady=([string]::IsNullOrWhiteSpace($setupIssue)); SetupIssue=$setupIssue; UpdateCount=0; Packages=''; Error='Details im Laufprotokoll'; LogFile=$logFile }
        Write-LinuxLog -Message "Fehler bei ${remoteHost}; Details im Laufprotokoll." -LogFile $logFile -Level Error
        Write-WindowsUpdateDiagnostic -WriteLog { param($message) Write-LinuxLog -Message $message -LogFile $logFile } -Operation 'Linux-Host-Update' -Target $remoteHost -ErrorRecord $_
    } finally {
        Invoke-LinuxLogRetention -RemoteHost $remoteHost -LogFile $logFile
    }
}
$linuxStats = [PSCustomObject]@{ TotalHosts=@($hostEntries).Count; HostsProcessed=@($hostStatus | Where-Object { $_.Status -ne 'Fehler' }).Count; UpdatesInstalled=$totalUpdatesInstalled; FailedHosts=@($hostStatus | Where-Object { $_.Status -eq 'Fehler' }).Count; RebootScheduleFailedHosts=$rebootScheduleFailures; VMRebootsScheduled=$vmRebootsScheduled; PendingPhysicalReboots=@($script:PendingPhysicalReboots); UpdateDetails=@($updateDetails); HostStatus=@($hostStatus) }
$statsFile = Join-Path $script:LogDirectory $(if ($CheckOnly -or $ConnectionOnly) { 'linux_update_check_stats.json' } else { 'linux_update_stats.json' })
$linuxStats | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $statsFile -Encoding utf8
$summaryVerb = if ($DryRun) { 'verfügbar' } else { 'installiert' }
$summaryLabel = if ($CheckOnly) { 'Linux-Check' } else { 'Linux-Zusammenfassung' }
if (-not $script:QuietMode -and ($totalUpdatesInstalled -gt 0 -or $linuxStats.FailedHosts -gt 0 -or $rebootScheduleFailures -gt 0)) {
    $summaryText = "${summaryLabel}: $($linuxStats.HostsProcessed)/$($linuxStats.TotalHosts) erfolgreich, $totalUpdatesInstalled Update(s) $summaryVerb, $($linuxStats.FailedHosts) Fehler."
    if ($rebootScheduleFailures -gt 0) { $summaryText += " Neustartplanung auf $rebootScheduleFailures Host(s) fehlgeschlagen; manuelles Eingreifen erforderlich." }
    Write-Host $summaryText -ForegroundColor Cyan
}
}

Export-ModuleMember -Function 'Invoke-LinuxServerUpdates'
