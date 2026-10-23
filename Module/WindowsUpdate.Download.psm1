function ConvertTo-WindowsUpdateDownloadResult {
    param([AllowNull()][object[]]$Updates)

    $uniqueUpdates = @($Updates | Sort-Object -Property KB, ComputerName -Unique)
    $tableLines = @()
    if ($uniqueUpdates.Count -gt 0) {
        $tableLines = @($uniqueUpdates | Select-Object ComputerName, Status, KB, Size, Title | Format-Table -AutoSize | Out-String) -split "\r?\n"
    }
    $htmlRows = @(
        foreach ($update in $uniqueUpdates) {
            [pscustomobject]@{
                ComputerName = [System.Net.WebUtility]::HtmlEncode([string]$update.ComputerName)
                Status = [System.Net.WebUtility]::HtmlEncode([string]$update.Status)
                KB = [System.Net.WebUtility]::HtmlEncode([string]$update.KB)
                Size = [System.Net.WebUtility]::HtmlEncode([string]$update.Size)
                Title = [System.Net.WebUtility]::HtmlEncode([string]$update.Title)
            }
        }
    )

    [pscustomobject]@{ Updates = $uniqueUpdates; TableLines = $tableLines; HtmlRows = $htmlRows; Count = $uniqueUpdates.Count }
}

function New-WindowsUpdateDownloadReportHeader {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][string]$Timestamp,
        [Parameter(Mandatory)][string]$PowerShellVersion
    )

    $safeComputerName = [Net.WebUtility]::HtmlEncode($ComputerName)
    $safeTimestamp = [Net.WebUtility]::HtmlEncode($Timestamp)
    $safePowerShellVersion = [Net.WebUtility]::HtmlEncode($PowerShellVersion)
    @"
<!DOCTYPE html>
<html>
<head>
<meta charset="UTF-8">
<title>Update-Download Report - $safeComputerName</title>
<style>
    body {
        font-family: Arial, sans-serif;
        margin: 20px;
        background-color: #f5f5f5;
    }
    h1 {
        color: #333;
        border-bottom: 2px solid #FF9800;
        padding-bottom: 10px;
    }
    .info-box {
        background-color: white;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #FF9800;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    .warning-box {
        background-color: #fff3cd;
        padding: 15px;
        margin: 10px 0;
        border-left: 4px solid #ffc107;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    table {
        border-collapse: collapse;
        width: 100%;
        margin: 10px 0;
        background-color: white;
        box-shadow: 0 2px 4px rgba(0,0,0,0.1);
    }
    th, td {
        border: 1px solid #ddd;
        padding: 12px 8px;
        text-align: left;
    }
    th {
        background-color: #FF9800;
        color: white;
        font-weight: bold;
    }
    tr:nth-child(even) {
        background-color: #f9f9f9;
    }
    tr:hover {
        background-color: #f1f1f1;
    }
    .server-title {
        background-color: #FF9800;
        color: white;
        padding: 10px;
        margin: 15px 0 5px 0;
        font-weight: bold;
        border-radius: 3px;
    }
    .no-updates {
        background-color: #d4edda;
        color: #155724;
        padding: 10px;
        margin: 5px 0;
        border-left: 4px solid #28a745;
    }
    .summary {
        background-color: #fff3e0;
        padding: 15px;
        margin: 20px 0;
        border-radius: 5px;
        font-size: 1.1em;
        border-left: 4px solid #FF9800;
    }
</style>
</head>
<body>
<h1>Update-Download Report - $safeComputerName</h1>
<div class="info-box">
    <p><strong>Computer:</strong> $safeComputerName</p>
    <p><strong>PowerShell Version:</strong> $safePowerShellVersion</p>
    <p><strong>Zeitstempel:</strong> $safeTimestamp</p>
    <p><strong>HINWEIS:</strong> Dieser Report zeigt heruntergeladene Updates. Es wurden <strong>KEINE Updates installiert</strong>!</p>
</div>
"@
}

function Complete-WindowsUpdateDownloadReport {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$ReportBody,
        [int]$DownloadedUpdateCount,
        [int]$UnreachableWindowsCount,
        [int]$ProcessedSystemCount,
        [AllowEmptyString()][string]$ProcessedSystemBreakdown,
        [Parameter(Mandatory)][string]$DurationMinutes,
        [bool]$IncludeLinux,
        [int]$LinuxAvailableUpdateCount,
        [bool]$IncludeHomeAssistant,
        [int]$HomeAssistantAvailableUpdateCount
    )

    if ($DownloadedUpdateCount -eq 0 -and $UnreachableWindowsCount -eq 0) {
        $ReportBody += @"
<div class="summary">
    <p><strong>Ergebnis: Es wurden KEINE Updates heruntergeladen!</strong></p>
    <p>Keine Updates verfügbar oder alle bereits heruntergeladen.</p>
</div>
"@
    } else {
        $headline = if ($DownloadedUpdateCount -eq 0) { 'Ergebnis: Keine Updates heruntergeladen; nicht erreichbare Ziele wurden übersprungen.' } else { "Ergebnis: Es wurden $DownloadedUpdateCount Update(s) heruntergeladen!" }
        $detail = if ($DownloadedUpdateCount -eq 0) { 'Die übersprungenen Systeme wurden nicht geprüft.' } else { 'Diese Updates können mit dem Install-ServersUpdates.ps1 Skript installiert werden.' }
        $ReportBody += @"
<div class="summary">
    <p><strong>$headline</strong></p>
    <p>$detail</p>
</div>
"@
    }

    if ($UnreachableWindowsCount -gt 0) {
        $ReportBody += "<div class='warning-box'><strong>Nicht erreichbar übersprungen:</strong> $UnreachableWindowsCount Windows-Ziel(e). Diese Systeme wurden nicht auf Updates geprüft oder Updates heruntergeladen.</div>"
    }

    $ReportBody += @"
<div class="info-box">
    <p><strong>Statistik:</strong></p>
    <ul>
        <li>Verarbeitete Systeme: $ProcessedSystemCount$(if ($ProcessedSystemBreakdown) { " ($ProcessedSystemBreakdown)" })</li>
        <li>Heruntergeladene Updates: $DownloadedUpdateCount</li>
$(if ($IncludeLinux) { "        <li>Linux-Updates verfügbar (nicht separat herunterladbar): $LinuxAvailableUpdateCount</li>" })
$(if ($IncludeHomeAssistant) { "        <li>Home-Assistant-Updates verfügbar (nicht separat herunterladbar): $HomeAssistantAvailableUpdateCount</li>" })
        <li>Verarbeitungsdauer: $DurationMinutes Minuten</li>
    </ul>
</div>
</body>
</html>
"@
    return $ReportBody
}

function New-WindowsUpdateDownloadConsoleSummary {
    param(
        [Parameter(Mandatory)][string]$PowerShellVersion,
        [int]$ProcessedSystemCount,
        [AllowEmptyString()][string]$ProcessedSystemBreakdown,
        [int]$DownloadedUpdateCount,
        [int]$UnreachableWindowsCount,
        [bool]$IncludeLinux,
        [int]$LinuxAvailableUpdateCount,
        [bool]$IncludeHomeAssistant,
        [int]$HomeAssistantAvailableUpdateCount,
        [Parameter(Mandatory)][string]$DurationMinutes
    )

    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("PowerShell Version: $PowerShellVersion")
    $breakdownText = if ($ProcessedSystemBreakdown) { " ($ProcessedSystemBreakdown)" } else { '' }
    $lines.Add("Verarbeitete Systeme: $ProcessedSystemCount$breakdownText")
    $lines.Add("Heruntergeladene Updates: $DownloadedUpdateCount")
    if ($UnreachableWindowsCount -gt 0) { $lines.Add("Nicht erreichbar übersprungen: $UnreachableWindowsCount Windows-Ziel(e)") }
    if ($IncludeLinux) { $lines.Add("Linux-Updates verfügbar (nicht separat herunterladbar): $LinuxAvailableUpdateCount") }
    if ($IncludeHomeAssistant) { $lines.Add("Home-Assistant-Updates verfügbar (nicht separat herunterladbar): $HomeAssistantAvailableUpdateCount") }
    $lines.Add("Dauer: $DurationMinutes Minuten")
    return $lines.ToArray()
}
Export-ModuleMember -Function ConvertTo-WindowsUpdateDownloadResult, New-WindowsUpdateDownloadReportHeader, Complete-WindowsUpdateDownloadReport, New-WindowsUpdateDownloadConsoleSummary
