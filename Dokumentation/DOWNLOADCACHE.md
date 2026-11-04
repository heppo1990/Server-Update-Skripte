# Downloadcache und Überwachung

Der gemeinsame Baustein `Module/WindowsUpdate.DownloadCache.psm1` unterstützt Windows PowerShell 5.1 und PowerShell 7. Er wird durch Common eingebunden. Die autonome WinGet-Wartungsdatei und der Remote-Paketworker enthalten eine Kopie derselben Downloadfunktion, damit der bestehende JEA-Endpunkt ohne neue allgemeine Datei- oder Importbefehle weiterarbeiten kann. Bei Änderungen müssen die eingebetteten Funktionen synchron bleiben.

## Bereits eingebunden

- Bei einer tatsächlich ausgeführten WinGet-Einrichtung lädt der Verwaltungsserver das aktuelle App-Installer-Bundle und die Abhängigkeiten zentral. Die Version wird dynamisch über die Release-Metadaten oder die feste GitHub-Releaseweiterleitung ermittelt.
- Vollständige Archive bleiben unter `%ProgramData%\WindowsUpdateAdm\DownloadCache\<URL-SHA256>\` erhalten. Ein Eintrag enthält `payload.bin` und `payload.json`. Vor Wiederverwendung werden Dateigröße und SHA256 erneut geprüft; vorhandene Release-Digests werden zusätzlich erzwungen.
- Die Einrichtung prüft den Zielcache und überträgt nur fehlende oder abweichende Archive. Nach der Übertragung werden Größe und SHA256 am Ziel erneut geprüft. Es entstehen keine zusätzlichen JEA-Freigaben.
- Die portable WinGet-Reparatur verwendet denselben Cache am Ziel. Die Archive bleiben nach dem Entpacken erhalten. Vor Ausführung werden weiterhin die Microsoft-Signaturen der CLI und der kopierten Abhängigkeits-DLLs geprüft.
- Release-Metadaten werden nach erfolgreicher Beschaffung gespeichert. Scheitern die Online-Metadatenabfragen, kann die zentrale Beschaffung die gespeicherten Metadaten und gültigen Archive verwenden. Innerhalb eines Modulaufrufs wird der Onlineabgleich höchstens 15 Minuten zwischengespeichert; die lokalen Dateien werden trotzdem erneut geprüft.

## Downloadverhalten

Der Downloader verwendet einen HTTP-Datenstrom ohne die langsame PS5-Fortschrittsanzeige. Er protokolliert Zeitmarken für Verbindungsaufbau, erwartete Größe, Fortschritt in Zehnsekundenabständen, Übertragungsrate, Abschluss und Prüfsummenprüfung. Die angegebenen Bytes sind empfangene Nutzdaten. Zeitmarken bleiben zusätzlich in `progress.log` im jeweiligen Cacheordner erhalten und können während des Laufs gelesen werden; ab 1 MiB wird eine vorherige Logdatei aufbewahrt.

Ein Download wird nach 120 Sekunden ohne neue Daten beendet. Zusätzlich gilt für jedes WinGet-Archiv eine absolute Grenze von 1200 Sekunden. Größenüberschreitungen, widersprüchliche HTTP-/Releasegrößen, leere oder unvollständige Antworten und falsche Prüfsummen werden abgelehnt. Die portable Reparaturstufe erhält 2700 Sekunden, der äußere Reparaturaufruf maximal 2820 Sekunden innerhalb eines auf 48 Minuten erweiterten Reparaturbudgets. Diese Grenzen berücksichtigen zwei Downloads und die anschließende Verarbeitung; vorhandene Dateien überspringen den Netztransfer.

Eine exklusive Dateisperre verhindert paralleles Beschaffen desselben Artefakts. Downloads werden zunächst als `payload.part` geschrieben und erst nach erfolgreichem Abschluss übernommen. Teilstände gelten nie als gültiger Cache; bei einem neuen Versuch werden sie derzeit neu begonnen. Automatisches HTTP-Resume ist noch nicht implementiert.

## Weiterer Umbau

Die zentrale Nachlieferung neuer Archive an bereits konfigurierte JEA-Ziele im normalen Check-/Download-/Install-Lauf ist noch offen. Aktuell gelangen zentrale Archive während einer tatsächlichen Einrichtung zum Ziel; bis dahin bleibt der überwachte Ziel-Download als Rückfallweg erhalten. Skripte, NuGet, Modularchive und weitere Reparaturwerkzeuge sind noch nicht vollständig auf diesen Baustein umgestellt. Eine umfassende Aussage „nur der Verwaltungsserver lädt alles“ gilt daher noch nicht.

## Prüfung

Unter Windows PowerShell 5.1 mit lokalem HTTP-Testserver geprüft: Erstdownload, Cachetreffer, beschädigter Cache, abweichender SHA256, falsche HTTP-Größe, zu großer Datenstrom, Stillstand und langsamer aktiver Datenstrom. Reale GitHub-Übertragung, Verteilung und anschließende WinGet-Reparatur mit vorverteilten Archiven müssen auf echten Zielen bestätigt werden.
