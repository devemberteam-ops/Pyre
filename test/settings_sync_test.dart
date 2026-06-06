// SYNC W3: usage SETTINGS + provider ROLE POINTERS now travel between paired
// devices as a SINGLE synced unit (one `settingsMtime`, LWW as one record).
//
// Why one unit and not a per-record collection: the settings objects
// (modelSettings / chatSettings / memorySettings / liveSheet / script /
// guide) and the three provider role pointers (active / creator / vision)
// are small, change together, and have no individual identity — so a single
// `settingsMtime` watermark with whole-blob LWW is both simpler and correct.
//
// EXCLUSIONS locked in by these tests:
//   - chatSettings.customBackgroundDataUrl is NEVER shipped (a large inline
//     base64 image; re-sending it every sync would bloat the wire). The
//     receiving device keeps its OWN local background.
//   - device-specific state (uiPrefs, activePersonaId, activePresetId, sort /
//     filter) is not part of the unit — those tests live elsewhere / by
//     omission here.
//
// These tests run on a BARE `AppStore` (NoopBackend, no Flutter bindings) —
// `syncedSettingsToJson` / `applySyncedSettings` must be pure enough for that.

import 'package:flutter_test/flutter_test.dart';
import 'package:pyre/models/models.dart';
import 'package:pyre/services/store_backend.dart';
import 'package:pyre/state/app_store.dart';

class _NoopBackend implements StoreBackend {
  @override
  Future<Map<String, dynamic>?> load() async => null;
  @override
  Future<void> save(Map<String, dynamic> blob) async {}
  @override
  Future<void> clear() async {}
}

void main() {
  group('syncedSettingsToJson', () {
    test('carries the settings objects + pointers + mtime', () {
      final store = AppStore(storage: _NoopBackend());
      store.updateModelSettings(ModelSettings(temperature: 0.5, maxTokens: 222));
      store.updateMemorySettings(MemorySettings.fromJson({'autoEvery': 7}));
      store.activeProviderId = 'prov-chat';
      store.setCreatorProvider('prov-creator');
      store.setVisionProvider('prov-vision');

      final j = store.syncedSettingsToJson();
      expect(j['mtime'], store.settingsMtime);
      expect(j['mtime'], greaterThan(0));
      expect((j['modelSettings'] as Map)['temperature'], 0.5);
      expect((j['modelSettings'] as Map)['maxTokens'], 222);
      expect(j['activeProviderId'], 'prov-chat');
      expect(j['creatorProviderId'], 'prov-creator');
      expect(j['visionProviderId'], 'prov-vision');
      // The five small settings objects are all present.
      expect(j.containsKey('memorySettings'), isTrue);
      expect(j.containsKey('liveSheetSettings'), isTrue);
      expect(j.containsKey('scriptSettings'), isTrue);
      expect(j.containsKey('guideSettings'), isTrue);
      expect(j.containsKey('chatSettings'), isTrue);
    });

    test('does NOT include chatSettings.customBackgroundDataUrl', () {
      final store = AppStore(storage: _NoopBackend());
      store.updateChatSettings(ChatSettings(
        customBackgroundDataUrl: 'data:image/png;base64,AAAA',
      ));
      final j = store.syncedSettingsToJson();
      final cs = j['chatSettings'] as Map;
      expect(cs.containsKey('customBackgroundDataUrl'), isFalse);
    });
  });

  group('applySyncedSettings round-trip', () {
    test('a higher-mtime payload applies settings + pointers to a fresh store',
        () {
      final source = AppStore(storage: _NoopBackend());
      source.updateModelSettings(
          ModelSettings(temperature: 0.42, topP: 0.7, maxTokens: 333));
      source.updateMemorySettings(MemorySettings.fromJson({'autoEvery': 9}));
      source.updateScriptSettings(ScriptSettings(beatsCap: 5));
      source.activeProviderId = 'A';
      source.setCreatorProvider('C');
      source.setVisionProvider('V');
      final payload = source.syncedSettingsToJson();

      // Fresh store at settingsMtime=0 → the higher payload applies.
      final dest = AppStore(storage: _NoopBackend());
      expect(dest.settingsMtime, 0);
      dest.applySyncedSettings(payload);

      expect(dest.modelSettings.temperature, 0.42);
      expect(dest.modelSettings.topP, 0.7);
      expect(dest.modelSettings.maxTokens, 333);
      expect(dest.memorySettings.autoEvery, 9);
      expect(dest.scriptSettings.beatsCap, 5);
      expect(dest.activeProviderId, 'A');
      expect(dest.creatorProviderId, 'C');
      expect(dest.visionProviderId, 'V');
      expect(dest.settingsMtime, payload['mtime']);
    });

    test('pointers may be null and arrive as null', () {
      final source = AppStore(storage: _NoopBackend());
      source.updateModelSettings(ModelSettings(temperature: 0.3));
      // No creator/vision override set → they stay null.
      source.activeProviderId = null;
      final payload = source.syncedSettingsToJson();

      final dest = AppStore(storage: _NoopBackend());
      // Seed dest with non-null pointers to prove they get overwritten to null.
      dest.activeProviderId = 'stale';
      dest.setCreatorProvider('stale-c');
      dest.setVisionProvider('stale-v');
      // dest now has a NEWER mtime than source (the setters bumped it), so to
      // force the apply we hand a payload mtime above dest's.
      payload['mtime'] = dest.settingsMtime + 1000;

      dest.applySyncedSettings(payload);
      expect(dest.activeProviderId, isNull);
      expect(dest.creatorProviderId, isNull);
      expect(dest.visionProviderId, isNull);
    });
  });

  group('LWW (last-writer-wins by mtime)', () {
    test('payload mtime <= local settingsMtime is a NO-OP', () {
      final dest = AppStore(storage: _NoopBackend());
      dest.updateModelSettings(ModelSettings(temperature: 0.88));
      final localMtime = dest.settingsMtime;

      // Equal mtime → keep local.
      dest.applySyncedSettings({
        'mtime': localMtime,
        'modelSettings': ModelSettings(temperature: 0.11).toJson(),
      });
      expect(dest.modelSettings.temperature, 0.88,
          reason: 'equal mtime must not downgrade');
      expect(dest.settingsMtime, localMtime);

      // Older mtime → keep local.
      dest.applySyncedSettings({
        'mtime': localMtime - 5000,
        'modelSettings': ModelSettings(temperature: 0.22).toJson(),
      });
      expect(dest.modelSettings.temperature, 0.88,
          reason: 'older mtime must not downgrade');
      expect(dest.settingsMtime, localMtime);
    });

    test('a strictly higher mtime applies', () {
      final dest = AppStore(storage: _NoopBackend());
      dest.updateModelSettings(ModelSettings(temperature: 0.88));
      final localMtime = dest.settingsMtime;

      dest.applySyncedSettings({
        'mtime': localMtime + 1,
        'modelSettings': ModelSettings(temperature: 0.33).toJson(),
      });
      expect(dest.modelSettings.temperature, 0.33);
      expect(dest.settingsMtime, localMtime + 1);
    });
  });

  group('custom background is preserved across apply', () {
    test('incoming settings (no background) keep the local background', () {
      final dest = AppStore(storage: _NoopBackend());
      dest.updateChatSettings(ChatSettings(
        bubbleAlpha: 0.4,
        customBackgroundDataUrl: 'data:image/png;base64,LOCALBG',
      ));
      final localMtime = dest.settingsMtime;

      // Source has a different chatSettings + NO background, higher mtime.
      final source = AppStore(storage: _NoopBackend());
      source.updateChatSettings(ChatSettings(bubbleAlpha: 0.9));
      final payload = source.syncedSettingsToJson();
      payload['mtime'] = localMtime + 1000;

      dest.applySyncedSettings(payload);
      // The synced field (bubbleAlpha) came across…
      expect(dest.chatSettings.bubbleAlpha, 0.9);
      // …but the local-only background survived.
      expect(dest.chatSettings.customBackgroundDataUrl,
          'data:image/png;base64,LOCALBG');
    });
  });
}
