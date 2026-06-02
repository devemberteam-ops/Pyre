// Wave CY.18.121: bundled example cards.
//
// A brand-new Pyre install ships with one cohesive, frankly-adult
// isekai-JRPG example set so the library is never empty on first launch
// AND so new users have a quality reference for what a good Pyre card
// looks like. The set is four native-Pyre JSON assets in
// `assets/examples/`:
//
//   - world.json     → a shared world Lorebook ("The Vael — World Lore")
//   - scenario.json  → a narrator scenario Character ("The Sunken Gate")
//   - ren.json       → the default user PERSONA source (Ren Brennan) — he
//                      is NOT added to the Characters library; he's
//                      converted into a persona only (see seeder).
//   - vesna.json     → a Character (Vesna, a wolfkin delver)
//
// The scenario + Vesna carry the world lorebook's id in `lorebookIds`.
// Ren is deliberately setting-NEUTRAL (no Vael/lore references at all) so
// he fits any scenario as the app's default persona — so he carries no
// lorebook bind either.
//
// This file holds the PURE pieces of the feature so they're trivially
// testable in isolation from `AppStore`:
//   - [shouldSeedExamples]  — the seed gate (no I/O, no globals).
//   - [loadExampleContent]  — loads + parses the bundled assets and
//     attaches the bundled avatar PNGs as base64 data URLs (each avatar
//     in its own try/catch so a missing/undeclared PNG just leaves the
//     card with a null avatar — the text + seeding ship independently of
//     the art being final).
//
// The actual one-time seeding into the store lives in
// `AppStore.seedExamplesIfFresh()` (it needs the live lists + persist),
// but it delegates the gate decision and the asset loading here.

import 'dart:convert';

import 'package:flutter/services.dart' show rootBundle;

import '../models/models.dart';
import 'attachment_store.dart';

/// Root of the bundled example assets (declared in `pubspec.yaml` under
/// `flutter: assets:`). Flutter does not recurse into subdirectories, so
/// `assets/examples/` and `assets/examples/avatars/` are listed
/// separately there.
const String _kExamplesDir = 'assets/examples';

/// The id of the shared world lorebook. Authored INTO `world.json` and
/// INTO the `lorebookIds` of `scenario.json` + `vesna.json`, so the bind
/// survives `_sweepOrphanReferences()` on the very first load (which
/// strips any lorebookId not present in `lorebooks`). Exposed as a const
/// so the seeder can defensively re-assert the bind regardless of what
/// the JSON happens to say.
const String kExampleWorldLorebookId = 'example-world-vael';

/// Wave CY.18.255 (FIX 3): deterministic ids for the seeded records.
///
/// Wave 254 made the bundled examples sync-eligible (real `mtime`). The
/// world lorebook already carries a FIXED id ([kExampleWorldLorebookId]), so
/// two devices that both fresh-install converge on ONE world lorebook by id.
/// The characters and the seeded Ren persona must do the same — otherwise
/// device A's Ren and device B's Ren are different random ids and sync
/// produces DUPLICATE Ren / Vesna / Sunken-Gate across paired devices.
///
/// The character ids below match what the JSON assets already declare
/// (`Character.fromJson` preserves `j['id']`), so setting them after parse is
/// a defensive no-op that pins the contract regardless of asset edits. The
/// PERSONA id is the one that genuinely needed fixing:
/// `buildPersonaFromCharacter` assigns a fresh `newId('persona')`, so the
/// seeder overrides it to [kExampleRenPersonaId] before append.
///
/// Forward-only: existing installs keep whatever ids they already seeded
/// (their flag is latched). Only fresh installs from this build onward seed
/// the deterministic ids, and two such installs de-dupe by id when they sync.
const String kExampleRenPersonaId = 'example-persona-ren';
const String kExampleVesnaCharacterId = 'example-char-vesna';
const String kExampleSunkenGateCharacterId = 'example-scenario-sunken-gate';

/// Pure seed gate. Seed the bundled examples ONLY on a genuinely fresh
/// install: never seeded before AND no characters yet AND the user
/// hasn't passed the welcome/onboarding screen. The triple-AND makes
/// "brand-new install only" airtight — an app UPDATE has
/// `seenOnboarding == true` (and usually non-empty characters), so the
/// gate is false and nothing is injected, even for an existing user who
/// deleted all their characters but kept personas/lorebooks/onboarding
/// state.
bool shouldSeedExamples({
  required bool alreadySeeded,
  required bool charactersEmpty,
  required bool seenOnboarding,
}) =>
    !alreadySeeded && charactersEmpty && !seenOnboarding;

/// The parsed, ready-to-seed bundled example content. The seeder appends
/// [lorebook] to the store's `lorebooks` FIRST, asserts the scenario +
/// Vesna `lorebookIds` contain [kExampleWorldLorebookId], then appends
/// the [characters] directly (bypassing `addCharacter` so the bundled
/// content skips the normal per-import side-effects), and finally
/// converts [renPersonaSource] into the default user persona.
class ExampleContent {
  /// The shared world lorebook.
  final Lorebook lorebook;

  /// The LIBRARY example characters, in display order:
  /// scenario ("The Sunken Gate"), then Vesna. The list ORDER is the
  /// order they land in the library. Ren is NOT here — he's persona-only
  /// (see [renPersonaSource]).
  final List<Character> characters;

  /// Wave CY.18.161: Ren is shipped as the default user PERSONA, not a
  /// library character. This is the parsed (setting-neutral) Ren card the
  /// seeder feeds to `buildPersonaFromCharacter`; it is never added to
  /// `characters`, so Ren never shows up in the Characters tab.
  final Character renPersonaSource;

  const ExampleContent({
    required this.lorebook,
    required this.characters,
    required this.renPersonaSource,
  });
}

/// Wave CY.18.188: one-time migration guard.
///
/// Returns true when [p] is unmistakably the Vesna persona that was seeded
/// by pre-Wave-161 builds — i.e. it should be removed from an existing
/// install that received it before Vesna was demoted to library-only.
///
/// **Why this heuristic is safe:**
/// Persona IDs are assigned via `newId('persona')` (a random UUID) so there
/// is no deterministic id to match on. Instead we use two independent
/// properties that only the seeder-created Vesna carries together:
///   1. `name == 'Vesna'` — the persona was created from the Vesna card.
///   2. `lorebookIds.contains(kExampleWorldLorebookId)` — `buildPersonaFromCharacter`
///      copies `lorebookIds` from the source character, and the Vesna character
///      is specifically bound to `example-world-vael`. A user who manually
///      created their OWN "Vesna" persona would not have that binding unless
///      they explicitly added it — an extremely unlikely accident, and even
///      if it happened the user can re-add the persona trivially.
///
/// The flag `vesnaExamplePersonaSwept` (in AppStore) ensures this runs at
/// most once per install, so it can NEVER fire on a post-migration install.
bool shouldRemoveAsSeededVesnaPersona(Persona p) =>
    p.name == 'Vesna' && p.lorebookIds.contains(kExampleWorldLorebookId);

/// Wave CY.18.204: one-time migration guard.
///
/// Returns true when [p] is unmistakably the example Ren persona that was
/// seeded as a FAVOURITE by Wave CY.18.122–203 builds — i.e. its
/// `favorite` star should be cleared on an existing install now that fresh
/// installs no longer favourite Ren.
///
/// **Why this heuristic is safe:**
/// Persona IDs are random UUIDs (`newId('persona')`), so there is no
/// deterministic id to match on — the same constraint Wave 188 faced for
/// Vesna. Instead we use three independent properties that ONLY the
/// seeder-created Ren persona carries together:
///   1. `name == 'Ren'` — the persona was created from the Ren source card.
///   2. `favorite == true` — the ONLY reason a seeded Ren persona is
///      starred is the old seeder; the new seeder never favourites him,
///      and a user who manually made a "Ren" persona would have to star it
///      by hand.
///   3. `lorebookIds.isEmpty` — Ren's source card is deliberately
///      setting-neutral and carries NO lorebook bind (asserted in
///      `example_seed_test`), so the seeded persona inherits none. This
///      distinguishes him from, say, a user's own world-bound "Ren".
///
/// Un-favouriting is non-destructive and trivially reversible (the user can
/// re-star the persona with one tap), so even in the vanishingly unlikely
/// event this matched a user's own unbound, favourited "Ren" persona, the
/// only effect is a cleared star. The flag `personaDefaultsAdjustedV3` (in
/// AppStore) ensures this runs at most once per install.
///
/// **Wave CY.18.209 — NAME-MATCH FIX:** the original Wave-204 guard matched
/// `p.name == 'Ren'`, but the seeded persona is built by
/// `buildPersonaFromCharacter`, which sets `name: c.name` from the source
/// card — and `assets/examples/ren.json` has `name: "Ren Brennan"`. So the
/// exact `== 'Ren'` check NEVER matched the real persona and the Wave-204
/// migration was a silent no-op (it still latched its `personaDefaultsAdjustedV2`
/// flag, hence the need for a fresh `personaDefaultsAdjustedV3` flag to re-run).
/// We now match `name.trim().startsWith('Ren')` (covers "Ren Brennan" and a
/// bare "Ren") while keeping the two independent safety signals — `favorite`
/// and `lorebookIds.isEmpty` — so a user's own persona is extremely unlikely
/// to be caught (it would have to be favourited, lorebook-free, AND named
/// starting with "Ren").
bool shouldUnfavoriteSeededRen(Persona p) =>
    p.name.trim().startsWith('Ren') &&
    p.favorite &&
    p.lorebookIds.isEmpty;

/// Load + parse the four bundled example assets and attach avatar PNGs.
///
/// Each JSON is read via [rootBundle.loadString] and parsed with the
/// native-Pyre `Character.fromJson` / `Lorebook.fromJson` (the assets are
/// authored in native-Pyre shape — flat camelCase — NOT chara_card_v2).
///
/// Avatars are OPTIONAL: each is loaded in its OWN try/catch, so a
/// missing or undeclared PNG (e.g. the art isn't final yet) just leaves
/// that card's `avatar` null and the rest of the content still seeds.
/// A present PNG is encoded as a `data:image/png;base64,...` data URL —
/// the same shape `Character.avatar` uses everywhere else.
///
/// Throws if a required JSON asset is missing or malformed — the caller
/// (`AppStore.seedExamplesIfFresh`) wraps the whole call in a try/catch
/// so a packaging mistake degrades to "no examples seeded" rather than a
/// crash on first launch.
Future<ExampleContent> loadExampleContent() async {
  final lorebook = await _loadLorebookAsset('$_kExamplesDir/world.json');

  // Scenario first (it's the showcase), then the two characters.
  final scenario = await _loadCharacterAsset('$_kExamplesDir/scenario.json');
  final ren = await _loadCharacterAsset('$_kExamplesDir/ren.json');
  final vesna = await _loadCharacterAsset('$_kExamplesDir/vesna.json');

  // Wave CY.18.255 (FIX 3): pin the deterministic ids. The assets already
  // declare these, but asserting them here guarantees two fresh installs
  // seed identical ids so LAN sync de-dupes by id instead of duplicating
  // the cards. (Ren's character id is also pinned even though he becomes a
  // persona — keeps the source card's id stable for any future use.)
  scenario.id = kExampleSunkenGateCharacterId;
  vesna.id = kExampleVesnaCharacterId;

  // Avatars are best-effort. The parent supplies the PNGs; the loader
  // tolerates their absence. Ren + Vesna have character portraits; the
  // scenario card gets a jungle-ruins background image as its thumbnail.
  // Ren's avatar still attaches so the converted persona inherits it.
  await _attachAvatar(ren, '$_kExamplesDir/avatars/ren.png');
  await _attachAvatar(vesna, '$_kExamplesDir/avatars/vesna.png');
  await _attachAvatar(scenario, '$_kExamplesDir/avatars/scenario.png');

  // Wave CY.18.249: seed ONE extra image into Ren's MINI-GALLERY (not his
  // avatar — the profile picture stays ren.png) so a brand-new install
  // visibly demonstrates that the gallery feature exists. Ren ships as the
  // default persona, and buildPersonaFromCharacter copies the gallery refs,
  // so this image lands in the persona's details-sheet mini-gallery.
  await _attachGalleryImage(ren, '$_kExamplesDir/avatars/ren_gallery1.png');

  return ExampleContent(
    lorebook: lorebook,
    // Library cards only — Ren is persona-only.
    characters: [scenario, vesna],
    renPersonaSource: ren,
  );
}

/// Read + parse a native-Pyre Lorebook JSON asset.
Future<Lorebook> _loadLorebookAsset(String path) async {
  final raw = await rootBundle.loadString(path);
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return Lorebook.fromJson(json);
}

/// Read + parse a native-Pyre Character JSON asset.
Future<Character> _loadCharacterAsset(String path) async {
  final raw = await rootBundle.loadString(path);
  final json = jsonDecode(raw) as Map<String, dynamic>;
  return Character.fromJson(json);
}

/// Best-effort: load a bundled PNG and set it on [c]'s avatar.
///
/// The bytes are EXTERNALISED into the content-addressed AttachmentStore
/// (Wave 64) so the resulting `pyre://attachment/<sha256>` URL is what
/// lands on the record. This matters because:
///   * `buildPersonaFromCharacter` copies the avatar STRING, so the
///     seeded Ren/Vesna personas reference the SAME hash as the
///     characters — ONE blob on disk, zero duplication.
///   * The persisted JSON holds only the short `pyre://` URL, not
///     ~megabytes of base64 (the on-load AttachmentMigration has already
///     run + flagged itself done before the seed, so inline data URLs
///     seeded here would never get externalised on their own).
///
/// `AttachmentStore.store` returns null on web (no filesystem) — there we
/// fall back to an inline `data:image/png;base64,...` URL, matching the
/// rest of the app's web path. Swallows ALL errors (missing asset, decode
/// failure) so the card simply keeps its null avatar — the bundled text
/// ships independently of the art being present.
Future<void> _attachAvatar(Character c, String path) async {
  try {
    final data = await rootBundle.load(path);
    final bytes = data.buffer.asUint8List();
    final ref = await AttachmentStore.store(bytes, mime: 'image/png');
    c.avatar = ref ?? 'data:image/png;base64,${base64Encode(bytes)}';
  } catch (_) {
    // Asset absent or unreadable — leave avatar null. The Characters UI
    // already falls back to an initial/placeholder.
  }
}

/// Wave CY.18.249: best-effort — load a bundled PNG and APPEND it to [c]'s
/// `gallery` (the mini-gallery on the card/persona details sheet). Same
/// externalisation path as [_attachAvatar]: the bytes go into the
/// content-addressed AttachmentStore and only the `pyre://attachment/<sha256>`
/// ref is stored on the record (web has no filesystem → inline data URL
/// fallback). Used to seed a demonstrative extra image of Ren so a fresh
/// install shows the gallery feature exists. Swallows all errors so a
/// missing/undeclared PNG simply leaves the gallery untouched.
Future<void> _attachGalleryImage(Character c, String path) async {
  try {
    final data = await rootBundle.load(path);
    final bytes = data.buffer.asUint8List();
    final ref = await AttachmentStore.store(bytes, mime: 'image/png');
    c.gallery.add(ref ?? 'data:image/png;base64,${base64Encode(bytes)}');
  } catch (_) {
    // Asset absent or unreadable — leave the gallery as-is.
  }
}
