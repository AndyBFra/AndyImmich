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
- Colima-Autostart über LaunchAgent `~/Library/LaunchAgents/local.colima.plist` (läuft beim Login automatisch hoch, kein GUI-Prozess nötig — läuft daher auch headless zuverlässig), Ressourcen: 4 CPU / 6 GB RAM / 100 GB Disk
- Container-Autostart über LaunchAgent `~/Library/LaunchAgents/local.immich.plist` → führt `start-immich.sh` aus, das wartet, bis Colimas Docker-Daemon bereit ist (max. 5 Min, Polling alle 5 Sek.), und dann `docker-compose up -d` ausführt
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

**Neustart von Andyserver:** kompletter Autostart, kein manueller Schritt nötig — Colima und die Container starten beim Login automatisch (siehe LaunchAgents oben). Rechne mit 1-2 Minuten, bis Immich nach einem Neustart wieder erreichbar ist (VM-Boot + Container-Healthchecks).

---

## Wichtige Pfade

| Pfad | Inhalt |
|---|---|
| `~/Servers/Immich/library` | Originaldateien (Fotos/Videos) — aktuell lokal auf Andyserver |
| `~/Servers/Immich/postgres` | Datenbank |
| `~/Servers/Immich/docker-compose.yml` | Compose-Definition (von Immich vorgegeben, i.d.R. nicht anfassen) |
| `~/Servers/Immich/.env` | Konfiguration + Secrets (DB-Passwort) — **nicht committen** |
| `~/Servers/Immich/start-immich.sh` | Autostart-Wrapper, von `local.immich.plist` aufgerufen |

---

## Offene Punkte / TODO

- [x] **Docker-Compose-Autostart** nach Reboot — LaunchAgent `local.immich.plist` + `start-immich.sh`
- [ ] **HTTPS** via nginx + mkcert einrichten (analog zu PrivatPortfolio) — aktuell nur HTTP im LAN
- [ ] **Library auf externe USB-C-Platte** umziehen, sobald vorhanden: `UPLOAD_LOCATION` in `.env` anpassen, Daten von `library/` auf die Platte kopieren, Container neu starten
- [ ] **DynDNS auf der FRITZ!Box** einrichten, falls Zugriff von unterwegs (z.B. automatisches Foto-Backup der Mobile-App außerhalb des Heimnetzes) gewünscht ist. Dafür zusätzlich nötig:
  - Port-Weiterleitung bzw. Reverse-Proxy für den extern erreichbaren Port
  - **Echtes** HTTPS-Zertifikat (Let's Encrypt via z.B. `certbot`) statt mkcert — mkcert-Zertifikate sind nur innerhalb des Heimnetzes vertrauenswürdig, da die Root-CA nur auf euren eigenen Geräten installiert ist
  - Absicherung des dann öffentlich erreichbaren Diensts bedenken (starke Passwörter, ggf. 2FA in Immich aktivieren, Fail2ban o.ä. gegen Brute-Force)

---

## Sicherheit

- `.env` enthält das DB-Passwort im Klartext — nicht ins Git-Repo committen (siehe `.gitignore`)
- Solange kein HTTPS/Internet-Zugriff eingerichtet ist: nur im vertrauenswürdigen LAN nutzen
