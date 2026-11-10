#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME"
if [ ! -f /runner/run.sh ]; then
    cp -R /opt/runner-template/. /runner/
fi
if [ "${1:-}" = "configure" ]; then
    exec /runner/config.sh "${@:2}"
fi
# Held: the owner put this runner in maintenance (the record is in the runner directory, which the host mounts here). A restart
# of the container or of Docker must not start a listener under it, so wait. Any record holds, whatever it says; run.sh starts
# only once the host's Resume has deleted it.
if [ -e /runner/maintenance.json ]; then
    echo "Held: /runner/maintenance.json exists; no listener starts until the owner resumes this runner." >&2
    while [ -e /runner/maintenance.json ]; do
        sleep 15
    done
    echo "Resumed: the maintenance record is gone; starting the listener." >&2
fi
exec /runner/run.sh
