param([Parameter(Mandatory)][ValidateSet('SourceList','SourceUpdate','SourceReset','ClientRepair')][string]$Action)
$ErrorActionPreference = 'Stop'
function Get-WinGetPath {
    $packages = @(Get-AppxPackage -AllUsers -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
        Where-Object { $_.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
        Sort-Object { [version]$_.Version } -Descending)
    if ($packages.Count -eq 0) {
        $packages = @(Get-AppxPackage -Name Microsoft.DesktopAppInstaller -ErrorAction Stop |
            Where-Object { $_.Status -eq 'Ok' -and -not [string]::IsNullOrWhiteSpace([string]$_.InstallLocation) } |
            Sort-Object { [version]$_.Version } -Descending)
    }
    if ($packages.Count -eq 0) { throw 'App Installer/WinGet ist für den JEA-Kontext nicht registriert.' }
    $path = Join-Path ([string]$packages[0].InstallLocation) 'winget.exe'
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'winget.exe fehlt im App-Installer-Paket.' }
    return $path
}
function Invoke-WinGet {
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string[]]$Arguments)
    $quoted = foreach ($item in $Arguments) { if ($item -match '[\s"]') { '"' + $item.Replace('"','\"') + '"' } else { $item } }
    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $Path; $start.Arguments = $quoted -join ' '; $start.UseShellExecute = $false
    $start.CreateNoWindow = $true; $start.WindowStyle = [Diagnostics.ProcessWindowStyle]::Hidden
    $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
    $process = [Diagnostics.Process]::new()
    try {
        $process.StartInfo = $start
        if (-not $process.Start()) { throw 'winget.exe konnte nicht gestartet werden.' }
        $stdout = $process.StandardOutput.ReadToEndAsync(); $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(300000)) { try { $process.Kill() } catch {}; throw 'WinGet-Aktion überschritt fünf Minuten.' }
        $process.WaitForExit()
        $text = @($stdout.GetAwaiter().GetResult(), $stderr.GetAwaiter().GetResult()) | Where-Object { -not [string]::IsNullOrWhiteSpace([string]$_) }
        [pscustomobject]@{ ExitCode = [int]$process.ExitCode; Output = ($text -join [Environment]::NewLine).Trim() }
    } finally { $process.Dispose() }
}
if ($Action -eq 'ClientRepair') {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('winget-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/asheroto/winget-install/releases/latest' -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $assets = @($release.assets | Where-Object { $_.name -eq 'winget-install.ps1' })
        if ($assets.Count -ne 1) { throw 'GitHub-Release enthält kein eindeutiges winget-install.ps1.' }
        $asset = $assets[0]
        if ([string]$asset.digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'GitHub-Release enthält keinen SHA256-Digest.' }
        $releaseHash = $Matches[1]
        $downloadUri = [uri]$asset.browser_download_url
        if ($downloadUri.Scheme -ne 'https' -or $downloadUri.Host -ne 'github.com' -or $downloadUri.AbsolutePath -notlike '/asheroto/winget-install/releases/download/*/winget-install.ps1') { throw 'Unerwartete Release-Downloadadresse.' }
        Invoke-WebRequest -Uri $downloadUri.AbsoluteUri -OutFile $temp -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        $sig = Get-AuthenticodeSignature -FilePath $temp -ErrorAction Stop

        $hashMatches = (Get-FileHash -LiteralPath $temp -Algorithm SHA256 -ErrorAction Stop).Hash -eq $releaseHash
        if (-not $hashMatches -or $sig.Status -notin @([Management.Automation.SignatureStatus]::Valid, [Management.Automation.SignatureStatus]::NotSigned)) {
            throw "WinGet-Reparaturskript ist weder gültig signiert noch die per Online-Digest bestätigte Release-Datei."
        }
        $ps51 = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $installerResult = Invoke-WinGet -Path $ps51 -Arguments @('-NoLogo','-NoProfile','-NonInteractive','-ExecutionPolicy','Bypass','-File',$temp,'-Force')
        $out = $installerResult.Output
        $code = $installerResult.ExitCode
        if ($code -ne 0) { throw "winget-install.ps1 -Force endete mit Exitcode $code. $out" }
        $version = (& (Get-WinGetPath) --version 2>&1 | Out-String).Trim()
        if ($LASTEXITCODE -ne 0 -or $version -notmatch '(?m)^\s*v?\d+\.\d+') { throw "WinGet besteht den Starttest nach der Client-Reparatur nicht: $version" }
        [pscustomobject]@{ Action=$Action; Success=$true; ExitCode=0; Output="Geprüfte winget-install.ps1 ausgeführt; WinGet $version. $out" }
        exit 0
    } catch {
        $primaryError = $_.Exception.ToString() + [Environment]::NewLine + $_.InvocationInfo.PositionMessage + [Environment]::NewLine + $_.ScriptStackTrace
        try {
            Import-Module Microsoft.WinGet.Client -ErrorAction Stop
            $repairParameters = @{ Latest=$true; Force=$true; ErrorAction='Stop' }
            # Microsofts Reparatur unterstützt AllUsers nicht unter SYSTEM.
            if ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value -ne 'S-1-5-18') {
                $repairParameters.AllUsers = $true
            }
            $repairOutput = Repair-WinGetPackageManager @repairParameters | Out-String
            $probe = Invoke-WinGet -Path (Get-WinGetPath) -Arguments @('--version')
            if ($probe.ExitCode -ne 0 -or $probe.Output -notmatch '(?m)^\s*v?\d+\.\d+') {
                throw "WinGet-Starttest nach Microsoft-Reparatur fehlgeschlagen: $($probe.Output)"
            }
            [pscustomobject]@{
                Action=$Action; Success=$true; ExitCode=0
                Output="winget-install-Reparatur fehlgeschlagen: $primaryError; Microsoft-Fallback Repair-WinGetPackageManager -Latest -Force erfolgreich. WinGet: $($probe.Output). $repairOutput"
            }
            exit 0
        } catch {
            $fallbackError = $_.Exception.ToString() + [Environment]::NewLine + $_.InvocationInfo.PositionMessage + [Environment]::NewLine + $_.ScriptStackTrace
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            $diagnostic = @(
                'Beide WinGet-Reparaturwege fehlgeschlagen.'
                ('Kontext: Benutzer={0}; SID={1}; PowerShell={2}; Computer={3}' -f $identity.Name, $identity.User.Value, $PSVersionTable.PSVersion, $env:COMPUTERNAME)
                '=== winget-install ==='
                $primaryError
                '=== Microsoft-Fallback ==='
                $fallbackError
            ) -join [Environment]::NewLine
            # stdout statt formatierter PowerShell-Fehler: verhindert Abbruch beim ersten stderr-Datensatz.
            [Console]::Out.WriteLine($diagnostic)
            exit 1
        }
    } finally { Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue }
}
$winget = Get-WinGetPath
$args = switch ($Action) {
    'SourceList' { @('source','list','--disable-interactivity') }
    'SourceUpdate' { @('source','update','--disable-interactivity') }
    'SourceReset' {
        $list = Invoke-WinGet -Path $winget -Arguments @('source','list','--disable-interactivity')
        if ($list.ExitCode -ne 0) { throw "WinGet-Quellenliste fehlgeschlagen: $($list.Output)" }
        $names = @($list.Output -split "`r?`n" | ForEach-Object { if ($_ -match '^\s*(?<Name>[^\s]+)\s+\S+\s+(?:true|false)\s*$') { $Matches.Name } })
        $custom = @($names | Where-Object { $_ -notin @('winget','msstore','winget-font') } | Select-Object -Unique)
        if ($custom.Count -gt 0) { throw "Quellenreset zum Schutz kundeneigener Quelle(n) ausgelassen: $($custom -join ', ')" }
        $reset = Invoke-WinGet -Path $winget -Arguments @('source','reset','--force')
        if ($reset.ExitCode -ne 0) { throw "WinGet-Quellenreset fehlgeschlagen: $($reset.Output)" }
        $refresh = Invoke-WinGet -Path $winget -Arguments @('source','update','--name','winget','--disable-interactivity')
        if ($refresh.ExitCode -ne 0) { throw "WinGet-Quellenaktualisierung nach Reset fehlgeschlagen: $($refresh.Output)" }
        [pscustomobject]@{ Action=$Action; Success=$true; ExitCode=0; Output=($reset.Output + [Environment]::NewLine + $refresh.Output).Trim() }
        exit 0
    }
}
$result = Invoke-WinGet -Path $winget -Arguments $args
[pscustomobject]@{ Action=$Action; Success=($result.ExitCode -eq 0); ExitCode=$result.ExitCode; Output=$result.Output }
exit $result.ExitCode
