# Server Updates

Diese Sammlung verwaltet Windows-, Linux- und Home-Assistant-Updates zentral. Alle Skripte erwarten, dass sie gemeinsam in einem Verzeichnis liegen. Pfade werden jeweils relativ zum Skriptverzeichnis bestimmt.

## Automatische Skriptaktualisierung

Alle direkt ausführbaren PowerShell-Skripte prüfen beim Start den öffentlichen Branch `main` von [heppo1990/Server-Update-Skripte](https://github.com/heppo1990/Server-Update-Skripte). Dafür ist weder Git noch ein GitHub-Konto auf dem ausführenden System erforderlich; der Rechner benötigt lediglich HTTPS-Zugriff auf GitHub.

Der Updater lädt keine ZIP-Datei und keinen vollständigen Repository-Klon. Er liest die Dateiliste und Git-Datei-Hashes des aktuellen Commits und vergleicht sie mit den lokalen Dateien. Dadurch lädt er nur geänderte oder neu hinzugekommene Programm- und Begleitdateien; unveränderte Dateien werden nicht übertragen. Später neu im Repository angelegte Dateien werden automatisch berücksichtigt. `.gitignore` und Markdown-Dokumentation werden nicht auf Kundensysteme kopiert. Die Linux- und Home-Assistant-Dateien werden bei Check, Download, Installation und Verteilung nur berücksichtigt, wenn sie in den lokal wirksamen Einstellungen konfiguriert sind. Bei einem auf Windows begrenzten Lauf werden sie übersprungen.

Kundenspezifische Werte in `settings.json` und skriptspezifischen `*.settings.json` werden nicht aus GitHub geladen oder überschrieben. Die versionierte `default_settings.json` wird bei Änderungen aktualisiert. Fehlende Standardwerte werden in die vorhandene allgemeine `settings.json` und alle vorhandenen skriptspezifischen Einstellungsdateien ergänzt. Für skriptspezifische Dateien stammen fehlende Werte aus den wirksamen allgemeinen Einstellungen (Vorlage plus `settings.json`); vorhandene skriptspezifische Werte behalten Vorrang. Alte Mailbereiche wie `Mailsettings` werden zu `MailSettings` vereinheitlicht. Alle vorhandenen alten Mailfelder außer `Subject` sowie alle übrigen Kundeneinstellungen bleiben erhalten. Nur ein alter `SendMail`-Schalter wird anhand des Dateinamens dem zugehörigen Bereich `Check`, `Download` oder `Install` zugeordnet. In einer allgemeinen `settings.json` gilt dieser Wert für alle drei Berichte. Bei einer alleinstehenden skriptspezifischen Datei werden die beiden anderen `SendMail`-Schalter auf `false` gesetzt; gibt es zusätzlich eine allgemeine Datei, gelten deren Werte für die nicht skriptspezifisch gesetzten Berichte. Der alte `Subject`-Wert wird immer verworfen; `CompanyName` wird nicht daraus abgeleitet und muss manuell gepflegt werden. Die migrierten Dateien folgen der Feldreihenfolge aus `default_settings.json`; zusätzliche kundeneigene Felder bleiben danach erhalten. Bereits mit `DPAPI:` geschützte Mailpasswörter werden unverändert übernommen und nicht erneut verschlüsselt. Die aktuellen Standardbetreffe und künftig neu hinzukommenden Standardfelder werden aus `default_settings.json` ergänzt; bereits vorhandene kundenspezifische Werte werden nicht überschrieben. Das geschieht für jede vorhandene Einstellungsdatei, unabhängig davon, welches Skript sie verwendet. Der atomare Austausch legt vor der Änderung eine Sicherung neben der Datei mit dem Suffix `.bak.<Zeitstempel>_<Kennung>` an; scheitert der Austausch, bleibt die bisherige Einstellungsdatei erhalten. Im Skriptordner bleiben höchstens die drei neuesten automatisch erstellten Sicherungen dieser Einstellungen erhalten. Zertifikate, Protokolle, Berichte und Laufzeitdateien werden nicht aus GitHub geladen. Der Update-Metadatencache liegt unter `%ProgramData%\ServerUpdateSkripte\UpdateCache.json` und enthält nur Commit-IDs, keine Konfiguration.

Wenn sich benötigte Skriptdateien geändert haben, speichert der Updater zunächst alle Downloads zwischen, übernimmt die Dateien und startet das aufgerufene Skript mit denselben Parametern erneut. Schlägt die Verbindung oder der Download fehl, wird mit dem vorhandenen lokalen Stand fortgefahren. Der Code auf `main` wird beim nächsten Skriptstart wirksam; Änderungen an diesem Branch sollten deshalb nur von berechtigten Personen mit Schreibzugriff eingepflegt werden.

**Altinstallation aktualisieren:** Für den ersten Lauf genügen der aktualisierte Einstiegspunkt und `Update-ServerUpdateScripts.ps1`. Beim Start lädt der Updater die übrigen benötigten oder fehlenden Programmdateien anhand der GitHub-Dateihashes nach. Kundenspezifische Einstellungswerte und lokale Zertifikate bleiben erhalten; fehlende Standardwerte werden mit Sicherung ergänzt. Ein Einstiegspunkt mit `-TargetComputer` überspringt optionale Linux- und Home-Assistant-Dateien.

`Update-ServerUpdateScripts.ps1` kann auch direkt gestartet werden, um die lokale Skriptsammlung zu synchronisieren. Dabei werden alle geänderten gemeinsamen Skripte und Module (einschließlich `WindowsUpdate.Common.psm1`) geladen; Linux- und Home-Assistant-Dateien nur, wenn sie in den vorhandenen Einstellungsdateien konfiguriert sind. Die Settings-Migration läuft dabei ebenfalls. Kundeneigene `settings.json`-Dateien, Markdown und `.gitignore` werden nicht aus GitHub geladen.

**Einmalige Aktivierung auf bestehenden Installationen:** Bereits installierte ältere Skriptkopien kennen den Updater noch nicht. Sie müssen zunächst einmal durch die aktualisierten Skripte aus diesem Repository ersetzt werden. Ab diesem ersten Austausch aktualisieren sie sich bei jedem Start selbst.

Beim Start von `Install-ServersUpdates.ps1` mit PowerShell 7 prüft ein im Updater enthaltener Vorlauf mit Windows PowerShell 5.1, ob Winget ein PS7-Update anbietet. Fehlt WinGet auf Windows Server 2019 oder 2022 oder schlägt seine Prüfung fehl, wird es auf diesem Rechner mit dem signaturgeprüften `winget-install`-Skript repariert beziehungsweise installiert und die PS7-Prüfung wiederholt. Das gilt unabhängig davon, ob der Rechner Mitglied einer AD-Domäne ist. Auf anderen Betriebssystemversionen wird diese Reparatur nicht ausgeführt. Wenn WinGet fehlt und diese versionsgebundene Reparatur nicht greift, wird Chocolatey nur dann auf ein verfügbares Update für `powershell-core` geprüft, wenn Chocolatey bereits installiert ist; Chocolatey wird niemals nachinstalliert. PS5.1 installiert ein verfügbares PS7-Update und startet dasselbe Installationsskript mit denselben Parametern erneut in PS7. Damit wird die aktive PS7-Instanz nicht während des Laufs ersetzt. Sind weder ein funktionsfähiger WinGet-Updateweg noch ein bereits installiertes Chocolatey verfügbar, läuft das Skript mit der installierten PS7-Version weiter. Andere Skripte führen diese Prüfung nicht aus.

Auf Windows Server 2019 und 2022 prüft Check und Installation vor der Winget-Abfrage `winget --version`. Fehlt WinGet oder schlägt der Aufruf fehl, wird `winget-install` unter Windows PowerShell 5.1 verwendet: Ein vorhandenes Skript wird zuerst mit `-UpdateSelf` aktualisiert, danach repariert beziehungsweise installiert `-Force` WinGet. Fehlt das Skript, wird es zuerst aus der PowerShell Gallery installiert; falls das nicht gelingt, wird die signierte aktuelle GitHub-Release-Datei geladen. Vor der Ausführung wird die Authenticode-Signatur geprüft und nachher `winget --version` erneut ausgewertet. Reparaturversuche und Ergebnisse stehen im Laufprotokoll. Optionale Bootstrap-Meldungen werden nur gelesen, wenn das zurückgegebene Ergebnisobjekt diese Eigenschaft enthält. Erkennt die Paketabfrage einen Fehler beim Aktualisieren oder Durchsuchen der Quelle `winget`, aktualisiert das Skript diese Quelle einmal und wiederholt die Suche automatisch. Bleibt die Suche gestört oder trotz erfolgreich aktualisierter Quelle leer, setzt das Skript die drei eingebauten Standardquellen (`msstore`, `winget`, `winget-font`) einzeln zurück und wiederholt die Paketabfrage; kundeneigene Quellen bleiben dabei erhalten. Die Zeitmarke `%ProgramData%\ServerUpdateSkripte\WingetDefaultSourcesResetUtc.txt` begrenzt einen solchen Reset je Zielsystem auf höchstens einmal innerhalb von 24 Stunden und bleibt auch bei wechselnden WinRM-/JEA-Profilen erhalten. Ein Marker älterer Skriptstände wird bewusst nicht verwendet, da diese nur die Quelle `winget` zurückgesetzt haben. „Kein installiertes Paket gefunden“ gilt nicht allein als Beleg für eine leere Suche, weil WinGet diese Meldung auch bei einem nicht initialisierten Quellenzustand ausgeben kann. Andere Windows-Serverversionen sowie der übersprungene SYSTEM-Kontext bleiben von der WinGet-Reparatur unberührt. Grundlage ist das [asheroto/winget-install-Projekt](https://github.com/asheroto/winget-install), das Windows Server 2019 und 2022 unterstützt.

Der Update-Check wiederholt eine Remote-SYSTEM-Suche einmal nach 20 Sekunden, wenn sie keine Ergebniszeilen oder nur leere Ergebnisobjekte zurückgibt. Das deckt verzögerte Suchergebnisse auf älteren Nicht-AD-Servern ab, bei denen Download und Installation bereits Updates finden. Der reine SYSTEM-Check verwendet `Get-WindowsUpdate -AcceptAll`, bestätigt damit etwaige Rückfragen, lädt oder installiert aber nichts. Leere Zeilen werden verworfen und nicht als Updates gezählt. Liefert auch die Wiederholung keine auswertbaren Daten, protokolliert der Check eine Warnung. Die Nachinstallationsaufgabe verarbeitet alle konfigurierten zurückgestellten KBs und Kategorien gemeinsam; eine leere KB-Liste unterdrückt keine Kategorie wie `SQL`, `Exchange` oder andere später konfigurierte Werte. Diagnosewerte aus der JEA-Prüfung werden ohne `Sort-Object` zusammengefügt, da dieses Cmdlet im eingeschränkten Endpunkt nicht zwingend verfügbar ist. Die Deferred-Prüfung entpackt außerdem verschachtelte .NET-Collections aus `Get-WindowsUpdate` vor dem Auslesen von KB, Titel und Größe, damit Remote-Ergebnisse nicht fälschlich als Metadatenfehler gewertet werden. Sie prüft täglich im Wartungsfenster des jeweiligen Ziels (`PhysicalRebootTime` für physische Rechner, `VMRebootStartTime` für VMs) und zusätzlich beim Systemstart. Ist das Wartungsfenster offen, startet sie die Nachinstallation auch ohne vorherigen Neustart. Nach einem erkannten Neustart fragt sie die Bereitschaft von Windows Update ab und versucht die Suche bei Fehlern alle 15 Sekunden erneut, maximal fünf Minuten lang. Sobald die Suche antwortet, startet die Nachinstallation im offenen Wartungsfenster. Ist Windows Update nach fünf Minuten noch nicht bereit oder ist das Wartungsfenster inzwischen geschlossen, bleibt die Aufgabe für das nächste Fenster bestehen. Ohne Wartungszeit startet sie nach erkannter Bereitschaft. Nach der Abschlussmail wird ein von `Get-WURebootStatus` bestätigter Neustart sofort ausgelöst.

Die Dateien `linux_update_check_stats.json` und `ha_update_check_stats.json` dienen Check- und Download-Läufen nur zur Übergabe von Ergebnissen an den gemeinsamen Bericht. Alte Reste werden vor einem neuen Lauf entfernt; erzeugte Dateien werden nach der Übernahme oder einem Fehler wieder gelöscht. Der SYSTEM-Worker für ältere Nicht-AD-Server fächert außerdem verschachtelte Ergebnis-Collections von PSWindowsUpdate auf, damit darin enthaltene Updates als einzelne Zeilen im Check erscheinen.

`WindowsUpdate.Common.psm1` ist ein internes Modul und muss im selben Verzeichnis bleiben. Check, Download, Installation und die Verteilung verwenden daraus dieselbe Zielermittlung für AD-Computer, zusätzliche Geräte und Hypervisoren. Check und Installation verwenden zusätzlich die zentrale Ermittlung von Winget- und Chocolatey-Paketupdates. Check, Download und Installation verwenden dieselbe Logik für das Laden der Settings-Dateien, die Nicht-AD-Remoting-Vorbereitung (TrustedHosts und Client-Zertifikat), WinRM/JEA-Aufrufe mit einheitlichen Open-/Operation-Timeouts, Protokollierung, Konsolen-Zusammenfassungen, Dateiaufbewahrung und den technischen SMTP-Versand. Wiederholbare WinRM-Operationen und Remote-Aufgaben verwenden eine zentrale Retry-Logik. Die Einstiegsskripte kündigen SYSTEM-Updateaufgaben an; das gemeinsame Modul wiederholt diese Meldung nicht noch einmal. Linux und Home Assistant verwenden gemeinsame SSH-Optionen mit Verbindungs- und Keepalive-Timeout. Es wird nicht direkt ausgeführt. Die HTML-Inhalte und Farben der drei Berichte bleiben bewusst in den jeweiligen Skripten.

Wenn bei einem Server zurückgestellte Windows-Updates gefunden und eine Nachinstallationsaufgabe eingerichtet wird, zeigt der Installationsbericht direkt bei diesem Server den geplanten Start des Wartungsfensters (VM oder physisch), die konfigurierte Auswahl und die beim Check konkret gefundenen Update-Titel und KB-Nummern. Nach einem Neustart wartet die Aufgabe automatisch auf eine erfolgreiche Antwort der Windows-Update-Suche. Ohne konfigurierten Wartungszeitpunkt weist der Bericht auf die Aktivierung beim nächsten Neustart hin. Die angezeigte Uhrzeit ist der geplante Aktivierungszeitpunkt; die tatsächliche Installation kann noch auf den Neustart, die Bereitschaft von Windows Update oder das nächste Wartungsfenster warten.

Für die konkrete Update-Liste vereinheitlicht die Abfrage KB-Nummern und Titel bereits auf dem Zielsystem, bevor das Ergebnis über JEA oder PowerShell-Remoting zurückgegeben wird. Damit bleiben diese Angaben auch bei unterschiedlichen PSWindowsUpdate-Versionen und serialisierten Remote-Objekten im Bericht erhalten. Liefert das Zielsystem tatsächlich keine Metadaten, nennt der Bericht stattdessen die gefundene Anzahl und weist auf die fehlenden Angaben hin.

Bei der Prüfung zurückgestellter Updates ist `MetadataMissing` nur auf Ergebnisobjekten ohne auflösbare Update-Metadaten vorhanden. Die Auswertung liest dieses optionale Feld sicher über die Objekteigenschaften, damit normale Updateergebnisse unter aktiviertem `StrictMode` nicht fälschlich die Nachinstallationsprüfung abbrechen. Für nicht auflösbare Ergebnisse protokolliert sie zusätzlich Typname und verfügbare Eigenschaftsnamen, damit ungewöhnliche PSWindowsUpdate-Rückgaben eingegrenzt werden können, ohne Updateinhalte oder Zugangsdaten auszugeben. Eine fehlgeschlagene Prüfung verändert eine bereits vorhandene Nachinstallationsaufgabe weiterhin nicht.

Beim Laden der Settings und auch beim direkten Lauf von `Update-ServerUpdateScripts.ps1` verschlüsselt der gemeinsame Settings-Schutz ein vorhandenes Klartextpasswort in `MailSettings.AuthPass` automatisch mit Windows DPAPI (`LocalMachine`), bevor die Settings-Migration eine Sicherung anlegt. Das gilt für `settings.json` und alle vorhandenen skriptspezifischen `*.settings.json`-Dateien; die versionierte `default_settings.json` bleibt unverändert und darf kein Mailpasswort enthalten. Skripte entschlüsseln den Wert nur im Arbeitsspeicher. Automatisch erzeugte Settings-Sicherungen enthalten ebenfalls nur den geschützten Wert; es bleiben höchstens drei Sicherungen. Der DPAPI-Wert ist an den Verwaltungsrechner gebunden und darf nicht auf einen anderen Rechner kopiert werden. Lokale Prozesse, die die verschlüsselte Datei lesen können, können `LocalMachine`-DPAPI auch entschlüsseln; die Settings-Dateien müssen deshalb weiterhin vor unbefugtem lokalem Zugriff geschützt sein.

Der Worker der Windows-Nachinstallationsaufgabe liegt während der offenen Aufgabe unter `%ProgramData%\WindowsUpdateAdm\DeferredUpdates.ps1`. Der Task startet ihn mit Windows PowerShell 5.1 und einem kurzen `-File`-Aufruf statt eines langen eingebetteten `-EncodedCommand`; die Worker-Syntax muss deshalb mit Windows PowerShell 5.1 kompatibel sein. Eine Worker-Korrektur wird auf dem Zielsystem übernommen, wenn das Installationsskript die Nachinstallationsaufgabe neu registriert. Das Mailpasswort wird bei der Task-Erstellung über die bestehende WinRM-Verbindung übertragen, auf dem Zielsystem mit dessen DPAPI geschützt und nur als Chiffretext im Worker hinterlegt. Leserechte für den Worker erhalten nur SYSTEM und die lokalen Administratoren. Nach erfolgreichem Abschluss, einem Fehler oder dem Entfernen der Aufgabe wird die Worker-Datei gelöscht. Das einmalige SYSTEM-Testmailtask verwendet ebenfalls den geschützten Wert. Das Task-Log protokolliert nur Empfänger und SMTP-Host, niemals das MailSettings-Objekt oder das Passwort.

Der Task-Aufruf verwendet einen kleinen CMD-Starthelfer. Er schreibt in `%ProgramData%\WindowsUpdateAdm\DeferredUpdates-TaskRunner.log`, bevor Windows PowerShell 5.1 startet, und leitet Standardausgabe sowie Fehler einschließlich Parserfehlern in dieses Log um. So bleibt die Ursache sichtbar, auch wenn der Worker keine eigene Protokollzeile schreiben kann. Ein täglicher Wartungsfenster-Start installiert zurückgestellte Updates, sobald das Wartungsfenster offen ist; ein vorheriger Neustart ist dafür nicht erforderlich. Nach einem erkannten Neustart wartet der Worker anhand einer erfolgreichen Windows-Update-Suche automatisch auf die Systembereitschaft. Die Suche wird alle 15 Sekunden bis zu fünf Minuten wiederholt; ist das Wartungsfenster dann geschlossen, wartet der Task bis zum nächsten Fenster. Die frühere Einstellung `DeferredUpdateDelayMinutes` wird nicht mehr verwendet. Das Skriptupdate entfernt diesen Schlüssel automatisch aus `settings.json` und skriptspezifischen `*.settings.json`-Dateien und legt davor wie bei anderen Settings-Änderungen eine Sicherung an. Die Nachinstallationsmail verwendet dieselben Tabellenspalten wie die übrigen Updateberichte (`ComputerName`, `Status`, `KB`, `Size`, `Title`) und zählt beziehungsweise zeigt jeden Update-Datensatz nur einmal.

`default_settings.json` ist optional. Liegt sie nicht im Skriptordner, wird eine vollständige `settings.json` direkt verwendet; skriptspezifische `*.settings.json`-Dateien bleiben weiterhin möglich und haben Vorrang.

## Reihenfolge der Verwendung

1. Einstellungen in `settings.json` pflegen.
2. Einmalig oder nach Änderungen an der Remoting-Konfiguration `Verteilung_WindowsUpdateAdmConfig.ps1` ausführen.
3. Mit `Check-ServersUpdates.ps1` verfügbare Updates prüfen.
4. Optional mit `Download-ServersUpdates.ps1` herunterladen.
5. Mit `Install-ServersUpdates.ps1` installieren.

Bei einem lokalen Start aus PowerShell 7 aktiviert `Enable-PSRemoting` nur PowerShell-7-Remoting; die erwartete Hinweiszeile dazu wird im Setup-Protokoll erklärt und nicht auf der Konsole wiederholt. Der benötigte WindowsUpdateAdm-JEA-Endpunkt wird separat registriert. Das Setup aktiviert dafür nicht zusätzlich die allgemeinen Windows-PowerShell-Remoting-Endpunkte.

## Einstellungen

`default_settings.json` ist die zentrale Fallback-Basis. Die allgemeine `settings.json` ist normalerweise ausreichend und überschreibt deren Werte. Existiert zusätzlich eine skriptspezifische Datei wie `Install-ServersUpdates.settings.json`, hat diese für das betreffende Skript Vorrang.

Für eine geplante Aufgabe den Skriptordner im Feld **„Starten in“** setzen und das jeweilige Skript relativ aufrufen, beispielsweise `powershell.exe -NonInteractive -ExecutionPolicy Bypass -File ".\Install-ServersUpdates.ps1"`. Dadurch bleibt der Speicherort der Skripte frei wählbar.

Die folgenden Tabellen beschreiben alle Felder aus `default_settings.json`. Optionale Felder können zusätzlich verwendet werden, wenn sie in der jeweiligen Beschreibung genannt sind. Die Werte der allgemeinen und skriptspezifischen Dateien überschreiben die Vorlage nur dort, wo sie tatsächlich gesetzt sind.

### `UpdateSettings`

| Feld | Wirkung |
|---|---|
| `SucheOnline` | Bestimmt, ob PSWindowsUpdate auch die Quelle Microsoft Update statt nur der konfigurierten Windows-Update-Quelle durchsucht. |
| `WriteReport` | Aktiviert oder deaktiviert das Speichern des HTML-Berichts. Ein Mailversand wird separat durch `MailSettings.<Skript>.SendMail` gesteuert. |
| `KeepReportFiles` | Maximale Anzahl gespeicherter HTML-Berichte je Skript; ältere Berichte werden entfernt. |
| `WriteLogFile` | Aktiviert oder deaktiviert die ausführliche lokale Logdatei. |
| `KeepLogFiles` | Maximale Anzahl gespeicherter Logdateien je Skript; ältere Logs werden entfernt. |
| `DetectNowWaitSeconds` | Wartezeit nach dem Anstoßen einer Windows-Update-Erkennung, bevor das Skript mit der Suche fortfährt. |
| `ClearUpdateCacheBeforeCheck` | Bei `true` werden vor dem Check Download- und DataStore-Cache bereinigt und eine neue Erkennung angestoßen; `false` überspringt diese Bereinigung. |
| `EnableWingetUpdates` | Bei `true` werden Winget-Paketupdates gesucht und im Installationslauf verarbeitet; `false` überspringt Winget. |
| `EnableChocolateyUpdates` | Bei `true` werden Chocolatey-Paketupdates gesucht und im Installationslauf verarbeitet; `false` überspringt Chocolatey. Chocolatey wird dadurch nicht installiert. |
| `TargetComputers` | AD-Auswahl: `Server` verarbeitet Windows-Server, `All` alle passenden Windows-Computer. Zusätzliche Geräte werden über die nächsten beiden Listen angegeben. |
| `AdditionalComputers` | Liste zusätzlicher Computer, die unabhängig von der AD-Auswahl verarbeitet werden. |
| `HypervisorComputers` | Liste der Hypervisoren außerhalb der AD-Auswahl; sie werden als eigene Zielgruppe für Remoting und Neustartplanung behandelt. |
| `ClientCertThumbprint` | Fingerabdruck des Client-Zertifikats für zertifikatsbasiertes Remoting zu Nicht-AD-Zielen. Das Verteilungs-/Zertifikat-Setup kann diesen Wert synchronisieren. |
| `DeferredUpdateCategories` | Kategorien, die beim regulären Update-Lauf ausgelassen und für die Nachinstallation vorgemerkt werden. Auswahl wird später gemeinsam abgearbeitet. Siehe [Kategorien für zurückgestellte Updates](#kategorien-für-zurückgestellte-updates). |
| `DeferredUpdateKBs` | Einzelne KB-Nummern, die ausgelassen und für die Nachinstallation vorgemerkt werden, zum Beispiel `KB5122871`. |
| `InstallDeferredUpdates` | Bei `true` richtet das Installationsskript eine Nachinstallationsaufgabe ein, wenn zurückgestellte Updates vorhanden sind; bei `false` bleiben diese Updates ausgelassen. |
| `PhysicalRebootTime` | Beginn des Wartungsfensters und geplante Neustartzeit für physische Systeme im Format `HH:mm`. Leer bedeutet, dass kein zeitgesteuerter Neustart geplant wird. |
| `PhysicalRebootWindowEndTime` | Ende des Wartungsfensters für physische Systeme. Neustarts dürfen spätestens zu dieser Zeit beginnen; leer lässt das Fensterende offen. |
| `VMRebootStartTime` | Beginn des VM-Wartungsfensters und geplante Neustartzeit der ersten VM im Format `HH:mm`. |
| `VMRebootWindowEndTime` | Ende des VM-Wartungsfensters. Neustarts dürfen spätestens zu dieser Zeit beginnen; leer lässt das Fensterende offen. |
| `VMRebootImmediately` | Bei `true` werden VM-Neustarts zeitnah eingeplant, unter Beachtung der Staffelung und des Wartungsfensters. Bei `false` gilt der konfigurierte Start des Wartungsfensters. |
| `VMRebootIntervalMinutes` | Abstand zwischen geplanten Neustarts von VMs. `0` erlaubt gleichzeitige Neustarts; ein positiver Wert staffelt die VMs. Die Staffelung wird bei der Planung physischer Neustarts berücksichtigt. |

### `MailSettings`

| Feld | Wirkung |
|---|---|
| `CompanyName` | Firmenname im Betreff. Das Skript setzt ihn automatisch genau einmal vor den Betreff des jeweiligen Laufs: `Firmenname - Betreff`. Ist der Name leer, wird nur der Betreff verwendet. |
| `Host` | Hostname des SMTP-Servers. |
| `Port` | TCP-Port des SMTP-Servers, üblicherweise `587` für STARTTLS oder `465` für implizites TLS, je nach Mailserver. |
| `UseSSL` | Aktiviert die verschlüsselte SMTP-Verbindung gemäß der vom Mailserver erwarteten TLS-Verbindung. |
| `Auth` | Legt fest, ob sich das Skript mit SMTP-Benutzerdaten anmeldet. |
| `AuthUser` | Benutzername für die SMTP-Anmeldung, sofern `Auth` aktiviert ist. |
| `AuthPass` | SMTP-Passwort. Ein Klartextwert wird beim Laden automatisch maschinengebunden mit DPAPI geschützt; in `default_settings.json` gehört kein echtes Passwort. |
| `Sender` | Absenderadresse der E-Mail. Muss für den SMTP-Server gültig und zulässig sein. Wenn das Feld leer ist und `CompanyName` gesetzt ist, erzeugt das Skript automatisch `Updates@<Firmenname>.de` (mit bereinigtem Namen). |
| `MailTo` | Empfängeradresse der E-Mail. |
| `MailCC` | Optionale CC-Empfänger. |
| `MailBCC` | Optionale BCC-Empfänger. |
| `Check.SendMail` | Bei `true` versendet `Check-ServersUpdates.ps1` den Check-Bericht per E-Mail. |
| `Check.Subject` | Betrefftext für den Check-Bericht; `CompanyName` wird automatisch davor gesetzt. |
| `Download.SendMail` | Bei `true` versendet `Download-ServersUpdates.ps1` den Download-Bericht. |
| `Download.Subject` | Betrefftext für den Download-Bericht; `CompanyName` wird automatisch davor gesetzt. |
| `Install.SendMail` | Bei `true` versendet `Install-ServersUpdates.ps1` den Installationsbericht. |
| `Install.Subject` | Betrefftext für den Installationsbericht; `CompanyName` wird automatisch davor gesetzt. |

Bei der Migration alter Dateien wird `SendMail` anhand des Dateinamens dem passenden Skriptbereich zugeordnet (`Check-ServersUpdates.settings.json` → `Check`, `Download-ServersUpdates.settings.json` → `Download`, `Install-ServersUpdates.settings.json` → `Install`). Alte Betrefftexte werden verworfen, damit ein alter Firmenname im `Subject` nicht zusätzlich zum automatisch vorangestellten `CompanyName` erscheint. Die aktuellen Betrefftexte kommen aus den Standardwerten.

### `LinuxSettings`

| Feld | Wirkung |
|---|---|
| `Hosts` | Liste der Linux-Ziele. Jeder Eintrag braucht `Host` (alternativ `Name`) und `User`, zum Beispiel `{ "Host": "linux01.example.local", "User": "admin" }`. Eine leere Liste bedeutet, dass keine Linux-Ziele verarbeitet werden. |
| `ConnectTimeoutSeconds` | Maximale Wartezeit für den SSH-Verbindungsaufbau in Sekunden. |
| `LockWaitMinutes` | Maximale Wartezeit auf eine vorhandene Update-Sperre auf dem Linux-Ziel, bevor der Lauf abbricht. |

### `HomeAssistantSettings`

| Feld | Wirkung |
|---|---|
| `Host` | Hostname oder IP-Adresse der Home-Assistant-OS-Instanz. Leer bedeutet, dass Home Assistant nicht konfiguriert ist. |
| `User` | SSH-Benutzer für die Verbindung zur Home-Assistant-Instanz. |
| `Port` | SSH-Port, normalerweise `22`. |
| `KeyPath` | Optionaler Pfad zum privaten SSH-Schlüssel. Ohne Angabe wird der vorgesehene Schlüssel im Benutzerprofil verwendet. |
| `SSHPath` | Optionaler Pfad zu `ssh.exe`. Ohne Angabe verwendet das Skript OpenSSH aus dem Systempfad beziehungsweise dem Windows-OpenSSH-Verzeichnis. |
| `CommandTimeoutSeconds` | Optionale maximale Laufzeit eines einzelnen HA-CLI-Aufrufs in Sekunden; Standardwert `300`. |
| `RebootWaitSeconds` | Optionale maximale Wartezeit auf die Rückkehr von SSH und Supervisor nach einem sofortigen Neustart; Standardwert `300`. |

Home Assistant verwendet für geplante Neustarts die gemeinsamen VM-/physischen Wartungszeitfelder aus `UpdateSettings`.

### Kategorien für zurückgestellte Updates

`DeferredUpdateCategories` wird als `-Category` beziehungsweise `-NotCategory` an `Get-WindowsUpdate` aus PSWindowsUpdate übergeben. Der Wert muss einer Kategorie entsprechen, die in den Metadaten der verfügbaren Updates auf dem jeweiligen System vorkommt. Es gibt deshalb keine vollständige, für alle Updatequellen und Produkte identische Liste.

Häufige Windows-Update-Klassifizierungen sind:

- `Critical Updates`
- `Definition Updates`
- `Driver Sets`
- `Drivers`
- `Feature Packs`
- `Hotfix`
- `Security Updates`
- `Service Packs`
- `Tools`
- `Update Rollups`
- `Updates`
- `Upgrades`

Zusätzlich gibt es Produktkategorien. Häufige Microsoft-Serverprodukte sind:

- `SQL Server` – passt auf versionsspezifische Produktnamen wie `Microsoft SQL Server 2019`.
- `Exchange Server` – passt auf Produktnamen wie `Exchange Server Subscription Edition` und Exchange-Server-Versionen.
- `SharePoint Server` – nur ergänzen, wenn SharePoint-Updates ebenfalls zurückgestellt werden sollen; Farm-Updates müssen separat geplant werden.
- `Windows Server <Version>` – nur verwenden, wenn Windows-Betriebssystemupdates dieser Version zurückgestellt werden sollen.

`Get-WindowsUpdate -Category` von PSWindowsUpdate sucht nach Kategoriebezeichnungen in den Update-Metadaten. Deshalb sind `SQL Server` und `Exchange Server` passendere und engere Werte als `SQL` oder `Exchange`. Den allgemeinen Wert `Server` vermeiden: Er kann gleichzeitig auf Windows Server, SQL Server und Exchange Server passen. Microsoft unterscheidet bei Updates zwischen Produkt und Klassifizierung; Produktnamen und Klassifizierungen sind also verschiedene Filterwerte. Beispiele aus dem Microsoft Update Catalog: [SQL Server 2019 – Produkt „Microsoft SQL Server 2019“, Klassifizierung „Security Updates“](https://www.catalog.update.microsoft.com/Search.aspx?q=Security+Update+for+SQL+Server+2019+RTM+CU) und [Exchange Server Subscription Edition – Produkt „Exchange Server Subscription Edition“, Klassifizierung „Security Updates“](https://www.catalog.update.microsoft.com/Search.aspx?q=exchange+server+subscription+edition). Grundlegende Erläuterungen zu Produktfamilien und Updatekategorien: [Microsoft: Updates anzeigen und verwalten](https://learn.microsoft.com/en-us/windows-server/administration/windows-server-update-services/manage/viewing-and-managing-updates).

Ein Eintrag wie `Security Updates` stellt alle passenden Sicherheitsupdates zurück, nicht nur kumulative Windows-Updates. Für eine gezielte Auswahl kann stattdessen `DeferredUpdateKBs` verwendet werden. Vor einem breiten Einsatz sollte geprüft werden, welche Kategoriebezeichnungen das jeweilige Ziel für die betreffenden Updates tatsächlich liefert.

Für den Normalbetrieb kann der relevante Block beispielsweise so aussehen:

```json
"ClearUpdateCacheBeforeCheck": true,
"EnableWingetUpdates": true,
"EnableChocolateyUpdates": true,
"DeferredUpdateCategories": ["Exchange Server", "SQL Server"],
"DeferredUpdateKBs": [],
"InstallDeferredUpdates": true,
"PhysicalRebootTime": "03:00",
"PhysicalRebootWindowEndTime": "05:00",
"VMRebootStartTime": "19:00",
"VMRebootWindowEndTime": "23:00",
"VMRebootImmediately": false,
"VMRebootIntervalMinutes": 30
```

Die Windows-Neustarts werden nach der VM-Klassifizierung koordiniert. Physische Windows-Systeme starten frühestens eine Stunde nach dem spätesten geplanten VM-Neustart. Passt dieser Abstand nicht mehr in das geplante physische Wartungsfenster, wird der Neustart auf den nächsten Tag zum konfigurierten physischen Start verschoben. Bei `VMRebootIntervalMinutes: 0` werden VMs für die Kapazitätsplanung als gleichzeitig angesetzt.

## Dateien auf Zielsystemen

Der GitHub-Updater läuft nur auf dem Verwaltungsrechner, auf dem die Skriptsammlung liegt. `New-WindowsUpdateAdmConfig.ps1` lädt auf Zielservern keine Repository-Dateien nach. Die Verteilung überträgt dieses eine Setup-Skript vorübergehend nach `%WINDIR%\Temp\WindowsUpdateAdmSetup_<Kennung>`; sie verwendet ausdrücklich nicht den benutzerspezifischen Temp-Pfad unter `C:\Users`. Für genau diesen Setup-Aufruf setzt die Verteilung `ExecutionPolicy Bypass` ausschließlich im Prozess der kurzlebigen WinRM-Sitzung; die Richtlinie des Zielsystems wird nicht dauerhaft geändert. Bei Nicht-AD-Zielen kommt das Client-Zertifikat dazu. Nach dem Lauf wird genau dieser Ordner entfernt. Falls die JEA-Aktivierung die bestehende WinRM-Sitzung trennt, versucht die Verteilung die Bereinigung über eine neue Verbindung bis zu fünfmal; wenn auch das nicht gelingt, meldet sie den Zielpfad als Warnung.

Die vorsorglichen Warnungen von `Register-PSSessionConfiguration` und `Set-PSSessionConfiguration` über mögliche WinRM-Neustarts werden bei der Registrierung ausgeblendet. Die Registrierung erfolgt mit `-NoServiceRestart`; der erforderliche WinRM-Neustart wird vom Setup anschließend gezielt gesteuert. Registrierungsfehler bleiben sichtbar und brechen das Setup ab.

Bei jeder Verteilung werden außerdem alte Ordner mit dem eindeutigen Namen `WindowsUpdateAdmSetup_*` in `%WINDIR%\Temp` und unter `C:\Users\*\AppData\Local\Temp` bereinigt, sofern sie älter als 30 Minuten sind. Die Schonfrist schützt parallel laufende Setups. Unregistrierte, danach vollständig leere Profil-Gerüste werden entfernt. Registrierte Benutzerprofile, Verknüpfungen und Ordner mit anderen Inhalten bleiben unangetastet.

Der NuGet-Paketprovider wird bei Bedarf ohne interaktive Rückfrage maschinenweit installiert. So steht er auch dann für weitere Verteilungen bereit, wenn diese von einem anderen Administratorkonto gestartet werden. Der lokale Fallback überspringt eine Kopie, wenn die gefundene DLL bereits im Zielordner liegt, und meldet Erfolg erst nach erfolgreicher Provider-Erkennung.

Für eine einmalige Bereinigung ohne erneute WindowsUpdateAdm-Einrichtung:

```powershell
.\Verteilung_WindowsUpdateAdmConfig.ps1 -CleanupLegacyTempOnly
```

Mit `-TargetComputer SRV01` lässt sich die Bereinigung auf ein einzelnes Remote-Ziel begrenzen. Ein lokaler Verwaltungsserver in der Zielliste wird im reinen Bereinigungslauf übersprungen.

Windows-Update-Prüfungen und -Installationen führen Befehle direkt per PowerShell-Remoting aus. Für bestimmte Nicht-AD-Systeme wird ein kurzlebiger Worker unter `C:\ProgramData\WindowsUpdateAdm` als SYSTEM-Aufgabe ausgeführt; Worker-Skript und Aufgabe löschen sich nach Abschluss. Der reine Check läuft ohne Download-, Installations- oder Neustartoptionen. Der Worker normalisiert unterschiedliche Eigenschaftsnamen älterer PSWindowsUpdate-Ausgaben, bevor er Ergebnisse zurückliefert. Geplante Neustart- und Nachinstallationsaufgaben speichern ihren kleinen Befehlsinhalt in der Windows-Aufgabenplanung statt als Repository-Skriptdatei. Das Installationsprotokoll `C:\ProgramData\WindowsUpdateAdm\DeferredUpdates.log` bleibt für die Nachvollziehbarkeit erhalten.

Linux-Updates laden jeweils ein eigens erzeugtes Shell-Skript nach `/tmp`; es entfernt sich nach Ausführung selbst, ebenso das kurze Skript zur Einrichtung der begrenzten sudo-Regeln. Home Assistant erhält keine Skriptdateien; die Befehle laufen direkt über SSH. Dauerhafte SSH-Schlüssel, sudo-Regeln, PSWindowsUpdate-/JEA-Konfiguration und Protokolle sind Betriebszustand, keine Kopien der Repository-Skripte.

## Windows-Skripte

### `Verteilung_WindowsUpdateAdmConfig.ps1`

Richtet die sichere Update-Verbindung auf den Windows-Zielen ein oder aktualisiert sie.

- AD-Rechner verwenden Kerberos und benötigen kein Client-Zertifikat.
- Nicht-AD-Rechner verwenden WinRM über HTTPS mit Client-Zertifikat.
- Bei einer Wiederholung prüft das Skript zuerst die Zertifikatsverbindung. Nur falls sie noch nicht funktioniert, werden einmalig lokale Administrator-Anmeldedaten abgefragt.
- Das Admin-Share (`C$`) ist keine Voraussetzung.
- Eigene Update-Service-Accounts werden nicht verwendet. Alte Konten `svc-updates` und `svc-wupdate-hv` werden bei der erneuten Einrichtung eines Nicht-AD-Geräts entfernt.
- Die Verteilung übernimmt das am Nicht-AD-Ziel gebundene WinRM-Serverzertifikat in den vertrauenswürdigen Zertifikatsspeicher des Verwaltungsservers und prüft die anschließende Verbindung vollständig. Check, Download und Installation verwenden danach keine `SkipCACheck`- oder `SkipCNCheck`-Optionen mehr. Deshalb Ziele immer per DNS-Namen, nicht per IP-Adresse eintragen.
- Die JEA-Sitzung `WindowsUpdateAdm` beschränkt die Update-Befehle. Die festen, selbstlöschenden Wartungsaufgaben werden nicht über zusätzliche JEA-Rechte angelegt.
- Auf Nicht-AD-Systemen mit Windows Server 2016 ist JEA mit Client-Zertifikat nicht zuverlässig mit dem SYSTEM-Kontext kombinierbar. Check, Download und Installation legen deshalb über die bereits geprüfte HTTPS-Zertifikatsverbindung eine temporäre Aufgabe im lokalen SYSTEM-Kontext an. Sie schreibt das Ergebnis zurück und löscht sich einschließlich ihrer Arbeitsdatei nach Abschluss. AD-Systeme sowie neuere Nicht-AD-Systeme laufen weiterhin mit dem JEA-Endpunkt und virtuellem SYSTEM-Konto.
- Da Windows Update auf diesen Nicht-AD-Server-2016-Systemen im Kompatibilitätsmodus keine Downloads/Installationen zulässt, führen Check, Download und Installation dort die Update-Befehle automatisch über die geprüfte WinRM-HTTPS-Clientzertifikatsverbindung aus; für alle anderen Ziele bleibt JEA aktiv.
- Im normalen Gesamtlauf werden zusätzlich Linux und Home Assistant im Check-Modus kontaktiert. Dadurch erfolgen SSH-Schlüssel-, Schlüssel-Login- und NOPASSWD-Ersteinrichtung bereits bei der Verteilung. Sie bleiben aus Sicherheitsgründen auch bei Check, Download und Installation erhalten.
- Nach der JEA-Registrierung testet die Verteilung den Endpunkt bis zu fünfmal im Abstand von 30 Sekunden. Die Konsole meldet nur noch den kompakten Wiederholungsstatus; die Zusammenfassung enthält bei einem endgültigen Fehler die Ursache in Kurzform.

Aufruf:

```powershell
.\Verteilung_WindowsUpdateAdmConfig.ps1
```

Nur ein Windows-Ziel einrichten (Linux und Home Assistant werden dabei übersprungen):

```powershell
.\Verteilung_WindowsUpdateAdmConfig.ps1 -TargetComputer VHost00
```

### `Setup-ClientCertificate.ps1`

Erstellt oder prüft das Client-Zertifikat auf dem Verwaltungsrechner und synchronisiert dessen Fingerabdruck in die vorhandenen Settings-Dateien. Normalerweise wird es automatisch durch die Verteilung aufgerufen und muss nicht manuell gestartet werden.

### `Check-ServersUpdates.ps1`

Prüft verfügbare Windows-, Winget-, Chocolatey-, Linux- und Home-Assistant-Updates und erzeugt optional einen HTML-Bericht mit E-Mail. Standardmäßig wird der Windows-Update-Cache vor der Suche bereinigt und danach eine neue Erkennung angestoßen. Mit `ClearUpdateCacheBeforeCheck: false` kann dies je Konfiguration übersprungen werden. Linux und Home Assistant werden ohne Update, Backup oder Neustart geprüft; fehlt die SSH-Einrichtung, wird sie beim ersten Aufruf einmalig durchgeführt.

Die Konsolenausgabe bezeichnet jedes Windows-Ziel passend als AD-Ziel, Zusatzcomputer oder Hypervisor. Leere Windows-Update-Ergebnisse werden ausdrücklich als „keine Windows-Updates verfügbar“ gemeldet und erzeugen keinen leeren Tabellenkopf.

Aufruf:

```powershell
.\Check-ServersUpdates.ps1
```

### `Download-ServersUpdates.ps1`

Lädt verfügbare Windows-Updates herunter, ohne sie zu installieren. Die Auswahl der Rechner und die Verbindung folgen derselben Konfiguration wie beim Check.

Aufruf:

```powershell
.\Download-ServersUpdates.ps1
```

### `Install-ServersUpdates.ps1`

Installiert Windows-Updates sowie verfügbare Chocolatey- und Winget-Updates. Winget-Pakete werden einzeln ohne fest vorgegebenen Installer-Typ aktualisiert, sodass ein einzelnes problematisches Paket die folgenden Pakete nicht aufhält. Die Paketzeilen werden unabhängig von der variierenden Zahl der Leerzeichen zwischen den Spalten ausgewertet; Paket-ID, installierte Version, verfügbare Version und Quelle werden von rechts erkannt, damit Versionsnummern nicht als Paket-ID fehlinterpretiert werden. Wenn WinGet ein in der Gesamtliste gefundenes Update beim direkten Aufruf über die Paket-ID nicht als installiert erkennt, versucht das Skript denselben Upgrade-Aufruf mit dem exakten Anzeigenamen und derselben Quelle. Meldet WinGet einen Konflikt der Installationstechnologie, wird das Paket mit Name und ID als übersprungen protokolliert; das Skript deinstalliert nichts und fährt mit den übrigen Paketen fort. Scheitert die Registrierung einer AppX-Abhängigkeit im WinRM-Kontext mit `0x80073D19` oder `0x80070002`, meldet die Installation den betroffenen Paketnamen und die Paket-ID sowie den interaktiven WinGet-Befehl. Diese einzelnen AppX-Updates müssen direkt auf dem Zielsystem in einer angemeldeten PowerShell-Sitzung ausgeführt werden; andere WinGet-Pakete werden weiterhin automatisch verarbeitet. Auf Windows Server 2022 kann WinGet verfügbar sein; der WinRM-Remotingkontext kann jedoch keine AppX-Abhängigkeiten registrieren. WinGet beschreibt diese Einschränkung in den [WinRM-Hinweisen](https://github.com/microsoft/winget-cli/issues/256) und beim [Fehler 0x80073D19](https://github.com/microsoft/winget-cli/issues/5398). Die Winget-Ausgabe nennt zunächst die gefundenen Pakete und danach den Installationsfortschritt.

Der Installations-E-Mail-Bericht enthält einen eigenen Abschnitt „Manuelle Prüfung/Aktion erforderlich“. Dort stehen fehlgeschlagene Paketmanager-Updates, übersprungene Pakete mit Handlungsbedarf, betroffene Server sowie der konkrete Hinweis oder WinGet-Befehl, der für die manuelle Bearbeitung benötigt wird. Normale, erfolgreich automatisch installierte Updates erscheinen nicht in diesem Abschnitt. Bei fehlgeschlagenen einzelnen WinGet-Paketen zeigt die normale Konsole nur Paket, Fehlercode und den Hinweis auf manuelle Prüfung; die vollständige Installer-Ausgabe erscheint nur mit `-Debug`.

Der Installationsbericht trennt installierte Updates von für die Nachinstallation eingeplanten Updates. Die geplanten Updates werden je Server in einer Tabelle mit ComputerName, Status, KB, Size und Title aufgeführt. Ein geplanter Deferred-Update-Lauf wird nicht als „System auf dem neuesten Stand“ gemeldet.

Winget-Quellenfehler im Check-Bericht erscheinen als Warnung und werden nicht als Paketupdate gezählt.

Neustart-Ablauf:

1. Nach Windows-Updates wird mit `Get-WURebootStatus -Silent` geprüft, ob ein Neustart erforderlich ist.
2. Bei VMs erfolgt der Neustart entweder sofort (`VMRebootImmediately`) oder ab der konfigurierten Uhrzeit zeitversetzt.
3. Physische Geräte starten zum nächsten konfigurierten Zeitpunkt neu.
4. Vor dem Anlegen prüft das Skript pro Ziel die zurückgestellten Kategorien bzw. KBs. Ohne verfügbare Updates wird keine Nachinstallationsaufgabe angelegt; eine vorhandene alte Aufgabe wird gelöscht.
5. Nach einem erkannten Neustart prüft die Nachinstallationsaufgabe automatisch, ob Windows Update antwortet. Sie wiederholt die Suche alle 15 Sekunden bis zu fünf Minuten und installiert danach im offenen Wartungsfenster.
6. Sie installiert die zurückgestellten Kategorien oder KBs, versendet eine HTML-E-Mail im gleichen Layout wie der normale Installationsbericht und startet bei erneutem Neustartbedarf noch einmal neu.
7. Jeder HTML-Mailversand wird bis zu dreimal versucht, mit jeweils 30 Sekunden Abstand – auch die normalen Check-, Download- und Installationsberichte.
8. Die angelegten Aufgaben löschen sich selbst. Ein manueller Neustart verhindert einen unnötigen späteren ersten Neustart.

Ist der Verwaltungsserver selbst ein Ziel und eine VM, wird sein Neustart unabhängig von seiner Position in der Serverliste immer bis zum Ende des gesamten Installationslaufs zurückgestellt. Erst nachdem alle übrigen Ziele, Berichte und E-Mails verarbeitet wurden, wird seine Neustartaufgabe angelegt.

Gezielter Testlauf für nur einen Windows-Server; Linux und Home Assistant werden dabei übersprungen:

```powershell
.\Install-ServersUpdates.ps1 -TargetComputer SRVSVC
```

Test des Mailversands aus dem späteren SYSTEM-Kontext der Nachinstallationsaufgabe – ohne Update und ohne Neustart:

```powershell
.\Install-ServersUpdates.ps1 -TargetComputer SRVSVC -TestDeferredMail
```

Die einmalige Testaufgabe löscht sich nach dem Versand. Sie verwendet dieselben SMTP-Einstellungen wie die Nachinstallation und versucht den Versand ebenfalls bis zu dreimal. Das Ergebnis steht auf dem Zielsystem in `C:\ProgramData\WindowsUpdateAdm\DeferredUpdates.log`.

Normaler Lauf für alle konfigurierten Ziele:

```powershell
.\Install-ServersUpdates.ps1
```

### `PendingReboot.ps1`

Prüft ausstehende Neustarts zentral. Ohne Parameter werden die AD-Ziele sowie `AdditionalComputers` und `HypervisorComputers` aus der Konfiguration verwendet. AD-Ziele werden per Kerberos abgefragt, Nicht-AD-Ziele per Client-Zertifikat. Berücksichtigt Windows Update, Component-Based Servicing, ausstehende Dateiumbenennungen und – sofern vorhanden – SCCM.

```powershell
.\PendingReboot.ps1
.\PendingReboot.ps1 -ComputerName SRVSVC,SrvHv01
```

### `Updateverlauf auslesen.ps1`

Liest den Windows-Updateverlauf aus. Für eine schnelle lokale Prüfung eignet sich auch:

```powershell
Get-WUHistory
```

## Linux und Home Assistant

### `Install-Linux Updates.ps1`

Führt die konfigurierten Linux-Updates aus und schreibt die Ergebnisse für den Gesamtbericht. Linux-Hosts stehen nicht mehr fest im Skript, sondern optional in der allgemeinen `settings.json` oder mit Vorrang in `Install-Linux Updates.settings.json`:

```json
"LinuxSettings": {
  "Hosts": [
    { "Host": "srv-oc", "User": "oc-ubuntu-administrator" },
    { "Host": "srvfog", "User": "srvfog-administrator" }
  ],
  "ConnectTimeoutSeconds": 15,
  "LockWaitMinutes": 5
}
```

Ein leerer Host-Eintrag bedeutet: Linux wird ohne Fehler übersprungen. Beim ersten Kontakt wird der SSH-Schlüssel mit genau einer SSH-Passworteingabe eingerichtet. Danach richtet das Skript NOPASSWD für die eng begrenzten Update- und Reboot-Befehle mit genau einer sudo-Passworteingabe ein. Das Passwort wird dabei weder in einen Befehl eingebettet noch zum Server kopiert; Sonderzeichen funktionieren daher unverändert.

Während der Paketinstallation wird die SSH-Ausgabe sofort angezeigt und protokolliert. SSH nutzt einen konfigurierbaren Verbindungs-Timeout, zwei Verbindungsversuche sowie Keepalive-Prüfungen; interaktive Passwort-Einrichtung wird bewusst nicht automatisch wiederholt. Erfordert ein installiertes Paket einen Neustart, gelten dieselben Einstellungen aus `UpdateSettings` wie für Windows (`PhysicalRebootTime`, `PhysicalRebootWindowEndTime`, `VMRebootStartTime`, `VMRebootWindowEndTime`, `VMRebootImmediately`, `VMRebootIntervalMinutes`). Im zentralen Installationslauf werden physische Linux-Neustarts wie physische Windows-Neustarts bis nach dem VM-Neustartblock zurückgestellt; als Puffer wird eine Stunde nach dem letzten geplanten VM-Neustart eingehalten. Reicht das aktuelle physische Wartungsfenster dafür nicht aus, wird das nächste verwendet. Ein manueller Neustart beendet einen eventuell geplanten Linux-Neustart.

### `Install-HomeAssistant Updates.ps1`

Führt die konfigurierten Home-Assistant-Updates aus und schreibt die Ergebnisse für den Gesamtbericht.

Die SSH-Verbindung kann optional in der `settings.json` oder mit Vorrang in `Install-HomeAssistant Updates.settings.json` hinterlegt werden:

```json
"HomeAssistantSettings": {
  "Host": "SrvHome",
  "User": "root",
  "Port": 22
}
```

Das Skript verwendet automatisch den SSH-Schlüssel des ausführenden Benutzers und ein im System gefundenes `ssh.exe`; falls noch kein Schlüssel existiert, wird er angelegt. Ein abweichender Schlüssel- oder SSH-Pfad kann bei Bedarf weiterhin direkt als Skriptparameter übergeben werden. `default_settings.json` ist die Basis, danach überschreibt die allgemeine `settings.json` und zuletzt die skriptspezifische JSON einzelne Werte.

Auch Home Assistant folgt den gemeinsamen Neustartzeiten aus `UpdateSettings`. Im zentralen Installationslauf wird ein physischer HA-Neustart wie ein physischer Windows- oder Linux-Neustart bis nach dem VM-Neustartblock zurückgestellt und nutzt dieselbe Ein-Stunden-Puffer- und Wartungsfensterregel. Erfordert ein HA-OS-Update einen sofortigen Neustart, löst das Skript ihn aus, wartet auf die Rückkehr von SSH und Supervisor und installiert anschließend die Add-ons. Bei einem zeitlich geplanten oder deaktivierten Neustart endet der Lauf regulär; die Add-ons folgen erst nach diesem Neustart im nächsten Installationslauf. Einzelne HA-CLI-Aufrufe werden nach 300 Sekunden beendet; der Wert ist über `HomeAssistantSettings.CommandTimeoutSeconds` anpassbar. `RebootWaitSeconds` (Standard: 300) begrenzt die Wartezeit nach einem sofortigen Neustart.

Beide Skripte werden bei einem normalen Aufruf von `Install-ServersUpdates.ps1` mit ausgeführt. Mit `-TargetComputer` werden sie ausdrücklich übersprungen.

`Install-Linux Updates.ps1 -DryRun` prüft zusätzlich die verfügbaren Linux-Paketupdates, ohne eine Installation, Paketlisten-Aktualisierung oder einen Neustart auszuführen.

## Protokolle und Berichte

Unter `Logs` werden – abhängig von den Einstellungen – Protokolle und HTML-Berichte gespeichert. Die Anzahl aufbewahrter Dateien wird über `KeepLogFiles` und `KeepReportFiles` gesteuert. Die Windows-Hauptskripte verwenden dafür dieselbe zentrale Aufbewahrungslogik. Linux und Home Assistant schreiben ausführliche eigene `.log`-Dateien ausschließlich bei der Installation; bei Check und Download werden nur die für den Gesamtbericht benötigten Statusdateien erzeugt. Auch die Ausgabe in Konsole und Logdatei sowie der SMTP-Versand sind für die drei Windows-Hauptskripte zentral im Modul umgesetzt.

Die selbstlöschende Nachinstallationsaufgabe protokolliert zusätzlich direkt auf dem jeweiligen Zielsystem in `C:\ProgramData\WindowsUpdateAdm\DeferredUpdates.log`. Dort stehen die erkannte Neustartzeit, die Nachinstallationsauswahl sowie jeder Mailversuch oder SMTP-Fehler.

## Test einer verzögerten Nachinstallation

Für einen Test kann eine einzelne KB zurückgestellt und eine VM sofort neu gestartet werden:

```json
"DeferredUpdateKBs": ["KB5122871"],
"InstallDeferredUpdates": true,
"VMRebootImmediately": true,
"PhysicalRebootTime": ""
```

Danach den gezielten Lauf ausführen. Die Nachinstallation wartet nach dem Neustart automatisch auf die Bereitschaft von Windows Update.
