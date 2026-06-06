// Regression guard for audit finding [repo-site-release-01]:
// `latest.json` must advertise the same semantic version as `pubspec.yaml`,
// otherwise the in-app update banner silently stops notifying existing users
// when a new build ships. See `lib/services/update_check.dart` — the
// comparator strips any `+build` / `-pre` suffix and compares only the
// `major.minor.patch` core, so we assert on that core.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Strip any `+build` / `-pre` suffix and return the `major.minor.patch` core,
/// mirroring `_compareSemver` in `lib/services/update_check.dart`.
String _semverCore(String v) => v.split(RegExp(r'[+\-]')).first.trim();

void main() {
  test('latest.json version matches pubspec.yaml semver core', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    final versionLine = LineSplitter.split(pubspec).firstWhere(
      (l) => l.startsWith('version:'),
      orElse: () => '',
    );
    expect(versionLine, isNotEmpty, reason: 'pubspec.yaml has no version: line');
    final pubspecVersion = _semverCore(
      versionLine.substring('version:'.length).trim(),
    );

    final latest = jsonDecode(File('latest.json').readAsStringSync()) as Map;
    final latestVersion = _semverCore(latest['latest'] as String);

    expect(
      latestVersion,
      pubspecVersion,
      reason:
          'latest.json ("$latestVersion") must match pubspec.yaml '
          '("$pubspecVersion") so the update banner stays coherent. '
          'Bump latest.json as part of the release.',
    );
  });
}
