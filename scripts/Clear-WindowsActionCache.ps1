$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$runner = [IO.Path]::GetFullPath((Join-Path $root (Get-Content -Raw (Join-Path $root 'runners.json') | ConvertFrom-Json).windows.directory))
# The work folder the runner was registered with (windows.workFolder): relative to the runner, or absolute.
$work = (Get-Content -Raw (Join-Path $runner '.runner') | ConvertFrom-Json).workFolder
$workPath = [IO.Path]::GetFullPath([IO.Path]::Combine($runner, "$work"))
if (-not $work -or $workPath -eq [IO.Path]::GetPathRoot($workPath)) {
    throw 'Unexpected action cache path.'
}
$cache = Join-Path $workPath '_actions'
# All action and post-action steps have finished before this completion hook runs.
# Retry temporary sharing violations before the next job prepares its action cache.
for ($attempt = 0; $attempt -lt 60; $attempt++) {
    try {
        if (Test-Path -LiteralPath $cache) {
            Remove-Item -LiteralPath $cache -Recurse -Force -ErrorAction Stop
        }
        Write-Output 'Action cache is ready for the next job.'
        exit 0
    }
    catch {
        if ($attempt -eq 59) { throw }
        Start-Sleep -Seconds 1
    }
}
