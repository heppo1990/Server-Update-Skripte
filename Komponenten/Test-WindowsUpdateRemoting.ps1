[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$ComputerName,
    [switch]$UseClientCertificate,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$')][string]$ProbePackageId
)

# Standardmäßig nur lesend. ProbePackageId ruft ausschließlich den bestehenden
# festen JEA-Updatewrapper auf; keine Neuinstallation oder Konfigurationsänderung.
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
Import-Module (Join-Path $root 'Module\WindowsUpdate.Common.psm1') -ErrorAction Stop
$auth = $null
if ($UseClientCertificate) {
    $settings = Get-WindowsUpdateSettings -ScriptRoot $root -ScriptName 'Check-ServersUpdates'
    $auth = Get-WindowsUpdateClientCertificateAuthInfo -UpdateSettings $settings.UpdateSettings -TargetComputer $ComputerName
    if (-not $auth) { throw 'Kein passendes Clientzertifikat gefunden; keine andere Anmeldung versuchen.' }
}
$report = [ordered]@{ ComputerName=$ComputerName; Started=(Get-Date).ToString('o'); Sections=@() }
$probeSession=$null
if ($ProbePackageId) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    $section=[ordered]@{Name='JEA-Paketupdate';Success=$false;Seconds=0;Data=@();Error=''}
    Write-Host ('[{0:HH:mm:ss}] {1}: Updateversuch für {2} über JEA' -f (Get-Date),$ComputerName,$ProbePackageId)
    try {
        $parameters=New-WindowsUpdateInvokeCommandParams -ComputerName $ComputerName -AuthInfo $auth -ConfigurationName WindowsUpdateAdm -OperationTimeoutSeconds 2100
        $probeSession=New-PSSession @parameters
        $section.Data=@(Invoke-Command -Session $probeSession -ErrorAction Stop -ArgumentList $ProbePackageId -ScriptBlock {
            param([string]$Id)
            Update-WindowsUpdateAdmWinGetPackage -Id $Id -Source winget -ErrorAction Stop
        })
        if ($section.Data.Count -gt 0) {
            $last=$section.Data[-1]
            $section.Success=([string]$last.Status -eq 'Ok' -and [string]$last.InstallerErrorCode -in @('','0') -and [string]$last.ExtendedErrorCode -in @('','0'))
        }
    } catch { $section.Error=$_.Exception.Message }
    $section.Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,1)
    $report.Sections += [pscustomobject]$section
    # Bis nach dem Einsammeln offen halten: temporäre JEA-Profilpfade erhalten.
}
$queries = @(
    @{ Name='JEA-Status'; Configuration='WindowsUpdateAdm'; Script={ Get-WindowsUpdateAdmDeploymentStatus } },
    @{ Name='JEA-Sperre-Get-Process'; Configuration='WindowsUpdateAdm'; ExpectDenied=$true; Script={ Get-Process } },
    @{ Name='JEA-Sperre-Get-Item'; Configuration='WindowsUpdateAdm'; ExpectDenied=$true; Script={ Get-Item -LiteralPath 'HKLM:\SOFTWARE' } },
    @{ Name='Baseline-und-WinGet-Fehler'; Configuration='Microsoft.PowerShell'; Script={
        $ErrorActionPreference = 'Stop'
        $result = [ordered]@{
            ComputerName=$env:COMPUTERNAME
            Identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
            Captured=(Get-Date).ToString('o')
            Errors=@(); WinGetLogs=@()
        }
        # Einzelne fehlende Komponenten verdecken nicht die übrigen Befunde.
        foreach ($section in @('WinRM','Listeners','Auth','RootSDDL','TokenFilter','Endpoints','Firewall','Roles','WinGetLogs')) {
            try {
                switch ($section) {
                    'WinRM' { $result.WinRM = Get-CimInstance Win32_Service -Filter "Name='WinRM'" | Select-Object State,StartMode,StartName,ProcessId }
                    'Listeners' { $result.Listeners = @(Get-ChildItem WSMan:\localhost\Listener | ForEach-Object { Get-ChildItem -LiteralPath $_.PSPath | Where-Object Name -in @('Transport','Port','Address','Enabled','CertificateThumbprint') | Select-Object PSParentPath,Name,Value }) }
                    'Auth' { $result.Auth = @(Get-ChildItem WSMan:\localhost\Service\Auth | Select-Object Name,Value) }
                    'RootSDDL' { $result.RootSDDL = (Get-Item WSMan:\localhost\Service\RootSDDL).Value }
                    'TokenFilter' {
                        $key=Get-Item 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System'
                        $name='LocalAccountTokenFilterPolicy'
                        $present=$key.GetValueNames() -contains $name
                        $result.TokenFilter=[pscustomobject]@{Present=$present;Value=$key.GetValue($name);Type=$(if($present){[string]$key.GetValueKind($name)}else{''})}
                    }
                    'Endpoints' { $result.Endpoints = @(Get-PSSessionConfiguration | Select-Object Name,Enabled,Permission,SecurityDescriptorSddl,RunAsVirtualAccount,RunAsUser,ConfigFilePath) }
                    'Firewall' {
                        $result.Firewall = @(Get-NetFirewallRule -Direction Inbound | Where-Object { $_.Name -like 'WINRM-*' -or $_.DisplayName -match 'WinRM|Windows.Remoteverwaltung' } | ForEach-Object {
                            $rule=$_; $port=$rule | Get-NetFirewallPortFilter; $address=$rule | Get-NetFirewallAddressFilter
                            [pscustomobject]@{Name=$rule.Name;Enabled=[string]$rule.Enabled;Action=[string]$rule.Action;Profile=[string]$rule.Profile;Port=@($port.LocalPort);RemoteAddress=@($address.RemoteAddress)}
                        })
                    }
                    'Roles' {
                        $roleRoot=Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules\JEA_Updates'
                        $result.Roles=@(Get-ChildItem -LiteralPath (Join-Path $roleRoot 'RoleCapabilities') -Filter '*.psrc' -File -ErrorAction SilentlyContinue | ForEach-Object {
                            [pscustomobject]@{Name=$_.Name;Content=[IO.File]::ReadAllText($_.FullName)}
                        })
                    }
                    'WinGetLogs' {
                        $profiles=@(Get-ChildItem (Join-Path $env:SystemDrive 'Users') -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
                        $profiles+=@((Join-Path $env:SystemRoot 'System32\config\systemprofile'))
                        $profiles+=@(Get-ChildItem (Join-Path $env:SystemRoot 'ServiceProfiles') -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
                        $profiles+=@(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList' | ForEach-Object { (Get-ItemProperty -LiteralPath $_.PSPath).ProfileImagePath } | Where-Object { $_ } | ForEach-Object { [Environment]::ExpandEnvironmentVariables($_) })
                        $profiles+=@(Get-ChildItem (Join-Path $env:SystemDrive 'Users\WinRM Virtual Users') -Directory -Force -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName)
                        $profiles=@($profiles | Sort-Object -Unique)
                        $files=@(foreach($profile in $profiles) {
                            foreach($relative in @('AppData\Local\Microsoft\WinGet\DiagOutputDir','AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir','AppData\Local\Temp\WinGet')) {
                                Get-ChildItem -LiteralPath (Join-Path $profile $relative) -Filter '*.log' -File -ErrorAction SilentlyContinue
                            }
                        })
                        foreach($folder in @((Join-Path $env:SystemRoot 'Temp\WinGet'),(Join-Path $env:SystemRoot 'Temp\WinGet\defaultState'),(Join-Path $env:ProgramData 'Microsoft\WinGet\DiagOutputDir'))) {
                            $files+=@(Get-ChildItem -LiteralPath $folder -Filter '*.log' -File -ErrorAction SilentlyContinue)
                        }
                        # COM-/JEA-Logs können älter als interaktive CLI-Logs sein.
                        # Auch die vom Installer selbst geschriebenen Logs erhalten:
                        # WinGet fasst deren unterschiedliche Fehler nur allgemein zusammen.
                        $files=@($files | Sort-Object FullName -Unique)
                        $result.WinGetLogFilesFound=$files.Count
                        $result.WinGetLogs=@($files | Sort-Object LastWriteTime -Descending | Select-Object -First 24 | ForEach-Object {
                            $file=$_
                            $lines=@(Get-Content -LiteralPath $file.FullName -Tail 600 | Select-String -Pattern 'ShellExecute|0x8a150006|0x8007|\berror\b|\bfail(?:ed|ure)?\b|owner|security|Return value 3|Apply complete|Starting:|Terminating context|IsCOMCall|Caller:|WinGet, version' -Context 2,2 | ForEach-Object { $_.ToString() })
                            [pscustomobject]@{Path=$file.FullName;LastWriteTime=$file.LastWriteTime;Evidence=$lines}
                        })
                    }
                }
            } catch { $result.Errors+=('{0}: {1}' -f $section,$_.Exception.Message) }
        }
        [pscustomobject]$result
    } }
)
try { foreach($query in $queries) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    Write-Host ('[{0:HH:mm:ss}] {1}: {2}' -f (Get-Date),$ComputerName,$query.Name)
    $section=[ordered]@{Name=$query.Name;Success=$false;Seconds=0;Data=@();Error='';ExpectedDenied=($query.ContainsKey('ExpectDenied') -and $query.ExpectDenied);Denied=$false}
    try {
        $section.Data=@(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $auth -ConfigurationName $query.Configuration -ScriptBlock $query.Script -TimeoutSeconds 90 -OperationName $query.Name)
        $section.Success=-not $section.ExpectedDenied
        if($section.ExpectedDenied) { $section.Error='Befehl ist über JEA ausführbar; Rollenfreigabe prüfen.' }
    } catch {
        $section.Error=$_.Exception.Message
        if($section.ExpectedDenied -and ($_.Exception.Message -match 'CommandNotFound|wird nicht als Name|is not recognized|nicht als Name.*erkannt')) {
            $section.Denied=$true
            $section.Success=$true
        }
    }
    $section.Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,1)
    $report.Sections += [pscustomobject]$section
} } finally { if($probeSession) { Remove-PSSession -Session $probeSession -ErrorAction SilentlyContinue } }
$directory=Join-Path $root 'Logs'
$null=New-Item -ItemType Directory -Path $directory -Force
$path=Join-Path $directory ('Remoting-Diagnose-{0}-{1}.json' -f $ComputerName,(Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Diagnose gespeichert: $path"
