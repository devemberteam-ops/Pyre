// Lightweight "is there a newer Pyre out there?" startup probe.
//
// Wave CY.18.45: ships before any GitHub repo is live, so the URL is a
// constant that you swap once the repo + `latest.json` are up. Until
// then the call fails silently (good — never blocks the UI, never
// blocks startup, the user sees nothing).
//
// The probe is intentionally minimal:
//   - One HTTP GET on a JSON file hosted at a fixed CDN-ish URL
//   - 5-second timeout
//   - Catches everything → returns null on any failure
//   - Compares semver (`major.minor.patch`) — no metadata suffix logic
//
// Why not in-app updates with auto-install?
//   - Sideload-distributed APK = the OS won't let us install without
//     user interaction anyway
//   - Anything more sophisticated needs a stable repo URL we don't
//     have yet — better to keep this dumb-but-correct
//
// JSON shape we expect at the URL:
//   {
//     "latest": "1.2.0",
//     "url": "https://github.com/<user>/pyre/releases/tag/v1.2.0",
//     "notes": "What's new in this build (one-line summary)"
//   }
// Extra fields are ignored. Missing `latest` → no update available.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show debugPrint, ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// Where to check for the latest release JSON.
///
/// Wave CY.18.45: placeholder until the GitHub repo exists. The path
/// reflects the eventual real layout — `raw.githubusercontent.com/USER/
/// pyre/main/latest.json` — but the USER segment is your handle to
/// fill in when the repo is up. Until then this URL 404s and the
/// startup probe silently no-ops, which is the intended fail-safe.
///
/// Points at the real org (`devemberteam-ops/pyre`). It goes live the moment
/// that public repo exists with a `latest.json` at its root; until then the
/// probe 404s and silently no-ops (the intended fail-safe). Release flow:
///   1. Push `latest.json` to the root of the repo (see docs/RELEASE.md)
///   2. Each new release bumps `latest` → every install starts comparing
const String kLatestJsonUrl =
    'https://raw.githubusercontent.com/devemberteam-ops/pyre/main/latest.json';

class UpdateInfo {
  final String latestVersion;
  final String url;
  final String notes;
  const UpdateInfo({
    required this.latestVersion,
    required this.url,
    required this.notes,
  });
}

/// Wave CY.18.266: the latest known available update, or null when the user is
/// up to date / nothing has been checked yet. [checkForUpdate] populates this
/// on a positive result, so every UI surface stays in sync from one probe:
///   - the transient launch snackbar (main.dart), and
///   - the persistent "Update available" indicator in the More screen footer.
/// A failed/again check never CLEARS a previously-found update (we only ever
/// set it to a non-null value), so a transient network blip can't hide it.
final ValueNotifier<UpdateInfo?> availableUpdateNotifier =
    ValueNotifier<UpdateInfo?>(null);

/// Check for an available update. Returns `null` if the user is on
/// the latest version, the network is unavailable, the JSON couldn't
/// be parsed, or the placeholder URL hasn't been configured yet. The
/// caller (main / startup flow) can show a snackbar when this returns
/// non-null.
///
/// Safe to call repeatedly — does no caching, no rate limiting, no
/// state. The fixed URL is hit once per app start (in main.dart's
/// post-`runApp` block).
Future<UpdateInfo?> checkForUpdate() async {
  try {
    final info = await PackageInfo.fromPlatform();
    final current = info.version; // e.g. "1.0.0" from pubspec.yaml
    final resp = await http
        .get(Uri.parse(kLatestJsonUrl))
        .timeout(const Duration(seconds: 5));
    if (resp.statusCode != 200) return null;
    final body = jsonDecode(resp.body);
    if (body is! Map) return null;
    final latest = body['latest'];
    if (latest is! String || latest.isEmpty) return null;
    final isNewer = _compareSemver(latest, current) > 0;
    if (!isNewer) return null;
    final update = UpdateInfo(
      latestVersion: latest,
      url: (body['url'] as String?) ?? '',
      notes: (body['notes'] as String?) ?? '',
    );
    // Publish to the shared notifier so the persistent More-screen indicator
    // and the launch snackbar both reflect the same result.
    availableUpdateNotifier.value = update;
    return update;
  } catch (e) {
    debugPrint('[UpdateCheck] silent failure: $e');
    return null;
  }
}

/// Compare two `major.minor.patch` strings.
///   `1` if `a` > `b`,
///   `-1` if `a` < `b`,
///   `0` if equal or unparseable (treat unparseable as "no update —
///   we'd rather miss a notify than mis-notify on a malformed
///   latest.json").
///
/// Tolerates trailing `+build` / `-pre` segments by stripping them
/// before parsing.
int _compareSemver(String a, String b) {
  List<int> parse(String v) {
    final core = v.split(RegExp(r'[+\-]')).first;
    return core.split('.').map((s) => int.tryParse(s) ?? 0).toList();
  }

  final pa = parse(a);
  final pb = parse(b);
  for (var i = 0; i < 3; i++) {
    final av = i < pa.length ? pa[i] : 0;
    final bv = i < pb.length ? pb[i] : 0;
    if (av > bv) return 1;
    if (av < bv) return -1;
  }
  return 0;
}
