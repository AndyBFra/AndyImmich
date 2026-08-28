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

exec "$COMPOSE" up -d
