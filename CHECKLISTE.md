# Checkliste

- [x] Check, Download und Install zählen Windows-, Linux- und Home-Assistant-Ziele gemeinsam; nicht konfigurierte Typen bleiben ausgeblendet.
- [x] SYSTEM-Update-Suche wiederholt leere Ergebnisse mit einer neuen Aufgabe. Nur erfolgreich abgeschlossene, erneut leere Suchen gelten als „keine Updates“; Aufgabenfehler bleiben Fehler.
- [x] WinGet-Pakete werden in Check und Install als Tabelle mit Name, ID, installierter und verfügbarer Version sowie Quelle ausgegeben.
- [x] WinGet-Abfragen bestätigen Quellen- und Paketvereinbarungen automatisch; abgefangene Vereinbarungstexte werden protokolliert und nicht als Paketzeilen gezählt.
- [x] Chocolatey-Pakete werden in Check und Install als Tabelle mit installierter und verfügbarer Version ausgegeben. Download führt keine Paketmanager-Abfrage aus.
- [x] WinGet- und Chocolatey-Ergebnisse erscheinen in Check- und Install-Mails als HTML-Tabellen. Download enthält keine Paketmanager-Ergebnisse.

## Offene Nacharbeiten

- [x] Erfolgsmeldung „WinGet-Abfrage war erfolgreich; keine Paketupdates verfügbar. Quellenreset wegen des 24-Stunden-Limits übersprungen.“ aus der Konsolenausgabe entfernen; ausschließlich im Log protokollieren.
- [x] Erfolgsmeldung „WinGet-Abfrage nach erfolgreich abgeschlossenem Quellenreset war erfolgreich; keine Paketupdates verfügbar. WinGet nach Quellenreset in neuer Sitzung erneut geprüft.“ aus der Konsolenausgabe entfernen; ausschließlich im Log protokollieren.
