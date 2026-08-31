# Immich — Self-hosted Foto-/Video-Backup

Persönliches Foto- und Video-Backup auf Andyserver. Läuft komplett containerisiert über Colima (Docker-Runtime) + Docker Compose, offizielles Immich-Deployment (kein natives macOS-Binary, nur Docker wird von Immich unterstützt).

---

## Architektur

```
Colima (Docker-Runtime, launchd-Autostart)
  └─ Docker Compose
       ├─ immich-server          (API + Web-UI, Port 2283)
       ├─ immich-machine-learning (Gesichtserkennung, Objekterkennung)
       ├─ postgres                (Datenbank)
       └─ redis                  (Cache/Queue)
```

## Zugriff

**http://andyserver.fritz.box:2283**

Aktuell nur im LAN erreichbar, kein HTTPS, kein Internet-Zugriff.

---

## Setup (Stand jetzt)

- Colima via `brew install colima docker docker-compose` installiert (Docker CLI + `docker-compose` Standalone-Binary; `docker compose` als Subcommand ist **nicht** verfügbar, daher `docker-compose` mit Bindestrich verwenden)
- Colima-Autostart über System-`launchd`-**LaunchDaemon** `/Library/LaunchDaemons/local.colima.plist` (`UserName: andy`) → führt `start-colima.sh` aus (Ressourcen: **8 CPU / 12 GB RAM** / 100 GB Disk — Obergrenzen, siehe `start-colima.sh`; M4 mini hat 10 Kerne / 16 GB. War anfangs 4/8, für den Google-Import hochgesetzt). Das Skript räumt vor `colima start` per `colima stop --force` **veralteten Laufzeit-Zustand** weg (`*.pid`/`*.sock` unter `~/.colima/_lima/colima/`), der nach einem unsauberen Shutdown — erzwungener Reboot durch macOS-Update, Stromausfall, Kernel-Panic — sonst `colima start` scheitern lässt (`error starting vm: exit status 1`); der Daemon hat kein Retry. **Hintergrund:** genau das ist am 2026-08-28 nach einem macOS-Update passiert — Immich kam nicht von selbst hoch.
- Container-Autostart über System-LaunchDaemon `/Library/LaunchDaemons/local.immich.plist` (`UserName: andy`) → führt `start-immich.sh` aus: wartet ~60 Sek. auf Colimas Docker-Daemon; kommt der nicht, ruft es **`start-colima.sh` als Fallback** auf (Startreihenfolge der beiden Daemons ist damit egal), wartet nochmal bis zu 2 Min, und führt dann `docker-compose up -d` aus
- Beide laufen als **LaunchDaemons statt LaunchAgents**, damit sie unabhängig von einer eingeloggten GUI-Session laufen (auf einem headless Server kann die Konsolen-Session enden — z.B. nach einer Bildschirmfreigabe-Sitzung — wodurch `gui/<uid>`-LaunchAgents sterben; `system`-Domain-LaunchDaemons sind davon unabhängig, genau wie nginx bei PrivatPortfolio). Quelldateien liegen zur Referenz auch unter `~/Servers/Immich/local.colima.plist` / `local.immich.plist`; Installieren/Updates brauchen `sudo` (`sudo launchctl bootstrap system ...`).
- `docker-compose.yml` + `.env` von der offiziellen Immich-Release-Seite geladen:
  ```bash
  curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
  curl -fsSL -o .env https://github.com/immich-app/immich/releases/latest/download/example.env
  ```
- `.env` angepasst gegenüber dem Default:
  - `UPLOAD_LOCATION` und `DB_DATA_LOCATION` auf absolute Pfade gesetzt statt relativ (inzwischen `UPLOAD_LOCATION=/Volumes/ServerData/pictures` auf externer SSD, `DB_DATA_LOCATION=~/Servers/Immich/postgres` intern — siehe [Externe Platte](#externe-platte-für-die-library))
  - `TZ=Europe/Berlin` gesetzt
  - `DB_PASSWORD` auf ein generiertes zufälliges Passwort geändert (Default war `postgres`)

---

## Bedienung

| Aktion | Befehl |
|---|---|
| Starten | `cd ~/Servers/Immich && docker-compose up -d` |
| Stoppen | `docker-compose down` |
| Status | `docker ps` |
| Logs | `docker logs immich_server -f` (analog `immich_machine_learning`, `immich_postgres`, `immich_redis`) |
| Update | Neue `docker-compose.yml`/`.env` von der Release-Seite laden (s.o.), Werte aus der alten `.env` übertragen, dann `docker-compose pull && docker-compose up -d` |
| Colima hängt / kommt nicht hoch | `bash ~/Servers/Immich/start-colima.sh` (macht `colima stop --force` + `colima start`); danach `bash ~/Servers/Immich/start-immich.sh` |
| Startskripte neu installieren | nach Änderung an `local.colima.plist`: `sudo launchctl bootout system/local.colima; sudo cp ~/Servers/Immich/local.colima.plist /Library/LaunchDaemons/; sudo launchctl bootstrap system /Library/LaunchDaemons/local.colima.plist` (analog `local.immich`) |

**Neustart von Andyserver:** kompletter Autostart beim Boot, kein manueller Schritt und kein Login nötig — die LaunchDaemons starten unabhängig von jeder GUI-Session (siehe oben). Rechne mit 1-2 Minuten, bis Immich nach einem Neustart wieder erreichbar ist (VM-Boot + Container-Healthchecks).

---

## Fotos importieren (Bestands-Migration)

Alte Fotosammlung liegt auf der NAS: SMB-Share `//192.168.178.38/Data/Pictures/` mit je einem
Ordner pro Person (`Andy_Pics`, `Steffi_Pics`, `Lilly_Pics`) — D-Link DNS-325 „bormankserver",
User `andy`. Die NAS ist zu langsam für eine dauerhafte externe Bibliothek — die Bilder werden
**einmalig in Immichs eigene Ablage kopiert**.

### Ablauf (verwendet für die Voll-Migration 2026-08-31)

**Mit immich-go `from-folder`**, ausgeführt **vom Mac Studio** (NAS dort nativ als `/Volumes/Data`
gemountet, mini per Thunderbolt-Bridge `http://10.10.10.1:2283` erreichbar — schneller als die
Colima-VM). `--api-key` bestimmt das Zielkonto, für jede Person deren eigener Key.

```bash
# 1. ML-Queues pausieren (auf dem mini) — sonst bricht der Upload unter Last ab:
for q in smartSearch faceDetection facialRecognition ocr duplicateDetection; do
  curl -s -X PUT -H "x-api-key: <ADMIN_KEY>" -H "Content-Type: application/json" \
    -d '{"command":"pause"}' "http://localhost:2283/api/jobs/$q"
done

# 2. Trockenlauf, dann ohne --dry-run:
immich-go upload from-folder \
  --server=http://10.10.10.1:2283 \
  --api-key=<PERSONEN_KEY> --admin-api-key=<ADMIN_KEY> \
  --pause-immich-jobs=false \
  --concurrent-tasks=4 --on-errors=continue --session-tag \
  --exclude-extensions=.cr2,.CR2,.arw,.nef,.dng,.lrcat \
  --dry-run \
  "/Volumes/Data/Pictures/<Person>_Pics"

# 3. Danach ML wieder resumen (erst Metadaten/Thumbnails leerlaufen lassen).
```

- `--on-errors=continue` **zwingend** — Default `stop` bricht beim ersten Timeout komplett ab.
- `--pause-immich-jobs=false`, weil die ML manuell gesteuert wird (sonst gibt immich-go am Ende
  *alle* Queues frei, auch die manuell pausierten).
- immich-go ist resumierbar (Hash-Dedup) — nach Abbruch einfach nochmal.
- `--exclude-extensions` filtert RAW. immich-go zieht (anders als die alte Immich-CLI) keine
  `*.files/`-Thumbnail-Ordner mit. Trotzdem nach dem Import **Papierkorb / Duplikate prüfen**.
- Läuft ein Personen-Import parallel zu einem anderen Import auf **dasselbe Konto**? Nicht machen
  (doppeltes Hashing, Album-/Dedup-Logik kollidiert) — nacheinander.

### Fallback: Immich-CLI-Container mit NAS-Mount in der Colima-VM

Wenn der Studio nicht verfügbar ist. Langsamer, NAS-über-VM-CIFS ist fragiler.

1. **NAS in der Colima-VM mounten** (die NAS kann nur SMB 2.0, Umlaute brauchen `iocharset=utf8`
   → einmalig `cifs-utils` + `linux-modules-extra-$(uname -r)` in der VM nachinstallieren):
   ```bash
   colima ssh -- sudo sh -c 'apt-get install -y cifs-utils linux-modules-extra-$(uname -r); modprobe nls_utf8; mkdir -p /mnt/andy_pics'
   colima ssh -- sudo mount -t cifs "//192.168.178.38/Data/Pictures/Andy_Pics" /mnt/andy_pics \
     -o username=andy,password=XXX,ro,vers=2.0,iocharset=utf8
   ```
2. **Import per immich-cli-Container** (im selben Docker-Netz wie Immich, kein Node auf dem Mac nötig):
   ```bash
   docker run --rm --network immich_default \
     -e IMMICH_INSTANCE_URL=http://immich-server:2283/api \
     -e IMMICH_API_KEY=<frischer_key> \
     -v "/mnt/andy_pics:/import:ro" \
     ghcr.io/immich-app/immich-cli:latest upload --recursive \
       --ignore '**/*.files/**' \
       --ignore '**/*.CR2' --ignore '**/*.cr2' \
       --ignore '**/*.lrcat*' \
       "/import/01_Pics/Ausflüge&Events/2003"
   ```
3. Nach dem Import **NAS wieder aushängen:** `colima ssh -- sudo umount /mnt/andy_pics`

### ⚠️ `--ignore`-Filter nicht vergessen

Die Immich-CLI hat **keinen** persistenten Filter — die `--ignore`-Patterns müssen bei
**jedem** Aufruf mitgegeben werden. Ohne sie landet Müll in Immich:

| Pattern | fängt weg |
|---|---|
| `**/*.files/**` | `Foo.jpg.files/vcm_s_kf_*.jpg` — Thumbnails eines alten Windows-Bildbetrachters (2 pro Originalfoto!) |
| `**/*.CR2` `**/*.cr2` | Canon-RAWs (~35 GB, sollen nicht mit) |
| `**/*.lrcat*` | Lightroom-Kataloge |

`.DS_Store`, `._*`, `Thumbs.db`, `*.db`, `*.ini` ignoriert die CLI von sich aus.

**Beim ersten POC-Import (Ordner 1992–2002) fehlte der Filter** → 275 `vcm_s_kf_*`-Thumbnails
mussten nachträglich per API (Suche nach `originalFileName` Präfix `vcm_s_kf`) in den Papierkorb
verschoben werden. Also: nach jedem Import einmal **Papierkorb / Duplikate in Immich prüfen**.

### API-Key

Für die CLI einen API-Key anlegen (Immich → Profilbild → *Konto-Einstellungen* → *API-Schlüssel*),
nach der Migration wieder löschen. Nicht ins Repo committen.

Die aktuell aktiven Import-Keys (andy/Admin, Lilly, Steffi) liegen in
**`import-api-keys.local.md`** – gitignored, nicht in Git. Nach Abschluss aller Importe
dort löschen und in Immich widerrufen.

---

## Google Photos / Takeout-Import

Google-Takeout-Archive **mit Alben** importieren. Die normale Immich-CLI kann keine
Takeout-Alben → **[`immich-go`](https://github.com/simulot/immich-go)** (v0.32): liest die ZIPs
direkt, wertet die `.json`-Sidecars aus (Datum, GPS, Beschreibung, Favorit, archiviert), baut
die **benannten Alben** nach, stapelt Live/Motion Photos.

**Immer ins Konto des `--api-key`-Besitzers** — jeder Nutzer braucht einen eigenen Key aus
seinem Konto (Keys: `import-api-keys.local.md`). `--admin-api-key` bleibt andys Admin-Key.

**Status (alle 2026-08-31):**

| Konto | vorher | nachher | Alben |
|---|---|---|---|
| andy | 5.265 | 55.338 | 4 → 317 |
| Lilly | 10.513 | 14.023 | — |
| Steffi | läuft | — | — |

### Regeln

- **Alle ZIPs eines Takeouts zusammen** in einem Aufruf — Google verteilt Fotos und Alben quer
  über die Archive. Einzeln = unvollständige Alben.
- ZIPs **nicht entpacken**. Auf dem Mac Studio unter `~/Downloads/` lassen, Glob auf den
  Takeout-Zeitstempel: `~/Downloads/takeout-<TS>-*.zip` (matcht nur diesen einen Takeout).
- Erst `--dry-run` (zeigt Alben-/Fotozahl), dann echt.
- **Reihenfolge:** erst Google-Takeout (bringt Alben), dann NAS-Rest, dann Duplikat-Ansicht.
- Nicht zwei Importe gleichzeitig auf **dasselbe Konto**.

### ⚠️ Lehren aus dem 1. Lauf (kostete Stunden)

1. **`--admin-api-key` zwingend mitgeben.** `--pause-immich-jobs` ist zwar Default-`true`, greift
   aber nur mit einem *separaten* Admin-Key (kann derselbe sein, wenn der User Admin ist). Ohne
   ihn laufen 24 parallele Uploads (`--concurrent-tasks` Default!) ungebremst → die VM
   kollabiert (Load 17, Server-Timeouts), nur ~40 % kommen an, Rest „pending".
2. **`--concurrent-tasks=6`** — der Flaschenhals ist Immichs Ingest, nicht das Netz.
3. immich-go ist **resumierbar** (Hash-Dedup) — nach Abbruch einfach nochmal mit obigen Flags.
4. immich-go gibt am Ende **alle** Job-Queues frei — auch manuell pausierte. Nach „Upload
   completed" die ML-Queues sofort wieder pausieren (s.u.).

### Ablauf

Läuft am schnellsten **vom Mac Studio über eine Thunderbolt-Bridge** (beide Macs sonst im WLAN;
mini per TB-IP `http://10.10.10.1:2283` erreichbar). immich-go ist ein einzelnes Binary
(`brew install immich-go` oder Release von GitHub, `Darwin_arm64`).

```bash
# Trockenlauf
immich-go upload from-google-photos \
  --server=http://10.10.10.1:2283 --api-key=<KEY> --dry-run \
  takeout-*.zip

# Echt
immich-go upload from-google-photos \
  --server=http://10.10.10.1:2283 \
  --api-key=<KEY> --admin-api-key=<ADMIN_KEY> \
  --concurrent-tasks=6 --session-tag \
  takeout-*.zip
```

### Server vorbereiten (bei großen Importen)

- **Colima temporär hochdrehen** — steht in `start-colima.sh` auf `--cpu 8 --memory 12` (M4 mini
  hat 10 Kerne / 16 GB). Job-Concurrency in Immich (*Administration → Einstellungen → Aufträge*)
  auf metadata 10 / thumbnail 6.
- **ML-Queues pausieren** während des Imports (der Python-ML-Prozess ist der größte CPU-Fresser):
  ```bash
  for q in smartSearch faceDetection facialRecognition ocr duplicateDetection; do
    curl -s -X PUT "http://localhost:2283/api/jobs/$q" -H "x-api-key: <KEY>" \
      -H 'content-type: application/json' -d '{"command":"pause"}'
  done
  ```
  Nach dem Import: erst Metadaten+Thumbnails leerlaufen lassen, dann dieselben Queues mit
  `{"command":"resume"}` — Gesichter/CLIP-Suche/OCR brauchen für ~68k Fotos 6–12 h.

**Nicht mitkommt:** Googles Gesichtsgruppen (Immich macht eigene), Freigaben.

### ⚠️ Takeout enthält keine mit dir geteilten Fremdfotos

Takeout exportiert **nur Fotos, die dir gehören** (selbst hochgeladen). Bilder, die andere mit
dir geteilt haben — auch wenn du sie in **deine eigenen Alben** gelegt hast — bleiben im Konto
des Uploaders und fehlen im Takeout. Bei andys Import betraf das ~30–40 Alben (teils viele
Fotos pro Album).

**Nacharbeit (album-weise, erhält die Gruppierung):**

1. Zuerst prüfen: 2–3 betroffene Alben in Immich vs. Google Fotos vergleichen — nur wenige
   Fehlende = Kosmetik, fast leere Alben = Aufwand lohnt.
2. Google Fotos (Web) → Album öffnen → `⋯` → *Alle herunterladen* → ZIP je Album. Alle unter
   **einen** Elternordner entpacken, **Ordnername = Albumname**:
   `~/Downloads/gphotos-shared/<Albumname>/…`
3. **Ein** immich-go-Lauf über den Elternordner (dedupt per Hash, gefahrlos wiederholbar,
   nur die fehlenden Fremdfotos landen im jeweiligen Album):
   ```bash
   immich-go upload from-folder \
     --server=http://10.10.10.1:2283 \
     --api-key=<ANDY_KEY> --admin-api-key=<ANDY_KEY> \
     --pause-immich-jobs=false --concurrent-tasks=4 --on-errors=continue \
     --folder-as-album=folder --session-tag \
     ~/Downloads/gphotos-shared/
   ```
4. Erst machen, wenn kein ML-Durchlauf läuft (keine zusätzliche Upload-Last).

Zu viel Klickerei bei 40 Alben? `gphotos-cdp` (steuert Chrome per DevTools-Protokoll, lädt auch
geteilte Inhalte) — ein Durchlauf statt 40, dafür fummeliger Setup.

**Familien-Alternative:** Steffi/Lilly haben ihre Fotos schon in ihren eigenen Immich-Konten →
in Immich ein **gemeinsames Album** anlegen statt die Fotos zu duplizieren.

---

## Wichtige Pfade

| Pfad | Inhalt |
|---|---|
| `/Volumes/ServerData/pictures` | `UPLOAD_LOCATION` — externe SSD (siehe [Externe Platte](#externe-platte-für-die-library)) |
| `/Volumes/ServerData/pictures/library/<user>/JAHR/JAHR-MM-TT/` | Originale mit echten Dateinamen (Storage Template, s.u.) |
| `/Volumes/ServerData/pictures/upload/` | nur noch Upload-Zwischenspeicher |
| `/Volumes/ServerData/pictures/backups/` | automatische Immich-DB-Dumps (nächtlich) |
| `~/Servers/Immich/postgres` | Datenbank — **bleibt intern** |
| `~/Servers/Immich/docker-compose.yml` | Compose-Definition (von Immich vorgegeben, i.d.R. nicht anfassen) |
| `~/Servers/Immich/.env` | Konfiguration + Secrets (DB-Passwort) — **nicht committen** |
| `~/Servers/Immich/start-colima.sh` | startet Colima idempotent + räumt veralteten Zustand auf; von `local.colima.plist` und als Fallback von `start-immich.sh` aufgerufen |
| `~/Servers/Immich/start-immich.sh` | wartet auf Docker (Fallback: `start-colima.sh`), dann `docker-compose up -d`; von `local.immich.plist` aufgerufen |
| `~/Servers/Immich/local.colima.plist`, `local.immich.plist` | Referenzkopien der aktiven LaunchDaemons unter `/Library/LaunchDaemons/` |

---

## Offene Punkte / TODO

- [x] **Docker-Compose-Autostart** nach Reboot — LaunchAgent `local.immich.plist` + `start-immich.sh`
- [x] **Storage Template + Datenportabilität** — Template `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}` aktiv, Bestand migriert
- [x] **Library auf externe SSD** umgezogen (2026-08-31) — `/Volumes/ServerData/pictures`, siehe [Externe Platte](#externe-platte-für-die-library)
- [x] **NAS-Bestands-Migration andy** (2026-08-31) — `01_Pics` komplett per immich-go `from-folder`, ~55k → 67k Assets (RAW ausgeschlossen)
- [x] **NAS-Bestands-Migration Steffi** (2026-08-31) — `Steffi_Pics`
- [ ] **NAS-Bestands-Migration Lilly** — `Lilly_Pics` (analog, Lillys Key). Ablauf siehe [Fotos importieren](#fotos-importieren-bestands-migration)
- [x] **Google-Takeout-Import andy** (2026-08-31) — 5.265 → 55.338 Assets, 317 Alben. Siehe [Google Photos / Takeout](#google-photos--takeout-import)
- [x] **Google-Takeout-Import Lilly** (2026-08-31) — 10.513 → 14.023 Assets
- [ ] **Google-Takeout-Import Steffi** — läuft 2026-08-31
- [ ] **Geteilte Fremdfotos nachholen** — ~30–40 andy-Alben, in denen Takeout die mit ihm geteilten Bilder Dritter ausgelassen hat. Album-weiser Download + immich-go, siehe [Takeout enthält keine Fremdfotos](#️-takeout-enthält-keine-mit-dir-geteilten-fremdfotos)
- [ ] **Nach ML-Durchlauf: Duplikat-Ansicht** durchgehen (Google-Neukomprimierung vs. NAS-Original). ⚠️ Beim Löschen eines Duplikats übernimmt Immich die **Album-Zuordnung des gelöschten Assets nicht** aufs behaltene — vorher Alben notieren.
- [ ] **Nach allen Importen:** Import-Keys in Immich widerrufen + `import-api-keys.local.md` leeren; Colima ggf. von 8 CPU/12 GB zurückdrehen
- [ ] **rsync-Backup auf die NAS** einrichten — Library (`/Volumes/ServerData/pictures/library/`) + DB-Dumps (`…/backups/`) regelmäßig per `rsync` auf die NAS spiegeln (bisher liegt alles nur auf der einen externen SSD).
- [ ] **DB-Backups auf anderes Medium** — die nächtlichen Dumps liegen unter `pictures/backups/` auf **derselben** externen Platte wie die Library. Für echten Schutz woanders hin kopieren (interne SSD / NAS / Cloud) — deckt der rsync-Punkt oben mit ab.
- [ ] **Öffentlicher Zugang** (Zugriff von unterwegs ohne WireGuard, z.B. für Mobile-Auto-Backup) — nginx-Reverse-Proxy + Let's Encrypt + FRITZ!Box-Portfreigabe + DynDNS. Kein DS-Lite vorhanden, FRITZ!Box kann DynDNS → machbar. Schritt für Schritt siehe [Öffentlicher Zugang (geplant)](#öffentlicher-zugang-geplant)

---

## Externe Platte für die Library

**Umgezogen am 2026-08-31.** Die Library (Originale + Thumbnails + Encoded-Video + DB-Backups,
`UPLOAD_LOCATION`) liegt auf einer externen USB-SSD. **Postgres bleibt auf der internen SSD.**

| | |
|---|---|
| Platte | Crucial X9 2 TB (USB 3.2 Gen 2 SSD), APFS case-insensitive, Volume **`ServerData`** |
| Mountpoint | `/Volumes/ServerData` |
| `UPLOAD_LOCATION` | `/Volumes/ServerData/pictures` (Immich legt darunter `library/`, `thumbs/`, `encoded-video/`, `upload/`, `backups/`, `profile/` an) |
| `DB_DATA_LOCATION` | unverändert `~/Servers/Immich/postgres` (intern) |
| Sentinel | `/Volumes/ServerData/pictures/.disk-present` — von `start-colima.sh` / `start-immich.sh` geprüft |

### Warum bleibt Postgres intern?

- Immich-Doku: DB **nicht** auf Netzlaufwerken — eine extern angesteckte Platte hat dasselbe
  Risiko: wird sie im Betrieb getrennt oder schläft ein, korrumpiert die laufende Postgres-Instanz
- Postgres braucht latenzarme `fsync`-Writes; interne SSD ist dafür besser als USB
- Die DB ist klein (Metadaten, keine Bilddaten)

### ⚠️ Colima `mounts:` ersetzt den `$HOME`-Default — nicht ergänzen!

**Die Falle beim Umzug (einmal reingefallen):** Sobald in `~/.colima/default/colima.yaml`
ein `mounts:`-Block steht, mountet Colima `$HOME` (`/Users/andy`) **nicht mehr automatisch**.
Trägt man dort nur die externe Platte ein, verschwindet `/Users/andy` aus der VM → der
Postgres-Bind-Mount (`~/Servers/Immich/postgres`) zeigt ins Leere → Postgres legt eine
**frische leere DB** an, Immich meldet „0 Assets". (Die echte DB bleibt unangetastet auf dem
Host — Fix: `/Users/andy` mit eintragen, `colima restart`, Container neu.)

Korrekte `colima.yaml`:
```yaml
mountType: virtiofs
mounts:
  - location: /Users/andy
    writable: true
  - location: /Volumes/ServerData
    writable: true
```

### Start-Absicherung

Wenn die Platte beim Boot **nicht** gemountet ist und die Container trotzdem starten, schreibt
Immich in ein leeres Verzeichnis → scheinbarer Totalverlust. Deshalb:

- **`start-colima.sh`** wartet bis ~90 s auf `.../pictures/.disk-present`, startet Colima
  danach notfalls trotzdem (damit Paperless nicht blockiert wird)
- **`start-immich.sh`** startet Immich **hart nicht**, wenn `.disk-present` am Host fehlt; ist
  die Platte am Host aber nicht in der VM sichtbar (Colima startete zu früh), macht es einmal
  `colima restart`

### Kür für den Umzug (falls nochmal nötig)

1. Platte als APFS formatieren: `diskutil eraseDisk APFS ServerData GPT /dev/diskN`, `sudo pmset -a disksleep 0`
2. `mkdir -p /Volumes/ServerData/pictures`
3. `cd ~/Servers/Immich && docker-compose down`
4. `rsync -aH ~/Servers/Immich/library/ /Volumes/ServerData/pictures/`
5. Sentinel: `date > /Volumes/ServerData/pictures/.disk-present`
6. `.env`: `UPLOAD_LOCATION=/Volumes/ServerData/pictures`
7. `colima.yaml`: **beide** Mounts (s.o.), dann `colima restart`
8. Prüfen: `colima ssh -- ls /Users/andy/Servers/Immich/postgres/PG_VERSION` **und** `.../pictures`
9. `docker-compose up -d`, in der DB `select count(*) from asset;` gegenprüfen
10. altes `~/Servers/Immich/library/` löschen

---

## Öffentlicher Zugang (geplant)

Ziel: Immich von unterwegs erreichbar ohne WireGuard (z.B. Mobile-Auto-Backup außerhalb
des Heimnetzes). Weg: **nginx-Reverse-Proxy + Let's Encrypt + FRITZ!Box-Portfreigabe + DynDNS**.

**Voraussetzungen (geprüft):** kein DS-Lite/CGNAT, FRITZ!Box kann DynDNS → machbar.
nginx läuft bereits auf dem Mac (Homebrew-LaunchDaemon `homebrew.mxcl.nginx`, bedient schon
PrivatPortfolio via `/opt/homebrew/etc/nginx/servers/portfolio.conf`).

### Phase 1 — DynDNS / Domain

- **Einfach/kostenlos:** FRITZ!Box → *Internet → MyFRITZ!-Konto* → `<hash>.myfritz.net`.
  FRITZ!Box hält DNS (v4+v6) automatisch aktuell. Let's Encrypt stellt für `*.myfritz.net` aus.
- **Alternativ:** eigene Domain (~12 €/Jahr) + FRITZ!Box → *Internet → Freigaben → DynDNS*
  mit Update-URL des Registrars/Cloudflare. Erlaubt frei wählbare Subdomain wie `fotos.example.de`.
- Feste interne IP für den Mac mini: FRITZ!Box → *Heimnetz → Netzwerk → [Mac] → „Immer die
  gleiche IPv4-Adresse zuweisen"*.

### Phase 2 — FRITZ!Box Portfreigaben

*Internet → Freigaben → Portfreigaben*, Ziel Mac mini:

| Extern | → Intern | Zweck |
|---|---|---|
| TCP **443** | :443 | HTTPS |
| TCP **80** | :80 | Let's Encrypt HTTP-01 + HTTP→HTTPS-Redirect |

Port **2283 nicht** freigeben. Bei aktivem IPv6 die Freigaben zusätzlich für die
IPv6-Adresse des Mac setzen (FRITZ!Box trennt v4/v6).

### Phase 3 — Reverse Proxy + TLS auf dem Mac

```bash
brew install certbot
```

Neuer Server-Block `/opt/homebrew/etc/nginx/servers/immich.conf`:

- `server_name immich.<hash>.myfritz.net;` — **Achtung:** `portfolio.conf` hat aktuell
  `server_name _;` (Catch-all auf 443). Beim zweiten HTTPS-Host beide auf echte Namen setzen
  bzw. genau einen als `default_server` markieren.
- Port 80: nur ACME-Webroot ausliefern, Rest `return 301 https://$host$request_uri;`
- Port 443 `ssl`: `proxy_pass http://127.0.0.1:2283;` mit den Immich-Pflicht-Optionen:
  - `client_max_body_size 0;` — große Videos
  - `proxy_read_timeout 600s; proxy_send_timeout 600s;` — lange Uploads
  - `proxy_http_version 1.1;` + `Upgrade`/`Connection`-Header — **WebSockets** (Live-Update)
  - `proxy_buffering off;`
  - `Host` / `X-Real-IP` / `X-Forwarded-For` / `X-Forwarded-Proto` (wie im portfolio-Block)

Zertifikat (Port 80 muss von außen erreichbar sein):
```bash
certbot certonly --webroot -w <acme-webroot> -d immich.<hash>.myfritz.net
# Cert unter /opt/homebrew/etc/letsencrypt/live/…
```
Auto-Renew per LaunchDaemon/cron, 1×/Tag: `certbot renew --quiet && /opt/homebrew/bin/nginx -s reload`

Dann `nginx -t && nginx -s reload`.

### Phase 4 — Immich konfigurieren

- *Administration → Einstellungen → Server* → **Externe Domain** = `https://immich.<hash>.myfritz.net`
- Test **von außen** (Mobilfunk): Login, großer Video-Upload, Live-Aktualisierung (WebSocket)
- Mobile-App: öffentliche Server-URL (App wechselt pro Netzwerk zwischen intern/extern)

### Phase 5 — Härtung (Pflicht, sobald öffentlich)

- Immich: **Registrierung deaktivieren** (*Einstellungen → Authentifizierung*), **2FA** für
  alle Konten, starke Passwörter, initiale `shouldChangePassword` erledigen
- nginx: Rate-Limit auf `/api/auth/login` (`limit_req_zone` / `limit_req`)
- Immich aktuell halten, Release-Notes auf Security-Fixes prüfen
- Logs beobachten: `docker logs immich_server -f`, nginx `access.log`/`error.log`
- Optional: GeoIP-Filter (nur DE) im nginx
- Backups laufen weiter (`library/backups/`) + Library-Backup separat
- Überlegung: WireGuard als Hauptzugang behalten, öffentlich nur das Nötige — kleinere
  Angriffsfläche. FRITZ!Box kann WireGuard nativ für weitere Personen.

### Alternativen ohne offenen Port

| Weg | Vorteil | Haken |
|---|---|---|
| **Cloudflare Tunnel** (`cloudflared`) | kein Portforwarding/DynDNS, hinter CGNAT, TLS automatisch | Daten laufen über Cloudflare; **Free-Tier 100 MB Upload-Limit pro Request** → große Videos scheitern (bekanntes Immich-Problem) |
| **Tailscale Funnel** | HTTPS-Endpoint ohne Portforwarding | über Tailscale-Relays, Durchsatzgrenzen |
| **WireGuard behalten** | minimale Angriffsfläche | Nutzer brauchen Client/Profil |

Da kein DS-Lite vorliegt und Immich große Uploads macht, ist der eigene Port + Let's Encrypt
hier der sauberere Weg gegenüber den Tunneln.

---

## Datenportabilität / Wechsel zu anderem Fotosystem

Anspruch: Auch in einigen Jahren müssen sich alle Fotos+Videos **verlustfrei und mit Metadaten** aus Immich herauslösen lassen, ohne auf Immich angewiesen zu sein.

### Was Immich mit den Dateien macht

- **Originale werden nie verändert oder umkodiert** — nur auf der Platte in `<uuid>.<ext>` umbenannt und unter `library/upload/<user-id>/xx/yy/` abgelegt
- EXIF/Metadaten *in* der Datei (Aufnahmedatum, Kamera, GPS) bleiben unangetastet
- **Immich-eigene** Zusatzinfos (Alben, erkannte Gesichter/Namen, manuelle Tags, Favoriten, Beschreibungen, Datums-Korrekturen) liegen **nur in Postgres**

### Storage Template — ✅ aktiv

*Administration → Einstellungen → Speicher-Template*, Template:
```
{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}   →  library/library/admin/2002/2002-10-14/peteraufBär.jpg
```
Tag-Ebene = praktisch keine Namenskollisionen. Damit ist `library/library/` schon **ohne Immich/DB**
ein sauberer, nach Datum sortierter Baum der unveränderten Originale mit echten Dateinamen.
Bestandsdateien wurden per *Auftrags-Warteschlange → Speicher-Template-Migration* nachgezogen.

### XMP-Sidecars — Grenzen

Immichs Sidecar-Funktion ist v.a. zum **Lesen** vorhandener `.xmp` da. Immich schreibt eine
`.xmp` nur, wenn man an einem Foto **in Immich Metadaten ändert** (Datum, GPS, Beschreibung) —
und sichert dann nur *diese* Änderung. Es exportiert **nicht** die komplette DB in Sidecars.

Konsequenz für den Umzug:

| Was | wo | kommt beim Ordner-Kopieren mit? |
|---|---|---|
| Fotos + Original-EXIF (Datum, Kamera, GPS) | in der Datei | ✅ |
| Datums-/GPS-**Korrekturen** aus Immich | `.xmp` neben der Datei | ✅ (sobald geändert) |
| **Alben, Personen-Namen, eigene Tags, Favoriten** | nur Postgres | ❌ |

Für Alben/Gesichter beim Ausstieg: **`pg_dump`** (liegt eh unter `library/backups/`) oder
**`immich-go`**, das beim Export die Alben als Ordner nachbaut.

### Export-Wege (heute schon möglich)

| Weg | Ergebnis |
|---|---|
| Web-UI: alles auswählen → *Download* | ZIP mit **Original-Dateinamen**, nach Alben gruppierbar |
| `immich-cli` / API | Skriptbarer Bulk-Download aller Assets |
| [`immich-go`](https://github.com/simulot/immich-go) | Dediziertes Tool für Massen-Im-/Export inkl. Alben-Struktur |
| Einfach `library/library/` kopieren | Bei aktivem Storage Template: fertiger dated Tree der Originale (+ `.xmp` falls aktiviert) |
| `pg_dump` der Immich-DB | Vollständige Metadaten als SQL, falls man Alben/Gesichter programmatisch übernehmen will. Automatische Dumps liegen bereits unter `library/backups/` |

### Fazit

Der Ausstieg für **Fotos + EXIF** ist trivial: Ordner `library/library/` wegkopieren — ein
selbsterklärender, nach Datum sortierter Baum der unveränderten Originale. Für die in Immich
gepflegte Ordnung (Alben, benannte Gesichter, Tags) zusätzlich DB-Dump bzw. `immich-go`.
Immich ist damit „Betrachter/Organisierer", kein Datensilo.

---

## Bekannte Eigenheiten

### Speicheranzeige zeigt „57,1 TiB" statt ~229 GiB

Das Dashboard (*Administration → Server-Statistik*) und `GET /api/server/storage` melden
absurde Absolutwerte (z.B. `diskSize 57,1 TiB`, `diskUse 29,2 TiB` bei einer 256-GB-SSD).

**Ursache:** Colima mountet den Host-Ordner per `virtiofs` in die VM. virtiofs meldet
`statvfs()` mit `f_bsize = 1 MiB`, während die Blockzahlen in `f_frsize = 4 KiB` gezählt
sind. Immich (bzw. Node.js `fs.statfs`, das nur `bsize` kennt, kein `frsize`) rechnet
`Blöcke × bsize` → **Faktor 256 zu groß** (229 GiB × 256 ≈ 57 TiB).

**Auswirkung: keine.**
- `diskUsagePercentage` in der API ist **korrekt** (~51 %), nur die Absolutwerte sind Müll
- `df -h` im Container zeigt richtig (`229G / 117G used`)
- Uploads, Quotas (falls je gesetzt — Quotas laufen gegen real getrackte Bytes) unberührt

**Fix in Sicht?** Eher nicht. Die falschen Werte kommen aus Apples
Virtualization.framework-virtiofs; Immich kann es kaum umgehen, weil Node `fs.statfs`
das nötige `f_frsize` gar nicht liefert. Kein bekannter Roadmap-Eintrag.

**Workaround** (nur bei Bedarf): Colima `mountType` auf `sshfs` oder `9p` stellen
(`~/.colima/default/colima.yaml` + `colima restart`). **Nicht empfohlen** — virtiofs ist
deutlich schneller, und ein Fotoserver mit vielen Thumbnail-I/Os würde das spüren. Die
externe SSD später zeigt denselben Effekt (kommt ebenfalls per virtiofs über `/Volumes/…`
in die VM, da `vz` kein USB-Passthrough kann).

---

## Sicherheit

- `.env` enthält das DB-Passwort im Klartext — nicht ins Git-Repo committen (siehe `.gitignore`)
- Solange kein HTTPS/Internet-Zugriff eingerichtet ist: nur im vertrauenswürdigen LAN nutzen
