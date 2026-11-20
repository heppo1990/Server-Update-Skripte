# Offene Praxistests

Ein erfolgreicher Praxistest an einem beliebigen System reicht je Funktion. Bestätigte Punkte werden gelöscht; bei teilweise bestätigten Sammelpunkten nur den offenen Rest behalten. Keine Kundendaten oder konkreten Servernamen eintragen. Die Tests begleiten die normalen Läufe und sind keine Voraussetzung für weitere Fehlerkorrekturen.

## In normalen Läufen beobachten

- [ ] **Physische Neustarts:** Physische Systeme erhalten plattformübergreifend eine Stunde Abstand; VM-Puffer und Wartungsfenster bleiben erhalten.

Diese Punkte brauchen keinen gesonderten Test, sobald der passende Fall in einem Lauf vorkommt. Ein Lauf ohne diesen Fall bestätigt den Punkt nicht.

- [ ] **Modulbereitstellung:** Eine tatsächlich neuere Modul-/NuGet-Version bereitstellen, ohne Passwortbestätigung oder dauerhafte Änderung des PSGallery-Vertrauens.
- [ ] **Portable SYSTEM-CLI:** Vorhandene AppX-CLI ohne geschützte portable Kopie wird beim Installieren über JEA ergänzt; einmalige Wiederholung vor dem Installerstart und vollständige Ergebnisrückgabe bestätigen.
- [ ] **Zentraler Reparaturablauf:** Fehler und fällige 30-Tage-Wartung verwenden denselben Ablauf. 24-Stunden-Schutz, Reset bei leeren Ergebnissen, frische Abschlussverbindung und höchstens 180 Sekunden Quellenreset bestätigen. Fehlgeschlagene Quellenpflege darf nicht als erfolgreiches leeres Ergebnis gelten; fehlgeschlagene Beschaffung startet keinen zweiten Download beim Reset.
- [ ] **AppX-Reparatur:** Registrierung und Provisionierung im echten Benutzerprofil bestätigen; ohne erforderlichen angemeldeten Benutzer als ausstehend melden.

## Gezielt händisch prüfen

Diese Fälle benötigen eine bewusst hergestellte Ausgangslage oder einen Vorher-/Nachher-Vergleich. Fehlerfälle nur auf einem geeigneten Testsystem auslösen.

- [ ] **Erreichbarkeit:** Erreichbare IPv4-Ziele bleiben bei zusätzlicher unerreichbarer IPv6-Adresse enthalten; negative Portvorprüfung allein verwirft keinen erfolgreichen JEA-Zugang.
- [ ] **Akku-Betrieb:** Einrichtung und eigene Aufgaben starten auf Akku und bleiben beim Wechsel auf Akku aktiv; vorhandene eigene Aufgaben behalten Konto, Trigger und Zeitplan.
- [ ] **Parallelbetrieb:** Reihenfolge Windows-VMs, physische Windows-Systeme, Linux und Home Assistant auch bei ParallelTargets=1 bestätigen.
- [ ] **Geplanter Check:** Ein fehlgeschlagener Check startet nicht doppelt.
- [ ] **WU-Cache und Bereitschaft:** Aktivierter Cache-Reset funktioniert; Suchbereitschaft wird mit Zeitmarkern begrenzt geprüft, statt fest zu warten. Timeout verhindert den regulären Check nicht.
- [ ] **JEA-Cacheempfang:** Check/Install liefern Archive zentral nach; vorhandene Dateien werden anhand Größe/SHA256 wiederverwendet. Offizielle Digestprüfung, Blockgrenzen und Ablehnung manipulierter Daten bestätigen; ohne überprüfbare Metadaten keine Übernahme. Ziel-Download bleibt der geprüfte Rückfallweg.
- [ ] **Worker und Offlinefallback:** Wartungsworker aktualisiert sich ohne Verteilung. API-Sperren verwenden Release-Web-/Raw-Fallback beziehungsweise geprüften Cache; keine beschädigten oder unsignierten ausführbaren Dateien starten. Downloadfortschritt, Größenlimit und Stillstandsabbruch bestätigen.
- [ ] **JEA-Grenzen:** Paket-Install/Uninstall und freie Prozess-, Dienst-, Registry-, WMI- und Importbefehle ablehnen. Nur feste Update-/Wartungsfunktionen zulassen; SYSTEM-Abfragerolle und Verlauf prüfen. Cacheempfang erlaubt keine freien Zielpfade oder Skriptausführung.
- [ ] **WinRM-Baseline:** Vorhandene Listener, Zertifikatszuordnungen, Firewallregeln und Remote-UAC unverändert lassen. Nur neue HTTPS-Regeln auf Verwaltungsserver-Adressen beschränken; mehrere Adressen berücksichtigen.
- [ ] **Frische Zertifikatseinrichtung:** Nicht-AD-Bootstrap, Servernamenprüfung und neuer Zertifikatszugang funktionieren; nur öffentlicher Schlüssel wird übertragen.
- [ ] **Settings und Zertifikatsdiagnosen:** DPAPI, dateibezogene Settings-Rechte und SYSTEM-Lauf prüfen. Fehlender Thumbprint/Privatschlüssel sowie zeitlich ungültige Zertifikate werden konkret gemeldet; übriger Skriptordner bleibt unverändert.
- [ ] **SSH-Diagnosen:** Ungültiger Schlüssel, geänderter Hostschlüssel, abgelehnte Anmeldung, Nichterreichbarkeit und fehlende sudo-Rechte werden in Log/Bericht unterschieden, ohne Prüfungen zu lockern.
- [ ] **Updater bei API-Sperre:** Archiv derselben festen Commit-ID und Git-Blob-Prüfung praktisch bestätigen; keine Abschaltung der Integritätsprüfung.

## Arbeitsregeln

Baseline nur ergänzen. Fachmodule importieren einander nicht; Common bindet sie ein. Updater bleibt eigenständig. Skriptversion und erforderliche Verteilungsversion getrennt pflegen; Neuverteilung nur bei technisch nötiger Zieländerung. Checklistenänderungen ausschließlich zusammen mit Skriptänderungen committen und pushen.
