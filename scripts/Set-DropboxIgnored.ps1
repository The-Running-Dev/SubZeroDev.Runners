# Marks every path matched by dropbox-ignore.txt as ignored by Dropbox. Safe to rerun.
. "$PSScriptRoot\Common.ps1"
$patterns = Get-Content (Join-Path $Root 'dropbox-ignore.txt') | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') }
foreach ($pattern in $patterns) {
    foreach ($item in Get-Item -Path (Join-Path $Root $pattern) -Force -ErrorAction SilentlyContinue) {
        # The Linux runner's self-update leaves bin and externals as Linux symlinks; Windows cannot open a
        # stream on one, and the real bin.* and externals.* folders they point at match their own patterns.
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { continue }
        $current = Get-Content -LiteralPath $item.FullName -Stream com.dropbox.ignored -ErrorAction SilentlyContinue
        if ($current -ne '1') {
            # One path that cannot be marked must not stop the runners from starting.
            try {
                Set-Content -LiteralPath $item.FullName -Stream com.dropbox.ignored -Value 1 -ErrorAction Stop
                Write-Output "Ignored $($item.FullName.Substring($Root.Length + 1))"
            } catch {
                Write-Warning "Could not mark $($item.FullName.Substring($Root.Length + 1)) as ignored: $($_.Exception.Message)"
            }
        }
    }
}
