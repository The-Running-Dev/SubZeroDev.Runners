$ErrorActionPreference = 'Stop'
$root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
$errorsFound = @()
foreach ($file in Get-ChildItem $root -Filter *.ps1 -Recurse) {
    $tokens = $null; $parseErrors = $null
    [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$parseErrors) | Out-Null
    $errorsFound += @($parseErrors)
}
if ($errorsFound.Count) { throw ($errorsFound | Out-String) }
Write-Output 'All delivered PowerShell scripts parse successfully.'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('smoke-eligibility-' + [guid]::NewGuid())
New-Item $temp -ItemType Directory | Out-Null
try {
    $registration = Join-Path $temp '.runner'
    @{gitHubUrl='https://github.com/fixture/consumer'; agentId=7; agentName='fixture-linux'} | ConvertTo-Json | Set-Content $registration
    $global:smokeFixtureStatus = 'online'
    $global:smokeFixtureId = 7
    $global:smokeFixtureLabel = 'subzerodev-linux'
    function gh {
        $global:LASTEXITCODE = 0
        if ($args -contains 'repos/fixture/consumer/actions/runners?per_page=100' -or $args -contains 'orgs/fixture/actions/runners?per_page=100' -or $args -contains 'orgs/fixture/actions/runner-groups/77/runners?per_page=100') {
            @(@{runners=@(@{id=$global:smokeFixtureId;name='fixture-linux';os='linux';status=$global:smokeFixtureStatus;busy=$false;labels=@(@{name='self-hosted'},@{name='Linux'},@{name='X64'},@{name=$global:smokeFixtureLabel})})}) | ConvertTo-Json -Depth 8 -AsArray
        } elseif ($args -contains 'repos/fixture/consumer') {
            @(@{id=99;full_name='fixture/consumer';private=$true;owner=@{type='Organization'};archived=$global:smokeFixtureArchived;disabled=$false}) | ConvertTo-Json -Depth 8 -AsArray
        } elseif ($args -contains 'repos/fixture/consumer/actions/permissions') {
            @(@{enabled=$global:smokeFixtureActionsEnabled}) | ConvertTo-Json -AsArray
        } elseif ($args -contains 'orgs/fixture/actions/runner-groups?per_page=100') {
            @(@{runner_groups=@(@{id=77;name='Selected';visibility='selected';inherited=$false;restricted_to_workflows=$global:smokeFixtureRestricted;allows_public_repositories=$false})}) | ConvertTo-Json -Depth 8 -AsArray
        } elseif ($args -contains 'orgs/fixture/actions/runner-groups/77/repositories?per_page=100') {
            @(@{repositories=@(@{id=$global:smokeFixtureRepoId})}) | ConvertTo-Json -Depth 8 -AsArray
        } else { throw "Unexpected request: $args" }
    }
    $checker = Join-Path $root 'scripts/docs-smoke/Get-SmokeEligibility.ps1'
    $global:smokeFixtureArchived = $false; $global:smokeFixtureActionsEnabled = $true
    $result = & $checker -RunnerRegistration $registration | ConvertFrom-Json
    if ($result.repository -ne 'fixture/consumer' -or -not $result.availableNow -or $result.runnerId -ne 7) { throw 'Eligible identity was not selected.' }
    $rejected = $false
    try { & $checker -RunnerRegistration $registration -Repository fixture/other | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Cross-repository runner was accepted.' }
    $global:smokeFixtureId = 8; $rejected = $false
    try { & $checker -RunnerRegistration $registration | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Mismatched registration ID was accepted.' }
    $global:smokeFixtureId = 7; $global:smokeFixtureStatus = 'offline'; $rejected = $false
    try { & $checker -RunnerRegistration $registration | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Offline runner was reported available.' }
    $global:smokeFixtureStatus = 'online'; $global:smokeFixtureLabel = 'ubuntu-latest'; $rejected = $false
    try { & $checker -RunnerRegistration $registration | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Runner without the subzerodev-linux label was accepted.' }
    $global:smokeFixtureLabel = 'subzerodev-linux'
    Write-Output 'Five synthetic eligibility cases pass: eligible, cross-repo refusal, ID mismatch refusal, offline refusal, missing-label refusal.'
    @{gitHubUrl='https://github.com/fixture'; agentId=7; agentName='fixture-linux'} | ConvertTo-Json | Set-Content $registration
    $global:smokeFixtureStatus = 'online'; $global:smokeFixtureRestricted=$false; $global:smokeFixtureRepoId=99
    $result = & $checker -RunnerRegistration $registration -Repository fixture/consumer | ConvertFrom-Json
    if (-not $result.availableNow -or $result.runnerGroup -ne 'Selected') { throw 'Eligible organization group was not recognized.' }
    $rejected = $false
    try { & $checker -RunnerRegistration $registration | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Organization runner silently selected a consumer.' }
    $global:smokeFixtureRepoId = 100; $rejected = $false
    try { & $checker -RunnerRegistration $registration -Repository fixture/consumer | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Disallowed organization repository was accepted.' }
    $global:smokeFixtureRepoId = 99; $global:smokeFixtureRestricted=$true; $rejected = $false
    try { & $checker -RunnerRegistration $registration -Repository fixture/consumer | Out-Null } catch { $rejected = $true }
    if (-not $rejected) { throw 'Workflow restriction was ignored.' }
    Write-Output 'Four organization eligibility cases pass: selected group access, candidate required, unselected repo refusal, workflow restriction refusal.'
    $global:smokeFixtureRestricted=$false
    foreach ($bad in @(@{Archived=$true;Enabled=$true}, @{Archived=$false;Enabled=$false})) {
        $global:smokeFixtureArchived=$bad.Archived; $global:smokeFixtureActionsEnabled=$bad.Enabled; $rejected=$false
        try { & $checker -RunnerRegistration $registration -Repository fixture/consumer | Out-Null } catch { $rejected=$true }
        if (-not $rejected) { throw 'Unavailable consumer policy was accepted.' }
    }
    Write-Output 'Archived consumers and disabled Actions are refused.'
} finally { Remove-Item $temp -Recurse -Force }
