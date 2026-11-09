#Requires -Version 7.2
# Every GitHub/process operation below is a recorder. No real runner, workflow, or repository is touched.
param([string] $SetupPath = (Join-Path $PSScriptRoot '..\scripts\WindowsRunnerSetup.ps1'), [ValidateSet('All', 'Recovery', 'Cancellation', 'Discovery', 'Workflow', 'Disruption', 'Options')] [string] $Scenario = 'All')
$ErrorActionPreference = 'Stop'
$root = Join-Path ([IO.Path]::GetTempPath()) ('acceptance-safeguards-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root -Force | Out-Null
$checks = [Collections.Generic.List[string]]::new()
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message }; $checks.Add($Message) }
function Reject([scriptblock] $Action, [string] $Message) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert $failed $Message
}
try {
    if ($Scenario -in 'All', 'Recovery') {
    & {
        . $SetupPath
        $f = @{ Writes = 0; Found = $null; Sleeps = 0 }
        function Start-Sleep { param($Seconds) $f.Sleeps++ }
        function Invoke-RunnerSetupGh { param($Arguments) @{ workflow_runs = @() } }
        function Send-RunnerSetupGh { param($Arguments, $Body) $f.Writes++ }
        $state = @{ version = 1; repository = 'example/private'; profile = ''; completed = @{}; activeRun = @{ id = 0; correlation = 'lost-response'; clone = ''; stopAttempted = $false } }
        Save-RunnerAcceptanceState $root $state
        Reject { Resume-RunnerSetupAcceptance $root example/private 2 } 'Undiscovered dispatch blocks resume instead of discarding its journal'
        Assert ((Get-RunnerAcceptanceState $root).activeRun.correlation -ceq 'lost-response') 'Undiscovered dispatch intent survives indexing timeout'
        Assert ($f.Writes -eq 0) 'Undiscovered dispatch causes no mutation'
    }
    }
    if ($Scenario -in 'All', 'Cancellation') {
    & {
        . $SetupPath
        $f = @{ Writes = 0; Override = @{}; Cancelled = $false }
        $owned = @{ id = 81; correlation = 'own'; branch = 'main' }
        function Invoke-RunnerSetupGh {
            param($Arguments)
            $r = @{ id = 81; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-lifecycle-acceptance.yml'; display_title = 'Windows runner lifecycle acceptance own'; status = 'completed'; head_branch = 'main'; run_attempt = 1 }
            foreach ($k in $f.Override.Keys) { $r[$k] = $f.Override[$k] }
            if ($f.Cancelled) { $r.id = 99 }
            $r
        }
        function Send-RunnerSetupGh { param($Arguments, $Body) $f.Writes++; $f.Cancelled = $true }
        foreach ($case in @(@{ id = 99 }, @{ event = 'push' }, @{ path = '.github/workflows/production.yml' }, @{ display_title = 'other' }, @{ run_attempt = 2 }, @{ head_branch = 'other' }, @{ status = $null })) {
            $f.Override = $case
            Reject { Stop-RunnerAcceptanceRun example/private $owned } "Cancellation rejects changed $($case.Keys -join ',')"
        }
        Assert ($f.Writes -eq 0) 'Identity mismatches never send cancellation'
        $f.Override = @{}
        Stop-RunnerAcceptanceRun example/private $owned | Out-Null
        Assert ($f.Writes -eq 0) 'Owned completed run needs no cancellation'
        $f.Override = @{ status = 'in_progress' }
        $saved = @{ version = 1; repository = 'example/private'; profile = ''; completed = @{}; activeRun = @{ id = 81; correlation = 'own'; branch = 'main'; clone = ''; stopAttempted = $false } }
        Save-RunnerAcceptanceState $root $saved
        Reject { Resume-RunnerSetupAcceptance $root example/private 2 } 'Cancellation confirmation rejects a swapped response'
        Assert ($f.Writes -eq 1 -and (Get-RunnerAcceptanceState $root).activeRun.id -eq 81) 'Unconfirmed cancellation retains the original journal and never cancels a replacement ID'

    }
    }
    if ($Scenario -in 'All', 'Discovery') {
    & {
        . $SetupPath
        $f = @{ Calls = @(); Duplicate = $false }
        function Invoke-RunnerSetupGh {
            param($Arguments)
            $f.Calls = $Arguments
            $r = @{ id = 81; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-lifecycle-acceptance.yml'; display_title = 'Windows runner lifecycle acceptance own'; status = 'completed'; run_attempt = 1 }
            @(@{ workflow_runs = @(@{ display_title = 'unrelated' }) }, @{ workflow_runs = @($r) })
            if ($f.Duplicate) { @{ workflow_runs = @($r) } }
        }
        Assert ((Find-RunnerAcceptanceRun example/private own).id -eq 81 -and $f.Calls -contains '--paginate' -and $f.Calls -contains '--slurp') 'Discovery finds an owned run beyond the first 100 results'
        $f.Duplicate = $true
        Reject { Find-RunnerAcceptanceRun example/private own } 'Duplicate correlation across pages blocks discovery'
    }
    }
    if ($Scenario -in 'All', 'Workflow') {
    & {
        . $SetupPath
        $f = @{ Writes = 0; Broken = ''; Existing = $false; Different = $false; Branch = 'release/host'; Body = $null }
        function gh { $global:LASTEXITCODE = 0 }
        function Invoke-RunnerSetupGh {
            param($Arguments)
            $url = $Arguments[1]
            if ($url -eq 'repos/example/private') { return @{ full_name = 'example/private'; private = $true; default_branch = $f.Branch } }
            if ($f.Broken -eq 'error') { throw 'Synthetic HTTP 503' }
            if ($f.Broken -eq 'object') { return @{ message = 'Not a listing' } }
            if ($url -like '*/contents?ref=*') { return @{ name = '.github'; type = 'dir' } }
            if ($url -like '*/contents/.github?ref=*') { return @{ name = 'workflows'; type = 'dir' } }
            if ($url -like '*/contents/.github/workflows?ref=*') {
                if ($f.Existing) { return @{ name = 'windows-runner-lifecycle-acceptance.yml'; type = 'file' } }
                return @()
            }
            if ($url -like '*/contents/.github/workflows/*.yml?ref=*') {
                $text = Get-Content -Raw -LiteralPath (Join-Path (Split-Path $PSScriptRoot -Parent) 'tests/windows-runner-lifecycle-acceptance.yml')
                if ($f.Different) { $text += '# changed' }
                return @{ type = 'file'; encoding = 'base64'; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($text)) }
            }
            throw "Unexpected URL: $url"
        }
        function Send-RunnerSetupGh { param($Arguments, $Body) $f.Writes++; $f.Body = $Body }
        foreach ($broken in 'error', 'object') {
            $f.Broken = $broken
            Reject { Install-RunnerAcceptanceWorkflow example/private (Split-Path $PSScriptRoot -Parent) } "Workflow install rejects $broken response"
            Assert ($f.Writes -eq 0) "Workflow install makes no PUT after $broken response"
        }
        $f.Broken = ''; $f.Existing = $true
        Install-RunnerAcceptanceWorkflow example/private (Split-Path $PSScriptRoot -Parent) | Out-Null
        Assert ($f.Writes -eq 0) 'Identical existing workflow is retained'
        $f.Different = $true
        Reject { Install-RunnerAcceptanceWorkflow example/private (Split-Path $PSScriptRoot -Parent) } 'Differing workflow is refused'
        Assert ($f.Writes -eq 0) 'Differing workflow is never overwritten'
        $f.Existing = $false
        $branch = Install-RunnerAcceptanceWorkflow example/private (Split-Path $PSScriptRoot -Parent)
        Assert ($f.Writes -eq 1 -and $f.Body.branch -ceq 'release/host' -and $branch -ceq 'release/host' -and -not $f.Body.ContainsKey('sha')) 'Create uses the inspected branch and cannot overwrite a concurrent file'
        . $SetupPath
        function gh { $global:LASTEXITCODE = 0; $f.Response }
        foreach ($response in @('', 'null')) {
            $f.Response = $response
            Reject { Invoke-RunnerSetupGh @('api', 'repos/example/private/contents') } 'Empty or null successful HTTP response is not absence'
        }
    }
    }
    if ($Scenario -in 'All', 'Disruption') {
    & {
        . $SetupPath
        $clones = @('win01', 'win02' | ForEach-Object { Join-Path $root $_ })
        $instances = @(@{ Instance = 'win01'; Name = 'runner-one'; AgentId = 11 }, @{ Instance = 'win02'; Name = 'runner-two'; AgentId = 22 })
        $f = @{ Latest = 0; Change = ''; Correlation = ''; Done = $false; Processes = 0; Cancels = 0 }
        function Start-Sleep { param($Seconds) }
        function Invoke-RunnerSetupGh {
            param($Arguments)
            $url = $Arguments[1]
            if ($url -eq 'repos/example/private') { return @{ default_branch = 'main' } }
            $remote = @{ id = 81; event = 'workflow_dispatch'; path = '.github/workflows/windows-runner-lifecycle-acceptance.yml'; display_title = "Windows runner lifecycle acceptance $($f.Correlation)"; status = $(if ($f.Done) { 'completed' } else { 'in_progress' }); run_attempt = 1; head_branch = 'main' }
            if ($url -like '*runs?event=*') { return @{ workflow_runs = @($remote) } }
            if ($url -like '*/runs/81') { return $remote }
            if ($url -like '*/jobs?*') {
                $f.Latest++
                $j = @{ id = 91; run_id = 81; run_attempt = 1; name = 'Controlled lifecycle job'; status = 'in_progress'; runner_name = 'runner-one'; runner_id = 11; steps = @(@{ name = 'Hold controlled acceptance job'; status = 'in_progress' }) }
                if ($f.Latest -gt 1) {
                    switch ($f.Change) {
                        name { $j.runner_name = 'other-runner' }
                        id { $j.runner_id = 99 }
                        run { $j.run_id = 99 }
                        attempt { $j.run_attempt = 2 }
                        duplicate { return @{ jobs = @($j, $j) } }
                        ended { $j.steps[0].status = 'completed' }
                    }
                }
                return @{ jobs = @($j) }
            }
            throw "Unexpected read $url"
        }
        function Send-RunnerSetupGh {
            param($Arguments, $Body)
            if ($Arguments -like '*/cancel') { $f.Done = $true; $f.Cancels++ }
            else { $f.Correlation = $Body.inputs.correlation }
        }
        function Get-RunnerAcceptanceFacts { param($Clone) @{ registered = $true; agentName = 'runner-one'; agentId = $(if ($f.Change -eq 'local') { 99 } else { 11 }) } }
        function Get-RunnerAcceptanceStatus { param($Clone) @{ Job = 'running (worker pid 7)'; Maintenance = $null } }
        function Invoke-RunnerAcceptanceProcess { param($Script, $Parameters) $f.Processes++ }
        foreach ($change in 'name', 'id', 'ended', 'local', 'run', 'attempt', 'duplicate') {
            $f.Change = $change; $f.Latest = 0; $f.Done = $false
            $state = @{ version = 1; repository = 'example/private'; profile = ''; completed = @{}; activeRun = $null }
            Reject { Invoke-RunnerAcceptanceLifecycle -InstallRoot $root -Repository example/private -SourceClone $clones[0] -Clones $clones -Instances $instances -State $state -Mode Force } "Disruption refuses stale $change observation"
            Assert ($f.Processes -eq 0 -and -not (Get-RunnerAcceptanceState $root).activeRun) "Stale $change observation stops no runner and cleans only its own run"
        }
    }
    }
    if ($Scenario -in 'All', 'Options') {
    & {
        . $SetupPath
        $f = @{ Installs = 0 }
        function Confirm-RunnerSetupAuthentication { }
        function Confirm-RunnerSetupRepositories { }
        function Sync-RunnerSetupInstance { }
        function Get-RunnerSetupEvidence { throw 'End fixture after installer recorder' }
        function Install-RunnerSetupInstance { $f.Installs++ }
        $state = @{ version = 1; repository = 'example/private'; profile = ''; completed = @{}; activeRun = @{ id = 81; correlation = 'own'; clone = ''; stopAttempted = $false } }
        Save-RunnerAcceptanceState $root $state
        Reject { Invoke-WindowsRunnerHostSetup -InstallRoot $root -Count 2 -GitHubUrl https://github.com/example/private -SourceCommit ('a' * 40) } 'Removing verification target cannot bypass an active acceptance journal'
        Assert ($f.Installs -eq 0) 'Changed setup options cannot start a runner before recovery'
    }
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "PASS: $($checks.Count) acceptance safeguard assertions (GitHub and process operations mocked)."
