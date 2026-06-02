# Pyre — Build a signed release.
#
# Usage:
#   powershell -ExecutionPolicy Bypass -File scripts\build-release.ps1
#       → produces both APK and Android App Bundle (.aab)
#
#   ...build-release.ps1 -ApkOnly       → just APK (faster, sideload)
#   ...build-release.ps1 -BundleOnly    → just AAB (Play Store upload)
#   ...build-release.ps1 -SkipClean     → skip `flutter clean` (faster iteration)

param(
    [switch]$ApkOnly,
    [switch]$BundleOnly,
    [switch]$SkipClean
)

$ErrorActionPreference = 'Stop'
$repoRoot = Split-Path -Parent $PSScriptRoot
Set-Location $repoRoot

# Find flutter
$flutterCmd = (Get-Command flutter -ErrorAction SilentlyContinue).Source
if (-not $flutterCmd) {
    $candidates = @(
        "$env:USERPROFILE\flutter\bin\flutter.bat",
        'C:\flutter\bin\flutter.bat',
        'C:\src\flutter\bin\flutter.bat'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $flutterCmd = $c; break }
    }
}
if (-not $flutterCmd) {
    Write-Host 'ERROR: flutter not found on PATH and not at common install locations.' -ForegroundColor Red
    exit 1
}
Write-Host "Using flutter at: $flutterCmd" -ForegroundColor DarkGray

# Warn if no release keystore configured
$keyProps = Join-Path $repoRoot 'android\key.properties'
if (-not (Test-Path $keyProps)) {
    Write-Host ''
    Write-Host 'WARNING: android\key.properties not found.' -ForegroundColor Yellow
    Write-Host '         The build will be signed with the DEBUG key — fine for'
    Write-Host '         personal sideload testing, NOT OK for distribution.'
    Write-Host '         Run scripts\sign-setup.ps1 first to produce real release builds.'
    Write-Host ''
    $cont = Read-Host 'Continue anyway? [y/N]'
    if ($cont -notmatch '^[Yy]') { exit 1 }
}

if (-not $SkipClean) {
    Write-Host ''
    Write-Host '=== flutter clean ===' -ForegroundColor Cyan
    & $flutterCmd clean
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
}

Write-Host ''
Write-Host '=== flutter pub get ===' -ForegroundColor Cyan
& $flutterCmd pub get
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }

Write-Host ''
Write-Host '=== flutter analyze ===' -ForegroundColor Cyan
& $flutterCmd analyze --no-pub
if ($LASTEXITCODE -ne 0) {
    Write-Host 'analyze failed — fix the issues above before shipping.' -ForegroundColor Red
    exit $LASTEXITCODE
}

Write-Host ''
Write-Host '=== flutter test ===' -ForegroundColor Cyan
& $flutterCmd test --no-pub
if ($LASTEXITCODE -ne 0) {
    Write-Host 'tests failed — investigate before shipping.' -ForegroundColor Red
    exit $LASTEXITCODE
}

$builtPaths = @()

if (-not $BundleOnly) {
    Write-Host ''
    Write-Host '=== flutter build apk --release ===' -ForegroundColor Cyan
    & $flutterCmd build apk --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $apk = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'
    if (Test-Path $apk) {
        $size = (Get-Item $apk).Length / 1MB
        $builtPaths += "APK ({0:N1} MB): $apk" -f $size
    }
}

if (-not $ApkOnly) {
    Write-Host ''
    Write-Host '=== flutter build appbundle --release ===' -ForegroundColor Cyan
    & $flutterCmd build appbundle --release
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $aab = Join-Path $repoRoot 'build\app\outputs\bundle\release\app-release.aab'
    if (Test-Path $aab) {
        $size = (Get-Item $aab).Length / 1MB
        $builtPaths += "AAB ({0:N1} MB): $aab" -f $size
    }
}

# Verify signing — print the cert MD5 so the user can compare to their keystore
Write-Host ''
Write-Host '=== Signature check ===' -ForegroundColor Cyan
$apk = Join-Path $repoRoot 'build\app\outputs\flutter-apk\app-release.apk'
if (Test-Path $apk) {
    $keytool = (Get-Command keytool -ErrorAction SilentlyContinue).Source
    if (-not $keytool) {
        $keytool = 'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe'
    }
    if (Test-Path $keytool) {
        & $keytool -printcert -jarfile $apk 2>$null | Select-String -Pattern 'Owner:|MD5:|SHA256:'
    }
}

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
foreach ($p in $builtPaths) { Write-Host "  $p" }
Write-Host ''
Write-Host 'Next steps:'
Write-Host '  - Sideload: install the APK on a device, run docs\SMOKE_TEST.md.'
Write-Host '  - Play Store: upload the AAB to Internal Testing first.'
