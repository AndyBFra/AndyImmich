#!/bin/bash
# Wartet auf den von Colima verwalteten Docker-Daemon und startet dann die
# Immich-Container. Laeuft (via LaunchDaemon local.immich) parallel zum
# LaunchDaemon local.colima.
#
# Falls Colima nach dem Boot nicht hochkommt - typisch nach einem unsauberen
# Shutdown, wenn veralteter Zustand 'colima start' im Daemon scheitern laesst -
# wird start-colima.sh hier als Fallback aufgerufen. Damit ist die Startreihenfolge
# der beiden Daemons egal.
DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$DIR"

DOCKER=/opt/homebrew/bin/docker
COMPOSE=/opt/homebrew/bin/docker-compose

wait_for_docker() {
    # $1 = Anzahl Versuche à 5 s
    local i
    for i in $(seq 1 "$1"); do
        "$DOCKER" info >/dev/null 2>&1 && return 0
        sleep 5
    done
    return 1
}

# Sentinel-Datei auf der externen Platte (UPLOAD_LOCATION liegt dort). Fehlt sie,
# ist die Platte nicht gemountet -> Immich NICHT starten, sonst schreibt es ins
# Leere auf der internen SSD und "verliert" scheinbar alle Bilder.
DISK_SENTINEL="/Volumes/ServerData/pictures/.disk-present"
COLIMA=/opt/homebrew/bin/colima

# ~90 s auf die Platte warten (USB-Enumeration nach Boot kann dauern)
for i in $(seq 1 18); do
    [ -f "$DISK_SENTINEL" ] && break
    sleep 5
done
if [ ! -f "$DISK_SENTINEL" ]; then
    echo "$(date '+%F %T') Externe Platte fehlt ($DISK_SENTINEL) - Immich wird NICHT gestartet" >&2
    exit 1
fi

# ~60 s auf den regulaeren Colima-Start (eigener Daemon) warten
if ! wait_for_docker 12; then
    echo "$(date '+%F %T') Docker nicht erreichbar - starte Colima selbst (Fallback)"
    /bin/bash "$DIR/start-colima.sh"
    # danach grosszuegiger Puffer fuer den VM-Boot
    if ! wait_for_docker 24; then
        echo "$(date '+%F %T') Docker weiterhin nicht erreichbar - Abbruch" >&2
        exit 1
    fi
fi

# Sieht die VM die Platte? Wenn nicht (Colima startete vor dem Platten-Mount),
# einmal neu starten, damit der virtiofs-Mount greift.
if ! "$COLIMA" ssh -- test -f "$DISK_SENTINEL" 2>/dev/null; then
    echo "$(date '+%F %T') Platte am Host, aber nicht in der VM - colima restart"
    "$COLIMA" restart
    wait_for_docker 24 || { echo "$(date '+%F %T') Docker nach colima restart weg - Abbruch" >&2; exit 1; }
fi

exec "$COMPOSE" up -d
