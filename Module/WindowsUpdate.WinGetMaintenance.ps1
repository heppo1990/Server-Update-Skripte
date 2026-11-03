param([Parameter(Mandatory)][ValidateSet('SourceList','SourceUpdate','SourceReset','ClientRepair')][string]$Action)
$ErrorActionPreference = 'Stop'
function Get-WinGetPath {
    $portableRoot = Join-Path $PSScriptRoot 'WinGetPortable'
    $portable = @(Get-ChildItem -LiteralPath $portableRoot -Filter winget.exe -File -Recurse -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending | Select-Object -First 1)
    if ($portable.Count -gt 0) { return $portable[0].FullName }
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
    $start.WorkingDirectory = Split-Path -Parent $Path
    $start.EnvironmentVariables['PATH'] = $start.WorkingDirectory + ';' + $env:PATH
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
        function Get-WinGetPortableClientFromGitHub {
            # WinGet kann auf Server 2019 experimentell aus einem entpackten
            # GitHub-MSIX-Bundle ausgeführt werden. Die Releaseversion und ein
            # optionaler SHA-256-Wert kommen dynamisch aus GitHub-Metadaten.
            [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
            $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' `
                -Headers @{ 'User-Agent' = 'Server-Update-Skripte'; Accept = 'application/vnd.github+json' } `
                -TimeoutSec 30 -ErrorAction Stop
            $releaseTag = [string]$release.tag_name
            if ([string]::IsNullOrWhiteSpace($releaseTag)) { throw 'GitHub lieferte keinen Tag für das aktuelle WinGet-Release.' }
            $asset = @($release.assets | Where-Object {
                [string]$_.name -eq 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
            } | Select-Object -First 1)
            if ($asset.Count -eq 0 -or [string]::IsNullOrWhiteSpace([string]$asset[0].browser_download_url)) {
                throw "GitHub-Release '$releaseTag' enthält nicht das erwartete App-Installer-MSIX-Bundle."
            }

            $safeTag = [regex]::Replace($releaseTag, '[^A-Za-z0-9._-]', '_')
            $cacheRoot = Join-Path $PSScriptRoot 'WinGetPortable'
            $packageRoot = Join-Path $cacheRoot $safeTag
            $cachedExecutable = @(Get-ChildItem -LiteralPath $packageRoot -Filter winget.exe -File -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1)
            if ($cachedExecutable.Count -gt 0) {
                try {
                    $cachedSignature = Get-AuthenticodeSignature -FilePath $cachedExecutable[0].FullName -ErrorAction Stop
                    if ($cachedSignature.Status -ne 'Valid' -or $cachedSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Portable CLI im Cache hat keine gültige Microsoft-Signatur.' }
                    $cachedProbe = Invoke-WinGet -Path $cachedExecutable[0].FullName -Arguments @('--version')
                    if ([int]$cachedProbe.ExitCode -eq 0 -and [string]$cachedProbe.Output -match '(?m)^\s*v?\d+\.\d+') {
                        return [pscustomobject]@{ Path = $cachedExecutable[0].FullName; Version = $releaseTag; ReleaseTag = $releaseTag; Cached = $true }
                    }
                }
                catch { }
                Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction Stop
            }

            $workingRoot = Join-Path ([IO.Path]::GetTempPath()) ('WindowsUpdate-WinGet-Portable-' + [guid]::NewGuid().ToString('N'))
            $bundlePath = Join-Path $workingRoot 'DesktopAppInstaller.msixbundle'
            $packagePath = Join-Path $workingRoot 'AppInstaller_x64.msix'
            try {
                New-Item -Path $workingRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                Invoke-WebRequest -Uri ([string]$asset[0].browser_download_url) -OutFile $bundlePath `
                    -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                if ((Get-Item -LiteralPath $bundlePath -ErrorAction Stop).Length -le 0) { throw 'Das GitHub-MSIX-Bundle ist leer.' }

                Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
                $bundleArchive = [IO.Compression.ZipFile]::OpenRead($bundlePath)
                try {
                    $x64Package = @($bundleArchive.Entries | Where-Object {
                        [IO.Path]::GetFileName([string]$_.FullName) -match '(?i)^AppInstaller_x64\.msix$'
                    } | Select-Object -First 1)
                    if ($x64Package.Count -eq 0) {
                        $availablePackages = @($bundleArchive.Entries | Where-Object {
                            [IO.Path]::GetExtension([string]$_.FullName) -in '.msix', '.appx'
                        } | ForEach-Object FullName)
                        throw "Das GitHub-Bundle enthält kein x64-App-Installer-Paket. Enthalten: $($availablePackages -join ', ')"
                    }
                    $inputStream = $x64Package[0].Open()
                    try {
                        $outputStream = [IO.File]::Create($packagePath)
                        try { $inputStream.CopyTo($outputStream) } finally { $outputStream.Dispose() }
                    } finally { $inputStream.Dispose() }
                }
                finally { $bundleArchive.Dispose() }

                if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction Stop }
                New-Item -Path $packageRoot -ItemType Directory -Force -ErrorAction Stop | Out-Null
                [IO.Compression.ZipFile]::ExtractToDirectory($packagePath, $packageRoot)
                $extractedExecutable = @(Get-ChildItem -LiteralPath $packageRoot -Filter winget.exe -File -Recurse -ErrorAction Stop | Select-Object -First 1)
                if ($extractedExecutable.Count -eq 0) { throw 'Das entpackte GitHub-App-Installer-Paket enthält keine winget.exe.' }

                $dependencyAsset = @($release.assets | Where-Object name -eq 'DesktopAppInstaller_Dependencies.zip')
                if ($dependencyAsset.Count -ne 1 -or [string]$dependencyAsset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw 'Microsoft-Abhängigkeiten oder ihr Release-Digest fehlen.' }
                $dependencyHash = $Matches[1]
                $dependencyUri = [uri]$dependencyAsset[0].browser_download_url
                if ($dependencyUri.Scheme -ne 'https' -or $dependencyUri.Host -ne 'github.com' -or $dependencyUri.AbsolutePath -notlike '/microsoft/winget-cli/releases/download/*') { throw 'Ungültige Abhängigkeitsquelle.' }
                $dependencyZip = Join-Path $workingRoot 'Dependencies.zip'
                Invoke-WebRequest -Uri $dependencyUri.AbsoluteUri -OutFile $dependencyZip -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
                if ((Get-FileHash -LiteralPath $dependencyZip -Algorithm SHA256).Hash -ine $dependencyHash) { throw 'Abhängigkeitsprüfsumme stimmt nicht.' }
                $dependencyRoot = Join-Path $workingRoot 'Dependencies'
                Expand-Archive -LiteralPath $dependencyZip -DestinationPath $dependencyRoot -ErrorAction Stop
                foreach ($dependencyPackage in @(Get-ChildItem -LiteralPath $dependencyRoot -Recurse -File | Where-Object { $_.Extension -in '.appx','.msix' -and $_.FullName -match '[\\/]x64[\\/]' })) {
                    $dllRoot = Join-Path $workingRoot ([guid]::NewGuid().ToString('N'))
                    [IO.Compression.ZipFile]::ExtractToDirectory($dependencyPackage.FullName, $dllRoot)
                    foreach ($dll in @(Get-ChildItem -LiteralPath $dllRoot -Recurse -Filter '*.dll' -File)) {
                        $destination = Join-Path (Split-Path -Parent $extractedExecutable[0].FullName) $dll.Name
                        if (-not (Test-Path -LiteralPath $destination)) { Copy-Item -LiteralPath $dll.FullName -Destination $destination -ErrorAction Stop }
                    }
                }
                $packageVersion = $releaseTag
                $manifestPath = Join-Path $packageRoot 'AppxManifest.xml'
                if (Test-Path -LiteralPath $manifestPath -PathType Leaf) {
                    [xml]$manifest = Get-Content -LiteralPath $manifestPath -Raw -ErrorAction Stop
                    $identity = $manifest.SelectSingleNode("//*[local-name()='Identity']")
                    if ($identity -and -not [string]::IsNullOrWhiteSpace([string]$identity.Version)) { $packageVersion = [string]$identity.Version }
                }
                if ([string]$asset[0].digest -match '^sha256:(?<Hash>[0-9a-fA-F]{64})$') {
                    $expectedHash = $Matches.Hash
                    $actualHash = (Get-FileHash -LiteralPath $bundlePath -Algorithm SHA256 -ErrorAction Stop).Hash
                    if ($actualHash -ine $expectedHash) { throw 'Die Bundle-Prüfsumme weicht vom dynamischen GitHub-Release-Metadatum ab.' }
                }
                $exeSignature = Get-AuthenticodeSignature -FilePath $extractedExecutable[0].FullName -ErrorAction Stop
                if ($exeSignature.Status -ne 'Valid' -or $exeSignature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') { throw 'Entpackte portable CLI hat keine gültige Microsoft-Signatur.' }
                return [pscustomobject]@{ Path = $extractedExecutable[0].FullName; Version = $packageVersion; ReleaseTag = $releaseTag; Cached = $false }
            }
            catch {
                if (Test-Path -LiteralPath $packageRoot) { Remove-Item -LiteralPath $packageRoot -Recurse -Force -ErrorAction SilentlyContinue }
                throw
            }
            finally {
                if (Test-Path -LiteralPath $workingRoot) { Remove-Item -LiteralPath $workingRoot -Recurse -Force -ErrorAction SilentlyContinue }
            }
        }

# Fester Wartungsbaustein; keine vom JEA-Aufrufer gelieferten Pfade oder Befehle.
function Repair-WindowsUpdateWinGetAppx {
    $root = Join-Path $PSScriptRoot 'AppxRepair'
    New-Item -ItemType Directory -Path $root -Force -ErrorAction Stop | Out-Null
    $release = Invoke-RestMethod -Uri 'https://api.github.com/repos/microsoft/winget-cli/releases/latest' -Headers @{'User-Agent'='Server-Update-Skripte'} -TimeoutSec 30 -ErrorAction Stop
    function Get-RepairAsset {
        param([string]$Name)
        $asset = @($release.assets | Where-Object name -eq $Name)
        if ($asset.Count -ne 1) { throw "Microsoft-Release enthält nicht genau ein Asset '$Name'." }
        $uri = [uri]$asset[0].browser_download_url
        if ($uri.Scheme -ne 'https' -or $uri.Host -ne 'github.com' -or $uri.AbsolutePath -notlike '/microsoft/winget-cli/releases/download/*') { throw 'Unerwartete Microsoft-Downloadadresse.' }
        $path = Join-Path $root $Name
        Invoke-WebRequest -Uri $uri.AbsoluteUri -OutFile $path -UseBasicParsing -TimeoutSec 120 -ErrorAction Stop
        if ([string]$asset[0].digest -notmatch '^sha256:([a-fA-F0-9]{64})$') { throw "Release-Digest fehlt für '$Name'." }
        if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ine $Matches[1]) { throw "Release-Digest stimmt nicht für '$Name'." }
        return $path
    }
    $bundle = Get-RepairAsset 'Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle'
    $dependencies = Get-RepairAsset 'DesktopAppInstaller_Dependencies.zip'
    $licenseAssets = @($release.assets | Where-Object { $_.name -like '*License*.xml' })
    if ($licenseAssets.Count -ne 1) { throw 'Microsoft-Release enthält keine eindeutige App-Installer-Lizenz.' }
    $license = Get-RepairAsset ([string]$licenseAssets[0].name)
    $extract = Join-Path $root ([guid]::NewGuid().ToString('N'))
    Expand-Archive -LiteralPath $dependencies -DestinationPath $extract -ErrorAction Stop
    $dependencyPaths = @(Get-ChildItem -LiteralPath $extract -Recurse -File | Where-Object { $_.Extension -in '.appx','.msix' -and $_.FullName -match '[\\/]x64[\\/]' } | ForEach-Object FullName)
    if ($dependencyPaths.Count -eq 0) { throw 'Keine x64-Abhängigkeiten im Microsoft-Release gefunden.' }
    try {
        Add-AppxProvisionedPackage -Online -PackagePath $bundle -DependencyPackagePath $dependencyPaths -LicensePath $license -ErrorAction Stop | Out-Null
    } finally {
        $resolvedExtract = [IO.Path]::GetFullPath($extract)
        $allowedRoot = [IO.Path]::GetFullPath($root).TrimEnd('\') + '\'
        if ($resolvedExtract.StartsWith($allowedRoot, [StringComparison]::OrdinalIgnoreCase)) {
            Remove-Item -LiteralPath $resolvedExtract -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Write-Output 'App-Installer-Maschinenbestand samt Abhängigkeiten aus aktuellem Microsoft-Release provisioniert.'
    # Nur bereits angemeldete echte Benutzer; keine Kennwörter und kein neues Administratorkonto.
    $user = [string](Get-CimInstance Win32_ComputerSystem -ErrorAction Stop).UserName
    if ([string]::IsNullOrWhiteSpace($user)) {
        Write-Output 'Benutzerregistrierung ausstehend: kein interaktiv angemeldeter Benutzer verfügbar.'
        return
    }
    $sid = ([Security.Principal.NTAccount]::new($user)).Translate([Security.Principal.SecurityIdentifier]).Value
    $profile = @(Get-CimInstance Win32_UserProfile | Where-Object { $_.SID -eq $sid -and $_.Loaded -and -not $_.Special })
    if ($profile.Count -ne 1) { throw "Kein geladenes echtes Benutzerprofil für '$user'." }
    $registration = Join-Path $root 'Register-AppInstaller.ps1'
    [IO.File]::WriteAllText($registration, "`$ErrorActionPreference='Stop'; Add-AppxPackage -RegisterByFamilyName -MainPackage Microsoft.DesktopAppInstaller_8wekyb3d8bbwe -ErrorAction Stop", [Text.UTF8Encoding]::new($true))
    $name = 'WindowsUpdateAdm-AppxRegistration-' + [guid]::NewGuid().ToString('N')
    try {
        $exe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $action = New-ScheduledTaskAction -Execute $exe -Argument ('-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $registration + '"')
        $principal = New-ScheduledTaskPrincipal -UserId $sid -LogonType Interactive -RunLevel Limited
        Register-ScheduledTask -TaskName $name -Action $action -Principal $principal -Force -ErrorAction Stop | Out-Null
        Start-ScheduledTask -TaskName $name -ErrorAction Stop
        $deadline = (Get-Date).AddMinutes(2)
        do {
            Start-Sleep -Seconds 2
            $info = Get-ScheduledTaskInfo -TaskName $name -ErrorAction Stop
            $task = Get-ScheduledTask -TaskName $name -ErrorAction Stop
        } while (($info.LastRunTime -lt (Get-Date).AddMinutes(-3) -or $task.State -in 'Running','Queued') -and (Get-Date) -lt $deadline)
        if ($task.State -in 'Running','Queued' -or $info.LastTaskResult -ne 0) { throw "Benutzerregistrierung fehlgeschlagen/abgelaufen: $($info.LastTaskResult)." }
        $registered = @(Get-AppxPackage -User $sid -Name Microsoft.DesktopAppInstaller -ErrorAction Stop | Where-Object Status -eq 'Ok')
        if ($registered.Count -eq 0) { throw 'App Installer nach Registrierungsaufgabe nicht im Benutzerprofil bestätigt.' }
        Write-Output "App Installer im echten Benutzerprofil '$user' registriert und bestätigt."
    } finally {
        Stop-ScheduledTask -TaskName $name -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue
    }
}

if ($Action -eq 'ClientRepair') {
    $temp = Join-Path ([IO.Path]::GetTempPath()) ('winget-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
    try {
        try {
            $appxRepairOutput = Repair-WindowsUpdateWinGetAppx | Out-String
            [Console]::Out.WriteLine($appxRepairOutput)
        } catch {
            [Console]::Out.WriteLine('AppX-Bestandsreparatur nicht vollständig: ' + $_.Exception.ToString())
        }
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
        $clientPath = Get-WinGetPath
        $clientProbe = Invoke-WinGet -Path $clientPath -Arguments @('--version')
        $version = $clientProbe.Output
        if ($clientProbe.ExitCode -ne 0 -or $version -notmatch '(?m)^\s*v?\d+\.\d+') { throw "WinGet-Starttest fehlgeschlagen: Pfad=$clientPath; Exitcode=$($clientProbe.ExitCode); Ausgabe=$version; Installerausgabe=$out" }
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
                throw "WinGet-Starttest nach Microsoft-Reparatur fehlgeschlagen: Exitcode=$($probe.ExitCode); Ausgabe=$($probe.Output)"
            }
            [pscustomobject]@{
                Action=$Action; Success=$true; ExitCode=0
                Output="winget-install-Reparatur fehlgeschlagen: $primaryError; Microsoft-Fallback Repair-WinGetPackageManager -Latest -Force erfolgreich. WinGet: $($probe.Output). $repairOutput"
            }
            exit 0
        } catch {
            $microsoftError = $_.Exception.ToString()
            try {
                $portableClient = Get-WinGetPortableClientFromGitHub
                $portableProbe = Invoke-WinGet -Path $portableClient.Path -Arguments @('--version')
                if ($portableProbe.ExitCode -ne 0 -or $portableProbe.Output -notmatch '(?m)^\s*v?\d+\.\d+') { throw "Portabler WinGet-Starttest fehlgeschlagen: Pfad=$($portableClient.Path); Exitcode=$($portableProbe.ExitCode); Ausgabe=$($portableProbe.Output)" }
                [Console]::Out.WriteLine("__WINGET_PORTABLE__ AppX-Reparatur nicht möglich; portable Microsoft-CLI erfolgreich: $($portableProbe.Output). winget-install: $primaryError; Microsoft-AppX: $microsoftError")
                exit 0
            } catch { $portableError = $_.Exception.ToString() }
            $fallbackError = $microsoftError + [Environment]::NewLine + 'Portabler Microsoft-Fallback: ' + $portableError
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
