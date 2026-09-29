# Server Updates

Skriptsammlung zur zentralen Aktualisierung von Windows-Servern, Linux-Systemen und Home Assistant.

## Schnellstart

1. Skripte gemeinsam in einem Verzeichnis ablegen.
2. Kundeneinstellungen in `settings.json` eintragen; `default_settings.json` liefert Standardwerte.
3. Einmalig `Verteilung_WindowsUpdateAdmConfig.ps1` für die Windows-Remoting-Einrichtung ausführen.
4. `Check-ServersUpdates.ps1` prüft verfügbare Updates.
5. Optional lädt `Download-ServersUpdates.ps1` die Updates vor.
6. `Install-ServersUpdates.ps1` installiert Updates im geplanten Wartungsfenster.

## Wichtig

- Die Skripte aktualisieren beim Start automatisch geänderte Programmdateien aus dem öffentlichen Branch `main`. Git muss auf den Zielsystemen nicht installiert sein.
- Kundeneinstellungen, Zertifikate und Laufzeitdaten werden nicht aus GitHub überschrieben. Fehlende Standardwerte werden in bestehende Settings ergänzt und vorher gesichert.
- Linux- und Home-Assistant-Skripte werden nur geladen, wenn sie in den Settings konfiguriert sind.
- Mailversand lässt sich mit `Check-ServersUpdates.ps1 -TestMail` separat prüfen.
- Zurückgestellte Windows-Updates und Neustart-Wartungsfenster werden über `UpdateSettings` konfiguriert.
- Die Konsole zeigt vor allem Ziel, Ergebnis und wichtige Hinweise. Erfolge sind grün, Warnungen gelb und Fehler rot; das Log enthält weiterhin alle Details.

## Ausführliche Dokumentation

Einstellungen, Migration, Skriptoptionen, Remoting, WinGet, Nachinstallationen, Protokolle und Fehlersuche stehen in [Dokumentation.md](Dokumentation.md).
