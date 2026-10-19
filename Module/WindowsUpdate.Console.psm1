# Fachmodul: WindowsUpdate.Console
# Wird durch WindowsUpdate.Common.psm1 in dessen Modulbereich eingebunden.

function Write-CommonLog {
    param(
        [scriptblock]$WriteLog,
        [string]$Message
    )

    if ($WriteLog) { & $WriteLog $Message }
}

function Write-WindowsUpdateDiagnostic {
    [CmdletBinding()]
    param(
        [scriptblock]$WriteLog,
        [Parameter(Mandatory)][string]$Operation,
        [string]$Target,
        [System.Management.Automation.ErrorRecord]$ErrorRecord,
        [AllowEmptyString()][string]$DiagnosticText,
        [string[]]$Context = @()
    )

    if (-not $WriteLog) { return }
    $lines = [System.Collections.Generic.List[string]]::new()
    $lines.Add("Operation=$Operation")
    if (-not [string]::IsNullOrWhiteSpace($Target)) { $lines.Add("Target=$Target") }
    foreach ($item in $Context) {
        if (-not [string]::IsNullOrWhiteSpace($item)) { $lines.Add("Context=$item") }
    }
    if ($ErrorRecord) {
        $lines.Add("ErrorId=$($ErrorRecord.FullyQualifiedErrorId)")
        $lines.Add("Category=$($ErrorRecord.CategoryInfo.Category)")
        if ($ErrorRecord.InvocationInfo -and $ErrorRecord.InvocationInfo.PositionMessage) {
            $lines.Add("Position=$($ErrorRecord.InvocationInfo.PositionMessage.Trim())")
        }
        if (-not [string]::IsNullOrWhiteSpace([string]$ErrorRecord.ScriptStackTrace)) {
            $lines.Add("ScriptStackTrace=$($ErrorRecord.ScriptStackTrace)")
        }
        $DiagnosticText = $ErrorRecord.Exception.ToString()
    }
    foreach ($line in ([string]$DiagnosticText -split "`r?`n")) {
        if (-not [string]::IsNullOrWhiteSpace($line)) { $lines.Add($line.TrimEnd()) }
    }
    foreach ($line in $lines) {
        $safeLine = [string]$line -replace '(?i)\b(password|passwd|authpass|secret|token|clientsecret)\b(\s*[:=]\s*)(?:"[^"]*"|''[^'']*''|[^\s,;]+)', '$1$2<redacted>'
        Write-CommonLog $WriteLog "[DIAG] $safeLine"
    }
}

function Test-WindowsUpdateZeroFailureSummary {
    param([AllowEmptyString()][string]$Message)
    return $Message -match '(?i)^\s*(?:Linux-(?:Stats|Zusammenfassung)|HA-Stats):.*\b0\s+(?:fehlgeschlagen|Fehler)\b'
}

function Get-WindowsUpdateConsoleColor {
    param([AllowEmptyString()][string]$Message)

    if (Test-WindowsUpdateZeroFailureSummary -Message $Message) { return 'Green' }
    if ($Message -match '(?i)^\s*(WARNUNG|WARNING|\[WARN\])|manuelle Prüfung|manuelle Aktion erforderlich') { return 'Yellow' }
    if ($Message -match '(?i)^\s*(Fehler|Errors?)\s*:\s*0(?:\D|$)') { return 'Green' }
    if ($Message -match '(?i)^\s*(Fehler|Errors?)\s*:\s*[1-9]\d*') { return 'Red' }
    if ($Message -match '(?i)^\s*(\[ERROR\]|FEHLER\b|ERROR\b)|\bfehlgeschlagen\b|\bkonnte nicht\b|aufgetreten!') { return 'Red' }
    if ($Message -match '(?i)\[SUCCESS\]|\berfolgreich\b|\babgeschlossen\b|Updates installiert|Update\(s\) installiert|keine .*Updates verfügbar|Paketupdates? verfügbar|Home-Assistant-Updates verfügbar|Home Assistant auf .*Update\(s\) verfügbar') { return 'Green' }
    if ($Message -match '(?i)^[\s═+|\-]*$|ZUSAMMENFASSUNG|UPDATE-(CHECK|DOWNLOAD|INSTALLATION)|^\s*(Starte|Beginne|Verarbeite|Lese|Prüfe|Ergebnis|Versuche|Gesamtliste)\b') { return 'Cyan' }
    return $null
}

function Format-WindowsUpdateConsoleError {
    param([AllowEmptyString()][string]$Message)

    if ([string]::IsNullOrWhiteSpace($Message)) { return $Message }
    # Ein Fehlerzähler von null ist ein erfolgreicher Status, keine Meldung.
    if ($Message -match '(?i)^\s*(Fehler|Errors?)\s*:\s*0(?:\D|$)') { return $Message }
    if (Test-WindowsUpdateZeroFailureSummary -Message $Message) { return $Message }
    if ($Message -notmatch '(?i)^\s*(WARNUNG|WARNING|FEHLER\b|ERROR\b|\[WARN\]|\[ERROR\])|^\s*Fehler bei\b|fehlgeschlagen|konnte nicht|UnableToDownload|Access is denied|Zugriff verweigert|Exception|Fehler beim') { return $Message }

    $target = $null
    if ($Message -match "(?i)\b(?:auf|für|bei Server|von Server)\s+(?!dem\b|der\b|den\b|einem\b|einer\b)'?(?<Target>[A-Za-z0-9_.-]+)") {
        $target = $Matches.Target.TrimEnd("'", '!', ':', '.')
    }

    $operation = $null
    if ($Message -match '(?i)\b(?<Operation>WinGet|Winget|Chocolatey|PSWindowsUpdate|Paketmanager|SYSTEM-Update-Suche|Update-Suche|Cache-Bereinigung|Nachinstallationsaufgabe|Linux-Check|Home-Assistant-Check)(?:-Prüfung|-Aktualisierung|-Update)?') {
        $operation = $Matches.Operation
        if ($operation -ieq 'Winget') { $operation = 'WinGet' }
    }

    $prefix = if ($Message -match '(?i)WARNUNG|WARNING') { 'WARNUNG' } else { 'FEHLER' }
    # Warnungen aus einem Unterprozess besitzen teils keinen standardisierten
    # Vorgangs-/Servertext. In diesem Fall den konkreten Hinweis bewahren,
    # statt ihn zu einer roten, inhaltslosen Fehlermeldung zu verkürzen.
    if ($prefix -eq 'WARNUNG' -and -not $operation -and -not $target) { return $Message }
    if ($operation -and $target) { return "$prefix`: $operation auf $target fehlgeschlagen; Details im Log." }
    if ($target) { return "$prefix`: Fehler auf $target; Details im Log." }
    if ($operation) { return "$prefix`: $operation fehlgeschlagen; Details im Log." }

    # Ohne ermittelbaren Vorgang oder Ziel den Originaltext erhalten. Der
    # generische Ersatztext hat die Ursache aus der Konsole entfernt und war
    # in den jeweiligen Unterprotokollen nicht immer wiederzufinden.
    $safeMessage = ($Message -replace '[\r\n\t]+', ' ').Trim()
    $safeMessage = $safeMessage -replace '(?i)(password|passwd|kennwort|passwort|token|secret)(\s*[:=]\s*)\S+', '$1$2[geschwärzt]'
    if ($safeMessage.Length -gt 220) { $safeMessage = $safeMessage.Substring(0, 217) + '...' }
    return $safeMessage
}

function Write-WindowsUpdateConsoleLine {
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string]$Message,
        [string]$ForegroundColor,
        [switch]$IsDebug,
        [switch]$AlreadyFiltered
    )

    $wasTableActive = $script:WindowsUpdateConsoleTableActive
    $wasTableHasRows = $script:WindowsUpdateConsoleTableHasRows
    $wasPackageRowsActive = $script:WindowsUpdateConsolePackageRowsActive
    $show = $AlreadyFiltered -or (Test-WindowsUpdateConsoleMessage -Message $Message -IsDebug:$IsDebug)
    if (-not $show) { return }

    $isTableLine = $Message -match '^\s*ComputerName\s+Status\s+KB\b|^\s*-{3,}(?:\s+-{2,})+|^\s*\S+\s+[A-Za-z-]{7}\s+(?:KB\d+)?(?:\s+\S.*)?$'
    $isPackageRow = $Message -match '^\s{2,}\S+\s*:'
    if (-not [string]::IsNullOrWhiteSpace($Message) -and (($wasTableActive -and -not $script:WindowsUpdateConsoleTableActive -and -not $isTableLine -and $wasTableHasRows) -or ($wasPackageRowsActive -and -not $script:WindowsUpdateConsolePackageRowsActive -and -not $isPackageRow))) {
        Write-Host ''
    }
    if ($wasTableActive -and -not $script:WindowsUpdateConsoleTableActive) { $script:WindowsUpdateConsoleTableHasRows = $false }
    if ([string]::IsNullOrWhiteSpace($Message) -and $script:WindowsUpdateConsoleTableActive) {
        $script:WindowsUpdateConsoleTableActive = $false
        $script:WindowsUpdateConsoleTableHasRows = $false
    }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        $script:WindowsUpdateConsolePackageRowsActive = $false
        $script:WindowsUpdateConsolePackageTableActive = $false
    }

    $displayMessage = if ($IsDebug) { $Message } else { Format-WindowsUpdateConsoleError -Message $Message }
    if ([string]::IsNullOrWhiteSpace($displayMessage)) {
        Write-Host ''
    } elseif ($ForegroundColor) {
        Write-Host $displayMessage -ForegroundColor $ForegroundColor
    } else {
        $color = if ($IsDebug) { 'Cyan' } else { Get-WindowsUpdateConsoleColor -Message $displayMessage }
        if ($color) { Write-Host $displayMessage -ForegroundColor $color } else { Write-Host $displayMessage }
    }

    if ($Message -match '^\s*Ergebnis (der (Update-Suche|Installation)|des Downloads)\s*:' -or
        $Message -match '(?i)(Paketupdates? verfügbar|Paketupdate\(s\) (erkannt und verarbeitet|verfügbar)|\d+ Paketupdates installiert)' -and $Message -notmatch '(?i)keine Paketupdates') {
        Write-Host ''
    }
}

function Test-WindowsUpdateConsoleMessage {
    param(
        [AllowEmptyString()][string]$Message,
        [switch]$IsDebug
    )

    if ($IsDebug) { return $true }
    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $true
    }

    if ($Message -match '(?i)^\s*(Kein automatischer Neustart|Kein Neustartstatus|Get-WURebootStatus auf|Keine zurückgestellten Updates|Zurückgestellte Updates auf .* verfügbar:)') { return $false }

    if ($script:WindowsUpdateConsoleSummaryActive) {
        if ($Message -match '^\s*═+\s*$') {
            $script:WindowsUpdateConsoleSummaryDividerCount++
            if ($script:WindowsUpdateConsoleSummaryDividerCount -ge 2) { $script:WindowsUpdateConsoleSummaryActive = $false }
        }
        return $true
    }
    if ($Message -match '(?i)^\s*UPDATE-(CHECK|DOWNLOAD|INSTALLATION) ZUSAMMENFASSUNG\s*$') {
        $script:WindowsUpdateConsoleSummaryActive = $true
        $script:WindowsUpdateConsoleSummaryDividerCount = 0
        return $true
    }
    if ($script:WindowsUpdateConsoleTableActive) {
        if ($Message -match '^\s*ComputerName\s+Status\s+KB\b' -or $Message -match '^\s*-{3,}(?:\s+-{2,})+') { return $true }
        if ($Message -match '^\s*\S+\s+[A-Za-z-]{7}\s+(?:KB\d+)?(?:\s+\S.*)?$') {
            $script:WindowsUpdateConsoleTableHasRows = $true
            return $true
        }
        $script:WindowsUpdateConsoleTableActive = $false
    }
    if ($script:WindowsUpdateConsolePackageRowsActive) {
        if ($Message -match '^\s{2,}\S+\s*:') { return $true }
        $script:WindowsUpdateConsolePackageRowsActive = $false
    }
    if ($script:WindowsUpdateConsolePackageTableActive) {
        if ($Message -match '^\s*ComputerName\s+Name\s+Id\s+InstalledVersion\s+AvailableVersion\s+Source\s*$' -or
            $Message -match '^\s*-{3,}(?:\s+-{2,})+' -or
            $Message -match '^\s*\S+\s+.+\s{2,}\S+\s+\S+\s+\S+\s+\S+\s*$' -or
            $Message -match '^\s{2,}\S.*$') { return $true }
        $script:WindowsUpdateConsolePackageTableActive = $false
    }

    if ($Message -match '^\s*Ergebnis (der (Update-Suche|Installation)|des Downloads)\s*:') {
        $script:WindowsUpdateConsoleTableActive = $true
        $script:WindowsUpdateConsoleTableHasRows = $false
        return $true
    }
    if ($Message -match '(?i)^\s*(WARNUNG|WARNING|\[WARN\]|\[ERROR\]|FEHLER\b|ERROR\b)|\bfehlgeschlagen\b|\bkonnte nicht\b|aufgetreten!|manuelle Prüfung|manuelle Aktion erforderlich') { return $true }
    if ($Message -match '(?i)^\s*(Fehler|Errors?)\s*:') { return $true }
    if ($Message -match '(?i)^\s*(Starte (Update-(Check|Download|Installation)|Windows-Updates) auf|Verarbeite (Windows|AD|Hypervisor)|Gesamtliste nach Zusammenführung|Check abgeschlossen\.|Download abgeschlossen\.|Installation abgeschlossen\.|E-Mail erfolgreich versendet|Mailkonfigurationstest erfolgreich)') { return $true }
    if ($Message -match '(?i)^\s*(Zurückgestellte Kategorien:|Zurückgestellte KBs:|Nachinstallation aktiviert$)') { return $true }
    if ($Message -match '(?i)keine Paketupdates verfügbar\.') { return $true }
    if ($Message -match '(?i)(Paketupdates? verfügbar|Paketupdate\(s\) (erkannt und verarbeitet|verfügbar)|\d+ Paketupdates installiert|Home-Assistant-Check: .*Update\(s\) verfügbar)') {
        $script:WindowsUpdateConsolePackageRowsActive = $Message -notmatch '(?i)Keine Paketupdates'
        $script:WindowsUpdateConsolePackageTableActive = $Message -notmatch '(?i)Keine Paketupdates'
        return $true
    }
    if ($Message -match '(?i)(Windows-Updates installiert|Updates verfügbar|Nachinstallation auf .* geplant|Neustart(aufgabe)? auf .* geplant|Neustart auf .* verschoben|Linux-(Check|Zusammenfassung)|Linux-Update(-Prüfung)? auf .* abgeschlossen|Linux auf .* (keine Paketupdates|Paketupdates verfügbar|Paketupdates installiert)|Home-Assistant-Check|Home Assistant auf .*(keine Updates|Update\(s\) verfügbar|Update\(s\) installiert))') {
        if ($Message -match '(?i)(Linux auf .* (Paketupdates verfügbar|Paketupdates installiert)|Home Assistant auf .*Update\(s\) (verfügbar|installiert))') { $script:WindowsUpdateConsolePackageRowsActive = $true }
        return $true
    }
    return $false
}

function Write-PSWindowsUpdateModuleLog {
    param([scriptblock]$WriteLog, [string]$Message, [string]$Level = 'INFO')
    if ($WriteLog) { & $WriteLog $Message $Level; return }
    if ($Level -eq 'WARN') { Write-Warning $Message } else { Write-Verbose $Message }
}
