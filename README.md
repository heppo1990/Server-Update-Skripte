# Server Updates

Skriptsammlung zur zentralen Aktualisierung von Windows-Servern, Linux-Systemen und Home Assistant.

## Schnellstart

1. Skripte gemeinsam in einem Verzeichnis ablegen.
2. Kundeneinstellungen in `settings.json` eintragen; `default_settings.json` liefert Standardwerte.
3. Einmalig `Verteilung_WindowsUpdateAdmConfig.ps1` für die Windows-Remoting-Einrichtung ausführen.
4. `Check-ServersUpdates.ps1` prüft verfügbare Updates.
5. Optional lädt `Download-ServersUpdates.ps1` die Updates vor.
6. `Install-ServersUpdates.ps1` installiert Updates im geplanten Wartungsfenster.

Beim PSWindowsUpdate-Check werden NuGet und PSWindowsUpdate auf dem Verwaltungsrechner und den Windows-Zielen geprüft und bei Bedarf aktualisiert.

## Wichtig

- Die Skripte aktualisieren beim Start automatisch geänderte Programmdateien aus dem öffentlichen Branch `main`. Git muss auf den Zielsystemen nicht installiert sein.
- Kundeneinstellungen, Zertifikate und Laufzeitdaten werden nicht aus GitHub überschrieben. Fehlende Standardwerte werden in bestehende Settings ergänzt und vorher gesichert.
- Linux- und Home-Assistant-Skripte werden nur geladen, wenn sie in den Settings konfiguriert sind.
- Mailversand lässt sich mit `Check-ServersUpdates.ps1 -TestMail` separat prüfen.
- Die Verteilung zeigt farbige Einrichtungsschritte, prüft bei Linux und Home Assistant nur SSH-Schlüssel und Verbindung und zählt alle Zielsysteme getrennt und gemeinsam. Zielarten mit Anzahl null werden in der Kopfzeile ausgeblendet. SSH-Rückfragen bleiben bei Check, Download, Install und Verteilung sichtbar; Details stehen gemäß `WriteLogFile` und `KeepLogFiles` im Log.
- Check, Download und Install trennen Ergebnisblöcke je Ziel mit Leerzeilen. Zusammenfassungen nennen nur Systemarten, für die Ziele vorhanden sind.
- Nicht konfigurierte Linux- und Home-Assistant-Ziele werden still ausgelassen und nicht als übersprungen ausgegeben.
- Zurückgestellte Windows-Updates und Neustart-Wartungsfenster werden über `UpdateSettings` konfiguriert.
- Alle Skripte zeigen Ziele, Updates und Aktionen knapp, farbig und mit Leerzeilen getrennt. Installierte Paketmanager melden auch dann ihren Status, wenn keine Updates verfügbar sind; Fehlerdetails stehen im Log.

## Ausführliche Dokumentation

Einstellungen, Migration, Skriptoptionen, Remoting, WinGet, Nachinstallationen, Protokolle und Fehlersuche stehen in [Dokumentation.md](Dokumentation.md).
