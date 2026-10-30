# Applies windows.startup from runners.json, or -Mode when given.
#   Disabled  no automatic start
#   Logon     start both runners when this user signs in (HKCU Run entry)
param([ValidateSet('Disabled', 'Logon')] [string] $Mode)
. "$PSScriptRoot\Common.ps1"
if (-not $Mode) { $Mode = $Config.windows.startup }
$run = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
switch ($Mode) {
    'Logon' { Set-ItemProperty -Path $run -Name $StartupValueName -Value (Get-HiddenPwshCommand 'Start-Runners.ps1') }
    'Disabled' { Remove-ItemProperty -Path $run -Name $StartupValueName -ErrorAction SilentlyContinue }
    default { throw "Unknown windows.startup '$Mode'. Use Disabled or Logon." }
}
Write-Output "Windows runner startup: $Mode"
