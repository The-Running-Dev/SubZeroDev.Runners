#Requires -Version 7.2
# A .GetNewClosure() block runs in a new dynamic module. When a script is started from an interactive session
# (./scripts/Manage-RunnerHost.ps1), that module cannot see the script's own functions, so a closure that calls one fails
# with "The term '...' is not recognized". A closure carries such a function as a variable (${function:Name}) instead.
$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$pwsh = (Get-Process -Id $PID).Path
$passed = 0
function Assert($Condition, [string] $Message) { if (-not $Condition) { throw $Message } }

$files = Get-ChildItem (Join-Path $repo 'scripts') -Recurse -Filter '*.ps1'
$asts = @{}
foreach ($file in $files) { $asts[$file.FullName] = [Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$null, [ref]$null) }
$defined = @($asts.Values | ForEach-Object { $_.FindAll({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] }, $true) } | ForEach-Object { $_.Name }) | Sort-Object -Unique

# 1. No closure in scripts/ calls a function the scripts define by its bare name.
$offenders = foreach ($entry in $asts.GetEnumerator()) {
    $closures = $entry.Value.FindAll({ param($n) $n -is [Management.Automation.Language.InvokeMemberExpressionAst] -and $n.Member.Value -eq 'GetNewClosure' }, $true)
    foreach ($closure in $closures) {
        $calls = $closure.Expression.FindAll({ param($n) $n -is [Management.Automation.Language.CommandAst] }, $true)
        foreach ($call in $calls) {
            $name = $call.GetCommandName()
            if ($name -and $name -in $defined) { "$([IO.Path]::GetRelativePath($repo, $entry.Key)):$($call.Extent.StartLineNumber) calls $name" }
        }
    }
}
Assert (-not $offenders) "Closures call script functions by name, which fails from an interactive session:`n$($offenders -join "`n")"
"PASS  No GetNewClosure block in scripts/ calls a script-defined function by name"
$passed++

# 2. Get-RunnerBusyCheck's block runs when its script is started from a session, as the owner starts Manage-RunnerHost.ps1.
$manage = $asts[(Join-Path $repo 'scripts/Manage-RunnerHost.ps1')]
$busyCheck = $manage.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-RunnerBusyCheck' }, $true)
Assert $busyCheck 'Manage-RunnerHost.ps1 has no Get-RunnerBusyCheck.'
$temp = Join-Path ([IO.Path]::GetTempPath()) ('closure-scope-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory $temp -Force | Out-Null
try {
    $probe = Join-Path $temp 'probe.ps1'
    @"
`$ErrorActionPreference = 'Stop'
function Invoke-Docker([string[]] `$Arguments) { [pscustomobject]@{ ExitCode = `$(if (`$Arguments[1] -eq 'busy') { 0 } else { 1 }); Output = '' } }
$($busyCheck.Extent.Text)
'busy=' + [bool](& (Get-RunnerBusyCheck 'busy'))
'idle=' + [bool](& (Get-RunnerBusyCheck 'idle'))
"@ | Set-Content -LiteralPath $probe
    $output = & $pwsh -NoProfile -NonInteractive -Command "& '$probe'" 2>&1 | ForEach-Object { "$_" }
    Assert ($LASTEXITCODE -eq 0 -and $output -contains 'busy=True' -and $output -contains 'idle=False') "Get-RunnerBusyCheck failed from a session: $($output -join ' ')"
}
finally { Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue }
"PASS  Get-RunnerBusyCheck reports busy and idle when its script is started from a session"
$passed++

""
"$passed of $passed passed."
