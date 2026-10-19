# Offene Checkliste

- [ ] Nachinstallationsaufgabe nach Neustart und Wartungsfenster praktisch prüfen: wiederholte Ausführung bis zum Abschluss (spätestens nach fünf Tagen Ende), Neustartbedarf korrekt erkennen und beachten, Updates nur im Wartungsfenster installieren sowie genau eine Abschlussmail senden (Erfolg oder endgültiger Fehler).
- [ ] WinGet-Kompatibilität praktisch prüfen: Auf einem Windows-Server vor Server 2019 (einschließlich SBS) muss WinGet übersprungen werden, während Windows Update und Chocolatey weiterlaufen; auf Server 2019 oder neuer muss WinGet wie konfiguriert funktionieren.
- [ ] HTTP.sys-Clientzertifikataushandlung praktisch über die Verteilung prüfen: Auf einem Nicht-AD-Ziel mit WinRM HTTPS muss Port 5986 nach der Einrichtung `Clientzertifikat aushandeln: Enabled` zeigen und die Zertifikatsverbindung erfolgreich sein.
- [ ] PSGallery-Offlinepaketbereitstellung nach Korrektur von `Save-Module` prüfen: Die Verteilung muss die Module online samt Abhängigkeiten zwischenspeichern und darf den Offline-Fallback-Hinweis bei erfolgreichem Abruf nicht ausgeben.
- [ ] Bei der nächsten WindowsUpdateAdm-Verteilung prüfen, dass die übergebene zentrale Bereitstellungsversion (aktuell 2) im Setup, im Endpunkttest und im Check übereinstimmt.
