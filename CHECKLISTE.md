# Offene Checkliste

## WinGet auf Windows Server 2019 und 2022

- [ ] Auf Windows Server 2019 und 2022 zu Beginn prüfen, ob `winget` vorhanden und ausführbar ist.
- [ ] Wenn WinGet fehlt oder nicht funktioniert, das Installationsskript [asheroto/winget-install](https://github.com/asheroto/winget-install) verwenden.
  - [ ] Ist `winget-install` bereits vorhanden: das Skript mit `-UpdateSelf` aktualisieren und anschließend WinGet unter Windows PowerShell 5.1 mit `-Force` neu installieren beziehungsweise reparieren.
  - [ ] Ist `winget-install` nicht vorhanden: das Skript installieren und damit WinGet einrichten.
- [ ] Abschließend prüfen, dass `winget` im für die Update-Skripte verwendeten Ausführungskontext funktioniert.

## Konkrete Updates in der Nachinstallationsplanung

- [x] Zurückgestellte Updates in der Nachinstallationsplanung und im Installationsbericht im selben Tabellenformat wie in Check-, Download- und Installationsskript anzeigen (`ComputerName`, `Status`, `KB`, `Size`, `Title`). Kategorien werden einzeln aufgelöst; doppelte Update-Zeilen werden in Tabelle und Anzahl zusammengeführt.
