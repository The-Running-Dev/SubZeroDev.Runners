$ErrorActionPreference = 'Stop'
& node (Join-Path $PSScriptRoot 'smoke.mjs') after
if ($LASTEXITCODE -ne 0) { throw 'Documentation smoke output check failed.' }
