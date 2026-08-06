# Patches cargokit's resolve_symlinks.ps1 inside the pub cache so Windows
# builds work when the path passes through hidden/system folders (e.g.
# C:\Users\<user>\AppData, which is where the default pub cache lives).
#
# Upstream bug: `Get-Item` without `-Force` throws ObjectNotFound on path
# segments that carry Hidden/System attributes, even though they exist, so
# super_native_extensions' cargokit cmake step fails with:
#   Get-Item : Could not find item C:\Users\runneradmin\AppData.
# Fix: https://github.com/irondash/cargokit/pull/119 (open, unmerged as of
# super_native_extensions 0.9.1). Remove this script once upstream ships it.
#
# Idempotent: safe to run on every `flutter pub get` / build.
$ErrorActionPreference = 'Stop'

$pubCache = if ($env:PUB_CACHE) {
    $env:PUB_CACHE
} else {
    Join-Path $env:LOCALAPPDATA 'Pub\Cache'
}

$pluginDirs = @()
$hostedDir = Join-Path $pubCache 'hosted\pub.dev'
if (Test-Path $hostedDir) {
    $pluginDirs = Get-ChildItem -LiteralPath $hostedDir -Directory |
        Where-Object { $_.Name -like 'super_native_extensions-*' }
}

$found = 0
$patched = 0
foreach ($dir in $pluginDirs) {
    $script = Join-Path $dir.FullName 'cargokit\cmake\resolve_symlinks.ps1'
    if (-not (Test-Path -LiteralPath $script)) {
        continue
    }
    $found++
    $content = Get-Content -LiteralPath $script -Raw
    # Matches the upstream fix: Get-Item must see hidden/system segments.
    # Guard on the already-fixed line: the replacement contains the search
    # string, so a naive Replace would append "-Force" on every run.
    $target = '$item = Get-Item $realPath'
    $fixedLine = '$item = Get-Item $realPath -Force'
    if ($content.Contains($target) -and -not $content.Contains($fixedLine)) {
        Set-Content -LiteralPath $script -Value $content.Replace($target, $fixedLine) -NoNewline -Encoding ASCII
        $patched++
    }
}

if ($found -eq 0) {
    Write-Warning "No super_native_extensions cargokit scripts found under '$pubCache'. If the Windows build fails with 'Could not find item', re-check the cargokit layout."
} else {
    Write-Host "Checked $found cargokit resolve_symlinks.ps1 (patched $patched)."
}
