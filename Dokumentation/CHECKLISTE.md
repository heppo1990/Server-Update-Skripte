# Noch offene Prüfpunkte

Neustart der Kundenzuordnung und Kunden-Teststände am 03.11.2026. Frühere Kundennummern werden nicht übernommen. Erledigte Punkte werden aus dieser Liste entfernt.

Validierungsregel: Es zählen nur Läufe mit aktuellem Skriptstand. Ein erfolgreicher Lauf auf einem beliebigen System reicht je Prüfpunkt; tritt ein Fehler erneut auf, wird er zuerst behoben.

Modulregel: Neue, fachlich abgegrenzte Funktionen kommen in thematische Module. Fachmodule importieren einander nicht direkt; `WindowsUpdate.Common.psm1` bindet sie gemeinsam ein. Der GitHub-Updater bleibt bewusst eigenständig und ohne Modulabhängigkeit, damit er auf alten oder leeren Installationen zuerst starten und die Moduldateien nachladen kann.

Bereits passend modularisiert: Linux- und Home-Assistant-Updatefunktionen liegen in eigenen Fachmodulen; ihre kurzen Komponenten-Einstiegsskripte benötigen derzeit keine weitere Aufteilung.

- [ ] **1. HOCHSTE PRIORITÄT – WinRM-HTTPS-Firewallregel:** V4 erstellt neue TCP-5986-Regeln nur mit nutzbaren Verwaltungsserver-Adressen; vorhandene Regeln bleiben als Baseline unverändert. Auf frischem System sowie mit mehreren Verwaltungsserver-IP-Adressen prüfen.
- [ ] **2. HOCHSTE PRIORITÄT – Remote-UAC für lokale Konten:** Das Setup setzt `LocalAccountTokenFilterPolicy` nicht; vorhandene Werte bleiben unverändert. Prüfen, dass frische Einrichtung und Wiederholung keinen Wert hinzufügen oder verändern.
- [ ] **3. HOCHSTE PRIORITÄT – JEA-Rollen und Ausführungsgrenze:** Die Sitzung nutzt `ConstrainedLanguage`. PSWindowsUpdate ist eng freigegeben; WinGet ist zusätzlich nur über `Update-WinGetPackage` und die feste Wrapperfunktion für installierte Pakete verfügbar. Install-/Uninstall-Cmdlets, externe Befehle sowie Prozess-, Dienst-, Registry-, WMI- und Modulimport-Befehle bleiben gesperrt. Check, Download, Install, Verlauf, WinGet-Update und Check-Rolle praktisch prüfen.
- [ ] **4. NuGet-/PSGallery-Versionsabgleich:** Dynamische Onlineversion und Versionsabgleich bei verfügbaren Updates prüfen.
- [ ] **5. Mehrere Benutzerupdates:** Bei mehreren erkannten Benutzer-WinGet-Paketen die Laufzeitregel praktisch prüfen: 15 Minuten je Paket, höchstens 90 Minuten, mit nachvollziehbarer Protokollierung der Ergebnisse und Fehler.
- [ ] **6. Monatlicher WinGet-Quellenreset:** WinGet-Standardquellen werden mindestens alle 30 Tage je ausführendem Benutzer und Ziel zurückgesetzt. Der separate 24-Stunden-Schutz für reaktive Resets und der Reset nach leerer Suche bleiben erhalten. Den ersten produktiven Monatsreset und anschließend einen verfügbaren Pakettreffer noch anhand des nächsten Checklogs bestätigen.
- [ ] **7. WinGet-GitHub-Ausfall:** Bei nicht erreichbarer API eine vorhandene, geprüfte portable CLI aus dem lokalen Cache verwenden; keine beschädigten Downloads ausführen.
- [ ] **8. WinGet-Installationsauswertung:** Nach Installation durch erneute Abfrage den tatsächlichen Versionswechsel bestätigen. Erfolgreiche Installer-Aufrufe allein reichen nicht.
- [ ] **9. Updater-Temporärdateien:** Nach dem Fix mit bis zu fünf Bereinigungsversuchen und Pfadprotokollierung prüfen, dass die temporären Updater-Dateien bei einem Update vollständig entfernt werden.
- [ ] **10. Check-Cachebereinigung:** Bei aktiviertem Konfigurationsschalter praktisch prüfen.
- [ ] **11. Clientzertifikat-Bootstrap:** Erstmalige Einrichtung samt Zertifikatserstellung und Ausschluss des privaten Schlüssels aus dem Updater-Payload bestätigen.
- [ ] **12. Nachinstallation – Logrotation:** Höchstens zwei zeitgestempelte .bak-Dateien je Log nach mehreren Rotationen bestätigen.

## Sicherheitsprüfungen


- **JEA-Fehlerpfade – kein aktueller Zusatzrisikopunkt:** Check, Download, Install und Verlauf laufen laut Betriebsmodell mit einem Administratorkonto, das auch den Standard-WinRM-Endpunkt verwenden darf. Der Fallback erweitert dessen Rechte deshalb nicht. Nur erneut prüfen, falls künftig eingeschränkte Konten verwendet werden.
- [ ] **13. Ersteinrichtung und Authentifizierung:** HTTPS-Bootstrap überspringt nur noch die CA-Prüfung; der Servername wird geprüft. HTTP bleibt als einmaliger Fallback erhalten, wenn HTTPS auf dem frischen Ziel fehlt. Frische Nicht-AD-Einrichtung und bestehende Zertifikatsverbindung prüfen.
- [ ] **14. Vorhandenen HTTPS-Listener bewahren:** V4 entfernt oder ersetzt einen bestehenden HTTPS-Listener samt Zertifikat auch bei `-ForceUpdate` nicht. Auf einem bestehenden und einem frischen System prüfen.
- [ ] **15. Vorhandene Zertifikatszuordnungen bewahren:** V4 löscht keine bestehenden Clientzertifikats-Mappings oder älteren öffentlichen Zertifikate. Kollisionen führen zu einer Diagnose statt zum Entfernen. Mit bestehendem und frischem Mapping prüfen.
- [ ] **16. DPAPI und Settings-ACLs:** Mailpasswörter bleiben mit `LocalMachine`-DPAPI geschützt. Lokale Settings und ihre Sicherungen erhalten dateibezogene ACLs für Owner, aktuelle Identität, SYSTEM und lokale Administratoren; der Skriptordner und andere Dateien bleiben unangetastet. Lesen, Bearbeiten, Synchronisieren und SYSTEM-Lauf praktisch prüfen.
- [ ] **17. PSGallery-Vertrauensstellung:** V4 ändert die dauerhafte `InstallationPolicy` der PSGallery nicht mehr. Modulbereitstellung und nicht vertrauenswürdige Repository-Rückfragen auf einem Ziel praktisch prüfen.
- [ ] **18. WinGet im JEA-Endpunkt:** Maschinenweite Updates laufen über den V4-Endpunkt einzeln durch `Update-WinGetPackage`. Installieren, Deinstallieren und Quellenänderungen sind dort nicht freigegeben. WinGet-Reparatur/Ersteinrichtung und Benutzerupdates bleiben in ihren bestehenden Wartungspfaden. Erfolgreiches Update sowie abgelehnte Install-/Uninstall-Aufrufe über JEA bestätigen.
- [ ] **19. Verteilung überspringt ausgeschaltete Server:** Die Verteilung prüft vor dem Setup dieselben WinRM-Ports wie Check, Download und Install und überspringt nicht erreichbare Windows-Ziele mit einer kurzen Meldung ohne IP-Adressen. Auf einem Lauf mit ausgeschaltetem Ziel praktisch bestätigen.
- [ ] **20. WinRM-Baseline bleibt erhalten:** Der lokale Setup-Pfad prüft Dienst, Standardlistener und `Microsoft.PowerShell`-Endpunkt nur lesend. Fehlt die Baseline, stoppt das Setup, statt `Enable-PSRemoting` mit möglichen Änderungen an Standardendpunkten und Firewallregeln aufzurufen. Auf Systemen mit vorhandener Baseline prüfen.

## Aktuelle WinGet-Korrekturen prüfen

- [ ] **21. Automatischer Wartungsworker:** Neuen Worker aus dem festen GitHub-Pfad unter PS5.1 übernehmen; ohne Neuverteilung ausführen. Bei Onlinefehlern vorhandenen Worker behalten. Keine freien URLs oder Skriptparameter über JEA.
- [ ] **22. Reparatur im JEA-Kontext:** Installer-, Microsoft- und portablen Rückfallweg mit vollständiger Diagnose prüfen; Windows Server 2022/2025 und Windows 11 berücksichtigen.
- [ ] **24. AppX-Bestand und Benutzerregistrierung:** Aktuelles Microsoft-Release samt Abhängigkeiten und Lizenz provisionieren; Registrierung nur in geeignetem echten Benutzerprofil bestätigen. Ohne angemeldeten Benutzer als ausstehend melden.
- [ ] **25. Konsolen-Ergebnisbewertung bei Install:** Nach erfolgreicher Wiederholung keine abschließende Fehlermeldung aus früheren Versuchen anzeigen. Check ist bestätigt; Install bleibt zu prüfen. Tatsächliche Fehler bleiben sichtbar.
- [ ] **26. Fehlendes Chocolatey:** Ohne Installation keine Konsolenwarnung oder überflüssige Übersprungen-Meldung; vorhandene Installation weiter prüfen.
## Aktueller Kundenstand ab 03.11.2026

- **KD1 – WBG Pfarrhuebel:** Check am 03.11.2026 08:23 erfolgreich auf 3 Windows-Zielen; 15 Windows- und 21 WinGet-Updates, Mail erfolgreich. Portabler Folgelauf auf SrvHV01 direkt aus Cache ohne Reparaturwartezeit. Download am 03.11.2026 08:27 auf allen 3 Zielen ohne gemeldeten Fehler abgeschlossen (15 Ergebniszeilen; Defender auf SrvHV01 nur A------, übrige AD-----). Install noch offen.

- **KD2 – HOST-SERVER / SERVER2:** Verteilung am 03.11.2026 08:34 erfolgreich auf 2 Windows-Zielen; beide V4-Endpunkte und Statusfunktionen per Kerberos geprüft, keine Fehler oder übersprungenen Ziele. Fehlendes Microsoft.WinGet.Client auf SERVER2 bereitgestellt; Check, Download und Install noch offen.

- **KD3 – SRVDOM01 / SRVSVC / TP-M08 / SrvHV01:** Check vom 03.11.2026 08:20 nur teilweise vorliegend. Windows-Abfragen auf SRVDOM01 und SRVSVC erfolgreich; WinGet-Reparatur auf SRVDOM01 scheitert zusätzlich in der Diagnose-Textverkettung. Allgemeiner Diagnosefix wird zusammen mit dieser Checklistenpflege ausgeliefert. WinGet-Fehler bleibt bis zum vollständigen Folgelog offen.

- **KD3, Folgelog 03.11.2026 08:43:** SRVDOM01 WinGet weiterhin fehlerhaft. SRVSVC und TP-M08 melden nach portabler Wiederholung leer; laut Nutzer sind auf TP-M08 Updates vorhanden, Ergebnis daher nicht als Erfolg bestätigt. Worker-Download wurde wegen durch Textaustausch beschädigter Quelldatei verworfen; Syntax wird im allgemeinen Fix wiederhergestellt. Prüfung des leeren TP-M08-Ergebnisses bleibt offen.

- **KD1 Install 03.11.2026 08:28–09:22 fehlgeschlagen:** Windows-Installergebnisse melden SRVAPP=5, SRVDOM01=3, SrvHV01=5, jeweils Neustartbedarf. Anschließende JEA-Abfrage mit nicht freigegebenem Get-CimInstance bricht alle 3 Serverabläufe ab; Zusammenfassung zählt deshalb fälschlich Windows=0. Nachinstallation/Neustartplanung nicht bestätigt. WinGet teils fälschlich leer, SrvHV01 RPC-Fehler; TeamViewer auf SRVDOM01 Exitcode 2, PowerShell auf HV manuell zu prüfen. Verwaltungsserver-PS7-Update samt Fortsetzung erfolgreich.

- [ ] **27. Install-Abschluss und Mail trotz Folgefehler:** VM-Inventar über vorhandene administrative Verbindung statt CIM im eingeschränkten JEA. Windows-Ergebnisse direkt nach Installation in Mail/Zähler übernehmen. KD1 muss nach Fix Neustart- und Nachinstallationsplanung sowie vollständigen Mailbericht bestätigen; keine zusätzliche JEA-Freigabe.

- [ ] **28. WinGet-Quellenkontext und portable Abhängigkeiten:** KD3 09:32 bestätigt DOM-Startfehler 0xC0000135 und JEA-/Suchkontext-Abweichung. Portable Abhängigkeiten aus dynamischem Microsoft-Release sowie winget-Reset/Update im tatsächlichen Suchkonto prüfen; Abbruchtext trotz Exitcode 0 nicht als Erfolg werten. Kundeneigene Quellen erhalten. TP-M08 meldet nach manuellem Eingriff 10 Updates; automatischer Weg bleibt zu bestätigen.
