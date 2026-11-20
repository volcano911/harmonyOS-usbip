# Build script for the HarmonyOS USB/IP app (produces an unsigned HAP).
# NOTE: keep this file ASCII-only. Windows PowerShell 5.1 decodes .ps1 files
# without a BOM using the ANSI code page, so non-ASCII comments can corrupt
# parsing and silently leave variables unassigned.
#
# Usage: powershell -NoProfile -ExecutionPolicy Bypass -File <this file>
# Env:   BUILD_MODE=debug|release   DEPS_ROOT=<third-party source root>

$ErrorActionPreference = 'Continue'

$Root    = 'D:\hm-tmp'
$Tools   = Join-Path $Root 'command-line-tools'
$Project = Join-Path $Root 'src\usbip-hm'
$Mode    = 'debug'
if ($env:BUILD_MODE) { $Mode = $env:BUILD_MODE }
if (-not $env:DEPS_ROOT) { $env:DEPS_ROOT = 'D:/hm-tmp/dl' }

Write-Host "==> tools   : $Tools"
Write-Host "==> project : $Project"
Write-Host "==> deps    : $env:DEPS_ROOT"
Write-Host "==> mode    : $Mode"
Write-Host ""

if (-not (Test-Path $Tools)) { Write-Host "[FAIL] tools not found"; exit 1 }

# Keep hvigor / ohpm caches on D: instead of the C: user profile.
$HomeDir = Join-Path $Root 'home'
New-Item -ItemType Directory -Force -Path $HomeDir | Out-Null
$env:HOME = $HomeDir
$env:USERPROFILE = $HomeDir
if (Test-Path Env:\DEVECO_NODE_HOME) { Remove-Item Env:\DEVECO_NODE_HOME -ErrorAction SilentlyContinue }
if (Test-Path Env:\DEVECO_SDK_HOME) { Remove-Item Env:\DEVECO_SDK_HOME -ErrorAction SilentlyContinue }
$env:npm_config_registry = 'https://registry.npmmirror.com'

# app_packing_tool.jar needs a JVM and is spawned by name, so java must be on PATH.
$JavaHome = 'D:\android-build\jdk17'
$JavaExe = Join-Path $JavaHome 'bin\java.exe'
if (Test-Path $JavaExe) {
    $env:JAVA_HOME = $JavaHome
    $env:PATH = "$JavaHome\bin;$env:PATH"
    $env:_JAVA_OPTIONS = '-Xms32m -Xmx512m'
    Write-Host "==> java    : $JavaHome"
} else {
    Write-Host "[WARN] no java at $JavaExe"
}

$Hvigor = Join-Path $Tools 'bin\hvigorw.bat'

# Bump versionCode/versionName on every build.
# Reason: installing a HAP whose versionCode is not newer than the installed
# one can be rejected (or silently keep the old APK-like payload on device),
# which makes us debug code that is not even running. The UI prints
# "v<versionName> (code <versionCode>)" at startup, so a mismatch is visible.
$AppJson = Join-Path $Project 'AppScope\app.json5'
if (Test-Path $AppJson) {
    $stamp = Get-Date
    $vcode = 1000000 + [int]$stamp.ToString('MMddHHmm')
    $vname = '1.0.' + $stamp.ToString('MMdd.HHmm')
    $text = [System.IO.File]::ReadAllText($AppJson)
    $text = [regex]::Replace($text, '"versionCode"\s*:\s*\d+', ('"versionCode": ' + $vcode))
    $text = [regex]::Replace($text, '"versionName"\s*:\s*"[^"]*"', ('"versionName": "' + $vname + '"'))
    [System.IO.File]::WriteAllText($AppJson, $text, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host "==> version : $vname (code $vcode)"
}

$HvArgs = @(
    'assembleHap',
    '--mode', 'module',
    '-p', 'product=default',
    '-p', 'module=entry@default',
    '-p', "buildMode=$Mode",
    '--no-daemon', '--no-parallel', '--no-incremental'
)

Push-Location $Project
Write-Host "==> building ..."
& $Hvigor @HvArgs
$rc = $LASTEXITCODE
Pop-Location

Write-Host ""
Write-Host "==> hvigor exit code: $rc"

$Hap = Join-Path $Project 'entry\build\default\outputs\default\entry-default-unsigned.hap'
if (-not (Test-Path $Hap)) {
    Write-Host "[FAIL] no output hap at: $Hap"
    $OutDir = Join-Path $Project 'entry\build\default\outputs'
    if (Test-Path $OutDir) {
        Write-Host "--- actual outputs:"
        Get-ChildItem $OutDir -Recurse -File | Select-Object -First 30 -ExpandProperty FullName | Write-Host
    }
    exit 1
}

$DistDir = Join-Path $Root 'out'
New-Item -ItemType Directory -Force -Path $DistDir | Out-Null
$Out = Join-Path $DistDir "usbip-1.0.0-api23-arm64-$Mode-unsigned.hap"
Copy-Item $Hap $Out -Force

$SizeMB = [math]::Round((Get-Item $Out).Length / 1MB, 2)
Write-Host ""
Write-Host "==> DONE"
Write-Host "    hap  : $Out"
Write-Host "    size : $SizeMB MB"

try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [System.IO.Compression.ZipFile]::OpenRead($Out)
    $names = $zip.Entries | ForEach-Object { $_.FullName }
    $zip.Dispose()
    $target = 'libs/arm64-v8a/libusbip_napi.so'
    if ($names -contains $target) {
        Write-Host "    so   : OK ($target)"
    } else {
        Write-Host "    so   : MISSING ($target)"
    }
    Write-Host "    entries: $($names.Count)"
} catch {
    Write-Host "    (zip check skipped)"
}
