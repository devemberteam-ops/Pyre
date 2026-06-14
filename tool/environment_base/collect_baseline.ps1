param(
  [string]$FlutterCommand = "flutter",
  [string]$OutDir = "docs/company/evidence/2026-06-14-environment-and-base"
)

$ErrorActionPreference = "Continue"
$repo = Resolve-Path "."
$out = Join-Path $repo $OutDir
New-Item -ItemType Directory -Force -Path $out | Out-Null

function Write-Log {
  param(
    [string]$Name,
    [scriptblock]$Body
  )

  $path = Join-Path $out $Name
  "repo: $repo" | Set-Content -Encoding UTF8 $path
  "timestamp: $(Get-Date -Format o)" | Add-Content -Encoding UTF8 $path
  "" | Add-Content -Encoding UTF8 $path
  try {
    & $Body 2>&1 | Out-String | Add-Content -Encoding UTF8 $path
  } catch {
    "ERROR: $($_.Exception.Message)" | Add-Content -Encoding UTF8 $path
  }
}

Write-Log "00-git.txt" {
  git status --short
  git branch --show-current
  git rev-parse --short HEAD
  git log -1 --oneline
}

Write-Log "01-toolchain.txt" {
  "Flutter command: $FlutterCommand"
  "Get-Command flutter:"
  Get-Command $FlutterCommand -ErrorAction SilentlyContinue | Format-List *
  "Get-Command dart:"
  Get-Command dart -ErrorAction SilentlyContinue | Format-List *
  "Environment:"
  Get-ChildItem Env: |
    Where-Object { $_.Name -match 'FLUTTER|DART|ANDROID|JAVA|PUB' } |
    Sort-Object Name |
    Format-Table -AutoSize
}

$flutterCmd = Get-Command $FlutterCommand -ErrorAction SilentlyContinue
if ($null -eq $flutterCmd) {
  Write-Log "02-flutter-blocker.txt" {
    "BLOCKED: '$FlutterCommand' is not available on PATH."
    "Live desktop, Android, web thin-client, and Flutter test fallback cannot be executed until Flutter SDK is installed or -FlutterCommand points at flutter.bat."
  }
} else {
  Write-Log "02-flutter-version.txt" { & $FlutterCommand --version }
  Write-Log "03-flutter-doctor.txt" { & $FlutterCommand doctor -v }
  Write-Log "04-flutter-devices.txt" { & $FlutterCommand devices }
  Write-Log "05-flutter-analyze.txt" { & $FlutterCommand analyze }
  Write-Log "06-fallback-tests.txt" {
    & $FlutterCommand test `
      test/creator_render_test.dart `
      test/creator_edit_preserve_test.dart `
      test/creator_json_test.dart `
      test/creator_build_pipeline_test.dart `
      test/chat_api_param_retry_test.dart `
      test/anthropic_format_test.dart `
      test/sync_watermark_test.dart `
      test/key_sync_toggle_test.dart `
      test/lorebook_import_test.dart `
      test/regex_rules_test.dart `
      test/slider_card_clamp_test.dart `
      test/web_attachment_request_test.dart `
      test/gallery_test.dart `
      test/avatar_original_test.dart
  }
}

Write-Log "07-android.txt" {
  "ANDROID_HOME=$env:ANDROID_HOME"
  "ANDROID_SDK_ROOT=$env:ANDROID_SDK_ROOT"
  $adb = Join-Path $env:ANDROID_HOME "platform-tools/adb.exe"
  if (Test-Path $adb) {
    & $adb devices -l
  } else {
    "adb.exe not found under ANDROID_HOME/platform-tools."
  }
}

Write-Log "08-live-visual-status.txt" {
  "LIVE VISUAL PENDING"
  "No screenshots were captured by this helper because Flutter was not launchable in the PATH-based environment during this run."
  "Required visual flows once launchable: desktop app, LAN server, paired web thin client with service-worker/cache pressure, web streaming/avatar/gallery/download, BotBooru /bbx embed, and provider calls where keys/endpoints are present."
}

"Baseline collection complete: $out"
