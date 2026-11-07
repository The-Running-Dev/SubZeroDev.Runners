#!/bin/bash
set -u
# Checkouts and action downloads are disposable. Keep package caches and the runner's _temp, _tool and mappings.
work="${RUNNER_WORK_FOLDER:-}"
case "$work" in
  /tmp/?*) ;;
  *) echo "RUNNER_WORK_FOLDER must be a folder under /tmp, not '$work'." >&2; exit 1 ;;
esac
# With a Docker daemon (the sidecar, or the runner's own in dind mode), the job's leftover containers, networks and
# anonymous volumes go too; images and build cache stay.
if docker info >/dev/null 2>&1; then
  containers=$(docker ps -aq)
  if [ -n "$containers" ]; then
    docker rm -f $containers >/dev/null || echo 'Could not remove the job containers.' >&2
  fi
  docker network prune -f >/dev/null
  docker volume prune -f >/dev/null
fi
shopt -s nullglob
# Bounded: RUNNER_CLEANUP_RETRIES attempts, RUNNER_CLEANUP_DELAY seconds apart (runners.json housekeeping), 20 and 1 by default.
retries="${RUNNER_CLEANUP_RETRIES:-20}"
delay="${RUNNER_CLEANUP_DELAY:-1}"
case "$retries" in ''|*[!0-9]*|0) retries=20 ;; esac
for target in "$work/_actions" "$work"/[!_]*; do
  for attempt in $(seq 1 "$retries"); do
    if rm -rf -- "$target" 2>/dev/null; then
      break
    fi
    if [ "$attempt" -eq "$retries" ]; then
      echo "Could not clean $target after $retries attempts." >&2
      exit 1
    fi
    sleep "$delay"
  done
done
echo 'Workspace and action cache are ready for the next job.'
