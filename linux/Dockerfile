# The Linux runner: Docker-BuildAgent (Node, .NET 8/9/10, PowerShell, Git, Docker CLI and opt-in Engine, GitVersion, NUKE)
# plus the Actions runner, the wasm-tools workload and the few native packages the builds also need.
# New-LinuxRunner.ps1 -Build passes linux.baseImage from runners.json (a pinned digest) and the runner release it downloaded
# and verified: RUNNER_VERSION is runners.json runnerVersion, the one version for Windows and Linux; RUNNER_SHA256 is the
# SHA-256 GitHub publishes for that archive. A build without them fails instead of using an unverified or stale archive.
ARG BASE_IMAGE
ARG RUNNER_VERSION
ARG RUNNER_SHA256
FROM ${BASE_IMAGE}
ARG RUNNER_VERSION
ARG RUNNER_SHA256
# The base switches to pwsh and probes a docs server on port 3000; the runner needs neither.
SHELL ["/bin/bash", "-c"]
# Healthy = the runner is registered, its listener is alive and, where one is expected, the Docker daemon answers.
# BuildAgent's updater waits for this status after replacing the container. The start period covers dockerd startup.
COPY linux/healthcheck.sh /opt/healthcheck.sh
HEALTHCHECK --interval=30s --timeout=15s --start-period=90s --retries=3 CMD ["/bin/bash", "/opt/healthcheck.sh"]
# Jobs run as root, like the base: no ownership changes, so the base's SDKs and tools are not copied into another layer.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build python-is-python3 libgtk-3-0 libice6 libsm6 && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,source=downloads,target=/downloads \
    : "${RUNNER_VERSION:?build with New-LinuxRunner.ps1 -Build (RUNNER_VERSION is missing)}" "${RUNNER_SHA256:?build with New-LinuxRunner.ps1 -Build (RUNNER_SHA256 is missing)}" \
    && archive="/downloads/actions-runner-linux-x64-${RUNNER_VERSION}.tar.gz" \
    && echo "${RUNNER_SHA256}  ${archive}" | sha256sum -c - \
    && mkdir -p /opt/runner-template /runner /cache \
    && tar -xzf "${archive}" -C /opt/runner-template
# /cache is the named volume from runners.json (linux.cacheVolume): home folder and NuGet packages survive container rebuilds.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_INSTALL_DIR=/usr/share/dotnet DOTNET_ROOT=/usr/share/dotnet HOME=/cache/home DOTNET_CLI_HOME=/cache/home NUGET_PACKAGES=/cache/nuget RUNNER_ALLOW_RUNASROOT=1 RUNNER_MANUALLY_TRAP_SIG=1
RUN dotnet workload install wasm-tools --skip-manifest-update
WORKDIR /runner
COPY linux/entrypoint.sh /opt/entrypoint.sh
# The base's entrypoint starts dockerd first when BUILD_AGENT_DOCKERD=1 (linux.docker.mode 'dind') and stops it after the runner exits.
ENTRYPOINT ["build-agent-entrypoint", "/bin/bash", "/opt/entrypoint.sh"]
