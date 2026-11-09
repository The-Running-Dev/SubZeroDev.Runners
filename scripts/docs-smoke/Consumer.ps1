#Requires -Version 7.2
# Functions only; dot-sourcing has no host or GitHub effects.
function Invoke-SmokeGh([string[]] $Arguments, $Body) {
    $PSNativeCommandUseErrorActionPreference=$false
    $output = if ($null -ne $Body) { ($Body | ConvertTo-Json -Depth 15 -Compress) | & gh @Arguments --input - 2>&1 } else { & gh @Arguments 2>&1 }
    if ($LASTEXITCODE -ne 0) {
        $message=($output | ForEach-Object { "$_" }) -join "`n"
        $failureException=[Exception]::new("GitHub CLI failed: $($Arguments -join ' '). $message")
        $failureException.Data['Rejected']=($message -match '\bHTTP 4(?!08)\d\d\b')
        throw $failureException
    }
    if ($output) { ($output -join "`n") | ConvertFrom-Json }
}
function Read-SmokeGitHub([string] $Endpoint, [switch] $Paginate) {
    $arguments = @('api', '--method', 'GET', $Endpoint)
    if ($Paginate) { $arguments += '--paginate', '--slurp' }
    Invoke-SmokeGh $arguments
}
function Write-SmokeGitHub([string] $Endpoint, $Body) { Invoke-SmokeGh @('api', '--method', 'POST', $Endpoint) $Body }
function Save-SmokeState([string] $Path, $State) {
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    $State | ConvertTo-Json -Depth 15 | Set-Content -LiteralPath $temporary -Encoding utf8
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Get-SmokeBlobSha([string] $Content) {
    $bytes = [Text.Encoding]::UTF8.GetBytes($Content)
    $header = [Text.Encoding]::UTF8.GetBytes("blob $($bytes.Length)`0")
    [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([byte[]]($header + $bytes))).ToLowerInvariant()
}
function Get-SmokeConsumerFiles([string] $Root) {
    $paths = [ordered]@{
        '.github/workflows/self-hosted-docs-smoke.yml' = 'tests/linux-runner-docs-smoke.yml'
        'scripts/docs-smoke/Before-Build.ps1' = 'scripts/docs-smoke/Before-Build.ps1'
        'scripts/docs-smoke/After-Build.ps1' = 'scripts/docs-smoke/After-Build.ps1'
        'scripts/docs-smoke/smoke.mjs' = 'scripts/docs-smoke/smoke.mjs'
        'tests/fixtures/self-hosted-docs/docs/index.md' = 'tests/fixtures/self-hosted-docs/docs/index.md'
        'tests/fixtures/self-hosted-docs/docs/second.md' = 'tests/fixtures/self-hosted-docs/docs/second.md'
    }
    foreach ($path in $paths.Keys) {
        $content = [IO.File]::ReadAllText((Join-Path $Root $paths[$path])).Replace("`r`n", "`n")
        [pscustomobject]@{ path=$path; mode='100644'; type='blob'; content=$content; sha=(Get-SmokeBlobSha $content) }
    }
}
function Get-SmokeSnapshot([string] $Repository, [string] $Ref) {
    $commit = Read-SmokeGitHub "repos/$Repository/commits/$([uri]::EscapeDataString($Ref))"
    if ($commit.sha -notmatch '^[0-9a-f]{40}$' -or $commit.commit.tree.sha -notmatch '^[0-9a-f]{40}$') { throw 'Could not resolve the exact consumer commit/tree.' }
    $tree = Read-SmokeGitHub "repos/$Repository/git/trees/$($commit.commit.tree.sha)?recursive=1"
    if ($tree.truncated -or $null -eq $tree.tree) { throw 'Consumer tree is truncated or unavailable; file conflicts cannot be ruled out.' }
    [pscustomobject]@{ sha=$commit.sha; treeSha=$commit.commit.tree.sha; files=@($tree.tree) }
}
function Compare-SmokeFiles($Expected, $Snapshot, [switch] $RequireAll) {
    $missing = @()
    foreach ($file in $Expected) {
        $remote = @($Snapshot.files | Where-Object path -ceq $file.path)
        if (-not $remote.Count) { $missing += $file; continue }
        if ($remote.Count -ne 1 -or $remote[0].type -cne 'blob' -or $remote[0].mode -cne '100644' -or $remote[0].sha -cne $file.sha) {
            throw "Consumer path differs: $($file.path). It will not be overwritten. Review the difference first."
        }
    }
    if ($RequireAll -and $missing.Count) { throw 'The reviewed smoke files are not installed on this ref. Run Prepare and merge its consumer PR first.' }
    $missing
}
function Prepare-SmokeConsumer([string] $Repository, [string] $DefaultBranch, $Files) {
    $snapshot = Get-SmokeSnapshot $Repository $DefaultBranch
    $missing = @(Compare-SmokeFiles $Files $snapshot)
    if (-not $missing.Count) { Write-Output "READY: exact smoke files already installed in $Repository on $DefaultBranch. Run -Action Run next."; return }
    $identity = ($Files | ForEach-Object { "$($_.path):$($_.sha)" }) -join "`n"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant().Substring(0, 12)
    $branch = "smoke/linux-docs-$hash"
    Write-Host "Preparing $Repository branch $branch from $($snapshot.sha); adding $($missing.Count) files. Existing files are retained; no merge or dispatch."
    $refs = @(Read-SmokeGitHub "repos/$Repository/git/matching-refs/heads/$branch" | Where-Object ref -ceq "refs/heads/$branch")
    if ($refs.Count -gt 1) { throw 'Ambiguous consumer branch.' }
    if (-not $refs.Count) {
        $elements = @($missing | ForEach-Object { @{path=$_.path;mode=$_.mode;type=$_.type;content=$_.content} })
        $tree = Write-SmokeGitHub "repos/$Repository/git/trees" @{base_tree=$snapshot.treeSha;tree=$elements}
        $commit = Write-SmokeGitHub "repos/$Repository/git/commits" @{message='Add manual self-hosted Linux documentation smoke';tree=$tree.sha;parents=@($snapshot.sha)}
        Write-SmokeGitHub "repos/$Repository/git/refs" @{ref="refs/heads/$branch";sha=$commit.sha} | Out-Null
    } else {
        Compare-SmokeFiles $Files (Get-SmokeSnapshot $Repository $refs[0].object.sha) -RequireAll | Out-Null
    }
    $owner = $Repository.Split('/')[0]
    $pulls = @(Read-SmokeGitHub "repos/$Repository/pulls?state=open&head=$([uri]::EscapeDataString("${owner}:$branch"))&per_page=100" | Where-Object { $_ })
    if ($pulls.Count -gt 1) { throw 'More than one consumer PR matches this branch.' }
    $pr = if ($pulls.Count) { $pulls[0] } else {
        Write-SmokeGitHub "repos/$Repository/pulls" @{
            title='Add manual self-hosted Linux documentation smoke';head=$branch;base=$DefaultBranch
            body="Adds six smoke runtime files from SubZeroDev.Runners. The workflow has only workflow_dispatch, calls pinned ActionTemplates docs.yml with the configured BuildAgent image and subzerodev-linux, disables deployment, and checks the transported site and exact runner identity. No workflow was dispatched by Prepare. Review and merge this PR before running Invoke-Smoke.ps1 -Action Run on the registered runner host. Existing hosted workflows are unchanged. Creating this branch/PR may run existing consumer CI."
        }
    }
    if (-not $pr.html_url) { throw 'Consumer PR creation was not confirmed.' }
    Write-Output "CONSUMER PR: $($pr.html_url)"
    Write-Output 'Review and merge that consumer PR, then run the same host command with -Action Run. Nothing is merged automatically.'
}
function Get-SmokeEligibility([string] $Root, [string] $Registration, [string] $Repository, [bool] $AllowUnavailable) {
    & (Join-Path $Root 'scripts/docs-smoke/Get-SmokeEligibility.ps1') -RunnerRegistration $Registration -Repository $Repository -AllowUnavailable:$AllowUnavailable | ConvertFrom-Json
}
function Invoke-SmokeHostProbe([string] $Root, [string] $ReportPath) {
    & (Join-Path $Root 'tests/Invoke-LinuxJobContainerProbe.ps1') -OutputPath $ReportPath | Out-Host
}
function Assert-SmokeRun($Run, $Expected) {
    if (($Expected.id -and $Run.id -ne $Expected.id) -or $Run.id -le 0 -or
        $Run.event -cne 'workflow_dispatch' -or $Run.path -cne '.github/workflows/self-hosted-docs-smoke.yml' -or
        $Run.display_title -cne "Self-hosted docs smoke $($Expected.correlation)" -or
        $Run.head_sha -cne $Expected.sha -or $Run.head_branch -cne $Expected.ref -or $Run.run_attempt -ne 1 -or
        $Run.status -notin 'queued','in_progress','completed','waiting','pending','requested') {
        throw 'Run identity/ref/commit/original attempt differs from this dispatch. Journal retained; no new run will be dispatched.'
    }
}
function Find-SmokeRun([string] $Repository, $Expected) {
    $pages = @(Read-SmokeGitHub "repos/$Repository/actions/workflows/self-hosted-docs-smoke.yml/runs?event=workflow_dispatch&per_page=100" -Paginate)
    $matches = @($pages.workflow_runs | Where-Object display_title -ceq "Self-hosted docs smoke $($Expected.correlation)")
    if ($matches.Count -gt 1) { throw 'Duplicate dispatch correlations; journal retained.' }
    if ($matches.Count -eq 1) { Assert-SmokeRun $matches[0] $Expected; $matches[0] }
}
function Download-SmokeArtifact([string] $Repository, [long] $RunId, [string] $Name, [string] $Directory) {
    & gh run download $RunId --repo $Repository --name $Name --dir $Directory
    if ($LASTEXITCODE -ne 0) { throw "Could not download $Name for run $RunId." }
}
function Confirm-SmokeDownload([string] $Repository, $Expected, [string] $Directory, [string] $Image) {
    New-Item -ItemType Directory -Path $Directory -Force | Out-Null
    Download-SmokeArtifact $Repository $Expected.id 'self-hosted-docs-result' (Join-Path $Directory 'result')
    Download-SmokeArtifact $Repository $Expected.id 'self-hosted-docs-site' (Join-Path $Directory 'archive')
    $result = Get-Content -Raw (Join-Path $Directory 'result/result.json') | ConvertFrom-Json
    $e = $result.buildEvidence
    if ($result.status -cne 'success' -or $result.selectedImage -cne $Image -or $e.repository -cne $Repository -or
        $e.sha -cne $Expected.sha -or "$($e.runId)" -cne "$($Expected.id)" -or "$($e.runAttempt)" -cne '1' -or
        $e.runner.name -cne $Expected.runnerName -or $e.runner.environment -cne 'self-hosted' -or $e.runner.os -cne 'Linux') { throw 'Downloaded result does not establish this run/commit/runner/image.' }
    $pages = @(Read-SmokeGitHub "repos/$Repository/actions/runs/$($Expected.id)/attempts/1/jobs?per_page=100" -Paginate)
    $build = @($pages.jobs | Where-Object name -ceq 'Docs smoke / Build')
    if ($build.Count -ne 1 -or $build[0].conclusion -cne 'success' -or $build[0].runner_id -ne $Expected.runnerId -or
        $build[0].runner_name -cne $Expected.runnerName -or $build[0].labels -notcontains 'subzerodev-linux') { throw 'GitHub job records do not confirm the selected runner.' }
    $archive = Join-Path $Directory 'archive/artifact.tar'
    if ((Get-Item -LiteralPath $archive).Length -le 0) { throw 'Site archive is empty.' }
    $site = Join-Path $Directory 'site'; New-Item -ItemType Directory -Path $site | Out-Null
    $entries = & tar -tf $archive
    if ($LASTEXITCODE -ne 0 -or @($entries | Where-Object { $_ -match '(^/|^[A-Za-z]:|(^|[\\/])\.\.([\\/]|$))' }).Count) { throw 'Site archive listing is invalid.' }
    & tar -xf $archive -C $site
    if ($LASTEXITCODE -ne 0) { throw 'Site archive extraction failed.' }
    $index = Get-Content -Raw (Join-Path $site 'index.html')
    $second = @(Get-ChildItem $site -Recurse -File -Filter '*.html' | Where-Object { (Get-Content -Raw $_.FullName).Contains('SubZeroDev second-page smoke marker.') })
    if (-not $index.Contains('SubZeroDev Linux runner documentation smoke fixture.') -or -not $second.Count -or -not (Test-Path (Join-Path $site 'assets') -PathType Container)) { throw 'Downloaded site is missing rendered fixture pages/assets.' }
    $manifest = Get-Content -Raw (Join-Path $site 'smoke-evidence.json') | ConvertFrom-Json
    if ("$($manifest.runId)" -cne "$($Expected.id)" -or $manifest.sha -cne $Expected.sha -or $manifest.runner.name -cne $Expected.runnerName -or $manifest.selectedImage -cne $Image) { throw 'Site and result artifacts disagree.' }
    [pscustomobject]@{ archiveSha256=(Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant();runnerId=$build[0].runner_id;runnerName=$build[0].runner_name;directory=$Directory }
}
function Invoke-DocsSmoke {
    param([string] $Root, [ValidateSet('Prepare','Run')][string] $Action, [string] $Repository, [string] $RunnerRegistration,
          [string] $Ref, [int] $TimeoutMinutes=45, [string] $StateDirectory)
    if (-not $RunnerRegistration) { $RunnerRegistration=Join-Path $Root 'linux/runner/.runner' }
    $eligible = Get-SmokeEligibility $Root $RunnerRegistration $Repository $true
    if (-not $eligible.registrationEligible) { throw 'An eligible registered Linux runner has not been established.' }
    $Repository=$eligible.repository
    Write-Host "Consumer: $Repository; runner: $($eligible.runnerName) (ID $($eligible.runnerId))."
    $metadata=Read-SmokeGitHub "repos/$Repository"
    if ($metadata.full_name -ine $Repository -or -not $metadata.default_branch) { throw 'Consumer repository/default branch could not be verified.' }
    $Repository=$metadata.full_name
    $files=@(Get-SmokeConsumerFiles $Root)
    if (-not $StateDirectory) {
        $key=[Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes("$Repository|$($eligible.runnerId)"))).Substring(0,16)
        $StateDirectory=Join-Path ([Environment]::GetFolderPath('LocalApplicationData')) "SubZeroDev/Runners/linux-docs-smoke/$key"
    }
    New-Item -ItemType Directory -Path $StateDirectory -Force | Out-Null
    $lock=$null
    try {
        try { $lock=[IO.File]::Open((Join-Path $StateDirectory 'controller.lock'),'OpenOrCreate','ReadWrite','None') } catch { throw 'Another Linux smoke controller is using this state directory.' }
        $statePath=Join-Path $StateDirectory 'state.json'
        $state=if(Test-Path $statePath){Get-Content -Raw $statePath | ConvertFrom-Json -AsHashtable}else{@{version=1;repository=$Repository;active=$null}}
        if ($state.version -ne 1 -or $state.repository -cne $Repository) { throw 'State file does not belong to this consumer.' }
        if ($Action -eq 'Prepare') {
            if ($state.active) { throw 'A previous dispatch needs -Action Run reconciliation before preparing another workflow.' }
            Prepare-SmokeConsumer $Repository $metadata.default_branch $files
            return
        }
        # Default-branch installation is required even when testing another ref.
        Compare-SmokeFiles $files (Get-SmokeSnapshot $Repository $metadata.default_branch) -RequireAll | Out-Null
        if (-not $Ref) { $Ref=$metadata.default_branch }
        $snapshot=Get-SmokeSnapshot $Repository $Ref
        Compare-SmokeFiles $files $snapshot -RequireAll | Out-Null
        if ($state.active) {
            if ($state.active.ref -cne $Ref -or $state.active.sha -cne $snapshot.sha -or $state.active.runnerId -ne $eligible.runnerId -or $state.active.runnerName -cne $eligible.runnerName -or $state.active.correlation -notmatch '^[0-9a-f]{32}$' -or $state.active.id -isnot [long] -and $state.active.id -isnot [int] -or $state.active.id -lt 0) { throw 'Pending dispatch belongs to another ref/commit/runner or has invalid state. Inspect the journal before continuing.' }
            Write-Host 'Resuming the saved dispatch; no new workflow will be dispatched.'
        } else {
            if (-not $eligible.availableNow) { throw 'Runner must be online and idle before a new dispatch. No run was dispatched.' }
            Invoke-SmokeHostProbe $Root (Join-Path $StateDirectory ('probe-'+[guid]::NewGuid().ToString('N')+'.json'))
            # Re-read the branch after the probe and refuse changes before dispatch.
            if ((Get-SmokeSnapshot $Repository $Ref).sha -cne $snapshot.sha) { throw 'Consumer ref changed during the probe. Nothing dispatched; review and retry.' }
            $state.active=@{id=0;correlation=[guid]::NewGuid().ToString('N');ref=$Ref;sha=$snapshot.sha;runnerId=$eligible.runnerId;runnerName=$eligible.runnerName}
            Save-SmokeState $statePath $state
            Write-Host "Dispatching $Repository/$Ref at $($snapshot.sha); journal: $statePath"
            try {
                Write-SmokeGitHub "repos/$Repository/actions/workflows/self-hosted-docs-smoke.yml/dispatches" @{ref=$Ref;inputs=@{correlation_id=$state.active.correlation;expected_runner_name=$eligible.runnerName;expected_runner_id="$($eligible.runnerId)"}} | Out-Null
            } catch {
                # An explicit non-timeout 4xx rejects the dispatch; transport/5xx
                # failures remain ambiguous and keep the intent for discovery.
                if ($_.Exception.Data['Rejected']) { $state.active=$null;Save-SmokeState $statePath $state }
                throw
            }
        }
        $deadline=[DateTime]::UtcNow.AddMinutes($TimeoutMinutes)
        $run=$null
        do {
            $run=if($state.active.id){Read-SmokeGitHub "repos/$Repository/actions/runs/$($state.active.id)"}else{Find-SmokeRun $Repository $state.active}
            if($run){
                Assert-SmokeRun $run $state.active
                if(-not $state.active.id){$state.active.id=$run.id;Save-SmokeState $statePath $state;Write-Host "Run: $($run.html_url)"}
                if($run.status -eq 'completed'){break}
            }
            Start-Sleep -Seconds 10
        }while([DateTime]::UtcNow -lt $deadline)
        if(-not $run -or $run.status -ne 'completed'){throw "Run not completed. Journal retained at $statePath; repeat -Action Run to resume. No run was cancelled."}
        $directory=Join-Path $StateDirectory ("runs/$($run.id)-"+[guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        $run | ConvertTo-Json -Depth 10 | Set-Content (Join-Path $directory 'run.json') -Encoding utf8
        $pins=Get-Content -Raw (Join-Path $Root 'runners.json') | ConvertFrom-Json
        if($run.conclusion -ne 'success'){
            try { Download-SmokeArtifact $Repository $run.id 'self-hosted-docs-result' (Join-Path $directory 'result') } catch { Write-Warning $_.Exception.Message }
            $state.last=@{id=$run.id;url=$run.html_url;status=$run.conclusion;directory=$directory};$state.active=$null;Save-SmokeState $statePath $state
            throw "Smoke run $($run.conclusion): $($run.html_url). Inspect its logs/artifacts before requesting another run."
        }
        $evidence=Confirm-SmokeDownload $Repository $state.active $directory $pins.buildAgent.image
        $state.last=@{id=$run.id;url=$run.html_url;status='success';evidence=$evidence};$state.active=$null;Save-SmokeState $statePath $state
        Write-Output "PASS: $($run.html_url)"
        Write-Output "Downloaded and independently verified site/result evidence: $directory"
    }finally{if($lock){$lock.Dispose()}}
}
