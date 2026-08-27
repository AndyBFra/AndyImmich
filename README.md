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
- Colima-Autostart über System-`launchd`-**LaunchDaemon** `/Library/LaunchDaemons/local.colima.plist` (`UserName: andy`), Ressourcen: 4 CPU / 6 GB RAM / 100 GB Disk
- Container-Autostart über System-LaunchDaemon `/Library/LaunchDaemons/local.immich.plist` (`UserName: andy`) → führt `start-immich.sh` aus, das wartet, bis Colimas Docker-Daemon bereit ist (max. 5 Min, Polling alle 5 Sek.), und dann `docker-compose up -d` ausführt
- Beide laufen als **LaunchDaemons statt LaunchAgents**, damit sie unabhängig von einer eingeloggten GUI-Session laufen (auf einem headless Server kann die Konsolen-Session enden — z.B. nach einer Bildschirmfreigabe-Sitzung — wodurch `gui/<uid>`-LaunchAgents sterben; `system`-Domain-LaunchDaemons sind davon unabhängig, genau wie nginx bei PrivatPortfolio). Quelldateien liegen zur Referenz auch unter `~/Servers/Immich/local.colima.plist` / `local.immich.plist`; Installieren/Updates brauchen `sudo` (`sudo launchctl bootstrap system ...`).
- `docker-compose.yml` + `.env` von der offiziellen Immich-Release-Seite geladen:
  ```bash
  curl -fsSL -o docker-compose.yml https://github.com/immich-app/immich/releases/latest/download/docker-compose.yml
  curl -fsSL -o .env https://github.com/immich-app/immich/releases/latest/download/example.env
  ```
- `.env` angepasst gegenüber dem Default:
  - `UPLOAD_LOCATION` und `DB_DATA_LOCATION` auf absolute Pfade gesetzt (`~/Servers/Immich/library`, `~/Servers/Immich/postgres`) statt relativ
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

**Neustart von Andyserver:** kompletter Autostart beim Boot, kein manueller Schritt und kein Login nötig — die LaunchDaemons starten unabhängig von jeder GUI-Session (siehe oben). Rechne mit 1-2 Minuten, bis Immich nach einem Neustart wieder erreichbar ist (VM-Boot + Container-Healthchecks).

---

## Fotos importieren (Bestands-Migration)

Alte Fotosammlung liegt auf der NAS: SMB-Share `//192.168.178.38/Data/Pictures/Andy_Pics`
(D-Link DNS-325 „bormankserver", User `andy`). Die NAS ist zu langsam für eine dauerhafte
externe Bibliothek — die Bilder werden **einmalig per CLI in Immichs eigene Ablage kopiert**.

### Ablauf

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

---

## Wichtige Pfade

| Pfad | Inhalt |
|---|---|
| `~/Servers/Immich/library` | Originaldateien + Thumbnails (`UPLOAD_LOCATION`) — aktuell lokal auf Andyserver |
| `~/Servers/Immich/library/library/admin/JAHR/JAHR-MM-TT/` | Originale mit echten Dateinamen (seit Storage Template aktiv, s.u.) |
| `~/Servers/Immich/library/upload/` | nur noch Upload-Zwischenspeicher |
| `~/Servers/Immich/postgres` | Datenbank |
| `~/Servers/Immich/docker-compose.yml` | Compose-Definition (von Immich vorgegeben, i.d.R. nicht anfassen) |
| `~/Servers/Immich/.env` | Konfiguration + Secrets (DB-Passwort) — **nicht committen** |
| `~/Servers/Immich/start-immich.sh` | Autostart-Wrapper, von `local.immich.plist` aufgerufen |
| `~/Servers/Immich/local.colima.plist`, `local.immich.plist` | Referenzkopien der aktiven LaunchDaemons unter `/Library/LaunchDaemons/` |

---

## Offene Punkte / TODO

- [x] **Docker-Compose-Autostart** nach Reboot — LaunchAgent `local.immich.plist` + `start-immich.sh`
- [x] **Storage Template + Datenportabilität** — Template `{{y}}/{{y}}-{{MM}}-{{dd}}/{{filename}}` aktiv, Bestand migriert
- [ ] **Bestands-Migration von der NAS** — bisher nur POC (Ordner 1992–2002, ~686 echte Fotos). Rest folgt, wenn die externe Platte da ist. Ablauf + `--ignore`-Filter siehe [Fotos importieren](#fotos-importieren-bestands-migration)
- [ ] **HTTPS** via nginx + mkcert einrichten (analog zu PrivatPortfolio) — aktuell nur HTTP im LAN
- [ ] **Library auf externe USB-C-/Thunderbolt-Platte** umziehen, sobald vorhanden — siehe [Externe Platte für die Library (geplant)](#externe-platte-für-die-library-geplant)
- [ ] **DynDNS auf der FRITZ!Box** einrichten, falls Zugriff von unterwegs (z.B. automatisches Foto-Backup der Mobile-App außerhalb des Heimnetzes) gewünscht ist. Dafür zusätzlich nötig:
  - Port-Weiterleitung bzw. Reverse-Proxy für den extern erreichbaren Port
  - **Echtes** HTTPS-Zertifikat (Let's Encrypt via z.B. `certbot`) statt mkcert — mkcert-Zertifikate sind nur innerhalb des Heimnetzes vertrauenswürdig, da die Root-CA nur auf euren eigenen Geräten installiert ist
  - Absicherung des dann öffentlich erreichbaren Diensts bedenken (starke Passwörter, ggf. 2FA in Immich aktivieren, Fail2ban o.ä. gegen Brute-Force)

---

## Externe Platte für die Library (geplant)

Sobald eine schnelle externe Platte am Server hängt, zieht **nur die Library** (Originale + Thumbnails, `UPLOAD_LOCATION`) auf die Platte um. **Die Postgres-Datenbank bleibt auf der internen SSD** (siehe unten, Begründung).

### Hardware / Formatierung

- **NVMe-SSD**, keine HDD — Immich macht viel Random-IO (Thumbnail-/Preview-Generierung, ML-Scan, Duplikat-Hashing beim Import)
- Anschluss: Thunderbolt oder USB4, mindestens USB 3.2 Gen 2 (10 Gbit/s)
- Größe: 1–2 TB (Bestand ~85 GB nach RAW-Filter + Thumbnails/Encoded-Video + Wachstum)
- **APFS** formatieren (macOS-nativ). Kein exFAT/NTFS — dort fehlen POSIX-Rechte/Symlinks, das bricht Immichs Storage-Handling
- Fester Mountpoint, hier als Beispiel `/Volumes/ImmichData` (APFS-Volume so benennen)
- Disk-Sleep abschalten, sonst hängt der Server bei jedem Zugriff kurz:
  ```bash
  sudo pmset -a disksleep 0
  ```

### Warum bleibt Postgres intern?

- Immich-Doku sagt explizit: DB **nicht** auf Netzlaufwerken, und eine extern angesteckte Platte hat dasselbe Risiko — wird sie im Betrieb getrennt oder schläft ein, korrumpiert die laufende Postgres-Instanz
- Postgres braucht latenzarme `fsync`-Writes; das interne SSD ist dafür besser als USB
- Die DB ist klein (Metadaten, keine Bilddaten) — sie belegt kaum Platz auf der internen SSD
- `DB_DATA_LOCATION` bleibt also unverändert auf `~/Servers/Immich/postgres`

### Schritte für den Umzug

1. Platte als APFS formatieren, Volume `ImmichData` nennen, `sudo pmset -a disksleep 0`
2. Container stoppen:
   ```bash
   cd ~/Servers/Immich && docker-compose down
   ```
3. Library rüberkopieren (Rechte/Struktur erhalten):
   ```bash
   mkdir -p /Volumes/ImmichData/immich/library
   rsync -aP ~/Servers/Immich/library/ /Volumes/ImmichData/immich/library/
   ```
4. In **`.env`** anpassen (nur diese eine Zeile):
   ```ini
   UPLOAD_LOCATION=/Volumes/ImmichData/immich/library
   # DB_DATA_LOCATION bleibt ~/Servers/Immich/postgres
   ```
5. **Colima die Platte durchreichen** — `/Volumes/...` wird *nicht* automatisch in die VM gemountet (nur `/Users/andy`). In `~/.colima/default/colima.yaml`:
   ```yaml
   mounts:
     - location: /Volumes/ImmichData
       writable: true
   ```
   Danach `colima restart` (übernimmt Mounts neu; kurze Downtime).
6. Container starten, prüfen, dass neue Uploads auf der Platte landen:
   ```bash
   docker-compose up -d
   # Testfoto hochladen, dann:
   ls /Volumes/ImmichData/immich/library/upload/
   ```
7. Wenn alles läuft: altes `~/Servers/Immich/library/` löschen (vorher einmal Backup ziehen)

### Start-Absicherung (wichtig)

Wenn die Platte beim Boot **nicht** gemountet ist und die Container trotzdem starten, schreibt Immich in ein leeres Verzeichnis auf der internen SSD und „verliert" scheinbar alle Bilder (die Originale sind noch da, aber die DB zeigt auf den falschen, leeren Pfad).

Daher muss `start-immich.sh` vor `docker-compose up -d` prüfen, dass der Mount wirklich da ist:
```sh
# in start-immich.sh, vor 'docker-compose up -d':
LIBRARY_MOUNT="/Volumes/ImmichData"
for i in $(seq 1 30); do
    mount | grep -q " ${LIBRARY_MOUNT} " && break
    sleep 5
done
if ! mount | grep -q " ${LIBRARY_MOUNT} "; then
    echo "$(date): ${LIBRARY_MOUNT} nicht gemountet — Immich wird NICHT gestartet" >&2
    exit 1
fi
```
(Analog sollte man beim Wiedereinstecken der Platte `docker-compose restart` fahren, falls die Container zwischenzeitlich ohne Mount liefen.)

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

## Sicherheit

- `.env` enthält das DB-Passwort im Klartext — nicht ins Git-Repo committen (siehe `.gitignore`)
- Solange kein HTTPS/Internet-Zugriff eingerichtet ist: nur im vertrauenswürdigen LAN nutzen
