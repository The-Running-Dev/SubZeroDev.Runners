# Marks every path matched by dropbox-ignore.txt as ignored by Dropbox. Safe to rerun.
. "$PSScriptRoot\Common.ps1"
$patterns = Get-Content (Join-Path $Root 'dropbox-ignore.txt') | ForEach-Object Trim | Where-Object { $_ -and -not $_.StartsWith('#') }
foreach ($pattern in $patterns) {
    foreach ($item in Get-Item -Path (Join-Path $Root $pattern) -Force -ErrorAction SilentlyContinue) {
        $current = Get-Content -LiteralPath $item.FullName -Stream com.dropbox.ignored -ErrorAction SilentlyContinue
        if ($current -ne '1') {
            Set-Content -LiteralPath $item.FullName -Stream com.dropbox.ignored -Value 1
            Write-Output "Ignored $($item.FullName.Substring($Root.Length + 1))"
        }
    }
}
