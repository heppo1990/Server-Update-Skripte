# Noch offene Prüfpunkte

- [ ] **1. NuGet-/PSGallery-Ausfall:** Check und Installation ohne NuGet-/PSGallery-Zugriff praktisch prüfen. Pakete und NuGet-Provider sollen zuerst zentral online beschafft und offline übertragen werden; der reine Offline-Fallback greift erst, wenn der Onlineabruf scheitert. Keine interaktiven NuGet-Abfragen oder rohen PackageManagement-Warnungen.
- [ ] **2. Mehrere Benutzerupdates:** Bei mehreren erkannten Benutzer-WinGet-Paketen die Laufzeitregel praktisch prüfen: 15 Minuten je Paket, höchstens 90 Minuten, mit nachvollziehbarem Protokoll der Ergebnisse und Fehler.
- [ ] **3. WinGet auf SRVTS01 und SRVSQL:** Auf SRVTS01 schlägt die Remote-Registrierung des Quellenpakets mit `0x80070005` fehl; die AppX-Ereignisse zur ActivityID aus dem Checklog auswerten und die Ursache beheben. Auf SRVSQL die korrigierte Erkennung der WinGet-Pin-Hinweiszeile mit einem neuen Check verifizieren; sie darf nicht als Paketupdate gezählt werden.
- [ ] **4. WinRM-Wiederholungsprüfung:** Bei einem kurzzeitigen Verbindungsproblem prüfen, dass Check, Download und Installation bis zu drei kurze Portversuche ausführen und erreichbare Ziele anschließend nicht überspringen.
