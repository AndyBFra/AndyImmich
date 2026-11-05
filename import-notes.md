# Import-Notizen (Archiv)

Detaillierte Abläufe und Lessons-Learned der einmaligen Bestands-Migration
(NAS-Altbestand + Google-Takeout) für alle drei Konten, abgeschlossen am 2026-08-31/09-01.
Aus dem README ausgelagert, weil abgeschlossen — als Referenz für einen künftigen,
ähnlichen Import (z.B. neues Familienkonto) aufbewahrt.

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

Die aktiven Import-Keys lagen in `import-api-keys.local.md` (gitignored). Nach Abschluss aller
Importe dort gelöscht und in Immich widerrufen.

---

## Google Photos / Takeout-Import

Google-Takeout-Archive **mit Alben** importieren. Die normale Immich-CLI kann keine
Takeout-Alben → **[`immich-go`](https://github.com/simulot/immich-go)** (v0.32): liest die ZIPs
direkt, wertet die `.json`-Sidecars aus (Datum, GPS, Beschreibung, Favorit, archiviert), baut
die **benannten Alben** nach, stapelt Live/Motion Photos.

**Immer ins Konto des `--api-key`-Besitzers** — jeder Nutzer braucht einen eigenen Key aus
seinem Konto. `--admin-api-key` bleibt andys Admin-Key.

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
