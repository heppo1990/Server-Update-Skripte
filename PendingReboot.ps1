#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Prüft zentral, ob Windows-Ziele einen Neustart benötigen.

.DESCRIPTION
    Ohne -ComputerName werden die Windows-Ziele aus AD und Konfiguration
    ermittelt. AD-Ziele verwenden Kerberos, Nicht-AD-Ziele Client-Zertifikate.

.EXAMPLE
    .\PendingReboot.ps1
    Prüft alle konfigurierten Windows-Ziele.

.EXAMPLE
    .\PendingReboot.ps1 -ComputerName SRVSVC,SrvHv01
    Prüft ausschließlich die angegebenen Ziele.
#>
[CmdletBinding()]
param([string[]]$ComputerName)

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'WindowsUpdate.Common.psm1') -Force -ErrorAction Stop

function Write-PendingLog {
    param([string]$Message)
    Write-Host $Message
}

function Get-PendingRebootSettings {
    Get-WindowsUpdateSettings -ScriptRoot $PSScriptRoot -ScriptName 'PendingReboot' -WriteLog { param($message) Write-PendingLog $message }
}

function Get-ConfiguredWindowsTargets {
    param($UpdateSettings)

    $targets = @()
    $adAvailable = $false
    try {
        if ($PSVersionTable.PSVersion.Major -ge 7) {
            Import-Module ActiveDirectory -UseWindowsPowerShell -ErrorAction Stop -WarningAction SilentlyContinue
        } else {
            Import-Module ActiveDirectory -ErrorAction Stop
        }
        $adAvailable = $true
        $filter = if ($UpdateSettings.TargetComputers -eq 'All') {
            { (OperatingSystem -like '*Windows*') -and (Enabled -eq $true) }
        } else {
            { (OperatingSystem -like '*Windows*Server*') -and (Enabled -eq $true) }
        }
        $targets += Get-ADComputer -Filter $filter -Properties Name | ForEach-Object {
            [PSCustomObject]@{ Name = $_.Name; IsCertificateTarget = $false }
        }
    } catch {
        Write-Warning "AD-Ziele konnten nicht ermittelt werden: $($_.Exception.Message)"
    }

    foreach ($name in @($UpdateSettings.AdditionalComputers) + @($UpdateSettings.HypervisorComputers)) {
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        $isInAd = $false
        if ($adAvailable) {
            try { $null = Get-ADComputer -Identity $name -ErrorAction Stop; $isInAd = $true } catch { }
        }
        $targets += [PSCustomObject]@{ Name = $name; IsCertificateTarget = -not $isInAd }
    }

    if ($targets.Count -eq 0) {
        Write-Warning 'Keine Ziele aus AD oder Konfiguration verfügbar; prüfe den lokalen Rechner.'
        $targets = @([PSCustomObject]@{ Name = $env:COMPUTERNAME; IsCertificateTarget = $false })
    }

    $targets | Group-Object Name | ForEach-Object {
        $group = $_.Group
        [PSCustomObject]@{
            Name = $group[0].Name
            IsCertificateTarget = ($group | Where-Object IsCertificateTarget | Measure-Object).Count -gt 0
        }
    }
}

function Get-PendingRebootStatus {
    param([Parameter(Mandatory)][string]$Target, $AuthInfo)

    $scriptBlock = {
        $reasons = [System.Collections.Generic.List[string]]::new()
        try {
            if (Get-Command Get-WURebootStatus -ErrorAction SilentlyContinue) {
                if (Get-WURebootStatus -Silent -ErrorAction Stop) { $reasons.Add('Windows Update') }
            }
        } catch { }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons.Add('Windows Update Registry') }
        if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons.Add('Component Based Servicing') }
        $pendingRename = Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue
        if ($pendingRename.PendingFileRenameOperations) { $reasons.Add('Pending File Rename') }
        try {
            $sccm = Invoke-CimMethod -Namespace 'ROOT\ccm\ClientSDK' -ClassName 'CCM_ClientUtilities' -Name 'DetermineIfRebootPending' -ErrorAction Stop
            if ($sccm.RebootPending -or $sccm.IsHardRebootPending) { $reasons.Add('SCCM') }
        } catch { }
        [PSCustomObject]@{
            ComputerName = $env:COMPUTERNAME
            RebootIsPending = $reasons.Count -gt 0
            Reasons = ($reasons | Select-Object -Unique) -join '; '
        }
    }

    try {
        if ($Target -ieq $env:COMPUTERNAME) { return & $scriptBlock }
        $params = New-WindowsUpdateInvokeCommandParams -ComputerName $Target -AuthInfo $AuthInfo
        return Invoke-WindowsUpdateWithRetry -OperationName "Pending-Reboot-Prüfung auf $Target" -WriteLog { param($message) Write-PendingLog $message } -ScriptBlock { Invoke-Command @params -ScriptBlock $scriptBlock }
    } catch {
        return [PSCustomObject]@{
            ComputerName = $Target
            RebootIsPending = $null
            Reasons = "FEHLER: $($_.Exception.Message)"
        }
    }
}

$settings = Get-PendingRebootSettings
$targets = if ($ComputerName) {
    $certificateNames = @($settings.UpdateSettings.AdditionalComputers) + @($settings.UpdateSettings.HypervisorComputers)
    $ComputerName | ForEach-Object {
        [PSCustomObject]@{ Name = $_; IsCertificateTarget = $_ -in $certificateNames }
    }
} else {
    Get-ConfiguredWindowsTargets -UpdateSettings $settings.UpdateSettings
}

$results = foreach ($target in $targets) {
    Write-PendingLog "Prüfe Pending Reboot auf $($target.Name)..."
    $authInfo = if ($target.IsCertificateTarget) {
        Get-WindowsUpdateClientCertificateAuthInfo -UpdateSettings $settings.UpdateSettings -TargetComputer $target.Name -WriteLog { param($message) Write-PendingLog $message }
    } else { $null }
    Get-PendingRebootStatus -Target $target.Name -AuthInfo $authInfo
}

$results | Sort-Object ComputerName | Format-Table ComputerName, RebootIsPending, Reasons -AutoSize
