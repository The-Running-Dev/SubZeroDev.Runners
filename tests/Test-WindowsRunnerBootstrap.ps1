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

# Exercise the real native-process bridge under 5.1 before mocking package operations.
Invoke-SetupNative -File $env:ComSpec -Arguments @('/d', '/c', 'echo native-stderr-fixture 1>&2 & exit /b 0')
$rejected = $false
try { Invoke-SetupNative -File $env:ComSpec -Arguments @('/d', '/c', 'exit /b 5') } catch { $rejected = $true }
Assert $rejected 'Native failure was hidden by the process bridge.'
$handoffFixture = Join-Path ([IO.Path]::GetTempPath()) ('runner setup ' + [guid]::NewGuid().ToString('N'))
try {
    New-Item -ItemType Directory -Path $handoffFixture -Force | Out-Null
    $worker = Join-Path $handoffFixture 'worker fixture.ps1'
    $options = Join-Path $handoffFixture 'options fixture.json'
    'param([string] $OptionsPath) Get-Content -Raw -LiteralPath $OptionsPath' | Set-Content -LiteralPath $worker -Encoding UTF8
    @{ Count = 2; InstallRoot = "C:\A folder\Ben's runners"; ExtraLabels = @('first-label', 'second-label') } | ConvertTo-Json | Set-Content -LiteralPath $options -Encoding UTF8
    $result = Invoke-SetupNative -File "$env:ProgramFiles\PowerShell\7\pwsh.exe" -Arguments @('-NoLogo', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $worker, '-OptionsPath', $options) -Capture
    $result = $result | ConvertFrom-Json
    Assert ($result.Count -eq 2 -and $result.InstallRoot -eq "C:\A folder\Ben's runners" -and $result.ExtraLabels.Count -eq 2) 'PowerShell 5.1 to 7 handoff damaged options or paths with spaces.'
} finally { Remove-Item -LiteralPath $handoffFixture -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output 'PASS: actual Windows PowerShell 5.1 native exit handling and PowerShell 7 handoff with spaced paths (no installation or registration).'

# -Repository is refused before any prerequisite, Docker or registration work when verification cannot run.
$realPrerequisites = ${function:Install-SetupPrerequisites}
$prerequisitesReached = $false
function Install-SetupPrerequisites { $script:prerequisitesReached = $true; throw 'prerequisites reached' }
foreach ($case in @(
    @{ Count = 1; Skip = $false; Repository = 'owner/repo' },
    @{ Count = 2; Skip = $true; Repository = 'owner/repo' },
    @{ Count = 2; Skip = $false; Repository = 'not a repository' },
    @{ Count = 2; Skip = $false; Repository = 'owner/repo/extra' }
)) {
    $refused = $false
    try { Start-WindowsRunnerSetup -Count $case.Count -InstallRoot 'C:\NeverCreated' -GitHubUrl 'https://github.com/owner/repo' -SkipBuildAgent $case.Skip -Repository $case.Repository } catch { $refused = $_.Exception.Message -ne 'prerequisites reached' }
    Assert $refused "Verification repository was accepted for Count $($case.Count), SkipBuildAgent $($case.Skip), '$($case.Repository)'."
}
Assert (-not $prerequisitesReached -and -not (Test-Path -LiteralPath 'C:\NeverCreated')) 'A refused verification request started setup work or created the install root.'
Set-Item -Path Function:Install-SetupPrerequisites -Value $realPrerequisites

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
