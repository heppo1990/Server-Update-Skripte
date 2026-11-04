# Offene Arbeiten und Prüfungen

Nur offene technische Punkte, keine Laufhistorie. Niemals Kundendaten, Kundennamen, Kundennummern oder konkrete Servernamen aufnehmen. Ein erfolgreicher Kundenlauf reicht je Prüfung. Erledigtes wird gelöscht. Checklistenänderungen nur zusammen mit Skriptänderungen committen/pushen.

## Aktuell

- [ ] **1. WinGet-Abschlussabfrage und Quellenreset:** Gemeinsamer Check-/Install-Abfragehelfer verwendet upgrade pro benannter App-Quelle; Prosa zählt nicht als Paket. Leere Ergebnisse nach fehlgeschlagener Quellenpflege dürfen nicht als erfolgreich gelten. Startverweigerung und nicht verfügbare AppX-Abfrage fallen auf die signaturgeprüfte portable CLI zurück; Resetzeit ist dynamisch bis 120 Sekunden im Check-Zeitbudget. Echter Zielcheck nach Resetfehler noch bestätigen.
- [ ] **2. Native AppX-Reparatur:** Provisionierung und Registrierung im echten Benutzerprofil bestätigen; ohne angemeldeten Benutzer als ausstehend melden. Portable WinGet-Nutzung ist bereits bestätigt.
- [ ] **3. Wartungsworker und Offlinefallback:** Automatische Workeraktualisierung ohne Verteilung sowie Rückgriff auf geprüften Cache bei GitHub-/Downloadfehlern bestätigen. Keine beschädigten Dateien ausführen.
- [ ] **4. Konsolenbereinigung:** Bei verwertbaren WinGet-Treffern Teilfehler nur im Log/Bericht ausweisen, nicht als zusätzliche Konsolen-Fehlermeldung. Ausgabe auf einem echten Lauf bestätigen; echte Fehler ohne Treffer weiter anzeigen.

## Verbleibende Funktions- und Sicherheitsprüfungen

- [ ] **5. JEA-Grenzen:** Installieren/Deinstallieren und allgemeine Prozess-, Dienst-, Registry-, WMI- und Importbefehle ablehnen; nur vorgesehene Update-/Wartungsfunktionen zulassen. SYSTEM-Check-Rolle und Verlauf prüfen. Erfolgreiche Paketupdates sind bestätigt.
- [ ] **6. WinRM-Baseline bewahren:** Bestehende Listener, Zertifikatszuordnungen, Firewallregeln und Remote-UAC-Wert unverändert lassen. Neue HTTPS-Regeln nur auf Verwaltungsserver-Adressen begrenzen; mehrere Adressen testen.
- [ ] **7. Frische Zertifikatseinrichtung:** Nicht-AD-Bootstrap, Servernamenprüfung, neuer Clientzertifikatszugang und Ausschluss privater Schlüssel aus dem Übertragungspaket bestätigen.
- [ ] **8. DPAPI und Settings-Rechte:** Geschützte Maildaten sowie dateibezogene ACLs bei Lesen, Bearbeiten, Synchronisieren und SYSTEM-Lauf prüfen; übrigen Skriptordner unverändert lassen.
- [ ] **9. NuGet-/Modulversionen:** Dynamischen Onlineabgleich und Bereitstellung einer tatsächlich neueren Version prüfen; NuGet-Onlineermittlung meldet derzeit eine Warnung.
- [ ] **10. PSGallery-Vertrauen:** Modulbereitstellung ohne Änderung der dauerhaften Repository-Vertrauensstellung und ohne unbeabsichtigte Rückfragen bestätigen.
- [ ] **11. Tatsächlicher Paketversionswechsel:** Nach Installationsversuchen die Version erneut abfragen; Installer-Erfolg allein genügt nicht als Nachweis. Einzelne Paketinstallerfehler bleiben zulässige manuelle Nacharbeit.
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

