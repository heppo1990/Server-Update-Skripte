[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._-]*$')][string]$ComputerName,
    [switch]$UseClientCertificate
)

# Lesende Diagnose: keine Reparatur, Updates, Aufgaben oder Konfigurationsänderung.
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
$queries = @(
    @{ Name='JEA-Status'; Configuration='WindowsUpdateAdm'; Script={ Get-WindowsUpdateAdmDeploymentStatus } },
    @{ Name='JEA-sichtbare-Befehle'; Configuration='WindowsUpdateAdm'; Script={ Get-Command | Select-Object Name,CommandType } },
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
                        $profiles=@($profiles | Sort-Object -Unique)
                        $files=@(foreach($profile in $profiles) {
                            foreach($relative in @('AppData\Local\Microsoft\WinGet\DiagOutputDir','AppData\Local\Packages\Microsoft.DesktopAppInstaller_8wekyb3d8bbwe\LocalState\DiagOutputDir','AppData\Local\Temp\WinGet')) {
                                Get-ChildItem -LiteralPath (Join-Path $profile $relative) -Filter '*.log' -File -ErrorAction SilentlyContinue
                            }
                        })
                        $result.WinGetLogFilesFound=$files.Count
                        $result.WinGetLogs=@($files | Sort-Object LastWriteTime -Descending | Select-Object -First 12 | ForEach-Object {
                            $file=$_
                            $lines=@(Get-Content -LiteralPath $file.FullName -Tail 600 | Select-String -Pattern 'ShellExecute|0x8a150006|0x8007|error|fail|Starting:|Terminating context|IsCOMCall|Caller:|WinGet, version' -Context 2,2 | ForEach-Object { $_.ToString() })
                            [pscustomobject]@{Path=$file.FullName;LastWriteTime=$file.LastWriteTime;Evidence=$lines}
                        })
                    }
                }
            } catch { $result.Errors+=('{0}: {1}' -f $section,$_.Exception.Message) }
        }
        [pscustomobject]$result
    } }
)
foreach($query in $queries) {
    $timer=[Diagnostics.Stopwatch]::StartNew()
    Write-Host ('[{0:HH:mm:ss}] {1}: {2}' -f (Get-Date),$ComputerName,$query.Name)
    $section=[ordered]@{Name=$query.Name;Success=$false;Seconds=0;Data=@();Error=''}
    try {
        $section.Data=@(Invoke-WindowsUpdateRemoteCommandWithTimeout -ComputerName $ComputerName -AuthInfo $auth -ConfigurationName $query.Configuration -ScriptBlock $query.Script -TimeoutSeconds 90 -OperationName $query.Name)
        $section.Success=$true
    } catch { $section.Error=$_.Exception.Message }
    $section.Seconds=[Math]::Round($timer.Elapsed.TotalSeconds,1)
    $report.Sections += [pscustomobject]$section
}
$directory=Join-Path $root 'Logs'
$null=New-Item -ItemType Directory -Path $directory -Force
$path=Join-Path $directory ('Remoting-Diagnose-{0}-{1}.json' -f $ComputerName,(Get-Date -Format 'yyyyMMdd-HHmmss'))
$report | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $path -Encoding UTF8
Write-Host "Diagnose gespeichert: $path"
