#!/bin/bash
set -u
# Checkouts and action downloads are disposable. Keep package caches and the runner's _temp, _tool and mappings.
work="${RUNNER_WORK_FOLDER:-}"
case "$work" in
  /tmp/?*) ;;
  *) echo "RUNNER_WORK_FOLDER must be a folder under /tmp, not '$work'." >&2; exit 1 ;;
esac
# With a Docker daemon, the job's leftover containers, networks and anonymous volumes go too; images and build cache stay.
if [ -n "${DOCKER_HOST:-}" ]; then
  containers=$(docker ps -aq)
  if [ -n "$containers" ]; then
    docker rm -f $containers >/dev/null || echo 'Could not remove the job containers.' >&2
  fi
  docker network prune -f >/dev/null
  docker volume prune -f >/dev/null
fi
shopt -s nullglob
for target in "$work/_actions" "$work"/[!_]*; do
  for attempt in $(seq 1 60); do
    if rm -rf -- "$target" 2>/dev/null; then
      break
    fi
    if [ "$attempt" -eq 60 ]; then
      echo "Could not clean $target after 60 attempts." >&2
      exit 1
    fi
    sleep 1
  done
done
echo 'Workspace and action cache are ready for the next job.'
