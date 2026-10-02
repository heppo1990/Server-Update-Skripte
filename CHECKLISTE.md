# Offene Checkliste

- [x] Automatische Skriptupdates über `UpdateSettings.AutoUpdateScripts` steuerbar; Standard `true`, direkte manuelle Ausführung des Updaters bleibt möglich.

## WinGet auf Windows Server 2019 und 2022

- [x] WinGet-Suche und Installation zuerst über `Microsoft.WinGet.Client` unter Windows PowerShell 5.1 ausführen; bei Modulfehlern `winget.exe` auf dem jeweiligen Zielsystem verwenden.
- [x] CLI-Fallback in Check und Installation mit Quellen- und Paketvereinbarungen sowie stiller Einzelinstallation verwenden; CLI-Suche nach 3 Minuten 30 Sekunden abbrechen.
- [x] Standardquellen nach leerer Modulsuche oder Quellenfehler mit `Reset-WinGetSource -All` zurücksetzen; eine leere CLI-Fallback-Suche löst keinen Reset aus.
- [x] Unbekannte kundeneigene Quellen am Namen erkennen und einen vollständigen Reset in diesem Fall überspringen; keine Quell-URLs in Meldungen ausgeben.
- [x] Chocolatey nur dann für das PS7-Update verwenden, wenn es bereits installiert ist; Chocolatey nicht automatisch nachinstallieren.
- [x] Bei einer fehlerhaften WinGet-Quelle die Standardquellen einmal per Modul zurücksetzen und die Paketabfrage wiederholen.
- [x] Alte `Mailsettings`-Bereiche und `SendMail` in allen vorhandenen allgemeinen und skriptspezifischen Settings-Dateien sichern und anhand des Dateinamens dem aktuellen Mail-Schema zuordnen; alte Betreffe verwerfen und aktuelle Standardbetreffe ergänzen.

## Konkrete Updates in der Nachinstallationsplanung

- [x] Zurückgestellte Updates in der Nachinstallationsplanung und im Installationsbericht im selben Tabellenformat wie in Check-, Download- und Installationsskript anzeigen (`ComputerName`, `Status`, `KB`, `Size`, `Title`). Verschachtelte Remoting-Ergebnisse werden aufgefächert, leere Zeilen verworfen und doppelte Update-Zeilen zusammengeführt. Die Anzahl geplanter Updates wird getrennt von bereits installierten Updates ausgewiesen.
- [x] Optionale Metadatenmarker bei normalen Updateobjekten sicher auswerten, damit `MetadataMissing` unter aktiviertem `StrictMode` keinen falschen Prüfungsfehler auslöst.
- [x] Bei nicht auflösbaren Nachinstallations-Ergebnissen Typ und verfügbare Eigenschaftsnamen protokollieren, damit abweichende Rückgabeobjekte eingegrenzt werden können.
- [x] Redundante INFO- und SYSTEM-Aufgabenmeldungen bei Windows-Update-Check, Download und Installation reduzieren; die konkrete Aktion bleibt durch das Einstiegsskript angekündigt.
