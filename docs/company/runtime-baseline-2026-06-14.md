# Runtime Baseline - 2026-06-14

## Worktree

- Repo: `C:\Users\Gui\Desktop\BotBooru chat app\flutter_app`
- Branch: `release/1.1.3`
- HEAD observed: `eb21efe`
- Pre-existing dirty files observed and not touched by this slice:
  - `lib/screens/presets_screen.dart`
  - `lib/services/sync_engine.dart`

## Toolchain

- `flutter --version`: blocked, command not found.
- `dart --version`: blocked, command not found.
- `ANDROID_HOME`: present at `C:\Users\Gui\AppData\Local\Android\Sdk`.
- `ANDROID_SDK_ROOT`: present at `C:\Users\Gui\AppData\Local\Android\Sdk`.

## Launch Status

- Windows desktop: blocked by missing Flutter command.
- Android: blocked by missing Flutter command; Android SDK is present but target discovery needs `flutter devices`.
- Web thin client: blocked by missing Flutter command and no running desktop LAN server from this shell.
- Screenshots: none captured; live visual pending.

## Provider/Network Status

- Anthropic real-key call: not exercised; no live app and no key probing performed.
- Slow-reasoning timeout repro: not exercised; no live app/provider endpoint available from this baseline.
- BotBooru `/bbx/` runtime probe: not exercised; desktop LAN server could not be started.

## Exact Next Command

After installing Flutter or locating the SDK, run:

```powershell
.\tool\environment_base\collect_baseline.ps1
```

If Flutter is installed but not on PATH:

```powershell
.\tool\environment_base\collect_baseline.ps1 -FlutterCommand "C:\path\to\flutter\bin\flutter.bat"
```

Then run the app for visual evidence:

```powershell
flutter run -d windows
flutter run -d chrome
flutter devices
```

