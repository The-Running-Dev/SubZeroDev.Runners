# The Actions runner release archive, for Windows and Linux: one version (runners.json runnerVersion), one download path,
# checked against the SHA-256 GitHub publishes for the release before anything uses it.

# Returns the verified archive path in $DownloadDirectory. $Platform is win-x64 or linux-x64.
# A cached file that fails verification is deleted and the call throws; rerun to download it again.
function Get-RunnerArchive {
    param(
        [Parameter(Mandatory)] [ValidateSet('win-x64', 'linux-x64')] [string] $Platform,
        [Parameter(Mandatory)] [string] $Version,
        [Parameter(Mandatory)] [string] $DownloadDirectory
    )
    $extension = if ($Platform -eq 'win-x64') { 'zip' } else { 'tar.gz' }
    $name = "actions-runner-$Platform-$Version.$extension"
    New-Item -ItemType Directory -Force $DownloadDirectory | Out-Null
    $path = Join-Path $DownloadDirectory $name
    if (-not (Test-Path -LiteralPath $path)) {
        Write-Output "Downloading $name..."
        Invoke-WebRequest "https://github.com/actions/runner/releases/download/v$Version/$name" -OutFile $path
    }
    $release = & gh api "repos/actions/runner/releases/tags/v$Version" | ConvertFrom-Json
    if ($LASTEXITCODE) { throw "Could not read the v$Version release of actions/runner to verify $name." }
    $digest = ($release.assets | Where-Object name -eq $name).digest
    $expected = if ($digest) { $digest -replace '^sha256:' } elseif ($release.body -match "<!-- BEGIN SHA $Platform -->([0-9a-f]{64})<!-- END SHA $Platform -->") { $Matches[1] }
    if (-not $expected) { throw "GitHub publishes no SHA-256 for $name; not using it." }
    if ((Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $expected) {
        Remove-Item -LiteralPath $path
        throw "$name does not match its published SHA-256 and was deleted; rerun to download it again."
    }
    [pscustomobject]@{ Path = $path; Name = $name; Sha256 = $expected.ToLowerInvariant() }
}
