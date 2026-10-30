# Registers both runners with GitHub under github.url, the names in runners.json, github.labels and each runner's own labels,
# removing whatever registration each had before (old name, old repository). Rerun it after changing any
# of those. Needs gh signed in as an admin of that repository or organization; the short-lived tokens it
# fetches go straight to the runner's config and are never printed.
. "$PSScriptRoot\Common.ps1"
$github = $Config.github
if (-not $github.url) { throw 'Set github.url in runners.local.json, for example { "github": { "url": "https://github.com/<owner>/<repo>" } }.' }

# A repository URL gets repository runners, an organization URL organization runners.
function Get-ApiScope([string] $Url) {
    $parts = ([Uri]$Url).AbsolutePath.Trim('/').Split('/')
    if ($parts.Count -eq 1) { "orgs/$($parts[0])" } else { "repos/$($parts[0])/$($parts[1])" }
}
function Get-RunnerToken([string] $Url, [string] $Kind) {
    $token = gh api -X POST "$(Get-ApiScope $Url)/actions/runners/$Kind-token" --jq .token
    if ($LASTEXITCODE -or -not $token) { throw "No $Kind token for $Url (gh must be signed in as an admin)." }
    $token
}
# Newer runners also keep a copy of .runner as .runner_migrated, and config refuses to run while either exists.
$RegistrationFiles = '.runner', '.runner_migrated', '.credentials', '.credentials_migrated', '.credentials_rsaparams'
function Remove-Registration([string] $Directory, [scriptblock] $Configure) {
    $file = @('.runner', '.runner_migrated') | ForEach-Object { Join-Path $Directory $_ } | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
    if (-not $file) { return }
    $old = Get-Content -Raw -LiteralPath $file | ConvertFrom-Json
    & $Configure remove --token (Get-RunnerToken $old.gitHubUrl 'remove')
    # Already gone from GitHub, or config could not reach it: drop the server side directly.
    if ($LASTEXITCODE) { gh api -X DELETE "$(Get-ApiScope $old.gitHubUrl)/actions/runners/$($old.agentId)" 2>$null | Out-Null }
    # Then whatever config left of the local files.
    Remove-Item -LiteralPath ($RegistrationFiles | ForEach-Object { Join-Path $Directory $_ }) -Force -ErrorAction SilentlyContinue
}

& (Join-Path $PSScriptRoot 'Stop-Runners.ps1') -Drain
$runners = @(
    @{ Name = $Config.windows.name; Labels = $Config.windows.labels; Directory = $WindowsRunner; Work = '_work'; Configure = { & (Join-Path $WindowsRunner 'config.cmd') @args } }
    # The Linux runner is configured from a throwaway container of the same image, on the same /runner mount.
    @{ Name = $Config.linux.name; Labels = $Config.linux.labels; Directory = $LinuxRunner; Work = $Config.linux.workFolder; Configure = { & $Docker run --rm --mount "type=bind,source=$LinuxRunner,target=/runner" $Config.linux.image configure @args } }
)
foreach ($runner in $runners) {
    Remove-Registration $runner.Directory $runner.Configure
    & $runner.Configure --unattended --url $github.url --token (Get-RunnerToken $github.url 'registration') --name $runner.Name --labels (@($github.labels) + @($runner.Labels) -join ',') --work $runner.Work --replace
    if ($LASTEXITCODE) { throw "Registering $($runner.Name) failed." }
}
& (Join-Path $PSScriptRoot 'Start-Runners.ps1')
