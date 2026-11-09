#Requires -Version 7.2
# Runs the opt-in probe against an external fake Docker executable. No daemon is used.
$ErrorActionPreference = 'Stop'
if ($IsWindows) { Write-Output 'External fake-Docker probe checks require Linux; use the opt-in real Docker probe on Windows.'; return }
$repo = Split-Path $PSScriptRoot -Parent
$temp = Join-Path ([IO.Path]::GetTempPath()) ('probe-fixture-' + [guid]::NewGuid().ToString('N'))
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
New-Item -ItemType Directory -Path $temp | Out-Null
$oldState = $env:SZR_PROBE_TEST_STATE; $oldFail = $env:SZR_PROBE_TEST_FAIL
$oldPwsh = $env:SZR_PROBE_TEST_PWSH; $oldFake = $env:SZR_PROBE_TEST_SCRIPT
try {
    $fake = Join-Path $temp 'fake-docker.ps1'
    @'
$arguments = @($args)
Add-Content $env:SZR_PROBE_TEST_STATE (ConvertTo-Json -InputObject $arguments -Compress)
if ($arguments[0] -eq 'inspect') { 'true'; exit 0 }
if ($arguments -contains 'readlink') { '/runner/externals.2.338.0'; exit 0 }
if ($arguments -contains '/runner-hooks/Sync-LinuxRunnerRuntimes.sh' -and $env:SZR_PROBE_TEST_FAIL -eq 'hook') {
    [Console]::Error.WriteLine('projection refused'); exit 1
}
if ($arguments -contains 'run') {
    if ($env:SZR_PROBE_TEST_FAIL -eq '1') { [Console]::Error.WriteLine('missing /__e/node24/bin/node'); exit 127 }
    'v24.9.0'; exit 0
}
if ($arguments -contains 'inspect') { '/fixture-leftover'; exit 0 }
exit 0
'@ | Set-Content $fake
    # Forward exact arguments through a real executable, without shell interpolation.
    $env:SZR_PROBE_TEST_PWSH = (Get-Process -Id $PID).Path
    $env:SZR_PROBE_TEST_SCRIPT = $fake
    $wrapper = Join-Path $temp 'docker'
    @'
#!/bin/sh
exec "$SZR_PROBE_TEST_PWSH" -NoProfile -File "$SZR_PROBE_TEST_SCRIPT" "$@"
'@ | Set-Content $wrapper
    & chmod +x $wrapper
    if ($LASTEXITCODE -ne 0) { throw 'Could not make fixture Docker executable.' }
    foreach ($fails in '0', '1', 'hook') {
        $env:SZR_PROBE_TEST_STATE = Join-Path $temp "calls-$fails.jsonl"
        $env:SZR_PROBE_TEST_FAIL = $fails
        $resultPath = Join-Path $temp "result-$fails.json"
        $failure = $null
        try { & (Join-Path $repo 'tests/Invoke-LinuxJobContainerProbe.ps1') -DockerCommand $wrapper -OutputPath $resultPath } catch { $failure = $_.Exception.Message }
        $result = Get-Content -Raw $resultPath | ConvertFrom-Json
        Assert (($result.status -eq 'success') -eq ($fails -eq '0')) 'Probe reported the wrong execution result.'
        Assert (($null -ne $failure) -eq ($fails -ne '0')) 'Runtime/projection failure did not propagate.'
        $calls = @(Get-Content $env:SZR_PROBE_TEST_STATE | ForEach-Object { [pscustomobject]@{Arguments=@($_ | ConvertFrom-Json)} })
        $nested = @($calls | Where-Object { $_.Arguments -contains 'run' })
        if ($fails -eq 'hook') {
            Assert ($nested.Count -eq 0) 'Probe created a nested container after projection failure.'
            Assert (-not $result.sidecarRegistrationPathsAbsent) 'Probe claimed isolation after projection failure.'
            continue
        }
        Assert ($nested.Count -eq 1) 'Probe did not create exactly one nested test container.'
        Assert ($nested[0].Arguments -contains 'type=bind,source=/runner/externals,target=/__e,readonly') 'Probe did not exercise the actual runner runtime bind.'
        Assert ($nested[0].Arguments -contains 'type=bind,source=/runner,target=/__runner,readonly') 'Probe did not check the sidecar runner parent for registration exposure.'
        Assert (@($calls | Where-Object { $_.Arguments -contains '/runner-hooks/Sync-LinuxRunnerRuntimes.sh' }).Count -eq 1) 'Probe did not refresh the runtime projection.'
        Assert ($nested[0].Arguments[-1] -match 'find /__runner.*credentials') 'Probe did not test sensitive path absence.'
        if ($fails -eq '0') { Assert $result.sidecarRegistrationPathsAbsent 'Probe omitted isolation evidence.' }
        Assert (@($nested[0].Arguments | Where-Object { $_ -match 'runner-layout/externals,target=/__fixture' }).Count -eq 1) 'Versioned symlink bind was not exercised.'
        Assert (@($calls | Where-Object { $_.Arguments -contains 'rm' -and $_.Arguments -contains '-f' -and $_.Arguments -contains $result.container }).Count -eq 1) 'Known test container was not cleaned up.'
        Assert (@($calls | Where-Object { $_.Arguments -contains 'prune' -or $_.Arguments -contains 'stop' -or $_.Arguments -contains 'restart' }).Count -eq 0) 'Probe touched unrelated Docker lifecycle.'
    }
    Write-Output 'PASS: nested bind and self-update probe commands, failure propagation, unique-object cleanup (external Docker mocked).'
} finally {
    $env:SZR_PROBE_TEST_STATE=$oldState; $env:SZR_PROBE_TEST_FAIL=$oldFail
    $env:SZR_PROBE_TEST_PWSH=$oldPwsh; $env:SZR_PROBE_TEST_SCRIPT=$oldFake
    Remove-Item $temp -Recurse -Force -ErrorAction SilentlyContinue
}
