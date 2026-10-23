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

Export-ModuleMember -Function ConvertTo-WindowsUpdateDownloadResult
