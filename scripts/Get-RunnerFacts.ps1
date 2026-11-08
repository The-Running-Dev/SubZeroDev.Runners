#Requires -Version 7.2
# Read-only facts about this clone as JSON, for tests\Invoke-WindowsHostAcceptance.ps1: registration, legacy-migration record,
# leftover legacy startup entries (Task Scheduler and the Run key, read only), the BuildAgent pins and workspace, and admission:
# the maintenance record (absent = maintenance cleared) and the custom labels GitHub currently lists for this clone's runner.
# Changes nothing. Run it from the instance's clone.
. "$PSScriptRoot\Common.ps1"
. "$PSScriptRoot\Registration.ps1"
. "$PSScriptRoot\Lifecycle.ps1"
. "$PSScriptRoot\LegacyCleanup.ps1"
. "$PSScriptRoot\BuildAgent.ps1"

$registration = Get-LocalRegistration $WindowsRunner
$migration = Get-LegacyMigration
$settings = Get-BuildAgentSettings $Config

$entries = @(
    @{ Name = $LegacyWindowsTaskName; Script = $Supervisor }
    @{ Name = $LegacyLogTrimTaskName; Script = (Join-Path $PSScriptRoot 'Trim-RunnerLogs.ps1') }
    if (-not $Config.windows.instanceId) { @{ Name = $LegacyLogonTaskName; Script = (Join-Path $PSScriptRoot 'Start-Runners.ps1') } }
)
$legacy = Get-LegacyEntryFacts -Entries $entries -RunScriptFolder $PSScriptRoot
$maintenance = Get-MaintenanceState
$github = Get-GitHubRunnerState $WindowsRunner

[ordered]@{
    instance = if ($Config.windows.instanceId) { "$($Config.windows.instanceId)" } else { 'default' }
    clone = $Root
    windowsRunner = $WindowsRunner
    registered = [bool]$registration
    agentId = if ($registration) { $registration.agentId } else { $null }
    agentName = if ($registration) { $registration.agentName } else { $null }
    gitHubUrl = if ($registration) { $registration.gitHubUrl } else { $null }
    credentials = [bool](Test-Path -LiteralPath (Join-Path $WindowsRunner '.credentials'))
    localConfig = $LocalConfig
    migration = if ($migration) { [ordered]@{ kind = $migration.kind; completedUtc = $migration.completedUtc; removed = @($migration.removed); kept = @($migration.kept) } } else { $null }
    legacyTasks = @($legacy.Tasks)
    legacyRunEntry = $legacy.RunEntry
    admission = [ordered]@{
        maintenance = if ($maintenance) { [ordered]@{ phase = $maintenance.phase; reason = $maintenance.reason; failure = $maintenance.failure } } else { $null }
        gitHubKnown = [bool]($github.Known -and $github.Present)
        customLabels = @($github.CustomLabels)
        detail = "$($github.Detail)"
    }
    buildAgent = [ordered]@{ enabled = [bool]$settings.Enabled; version = $settings.Version; imageDigest = $settings.ImageDigest; workspace = $settings.Workspace; outputDirectory = $settings.OutputDirectory; cacheDirectory = $settings.CacheDirectory }
} | ConvertTo-Json -Depth 6
