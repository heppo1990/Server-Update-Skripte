# Fachmodul: WindowsUpdate.Paketdarstellung
# Tabellen- und HTML-Darstellung von Paketmanager-Ergebnissen.

function ConvertTo-WindowsUpdatePackageRows {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('Winget', 'Chocolatey')][string]$Manager,
        [AllowNull()][object[]]$Packages
    )

    foreach ($package in @($Packages)) {
        if ($null -eq $package) { continue }
        $name = ''; $id = ''; $installed = ''; $available = ''; $source = $Manager.ToLowerInvariant()
        if ($package -isnot [string] -and $package.PSObject.Properties['Name']) {
            $name = [string]$package.Name
            $idProperty = $package.PSObject.Properties['Id']
            $installedProperty = $package.PSObject.Properties['InstalledVersion']
            $availableProperty = $package.PSObject.Properties['AvailableVersion']
            $sourceProperty = $package.PSObject.Properties['Source']
            if ($idProperty) { $id = [string]$idProperty.Value }
            if ($installedProperty) { $installed = [string]$installedProperty.Value }
            if ($availableProperty) { $available = [string]$availableProperty.Value }
            if ($sourceProperty -and -not [string]::IsNullOrWhiteSpace([string]$sourceProperty.Value)) { $source = [string]$sourceProperty.Value }
        }
        else {
            $text = [string]$package
            if ($Manager -eq 'Chocolatey' -and $text.Contains('|')) {
                $parts = @($text -split '\|', 4)
                $name = [string]$parts[0]
                if ($parts.Count -gt 1) { $installed = [string]$parts[1] }
                if ($parts.Count -gt 2) { $available = [string]$parts[2] }
                if ($parts.Count -gt 3 -and $parts[3]) { $id = [string]$parts[3] } else { $id = $name }
            }
            elseif ($Manager -eq 'Winget') {
                $match = [regex]::Match($text, '^\s*(?<Name>.+?)\s{2,}(?<Id>\S+)\s{2,}(?<Installed>\S+)\s{2,}(?<Available>\S+)\s{2,}(?<Source>\S+)\s*$')
                if ($match.Success) {
                    $name = $match.Groups['Name'].Value.Trim(); $id = $match.Groups['Id'].Value
                    $installed = $match.Groups['Installed'].Value; $available = $match.Groups['Available'].Value
                    $source = $match.Groups['Source'].Value
                }
                else { $name = $text.Trim() }
            }
            else { $name = $text.Trim(); $id = $name }
        }
        if ([string]::IsNullOrWhiteSpace($name)) { continue }
        [pscustomobject]@{
            ComputerName = $ComputerName; Name = $name; Id = $id
            InstalledVersion = $installed; AvailableVersion = $available; Source = $source
        }
    }
}

function Format-WindowsUpdatePackageConsoleTable {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('Winget', 'Chocolatey')][string]$Manager,
        [AllowNull()][object[]]$Packages
    )
    $rows = @(ConvertTo-WindowsUpdatePackageRows -ComputerName $ComputerName -Manager $Manager -Packages $Packages)
    if ($rows.Count -eq 0) { return '' }
    $consoleRows = @($rows | ForEach-Object {
        $name = [string]$_.Name
        $id = [string]$_.Id
        if ($name.Length -gt 34) { $name = $name.Substring(0, 31) + '...' }
        if ($id.Length -gt 36) { $id = $id.Substring(0, 33) + '...' }
        [pscustomobject]@{
            Name = $name
            Id = $id
            Installed = [string]$_.InstalledVersion
            Available = [string]$_.AvailableVersion
        }
    })
    # Server und Paketquelle stehen bereits in der umgebenden Statuszeile.
    # Die kompakte Tabelle passt damit auch in schmale Konsolenfenster.
    $tableWidth = 120
    try { $tableWidth = [Math]::Max(100, [Math]::Min(180, [int]$Host.UI.RawUI.WindowSize.Width)) } catch { }
    return (($consoleRows | Format-Table -AutoSize | Out-String -Width $tableWidth).TrimEnd())
}

function ConvertTo-WindowsUpdatePackageHtmlTable {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][ValidateSet('Winget', 'Chocolatey')][string]$Manager,
        [AllowNull()][object[]]$Packages
    )
    $rows = @(ConvertTo-WindowsUpdatePackageRows -ComputerName $ComputerName -Manager $Manager -Packages $Packages)
    if ($rows.Count -eq 0) { return '' }
    # Paket-IDs und Versionsstrings enthalten oft lange, nicht umbrechende
    # Zeichenfolgen. Ohne feste Tabellenaufteilung wächst die HTML-Tabelle in
    # Outlook über die verfügbare Mailbreite hinaus. Die Tabelle nutzt daher
    # immer 100 % des verfügbaren Inhaltsbereichs und verteilt die Spalten
    # proportional; lange Zellen umbrechen innerhalb ihrer Spalte.
    $html = '<table class="package-update-table" style="width:100%; table-layout:fixed; border-collapse:collapse;"><colgroup><col style="width:12%;"><col style="width:24%;"><col style="width:25%;"><col style="width:14%;"><col style="width:14%;"><col style="width:11%;"></colgroup><tr><th>ComputerName</th><th>Name</th><th>ID</th><th>Installiert</th><th>Verfügbar</th><th>Quelle</th></tr>'
    foreach ($row in $rows) {
        $html += '<tr>'
        foreach ($field in @('ComputerName', 'Name', 'Id', 'InstalledVersion', 'AvailableVersion', 'Source')) {
            $html += '<td style="word-wrap:break-word; overflow-wrap:anywhere;">' + [System.Net.WebUtility]::HtmlEncode([string]$row.$field) + '</td>'
        }
        $html += '</tr>'
    }
    return ($html + '</table>')
}
