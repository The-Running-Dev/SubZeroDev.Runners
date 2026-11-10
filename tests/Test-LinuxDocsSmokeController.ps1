#Requires -Version 7.2
# GitHub, eligibility, Docker probe and artifact download boundaries are replaced.
# Real temp files, dispatch journals/locks and the downloaded-site checker are used.
$ErrorActionPreference='Stop'
$repo=Split-Path $PSScriptRoot -Parent
. (Join-Path $repo 'scripts/docs-smoke/Consumer.ps1')
$realConfirm=${function:Confirm-SmokeDownload}
function Assert($Condition,[string]$Message){if(-not $Condition){throw $Message}}
function Reject([scriptblock]$Action,[string]$Pattern){try{&$Action|Out-Null}catch{Assert ($_.Exception.Message -match $Pattern) "Unexpected error: $($_.Exception.Message)";return};throw "Expected rejection: $Pattern"}
$files=@(Get-SmokeConsumerFiles $repo)
Assert ((Get-SmokeBlobSha "hello`n") -eq 'ce013625030ba8dba906f756967f9e9ca394464a') 'Git blob hashing differs.'
Assert ($files.Count -eq 6) 'Consumer runtime manifest is not minimal.'
$temp=Join-Path ([IO.Path]::GetTempPath()) ('linux-controller-test-'+[guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $temp|Out-Null
$fixture=@{}
$tarApplication=(Get-Command tar -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
function tar {
    # Prove archive operands stay portable even on a Linux test machine.
    Assert (-not [IO.Path]::IsPathRooted($args[1]) -and $args[1] -notmatch '^[A-Za-z]:') 'tar archive operand must be relative for Windows GNU tar.'
    & $tarApplication @args
}
function Reset-Fixture {
    $fixture.Clear()
    $fixture.BaseFiles=@();$fixture.Branch=$false;$fixture.PR=$null;$fixture.Writes=@();$fixture.Run=$null
    $fixture.Ready=$true;$fixture.Probes=0;$fixture.Dispatches=0;$fixture.Downloads=0;$fixture.Snapshots=0
    $fixture.LostResponse=$false;$fixture.Rejected=$false;$fixture.NoDiscovery=$false;$fixture.Moved=$false;$fixture.BadRun=$false;$fixture.DownloadFail=$false
}
function Invoke-SmokeGh { throw 'Unexpected real GitHub boundary.' }
function Get-SmokeEligibility { [pscustomobject]@{registrationEligible=$true;availableNow=$fixture.Ready;repository='fixture/consumer';runnerId=7;runnerName='fixture-linux'} }
function Invoke-SmokeHostProbe {param($Root,$ReportPath)$fixture.Probes++;'{}'|Set-Content $ReportPath}
function Start-Sleep {param($Seconds)}
function Get-SmokeSnapshot {
    param($Repository,$Ref)
    $fixture.Snapshots++
    [pscustomobject]@{sha=$(if($fixture.Moved -and $fixture.Snapshots -ge 3){'b'*40}else{'a'*40});treeSha='d'*40;files=$(if($Ref -eq ('c'*40)){$files}else{$fixture.BaseFiles})}
}
function Read-SmokeGitHub {
    param($Endpoint,[switch]$Paginate)
    if($Endpoint -eq 'repos/fixture/consumer'){return @{full_name='fixture/consumer';default_branch='main'}}
    if($Endpoint -like '*/git/matching-refs/*'){if($fixture.Branch){return @{ref=$fixture.Branch;object=@{sha='c'*40}}};return}
    if($Endpoint -like '*/pulls?*'){return $fixture.PR}
    if($Endpoint -like '*/self-hosted-docs-smoke.yml/runs?*'){return @{workflow_runs=$(if($fixture.NoDiscovery){@()}else{@($fixture.Run)})}}
    if($Endpoint -eq 'repos/fixture/consumer/actions/runs/77'){return $fixture.Run}
    if($Endpoint -like '*/attempts/1/jobs?*'){return @{jobs=@(@{id=501;name='Docs smoke / Build';conclusion='success';runner_id=$fixture.JobRunnerId;runner_name='fixture-linux';labels=@('subzerodev-linux')})}}
    throw "Unexpected GET: $Endpoint"
}
function Write-SmokeGitHub {
    param($Endpoint,$Body)
    $fixture.Writes+=@{endpoint=$Endpoint;body=$Body}
    if($Endpoint.EndsWith('/git/trees')){Assert ($Body.tree.Count -eq 6) 'Prepare changed the wrong files.';return @{sha='d'*40}}
    if($Endpoint.EndsWith('/git/commits')){return @{sha='c'*40}}
    if($Endpoint.EndsWith('/git/refs')){$fixture.Branch=$Body.ref;return @{ref=$Body.ref}}
    if($Endpoint.EndsWith('/pulls')){$fixture.PR=@{html_url='https://github.com/fixture/consumer/pull/1'};return $fixture.PR}
    if($Endpoint.EndsWith('/dispatches')){
        $fixture.Dispatches++
        if($fixture.Rejected){$failureException=[Exception]::new('Synthetic HTTP 422 rejection.');$failureException.Data['Rejected']=$true;throw $failureException}
        $fixture.Run=@{id=77;event='workflow_dispatch';path='.github/workflows/self-hosted-docs-smoke.yml';display_title="Self-hosted docs smoke $($Body.inputs.correlation_id)";head_sha=$(if($fixture.BadRun){'b'*40}else{'a'*40});head_branch=$Body.ref;run_attempt=1;status='completed';conclusion='success';html_url='https://github.com/fixture/consumer/actions/runs/77'}
        if($fixture.LostResponse){throw 'Synthetic lost POST response.'};return
    }
    throw "Unexpected POST: $Endpoint"
}
function Confirm-SmokeDownload {
    param($Repository,$Expected,$Directory,$Image)
    $fixture.Downloads++
    if($fixture.DownloadFail){throw 'Synthetic artifact service failure.'}
    Assert ($Expected.id -eq 77 -and $Expected.runnerId -eq 7) 'Download selected the wrong dispatch.'
    @{directory=$Directory;runnerId=7;archiveSha256='fixture'}
}
function Invoke-Case([string]$Name,[string]$Action='Run',[int]$TimeoutMinutes=1){
    Invoke-DocsSmoke -Root $repo -Action $Action -StateDirectory (Join-Path $temp $Name) -TimeoutMinutes $TimeoutMinutes
}
function Read-Case([string]$Name){Get-Content -Raw (Join-Path $temp "$Name/state.json")|ConvertFrom-Json -AsHashtable}
try {
    Reset-Fixture
    Invoke-Case prepare Prepare|Out-Null
    Assert ($fixture.Writes.Count -eq 4 -and $fixture.Dispatches -eq 0 -and $fixture.Probes -eq 0) 'Prepare performed unexpected mutations.'
    Invoke-Case prepare Prepare|Out-Null
    Assert ($fixture.Writes.Count -eq 4) 'Repeated Prepare created duplicate branch/commit/PR.'
    $fixture.BaseFiles=$files
    Invoke-Case installed Prepare|Out-Null
    Assert ($fixture.Writes.Count -eq 4) 'Already installed workflow caused mutations.'
    $collision=$files[0].PSObject.Copy();$collision.sha='0'*40
    Reject {Compare-SmokeFiles $files @{files=@($collision)}} 'will not be overwritten'
    Write-Output 'PASS: minimal atomic consumer branch/PR, idempotent Prepare and conflict refusal.'

    Reset-Fixture
    Reject {Invoke-Case missing} 'not installed'
    Assert ($fixture.Dispatches -eq 0 -and $fixture.Probes -eq 0) 'Run started before default-branch installation.'
    $fixture.BaseFiles=$files
    Invoke-Case success|Out-Null
    Assert ($fixture.Dispatches -eq 1 -and $fixture.Probes -eq 1 -and $fixture.Downloads -eq 1) 'Successful Run did not execute all stages.'
    Assert ((Read-Case success).last.status -eq 'success' -and -not (Read-Case success).active) 'Success state is incomplete.'

    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.LostResponse=$true
    Reject {Invoke-Case interrupted} 'lost POST'
    Assert ((Read-Case interrupted).active.correlation) 'Ambiguous dispatch intent was erased.'
    $fixture.LostResponse=$false;$fixture.Ready=$false
    Invoke-Case interrupted|Out-Null
    Assert ($fixture.Dispatches -eq 1 -and $fixture.Probes -eq 1) 'Busy-run recovery redispatched or reprobed.'

    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.Ready=$false
    Reject {Invoke-Case busy} 'online and idle'
    Assert ($fixture.Dispatches -eq 0 -and $fixture.Probes -eq 0) 'A new run started on an unavailable runner.'
    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.Rejected=$true
    Reject {Invoke-Case refused} '422 rejection'
    Assert (-not (Read-Case refused).active) 'An explicitly refused dispatch left a false pending run.'

    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.NoDiscovery=$true
    Reject {Invoke-Case undiscovered Run 0} 'Journal retained'
    Reject {Invoke-Case undiscovered Run 0} 'Journal retained'
    Assert ($fixture.Dispatches -eq 1 -and (Read-Case undiscovered).active) 'Undiscovered run was redispatched or forgotten.'

    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.BadRun=$true
    Reject {Invoke-Case wrongrun} 'identity/ref/commit'
    Assert ((Read-Case wrongrun).active -and $fixture.Downloads -eq 0) 'Mismatched GitHub run was accepted.'

    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.Moved=$true
    Reject {Invoke-Case moved} 'ref changed'
    Assert ($fixture.Dispatches -eq 0) 'Moved source ref was dispatched.'

    $expectedRun=@{id=77;correlation='1'*32;sha='a'*40;ref='main'}
    $validRun=@{id=77;event='workflow_dispatch';path='.github/workflows/self-hosted-docs-smoke.yml';display_title=('Self-hosted docs smoke '+('1'*32));head_sha='a'*40;head_branch='main';run_attempt=1;status='completed'}
    Assert-SmokeRun $validRun $expectedRun
    foreach($change in @(@{id=78},@{run_attempt=2},@{head_branch='other'})){
        $bad=$validRun.Clone();foreach($key in $change.Keys){$bad[$key]=$change[$key]}
        Reject {Assert-SmokeRun $bad $expectedRun} 'identity/ref/commit'
    }

    Reset-Fixture;$fixture.BaseFiles=$files;$fixture.DownloadFail=$true
    Reject {Invoke-Case download} 'artifact service'
    Assert ((Read-Case download).active.id -eq 77) 'Download failure lost the known run.'
    $fixture.DownloadFail=$false;Invoke-Case download|Out-Null
    Assert ($fixture.Dispatches -eq 1) 'Download retry dispatched another workflow.'

    Reset-Fixture
    $lockDir=Join-Path $temp 'locked';New-Item -ItemType Directory -Path $lockDir|Out-Null
    $held=[IO.File]::Open((Join-Path $lockDir 'controller.lock'),'OpenOrCreate','ReadWrite','None')
    try{Reject {Invoke-Case locked Prepare} 'Another Linux smoke controller'}finally{$held.Dispose()}
    Assert ($fixture.Writes.Count -eq 0) 'Concurrent Prepare changed the consumer.'
    Write-Output 'PASS: installed-file gate, dispatch/probe/download, durable lost-response recovery, busy resume, no redispatch, ref/attempt ownership and controller lock.'

    # Exercise the real downloaded-evidence checker, not its controller fixture.
    $fixture.JobRunnerId=7;$fixture.BadSite=$false
    $expected=@{id=77;sha='a'*40;runnerId=7;runnerName='fixture-linux'}
    $image=(Get-Content -Raw (Join-Path $repo 'runners.json')|ConvertFrom-Json).buildAgent.image
    function Download-SmokeArtifact {
        param($Repository,$RunId,$Name,$Directory)
        New-Item -ItemType Directory -Path $Directory -Force|Out-Null
        $e=@{repository='fixture/consumer';runId='77';runAttempt='1';sha='a'*40;selectedImage=$image;runner=@{name='fixture-linux';environment='self-hosted';os='Linux'}}
        if($Name -eq 'self-hosted-docs-result'){@{status='success';selectedImage=$image;buildEvidence=$e}|ConvertTo-Json -Depth 8|Set-Content (Join-Path $Directory 'result.json');return}
        $source=Join-Path $Directory 'source';New-Item -ItemType Directory -Path (Join-Path $source 'assets') -Force|Out-Null
        $(if($fixture.BadSite){'wrong site'}else{'<html>SubZeroDev Linux runner documentation smoke fixture.</html>'})|Set-Content (Join-Path $source 'index.html')
        '<html>SubZeroDev second-page smoke marker.</html>'|Set-Content (Join-Path $source 'second.html')
        $e|ConvertTo-Json -Depth 8|Set-Content (Join-Path $source 'smoke-evidence.json')
        Push-Location $Directory
        try {
            & tar -cf 'artifact.tar' -C 'source' .
            if($LASTEXITCODE -ne 0){throw 'Fixture tar creation failed.'}
        } finally { Pop-Location }
    }
    &$realConfirm 'fixture/consumer' $expected (Join-Path $temp 'evidence-good') $image|Out-Null
    $fixture.BadSite=$true
    Reject {&$realConfirm 'fixture/consumer' $expected (Join-Path $temp 'evidence-bad-site') $image} 'rendered fixture'
    $fixture.BadSite=$false;$fixture.JobRunnerId=99
    Reject {&$realConfirm 'fixture/consumer' $expected (Join-Path $temp 'evidence-bad-runner') $image} 'job records'
    Write-Output 'PASS: downloaded archive content is checked independently; wrong site and wrong actual GitHub runner ID are rejected (downloads/API mocked).'
    $global:LASTEXITCODE=0
}finally{Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue}
