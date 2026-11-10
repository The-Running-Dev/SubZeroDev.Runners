#!/usr/bin/env bash
# Runner-specific container health, for HEALTHCHECK and for BuildAgent's updater (it waits for "healthy" after a replacement).
# Healthy means the Actions runner is configured, its listener process is alive, and, where this container is meant to have a
# Docker daemon (its own dockerd, or the sidecar through DOCKER_HOST), that daemon answers. The base image's own check (a docs
# server on port 3000) does not apply here and is disabled in the Dockerfile.
# Prints one line saying why it is unhealthy; exit 0 healthy, 1 unhealthy.
set -u

fail() { echo "unhealthy: $*"; exit 1; }

[ -f /runner/.runner ] || fail "the runner is not registered (/runner/.runner is missing); run Register-Runners.ps1"
[ -f /runner/.credentials ] || fail "the runner has no credentials (/runner/.credentials is missing); run Register-Runners.ps1"

# Held by the owner: the entrypoint waits and no listener is expected, so the container is healthy (BuildAgent's updater waits for it).
if [ -e /runner/maintenance.json ]; then
    echo "healthy: held in maintenance; no listener until the owner resumes"
    exit 0
fi

# The listener, found without procps: the first word of an argv that ends in Runner.Listener.
listener=0
for cmdline in /proc/[0-9]*/cmdline; do
    [ -r "$cmdline" ] || continue
    args=$(tr '\0' ' ' < "$cmdline" 2>/dev/null) || continue
    case "$args" in
        *Runner.Listener*) listener=1; break ;;
    esac
done
[ "$listener" = 1 ] || fail "Runner.Listener is not running"

# A Docker daemon is expected when the container runs dockerd itself or is pointed at the sidecar.
if [ "${BUILD_AGENT_DOCKERD:-}" = "1" ] || [ -n "${DOCKER_HOST:-}" ]; then
    timeout 10 docker version --format '{{.Server.Version}}' > /dev/null 2>&1 || fail "the Docker daemon does not answer (${DOCKER_HOST:-local socket})"
fi

echo "healthy"
