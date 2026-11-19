# Offene Praxistests

Ein erfolgreicher Praxistest an einem beliebigen System reicht je Funktion. Bestätigte Punkte werden gelöscht; bei teilweise bestätigten Sammelpunkten nur den offenen Rest behalten. Keine Kundendaten oder konkreten Servernamen eintragen. Die Tests begleiten die normalen Läufe und sind keine Voraussetzung für weitere Fehlerkorrekturen.

## Verteilung

- [ ] **Modulbereitstellung:** Eine tatsächlich neuere Modul-/NuGet-Version bereitstellen, ohne Passwortbestätigung oder dauerhafte Änderung des PSGallery-Vertrauens.
- [ ] **Server Core:** WinGet in Verteilung, Check und Install auslassen; Windows Update und vorhandenes Chocolatey weiter nutzen. Zertifikatszugang auf Hyper-V Server 2019 Core bestätigen.
- [ ] **Ausgeschaltete Ziele:** Verteilung, Check, Download und Install überspringen nicht erreichbare Ziele zügig und mit kompakter Ausgabe. Erreichbare IPv4-Ziele bleiben bei zusätzlicher unerreichbarer IPv6-Adresse enthalten; negative Portvorprüfung allein verwirft keinen erfolgreichen JEA-Zugang.

## Check, Download und Install

- [ ] **Parallelbetrieb:** Plattformübergreifend alle VMs einschließlich Verwaltungsserver vor allen physischen Systemen; auch bei ParallelTargets=1. Verständlichen Hinweis bei unbekannter Bauart bestätigen. Download/Install: höchstens drei vollständige Windows-Zielabläufe gleichzeitig; Summen, Bericht und Mail stimmen.
- [ ] **Neustartplanung:** Gemeinsame VM-Reservierungen halten Mindestabstand, eingestellten Neustartmodus und Wartungsfenster ein; VM-Nachinstallationen erhalten getrennte Starttermine. Physische Neustarts bleiben hinter dem VM-Block, Verwaltungsserver hinter dem Gesamtbericht.
- [ ] **Geplanter Check:** Bestehende Aufgabe wird auf den PS5.1-Starthelfer aktualisiert. Fehlende/defekte PS7 fällt auf PS5.1 zurück; ein fehlgeschlagener Check startet nicht doppelt. Startprotokoll: Logs/ScheduledCheck-Launcher.log.
- [ ] **PowerShell-Vorabupdate:** Dieselbe WinGet-CLI wie bei der Suche verwenden. Bei Installer-Technikkonflikt mit vorhandener PowerShell fortsetzen und manuelle Nacharbeit im Bericht nennen.
- [ ] **WU-Cache und Bereitschaft:** Aktivierter Cache-Reset funktioniert; Suchbereitschaft wird mit Zeitmarkern begrenzt geprüft, statt fest zu warten. Timeout verhindert den regulären Check nicht.
- [ ] **Paketergebnisse und Ausgabe:** Kompakte WinGet-/Chocolatey-Paketlisten erscheinen auch bei parallelen Läufen vollständig in der Konsole. Tatsächlichen Versionswechsel nach Installation bestätigen. Einzelne Installerfehler verlangen manuelle Nacharbeit statt Clientreparatur. Erfolgreicher Rückfall erzeugt keine zusätzliche Fehlermeldung in der Konsole; echte Fehler bleiben sichtbar.

## WinGet-Wartung und Downloadcache

- [ ] **Zentraler Reparaturablauf:** Fehler und fällige 30-Tage-Wartung verwenden denselben Ablauf. 24-Stunden-Schutz, Reset bei leeren Ergebnissen, frische Abschlussverbindung und höchstens 180 Sekunden Quellenreset bestätigen. Fehlgeschlagene Quellenpflege darf nicht als erfolgreiches leeres Ergebnis gelten; fehlgeschlagene Beschaffung startet keinen zweiten Download beim Reset.
- [ ] **AppX-Reparatur:** Registrierung und Provisionierung im echten Benutzerprofil bestätigen; ohne erforderlichen angemeldeten Benutzer als ausstehend melden.
- [ ] **JEA-Cacheempfang:** Check/Install liefern Archive zentral nach; vorhandene Dateien werden anhand Größe/SHA256 wiederverwendet. Offizielle Digestprüfung, Blockgrenzen und Ablehnung manipulierter Daten bestätigen; ohne überprüfbare Metadaten keine Übernahme. Ziel-Download bleibt der geprüfte Rückfallweg.
- [ ] **Worker und Offlinefallback:** Wartungsworker aktualisiert sich ohne Verteilung. API-Sperren verwenden Release-Web-/Raw-Fallback beziehungsweise geprüften Cache; keine beschädigten oder unsignierten ausführbaren Dateien starten. Downloadfortschritt, Größenlimit und Stillstandsabbruch bestätigen.

## Sicherheit und Fehlerdiagnosen

- [ ] **JEA-Grenzen:** Paket-Install/Uninstall und freie Prozess-, Dienst-, Registry-, WMI- und Importbefehle ablehnen. Nur feste Update-/Wartungsfunktionen zulassen; SYSTEM-Abfragerolle und Verlauf prüfen. Cacheempfang erlaubt keine freien Zielpfade oder Skriptausführung.
- [ ] **WinRM-Baseline:** Vorhandene Listener, Zertifikatszuordnungen, Firewallregeln und Remote-UAC unverändert lassen. Nur neue HTTPS-Regeln auf Verwaltungsserver-Adressen beschränken; mehrere Adressen berücksichtigen.
- [ ] **Frische Zertifikatseinrichtung:** Nicht-AD-Bootstrap, Servernamenprüfung und neuer Zertifikatszugang funktionieren; nur öffentlicher Schlüssel wird übertragen.
- [ ] **Settings und Zertifikatsdiagnosen:** DPAPI, dateibezogene Settings-Rechte und SYSTEM-Lauf prüfen. Fehlender Thumbprint/Privatschlüssel sowie zeitlich ungültige Zertifikate werden konkret gemeldet; übriger Skriptordner bleibt unverändert.
- [ ] **SSH-Diagnosen:** Ungültiger Schlüssel, geänderter Hostschlüssel, abgelehnte Anmeldung, Nichterreichbarkeit und fehlende sudo-Rechte werden in Log/Bericht unterschieden, ohne Prüfungen zu lockern.

## Bereinigung und Skriptaktualisierung

- [ ] **Linux-/HA-Protokolle:** Check, Download und Verteilung erzeugen keine separaten Linux-/HA-Logdateien; Details bleiben im jeweiligen gemeinsamen Laufprotokoll. Eigentliche Installation behält ihre eigenen Protokolle.

- [ ] **Updater bei API-Sperre:** Archiv derselben festen Commit-ID und Git-Blob-Prüfung praktisch bestätigen; keine Abschaltung der Integritätsprüfung.
- [ ] **Temporäre Dateien und Logrotation:** Updater-Reste begrenzt erneut entfernen und verbleibende Pfade protokollieren. Nachinstallation behält höchstens zwei datierte Log-Sicherungen.

## Arbeitsregeln

Baseline nur ergänzen. Fachmodule importieren einander nicht; Common bindet sie ein. Updater bleibt eigenständig. Skriptversion und erforderliche Verteilungsversion getrennt pflegen; Neuverteilung nur bei technisch nötiger Zieländerung. Checklistenänderungen ausschließlich zusammen mit Skriptänderungen committen und pushen.
