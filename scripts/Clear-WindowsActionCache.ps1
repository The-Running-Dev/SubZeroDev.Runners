$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
$runner = [IO.Path]::GetFullPath((Join-Path $root (Get-Content -Raw (Join-Path $root 'runners.json') | ConvertFrom-Json).windows.directory))
$cache = [IO.Path]::GetFullPath((Join-Path $runner '_work\_actions'))
if (-not $cache.StartsWith("$root\", [StringComparison]::OrdinalIgnoreCase) -or $cache -ne "$runner\_work\_actions") {
    throw 'Unexpected action cache path.'
}
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
