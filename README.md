# Server Updates

Skriptsammlung zur zentralen Aktualisierung von Windows-Servern, Linux-Systemen und Home Assistant. Die Ordnerstruktur muss beim Kopieren vollständig erhalten bleiben.

## Ordnerstruktur

Die direkt ausführbaren Hauptskripte sowie `settings.json` und `default_settings.json` liegen im Stammordner. Fachmodule stehen unter `Module`, Hilfs- und Verteilungsskripte sowie der öffentliche WinRM-Clientschlüssel unter `Komponenten`, diese Dokumentation unter `Dokumentation`. `Logs` und `Sicherungen` werden nur bei Bedarf angelegt, sind in Git ignoriert und gehören nicht als leere Ordner ins Repository. Der öffentliche Schlüssel liegt lokal unter `Komponenten\WinRM-ClientCert.cer`; der private Schlüssel verbleibt im Zertifikatsspeicher des Verwaltungsrechners.

Die Hauptskripte laden gemeinsame Funktionen über `Module\WindowsUpdate.Common.psm1`. Dieses Kompatibilitätsmodul bindet die nach Aufgaben gegliederten `WindowsUpdate.*.psm1`-Module ein. Check-Cachepflege, Download-Reportaufbau, Installationsprüfungen, Setup-/Zertifikatsdiagnosen und Verlaufsdarstellung liegen in den jeweiligen Fachmodulen; die Hauptskripte behalten die Ablaufsteuerung. Fachmodule importieren einander nicht direkt. Die Linux- und Home-Assistant-Logik liegt in `Module\Linux.Updates.psm1` und `Module\HomeAssistant.Updates.psm1`; die bisherigen Skriptpfade unter `Komponenten` bleiben als schlanke, rückwärtskompatible Startdateien erhalten.

## Schnellstart

1. Skripte gemeinsam in einem Verzeichnis ablegen.
2. Kundeneinstellungen in `settings.json` eintragen; `default_settings.json` liefert Standardwerte.
3. Einmalig `Verteilung_WindowsUpdateAdmConfig.ps1` für die Windows-Remoting-Einrichtung ausführen.
4. `Check-ServersUpdates.ps1` prüft verfügbare Updates.
5. Optional lädt `Download-ServersUpdates.ps1` die Updates vor.
6. `Install-ServersUpdates.ps1` installiert Updates im geplanten Wartungsfenster.
7. `Updateverlauf auslesen.ps1` erstellt den zentralen Verlaufsbericht und versendet ihn per Mail.

Beim PSWindowsUpdate-Check werden NuGet und PSWindowsUpdate auf dem Verwaltungsrechner und den Windows-Zielen geprüft und nur bei fehlender oder veralteter Version aktualisiert. Für PSWindowsUpdate und Microsoft.WinGet.Client wird vor einem Paketdownload die installierte Version mit PSGallery verglichen; aktuelle Remote-Module werden nicht übertragen. Ein bereitgestellter NuGet-Provider wird erst nach dem Versionsvergleich kopiert und importiert.
Das gemeinsame Modul beschafft benötigte PSWindowsUpdate- und Microsoft.WinGet.Client-Pakete samt Abhängigkeiten zuerst online auf dem Verwaltungsrechner und überträgt sie temporär offline an die Ziele. Nur wenn ein Onlineabruf fehlschlägt, greift es auf Offlinepakete und zuletzt lokal vorhandene Versionen zurück.
PowerShell 7 prüft zusätzlich PackageManagement auf Updates; auf Remotezielen erfolgt das nur, wenn PowerShell 7 installiert ist.
Bei der WindowsUpdateAdm-Verteilung vergleicht der Verwaltungsserver zuerst auf jedem Ziel die installierten Versionen von PSWindowsUpdate, optional Microsoft.WinGet.Client und NuGet mit dem aktuellen Stand. Nur fehlende oder veraltete Pakete werden zentral als Offlinepakete vorbereitet und an dieses Ziel übertragen. Sind alle Versionen aktuell, wird kein Paketpayload erstellt oder übertragen. Die Ziele benötigen für bereitgestellte Pakete keinen Zugriff auf NuGet oder PSGallery; temporäre Paketablagen werden nach der Verteilung entfernt.
`Save-Module` lädt Modulabhängigkeiten selbstständig. Das Verteilungsskript verwendet dafür keinen separaten `-IncludeDependencies`-Parameter und protokolliert bei einem fehlgeschlagenen Paketabruf die konkrete Ursache.

## Wichtig

- Die Skripte aktualisieren beim Start automatisch geänderte Programmdateien aus dem öffentlichen Branch `main` (`UpdateSettings.AutoUpdateScripts`, Standard: `true`). Bei `false` bleiben automatische Updates aus; `Komponenten\Update-ServerUpdateScripts.ps1` lässt sich weiterhin manuell starten. Git muss auf den Zielsystemen nicht installiert sein.
- Kundeneinstellungen, Zertifikate und Laufzeitdaten werden nicht aus GitHub überschrieben. Fehlende Standardwerte werden in bestehende Settings ergänzt und vorher gesichert.
- Linux- und Home-Assistant-Skripte werden nur geladen, wenn sie in den Settings konfiguriert sind.
- Mailversand lässt sich mit `Check-ServersUpdates.ps1 -TestMail` separat prüfen.
- Der zentrale Updateverlaufsbericht nutzt die konfigurierten Windows-, Linux- und Home-Assistant-Ziele; Details und Grenzen der jeweiligen Historienquellen stehen in der Dokumentation.
- Die Verteilung zeigt farbige Einrichtungsschritte, prüft bei Linux und Home Assistant nur SSH-Schlüssel und Verbindung und zählt alle Zielsysteme getrennt und gemeinsam. Zielarten mit Anzahl null werden in der Kopfzeile ausgeblendet. SSH-Rückfragen bleiben bei Check, Download, Install und Verteilung sichtbar; Details stehen gemäß `WriteLogFile` und `KeepLogFiles` im Log.
- Check, Download und Install trennen Ergebnisblöcke je Ziel mit Leerzeilen. Zusammenfassungen nennen nur Systemarten, für die Ziele vorhanden sind.
- Der Check prüft WindowsUpdateAdm-Versionen, Linux-SSH-/sudo-Einrichtungen und den Home-Assistant-SSH-Zugang. Fehlende oder veraltete Voraussetzungen werden in Konsole und Check-Mail als Handlungsbedarf gemeldet.
- Bei Nicht-AD-Zielen erkennt die Verteilung bestehende WinRM-Zertifikatszuordnungen auch dann, wenn Windows ihre Schlüssel nur im WSMan-Attribut `Keys` liefert. Scheitert die Zertifikatsanmeldung, wird die Zuordnung anhand der einmalig eingegebenen lokalen Administrator-Anmeldedaten erneuert.
- Bei WinRM über HTTPS prüft die Verteilung zusätzlich die HTTP.sys-Bindung auf Port 5986 und aktiviert nötigenfalls die Clientzertifikataushandlung. Die Änderung erhält das gebundene Zertifikat und dessen App-ID; eine erhöhte Bereitstellungsversion fordert die erneute Verteilung an.
- Die Verteilung übergibt die zentral ermittelte WindowsUpdateAdm-Version explizit an das Setup und verwendet sie auch für Endpunktprüfung und Erfolgsmeldung.
- Nicht konfigurierte Linux- und Home-Assistant-Ziele werden still ausgelassen und nicht als übersprungen ausgegeben.
- Zurückgestellte Windows-Updates und Neustart-Wartungsfenster werden über `UpdateSettings` konfiguriert.
- Alle Skripte zeigen Ziele, Updates und Aktionen knapp, farbig und mit Leerzeilen getrennt. Installierte Paketmanager melden auch dann ihren Status, wenn keine Updates verfügbar sind; Fehlerdetails stehen im Log.
- WinGet-Suche und Updates verwenden zuerst `Microsoft.WinGet.Client` unter Windows PowerShell 5.1; bei Modulfehlern fällt Check und Installation auf `winget.exe` zurück.
- Der WinGet-Check berücksichtigt zusätzlich benutzerbezogene Updates angemeldeter interaktiver Benutzer, etwa VS-Code-User-Installationen, und markiert sie mit dem Benutzerkonto. Diese Zusatzabfrage installiert nichts.
- WinGet wird auf Windows-Servern mit einem Betriebssystem-Build vor 17763 (älter als Server 2019) ausgelassen; die Erkennung nutzt den Systemtyp und Build, nicht eine Jahreszahl im Produktnamen. Windows Update und Chocolatey laufen weiter.
- Bei einer leeren WinGet-Check-Suche wird der Quellenzustand einmal geprüft: Standardquellen werden bei Bedarf zurückgesetzt und `Microsoft.Winget.Source` nur registriert, wenn es fehlt oder das heruntergeladene Paket neuer ist. Eine danach weiterhin leere, fehlerfreie Suche gilt als „keine Updates“. Sie bleibt im Protokoll, erscheint aber nicht extra in der Konsole. Scheitert eine nötige Registrierung oder die Wiederholung, wird die Suche als Fehler gemeldet. Kundeneigene Quellen bleiben unangetastet.
- Die CLI-Abfrage ist auf 3 Minuten 30 Sekunden begrenzt; das gesamte WinGet-Prüffenster bleibt bei fünf Minuten. Paketupdates installiert der Fallback einzeln und still.
- Meldet WinGet neben einer Quellenwarnung trotzdem Paketupdates, zeigt und zählt der Check diese Updates zusätzlich zur Warnung.

## Ausführliche Dokumentation

Einstellungen, Migration, Skriptoptionen, Remoting, WinGet, Nachinstallationen, Protokolle und Fehlersuche stehen in [Dokumentation.md](Dokumentation/Dokumentation.md).
