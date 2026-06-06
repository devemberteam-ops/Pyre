// SYNC W6 (verification): a PURE, read-only "do the two devices actually
// hold the same library?" manifest + diff.
//
// WHY this exists
// ---------------
// LAN sync is Last-Writer-Wins and fire-and-forget: after a tick the user
// has no way to CONFIRM both sides converged — the whole thing felt like a
// black box ("how sync works is a total mystery; there should be a hash to
// compare the two versions"). This file is the answer. The phone builds a
// per-collection manifest of its OWN library, asks the paired PC for the
// PC's manifest (GET /manifest), and diffs them. The result drives a plain-
// language "✓ everything matches" / "characters: 9 here · 5 on PC" readout.
//
// It NEVER mutates anything. It only reads counts + computes a digest. The
// digest deliberately mirrors what the sync transport actually compares: a
// record's IDENTITY (`id`) + its sync version (`mtime`). Two collections with
// the same set of `(id, mtime)` pairs are byte-for-byte in sync under LWW
// (same ids present, each at the same version), so equal digests ⇒ in sync,
// and a digest mismatch points the user at exactly the collection that drifted.
//
// PURITY: no Flutter, no I/O, no SecureKeys. Takes the raw record lists (the
// caller pulls them off AppStore) so the whole thing is unit-testable on bare
// data. Stable across list ORDER (we sort by id before hashing) so the phone
// and the PC — which hold the same records in different in-memory order —
// produce the SAME digest for the same logical contents.

import 'dart:convert' show utf8;

import 'package:crypto/crypto.dart' show sha256;

import '../state/app_store.dart';

/// One synced collection's fingerprint: how many records it holds + a stable
/// content digest. [count] is the human-facing number ("9 here · 5 on PC");
/// [digest] is the machine comparison (equal ⇒ in sync).
class SyncCollectionStat {
  /// Number of records in the collection (after the same exclusions the sync
  /// transport applies — e.g. locked presets are dropped because they're
  /// rebuilt-from-build and never synced).
  final int count;

  /// Stable sha256 (hex) over the collection's `<id>:<mtime>` pairs, sorted by
  /// id. Order-independent: the same logical contents hash identically no
  /// matter what order the records sit in memory. Empty collections get the
  /// digest of the empty string (a fixed, well-known sha256) so two empty
  /// collections compare equal.
  final String digest;

  const SyncCollectionStat(this.count, this.digest);

  /// Parse from the JSON the server emits under `collections.<name>`. Defensive:
  /// a missing/garbled field degrades to 0 / '' rather than throwing, so a
  /// slightly-off server payload still yields a usable (if "differ") diff.
  factory SyncCollectionStat.fromJson(Map<String, dynamic> j) {
    return SyncCollectionStat(
      (j['count'] as num?)?.toInt() ?? 0,
      (j['digest'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {'count': count, 'digest': digest};

  @override
  bool operator ==(Object other) =>
      other is SyncCollectionStat &&
      other.count == count &&
      other.digest == digest;

  @override
  int get hashCode => Object.hash(count, digest);
}

/// The minimum a record must expose to be fingerprinted: a stable id + an
/// mtime (its sync version). Both [Character], [Chat], [Lorebook] … already
/// carry these, so the caller adapts each list to this shape with a tiny
/// closure. Kept as a plain record-ref (not the model) so this file stays
/// dependency-free + the helper is trivially unit-testable.
class SyncRecordDigestInput {
  final String id;
  final int mtime;
  const SyncRecordDigestInput(this.id, this.mtime);
}

/// Compute the stable digest for ONE collection. Sorts the records by id, joins
/// each as `<id>:<mtime>`, separates entries with `\n` (a char that can't
/// appear in a UUID id), and sha256-hexes the UTF-8 of the whole thing.
///
/// Stability guarantees:
///   * ORDER-INDEPENDENT — sorted by id first, so the phone + PC (different
///     in-memory order, same contents) match.
///   * VERSION-SENSITIVE — a record edited on one side bumps its mtime, which
///     changes the digest, so the diff flags the collection.
///   * MEMBERSHIP-SENSITIVE — an added/removed record changes the set of pairs.
String collectionDigest(Iterable<SyncRecordDigestInput> records) {
  final sorted = records.toList()..sort((a, b) => a.id.compareTo(b.id));
  final joined = sorted.map((r) => '${r.id}:${r.mtime}').join('\n');
  return sha256.convert(utf8.encode(joined)).toString();
}

/// Build a manifest from already-extracted per-collection record refs. This is
/// the PURE core — [buildSyncManifest] (in app_store_sync_manifest.dart-style
/// wiring) is a thin adapter that pulls the refs off an AppStore and calls this.
///
/// [collections] maps a collection NAME (e.g. 'characters') to its record refs.
/// [settingsMtime] is the singleton settings unit's version; when non-null it's
/// emitted as a `settings` stat with count=1 and a digest over just that mtime
/// (the settings unit has no id, so it can't ride the per-collection path).
/// Pass null to omit settings entirely.
Map<String, SyncCollectionStat> buildManifestFromRefs(
  Map<String, List<SyncRecordDigestInput>> collections, {
  int? settingsMtime,
}) {
  final out = <String, SyncCollectionStat>{};
  collections.forEach((name, records) {
    out[name] = SyncCollectionStat(records.length, collectionDigest(records));
  });
  if (settingsMtime != null) {
    // The settings unit is a singleton (no id) — fingerprint it as a one-record
    // collection whose digest is over the bare mtime. count=1 keeps the UI line
    // uniform ("settings: in sync" / "differ") with the rest.
    out['settings'] = SyncCollectionStat(
      1,
      sha256.convert(utf8.encode('settings:$settingsMtime')).toString(),
    );
  }
  return out;
}

/// One collection's diff: the local + remote counts and whether the two
/// digests matched. [inSync] is the authoritative verdict; the counts are for
/// the human-readable readout (and may even be EQUAL while [inSync] is false —
/// same number of records, different contents).
class SyncCollectionDiff {
  final String name;
  final int localCount;
  final int remoteCount;
  final bool inSync;

  const SyncCollectionDiff({
    required this.name,
    required this.localCount,
    required this.remoteCount,
    required this.inSync,
  });
}

/// The full comparison of a local manifest against a remote one. [collections]
/// is sorted by name for a stable UI order. [allInSync] is the headline verdict
/// the UI keys off ("✓ Everything matches" vs the per-collection list).
class SyncManifestDiff {
  final List<SyncCollectionDiff> collections;

  const SyncManifestDiff(this.collections);

  /// True iff EVERY collection matched (same digest). A collection present on
  /// one side but absent on the other counts as out-of-sync (its missing-side
  /// digest is the empty-collection digest, which only matches a genuinely
  /// empty collection — so a populated-vs-absent pair correctly differs).
  bool get allInSync => collections.every((c) => c.inSync);

  /// Just the collections that are OUT of sync — what the UI lists when
  /// [allInSync] is false.
  List<SyncCollectionDiff> get differing =>
      collections.where((c) => !c.inSync).toList();
}

/// Diff a [local] manifest against a [remote] one. Compares the UNION of
/// collection names on both sides (so a collection the remote lacks, or one the
/// local lacks, still appears in the result and is flagged out-of-sync). A
/// missing side is treated as an empty stat (count 0, empty-string digest),
/// which only "matches" a genuinely-empty present side.
SyncManifestDiff diffManifests(
  Map<String, SyncCollectionStat> local,
  Map<String, SyncCollectionStat> remote,
) {
  // Empty stat for a side that doesn't list a collection at all. Its digest is
  // '' — NOT the empty-collection sha256 — so an absent side never accidentally
  // matches a present empty collection's real digest. (An absent vs absent name
  // can't occur: the name is only in the union because at least one side has it.)
  const absent = SyncCollectionStat(0, '');

  final names = <String>{...local.keys, ...remote.keys}.toList()..sort();
  final diffs = <SyncCollectionDiff>[];
  for (final name in names) {
    final l = local[name] ?? absent;
    final r = remote[name] ?? absent;
    diffs.add(SyncCollectionDiff(
      name: name,
      localCount: l.count,
      remoteCount: r.count,
      // In sync iff both sides KNOW the collection AND their digests match.
      // (A genuinely-empty present collection has a real, non-empty sha256
      // digest of the empty string on BOTH sides, so two empties match; an
      // absent side carries '' and never matches that.)
      inSync: local.containsKey(name) &&
          remote.containsKey(name) &&
          l.digest == r.digest,
    ));
  }
  return SyncManifestDiff(diffs);
}

/// Parse a remote `/manifest` response body's `collections` map into stats.
/// Defensive: a non-map entry is skipped rather than throwing. Returns an empty
/// map for a missing/garbled `collections` key (→ everything diffs, which is the
/// safe "can't confirm" outcome).
Map<String, SyncCollectionStat> parseRemoteManifest(Map<String, dynamic> body) {
  final out = <String, SyncCollectionStat>{};
  final raw = body['collections'];
  if (raw is! Map) return out;
  raw.forEach((key, value) {
    if (value is Map) {
      out[key.toString()] =
          SyncCollectionStat.fromJson(value.cast<String, dynamic>());
    }
  });
  return out;
}

/// Build the manifest for a live [AppStore]. This is the only AppStore-aware
/// part of this file; everything above is pure data → testable without Flutter.
///
/// The collection SET + EXCLUSIONS deliberately mirror exactly what the sync
/// transport ships (PyreServer._allCollections + the /pull gates), so a diff
/// reflects what would actually converge:
///   * locked presets / locked creatorPresets are EXCLUDED — they're rebuilt
///     from the app binary on every load and never synced, so counting them
///     would create a phantom mismatch (the desktop's locked copy vs the
///     phone's locked copy can differ by build);
///   * providers ARE included by id+mtime (the API key never enters the digest
///     — only id+mtime do, exactly like every other collection, so this leaks
///     nothing about keys and matches the LWW compare the transport uses);
///   * the settings singleton rides as a one-record `settings` stat.
///
/// Both ends call THIS function on their own store, so the comparison is
/// apples-to-apples. The same record present on both sides at the same mtime
/// hashes identically regardless of in-memory order.
Map<String, SyncCollectionStat> buildSyncManifest(AppStore store) {
  SyncRecordDigestInput ref(String id, int mtime) =>
      SyncRecordDigestInput(id, mtime);
  final m = buildManifestFromRefs(
    {
      'characters': [for (final c in store.characters) ref(c.id, c.mtime)],
      'personas': [for (final p in store.personas) ref(p.id, p.mtime)],
      'chats': [for (final c in store.chats) ref(c.id, c.mtime)],
      // Locked default preset is rebuilt-from-build + never synced — exclude it
      // so it can't manufacture a false mismatch (mirrors the /pull `!p.locked`).
      'presets': [
        for (final p in store.presets)
          if (!p.locked) ref(p.id, p.mtime),
      ],
      'lorebooks': [for (final l in store.lorebooks) ref(l.id, l.mtime)],
      'regexRules': [for (final r in store.regexRules) ref(r.id, r.mtime)],
      'folders': [for (final f in store.folders) ref(f.id, f.mtime)],
      // Locked default creator preset excluded, same reasoning as presets.
      'creatorPresets': [
        for (final p in store.creatorPresets)
          if (!p.locked) ref(p.id, p.mtime),
      ],
      // Providers: id+mtime only — the digest NEVER touches the API key, so
      // this is safe to compute + transmit and still matches the LWW compare.
      'providers': [for (final p in store.providers) ref(p.id, p.mtime)],
    },
    // Singleton settings unit — emitted as `settings` (count 1) so it shows up
    // in the readout like any other collection. 0 means "never set" on a fresh
    // store; we still emit it (both sides will agree on 0).
    settingsMtime: store.settingsMtime,
  );
  // The BotBooru PROFILE unit — its OWN singleton stat, mirroring how the
  // `settings` singleton is fingerprinted inside buildManifestFromRefs
  // (count=1, digest over the bare mtime). 0 means "never set" on a fresh
  // store; both sides agree on 0.
  m['botbooruProfile'] = SyncCollectionStat(
    1,
    sha256
        .convert(utf8.encode('botbooruProfile:${store.botbooruProfileMtime}'))
        .toString(),
  );
  return m;
}
