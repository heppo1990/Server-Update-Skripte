# Offene Checkliste

## WinGet auf Windows Server 2019 und 2022

- [x] Auf Windows Server 2019 und 2022 vor der Winget-Abfrage prüfen, ob `winget --version` im verwendeten Ausführungskontext erfolgreich ist.
- [x] Wenn WinGet fehlt oder nicht funktioniert, das Installationsskript [asheroto/winget-install](https://github.com/asheroto/winget-install) verwenden.
  - [x] Ist `winget-install` bereits vorhanden: das Skript unter Windows PowerShell 5.1 mit `-UpdateSelf` aktualisieren und WinGet danach mit `-Force` reparieren.
  - [x] Ist `winget-install` nicht vorhanden: aus PSGallery installieren; bei Fehler die signierte aktuelle GitHub-Release-Datei verwenden.
- [x] Nach der Reparatur `winget --version` im selben Ausführungskontext erneut prüfen und Ergebnis protokollieren.

## Konkrete Updates in der Nachinstallationsplanung

- [x] Zurückgestellte Updates in der Nachinstallationsplanung und im Installationsbericht im selben Tabellenformat wie in Check-, Download- und Installationsskript anzeigen (`ComputerName`, `Status`, `KB`, `Size`, `Title`). Kategorien werden einzeln aufgelöst; doppelte Update-Zeilen werden in Tabelle und Anzahl zusammengeführt.
