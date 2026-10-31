# Applies windows.startup from runners.json, or -Mode when given.
#   Disabled  no automatic start
#   Logon     start both runners when this user signs in (scheduled task \SubZeroDev.Runners\Start runners)
param([ValidateSet('Disabled', 'Logon')] [string] $Mode)
. "$PSScriptRoot\Common.ps1"
if (-not $Mode) { $Mode = $Config.windows.startup }
$name = 'Start runners'
# Earlier versions used an HKCU Run entry, which Windows can skip at sign-in; always remove it.
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name $StartupValueName -ErrorAction SilentlyContinue
switch ($Mode) {
    'Logon' {
        $user = "$env:USERDOMAIN\$env:USERNAME"
        $action = New-ScheduledTaskAction -Execute $Pwsh -Argument "-NoLogo -NoProfile -NonInteractive -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$(Join-Path $PSScriptRoot 'Start-Runners.ps1')`"" -WorkingDirectory $WindowsRunner
        $trigger = New-ScheduledTaskTrigger -AtLogOn -User $user
        $trigger.Delay = 'PT30S'
        $principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
        # Start-Runners waits up to 10 minutes for Docker and exits 1 on failure; retry a failed run.
        $settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -ExecutionTimeLimit (New-TimeSpan -Minutes 20) -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 5)
        Register-ScheduledTask -TaskPath $TaskPath -TaskName $name -Action $action -Trigger $trigger -Principal $principal -Settings $settings -Description 'Starts the SubZeroDev Windows and Linux runners at sign-in.' -Force | Out-Null
    }
    'Disabled' { Unregister-ScheduledTask -TaskPath $TaskPath -TaskName $name -Confirm:$false -ErrorAction SilentlyContinue }
    default { throw "Unknown windows.startup '$Mode'. Use Disabled or Logon." }
}
Write-Output "Windows runner startup: $Mode"
