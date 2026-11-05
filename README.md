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
- Colima-Autostart über System-`launchd`-**LaunchDaemon** `/Library/LaunchDaemons/local.colima.plist` (`UserName: andy`) → führt `start-colima.sh` aus (Ressourcen: **6 CPU / 8 GB RAM** / 100 GB Disk — Obergrenzen, siehe `start-colima.sh`; M4 mini hat 10 Kerne / 16 GB. War anfangs 4/8, für die Massen-Importe kurz auf 8/12, seit 2026-09-01 wieder 6/8). Das Skript räumt vor `colima start` per `colima stop --force` **veralteten Laufzeit-Zustand** weg (`*.pid`/`*.sock` unter `~/.colima/_lima/colima/`), der nach einem unsauberen Shutdown — erzwungener Reboot durch macOS-Update, Stromausfall, Kernel-Panic — sonst `colima start` scheitern lässt (`error starting vm: exit status 1`); der Daemon hat kein Retry. **Hintergrund:** genau das ist am 2026-08-28 nach einem macOS-Update passiert — Immich kam nicht von selbst hoch.
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
| Update (Minor/Patch, gleiche Major-Version) | 1. Breaking Changes der Release-Notes lesen. 2. `docker exec immich_postgres pg_dumpall -U postgres \| gzip > ~/immich-preupdate-$(date +%F).sql.gz` (Dump auf die **interne** Platte). 3. `docker-compose.yml` von der Release-Seite neu ziehen (ändert sich ab und zu minimal). 4. In `.env` `IMMICH_VERSION` auf die **exakte** Version pinnen (nicht `v3`). 5. `docker-compose pull && docker-compose up -d` — DB-Migrationen laufen automatisch, mit `docker logs immich_server -f` verfolgen. 6. `docker-compose.yml` committen. Rollback: `.env` zurück auf alte Version + `up -d`; Notfall: Dump zurückspielen. Aktuell installierte Version: `grep IMMICH_VERSION .env`. |
| Colima hängt / kommt nicht hoch | `bash ~/Servers/Immich/start-colima.sh` (macht `colima stop --force` + `colima start`); danach `bash ~/Servers/Immich/start-immich.sh` |
| Startskripte neu installieren | nach Änderung an `local.colima.plist`: `sudo launchctl bootout system/local.colima; sudo cp ~/Servers/Immich/local.colima.plist /Library/LaunchDaemons/; sudo launchctl bootstrap system /Library/LaunchDaemons/local.colima.plist` (analog `local.immich`) |

**Neustart von Andyserver:** kompletter Autostart beim Boot, kein manueller Schritt und kein Login nötig — die LaunchDaemons starten unabhängig von jeder GUI-Session (siehe oben). Rechne mit 1-2 Minuten, bis Immich nach einem Neustart wieder erreichbar ist (VM-Boot + Container-Healthchecks).

---

## Fotos importieren (Bestands-Migration)

Die einmalige Bestands-Migration (NAS-Altbestand per `immich-go from-folder` + Google-Takeout
per `immich-go from-google-photos`, für alle drei Konten) ist abgeschlossen (2026-08-31/09-01).
Ablauf, immich-go-Flags, Fallstricke und Lessons-Learned stehen in **[`import-notes.md`](import-notes.md)**
— als Referenz für einen künftigen, ähnlichen Import (z.B. neues Familienkonto).

API-Keys für CLI-Importe: Immich → Profilbild → *Konto-Einstellungen* → *API-Schlüssel*, nach
Gebrauch wieder löschen, nicht ins Repo committen.

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

Erledigt (Autostart, Storage Template, externe SSD, Bestands-Migration aller drei Konten,
ML-Durchlauf, rsync-/DB-Backups, Personen-Benennung): siehe Abschnitte oben bzw.
[`import-notes.md`](import-notes.md) und Git-Historie. Noch offen:

- [ ] **Import-Keys widerrufen** + `import-api-keys.local.md` leeren
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

### ✅ Behoben mit v3.3.0 (2026-10-09): Speicheranzeige zeigte „57,1 TiB" statt ~229 GiB

Ursache war ein virtiofs/Node.js-`statfs`-Rundungsfehler (Colima mountet per `virtiofs`,
`f_bsize = 1 MiB` statt `f_frsize = 4 KiB` → Immich rechnete Blöcke × bsize, Faktor 256 zu groß).
Reine Anzeige, keine Auswirkung auf Uploads/Quotas. Immichs „Storage Calculation Fix" in v3.3.0
behebt es — `GET /api/server/storage` zeigt seitdem korrekte Werte (verifiziert: `diskSize 1.8 TiB`,
`diskUse 791.4 GiB`, deckt sich mit `df -h`).

---

## Sicherheit

- `.env` enthält das DB-Passwort im Klartext — nicht ins Git-Repo committen (siehe `.gitignore`)
- Solange kein HTTPS/Internet-Zugriff eingerichtet ist: nur im vertrauenswürdigen LAN nutzen
