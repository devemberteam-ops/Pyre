<#
  build_all.ps1 - one-shot release build for Pyre.

  Builds Android APK + Windows desktop + Flutter web, then MIRRORS the
  fresh web bundle next to pyre.exe so the self-hosted LAN web client is
  never left behind. (The PyreServer serves <exe-dir>\web; a plain
  `flutter build windows` does NOT regenerate the web bundle, which is
  how the web app drifts versions behind — see Wave 246 / 2026-06-01.)

  Usage (run from the flutter_app/ folder):
    .\build_all.ps1           # analyze, then build apk+windows+web, then mirror web
    .\build_all.ps1 -Test     # also run the full test suite before building
    .\build_all.ps1 -NoCheck  # skip analyze (fast, not recommended)

  After it finishes: run build\windows\x64\runner\Release\pyre.exe and
  HARD-REFRESH the browser (Ctrl+Shift+R) to bust the web service worker.
#>
param(
  [switch] $Test,
  [switch] $NoCheck
)

# 'Continue' (not 'Stop'): flutter writes harmless warnings (e.g. the Kotlin
# KGP notice) to stderr, and PowerShell 5.1 would otherwise wrap those as
# terminating NativeCommandErrors and abort a perfectly good build. Real
# failures are caught by the explicit `$LASTEXITCODE -ne 0` throws below.
$ErrorActionPreference = 'Continue'
$flutter = 'C:\Users\Gui\flutter\bin\flutter.bat'
$root = $PSScriptRoot
Set-Location $root

function Step([string] $msg) { Write-Host "`n=== $msg ===" -ForegroundColor Cyan }

# Free the Gradle/lint-cache lock a prior build may have left held.
Get-Process java -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

if (-not $NoCheck) {
  Step 'flutter analyze'
  & $flutter analyze
  if ($LASTEXITCODE -ne 0) { throw 'analyze found issues - aborting build.' }
}

if ($Test) {
  Step 'flutter test'
  & $flutter test
  if ($LASTEXITCODE -ne 0) { throw 'tests failed - aborting build.' }
}

Step 'flutter build apk --release'
& $flutter build apk --release
if ($LASTEXITCODE -ne 0) { throw 'APK build failed.' }

Step 'flutter build windows --release'
# Release the pyre.exe link lock: a RUNNING desktop build (or the LAN web
# client's proxy host) holds Release\pyre.exe open, so the Windows linker
# fails with LNK1104 "cannot open file pyre.exe". Kill it just before the
# link step so the disruption window is as short as possible.
Get-Process pyre -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
& $flutter build windows --release
if ($LASTEXITCODE -ne 0) { throw 'Windows build failed.' }

Step 'flutter build web --release'
& $flutter build web --release
if ($LASTEXITCODE -ne 0) { throw 'web build failed.' }

Step 'mirror build\web -> Release\web (self-hosted LAN web client)'
$src = Join-Path $root 'build\web'
$dst = Join-Path $root 'build\windows\x64\runner\Release\web'
if (Test-Path $dst) { Remove-Item $dst -Recurse -Force }
New-Item -ItemType Directory -Path $dst -Force | Out-Null
Copy-Item -Path (Join-Path $src '*') -Destination $dst -Recurse -Force
$n = (Get-ChildItem $dst -Recurse -File | Measure-Object).Count

Step 'DONE'
Write-Host "APK:     build\app\outputs\flutter-apk\app-release.apk"
Write-Host "Windows: build\windows\x64\runner\Release\pyre.exe"
Write-Host "Web:     build\web  (mirrored $n files into Release\web)"
Write-Host "Now: run Release\pyre.exe and HARD-REFRESH the browser (Ctrl+Shift+R)."
