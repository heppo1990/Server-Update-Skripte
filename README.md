# Server Updates

Diese Sammlung verwaltet Windows-, Linux- und Home-Assistant-Updates zentral. Alle Skripte erwarten, dass sie gemeinsam in einem Verzeichnis liegen. Pfade werden jeweils relativ zum Skriptverzeichnis bestimmt.

## Automatische Skriptaktualisierung

Alle direkt ausführbaren PowerShell-Skripte prüfen beim Start den öffentlichen Branch `main` von [heppo1990/Server-Update-Skripte](https://github.com/heppo1990/Server-Update-Skripte). Dafür ist weder Git noch ein GitHub-Konto auf dem ausführenden System erforderlich; der Rechner benötigt lediglich HTTPS-Zugriff auf GitHub.

Der Updater lädt keine ZIP-Datei und keinen vollständigen Repository-Klon. Er liest die Dateiliste und Git-Datei-Hashes des aktuellen Commits und vergleicht sie mit den lokalen Dateien. Dadurch lädt er nur geänderte oder neu hinzugekommene Programm- und Begleitdateien; unveränderte Dateien werden nicht übertragen. Später neu im Repository angelegte Dateien werden automatisch berücksichtigt. `.gitignore` und Markdown-Dokumentation werden nicht auf Kundensysteme kopiert. Die Linux- und Home-Assistant-Dateien werden bei Check, Download, Installation und Verteilung nur berücksichtigt, wenn sie in den lokal wirksamen Einstellungen konfiguriert sind. Bei einem auf Windows begrenzten Lauf werden sie übersprungen.

Die lokale `settings.json`, skriptspezifische `*.settings.json`, Zertifikate, Protokolle, Berichte und Laufzeitdateien werden nicht aus GitHub geladen oder ersetzt. `default_settings.json` wird nur ergänzt, wenn sie lokal fehlt. Der Update-Metadatencache liegt unter `%ProgramData%\ServerUpdateSkripte\UpdateCache.json` und enthält nur Commit-IDs, keine Konfiguration.

Wenn sich benötigte Skriptdateien geändert haben, speichert der Updater zunächst alle Downloads zwischen, übernimmt die Dateien und startet das aufgerufene Skript mit denselben Parametern erneut. Schlägt die Verbindung oder der Download fehl, wird mit dem vorhandenen lokalen Stand fortgefahren. Der Code auf `main` wird beim nächsten Skriptstart wirksam; Änderungen an diesem Branch sollten deshalb nur von berechtigten Personen mit Schreibzugriff eingepflegt werden.

**Altinstallation aktualisieren:** Für den ersten Lauf genügen der aktualisierte Einstiegspunkt und `Update-ServerUpdateScripts.ps1`. Beim Start lädt der Updater die übrigen benötigten oder fehlenden Programmdateien anhand der GitHub-Dateihashes nach. Die `settings.json` und lokale Zertifikate bleiben erhalten. Ein Einstiegspunkt mit `-TargetComputer` überspringt optionale Linux- und Home-Assistant-Dateien.

**Einmalige Aktivierung auf bestehenden Installationen:** Bereits installierte ältere Skriptkopien kennen den Updater noch nicht. Sie müssen zunächst einmal durch die aktualisierten Skripte aus diesem Repository ersetzt werden. Ab diesem ersten Austausch aktualisieren sie sich bei jedem Start selbst.

Beim Start von `Install-ServersUpdates.ps1` mit PowerShell 7 prüft ein im Updater enthaltener Vorlauf mit Windows PowerShell 5.1, ob Winget ein PS7-Update anbietet. Wenn Winget fehlt, wird Chocolatey auf ein verfügbares Update für `powershell-core` geprüft. PS5.1 installiert das Update und startet dasselbe Installationsskript mit denselben Parametern erneut in PS7. Damit wird die aktive PS7-Instanz nicht während des Laufs ersetzt. Sind beide Paketmanager nicht installiert, läuft das Skript direkt weiter. Andere Skripte führen diese Prüfung nicht aus.

Der Update-Check wiederholt eine Remote-SYSTEM-Suche einmal nach 20 Sekunden, wenn sie nur ein leeres Ergebnisobjekt zurückgibt. Leere Zeilen werden verworfen und nicht als Updates gezählt. Bleibt die Antwort leer, meldet der Check das Ergebnis als nicht auswertbar. Die Nachinstallationsaufgabe verarbeitet alle konfigurierten zurückgestellten KBs und Kategorien gemeinsam; eine leere KB-Liste unterdrückt keine Kategorie wie `SQL`, `Exchange` oder andere später konfigurierte Werte. Sie prüft täglich im Wartungsfenster des jeweiligen Ziels (`PhysicalRebootTime` für physische Rechner, `VMRebootStartTime` für VMs) und zusätzlich beim Systemstart. Nach einem erkannten Neustart ist `DeferredUpdateDelayMinutes` eine Mindestwartezeit: Läuft sie in einem offenen Wartungsfenster ab, beginnt die Nachinstallation dann sofort; andernfalls wartet die Aufgabe bis zum nächsten Fenster. Ohne Wartungszeit wartet die Aufgabe nach dem Neustart bis zum Ende der Mindestwartezeit. Nach der Abschlussmail wird ein von `Get-WURebootStatus` bestätigter Neustart sofort ausgelöst.

`WindowsUpdate.Common.psm1` ist ein internes Modul und muss im selben Verzeichnis bleiben. Check, Download, Installation und die Verteilung verwenden daraus dieselbe Zielermittlung für AD-Computer, zusätzliche Geräte und Hypervisoren. Check und Installation verwenden zusätzlich die zentrale Ermittlung von Winget- und Chocolatey-Paketupdates. Check, Download und Installation verwenden dieselbe Logik für das Laden der Settings-Dateien, die Nicht-AD-Remoting-Vorbereitung (TrustedHosts und Client-Zertifikat), WinRM/JEA-Aufrufe mit einheitlichen Open-/Operation-Timeouts, Protokollierung, Konsolen-Zusammenfassungen, Dateiaufbewahrung und den technischen SMTP-Versand. Wiederholbare WinRM-Operationen und Remote-Aufgaben verwenden eine zentrale Retry-Logik. Linux und Home Assistant verwenden gemeinsame SSH-Optionen mit Verbindungs- und Keepalive-Timeout. Es wird nicht direkt ausgeführt. Die HTML-Inhalte und Farben der drei Berichte bleiben bewusst in den jeweiligen Skripten.

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

Wichtige Werte in `UpdateSettings`:

| Einstellung                   | Bedeutung                                                                                                                                                                                                |
|-------------------------------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|
| `TargetComputers`             | `Server` für Windows Server oder `All` für alle Windows-Computer in AD.                                                                                                                                  |
| `AdditionalComputers`         | Zusätzliche Rechner außerhalb der AD.                                                                                                                                                                    |
| `HypervisorComputers`         | Hypervisoren außerhalb der AD, z. B. `SrvHv01`.                                                                                                                                                          |
| `ClientCertThumbprint`        | Fingerabdruck des lokalen Client-Zertifikats für Nicht-AD-Ziele. Wird durch das Zertifikat-Setup synchronisiert.                                                                                         |
| `ClearUpdateCacheBeforeCheck` | `true` (Standard): Leert vor dem Update-Check Download und DataStore und stößt eine neue Erkennung an. `false`: überspringt diese Bereinigung, etwa bei häufigen Prüfungen.                              |
| `EnableWingetUpdates`         | `true` (Standard): Winget-Pakete prüfen und beim Installationslauf aktualisieren. `false`: Winget vollständig überspringen.                                                                              |
| `EnableChocolateyUpdates`     | `true` (Standard): Chocolatey-Pakete prüfen und beim Installationslauf aktualisieren. `false`: Chocolatey vollständig überspringen.                                                                      |
| `DeferredUpdateCategories`    | Kategorien, die zunächst ausgelassen werden sollen, z. B. `Exchange` und `SQL`.                                                                                                                          |
| `DeferredUpdateKBs`           | Einzelne KBs, die zunächst ausgelassen werden sollen, z. B. `KB5122871`.                                                                                                                                 |
| `InstallDeferredUpdates`      | `true`: zurückgestellte Updates werden nur dann nach dem nächsten Neustart nachinstalliert, wenn die Auswahl auf dem jeweiligen Ziel tatsächlich noch Updates enthält. `false`: sie bleiben ausgelassen. |
| `DeferredUpdateDelayMinutes`  | Wartezeit ab dem tatsächlichen Neustart bis zur Nachinstallation. `1440` entspricht 24 Stunden.                                                                                                          |
| `PhysicalRebootTime`          | Startzeit des Wartungsfensters für physische Rechner, z. B. `03:00`. Leer bedeutet: kein automatischer Neustart.                                                                                        |
| `PhysicalRebootWindowEndTime` | Spätester Beginn eines physischen Neustarts und Ende des Wartungsfensters, z. B. `05:00`. Leer lässt das Fensterende unbeschränkt.                                                                      |
| `VMRebootStartTime`           | Startzeit des VM-Wartungsfensters und Uhrzeit für die erste VM, z. B. `19:00`. Leer bedeutet: kein zeitgesteuerter VM-Neustart.                                                                         |
| `VMRebootWindowEndTime`       | Spätester Beginn eines VM-Neustarts und Ende des VM-Wartungsfensters. Leer lässt das Fensterende unbeschränkt.                                                                                           |
| `VMRebootIntervalMinutes`     | Zeitversatz jeder weiteren VM; `0` erlaubt gleichzeitige VM-Neustarts, ein positiver Wert staffelt sie.                                                                                                  |
| `VMRebootImmediately`         | `true` plant VM-Neustarts zeitnah; ein positives Intervall staffelt sie auch dann. Ein konfiguriertes Fensterende begrenzt den zulässigen Start.                                                          |

Für den Normalbetrieb kann der relevante Block beispielsweise so aussehen:

```json
"ClearUpdateCacheBeforeCheck": true,
"EnableWingetUpdates": true,
"EnableChocolateyUpdates": true,
"DeferredUpdateCategories": ["Exchange", "SQL"],
"DeferredUpdateKBs": [],
"InstallDeferredUpdates": true,
"DeferredUpdateDelayMinutes": 1440,
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

Windows-Update-Prüfungen und -Installationen führen Befehle direkt per PowerShell-Remoting aus. Für bestimmte Nicht-AD-Systeme wird ein kurzlebiger Worker unter `C:\ProgramData\WindowsUpdateAdm` als SYSTEM-Aufgabe ausgeführt; Worker-Skript und Aufgabe löschen sich nach Abschluss. Geplante Neustart- und Nachinstallationsaufgaben speichern ihren kleinen Befehlsinhalt in der Windows-Aufgabenplanung statt als Repository-Skriptdatei. Das Installationsprotokoll `C:\ProgramData\WindowsUpdateAdm\DeferredUpdates.log` bleibt für die Nachvollziehbarkeit erhalten.

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

Installiert Windows-Updates sowie verfügbare Chocolatey- und Winget-Updates. Die Winget-Ausgabe nennt zunächst die gefundenen Pakete und danach den Installationsfortschritt.

Neustart-Ablauf:

1. Nach Windows-Updates wird mit `Get-WURebootStatus -Silent` geprüft, ob ein Neustart erforderlich ist.
2. Bei VMs erfolgt der Neustart entweder sofort (`VMRebootImmediately`) oder ab der konfigurierten Uhrzeit zeitversetzt.
3. Physische Geräte starten zum nächsten konfigurierten Zeitpunkt neu.
4. Vor dem Anlegen prüft das Skript pro Ziel die zurückgestellten Kategorien bzw. KBs. Ohne verfügbare Updates wird keine Nachinstallationsaufgabe angelegt; eine vorhandene alte Aufgabe wird gelöscht.
5. Die Nachinstallationsaufgabe erkennt den tatsächlichen Neustart und wartet danach `DeferredUpdateDelayMinutes`.
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

Während der Paketinstallation wird die SSH-Ausgabe sofort angezeigt und protokolliert. SSH nutzt einen konfigurierbaren Verbindungs-Timeout, zwei Verbindungsversuche sowie Keepalive-Prüfungen; interaktive Passwort-Einrichtung wird bewusst nicht automatisch wiederholt. Erfordert ein installiertes Paket einen Neustart, gelten dieselben Einstellungen aus `UpdateSettings` wie für Windows (`PhysicalRebootTime`, `VMRebootStartTime`, `VMRebootImmediately`, `VMRebootIntervalMinutes`). Ein manueller Neustart beendet einen eventuell geplanten Linux-Neustart.

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

Auch Home Assistant folgt den gemeinsamen Neustartzeiten aus `UpdateSettings`. Erfordert ein HA-OS-Update einen sofortigen Neustart, löst das Skript ihn aus, wartet auf die Rückkehr von SSH und Supervisor und installiert anschließend die Add-ons. Bei einem zeitlich geplanten oder deaktivierten Neustart endet der Lauf regulär; die Add-ons folgen erst nach diesem Neustart im nächsten Installationslauf. Einzelne HA-CLI-Aufrufe werden nach 300 Sekunden beendet; der Wert ist über `HomeAssistantSettings.CommandTimeoutSeconds` anpassbar. `RebootWaitSeconds` (Standard: 300) begrenzt die Wartezeit nach einem sofortigen Neustart.

Beide Skripte werden bei einem normalen Aufruf von `Install-ServersUpdates.ps1` mit ausgeführt. Mit `-TargetComputer` werden sie ausdrücklich übersprungen.

`Install-Linux Updates.ps1 -DryRun` prüft zusätzlich die verfügbaren Linux-Paketupdates, ohne eine Installation, Paketlisten-Aktualisierung oder einen Neustart auszuführen.

## Protokolle und Berichte

Unter `Logs` werden – abhängig von den Einstellungen – Protokolle und HTML-Berichte gespeichert. Die Anzahl aufbewahrter Dateien wird über `KeepLogFiles` und `KeepReportFiles` gesteuert. Die Windows-Hauptskripte verwenden dafür dieselbe zentrale Aufbewahrungslogik. Linux und Home Assistant schreiben ausführliche eigene `.log`-Dateien ausschließlich bei der Installation; bei Check und Download werden nur die für den Gesamtbericht benötigten Statusdateien erzeugt. Auch die Ausgabe in Konsole und Logdatei sowie der SMTP-Versand sind für die drei Windows-Hauptskripte zentral im Modul umgesetzt.

Die selbstlöschende Nachinstallationsaufgabe protokolliert zusätzlich direkt auf dem jeweiligen Zielsystem in `C:\ProgramData\WindowsUpdateAdm\DeferredUpdates.log`. Dort stehen die erkannte Neustartzeit, die Nachinstallationsauswahl sowie jeder Mailversuch oder SMTP-Fehler.

## Test einer verzögerten Nachinstallation

Nur für eine Test-VM kann die Wartezeit vorübergehend verkürzt werden:

```json
"DeferredUpdateKBs": ["KB5122871"],
"InstallDeferredUpdates": true,
"DeferredUpdateDelayMinutes": 5,
"VMRebootImmediately": true,
"PhysicalRebootTime": ""
```

Danach den gezielten Lauf ausführen. Nach erfolgreichem Test die Werte wieder auf die normalen Kategorien und `1440` Minuten zurückstellen.
