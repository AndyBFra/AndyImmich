#!/bin/bash
# Startet die Colima-VM idempotent und raeumt vorher veralteten Laufzeit-Zustand auf.
#
# Nach einem unsauberen Shutdown (erzwungener Reboot durch macOS-Update, Stromausfall,
# Kernel-Panic) bleiben *.pid / *.sock unter ~/.colima/_lima/colima/ liegen, die auf
# einen toten Prozess zeigen. 'colima start' bricht dann beim Boot mit
# "error starting vm: exit status 1" ab und der LaunchDaemon (RunAtLoad, kein Retry)
# gibt auf. 'colima stop --force' entfernt diese Reste.
#
# Aufgerufen von: LaunchDaemon local.colima  UND  als Fallback von start-immich.sh
export PATH=/opt/homebrew/bin:/opt/homebrew/sbin:/usr/bin:/bin:/usr/sbin:/sbin

if colima status >/dev/null 2>&1; then
    echo "$(date '+%F %T') colima laeuft bereits"
    exit 0
fi

echo "$(date '+%F %T') colima nicht aktiv - raeume veralteten Zustand auf und starte"
colima stop --force >/dev/null 2>&1 || true
exec colima start --cpu 4 --memory 6 --disk 100
