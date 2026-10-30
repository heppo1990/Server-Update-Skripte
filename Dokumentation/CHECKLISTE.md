# Noch offene Prüfpunkte

Validierungsregel: Es zählen nur Läufe mit aktuellem Skriptstand. Ein erfolgreicher Lauf auf einem beliebigen passenden System reicht je Prüfpunkt; tritt ein Fehler erneut auf, wird er zuerst behoben.

Modulregel: Neue, fachlich abgegrenzte Funktionen kommen in thematische Module. Fachmodule importieren einander nicht direkt; `WindowsUpdate.Common.psm1` bindet sie gemeinsam ein. Der GitHub-Updater bleibt bewusst eigenständig und ohne Modulabhängigkeit, damit er auf alten oder leeren Installationen zuerst starten und die Moduldateien nachladen kann.

Bereits passend modularisiert: Linux- und Home-Assistant-Updatefunktionen liegen in eigenen Fachmodulen; ihre kurzen Komponenten-Einstiegsskripte benötigen derzeit keine weitere Aufteilung.

Die Codeanpassungen für alle folgenden Punkte sind umgesetzt. Offen sind nur noch die praktischen Bestätigungen:

- [ ] **1. HOCHSTE PRIORITÄT – WinRM-HTTPS-Firewall:** Auf einem Ziel TCP 5986 aus dem Verwaltungsnetz verbinden; prüfen, dass nur die erwarteten Verwaltungsserveradressen zugelassen werden und zusätzliche breite Regeln die Verteilung korrekt stoppen.
- [ ] **2. HOCHSTE PRIORITÄT – Remote-UAC:** Auf einem unterstützten Nicht-AD-Ziel die Zertifikatsverbindung samt JEA-Updatefunktion bestätigen; auf Server 2016/2019 im Kompatibilitätsmodus prüfen, dass die Ausnahme nur dort gesetzt wird.
- [ ] **3. HOCHSTE PRIORITÄT – JEA und Clientzertifikat:** Verteilung auf einem bestehenden Nicht-AD-Ziel ausführen. Prüfen, dass ein altes Wildcard-Mapping einmalig mit Bootstrap-Anmeldedaten migriert wird, neue Systeme nur `WindowsUpdateAdm` zulassen, Server 2016/2019 zusätzlich nur den für SYSTEM-Aufgaben benötigten `Microsoft.PowerShell`-URI zulassen, JEA im eingeschränkten Sprachmodus funktioniert und Check/Download/Installation weiterlaufen.
- [ ] **4. NuGet-/PSGallery:** Onlineermittlung der aktuellen NuGet-Provider-Version samt Abhängigkeiten und Offline-Fallback anhand eines Verteilungslaufs bestätigen.
- [ ] **5. Mehrere Benutzerupdates:** Bei mehreren erkannten Benutzer-WinGet-Paketen die Laufzeitregel praktisch prüfen: 15 Minuten je Paket, höchstens 90 Minuten, mit nachvollziehbarer Protokollierung der Ergebnisse und Fehler.
- [ ] **6. Monatlicher WinGet-Quellenreset:** Den ersten produktiven Monatsreset und anschließend einen PowerShell-Treffer auf SRVDOM anhand des Checklogs bestätigen. Der 24-Stunden-Schutz für reaktive Resets und der Reset nach leerer Suche müssen erhalten bleiben.
- [ ] **7. WinGet-GitHub-API-Ausfall:** Vorhandene gültige portable CLI aus dem lokalen Cache bei vorübergehend nicht erreichbarer GitHub-API praktisch bestätigen.
- [ ] **8. WinGet-Installationsauswertung:** Bei einem Installationslauf mit Paketupdates anhand des Folgechecks bestätigen, welche Versionen tatsächlich installiert wurden; Installationsmeldungen allein gelten nicht als Versionsnachweis.
- [ ] **9. Updater-Temporärdateien:** Nach einem Skriptupdate prüfen, dass temporäre Updater-Dateien vollständig entfernt werden und verbleibende Pfade protokolliert sind.
- [ ] **10. Check-Modul und Cachebereinigung:** Bei aktivierter Cachebereinigung einen Checklauf ausführen und Windows-, Linux-, WinGet- und Home-Assistant-Ergebnisse samt Bericht bestätigen.
- [ ] **11. Clientzertifikat-Bootstrap:** Erstmalige Zertifikatserstellung und -verteilung praktisch bestätigen; sicherstellen, dass nur der öffentliche Schlüssel übertragen wird.
- [ ] **12. Nachinstallation – Logrotation:** Nach mehreren Rotationen bestätigen, dass höchstens zwei zeitgestempelte `.bak`-Dateien je Log erhalten bleiben.
- [ ] **13. Standardendpunkt-Bootstrap v5 (additiv):** Auf HWG-SQL ohne bisherigen WindowsUpdateAdm-Endpunkt testen, dass die Verteilung über den Standardendpunkt startet, `WindowsUpdateAdm` ergänzt und Version 5 erfolgreich bestätigt. Vorher/Nachher vergleichen: vorhandene WinRM-Diensteinstellungen, HTTP-Listener, Microsoft.PowerShell-Endpunkte, Firewallregeln und Zertifikatszuordnungen bleiben erhalten; nur fehlende WindowsUpdateAdm-Bestandteile kommen hinzu. Konflikte müssen zum Abbruch führen, ohne vorhandene Einträge zu überschreiben oder zu löschen. Danach auf einem AD- und einem Nicht-AD-Ziel prüfen.
- [ ] **14. WinRM-Portprüfung mit mehreren DNS-Adressen:** Einen Hostnamen mit nicht erreichbarer IPv6- und erreichbarer IPv4-Adresse prüfen; der Check muss den erreichbaren Port erkennen und die getesteten IPs im Log ausweisen.
