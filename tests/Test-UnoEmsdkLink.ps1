#Requires -Version 7.2
# Uno links $(USERPROFILE)\.uno\emsdk\<version> to the Emscripten pack of whichever .NET built first, shared by every slot. A
# link whose target is gone breaks every slot's wasm build, so the job-started hook removes dangling links and nothing else.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$passed = 0
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }
. (Join-Path $repo 'scripts/Housekeeping.ps1')

$work = Join-Path ([IO.Path]::GetTempPath()) "szr-uno-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
try {
    $profileDir = Join-Path $work 'profile'
    $emsdk = Join-Path $profileDir '.uno\emsdk'
    $live = Join-Path $work 'packs\live\tools'
    $gone = Join-Path $work 'packs\gone\tools'
    New-Item -ItemType Directory -Force $emsdk, $live, $gone | Out-Null
    Set-Content (Join-Path $live 'emcc.bat') 'live'
    Set-Content (Join-Path $gone 'emcc.bat') 'gone'
    New-Item -ItemType Junction -Path (Join-Path $emsdk '10.0.14') -Target $live | Out-Null
    New-Item -ItemType Junction -Path (Join-Path $emsdk '10.0.13') -Target $gone | Out-Null
    New-Item -ItemType Directory (Join-Path $emsdk 'plain') | Out-Null
    Set-Content (Join-Path $emsdk 'plain\keep.txt') 'keep'
    Remove-Item -LiteralPath (Join-Path $work 'packs\gone') -Recurse -Force

    $output = @(Repair-UnoEmsdkLink $profileDir)
    Assert (-not (Test-Path -LiteralPath (Join-Path $emsdk '10.0.13'))) 'The dangling link is still there.'
    Assert ($output.Count -eq 1 -and $output[0] -like '*10.0.13*') "Unexpected report: $($output -join ' | ')"
    "PASS  A link whose target is gone is removed and reported"
    $passed++

    Assert ((Get-Item -LiteralPath (Join-Path $emsdk '10.0.14')).LinkType -eq 'Junction') 'The live link was removed.'
    Assert (Test-Path -LiteralPath (Join-Path $live 'emcc.bat')) "The live link's target lost its files."
    "PASS  A live link and its target stay"
    $passed++

    Assert (Test-Path -LiteralPath (Join-Path $emsdk 'plain\keep.txt')) 'A plain folder was touched.'
    "PASS  A folder that is not a link stays"
    $passed++

    Assert (@(Repair-UnoEmsdkLink (Join-Path $work 'no-profile')).Count -eq 0) 'A profile without .uno reported something.'
    "PASS  A profile without an Uno emsdk folder is left alone"
    $passed++
}
finally { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }

$script = Join-Path $repo 'scripts/Run-WindowsRunner.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$hook = $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -eq '$env:ACTIONS_RUNNER_HOOK_JOB_STARTED' }, $true)
Assert (@($hook).Count -eq 1 -and $hook[0].Right.Extent.Text -eq "Join-Path `$PSScriptRoot 'Repair-UnoEmsdkLink.ps1'") 'Run-WindowsRunner.ps1 does not run Repair-UnoEmsdkLink.ps1 when a job starts.'
"PASS  The supervisor runs the repair when a job starts"
$passed++

""
"$passed of $passed passed."
