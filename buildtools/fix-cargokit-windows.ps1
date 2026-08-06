# Patches packages in the pub cache so Windows builds work:
#
# 1. cargokit's resolve_symlinks.ps1 (super_native_extensions): `Get-Item`
#    without `-Force` throws ObjectNotFound on hidden/system path segments
#    (e.g. C:\Users\<user>\AppData, the default pub cache location).
#    Fix: https://github.com/irondash/cargokit/pull/119 (open, unmerged as of
#    super_native_extensions 0.9.1).
# 2. tailscale's hook/build.dart: Flutter's native-assets hook runner executes
#    hooks with a stripped environment (no GOCACHE, no LocalAppData), so
#    `go build -buildmode=c-shared` fails with:
#      build cache is required, but could not be located:
#      GOCACHE is not defined and %LocalAppData% is not defined
#    We inject an explicit GOCACHE into the environment the hook passes to go.
#
# Remove this script once upstream ships both fixes.
#
# Idempotent: safe to run on every `flutter pub get` / build.
$ErrorActionPreference = 'Stop'

Write-Host "PUB_CACHE=$env:PUB_CACHE"
Write-Host "LOCALAPPDATA=$env:LOCALAPPDATA"

$pubCache = if ($env:PUB_CACHE) { $env:PUB_CACHE } else { Join-Path $env:LOCALAPPDATA 'Pub\Cache' }
$hostedDir = Join-Path $pubCache 'hosted\pub.dev'

$script:found = 0
$script:patched = 0

function Patch-CargokitScript([string]$script) {
    if (-not (Test-Path -LiteralPath $script)) { return }
    $script:found++
    $content = Get-Content -LiteralPath $script -Raw
    $target = '$item = Get-Item $realPath'
    $fixedLine = '$item = Get-Item $realPath -Force'
    if ($content.Contains($fixedLine)) {
        Write-Host "OK (already patched): $script"
    } elseif ($content.Contains($target)) {
        Set-Content -LiteralPath $script -Value $content.Replace($target, $fixedLine) -NoNewline -Encoding ASCII
        $script:patched++
        Write-Host "Patched: $script"
    } else {
        Write-Host "WARN (cargokit layout changed?): $script"
    }
    $line = Get-Content -LiteralPath $script | Where-Object { $_ -like '*Get-Item $realPath*' }
    Write-Host "  Get-Item line: $line"
}

function Patch-TailscaleHook([string]$script) {
    if (-not (Test-Path -LiteralPath $script)) { return }
    $script:found++
    $content = Get-Content -LiteralPath $script -Raw
    if ($content.Contains("env['GOCACHE']")) {
        Write-Host "OK (already patched): $script"
        return
    }
    $target = '      final result = await Process.run('
    $insert = "      env['GOCACHE'] = p.join(input.outputDirectory.toFilePath(), 'go-build');`n"
    if ($content.Contains($target)) {
        Set-Content -LiteralPath $script -Value $content.Replace($target, $insert + $target) -NoNewline -Encoding ASCII
        $script:patched++
        Write-Host "Patched: $script"
    } else {
        Write-Host "WARN (tailscale hook layout changed?): $script"
    }
    $line = Get-Content -LiteralPath $script | Where-Object { $_ -like '*GOCACHE*' }
    Write-Host "  GOCACHE line: $line"
}

# 1. cargokit resolve_symlinks.ps1 - the exact file cmake executes, via the
#    plugin symlink Flutter created during `flutter pub get` (junction or copy).
$ephemeral = Join-Path $PWD 'windows\flutter\ephemeral\.plugin_symlinks\super_native_extensions\cargokit\cmake\resolve_symlinks.ps1'
if (Test-Path -LiteralPath $ephemeral) {
    Patch-CargokitScript $ephemeral
}

# 2. cargokit copies in the pub cache (custom PUB_CACHE locations).
if (Test-Path -LiteralPath $hostedDir) {
    Get-ChildItem -LiteralPath $hostedDir -Directory |
        Where-Object { $_.Name -like 'super_native_extensions-*' } |
        ForEach-Object {
            Patch-CargokitScript (Join-Path $_.FullName 'cargokit\cmake\resolve_symlinks.ps1')
        }
}

# 3. tailscale native build hook (go build needs GOCACHE in the stripped
#    hooks-runner environment).
if (Test-Path -LiteralPath $hostedDir) {
    Get-ChildItem -LiteralPath $hostedDir -Directory |
        Where-Object { $_.Name -like 'tailscale-*' } |
        ForEach-Object {
            Patch-TailscaleHook (Join-Path $_.FullName 'hook\build.dart')
        }
}

Write-Host "scripts checked: $script:found, patched: $script:patched"
if ($script:found -eq 0) {
    Write-Error "Could not find any cargokit/tailscale scripts to patch. The Windows build will likely fail."
    exit 1
}
