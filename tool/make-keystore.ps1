<#
  Pyre — one-shot release signing setup (Wave G).

  Run this ONCE in your own PowerShell. It will:
    1. Ask you for a password (typed locally, twice, never shown).
    2. Generate the Android signing keystore  -> android/app/upload-keystore.jks
    3. Write android/key.properties with that password + the right alias/path.

  After it finishes, the next `flutter build apk --release` is auto-signed.

  IMPORTANT: back up upload-keystore.jks + the password somewhere safe forever.
  Lose either and you can never ship an update over an existing install.

  Usage (from anywhere):
    powershell -ExecutionPolicy Bypass -File "C:\Users\Gui\Desktop\BotBooru chat app\flutter_app\tool\make-keystore.ps1"
#>

$ErrorActionPreference = 'Stop'

# --- paths ---------------------------------------------------------------
$root      = Split-Path -Parent (Split-Path -Parent $PSCommandPath)  # ...\flutter_app
$ksPath    = Join-Path $root 'android\app\upload-keystore.jks'
$propsPath = Join-Path $root 'android\key.properties'
$alias     = 'upload'

# --- locate keytool ------------------------------------------------------
$keytool = @(
  'C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe',
  "$env:JAVA_HOME\bin\keytool.exe"
) | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
if (-not $keytool) {
  $cmd = Get-Command keytool -ErrorAction SilentlyContinue
  if ($cmd) { $keytool = $cmd.Source }
}
if (-not $keytool) {
  Write-Host 'ERROR: keytool.exe not found. Install Android Studio / a JDK first.' -ForegroundColor Red
  exit 1
}

# --- never overwrite an existing key -------------------------------------
if (Test-Path $ksPath) {
  Write-Host "A keystore ALREADY exists at:" -ForegroundColor Yellow
  Write-Host "  $ksPath"
  Write-Host "Refusing to overwrite it (that would orphan your current signing key)." -ForegroundColor Yellow
  Write-Host "If you are 100% sure you want a fresh one, delete that file manually and re-run."
  exit 1
}

Write-Host '=== Pyre signing key setup ===' -ForegroundColor Cyan
Write-Host 'Pick a password for your signing key. WRITE IT DOWN — you need it for every future update.'
Write-Host ''

$pw1 = Read-Host 'Enter password' -AsSecureString
$pw2 = Read-Host 'Confirm password' -AsSecureString

$b1 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw1)
$b2 = [Runtime.InteropServices.Marshal]::SecureStringToBSTR($pw2)
$p1 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b1)
$p2 = [Runtime.InteropServices.Marshal]::PtrToStringBSTR($b2)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b1)
[Runtime.InteropServices.Marshal]::ZeroFreeBSTR($b2)

if ($p1 -ne $p2) {
  Write-Host 'Passwords do not match. Nothing was created — just run the script again.' -ForegroundColor Red
  exit 1
}
if ($p1.Length -lt 6) {
  Write-Host 'Password must be at least 6 characters (keytool requirement). Run again.' -ForegroundColor Red
  exit 1
}

# --- generate the keystore (password passed via env, not the command line) ---
$env:PYRE_KS_PW = $p1
try {
  & $keytool -genkeypair -v `
    -keystore $ksPath `
    -alias $alias `
    -keyalg RSA -keysize 2048 -validity 10000 `
    -dname 'CN=Ember Team, O=Ember Team, C=BR' `
    -storepass:env PYRE_KS_PW -keypass:env PYRE_KS_PW
  $ok = ($LASTEXITCODE -eq 0)
} finally {
  Remove-Item Env:\PYRE_KS_PW -ErrorAction SilentlyContinue
}

if (-not $ok -or -not (Test-Path $ksPath)) {
  Write-Host "keytool failed (exit $LASTEXITCODE). Nothing was written to key.properties." -ForegroundColor Red
  exit 1
}

# --- write key.properties (UTF-8, NO BOM, so Gradle parses it cleanly) ---
$props = "storePassword=$p1`nkeyPassword=$p1`nkeyAlias=$alias`nstoreFile=upload-keystore.jks`n"
[System.IO.File]::WriteAllText($propsPath, $props, [System.Text.UTF8Encoding]::new($false))

# best-effort scrub of the plaintext vars
$p1 = $null; $p2 = $null

Write-Host ''
Write-Host 'DONE — your release signing is set up.' -ForegroundColor Green
Write-Host "  Keystore : $ksPath"
Write-Host "  Config   : $propsPath"
Write-Host ''
Write-Host '>>> BACK IT UP NOW <<<' -ForegroundColor Yellow
Write-Host '    Copy upload-keystore.jks AND the password to a safe place'
Write-Host '    (password manager + an external/cloud backup).'
Write-Host '    Lose either and you can NEVER update the app over an existing install.'
Write-Host ''
Write-Host 'Both files are gitignored, so they will never be committed.'
