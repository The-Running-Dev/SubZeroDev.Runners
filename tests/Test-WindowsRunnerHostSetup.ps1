#Requires -Version 7.2
# Host orchestration fixtures only; no target runners or GitHub repositories are changed.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$functions = Join-Path $repo 'scripts\WindowsRunnerSetup.ps1'
. $functions
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock] $Action, [string] $Message) {
    $rejected = $false
    try { & $Action | Out-Null } catch { $rejected = $true }
    Assert $rejected $Message
}
Assert ((Get-RunnerSetupScope 'https://github.com/AbsoluteZeroDev/') -eq 'orgs/AbsoluteZeroDev') 'Organization scope incorrect.'
Assert ((Get-RunnerSetupScope 'https://github.com/example/project') -eq 'repos/example/project') 'Repository scope incorrect.'
foreach ($url in 'http://github.com/example', 'https://other.example/example', 'https://github.com/example/project/more', 'https://github.com/example?token=x') {
    Assert-Throws { Get-RunnerSetupScope $url } 'Unsafe target accepted.'
}

# Verify authentication reuses a credential and never starts login/refresh in unattended mode.
$auth = @{ Calls = [Collections.Generic.List[string]]::new(); SignedIn = $true; CanRegister = $true }
$oldGhToken = $env:GH_TOKEN
$oldGitHubToken = $env:GITHUB_TOKEN
try {
    Remove-Item Env:GH_TOKEN, Env:GITHUB_TOKEN -ErrorAction SilentlyContinue
    function gh {
        $auth.Calls.Add(($args -join ' '))
        $global:LASTEXITCODE = 0
        if ($args[0] -eq 'auth' -and $args[1] -eq 'status' -and -not $auth.SignedIn) { $global:LASTEXITCODE = 1 }
        if ($args[0] -eq 'api' -and -not $auth.CanRegister) { $global:LASTEXITCODE = 1 }
    }
    Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $true -WithSmoke $false
    Assert (-not @($auth.Calls | Where-Object { $_ -match 'auth (login|refresh)' }).Count) 'Existing credential triggered sign-in.'
    Assert (@($auth.Calls | Where-Object { $_ -like '*registration-token --silent' }).Count -eq 1) 'Runner permissions were not checked without token output.'
    $auth.SignedIn = $false
    Assert-Throws { Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $true -WithSmoke $false } 'Unattended setup accepted missing auth.'
    $auth.Calls.Clear()
    Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $false -WithSmoke $true
    Assert (@($auth.Calls | Where-Object { $_ -like 'auth login*--web*admin:org,repo,workflow' }).Count -eq 1) 'Interactive setup did not request the required scopes.'
    $env:GH_TOKEN = 'synthetic-test-value'
    $auth.Calls.Clear()
    Assert-Throws { Confirm-RunnerSetupAuthentication -Scope orgs/AbsoluteZeroDev -NonInteractive $false -WithSmoke $true } 'Invalid environment credential triggered browser fallback.'
    Assert (-not @($auth.Calls | Where-Object { $_ -match 'auth (login|refresh)' }).Count) 'Environment credential triggered sign-in.'
} finally {
    $env:GH_TOKEN = $oldGhToken
    $env:GITHUB_TOKEN = $oldGitHubToken
    Remove-Item Function:gh
}

# Verify the real high-level flow and pair-only targeting on hosts with more than two instances.
. $functions
$flow = @{ Auth = 0; Clones = @(); Installs = @(); Verified = 0; Smoke = @() }
function Confirm-RunnerSetupAuthentication { param($Scope, $NonInteractive, $WithSmoke) $flow.Auth++ }
function Sync-RunnerSetupInstance { param($Clone, $InstanceId, $SourceCommit, $GitHubUrl) $flow.Clones += $Clone }
function Install-RunnerSetupInstance { param($Clone, $InstanceId, $GitHubUrl, $Labels) $flow.Installs += [pscustomobject]@{ Id = $InstanceId; Labels = $Labels } }
function Get-RunnerSetupEvidence {
    param($Clone, $InstanceId)
    [pscustomobject]@{ Instance = $InstanceId; Name = "custom-$InstanceId"; AgentId = [int]$InstanceId.Substring(3); Workspace = "$Clone\work"; SupervisorPid = 100 + [int]$InstanceId.Substring(3) }
}
function Confirm-RunnerSetupHost { param($Instances, $Scope) $flow.Verified = $Instances.Count }
function Invoke-RunnerSetupSmoke { param($Repository, $Label, $SourceClone, $ExpectedRunnerNames) $flow.Smoke += [pscustomobject]@{ Repo = $Repository; Label = $Label; Names = $ExpectedRunnerNames } }
$options = @{ Count = 3; InstallRoot = 'C:\Fixtures'; GitHubUrl = 'https://github.com/AbsoluteZeroDev'; ExtraLabels = @('extra'); SourceCommit = ('a' * 40); SmokeRepository = 'AbsoluteZeroDev/RunnerSmoke'; NonInteractive = $true }
Invoke-WindowsRunnerHostSetup @options
Assert ($flow.Auth -eq 1 -and $flow.Verified -eq 3 -and $flow.Installs.Count -eq 3) 'Host setup skipped authentication, instances or verification.'
Assert (($flow.Installs.Id -join ',') -eq 'win01,win02,win03') 'Instance IDs were not deterministic.'
$pair = "subzerodev-pair-$($env:COMPUTERNAME.ToLowerInvariant())"
Assert ($flow.Installs[0].Labels -contains $pair -and $flow.Installs[1].Labels -contains $pair -and $flow.Installs[2].Labels -notcontains $pair) 'Smoke targeting did not select only the first two instances.'
Assert (($flow.Smoke[0].Names -join ',') -eq 'custom-win01,custom-win02') 'Smoke ignored actual persisted identities.'
$options.SmokeRepository = 'DifferentOrg/Smoke'
Assert-Throws { Invoke-WindowsRunnerHostSetup @options } 'Cross-target smoke repository accepted.'
$options.SmokeRepository = ''
$options.Count = 1
Invoke-WindowsRunnerHostSetup @options
Assert ($flow.Smoke.Count -eq 1) 'Setup dispatched a smoke test without a requested repository.'

# Verify online state, remote/local ID equality, isolation and adding labels to existing registrations.
. $functions
$evidence = @(
    [pscustomobject]@{ Instance = 'win01'; Name = 'one'; AgentId = 11; Workspace = 'C:\one'; SupervisorPid = 101; Labels = @('shared', 'host') },
    [pscustomobject]@{ Instance = 'win02'; Name = 'two'; AgentId = 22; Workspace = 'C:\two'; SupervisorPid = 202; Labels = @('shared', 'host') }
)
$remote = @{ Offline = $false; WrongId = $false; Added = 0 }
function Invoke-RunnerSetupGh {
    param($Arguments)
    if ($Arguments[1] -like '*/labels') { return [pscustomobject]@{ labels = @(@{ name = 'shared' }, @{ name = 'host' }) } }
    @([pscustomobject]@{ runners = @(
        @{ name = 'one'; id = $(if ($remote.WrongId) { 99 } else { 11 }); status = $(if ($remote.Offline) { 'offline' } else { 'online' }); labels = @(@{ name = 'shared' }) },
        @{ name = 'two'; id = 22; status = 'online'; labels = @(@{ name = 'shared' }) }
    ) })
}
Set-Item Function:gh -Value { $null = $input | Out-String; $remote.Added++; $global:LASTEXITCODE = 0 }
Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example
Assert ($remote.Added -eq 2) 'Existing runners did not receive their missing targeting labels.'
$remote.Offline = $true
Assert-Throws { Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example } 'Offline runner accepted.'
$remote.Offline = $false; $remote.WrongId = $true
Assert-Throws { Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example } 'Mismatched registration ID accepted.'
$remote.WrongId = $false; $evidence[1].Workspace = 'C:\one'
Assert-Throws { Confirm-RunnerSetupHost -Instances $evidence -Scope orgs/example } 'Shared workspace accepted.'
Remove-Item Function:gh

Write-Output 'PASS: authentication, deterministic host orchestration, target/smoke boundaries, pair labels, registration identity/online checks and isolation (external operations mocked).'
