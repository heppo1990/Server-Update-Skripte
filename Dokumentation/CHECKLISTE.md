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


- **KD2 – HOST-SERVER / SERVER2:** Verteilung am 03.11.2026 08:34 erfolgreich auf 2 Windows-Zielen; beide V4-Endpunkte und Statusfunktionen per Kerberos geprüft, keine Fehler oder übersprungenen Ziele. Fehlendes Microsoft.WinGet.Client auf SERVER2 bereitgestellt; Check, Download und Install noch offen.

- **KD3 – SRVDOM01 / SRVSVC / TP-M08 / SrvHV01:** Check vom 03.11.2026 08:20 nur teilweise vorliegend. Windows-Abfragen auf SRVDOM01 und SRVSVC erfolgreich; WinGet-Reparatur auf SRVDOM01 scheitert zusätzlich in der Diagnose-Textverkettung. Allgemeiner Diagnosefix wird zusammen mit dieser Checklistenpflege ausgeliefert. WinGet-Fehler bleibt bis zum vollständigen Folgelog offen.

- **KD3, Folgelog 03.11.2026 08:43:** SRVDOM01 WinGet weiterhin fehlerhaft. SRVSVC und TP-M08 melden nach portabler Wiederholung leer; laut Nutzer sind auf TP-M08 Updates vorhanden, Ergebnis daher nicht als Erfolg bestätigt. Worker-Download wurde wegen durch Textaustausch beschädigter Quelldatei verworfen; Syntax wird im allgemeinen Fix wiederhergestellt. Prüfung des leeren TP-M08-Ergebnisses bleibt offen.


- [ ] **27. Install-Abschluss und Mail trotz Folgefehler:** VM-Inventar über vorhandene administrative Verbindung statt CIM im eingeschränkten JEA. Windows-Ergebnisse direkt nach Installation in Mail/Zähler übernehmen. KD1 muss nach Fix Neustart- und Nachinstallationsplanung sowie vollständigen Mailbericht bestätigen; keine zusätzliche JEA-Freigabe.

- [ ] **28. WinGet-Quellenkontext und portable Abhängigkeiten:** KD3 09:32 bestätigt DOM-Startfehler 0xC0000135 und JEA-/Suchkontext-Abweichung. Portable Abhängigkeiten aus dynamischem Microsoft-Release sowie winget-Reset/Update im tatsächlichen Suchkonto prüfen; Abbruchtext trotz Exitcode 0 nicht als Erfolg werten. Kundeneigene Quellen erhalten. TP-M08 meldet nach manuellem Eingriff 10 Updates; automatischer Weg bleibt zu bestätigen.

- **KD3 03.11.2026 10:21:** DOM-Wartungsworker startet portable CLI erfolgreich, Wiederholungsabfrage im separaten Benutzer-Cache jedoch weiterhin fehlerhaft. Abhängigkeitsbereitstellung wird auch im portablen Abfragepfad ergänzt. Andere Ziele melden Paketupdates; DOM erst nach Folgelauf abschließen. Keine Ausweitung von JEA-Rechten, keine neue Verteilung erforderlich.

Kundenabschluss 03.11.2026: KD1 / WBG Pfarrhuebel vom Nutzer als abgeschlossen bestätigt. Nachinstallation war bereits eingerichtet; keine Bestätigung einer frischen Aufgabeneinrichtung durch diesen Abschluss. KD1 gehört nicht mehr zu den offenen Kunden.

- [ ] **29. Verteilung auf Server 2016:** WinGet-Modulübertragung und Paketupdatefreigabe für Server-Builds vor 17763 auslassen, auch bei direktem Setup und SYSTEM-Finalisierung. Windows Update/Chocolatey unverändert. Folge-Verteilung darf nicht wegen fehlendem WinGet erneut einrichten. Bestehende Module nicht deinstallieren.

- **KD3 / Irrenanstalt Krahmann, Check 03.11.2026 12:30 erfolgreich:** Alle 7 Ziele geprüft. SRVDOM01 findet PowerShell 7.6.8.0 auf 7.6.9.0 nach automatischem Quellenreset im tatsächlichen Suchkonto und CLI-Gegenprüfung. SRVSVC 4, TP-M08 10, SrvHV01 4 WinGet-Treffer; insgesamt 14 Windows-, 19 WinGet-, 1 Chocolatey- und 7 Linux-Updates. HA keine Updates, Mail erfolgreich. Monatlicher Reset samt PowerShell-Treffer bestätigt, Prüfpunkt 6 entfernt. AppX-Bestandsreparatur meldet weiterhin 0x80073CF9 und bleibt separat offen. Download/Install KD3 noch offen.

- **KD2 Download 03.11.2026 10:18:** HOST-SERVER und SERVER2 verarbeitet, Dauer 54,17 Minuten. Alle 7 Ergebniszeilen nur A------ statt AD-----; Zusammenfassung zählt trotzdem 7 heruntergeladen. Nutzer bestätigt Anzeigeproblem; A------ wird nicht als Downloadfehler gewertet. Kein expliziter Fehler im Lauf. Downloadlauf als abgeschlossen geführt; Statusanzeige gegebenenfalls separat verbessern.

- **Neuer KD1 (ersetzt die freigewordene Nummer, nicht Pfarrhuebel):** Verteilung 03.11.2026 08:48: SRVDOM, SRVEX01, SRVFILE, SRVMAIL erfolgreich; HV01 und HV02 Setupfehler unmittelbar nach Erkennung bestehender HTTPS-Listener. 4/6 erfolgreich. Konkrete Ursache nur in lokalen Setup-Logs, noch anzufordern. Kunde offen.

- [ ] **30. Bestehende WinRM-Zertifikatsverwaltung migrieren:** Nur nach durch die Verteilung erfolgreich getesteter Clientzertifikatsanmeldung darf die vorhandene HTTP.sys-Bindung auf 5986 die erforderliche Clientzertifikataushandlung aktivieren (PreserveExistingCertificateMapping). Ohne diesen Nachweis bleibt die Baseline-Sperre erhalten. Neuer KD1/HV01: Ursache bestätigt, Folge-Verteilung prüfen; HV02 separat bestätigen.
