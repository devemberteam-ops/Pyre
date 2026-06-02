# Pyre — One-time release keystore setup.
#
# Run this once, on the machine that will produce release builds. It will:
#   1. Locate keytool (from Android Studio's bundled JBR if it's not on PATH).
#   2. Generate `android/app/upload-keystore.jks` if missing.
#   3. Generate `android/key.properties` pointing at it.
#   4. Print a "back up these files NOW" reminder.
#
# Usage (from project root):
#     powershell -ExecutionPolicy Bypass -File scripts\sign-setup.ps1
#
# The script asks you interactively for the keystore + key passwords.
# Pick STRONG distinct passwords and write them down somewhere
# non-digital (passport, safe deposit). Losing them is equivalent to
# losing the keystore — every future update has to be signed by the
# same key, forever.

$ErrorActionPreference = 'Stop'

# Resolve repo root relative to this script (works no matter where it's run from).
$repoRoot = Split-Path -Parent $PSScriptRoot
$androidDir = Join-Path $repoRoot 'android'
$appDir = Join-Path $androidDir 'app'
$keystorePath = Join-Path $appDir 'upload-keystore.jks'
$propertiesPath = Join-Path $androidDir 'key.properties'

Write-Host ''
Write-Host '=== Pyre release signing setup ===' -ForegroundColor Cyan
Write-Host ''

# --- 1. Find keytool ---------------------------------------------------------
$keytoolCmd = (Get-Command keytool -ErrorAction SilentlyContinue).Source
if (-not $keytoolCmd) {
    $candidates = @(
        'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe',
        'C:\Program Files\Java\jdk-17\bin\keytool.exe',
        'C:\Program Files\Java\jdk-21\bin\keytool.exe'
    )
    foreach ($c in $candidates) {
        if (Test-Path $c) { $keytoolCmd = $c; break }
    }
}
if (-not $keytoolCmd) {
    Write-Host 'ERROR: keytool not found.' -ForegroundColor Red
    Write-Host 'Install JDK 17+ or Android Studio (it bundles a JBR with keytool).'
    exit 1
}
Write-Host "[1/4] Using keytool at: $keytoolCmd"

# --- 2. Refuse to overwrite an existing keystore -----------------------------
if (Test-Path $keystorePath) {
    Write-Host ''
    Write-Host "WARNING: $keystorePath already exists." -ForegroundColor Yellow
    Write-Host '         Overwriting it means losing the ability to update'
    Write-Host '         existing installs. Aborting to keep you safe.'
    Write-Host ''
    Write-Host 'If you really want to start over (no users installed yet):'
    Write-Host "  Remove-Item '$keystorePath'"
    Write-Host '  then re-run this script.'
    exit 1
}

# --- 3. Collect passwords + identity ----------------------------------------
Write-Host ''
Write-Host '[2/4] Choose passwords. Pick STRONG ones (16+ chars, mix of cases/digits/symbols).'
Write-Host '      The store password protects the .jks file.'
Write-Host '      The key password protects the key inside it. (Common to use the same.)'
Write-Host ''
$storePass = Read-Host 'Keystore password' -AsSecureString
$storePassConfirm = Read-Host 'Confirm keystore password' -AsSecureString
$keyPass = Read-Host 'Key password (press Enter to reuse keystore password)' -AsSecureString

# Convert SecureString -> plaintext for keytool (it doesn't accept SecureString).
function ConvertFrom-SecureToPlain($secure) {
    $bstr = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($secure)
    try   { return [Runtime.InteropServices.Marshal]::PtrToStringAuto($bstr) }
    finally { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($bstr) }
}
$storePassPlain = ConvertFrom-SecureToPlain $storePass
$confirmPlain = ConvertFrom-SecureToPlain $storePassConfirm
if ($storePassPlain -ne $confirmPlain) {
    Write-Host 'ERROR: passwords do not match.' -ForegroundColor Red
    exit 1
}
if ($storePassPlain.Length -lt 8) {
    Write-Host 'ERROR: password too short. Minimum 8 chars.' -ForegroundColor Red
    exit 1
}
$keyPassPlain = ConvertFrom-SecureToPlain $keyPass
if ([string]::IsNullOrEmpty($keyPassPlain)) {
    $keyPassPlain = $storePassPlain
}

Write-Host ''
Write-Host '[3/4] Cert details. These are printed on the certificate inside the keystore.'
Write-Host '      They don''t have to match a real identity, but they''re visible to anyone'
Write-Host '      who inspects the APK signature. Use your handle or "Pyre".'
Write-Host ''
$cn = Read-Host 'Your name or handle (e.g. Pyre)'
if ([string]::IsNullOrWhiteSpace($cn)) { $cn = 'Pyre' }
$org = Read-Host 'Organisation (press Enter for "Pyre")'
if ([string]::IsNullOrWhiteSpace($org)) { $org = 'Pyre' }
$locality = Read-Host 'City (press Enter for "Unknown")'
if ([string]::IsNullOrWhiteSpace($locality)) { $locality = 'Unknown' }
$country = Read-Host 'Country code, 2 letters (press Enter for "BR")'
if ([string]::IsNullOrWhiteSpace($country)) { $country = 'BR' }

$dname = "CN=$cn, O=$org, L=$locality, C=$country"
$alias = 'pyre-upload'

# --- 4. Run keytool ---------------------------------------------------------
Write-Host ''
Write-Host '[4/4] Generating keystore (10000 days = ~27 years validity)…'
& $keytoolCmd `
    -genkey -v `
    -keystore $keystorePath `
    -keyalg RSA -keysize 2048 -validity 10000 `
    -alias $alias `
    -storepass $storePassPlain `
    -keypass $keyPassPlain `
    -dname $dname
if ($LASTEXITCODE -ne 0) {
    Write-Host 'ERROR: keytool failed.' -ForegroundColor Red
    exit $LASTEXITCODE
}

# --- 5. Write key.properties ------------------------------------------------
$props = @"
# Generated by scripts/sign-setup.ps1 on $(Get-Date -Format 'yyyy-MM-dd HH:mm')
# This file is gitignored. DO NOT commit. DO NOT share. If you lose the
# values here AND the keystore, you cannot update existing installs.
storePassword=$storePassPlain
keyPassword=$keyPassPlain
keyAlias=$alias
storeFile=upload-keystore.jks
"@
Set-Content -Path $propertiesPath -Value $props -Encoding utf8

Write-Host ''
Write-Host '=== Done ===' -ForegroundColor Green
Write-Host "  Keystore : $keystorePath"
Write-Host "  Config   : $propertiesPath"
Write-Host ''
Write-Host '!! IMPORTANT — back these up RIGHT NOW !!' -ForegroundColor Yellow
Write-Host '  1. Copy upload-keystore.jks to TWO offline locations'
Write-Host '     (e.g. an encrypted USB drive AND an encrypted cloud archive).'
Write-Host '  2. Write the passwords on paper. Store separately from the .jks.'
Write-Host '  3. Anyone with the .jks + passwords can sign updates to your app.'
Write-Host '     Anyone WITHOUT them — including future you — cannot.'
Write-Host ''
Write-Host 'Next step:  scripts\build-release.ps1' -ForegroundColor Cyan
