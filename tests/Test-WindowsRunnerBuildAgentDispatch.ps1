#Requires -Version 7.2
# Dispatch-flow tests with a fake `gh`; no repository is contacted and no workflow runs.
$ErrorActionPreference = 'Stop'
$script = Join-Path $PSScriptRoot 'Invoke-WindowsRunnerBuildAgentAcceptance.ps1'
$template = Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot 'windows-runner-buildagent.yml')
$work = Join-Path ([IO.Path]::GetTempPath()) "buildagent-dispatch-test-$PID"
New-Item -ItemType Directory -Force $work | Out-Null
$checkerLog = Join-Path $work 'checker.log'
$checker = Join-Path $work 'checker.ps1'
'param($Repository, $RunId, $ComputerName, $ExpectedRunnerNames, $ReportDirectory) Add-Content -LiteralPath $PSScriptRoot\checker.log "$Repository $RunId $ComputerName $($ExpectedRunnerNames -join ",")"' | Set-Content -LiteralPath $checker
$state = @{}
function Reset-State([hashtable] $Overrides = @{}) {
    $script:state = @{ Private = $true; Workflow = $null; Conclusion = 'success'; Put = $null; Dispatch = $null; Calls = [Collections.Generic.List[string]]::new() }
    foreach ($key in $Overrides.Keys) { $script:state[$key] = $Overrides[$key] }
    Remove-Item -LiteralPath $checkerLog -ErrorAction SilentlyContinue
}
function gh {
    $global:LASTEXITCODE = 0
    $line = "$args"
    $state.Calls.Add($line)
    $body = if ($MyInvocation.ExpectingInput) { ($input | Out-String) }
    switch -Regex ($line) {
        '^api repos/[^/]+/[^/]+$' { return (@{ private = $state.Private; default_branch = 'main' } | ConvertTo-Json) }
        '^api (-X PUT )?repos/.+/contents/' {
            if ($args -contains 'PUT') { $state.Put = $body; return '{}' }
            if ($null -eq $state.Workflow) { $global:LASTEXITCODE = 1; return }
            return (@{ content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($state.Workflow)) } | ConvertTo-Json)
        }
        '^api repos/.+/actions/workflows/[^/ ]+( --silent)?$' { return '{}' }
        '-X POST repos/.+/dispatches' { $state.Dispatch = ($body | ConvertFrom-Json); return }
        '/runs\?event=workflow_dispatch' {
            return (@{ workflow_runs = @(@{ id = 555; display_title = "Windows runner BuildAgent acceptance $($state.Dispatch.inputs.setup_id)"; status = 'completed'; conclusion = $state.Conclusion; html_url = 'https://example/run/555' }) } | ConvertTo-Json -Depth 5)
        }
        '^api repos/.+/actions/runs/555$' { return (@{ id = 555; status = 'completed'; conclusion = $state.Conclusion; html_url = 'https://example/run/555' } | ConvertTo-Json) }
        default { throw "Unexpected gh call: $line" }
    }
}
function Assert-Throws([scriptblock] $Block, [string] $Pattern, [string] $Case) {
    $message = $null
    try { & $Block | Out-Null } catch { $message = $_.Exception.Message }
    if (-not $message) { throw "Expected failure was accepted: $Case" }
    if ($message -notmatch $Pattern) { throw "Case '$Case' failed for another reason: $message" }
}
$common = @{ Repository = 'AbsoluteZeroDev/runner-checks'; ComputerName = 'Test-Host'; CheckerPath = $checker }

Reset-State @{ Private = $false; Workflow = $template }
Assert-Throws { & $script @common } 'public' 'public repository'

Reset-State
Assert-Throws { & $script @common } 'InstallWorkflow' 'workflow absent without -InstallWorkflow'
if ($state.Put) { throw 'The workflow was installed without -InstallWorkflow.' }

Reset-State @{ Workflow = $template + "# edited`n" }
Assert-Throws { & $script @common -InstallWorkflow } 'differs' 'differing workflow'
if ($state.Put) { throw 'A differing workflow was overwritten.' }

Reset-State
& $script @common -InstallWorkflow | Out-Null
$put = $state.Put | ConvertFrom-Json
if ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($put.content)) -cne $template) { throw 'The installed workflow is not this clone''s template.' }
$inputs = $state.Dispatch.inputs
$pins = (Get-Content -Raw -LiteralPath (Join-Path $PSScriptRoot '..\runners.json') | ConvertFrom-Json).buildAgent
if ($state.Dispatch.ref -ne 'main' -or $inputs.computer_name -ne 'Test-Host' -or $inputs.runner_label -ne 'subzerodev-pair-test-host' -or $inputs.expected_tool_version -ne $pins.tool.version -or $inputs.expected_image_digest -ne ($pins.image -replace '^.*@', '')) {
    throw "Dispatch inputs are wrong: $($inputs | ConvertTo-Json -Compress)"
}
if (@($inputs.runner_names | ConvertFrom-Json) -join ',' -ne 'subzerodev.runner.windows.test-host.win01,subzerodev.runner.windows.test-host.win02') { throw 'Expected runner names are wrong.' }
if ((Get-Content -Raw -LiteralPath $checkerLog) -notmatch '^AbsoluteZeroDev/runner-checks 555 Test-Host subzerodev.runner.windows.test-host.win01,subzerodev.runner.windows.test-host.win02') { throw 'The checker did not receive the run.' }

# An identical workflow already in place is not touched, and an explicit label and names are passed on unchanged.
Reset-State @{ Workflow = $template }
& $script @common -RunnerLabel custom-pair -ExpectedRunnerNames 'one', 'two' | Out-Null
if ($state.Put) { throw 'An identical workflow was rewritten.' }
if ($state.Dispatch.inputs.runner_label -ne 'custom-pair' -or (@($state.Dispatch.inputs.runner_names | ConvertFrom-Json) -join ',') -ne 'one,two') { throw 'Explicit label or names were not used.' }

# A failed run still has its evidence read, and the script still fails.
Reset-State @{ Workflow = $template; Conclusion = 'failure' }
Assert-Throws { & $script @common } 'failed' 'failed run'
if (-not (Test-Path -LiteralPath $checkerLog)) { throw 'The evidence of a failed run was not read.' }

Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
Write-Output 'PASS: acceptance dispatch refuses public repositories, absent or differing workflows, pins the inputs from runners.json, and judges failed runs too. No repository contacted.'
