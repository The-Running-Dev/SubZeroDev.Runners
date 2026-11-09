#Requires -Version 7.2
# Dispatch-flow tests with a fake `gh`; no repository is contacted and no workflow runs.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Invoke-WindowsRunnerBuildAgentAcceptance.ps1'
$template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'windows-runner-buildagent.yml')
$work = Join-Path ([IO.Path]::GetTempPath()) ("buildagent-dispatch-test-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Force $work | Out-Null
$checkerLog = Join-Path $work 'checker.log'
$checker = Join-Path $work 'checker.ps1'
'param($Repository, $RunId, $ComputerName, $ExpectedRunnerNames, $ReportDirectory) Add-Content -LiteralPath $PSScriptRoot\checker.log "$Repository $RunId $ComputerName $($ExpectedRunnerNames -join ",")"' | Set-Content -LiteralPath $checker
$fake = @{}
function Reset-State([hashtable] $Overrides = @{}) {
    $script:fake = @{ Private = $true; Workflow = $null; Conclusion = 'success'; Put = $null; Dispatch = $null; DispatchError = $false; DispatchRejected = $false; ListError = $false; RefreshWrongId = $false; RunStatus = 'completed'; Cancels = 0; Calls = [Collections.Generic.List[string]]::new() }
    foreach ($key in $Overrides.Keys) { $script:fake[$key] = $Overrides[$key] }
    Remove-Item -LiteralPath $checkerLog -ErrorAction SilentlyContinue
}
function gh {
    $global:LASTEXITCODE = 0
    $line = "$args"
    $fake.Calls.Add($line)
    $body = if ($MyInvocation.ExpectingInput) { ($input | Out-String) }
    switch -Regex ($line) {
        '^api repos/[^/]+/[^/]+$' { return (@{ full_name = 'AbsoluteZeroDev/runner-checks'; private = $fake.Private; default_branch = 'main' } | ConvertTo-Json) }
        '^api (-X PUT )?repos/.+/contents' {
            if ($args -contains 'PUT') { $fake.Put = $body; return '{}' }
            if ($line -match '/contents\?') { return (@(@{ name = '.github'; type = 'dir' }) | ConvertTo-Json -AsArray) }
            if ($line -match '/contents/\.github\?') { return (@(@{ name = 'workflows'; type = 'dir' }) | ConvertTo-Json -AsArray) }
            if ($line -match '/contents/\.github/workflows\?') {
                $entries = if ($null -eq $fake.Workflow) { @() } else { @(@{ name = 'windows-runner-buildagent.yml'; type = 'file' }) }
                return (ConvertTo-Json -InputObject @($entries) -Compress)
            }
            return (@{ type = 'file'; encoding = 'base64'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($fake.Workflow)) } | ConvertTo-Json)
        }
        '^api repos/.+/actions/workflows/[^/ ]+( --silent)?$' { return '{}' }
        '-X POST repos/.+/dispatches' { $fake.Dispatch = ($body | ConvertFrom-Json); if ($fake.DispatchError) { $global:LASTEXITCODE = 1 }; if ($fake.DispatchRejected) { $global:LASTEXITCODE = 1; return "gh: Workflow does not have 'workflow_dispatch' trigger (HTTP 422)" }; return }
        '/runs\?event=workflow_dispatch' {
            if ($fake.ListError) { $global:LASTEXITCODE = 1; return }
            return (@{ workflow_runs = @(@{ id = 555; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-buildagent.yml'; run_attempt = 1; head_branch = 'main'; display_title = "Windows runner BuildAgent acceptance $($fake.Dispatch.inputs.setup_id)"; status = $fake.RunStatus; conclusion = $fake.Conclusion; html_url = 'https://example/run/555' }) } | ConvertTo-Json -Depth 5)
        }
        '^api repos/.+/actions/runs/555$' { return (@{ id = $(if ($fake.RefreshWrongId) { 777 } else { 555 }); event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-buildagent.yml'; run_attempt = 1; head_branch = 'main'; display_title = "Windows runner BuildAgent acceptance $($fake.Dispatch.inputs.setup_id)"; status = $fake.RunStatus; conclusion = $fake.Conclusion; html_url = 'https://example/run/555' } | ConvertTo-Json) }
        '/cancel' { $fake.Cancels++; return }
        default { throw "Unexpected gh call: $line" }
    }
}
function Assert-Throws([scriptblock] $Block, [string] $Pattern, [string] $Case) {
    $message = $null
    try { & $Block | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message) { throw "Expected failure was accepted: $Case" }
    if ($message -notmatch $Pattern) { throw "Case '$Case' failed for another reason: $message" }
}
function Start-Sleep { param($Seconds) }
$common = @{ Repository = 'AbsoluteZeroDev/runner-checks'; ComputerName = 'Test-Host'; CheckerPath = $checker; StateDirectory = (Join-Path $work 'journal') }

Reset-State @{ Private = $false; Workflow = $template }
Assert-Throws { & $script @common } 'public' 'public repository'

Reset-State
Assert-Throws { & $script @common } 'InstallWorkflow' 'workflow absent without -InstallWorkflow'
if ($fake.Put) { throw 'The workflow was installed without -InstallWorkflow.' }

Reset-State @{ Workflow = $template + "# edited`n" }
Assert-Throws { & $script @common -InstallWorkflow } 'differs' 'differing workflow'
if ($fake.Put) { throw 'A differing workflow was overwritten.' }

Reset-State
& $script @common -InstallWorkflow | Out-Null
$put = $fake.Put | ConvertFrom-Json
if ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($put.content)) -cne $template) { throw 'The installed workflow is not this clone''s template.' }
$inputs = $fake.Dispatch.inputs
$pins = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\runners.json') | ConvertFrom-Json).buildAgent
if ($put.branch -cne 'main' -or $fake.Dispatch.ref -ne 'main' -or $inputs.computer_name -ne 'Test-Host' -or $inputs.runner_label -ne 'subzerodev-pair-test-host' -or $inputs.expected_tool_version -ne $pins.tool.version -or $inputs.expected_image_digest -ne ($pins.image -replace '^.*@', '')) {
    throw "Dispatch inputs are wrong: $($inputs | ConvertTo-Json -Compress)"
}
if (@($inputs.runner_names | ConvertFrom-Json) -join ',' -ne 'subzerodev.runner.windows.test-host.win01,subzerodev.runner.windows.test-host.win02') { throw 'Expected runner names are wrong.' }
if ((Get-Content -Raw -LiteralPath $checkerLog) -notmatch '^AbsoluteZeroDev/runner-checks 555 Test-Host subzerodev.runner.windows.test-host.win01,subzerodev.runner.windows.test-host.win02') { throw 'The checker did not receive the run.' }

# An identical workflow already in place is not touched, and an explicit label and names are passed on unchanged.
Reset-State @{ Workflow = $template }
& $script @common -RunnerLabel custom-pair -ExpectedRunnerNames 'one', 'two' | Out-Null
if ($fake.Put) { throw 'An identical workflow was rewritten.' }
if ($fake.Dispatch.inputs.runner_label -ne 'custom-pair' -or (@($fake.Dispatch.inputs.runner_names | ConvertFrom-Json) -join ',') -ne 'one,two') { throw 'Explicit label or names were not used.' }

# A failed run still has its evidence read, and the script still fails.
Reset-State @{ Workflow = $template; Conclusion = 'failure' }
Assert-Throws { & $script @common } 'failed' 'failed run'
if (-not (Test-Path -LiteralPath $checkerLog)) { throw 'The evidence of a failed run was not read.' }

# Persist intent BEFORE a dispatch with a lost response; retry recovers it before dispatching again.
Reset-State @{ Workflow = $template; DispatchError = $true }
Assert-Throws { & $script @common } 'failed' 'ambiguous dispatch response'
$journalPath = Join-Path $common.StateDirectory 'acceptance-state.json'
$journal = Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json
if (-not $journal.activeRun.correlation -or $journal.activeRun.id) { throw 'Dispatch intent was not retained before the failed POST response.' }
$oldCorrelation = $fake.Dispatch.inputs.setup_id
$fake.DispatchError = $false
& $script @common | Out-Null
if ($fake.Dispatch.inputs.setup_id -ceq $oldCorrelation -or (Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json).activeRun) { throw 'Retry failed to recover the old dispatch before starting a new one.' }

# A dispatch GitHub refused (HTTP 4xx) created nothing: its journal must not block every later invocation.
Remove-Item -LiteralPath $journalPath -ErrorAction SilentlyContinue
Reset-State @{ Workflow = $template; DispatchRejected = $true }
Assert-Throws { & $script @common } 'failed' 'refused dispatch'
if ((Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json).activeRun) { throw 'A refused dispatch left a journal that blocks later runs.' }
$fake.DispatchRejected = $false
& $script @common | Out-Null

# An interrupted discovery also leaves its intent; a mutated refreshed run cannot redirect cancellation to another ID.
Reset-State @{ Workflow = $template; ListError = $true }
Assert-Throws { & $script @common } 'failed' 'discovery failure'
if (-not (Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json).activeRun) { throw 'Discovery failure lost the journal.' }
Remove-Item -LiteralPath $journalPath
Reset-State @{ Workflow = $template; RunStatus = 'in_progress'; RefreshWrongId = $true }
Assert-Throws { & $script @common } 'does not match' 'run ID changed on refresh'
if ($fake.Cancels -ne 0 -or -not (Get-Content -Raw -LiteralPath $journalPath | ConvertFrom-Json).activeRun) { throw 'Changed run identity caused cancellation or lost its journal.' }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'PASS: acceptance dispatch refuses public repositories, absent or differing workflows, pins the inputs from runners.json, and judges failed runs too. No repository contacted.'
