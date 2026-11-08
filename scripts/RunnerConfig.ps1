# The one settings loader. runners.json, then runners.local.json (git-ignored, this machine's settings) merged over it,
# then validated. Every host script, the setup phase and the cleanup hooks read settings through Read-RunnerConfig, so
# a value saved to runners.local.json cannot mean one thing to the installer and another to a hook.
# Objects merge setting by setting at every level: { "linux": { "docker": { "mode": "dind" } } } changes only that mode.
function Merge-Settings($Target, $Source) {
    foreach ($setting in $Source.PSObject.Properties) {
        $current = $Target.($setting.Name)
        if ($current -is [pscustomobject] -and $setting.Value -is [pscustomobject]) { Merge-Settings $current $setting.Value }
        else { $Target | Add-Member -Force -NotePropertyName $setting.Name -NotePropertyValue $setting.Value }
    }
}

# Throws one error listing every invalid setting, so a bad runners.local.json is fixed in one pass.
function Assert-RunnerConfig($Config) {
    $problems = [Collections.Generic.List[string]]::new()
    function Require([bool] $Condition, [string] $Message) { if (-not $Condition) { $problems.Add($Message) } }
    function IsDigest([string] $Reference) { $Reference -match '^[^\s@]+@sha256:[0-9a-f]{64}$' }
    function IsRelativeInside([string] $Path) {
        $Path -and -not [IO.Path]::IsPathRooted($Path) -and $Path -notmatch '(^|[\\/])\.\.([\\/]|$)' -and $Path -notmatch '[:*?"<>|]'
    }
    Require ($Config.runnerVersion -match '^\d+\.\d+\.\d+$') 'runnerVersion must be a version such as 2.338.0.'
    if ($Config.windows.instanceId) { Require ($Config.windows.instanceId -match '^[a-zA-Z0-9][a-zA-Z0-9_-]{0,39}$') 'Invalid windows.instanceId: use 1-40 letters, digits, underscores or hyphens.' }
    Require ([bool]$Config.windows.name) 'windows.name is required.'
    Require ([bool]$Config.windows.workFolder) 'windows.workFolder is required.'
    $agent = $Config.buildAgent
    if ($agent) {
        Require ($agent.tool.version -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') 'buildAgent.tool.version must be an exact version such as 2.1.0, never a range or latest.'
        Require ([bool]$agent.tool.package) 'buildAgent.tool.package is required.'
        Require ([bool]$agent.tool.directory) 'buildAgent.tool.directory is required.'
        Require ($agent.dotnetRuntime.channel -match '^\d+\.\d+$') 'buildAgent.dotnetRuntime.channel must be a channel such as 8.0.'
        Require ([bool]$agent.dotnetRuntime.directory) 'buildAgent.dotnetRuntime.directory is required.'
        Require (IsDigest $agent.image) 'buildAgent.image must be pinned by digest (name@sha256:<64 hex>); a tag, including latest, is refused.'
        if ($agent.docker.host) { Require ($agent.docker.host -match '^(npipe|tcp|unix)://\S+$') 'buildAgent.docker.host must be npipe://, tcp:// or unix://, or null for the default daemon.' }
        Require ([int]$agent.docker.readyTimeoutSeconds -gt 0) 'buildAgent.docker.readyTimeoutSeconds must be a positive number.'
        Require ([bool]$agent.paths.workspaceRoot) 'buildAgent.paths.workspaceRoot is required.'
        Require (IsRelativeInside $agent.paths.outputDirectory) 'buildAgent.paths.outputDirectory must be a relative path inside the workspace.'
        Require (IsRelativeInside $agent.paths.cacheDirectory) 'buildAgent.paths.cacheDirectory must be a relative path inside the workspace.'
        Require (@($agent.paths.extraMounts).Count -eq 0) 'buildAgent.paths.extraMounts must be empty: build-agent build mounts only the workspace and the Docker socket, and there is no supported way to add a mount.'
        Require ([int]$agent.cache.retentionDays -ge 0 -and [int]$agent.cache.maxGB -ge 0) 'buildAgent.cache.retentionDays and maxGB must not be negative.'
        if ($agent.updater.version) { Require ($agent.updater.version -match '^\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?$') 'buildAgent.updater.version must be an exact published BuildAgent.Tool version, never latest.' }
    }
    if ($Config.linux.baseImage) { Require (IsDigest $Config.linux.baseImage) 'linux.baseImage must be pinned by digest.' }
    Require ($Config.linux.docker.mode -in 'sidecar', 'dind') 'linux.docker.mode must be sidecar or dind.'
    foreach ($key in 'drainTimeoutMinutes', 'pollSeconds', 'stopTimeoutSeconds', 'restartDelaySeconds', 'quickExitSeconds', 'quickExitLimit', 'backoffMaxSeconds', 'startTimeoutSeconds') {
        Require ([int]$Config.lifecycle.$key -gt 0) "lifecycle.$key must be a positive number."
    }
    Require ([int]$Config.logs.retentionDays -gt 0 -and [int]$Config.logs.maxMB -gt 0) 'logs.retentionDays and logs.maxMB must be positive.'
    Require ([int]$Config.housekeeping.retries -gt 0 -and [int]$Config.housekeeping.retryDelaySeconds -ge 0 -and [int]$Config.housekeeping.minFreeGB -ge 0) 'housekeeping.retries must be positive; retryDelaySeconds and minFreeGB must not be negative.'
    if ($problems.Count) { throw "Invalid runners settings:`n - $($problems -join "`n - ")" }
}

function Read-RunnerConfig([Parameter(Mandatory)] [string] $Root) {
    $config = Get-Content -Raw -LiteralPath (Join-Path $Root 'runners.json') | ConvertFrom-Json
    $local = Join-Path $Root 'runners.local.json'
    if (Test-Path -LiteralPath $local) {
        try { Merge-Settings $config (Get-Content -Raw -LiteralPath $local | ConvertFrom-Json) }
        catch { throw "runners.local.json cannot be read: $($_.Exception.Message)" }
    }
    # The Linux image is built on the BuildAgent image, so there is one digest. linux.baseImage in runners.local.json
    # overrides it for the Linux runner alone.
    if (-not $config.linux.baseImage -and $config.buildAgent.image) {
        $config.linux | Add-Member -Force -NotePropertyName baseImage -NotePropertyValue $config.buildAgent.image
    }
    Assert-RunnerConfig $config
    $config
}

# Canonical form of a path: full, no trailing separator. Used for every "is this inside that" decision.
function Get-CanonicalPath([string] $Path) {
    [IO.Path]::GetFullPath([Environment]::ExpandEnvironmentVariables($Path)).TrimEnd('\', '/')
}

# True when $Path is $Directory or lies below it. Compares whole path segments, so C:\runner2\x is not inside C:\runner.
function Test-PathUnder([string] $Path, [string] $Directory) {
    if (-not $Path -or -not $Directory) { return $false }
    $candidate = Get-CanonicalPath $Path
    $parent = Get-CanonicalPath $Directory
    $candidate.Equals($parent, [StringComparison]::OrdinalIgnoreCase) -or $candidate.StartsWith($parent + '\', [StringComparison]::OrdinalIgnoreCase)
}

# Runs a native command and throws, with its output, when it exits non-zero. Returns the output lines.
function Invoke-Native([string] $FilePath, [string[]] $Arguments = @(), [string] $Description = $FilePath, [int[]] $AllowedExitCodes = @(0)) {
    $output = & $FilePath @Arguments 2>&1 | ForEach-Object { "$_" }
    if ($LASTEXITCODE -notin $AllowedExitCodes) {
        throw "$Description failed with exit code $LASTEXITCODE.$(if ($output) { "`n$($output -join "`n")" })"
    }
    $output
}
