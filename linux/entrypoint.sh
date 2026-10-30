#!/usr/bin/env bash
set -euo pipefail
mkdir -p "$HOME"
if [ ! -f /runner/run.sh ]; then
    cp -R /opt/runner-template/. /runner/
fi
if [ "${1:-}" = "configure" ]; then
    exec /runner/config.sh "${@:2}"
fi
exec /runner/run.sh
