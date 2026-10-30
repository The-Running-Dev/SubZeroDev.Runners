# Handoff: Docker-in-Docker inside build-agent

For the Docker-BuildAgent repository. Follow that repository's own process (AGENTS.md, design/).

## Goal

build-agent can run its own Docker daemon when it is started privileged. A container built on
it can then build images, run containers and use Compose or Testcontainers without the host's
Docker socket and without a sidecar. The daemon is opt-in, so nothing changes for current users.

## Who uses the image today (must keep working unchanged)

- **SubZeroDev.Runners Linux runner.** `FROM ghcr.io/the-running-dev/build-agent@sha256:...`
  (pinned by digest). It sets `SHELL ["/bin/bash", "-c"]`, `HEALTHCHECK NONE` and `USER root`,
  has its own `ENTRYPOINT` (`/opt/entrypoint.sh`, which ends in `exec /runner/run.sh`), and runs
  jobs as root. Today it has no daemon; its Docker access comes from a `docker:dind` sidecar, so
  the two setups can be compared.
- **GitHub-ActionTemplates `docs.yml`.** Uses the image as a job container on GitHub-hosted
  runners: not privileged, and GitHub overrides the entrypoint.
- **`build-agent build`** from the host, and anything else run from the image as it is now.

## What to build

1. **Engine packages.** Install `docker-ce` and `containerd.io` from the Docker apt repository
   the Dockerfile already adds, next to the existing CLI and plugins. Add what the daemon needs
   inside a container (at least `iptables`, plus whatever else the official `docker:dind` image
   relies on, for example `iproute2`, `pigz`, `xz-utils`). Pin the versions with `ARG`s like the
   other tools in the Dockerfile.
2. **A start script, `/usr/local/bin/start-dockerd`** (bash, safe to call twice):
   - Does nothing and exits 0 unless the opt-in variable is set (suggested name
     `BUILD_AGENT_DOCKERD=1`).
   - Fails with a clear message if the container is not privileged (for example when
     `CAP_SYS_ADMIN` is missing from `CapEff`).
   - Prepares nested cgroup v2 the way Moby's `hack/dind` script does. Vendor it from a pinned
     commit, or reimplement it. Leave out its tmpfs mount over `/tmp`: the runner keeps its work
     folder in `/tmp/runner-work`, and a tmpfs there hides the checkout and drops it on restart.
   - Chooses an iptables backend that works on the host kernel, the way `docker:dind` does:
     nft first, then legacy. Docker Desktop's WSL2 VM is the first host it will run on.
   - Starts `dockerd` in the background, listening on `unix:///var/run/docker.sock`, with its log
     in `/var/log/dockerd.log`.
   - Waits until `docker info` works (with a timeout), then exits 0. On failure it exits non-zero
     and prints the end of the log.
   - Warns if `/var/lib/docker` is not a volume. On the container's overlay filesystem dockerd
     falls back to `vfs`, which is slow and large.
3. **The image's own entrypoint.** A small entrypoint that calls `start-dockerd` (which does
   nothing without the opt-in) and then `exec "$@"`, so `CMD ["pwsh"]` and the docs server
   behave as before. Images with their own entrypoint, like the runner, call `start-dockerd`
   themselves.
4. **Shutdown.** When the container stops, dockerd should stop cleanly instead of being killed:
   containerd and overlay state stays consistent on the `/var/lib/docker` volume. A trap in the
   entrypoint, or a documented `stop-dockerd` that downstream entrypoints call from their own
   trap, both work. Say which one you chose.

## Contract the runner will consume

Change the names if the repository's conventions call for it, but report back what they are:

| Item | Value |
| --- | --- |
| Opt-in | `BUILD_AGENT_DOCKERD=1` |
| Start | `/usr/local/bin/start-dockerd`: exit 0 once the daemon answers, non-zero with a message otherwise |
| Stop | trap in the entrypoint, or `/usr/local/bin/stop-dockerd` |
| Socket | `/var/run/docker.sock`, with `DOCKER_HOST` left unset |
| Data | `/var/lib/docker`, which the caller mounts as a volume |
| Run flags | `--privileged` plus `-v <volume>:/var/lib/docker` |

## Tests (in the image's CI)

- Privileged, with the opt-in and a data volume: `docker run --rm` of a small image pinned by
  digest, `docker buildx build` of a two-line Dockerfile, a bind mount that the inner container
  writes to, a published port reachable from the outer container, and `docker compose up`/`down`.
- Not privileged, with the opt-in: a clear error and a non-zero exit.
- Without the opt-in: no dockerd process, and the existing behaviour (CMD, docs server
  healthcheck) unchanged.
- Report the image size before and after.

## Docs

A README or documentation section covering how to run it with DinD (flags, volume, opt-in) and
the security trade-off: `--privileged` gives jobs root on the host, which for Docker Desktop is
its VM. Use it only for trusted code.

## Release

Publish a new version as usual and report its digest
(`ghcr.io/the-running-dev/build-agent@sha256:...`). Do not edit SubZeroDev.Runners. The runner
side will add a `dind` mode that bumps `linux.baseImage` to that digest, runs privileged with a
data volume and calls `start-dockerd` from its entrypoint.
