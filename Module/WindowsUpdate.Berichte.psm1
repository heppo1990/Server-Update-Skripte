# Fachmodul: WindowsUpdate.Berichte
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Invoke-WindowsUpdateFileRetention {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][int]$KeepFiles
    )

    $keep = [Math]::Max(1, $KeepFiles)
    $enumerationError = $null
    try {
        $files = if (Test-Path -LiteralPath $Directory -PathType Container -ErrorAction Stop) {
            @(Get-ChildItem -LiteralPath $Directory -File -Filter $Filter -ErrorAction Stop | Sort-Object LastWriteTime)
        } else { @() }
    }
    catch {
        $files = @()
        $enumerationError = $_.Exception.ToString()
    }
    # PowerShell entpackt Arrays mit genau einem Element bei einer Zuweisung.
    # Deshalb niemals direkt $files.Count verwenden.
    $fileCount = @($files).Count
    $removeCount = [Math]::Max(0, $fileCount - $keep)
    $removedFiles = @()
    $failedFiles = @()
    if ($removeCount -gt 0) { foreach ($file in @($files | Select-Object -First $removeCount)) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force -ErrorAction Stop
            $removedFiles += $file.FullName
        }
        catch {
            $failedFiles += [PSCustomObject]@{ Path = $file.FullName; Error = $_.Exception.Message; Diagnostic = $_.Exception.ToString() }
        }
    } }

    return [PSCustomObject]@{
        ExistingCount = $fileCount
        RemovedFiles  = @($removedFiles)
        FailedFiles   = @($failedFiles)
        EnumerationError = $enumerationError
    }
}

function Write-WindowsUpdateLog {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [Parameter(Mandatory)][string]$LogFile,
        [Parameter(Mandatory)][string]$ScriptName,
        [Parameter(Mandatory)][string]$RunTimestamp,
        [bool]$WriteLogFile,
        [switch]$IsDebug,
        [switch]$LogOnly,
        [bool]$DebugEnabled
    )

    if ($IsDebug -and -not $DebugEnabled) { return }
    $prefix = if ($IsDebug) { '[DEBUG] ' } else { '' }
    if ($Message -match '^\[DIAG\]') { $LogOnly = $true }
    if (-not $LogOnly) {
        if ($Host.Name -eq 'ConsoleHost') {
            try {
                if (-not [Console]::IsOutputRedirected) {
                    $consoleColor = if ($IsDebug) { 'Cyan' } else { Get-WindowsUpdateConsoleColor -Message $Message }
                } else { $consoleColor = $null }
            } catch { $consoleColor = $null }
        } else { $consoleColor = $null }
        Write-WindowsUpdateConsoleLine -Message "$prefix$Message" -ForegroundColor $consoleColor -IsDebug:$IsDebug
    }
    if (-not $WriteLogFile) { return }

    $logDirectory = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path -LiteralPath $logDirectory)) { New-Item -ItemType Directory -Path $logDirectory -Force | Out-Null }
    if (-not (Test-Path -LiteralPath $LogFile)) { "Protokolldatei vom $RunTimestamp  / $ScriptName " | Set-Content -LiteralPath $LogFile -Encoding UTF8 }
    "$(Get-Date -Format 'dd.MM.yyyy HH:mm:ss') $prefix$Message" | Add-Content -LiteralPath $LogFile -Encoding UTF8
}

function Write-WindowsUpdateConsoleSummary {
    param(
        [Parameter(Mandatory)][string]$Title,
        [string[]]$Lines,
        [Parameter(Mandatory)][scriptblock]$WriteLog
    )

    Write-CommonLog $WriteLog ''
    Write-CommonLog $WriteLog '═══════════════════════════════════════'
    Write-CommonLog $WriteLog $Title
    Write-CommonLog $WriteLog '═══════════════════════════════════════'
    foreach ($line in @($Lines)) {
        Write-CommonLog $WriteLog $line
    }
    Write-CommonLog $WriteLog '═══════════════════════════════════════'
}

function Invoke-WindowsUpdateRetentionWithLog {
    param(
        [Parameter(Mandatory)][string]$Directory,
        [Parameter(Mandatory)][string]$Filter,
        [Parameter(Mandatory)][int]$KeepFiles,
        [Parameter(Mandatory)][string]$Description,
        [scriptblock]$WriteLog
    )

    if ($WriteLog) { & $WriteLog "Bereinige $Description" }
    $result = Invoke-WindowsUpdateFileRetention -Directory $Directory -Filter $Filter -KeepFiles $KeepFiles
    $removedFiles = @($result.RemovedFiles)
    $failedFiles = @($result.FailedFiles)
    if ($removedFiles.Count -eq 0) {
        if ($WriteLog) { & $WriteLog 'Es sind keine Dateien zum Entfernen vorhanden.' }
    } else {
        if ($WriteLog) { & $WriteLog "Es sind $($removedFiles.Count) Datei(en) zum Entfernen vorhanden." }
        foreach ($file in $removedFiles) { if ($WriteLog) { & $WriteLog "Entferne $file ..." } }
    }
    if ($result.EnumerationError) {
        if ($WriteLog) { & $WriteLog "WARNUNG: $Description konnte nicht vollständig gelesen werden; Details im Log." }
        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation "Log-Bereinigung: $Description" -Target $Directory -DiagnosticText $result.EnumerationError -Context @("Filter=$Filter")
    }
    foreach ($failed in $failedFiles) {
        if ($WriteLog) { & $WriteLog "WARNUNG: Eine Datei aus $Description konnte nicht entfernt werden; Details im Log." }
        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation "Logdatei entfernen: $Description" -Target ([string]$failed.Path) -DiagnosticText ([string]$failed.Diagnostic)
    }
    return $result
}

function ConvertTo-WindowsUpdateMailSafeString {
    param([AllowEmptyString()][string]$Text)
    $result = $Text -replace 'ä','ae' -replace 'ö','oe' -replace 'ü','ue' -replace 'Ä','Ae' -replace 'Ö','Oe' -replace 'Ü','Ue' -replace 'ß','ss'
    $result = ($result -replace '\s+','-').ToLower() -replace '[^a-z0-9\-\.]',''
    foreach ($form in @('gmbh-co-kg','gmbh-co','gmbh','mbh','ug','ag','kg','ohg','gbr','ev','inc','ltd','se')) { $result = $result -replace "-$form$",'' -replace "^$form-",'' }
    while ($result.Length -gt 40) { $firstDash = $result.IndexOf('-'); if ($firstDash -gt 0) { $result = $result.Substring($firstDash + 1) } else { $result = $result.Substring(0,40); break } }
    return $result
}

function Send-WindowsUpdateSmtpMessage {
    param([Parameter(Mandatory)]$MailSettings, [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body, [bool]$IsBodyHtml = $true)
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        # SmtpClient unter modernem .NET übernimmt ServicePointManager nicht
        # zuverlässig. Der feste PS5.1-Transport erzwingt TLS 1.2 auch bei PS7.
        # Zugangsdaten und Mailinhalt ausschließlich über stdin, nie argv/Datei.
        $definition = 'function Send-WindowsUpdateSmtpMessageTls12 {' + ${function:Send-WindowsUpdateSmtpMessageTls12}.ToString() + '}' + [Environment]::NewLine + 'function Send-WindowsUpdateSmtpMessage {' + ${function:Send-WindowsUpdateSmtpMessage}.ToString() + '}'
        $runner = $definition + @'

$ErrorActionPreference = 'Stop'
try {
    $data = [Management.Automation.PSSerializer]::Deserialize([Text.Encoding]::Unicode.GetString([Convert]::FromBase64String([Console]::In.ReadToEnd())))
    Send-WindowsUpdateSmtpMessage @data
    [Console]::Out.Write('SMTP_OK')
} catch { [Console]::Error.WriteLine($_.Exception.Message); exit 1 }
'@
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $start.Arguments = '-NoLogo -NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($runner))
        $start.UseShellExecute = $false; $start.CreateNoWindow = $true
        $start.RedirectStandardInput = $true; $start.RedirectStandardOutput = $true; $start.RedirectStandardError = $true
        $process = New-Object Diagnostics.Process
        $process.StartInfo = $start
        try {
            [void]$process.Start()
            $output = $process.StandardOutput.ReadToEndAsync(); $errorOutput = $process.StandardError.ReadToEndAsync()
            $data = @{MailSettings=$MailSettings;Subject=$Subject;Body=$Body;IsBodyHtml=$IsBodyHtml}
            $process.StandardInput.Write([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes([Management.Automation.PSSerializer]::Serialize($data))))
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(90000)) { $process.Kill(); $process.WaitForExit(); throw 'SMTP-Versand nach 90 Sekunden abgebrochen.' }
            if ($process.ExitCode -ne 0 -or $output.GetAwaiter().GetResult() -ne 'SMTP_OK') {
                throw "SMTP-Versand mit TLS 1.2 fehlgeschlagen: $($errorOutput.GetAwaiter().GetResult())"
            }
        } finally { $process.Dispose() }
        return
    }
    Send-WindowsUpdateSmtpMessageTls12 @PSBoundParameters
}

function Send-WindowsUpdateSmtpMessageTls12 {
    param([Parameter(Mandatory)]$MailSettings, [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$Body, [bool]$IsBodyHtml = $true)
    $previousProtocol = [Net.ServicePointManager]::SecurityProtocol
    $smtp = $null; $message = $null
    try {
        # Bewusst ersetzen statt -bor: SSL3/TLS1.0/TLS1.1 nicht weiter erlauben.
        [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
        $smtp = New-Object Net.Mail.SmtpClient($MailSettings.Host, [int]$MailSettings.Port)
        $smtp.EnableSsl = $true
        $smtp.Timeout = 60000
        if ($MailSettings.Auth) { $smtp.Credentials = New-Object Net.NetworkCredential($MailSettings.AuthUser, $MailSettings.AuthPass) }
        $message = New-Object Net.Mail.MailMessage
        $message.From = $MailSettings.Sender; $message.To.Add($MailSettings.MailTo)
        if ($MailSettings.MailCC -and $MailSettings.MailCC -ne $MailSettings.MailTo) { $message.CC.Add($MailSettings.MailCC) }
        if ($MailSettings.MailBCC -and $MailSettings.MailBCC -ne $MailSettings.MailTo) { $message.Bcc.Add($MailSettings.MailBCC) }
        $message.Subject = $Subject; $message.Body = $Body; $message.IsBodyHtml = $IsBodyHtml
        $message.BodyEncoding = [Text.Encoding]::UTF8; $message.SubjectEncoding = [Text.Encoding]::UTF8
        $smtp.Send($message)
    } finally {
        if ($message) { $message.Dispose() }; if ($smtp) { $smtp.Dispose() }
        [Net.ServicePointManager]::SecurityProtocol = $previousProtocol
    }
}

function Send-WindowsUpdateHtmlMail {
    param(
        [Parameter(Mandatory)]$MailSettings,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$HtmlBody,
        [scriptblock]$WriteLog,
        [ValidateRange(1, 10)][int]$RetryCount = 3,
        [ValidateRange(0, 300)][int]$RetryDelaySeconds = 30
    )
    if ($WriteLog) { & $WriteLog 'Starte Mailversand...' }
    for ($attempt = 1; $attempt -le $RetryCount; $attempt++) {
        $smtp = $null; $mail = $null
        try {
            Send-WindowsUpdateSmtpMessage -MailSettings $MailSettings -Subject $Subject -Body $HtmlBody
            if ($WriteLog) { & $WriteLog 'E-Mail erfolgreich versendet' }
            return $true
        }
        catch {
            if ($WriteLog) {
                & $WriteLog "WARNUNG: E-Mailversand fehlgeschlagen (Versuch $attempt von $RetryCount); Details im Log."
                Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'SMTP-Mailversand' -ErrorRecord $_ -Context @("Attempt=$attempt/$RetryCount", "Server=$($MailSettings.Host)", "Port=$($MailSettings.Port)")
            }
            if ($attempt -lt $RetryCount -and $RetryDelaySeconds -gt 0) {
                if ($WriteLog) { & $WriteLog "Nächster Mailversuch in $RetryDelaySeconds Sekunden..." }
                Start-Sleep -Seconds $RetryDelaySeconds
            }
        }
        finally { if ($mail) { $mail.Dispose() }; if ($smtp) { $smtp.Dispose() } }
    }
    return $false
}

function Add-WindowsUpdateTrustedHost {
    param([Parameter(Mandatory)][string]$ComputerName, [scriptblock]$WriteLog)
    try {
        $current = (Get-Item WSMan:\localhost\Client\TrustedHosts -ErrorAction Stop).Value
        if ($current -eq "*") { return }
        $entries = @($current -split "," | ForEach-Object { $_.Trim() } | Where-Object { $_ })
        if ($entries -contains $ComputerName) { return }
        if ($entries.Count -gt 0) { $newValue = ($entries + $ComputerName) -join "," }
        else { $newValue = $ComputerName }
        Set-Item WSMan:\localhost\Client\TrustedHosts -Value $newValue -Force -ErrorAction Stop
    }
    catch {
        Write-CommonLog $WriteLog 'WARNUNG: TrustedHosts konnte nicht aktualisiert werden; Details im Log.'
        Write-WindowsUpdateDiagnostic -WriteLog $WriteLog -Operation 'TrustedHosts aktualisieren' -Target $ComputerName -ErrorRecord $_
    }
}
