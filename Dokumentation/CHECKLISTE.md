# Offene Arbeiten und Prüfungen

Nur offene technische Punkte, keine Laufhistorie. Niemals Kundendaten, Kundennamen, Kundennummern oder konkrete Servernamen aufnehmen. Ein erfolgreicher Kundenlauf reicht je Prüfung. Erledigtes wird gelöscht. Checklistenänderungen nur zusammen mit Skriptänderungen committen/pushen.

## Aktuell

- [ ] **PowerShell-Vorabupdate:** Übergabe derselben WinGet-CLI aus der Suche an den PS5.1-Worker und Paketzuordnung ohne feste Installerfilter am Ziel bestätigen. Bei Installer-Technikkonflikt die Fortsetzung mit vorhandener PowerShell und den manuellen Prüfhinweis im Bericht prüfen.

- [ ] **Linux-sudo:** Nach Ergänzung der verwalteten Regeln APT-/DNF-/YUM-Prüfung ohne Passwortcache bestätigen. Fehlende Rechte müssen im Check eine Linux-Neuverteilung verlangen.

- [ ] **Ältere Windows-Ziele:** Auf einem Build unter 17763 die Verteilung ohne WinGet-Transfer und NuGet-Rückfrage sowie die kurze JEA-Finalisierung über schtasks.exe bestätigen.

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
- [ ] **9. NuGet-/Modulversionen:** Dynamischen Onlineabgleich und Bereitstellung einer tatsächlich neueren Version prüfen; NuGet-Onlineermittlung meldet derzeit eine Warnung.
- [ ] **10. PSGallery-Vertrauen:** Modulbereitstellung ohne Änderung der dauerhaften Repository-Vertrauensstellung und ohne unbeabsichtigte Rückfragen bestätigen.
- [ ] **11. Tatsächlicher Paketversionswechsel:** Nach Installationsversuchen die Version erneut abfragen; Installer-Erfolg allein genügt nicht als Nachweis. Einzelne Paketinstallerfehler als manuelle Nacharbeit ausgeben und am Ziel prüfen, dass sie keine Clientreparatur auslösen.
- [ ] **12. Updater-Bereinigung:** Temporäre Updater-Dateien nach Update mit begrenzten Wiederholungen entfernen und verbleibende Pfade protokollieren.
- [ ] **13. Cachebereinigung:** Aktivierten Windows-Update-Cache-Reset praktisch prüfen.
- [ ] **14. Nachinstallations-Logrotation:** Nach mehreren Rotationen höchstens zwei datierte .bak-Dateien je Log bestätigen. Aufgabenanlage und Mail sind bestätigt.
- [ ] **15. Ausgeschaltete Verteilungsziele:** Zügiges Überspringen durch dieselbe Portprüfung wie bei Check/Download/Install bestätigen; kompakte Ausgabe.

## Vorgemerkte Verbesserungen – anschließend einzeln umsetzen

- [ ] **16. SSH-Diagnosen:** Linux/Home Assistant: ungültiger Schlüssel, abgelehnte Anmeldung, geänderter Hostschlüssel, Nichterreichbarkeit und fehlende sudo-Rechte im Bericht unterscheiden; keine automatische Lockerung der Prüfungen.
- [ ] **17. Fehlende Zertifikatsdaten:** Vor Nicht-AD-Paketmanageraufrufen fehlende/unvollständige AuthInfo verständlich melden. Die vorhandene zentrale Authentifizierung beibehalten; Check/Download/Install berücksichtigen.
- [ ] **18. Dynamische WU-Bereitschaft:** Feste Wartezeit nach DetectNow durch begrenzte Bereitschafts-/Suchprüfung ersetzen; langsame Ziele, Timeout und PS5/PS7 testen. Laufender Dienst allein reicht nicht.
- [ ] **19. Begrenzte Parallelisierung:** Erst nach Stabilisierung Check/Download mit wenigen gleichzeitigen Zielen und PS5-Unterstützung erproben. Verteilung und Installation/Neustarts separat bewerten; VM-/Hypervisor-/Verwaltungsserver-Abhängigkeiten bewahren.

## Arbeitsregeln

Baseline nur ergänzen, bestehende Einstellungen nicht verschärfen oder entfernen. Fachmodule importieren einander nicht; Common bindet sie ein. Updater bleibt eigenständig. Neue Funktionen passend modularisieren. Skriptversion und erforderliche Bereitstellungsversion getrennt pflegen; Neuverteilung nur bei technisch nötiger Zieländerung.

- [ ] **20. Updater bei API-Sperre:** GitHub-Dateiliste bei API-Fehler aus dem Archiv derselben festen Commit-ID ermitteln; Git-Blob-Prüfsummen weiter prüfen. Simulierter HTTP403 und echter Codeload-Download mit Git-Objektvergleich unter PS5 bestätigt. Automatische Aktualisierung auf betroffenem Ziel nach einmaligem Nachladen des Updaters bestätigen.

- [ ] **Zentraler Downloadcache:** WinGet-Archive bei Einrichtung einmal auf Verwaltungsserver laden und nur bei Abweichung übertragen. Cachetreffer, Versionserneuerung und Quellenreparatur mit vorverteilten Archiven auf echten Zielen bestätigen. Für bestehende JEA-Ziele den sicheren Nachlieferungsweg im normalen Check-/Install-Lauf ergänzen; derzeit besteht dort der überwachte Ziel-Download als Rückfallweg.
