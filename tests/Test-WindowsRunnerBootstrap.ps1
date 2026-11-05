#Requires -Version 5.1
# Runs under stock Windows PowerShell: all package/repair/network operations below are mocked.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$errors = $null
$tokens = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'Setup-WindowsRunners.ps1'), [ref]$tokens, [ref]$errors)
if ($errors.Count) { throw "Stock Windows PowerShell cannot parse bootstrap: $errors" }
$definitions = $ast.EndBlock.Statements | Where-Object { $_ -is [Management.Automation.Language.FunctionDefinitionAst] }
$bootstrapFunctions = [scriptblock]::Create(($definitions.Extent.Text -join "`n"))
. $bootstrapFunctions
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$state = @{ Tools = @{}; Installs = [Collections.Generic.List[string]]::new(); Repairs = 0; Fail = $false }
function Update-SetupPath { }
function Find-SetupTool([string] $Name) { $state.Tools[$Name] }
function Test-SetupWinGet([string] $Path) { [bool]$Path }
function Repair-SetupWinGet { $state.Repairs++; $state.Tools.winget = 'winget.exe' }
function Invoke-SetupNative {
    param([string] $File, [string[]] $Arguments, [switch] $Capture)
    Assert ($File -eq 'winget.exe') 'Bootstrap used an unexpected package installer.'
    Assert ($Arguments -contains '--silent' -and $Arguments -contains '--disable-interactivity') 'Package install would ask CLI questions.'
    Assert ($Arguments -contains '--accept-package-agreements' -and $Arguments -contains '--accept-source-agreements') 'Missing package agreement flags.'
    $package = $Arguments[[Array]::IndexOf($Arguments, '--id') + 1]
    $state.Installs.Add($package)
    if ($state.Fail) { throw 'Simulated package failure.' }
    $name = switch ($package) { 'Microsoft.PowerShell' { 'pwsh' }; 'Git.Git' { 'git' }; 'GitHub.cli' { 'gh' } }
    $state.Tools[$name] = "$name.exe"
}
$tools = Install-SetupPrerequisites
Assert ($state.Repairs -eq 1) 'Missing WinGet was not repaired exactly once.'
Assert (($state.Installs -join ',') -eq 'Microsoft.PowerShell,Git.Git,GitHub.cli') 'Missing prerequisites were not installed in order.'
Assert ($tools.pwsh -and $tools.git -and $tools.gh) 'Bootstrap did not resolve newly installed tools.'
$tools = Install-SetupPrerequisites
Assert ($state.Installs.Count -eq 3 -and $state.Repairs -eq 1) 'Rerun reinstalled working prerequisites.'
$state.Tools.Remove('git')
$state.Fail = $true
$rejected = $false
try { Install-SetupPrerequisites | Out-Null } catch { $rejected = $true }
Assert $rejected 'A failed package install was ignored.'
Write-Output 'PASS: Windows PowerShell 5.1 parses bootstrap; missing WinGet/tool installs, same-session resolution, idempotence and failure propagation (external operations mocked).'
