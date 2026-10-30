# Deletes runner, worker, step and console logs older than logs.retentionDays from both runners' _diag folders.
. "$PSScriptRoot\Common.ps1"
$cutoff = (Get-Date).AddDays(-[int]$Config.logs.retentionDays)
$removed = 0
foreach ($diag in (Join-Path $WindowsRunner '_diag'), (Join-Path $LinuxRunner '_diag')) {
    if (-not (Test-Path -LiteralPath $diag)) { continue }
    $files = Get-ChildItem -LiteralPath $diag -Recurse -File -Force
    # A listener that has run for weeks keeps writing its newest log, so never touch the newest of each kind.
    $newest = $files | Where-Object Name -match '^(Runner|Worker|Console|Startup)_' | Group-Object { $_.Name.Split('_')[0] } | ForEach-Object { ($_.Group | Sort-Object LastWriteTime)[-1].FullName }
    foreach ($file in $files | Where-Object { $_.LastWriteTime -lt $cutoff -and $_.FullName -notin $newest }) {
        try {
            Remove-Item -LiteralPath $file.FullName -Force
            $removed++
        }
        catch {
            # Still open; the next run gets it.
        }
    }
}
# Also keeps paths created since the last start (runner updates, new caches) out of Dropbox.
& (Join-Path $PSScriptRoot 'Set-DropboxIgnored.ps1') | Out-Null
Write-Output "Removed $removed log file(s) older than $($Config.logs.retentionDays) days."
