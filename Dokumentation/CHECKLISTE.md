# Offene Checkliste

- [ ] Nachinstallationsaufgabe praktisch prüfen: Neustart, Wartungsfenster, Wiederholungen bis zum Abschluss und genau eine Abschlussmail.
- [ ] WinGet-Kompatibilität praktisch prüfen: Auf einem Windows-Server vor Server 2019 (einschließlich SBS) muss WinGet übersprungen werden, während Windows Update und Chocolatey weiterlaufen; auf Server 2019 oder neuer muss WinGet wie konfiguriert funktionieren.
- [ ] Check und Installation auf einem Ziel ohne NuGet-/PSGallery-Zugriff prüfen: aktuelle Module und NuGet-Provider zuerst zentral online beschaffen und offline übertragen; erst bei fehlendem Onlineabruf Offline-Fallback verwenden und Updateabfragen ohne rohe PackageManagement-Warnungen fortsetzen.
- [ ] Modulpflege bei veralteten Versionen praktisch prüfen: Eine ältere PSWindowsUpdate-, Microsoft.WinGet.Client- oder NuGet-Version muss erkannt, zentral beschafft und auf dem Ziel aktualisiert werden.
- [ ] Benutzerbezogene WinGet-Installation mit mehreren Updates praktisch prüfen: Das Gesamtzeitlimit muss 15 Minuten je erkanntem Paket betragen, höchstens 90 Minuten; Ergebnisse und Fehler aller Paketinstallationen müssen nachvollziehbar protokolliert werden.
