// Wave CY.18.63: persistence abstraction so AppStore can run against
// either local disk (current behaviour, native builds) or a remote
// HTTP server (web/PWA, wired in Wave 71's `RemoteBackend`).
//
// The interface is deliberately minimal — just load + save of the full
// JSON blob — because that's all AppStore uses. Anything more granular
// (per-record CRUD, query, paging) is something Wave 71's
// RemoteBackend implements internally on top of /pull and /push, and
// it materialises the same blob shape for AppStore so the rest of the
// app sees no difference.
//
// On native this is currently a zero-cost wrapper around JsonStorage.
// Other JsonStorage features (lastLoad, approximateSize, clear) stay
// directly on the JsonStorage class because they're admin/diagnostic
// (Storage screen, backup/restore) and only make sense in local-disk
// land. The web/PWA build will route around them entirely.

import 'storage.dart';

/// Persistence target for the AppStore. Implementations decide whether
/// the blob lives on local disk, in a browser cache, or on a remote
/// LAN server.
abstract class StoreBackend {
  /// Read the persisted blob. Returns null on a fresh install or when
  /// the backend can't reach storage (e.g. RemoteBackend with no
  /// server connection — AppStore treats that as "boot empty").
  Future<Map<String, dynamic>?> load();

  /// Write the full blob. Implementations may debounce, batch, or
  /// stream-partial; AppStore makes no assumptions other than the
  /// blob is intact after a successful await.
  Future<void> save(Map<String, dynamic> blob);

  /// Wave CY.18.168: erase the persisted blob (and any rolling backups).
  /// Used ONLY by the in-app factory reset, which has already written a
  /// safety backup and double-confirmed with the user. A subsequent
  /// `save()` of the cleared state re-creates the file.
  Future<void> clear();
}

/// Native-disk backend. Thin wrapper around the existing JsonStorage —
/// keeps the atomic-write + rolling-backup + salvage logic exactly
/// where it lived pre-Wave-63, just behind the StoreBackend seam.
class LocalBackend implements StoreBackend {
  final JsonStorage _json;

  /// Optional injection for tests; production passes nothing.
  LocalBackend({JsonStorage? json}) : _json = json ?? JsonStorage();

  /// Expose the underlying JsonStorage so admin code (Storage screen,
  /// backup/restore) can still reach `lastLoad`, `approximateSize`,
  /// `clear` etc. Production code that just needs load/save should
  /// use the abstract `StoreBackend` interface.
  JsonStorage get jsonStorage => _json;

  @override
  Future<Map<String, dynamic>?> load() => _json.load();

  @override
  Future<void> save(Map<String, dynamic> blob) => _json.save(blob);

  @override
  Future<void> clear() => _json.clear();
}
