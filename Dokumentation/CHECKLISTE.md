# Noch offene Prüfpunkte

Die ursprünglichen Nummern bleiben erhalten, damit die Punkte mit den bisherigen Testnotizen abgeglichen werden können.

- [ ] **2. Nachinstallationsaufgabe:** Neustart, Wartungsfenster, Wiederholungen bis zum Abschluss und genau eine Abschlussmail praktisch prüfen.
- [ ] **3. WinGet auf älteren Servern:** Auf Windows-Servern vor Server 2019 einschließlich SBS muss WinGet übersprungen werden; Windows Update und Chocolatey müssen weiterlaufen.
- [ ] **6. NuGet-/PSGallery-Ausfall:** Check und Installation ohne NuGet-/PSGallery-Zugriff praktisch prüfen. Pakete und NuGet-Provider sollen zuerst zentral online beschafft und offline übertragen werden; der reine Offline-Fallback greift erst, wenn der Onlineabruf scheitert. Keine interaktiven NuGet-Abfragen oder rohen PackageManagement-Warnungen.
- [ ] **10. Mehrere Benutzerupdates:** Bei mehreren erkannten Benutzer-WinGet-Paketen die Laufzeitregel praktisch prüfen: 15 Minuten je Paket, höchstens 90 Minuten, mit nachvollziehbarem Protokoll der Ergebnisse und Fehler.
