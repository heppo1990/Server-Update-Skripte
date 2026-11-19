# Offene Arbeiten und Prüfungen

Nur offene technische Punkte, keine Laufhistorie. Niemals Kundendaten, Kundennamen, Kundennummern oder konkrete Servernamen aufnehmen. Ein erfolgreicher Kundenlauf reicht je Prüfung. Erledigtes wird gelöscht. Checklistenänderungen nur zusammen mit Skriptänderungen committen/pushen.

## Aktuell

- [ ] **Geplanter Check:** Verteilung aktualisiert bestehende Check-Aufgaben auf den PS5.1-Starthelfer. Aufgabenstart mit vorhandener, entfernter und defekter PS7 prüfen; bei fehlender PS7 muss PS5.1 übernehmen. Fehlgeschlagene Check-Läufe dürfen nicht doppelt starten. Startprotokoll unter Logs/ScheduledCheck-Launcher.log prüfen.

- [ ] **PowerShell-Vorabupdate:** Übergabe derselben WinGet-CLI aus der Suche an den PS5.1-Worker und Paketzuordnung ohne feste Installerfilter am Ziel bestätigen. Bei Installer-Technikkonflikt die Fortsetzung mit vorhandener PowerShell und den manuellen Prüfhinweis im Bericht prüfen.

- [ ] **Server Core:** Überspringen von WinGet in Check, Install und Verteilung bestätigen. Chocolatey und Windows Update separat prüfen. Auf Nicht-AD-Hyper-V Server 2019 Core die Endpunkt-Neueinrichtung und Chocolatey-Abfrage per Clientzertifikat bestätigen.

- [ ] **1. WinGet-Abschlussabfrage und Quellenreset:** Gemeinsamer Check-/Install-Abfragehelfer verwendet upgrade pro benannter App-Quelle; Prosa zählt nicht als Paket. Leere Ergebnisse nach fehlgeschlagener Quellenpflege dürfen nicht als erfolgreich gelten. Startverweigerung und nicht verfügbare AppX-Abfrage fallen auf die signaturgeprüfte portable CLI zurück. Archivdownloads erhalten ein größeres Budget mit Fortschritts-, Größen- und Stillstandsüberwachung; Quellenreset maximal 180 Sekunden. Erstlauf nach Clientbereitstellung, Quellenaktualisierung im Suchkonto und frischer Abschlussabfrage prüfen. Nachlauf innerhalb von 24 Stunden und Monatswartung nach 30 Tagen bestätigen. Vorhandene CLI vor Reparatur starten; portable Beschaffung verwendet den dauerhaften Archivcache und überwachte Downloads innerhalb des Reparaturbudgets. Fehlgeschlagene Beschaffung beendet die WinGet-Prüfung ohne erneuten Download beim Reset.
- [ ] **2. Native AppX-Reparatur:** Provisionierung und Registrierung im echten Benutzerprofil bestätigen; ohne angemeldeten Benutzer als ausstehend melden. Portable WinGet-Nutzung ist bereits bestätigt.
- [ ] **3. Wartungsworker und Offlinefallback:** Dynamischen Release-Web-Fallback für CLI und signaturgeprüfte Abhängigkeiten bei API-Limit bestätigen. Fester Raw-GitHub-Fallback bei Contents-API-Rate-Limit, automatische Workeraktualisierung ohne Verteilung und Rückgriff auf geprüften Cache bei Downloadfehlern auf echten Zielen bestätigen. Keine beschädigten Dateien ausführen.
- [ ] **4. Konsolenbereinigung:** Bei verwertbaren WinGet-Treffern Teilfehler nur im Log/Bericht ausweisen, nicht als zusätzliche Konsolen-Fehlermeldung. Ausgabe auf einem echten Lauf bestätigen; echte Fehler ohne Treffer weiter anzeigen.

## Verbleibende Funktions- und Sicherheitsprüfungen

- [ ] **5. JEA-Grenzen:** Installieren/Deinstallieren und allgemeine Prozess-, Dienst-, Registry-, WMI- und Importbefehle ablehnen; nur vorgesehene Update-/Wartungsfunktionen zulassen. SYSTEM-Check-Rolle und Verlauf prüfen. Erfolgreiche Paketupdates sind bestätigt.
- [ ] **6. WinRM-Baseline bewahren:** Bestehende Listener, Zertifikatszuordnungen, Firewallregeln und Remote-UAC-Wert unverändert lassen. Neue HTTPS-Regeln nur auf Verwaltungsserver-Adressen begrenzen; mehrere Adressen testen.
- [ ] **7. Frische Zertifikatseinrichtung:** Nicht-AD-Bootstrap, Servernamenprüfung, neuer Clientzertifikatszugang und Ausschluss privater Schlüssel aus dem Übertragungspaket bestätigen.
- [ ] **8. DPAPI und Settings-Rechte:** Geschützte Maildaten sowie dateibezogene ACLs bei Lesen, Bearbeiten, Synchronisieren und SYSTEM-Lauf prüfen; übrigen Skriptordner unverändert lassen.
- [ ] **9. NuGet-/Modulversionen:** Dynamischen Onlineabgleich und Bereitstellung einer tatsächlich neueren Version prüfen. Der neue dynamische Fallback auf den offiziellen Discovery-Feed soll die bisherige Bootstrap-Warnung beheben.
- [ ] **10. PSGallery-Vertrauen:** Modulbereitstellung ohne Änderung der dauerhaften Repository-Vertrauensstellung und ohne unbeabsichtigte Rückfragen bestätigen.
- [ ] **11. Tatsächlicher Paketversionswechsel:** Nach Installationsversuchen die Version erneut abfragen; Installer-Erfolg allein genügt nicht als Nachweis. Einzelne Paketinstallerfehler als manuelle Nacharbeit ausgeben und am Ziel prüfen, dass sie keine Clientreparatur auslösen.
- [ ] **12. Updater-Bereinigung:** Temporäre Updater-Dateien nach Update mit begrenzten Wiederholungen entfernen und verbleibende Pfade protokollieren.
- [ ] **13. Cachebereinigung:** Aktivierten Windows-Update-Cache-Reset praktisch prüfen.
- [ ] **14. Nachinstallations-Logrotation:** Nach mehreren Rotationen höchstens zwei datierte .bak-Dateien je Log bestätigen. Aufgabenanlage und Mail sind bestätigt.
- [ ] **15. Ausgeschaltete Verteilungsziele:** Zügiges Überspringen durch dieselbe Portprüfung wie bei Check/Download/Install bestätigen; kompakte Ausgabe.

## Neue Funktionen – gemeinsam praktisch bestätigen

- [ ] **SSH-Diagnosen:** Neue Unterscheidung von Schlüssel-/Hostschlüsselfehler, Anmeldung, Nichterreichbarkeit und sudo-Rechten in einem Bericht bestätigen.
- [ ] **Zertifikatsdiagnosen:** Fehlender Thumbprint, fehlender privater Schlüssel und zeitlich ungültiges Zertifikat müssen vor einem Nicht-AD-Aufruf konkret gemeldet werden.
- [ ] **WU-Bereitschaft:** Zeitmarkierte, begrenzte Suchprüfung statt fester Wartezeit auf einem Ziel bestätigen; Timeout darf den anschließenden regulären Check nicht verhindern.
- [ ] **Parallelbetrieb:** Check, Download und Install mit ParallelTargets=3 praktisch bestätigen: vollständige Zielabläufe, gemeinsame Zähler/Berichte, Fehlerisolation und Verwaltungsserver zuletzt. VM-Termine mit gesperrter gemeinsamer Reservierung, Abstand und Wartungsfenster prüfen; physische Neustarts bleiben nachgelagert. PS5-Prozessparallelität, Fehlerisolation und Slotplanung lokal bestätigt.

## Arbeitsregeln

Baseline nur ergänzen, bestehende Einstellungen nicht verschärfen oder entfernen. Fachmodule importieren einander nicht; Common bindet sie ein. Updater bleibt eigenständig. Neue Funktionen passend modularisieren. Skriptversion und erforderliche Bereitstellungsversion getrennt pflegen; Neuverteilung nur bei technisch nötiger Zieländerung.

- [ ] **20. Updater bei API-Sperre:** GitHub-Dateiliste bei API-Fehler aus dem Archiv derselben festen Commit-ID ermitteln; Git-Blob-Prüfsummen weiter prüfen. Simulierter HTTP403 und echter Codeload-Download mit Git-Objektvergleich unter PS5 bestätigt. Automatische Aktualisierung auf betroffenem Ziel nach einmaligem Nachladen des Updaters bestätigen.

- [ ] **Zentraler Downloadcache:** Nachlieferung über den eingeschränkten JEA-Empfänger 5.2.0 in Check/Install sowie Cachetreffer bestätigen. Erstbeschaffung und SHA256-geprüfte Übertragung bei Verteilung sind praktisch bestätigt. Offizielle Digestprüfung, Größen-/Pfadgrenzen und manipulierte Blöcke sind lokal geprüft; fehlende Metadaten müssen die Übernahme ablehnen.
