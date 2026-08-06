# Patches cargokit's resolve_symlinks.ps1 so Windows builds work when the
# path passes through hidden/system folders (e.g. C:\Users\<user>\AppData,
# the default pub cache location).
#
# Upstream bug: `Get-Item` without `-Force` throws ObjectNotFound on path
# segments carrying Hidden/System attributes, even though they exist, so
# super_native_extensions' cargokit cmake step fails with:
#   Get-Item : Could not find item C:\Users\runneradmin\AppData.
# Fix: https://github.com/irondash/cargokit/pull/119 (open, unmerged as of
# super_native_extensions 0.9.1). Remove this script once upstream ships it.
#
# Idempotent: safe to run on every `flutter pub get` / build.
$ErrorActionPreference = 'Stop'

$target = '$item = Get-Item $realPath'
$fixedLine = '$item = Get-Item $realPath -Force'

function Patch-Script([string]$script) {
    if (-not (Test-Path -LiteralPath $script)) { return 0 }
    $content = Get-Content -LiteralPath $script -Raw
    if ($content.Contains($target) -and -not $content.Contains($fixedLine)) {
        Set-Content -LiteralPath $script -Value $content.Replace($target, $fixedLine) -NoNewline -Encoding ASCII
        Write-Host "Patched: $script"
    } else {
        Write-Host "OK (no change needed): $script"
    }
    $line = Get-Content -LiteralPath $script | Where-Object { $_ -like '*Get-Item $realPath*' }
    Write-Host "  Get-Item line: $line"
    return 1
}

$total = 0
$patched = 0

# 1. The exact file cmake executes, via the plugin symlink Flutter created
#    during `flutter pub get` (covers both junction and copy layouts).
$ephemeral = Join-Path $PWD 'windows\flutter\ephemeral\.plugin_symlinks\super_native_extensions\cargokit\cmake\resolve_symlinks.ps1'
if (Test-Path -LiteralPath $ephemeral) {
    $total += 1
    $patched += Patch-Script $ephemeral
}

# 2. Any copies in the pub cache (custom PUB_CACHE locations).
$pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
$hostedDir = Join-Path $pubCache 'hosted\pub.dev'
if (Test-Path -LiteralPath $hostedDir) {
    Get-ChildItem -LiteralPath $hostedDir -Directory |
        Where-Object { $_.Name -like 'super_native_extensions-*' } |
        ForEach-Object {
            $script = Join-Path $_.FullName 'cargokit\cmake\resolve_symlinks.ps1'
            if (Test-Path -LiteralPath $script) {
                $total += 1
                $patched += Patch-Script $script
            }
        }
}

Write-Host "cargokit scripts checked: $total, patched: $patched"
if ($total -eq 0) {
    Write-Error "Could not find any cargokit resolve_symlinks.ps1 to patch. The Windows build will likely fail with the hidden-AppData error."
    exit 1
}
