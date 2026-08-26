#!/bin/bash
# Waits for the Colima-managed Docker daemon to come up (it starts in parallel
# via its own LaunchAgent), then brings up the Immich containers.
cd "$(dirname "$0")"

for i in $(seq 1 60); do
    /opt/homebrew/bin/docker info >/dev/null 2>&1 && break
    sleep 5
done

/opt/homebrew/bin/docker-compose up -d
