# Offene Checkliste

## WinGet auf Windows Server 2019 und 2022

- [x] Auf Windows Server 2019 und 2022 vor der Winget-Abfrage prüfen, ob `winget --version` im verwendeten Ausführungskontext erfolgreich ist.
- [x] Wenn WinGet fehlt oder nicht funktioniert, das Installationsskript [asheroto/winget-install](https://github.com/asheroto/winget-install) verwenden.
  - [x] Ist `winget-install` bereits vorhanden: das Skript unter Windows PowerShell 5.1 mit `-UpdateSelf` aktualisieren und WinGet danach mit `-Force` reparieren.
  - [x] Ist `winget-install` nicht vorhanden: aus PSGallery installieren; bei Fehler die signierte aktuelle GitHub-Release-Datei verwenden.
- [x] Nach der Reparatur `winget --version` im selben Ausführungskontext erneut prüfen und Ergebnis protokollieren.
- [x] Fehlt WinGet oder schlägt die WinGet-Prüfung für das PS7-Update fehl, WinGet auf Windows Server 2019/2022 unabhängig von AD-Mitgliedschaft mit `winget-install` reparieren und die PS7-Prüfung wiederholen.
- [x] Chocolatey nur dann für das PS7-Update verwenden, wenn es bereits installiert ist; Chocolatey nicht automatisch nachinstallieren.
- [x] Bei einem Fehler beim Durchsuchen der WinGet-Quelle `winget` diese Quelle einmal aktualisieren und die Paketabfrage wiederholen.

## Konkrete Updates in der Nachinstallationsplanung

- [x] Zurückgestellte Updates in der Nachinstallationsplanung und im Installationsbericht im selben Tabellenformat wie in Check-, Download- und Installationsskript anzeigen (`ComputerName`, `Status`, `KB`, `Size`, `Title`). Verschachtelte Remoting-Ergebnisse werden aufgefächert, leere Zeilen verworfen und doppelte Update-Zeilen zusammengeführt. Die Anzahl geplanter Updates wird getrennt von bereits installierten Updates ausgewiesen.
- [x] Optionale Metadatenmarker bei normalen Updateobjekten sicher auswerten, damit `MetadataMissing` unter aktiviertem `StrictMode` keinen falschen Prüfungsfehler auslöst.
- [x] Bei nicht auflösbaren Nachinstallations-Ergebnissen Typ und verfügbare Eigenschaftsnamen protokollieren, damit abweichende Rückgabeobjekte eingegrenzt werden können.
