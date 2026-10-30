# The Linux runner: Docker-BuildAgent (Node, .NET 8/9/10, PowerShell, Git, Docker CLI, GitVersion, NUKE)
# plus the Actions runner, the wasm-tools workload and the few native packages the builds also need.
# New-LinuxRunner.ps1 -Build passes linux.baseImage from runners.json, a pinned digest.
ARG BASE_IMAGE
FROM ${BASE_IMAGE}
# The base switches to pwsh and probes a docs server on port 3000; the runner needs neither.
SHELL ["/bin/bash", "-c"]
HEALTHCHECK NONE
# Jobs run as root, like the base: no ownership changes, so the base's SDKs and tools are not copied into another layer.
USER root
RUN apt-get update && apt-get install -y --no-install-recommends cmake ninja-build python-is-python3 libgtk-3-0 libice6 libsm6 && rm -rf /var/lib/apt/lists/*
RUN --mount=type=bind,source=downloads/actions-runner-linux-x64-2.338.0.tar.gz,target=/tmp/runner.tar.gz mkdir -p /opt/runner-template /runner /cache && tar -xzf /tmp/runner.tar.gz -C /opt/runner-template
# /cache is the named volume from runners.json (linux.cacheVolume): home folder and NuGet packages survive container rebuilds.
ENV DOTNET_CLI_TELEMETRY_OPTOUT=1 DOTNET_NOLOGO=1 DOTNET_SKIP_FIRST_TIME_EXPERIENCE=1 DOTNET_INSTALL_DIR=/usr/share/dotnet DOTNET_ROOT=/usr/share/dotnet HOME=/cache/home DOTNET_CLI_HOME=/cache/home NUGET_PACKAGES=/cache/nuget RUNNER_ALLOW_RUNASROOT=1 RUNNER_MANUALLY_TRAP_SIG=1
RUN dotnet workload install wasm-tools --skip-manifest-update
WORKDIR /runner
COPY linux/entrypoint.sh /opt/entrypoint.sh
ENTRYPOINT ["/bin/bash", "/opt/entrypoint.sh"]
