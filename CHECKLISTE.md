# Offene Checkliste

## WinGet auf Windows Server 2019

- [ ] Auf Windows Server 2019 zu Beginn prüfen, ob `winget` vorhanden und ausführbar ist.
- [ ] Wenn WinGet fehlt oder nicht funktioniert, das Installationsskript [asheroto/winget-install](https://github.com/asheroto/winget-install) verwenden.
  - [ ] Ist `winget-install` bereits vorhanden: das Skript mit `-UpdateSelf` aktualisieren und anschließend WinGet unter Windows PowerShell 5.1 mit `-Force` neu installieren beziehungsweise reparieren.
  - [ ] Ist `winget-install` nicht vorhanden: das Skript installieren und damit WinGet einrichten.
- [ ] Abschließend prüfen, dass `winget` im für die Update-Skripte verwendeten Ausführungskontext funktioniert.
