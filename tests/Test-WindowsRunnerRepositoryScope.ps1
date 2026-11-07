#Requires -Version 7.2
# Repository API fixtures only. No registration tokens, runner changes or workflow dispatches.
$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path $PSScriptRoot -Parent) 'scripts/WindowsRunnerSetup.ps1')
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Pattern) {
    try { & $Action | Out-Null } catch {
        Assert ($_.Exception.Message -match $Pattern) "Unexpected failure: $($_.Exception.Message)"
        return
    }
    throw "Expected rejection matching: $Pattern"
}
$fixture = @{ Calls = @(); OwnerType = 'Organization'; Archived = $false; Disabled = $false; Enabled = $true; Moved = $false; Denied = $false }
function Invoke-RunnerSetupGh {
    param($Arguments)
    Assert ($Arguments.Count -eq 2 -and $Arguments[0] -eq 'api') 'Preflight attempted an unexpected operation.'
    $endpoint = $Arguments[1]
    $fixture.Calls += $endpoint
    if ($fixture.Denied) { throw 'Fixture API access denied.' }
    if ($endpoint.EndsWith('/actions/permissions')) { return @{ enabled = $fixture.Enabled } }
    @{ full_name = $(if ($fixture.Moved) { 'moved/elsewhere' } else { $endpoint.Substring(6) });
       owner = @{ type = $fixture.OwnerType }; archived = $fixture.Archived; disabled = $fixture.Disabled }
}

$repositories = @(Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @('AbsoluteZeroDev/One', 'AbsoluteZeroDev/Two'))
Assert (($repositories -join ',') -eq 'AbsoluteZeroDev/One,AbsoluteZeroDev/Two') 'Valid organization repositories were not reported.'
Assert ($fixture.Calls.Count -eq 4) 'Preflight did not read metadata and Actions policy for each repository.'
$fixture.OwnerType = 'User'
$repositories = @(Confirm-RunnerSetupRepositories -Scope repos/The-Running-Dev/SubZeroDev.FileManager)
Assert ($repositories.Count -eq 1 -and $repositories[0] -eq 'The-Running-Dev/SubZeroDev.FileManager') 'Repository scope did not validate its target by default.'
$repositories = @(Confirm-RunnerSetupRepositories -Scope repos/The-Running-Dev/SubZeroDev.FileManager -Repositories @('the-running-dev/subzerodev.filemanager'))
Assert ($repositories.Count -eq 1) 'Case-insensitive scope rejected.'

$fixture.Calls = @()
Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @('AbsoluteZeroDev/One', 'The-Running-Dev/SubZeroDev.FileManager') } 'cannot serve'
Assert-Throws { Confirm-RunnerSetupRepositories -Scope repos/The-Running-Dev/One -Repositories @('The-Running-Dev/Two') } 'cannot serve'
foreach ($name in '', 'owner', 'owner/repo?token=x', 'https://github.com/owner/repo', 'owner/repo/more') {
    Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @($name) } 'owner/repository'
}
Assert ($fixture.Calls.Count -eq 0) 'Malformed or cross-scope targets reached the API.'
Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/The-Running-Dev -Repositories @('The-Running-Dev/One') } 'not owned by an organization'
$fixture.OwnerType = 'Organization'
foreach ($field in 'Archived', 'Disabled') {
    $fixture[$field] = $true
    Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @('AbsoluteZeroDev/One') } 'archived or disabled'
    $fixture[$field] = $false
}
foreach ($enabled in $false, $null) {
    $fixture.Enabled = $enabled
    Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @('AbsoluteZeroDev/One') } 'disabled or its enabled state'
}
$fixture.Enabled = $true; $fixture.Moved = $true
Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @('AbsoluteZeroDev/One') } 'moved'
$fixture.Moved = $false; $fixture.Denied = $true
Assert-Throws { Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -Repositories @('AbsoluteZeroDev/One') } 'access denied'
$fixture.Denied = $false; $fixture.Calls = @()
$warning = @()
$repositories = @(Confirm-RunnerSetupRepositories -Scope orgs/AbsoluteZeroDev -WarningVariable warning 3>$null)
Assert ($repositories.Count -eq 0 -and $warning.Count -eq 1 -and $fixture.Calls.Count -eq 0) 'Missing intended repositories silently claimed validation.'

# The real orchestration must stop before instance sync/install, verification, state writes or smoke.
$flow = @{ Auth = 0; Mutations = 0 }
function Confirm-RunnerSetupAuthentication { param($Scope, $NonInteractive, $WithSmoke) $flow.Auth++ }
function Get-SetupPendingAction { param($InstallRoot) @() }
function Sync-RunnerSetupInstance { $flow.Mutations++ }
function Install-RunnerSetupInstance { $flow.Mutations++ }
function Confirm-RunnerSetupHost { $flow.Mutations++ }
function Set-SetupStep { $flow.Mutations++ }
function Invoke-RunnerSetupSmoke { $flow.Mutations++ }
$options = @{ Count = 2; InstallRoot = 'fixture-root'; GitHubUrl = 'https://github.com/AbsoluteZeroDev';
    SourceCommit = ('a' * 40); TargetRepositories = @('The-Running-Dev/SubZeroDev.FileManager'); NonInteractive = $true; SkipBuildAgent = $true }
Assert-Throws { Invoke-WindowsRunnerHostSetup @options } 'cannot serve'
$options.TargetRepositories = @('AbsoluteZeroDev/One'); $fixture.Denied = $true
Assert-Throws { Invoke-WindowsRunnerHostSetup @options } 'access denied'
Assert ($flow.Auth -eq 2 -and $flow.Mutations -eq 0) 'Rejected repository preflight changed runner instances or dispatched jobs.'
Write-Output 'PASS: organization/personal repository boundaries, Actions enabled state, archived/disabled/moved/unreadable targets, explicit unverified scope and rejection before runner mutations (API mocked).'
