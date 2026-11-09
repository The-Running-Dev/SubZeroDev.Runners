$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'smoke.mjs') before
if ($LASTEXITCODE -ne 0) { throw 'Documentation smoke preflight failed.' }
