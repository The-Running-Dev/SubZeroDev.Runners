#Requires -Version 7.2
# Every Windows slot's jobs inherit the supervisor's environment. Caches and temp folders set there must live under the slot's
# own folder ($WindowsRunner): a folder shared with other slots or the owner's builds (the user's %TMP%, where Uno keeps
# emscripten's cache) gets erased mid-build by whichever build stamped it with another toolchain.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$passed = 0
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$script = Join-Path $repo 'scripts/Run-WindowsRunner.ps1'
$ast = [Management.Automation.Language.Parser]::ParseFile($script, [ref]$null, [ref]$null)
$assignments = @{}
foreach ($node in $ast.FindAll({ param($n) $n -is [Management.Automation.Language.AssignmentStatementAst] -and $n.Left.Extent.Text -like '$env:*' }, $true)) {
    $assignments[$node.Left.Extent.Text.Substring(5)] = $node.Right.Extent.Text
}

foreach ($name in 'DOTNET_CLI_HOME', 'NUGET_PACKAGES', 'TMP') {
    Assert ($assignments[$name] -match '^Join-Path \$WindowsRunner ') "Run-WindowsRunner.ps1 does not put $name under the slot's folder: $($assignments[$name])"
    "PASS  $name lives under the slot's folder"
    $passed++
}
Assert ($assignments['TEMP'] -eq '$env:TMP') "Run-WindowsRunner.ps1 does not point TEMP at the slot's TMP: $($assignments['TEMP'])"
"PASS  TEMP follows the slot's TMP"
$passed++

$ignored = Get-Content (Join-Path $repo 'dropbox-ignore.txt')
Assert ($ignored -contains 'windows/_temp') 'dropbox-ignore.txt does not keep windows/_temp out of Dropbox.'
"PASS  The slot's temp folder stays out of Dropbox"
$passed++

""
"$passed of $passed passed."
