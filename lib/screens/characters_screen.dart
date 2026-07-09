import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image/image.dart' as img;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/capped_fetch.dart';
import '../services/card_import.dart';
import '../services/focus_bus.dart';
import '../services/gallery_import.dart';
import '../services/http_errors.dart';
import '../services/lorebook_import.dart';
import '../services/lorebook_merge.dart';
import '../services/attachment_store.dart';
import '../services/png_encoder.dart';
import '../services/png_parser.dart';
import '../services/web_download.dart';
import '../services/resolvers.dart';
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/card_import_confirm.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/export_snack.dart';
import '../widgets/menu_sheet.dart';
import 'character_assistant_screen.dart';
import 'character_details_sheet.dart';
import 'character_edit_screen.dart';
import 'chat_picker_screens.dart';
import 'chat_screen.dart';
import 'lorebooks_screen.dart' show LorebookList, editLorebook, importLorebookFile;
import 'persona_editor.dart';

class CharactersScreen extends StatefulWidget {
  const CharactersScreen({super.key});

  @override
  State<CharactersScreen> createState() => _CharactersScreenState();
}

class _CharactersScreenState extends State<CharactersScreen> {
  String _query = '';

  // BATCH P2-ui (I): debounce the search box. Each keystroke previously called
  // `setState` immediately, re-running the whole filter+sort and rebuilding the
  // list per character typed. Now a keystroke only (re)schedules this timer;
  // the actual `_query` update (and rebuild) fires once the user pauses, so a
  // burst of typing collapses to a single filter pass.
  Timer? _searchDebounce;
  static const _searchDebounceDelay = Duration(milliseconds: 250);

  // Wave CY.18.61: published to FocusBus so the global Ctrl+F shortcut
  // registered in main.dart can call .requestFocus() without needing
  // a direct widget-tree path here.
  final FocusNode _searchFocus = FocusNode();

  @override
  void initState() {
    super.initState();
    FocusBus.charactersSearch = _searchFocus;
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    // Clear before disposing so a hot-reload-stale reference can't
    // be re-used after the node is dead.
    if (identical(FocusBus.charactersSearch, _searchFocus)) {
      FocusBus.charactersSearch = null;
    }
    _searchFocus.dispose();
    super.dispose();
  }

  /// Apply a new search query immediately, cancelling any pending debounce.
  /// Used when the value must take effect now (segment switch clears it).
  void _setQueryNow(String value) {
    _searchDebounce?.cancel();
    if (_query == value) return;
    setState(() => _query = value);
  }

  /// Debounced search handler — see [_searchDebounce].
  void _onQueryChanged(String raw) {
    final next = raw.trim().toLowerCase();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(_searchDebounceDelay, () {
      if (!mounted) return;
      if (_query == next) return;
      setState(() => _query = next);
    });
  }

  @override
  Widget build(BuildContext context) {
    // BATCH P2-ui (F): read (not watch). This screen is hosted inside an
    // `ActiveTabGate` in the shell, which rebuilds it on every store notify
    // while it's the active tab and freezes it while off-screen. A root
    // `context.watch` here would re-subscribe and rebuild even when off-screen
    // (the InheritedWidget marks dependents dirty regardless of the gate),
    // defeating the gate — so the screen reads the store instead and lets the
    // gate govern its rebuilds.
    final store = context.read<AppStore>();
    // 2026-07-03 (Gui): Lorebooks moved out of More into this library —
    // they're content like characters and personas, not a setting.
    final segment = switch (store.uiPrefs.charactersSegment) {
      'personas' => 1,
      'lorebooks' => 2,
      _ => 0,
    };
    final charCount = store.characters.length;
    final personaCount = store.personas.length;
    final loreCount =
        store.lorebooks.where((b) => !b.hidden && !b.deleted).length;

    return Scaffold(
      appBar: AppBar(
        title: Text(switch (segment) {
          1 => 'Personas',
          2 => 'Lorebooks',
          _ => 'Characters',
        }),
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            child: ElevatedButton.icon(
              icon: const Icon(Icons.add, size: 16),
              label: const Text('Create'),
              onPressed: () => _onAdd(context, segment),
            ),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
            child: SegmentedButton<int>(
              segments: [
                ButtonSegment(value: 0, label: Text('Characters ($charCount)')),
                ButtonSegment(value: 1, label: Text('Personas ($personaCount)')),
                ButtonSegment(value: 2, label: Text('Lorebooks ($loreCount)')),
              ],
              selected: {segment},
              showSelectedIcon: false,
              onSelectionChanged: (s) {
                store.setCharactersSegment(switch (s.first) {
                  1 => 'personas',
                  2 => 'lorebooks',
                  _ => 'characters',
                });
                _setQueryNow('');
              },
              style: ButtonStyle(
                backgroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? EmberColors.primary
                        : EmberColors.bgElevated),
                foregroundColor: WidgetStateProperty.resolveWith((states) =>
                    states.contains(WidgetState.selected)
                        ? Colors.white
                        : EmberColors.textMid),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: TextField(
              // Wave CY.18.61: focus node wired to FocusBus so Ctrl+F
              // (desktop) lands the cursor here regardless of which
              // tab the user was on before.
              focusNode: _searchFocus,
              decoration: InputDecoration(
                hintText: switch (segment) {
                  1 => 'Search Persona',
                  2 => 'Search Lorebook',
                  _ => 'Search Character',
                },
                prefixIcon: const Icon(Icons.search, size: 18),
                isDense: true,
              ),
              onChanged: _onQueryChanged,
            ),
          ),
          Expanded(
            child: switch (segment) {
              1 => _PersonaList(store: store, query: _query),
              2 => LorebookList(store: store, query: _query),
              _ => _CharacterList(store: store, query: _query),
            },
          ),
        ],
      ),
    );
  }

  Future<void> _onAdd(BuildContext context, int segment) async {
    if (segment == 0) {
      await _showImportSourceSheet(context);
    } else if (segment == 1) {
      await _showPersonaAddSheet(context);
    } else {
      await _showLorebookAddSheet(context);
    }
  }
}

/// Lorebook add chooser — "Build with AI" (opens the lorebook-mode Creator)
/// vs "Create manually" (the classic entry editor) vs import. Mirrors the
/// persona add sheet, so all three library segments create things the same
/// way. (2026-07-03, Gui: lorebook AI creation lives HERE now, not as a
/// third choice inside the main Creator's chooser.)
Future<void> _showLorebookAddSheet(BuildContext context) async {
  await showMenuSheet<void>(
    context,
    itemsBuilder: (sheet) => [
      ListTile(
        leading: Icon(Icons.auto_awesome, color: EmberColors.primary),
        title: const Text('Build with AI assistant'),
        subtitle: Text(
          'Describe the world or topic and the AI drafts keyword-'
          'triggered entries you can review before saving.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () {
          Navigator.pop(sheet);
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                const CharacterAssistantScreen(lorebookMode: true),
          ));
        },
      ),
      ListTile(
        leading: Icon(Icons.edit_note, color: EmberColors.primary),
        title: const Text('Create manually'),
        subtitle: Text(
          'Name the book, then add keyword-triggered entries yourself.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () {
          Navigator.pop(sheet);
          editLorebook(context, null);
        },
      ),
      Divider(color: EmberColors.stroke, height: 1),
      ListTile(
        leading: const Icon(Icons.file_upload_outlined),
        title: const Text('Import from JSON'),
        subtitle: Text(
          'Pick a SillyTavern World Info / lorebook JSON from your device.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () async {
          Navigator.pop(sheet);
          await importLorebookFile(context);
        },
      ),
    ],
  );
}

/// Persona add chooser — "Build with AI" (opens the persona-mode
/// Character Creator) vs "Create manually" (the classic persona form).
/// Mirrors how characters offer build-with-AI vs from-scratch.
Future<void> _showPersonaAddSheet(BuildContext context) async {
  await showMenuSheet<void>(
    context,
    itemsBuilder: (sheet) => [
      ListTile(
        leading:
            Icon(Icons.auto_awesome, color: EmberColors.primary),
        title: const Text('Build with AI assistant'),
        subtitle: Text(
          'Chat with an AI that helps you flesh out your persona — who '
          'you are in chats — then writes it for you.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () {
          Navigator.pop(sheet);
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) =>
                const CharacterAssistantScreen(personaMode: true),
          ));
        },
      ),
      ListTile(
        leading: Icon(Icons.edit_note, color: EmberColors.primary),
        title: const Text('Create manually'),
        subtitle: Text(
          'Fill in the persona fields yourself in the in-app editor.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () {
          Navigator.pop(sheet);
          showPersonaEditor(context);
        },
      ),
      Divider(color: EmberColors.stroke, height: 1),
      // Wave CY.18.250: import a persona from a file — either a
      // chara_card PNG/JSON (converted via buildPersonaFromCharacter)
      // or a native Pyre persona JSON.
      ListTile(
        leading: const Icon(Icons.file_upload_outlined),
        title: const Text('Import from file'),
        subtitle: Text(
          'Pick a character card PNG/JSON or a Pyre persona JSON from your device.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () async {
          Navigator.pop(sheet);
          await _pickAndImportPersona(context);
        },
      ),
    ],
  );
}

/// Wave CY.18.250: import a persona from a file (.png or .json).
///
///  * `.png` → `parseCharaCardPng` → `characterFromCharaCard` →
///    `_personaFromImportedCard` (swaps {{user}}/{{char}}, folds
///    mes_example → dialogueExamples, carries gallery + lorebookIds —
///    UNLESS the card was exported BY Pyre as a persona, in which case
///    it's already persona-POV and the swap is skipped; see FIX 2).
///  * `.json` with a STRONG chara_card signal (spec `chara_card*` /
///    nested `data` Map / `first_mes`) and NO native-persona keys →
///    same chara_card path as above.
///  * any other `.json` → treated as a NATIVE Pyre persona
///    (`Persona.fromJson`), given a fresh id to avoid collisions.
///
/// Shows the same import-confirm dialog the card import uses, then a
/// success/failure snackbar.
Future<void> _pickAndImportPersona(BuildContext context) async {
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final bytes = f.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read file bytes.')),
      );
      return;
    }
    final ext = (f.extension ?? '').toLowerCase();

    // Decide whether the payload is a character card or a native persona.
    // PNGs are always character cards (chara_card_v2). JSONs can be either,
    // so sniff for chara_card markers before falling back to a native persona.
    Persona persona;
    if (ext == 'json') {
      // Audit 2026-06-04 [library-01]: decode the file as UTF-8 (not Latin-1
      // via String.fromCharCodes) so accented/CJK/emoji persona text survives.
      // Decode once and reuse for both the chara_card sniff and the parser.
      final jsonText = utf8.decode(bytes, allowMalformed: true);
      final map = jsonDecode(jsonText);
      if (map is! Map<String, dynamic>) {
        throw const FormatException('Not a JSON object');
      }
      // Wave CY.18.255 (FIX 1): tighten chara_card detection. The old
      // heuristic flagged ANY of spec/data/first_mes/mes_example/personality
      // as a card, so a hand-edited native persona JSON carrying a stray
      // `personality` (or `mes_example`) key got routed through the card
      // path → buildPersonaFromCharacter ran the {{user}}↔{{char}} swap and
      // INVERTED pronouns on already-persona-POV text. Now: only STRONG
      // chara_card signals count (spec starts with `chara_card`, a nested
      // `data` Map, or `first_mes`). And even with a strong signal, if the
      // object ALSO carries native-persona keys (dialogueExamples /
      // lorebookIds / gallery), treat it as a NATIVE persona — those keys
      // never appear on a chara_card_v2 payload, so their presence is a
      // reliable "this is a Pyre persona" tell that overrides a stray field.
      final specRaw = map['spec'];
      final strongCardSignal =
          (specRaw is String && specRaw.startsWith('chara_card')) ||
              map['data'] is Map ||
              map.containsKey('first_mes');
      final hasNativePersonaKeys = map.containsKey('dialogueExamples') ||
          map.containsKey('lorebookIds') ||
          map.containsKey('gallery');
      final looksLikeCard = strongCardSignal && !hasNativePersonaKeys;
      if (looksLikeCard) {
        final card = parseCharaCardJson(jsonText);
        persona = _personaFromImportedCard(characterFromCharaCard(card));
      } else {
        // Native Pyre persona. Re-id so importing a persona you already
        // have (same id in JSON) doesn't clobber / collide with it.
        persona = Persona.fromJson(map);
        persona.id = newId('persona');
      }
    } else {
      final card = parseCharaCardPng(bytes);
      persona = _personaFromImportedCard(characterFromCharaCard(card));
    }

    // Confirm before adding — persona text is templated into prompts, so
    // surface it first (same guard the card import uses). Reuse the card
    // confirm dialog by previewing the persona as a throwaway Character.
    if (!context.mounted) return;
    final previewCard = Character(
      id: newId('preview'),
      name: persona.name,
      tagline: persona.tagline,
      description: persona.description,
      mesExample: persona.dialogueExamples,
    );
    final choice = await confirmCardImport(context, previewCard);
    if (!choice.import) {
      messenger.showSnackBar(const SnackBar(content: Text('Import cancelled.')));
      return;
    }
    // B-2 / H-6: externalise a card-imported persona's inline avatar so it
    // persists as a pyre:// ref, not inline base64.
    await externalizePersonaImages(persona);
    store.addPersona(persona);
    messenger.showSnackBar(
      SnackBar(content: Text('Imported persona "${persona.name}"')),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Import failed: $e')),
    );
  }
}

/// Wave CY.18.255 (FIX 2): build a persona from a chara_card-imported
/// [Character], honouring the Pyre-origin persona marker.
///
/// A persona PNG exported by `_exportPersonaAsPng` carries
/// `extensions.pyre.kind == 'persona'`. That card's text is ALREADY in
/// persona POV (it was written from the persona's own perspective), so
/// running `buildPersonaFromCharacter`'s {{user}}↔{{char}} swap on it
/// would re-invert the pronouns — a net inversion vs the original. So
/// for a Pyre persona card we build with `swap: false` (the fields map
/// straight across, no role flip). Foreign cards (no marker) still go
/// through the normal swap so {{char}} text becomes {{user}} text.
Persona _personaFromImportedCard(Character c) {
  final pyreExt = c.extensions['pyre'];
  final isPyrePersona =
      pyreExt is Map && pyreExt['kind'] == 'persona';
  return buildPersonaFromCharacter(c, swap: !isPyrePersona);
}

Future<void> _showImportSourceSheet(BuildContext context) async {
  await showMenuSheet<void>(
    context,
    itemsBuilder: (sheet) => [
      ListTile(
        leading: Icon(Icons.auto_awesome, color: EmberColors.primary),
        title: const Text('Build with AI assistant'),
        subtitle: Text(
          'Chat with an AI that helps you flesh out a character, then writes the card for you.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () {
          Navigator.pop(sheet);
          Navigator.of(context).push(MaterialPageRoute(
            builder: (_) => const CharacterAssistantScreen(),
          ));
        },
      ),
      // Wave BL: drafts only live INSIDE the "Create from scratch"
      // path. They're a feature of the manual editor — the AI
      // assistant has its own session system, and surfacing drafts
      // at the Create root mixed the two metaphors. Now: tap Create
      // from scratch → if drafts exist, show chooser (Resume X /
      // Start fresh); if none, go straight to new editor.
      ListTile(
        leading: Icon(Icons.edit_note, color: EmberColors.primary),
        title: const Text('Create from scratch'),
        subtitle: Text(
          'Build a new chara_card_v2 card from blank in the in-app editor.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () async {
          Navigator.pop(sheet);
          await _createBlankCharacter(context);
        },
      ),
      Divider(color: EmberColors.stroke, height: 1),
      ListTile(
        leading: const Icon(Icons.link),
        title: const Text('From URL'),
        subtitle: Text(
          'Paste a direct PNG link from botbooru or chub.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () {
          Navigator.pop(sheet);
          _showImportCharacterDialog(context);
        },
      ),
      ListTile(
        leading: const Icon(Icons.file_upload_outlined),
        title: const Text('From file'),
        subtitle: Text(
          'Pick a Tavern Card PNG (or .json) from your device.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
        onTap: () async {
          Navigator.pop(sheet);
          await _pickAndImportCard(context);
        },
      ),
    ],
  );
}

/// Wave BG: create a DRAFT and open the editor on it. The draft only
/// persists if the user actually types something — back-out from an
/// empty editor cleans up silently (no phantom "Untitled character"
/// rows in the main list). Save promotes the draft to a real character.
///
/// Wave BL: if drafts already exist when the user taps "Create from
/// scratch", show a chooser sheet first (`Resume [name]` tiles +
/// `Start fresh` tile). The user can either pick up where they left
/// off OR explicitly start a new card. Avoids accidentally orphaning
/// existing drafts because the user forgot they had one.
Future<void> _createBlankCharacter(BuildContext context) async {
  final store = context.read<AppStore>();
  if (store.characterDrafts.isNotEmpty) {
    await _showResumeOrStartFreshSheet(context);
    return;
  }
  final draft = Character(
    id: newId('draft'),
    name: '',
  );
  store.saveDraft(draft);
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute(
    builder: (_) => CharacterEditScreen(draftId: draft.id),
  ));
}

/// Wave BL: bottom sheet that opens when the user taps "Create from
/// scratch" and there are existing drafts. Lists each draft with
/// long-press → delete, and a "Start fresh" tile at the bottom that
/// spawns a new draft.
Future<void> _showResumeOrStartFreshSheet(BuildContext context) async {
  final store = context.read<AppStore>();
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheet) {
      final drafts = store.characterDrafts;
      return SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Resume a draft or start fresh',
                  style: TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 17,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            Padding(
              padding: EdgeInsets.fromLTRB(20, 0, 20, 12),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'You have in-progress cards. Tap one to resume; '
                  'long-press to delete.',
                  style: TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 12,
                    height: 1.4,
                  ),
                ),
              ),
            ),
            Flexible(
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: drafts.length,
                separatorBuilder: (_, _) =>
                    Divider(height: 1, color: EmberColors.stroke),
                itemBuilder: (_, i) {
                  final d = drafts[i];
                  final title = d.name.trim().isEmpty
                      ? '(unnamed draft)'
                      : d.name;
                  return ListTile(
                    leading: Icon(Icons.drafts_outlined,
                        color: EmberColors.textMid),
                    title: Text(title,
                        style:
                            TextStyle(color: EmberColors.textHigh)),
                    subtitle: d.tagline != null && d.tagline!.isNotEmpty
                        ? Text(
                            d.tagline!,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                                color: EmberColors.textMid, fontSize: 11),
                          )
                        : null,
                    onTap: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => CharacterEditScreen(draftId: d.id),
                      ));
                    },
                    onLongPress: () {
                      Navigator.pop(sheet);
                      showDialog<void>(
                        context: context,
                        builder: (ctx) => AlertDialog(
                          backgroundColor: EmberColors.bgPanel,
                          title: const Text('Delete draft?'),
                          content: Text(
                              'Permanently discard "$title"? '
                              'This cannot be undone.'),
                          actions: [
                            TextButton(
                              onPressed: () => Navigator.pop(ctx),
                              child: const Text('Cancel'),
                            ),
                            ElevatedButton(
                              style: ElevatedButton.styleFrom(
                                backgroundColor: EmberColors.danger,
                              ),
                              onPressed: () {
                                Navigator.pop(ctx);
                                store.removeDraft(d.id);
                              },
                              child: const Text('Delete'),
                            ),
                          ],
                        ),
                      );
                    },
                  );
                },
              ),
            ),
            Divider(color: EmberColors.stroke, height: 1),
            ListTile(
              leading: Icon(Icons.add,
                  color: EmberColors.primary),
              title: Text('Start fresh',
                  style: TextStyle(
                      color: EmberColors.textHigh,
                      fontWeight: FontWeight.w600)),
              subtitle: Text(
                'Create a brand-new card alongside your existing drafts.',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () async {
                Navigator.pop(sheet);
                final draft = Character(
                  id: newId('draft'),
                  name: '',
                );
                store.saveDraft(draft);
                if (!context.mounted) return;
                await Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => CharacterEditScreen(draftId: draft.id),
                ));
              },
            ),
            const SizedBox(height: 4),
          ],
        ),
      );
    },
  );
}

// Bug 3 fix: transcode any non-PNG raster image (JPEG, WEBP, GIF …) to PNG
// so encodeCharaCardPng never throws FormatException('Not a PNG …').
// Returns the original bytes unchanged if they are already a PNG.
// Returns null when the bytes can't be decoded (truly unreadable — caller
// surfaces a user-friendly error instead of the raw exception).
Uint8List? _ensurePngBytes(Uint8List bytes) {
  if (looksLikePng(bytes)) return bytes; // already PNG — no conversion needed
  final decoded = img.decodeImage(bytes);
  if (decoded == null) return null; // unrecognised / corrupt image data
  return Uint8List.fromList(img.encodePng(decoded));
}

/// Export the character as a chara_card_v2 PNG, written to the device's
/// documents directory. The user can then share it / upload to botbooru
/// or any other Tavern-compatible community.
///
/// Requires an avatar on the character (the PNG is built from the avatar
/// bytes + the embedded JSON metadata). If there's no avatar, abort with
/// a hint so the user knows what to do.
Future<void> _exportCharacterAsPng(BuildContext context, Character c) async {
  final messenger = ScaffoldMessenger.of(context);
  // D3: capture store reference before the first await so we can read it
  // safely after any async gaps (avoids use_build_context_synchronously).
  final store = context.read<AppStore>();
  try {
    // Wave CY.18.145: resolve via the shared helper so a migrated
    // `pyre://attachment/<hash>` avatar works — the old naive comma-split
    // decode threw on those, so "Export as PNG card" was broken for every
    // character whose avatar had been externalised to an attachment.
    final avatarBytes = await resolveAvatarBytes(c.avatar);
    if (avatarBytes == null) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                'This character has no avatar. Set one in the editor first, then re-export.')),
      );
      return;
    }
    // Bug 3 fix: transcode JPEG/WEBP/GIF avatar to PNG before encoding.
    final pngAvatarBytes = _ensurePngBytes(avatarBytes);
    if (pngAvatarBytes == null) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                "Couldn't read the avatar image to embed in the card. Try setting a different avatar.")),
      );
      return;
    }
    // D3: gather bound lorebooks and merge into a single character_book so
    // lore travels with the exported card (was never wired before this fix).
    final boundBooks = c.lorebookIds
        .map(store.lorebookById)
        .whereType<Lorebook>()
        .where((b) => !b.deleted)
        .toList(growable: false);
    final mergedLorebook = mergeBoundLorebooksForExport(boundBooks);
    final pngBytes = encodeCharaCardPng(c, pngAvatarBytes,
        lorebook: mergedLorebook);

    // Sanitise the filename — strip anything but ASCII alphanumerics and
    // a few safe punctuation chars, fall back to "card" if empty.
    final safeName = c.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final filename =
        '${safeName.isEmpty ? 'card' : safeName}.card.png';

    if (kIsWeb) {
      // Web has no filesystem — trigger a real browser download instead of
      // copying an unsaveable data URL to the clipboard.
      downloadBytesToBrowser(pngBytes, filename, 'image/png');
      messenger.showSnackBar(
        SnackBar(content: Text('Downloading $filename')),
      );
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/PyreExports');
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final file = File('${outDir.path}/$filename');
    await file.writeAsBytes(pngBytes);

    // Wave CY.18.250: also export the mini-gallery alongside the card so a
    // shared/downloaded card carries its extra art. Each gallery ref is
    // resolved with the same helper the avatar uses; a ref that fails to
    // resolve is skipped (never aborts the whole export). All resulting
    // files — card + gallery — go into the single Share sheet's XFile list.
    final shareFiles = <XFile>[
      XFile(file.path, mimeType: 'image/png'),
    ];
    final galleryBase = safeName.isEmpty ? 'card' : safeName;
    var galleryExported = 0;
    for (var i = 0; i < c.gallery.length; i++) {
      try {
        final gbytes = await resolveAvatarBytes(c.gallery[i]);
        if (gbytes == null) continue;
        galleryExported++;
        final gfile =
            File('${outDir.path}/${galleryBase}_gallery_$galleryExported.png');
        await gfile.writeAsBytes(gbytes);
        shareFiles.add(XFile(gfile.path, mimeType: 'image/png'));
      } catch (_) {
        // Skip an unresolvable / unwritable gallery image silently.
      }
    }

    // Deliver per platform: on mobile the documents dir is app-private and
    // invisible, so we open the share sheet directly; on desktop we show the
    // saved-path confirmation + a Share button. (Filename only, not the full
    // path, so the desktop bar stays compact.)
    final banner = galleryExported > 0
        ? 'Exported — ${file.uri.pathSegments.last} '
            '(+$galleryExported gallery ${galleryExported == 1 ? 'image' : 'images'})'
        : 'Exported — ${file.uri.pathSegments.last}';
    await deliverExport(
      messenger,
      shareFiles,
      savedBanner: banner,
      shareSubject: '${c.name} — Pyre card',
      shareText: 'Character card exported from Pyre.',
      // Mobile: offer a real "Save to device" (SAF → Downloads) for the card
      // PNG; gallery images still ride along via the Share action.
      saveBytes: pngBytes,
      saveFileName: file.uri.pathSegments.last,
      saveExtensions: const ['png'],
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Export failed: $e')),
    );
  }
}

/// 1.2.1: export the character as a standard chara_card_v2 JSON file
/// (`<name>.card.json`) — the same payload `buildCharaCardV2Json` already
/// builds for the PNG export, just pretty-printed straight to a file
/// instead of base64-embedded in a PNG chunk.
///
/// KEY DIFFERENCE from `_exportCharacterAsPng`: this needs NO avatar. The
/// PNG export must abort without one (there's no image to embed the chunk
/// into); a bare JSON file has no image at all, so an avatarless character
/// exports just fine here — a real bonus over the PNG path.
Future<void> _exportCharacterAsJson(BuildContext context, Character c) async {
  final messenger = ScaffoldMessenger.of(context);
  // D3: capture store reference before the first await (see _exportCharacterAsPng).
  final store = context.read<AppStore>();
  try {
    // Gather bound lorebooks and merge into a single character_book, same
    // as the PNG export, so lore travels with the exported card.
    final boundBooks = c.lorebookIds
        .map(store.lorebookById)
        .whereType<Lorebook>()
        .where((b) => !b.deleted)
        .toList(growable: false);
    final mergedLorebook = mergeBoundLorebooksForExport(boundBooks);
    final map = buildCharaCardV2Json(c, lorebook: mergedLorebook);
    final bytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(map));

    // Sanitise the filename exactly like the PNG export.
    final safeName = c.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final filename =
        '${safeName.isEmpty ? 'card' : safeName}.card.json';

    if (kIsWeb) {
      // Web has no filesystem — trigger a real browser download instead of
      // copying an unsaveable data URL to the clipboard.
      downloadBytesToBrowser(bytes, filename, 'application/json');
      messenger.showSnackBar(
        SnackBar(content: Text('Downloading $filename')),
      );
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/PyreExports');
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final file = File('${outDir.path}/$filename');
    await file.writeAsBytes(bytes);

    await deliverExport(
      messenger,
      [XFile(file.path, mimeType: 'application/json')],
      savedBanner: 'Exported — ${file.uri.pathSegments.last}',
      shareSubject: '${c.name} — Pyre card (JSON)',
      shareText:
          'Character card exported from Pyre as standard chara_card_v2 JSON.',
      saveBytes: bytes,
      saveFileName: file.uri.pathSegments.last,
      saveExtensions: const ['json'],
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Export failed: $e')),
    );
  }
}

/// Wave CY.18.250: export a PERSONA as a chara_card_v2 PNG (+ its gallery),
/// mirroring `_exportCharacterAsPng`. Personas have no chara_card encoder of
/// their own, so we build a throwaway [Character] carrying the persona's
/// shareable fields and reuse `encodeCharaCardPng`. The persona↔card mapping:
///   name        → name
///   tagline      → tagline
///   description  → description
///   dialogueExamples → mesExample
///   avatar       → avatar
///   gallery      → gallery
///   lorebookIds  → lorebookIds (copied list)
/// All other Character fields stay at their defaults.
Future<void> _exportPersonaAsPng(BuildContext context, Persona p) async {
  final messenger = ScaffoldMessenger.of(context);
  // D3: capture store reference before the first await (see _exportCharacterAsPng).
  final personaStore = context.read<AppStore>();
  try {
    final avatarBytes = await resolveAvatarBytes(p.avatar);
    if (avatarBytes == null) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                'This persona has no avatar. Set one in the editor first, then re-export.')),
      );
      return;
    }
    // Bug 3 fix: transcode JPEG/WEBP/GIF avatar to PNG before encoding.
    final pngAvatarBytes = _ensurePngBytes(avatarBytes);
    if (pngAvatarBytes == null) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                "Couldn't read the avatar image to embed in the card. Try setting a different avatar.")),
      );
      return;
    }
    final asCard = Character(
      id: newId('export'),
      name: p.name,
      tagline: p.tagline,
      description: p.description,
      mesExample: p.dialogueExamples,
      avatar: p.avatar,
      gallery: List<String>.from(p.gallery),
      lorebookIds: List<String>.from(p.lorebookIds),
      // Wave CY.18.255 (FIX 2): tag this PNG as a Pyre-origin persona so a
      // round-trip import knows the text is ALREADY persona-POV and skips
      // the {{user}}↔{{char}} swap (see `_personaFromImportedCard`). Other
      // tools ignore the unknown `pyre` namespace. `buildCharaCardV2Json`
      // preserves this map and merges the tagline into it without clobbering
      // `kind`.
      extensions: <String, dynamic>{
        'pyre': <String, dynamic>{'kind': 'persona'},
      },
    );
    // D3: embed persona's bound lorebooks so lore travels with the exported card.
    final personaBoundBooks = p.lorebookIds
        .map(personaStore.lorebookById)
        .whereType<Lorebook>()
        .where((b) => !b.deleted)
        .toList(growable: false);
    final personaMergedLorebook = mergeBoundLorebooksForExport(personaBoundBooks);
    final pngBytes = encodeCharaCardPng(asCard, pngAvatarBytes,
        lorebook: personaMergedLorebook);

    final safeName = p.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final filename = '${safeName.isEmpty ? 'persona' : safeName}.card.png';

    if (kIsWeb) {
      // Web has no filesystem — trigger a real browser download.
      downloadBytesToBrowser(pngBytes, filename, 'image/png');
      messenger.showSnackBar(
        SnackBar(content: Text('Downloading $filename')),
      );
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/PyreExports');
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final file = File('${outDir.path}/$filename');
    await file.writeAsBytes(pngBytes);

    // Export the persona's gallery alongside the card, same as characters.
    final shareFiles = <XFile>[
      XFile(file.path, mimeType: 'image/png'),
    ];
    final galleryBase = safeName.isEmpty ? 'persona' : safeName;
    var galleryExported = 0;
    for (var i = 0; i < p.gallery.length; i++) {
      try {
        final gbytes = await resolveAvatarBytes(p.gallery[i]);
        if (gbytes == null) continue;
        galleryExported++;
        final gfile =
            File('${outDir.path}/${galleryBase}_gallery_$galleryExported.png');
        await gfile.writeAsBytes(gbytes);
        shareFiles.add(XFile(gfile.path, mimeType: 'image/png'));
      } catch (_) {
        // Skip an unresolvable / unwritable gallery image silently.
      }
    }

    final banner = galleryExported > 0
        ? 'Exported — ${file.uri.pathSegments.last} '
            '(+$galleryExported gallery ${galleryExported == 1 ? 'image' : 'images'})'
        : 'Exported — ${file.uri.pathSegments.last}';
    await deliverExport(
      messenger,
      shareFiles,
      savedBanner: banner,
      shareSubject: '${p.name} — Pyre persona',
      shareText: 'Persona exported from Pyre as a character card.',
      saveBytes: pngBytes,
      saveFileName: file.uri.pathSegments.last,
      saveExtensions: const ['png'],
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Export failed: $e')),
    );
  }
}

/// 1.2.1: export a PERSONA as a standard chara_card_v2 JSON file, mirroring
/// `_exportPersonaAsPng` — builds the same throwaway [Character] carrying
/// the persona's shareable fields, then reuses `buildCharaCardV2Json`
/// instead of `encodeCharaCardPng`.
///
/// KEY DIFFERENCE from `_exportPersonaAsPng`: this needs NO avatar (see
/// `_exportCharacterAsJson`). No gallery images are attached either — the
/// gallery is a PNG-side-files concern, not part of the JSON payload.
Future<void> _exportPersonaAsJson(BuildContext context, Persona p) async {
  final messenger = ScaffoldMessenger.of(context);
  // D3: capture store reference before the first await (see _exportCharacterAsPng).
  final personaStore = context.read<AppStore>();
  try {
    final asCard = Character(
      id: newId('export'),
      name: p.name,
      tagline: p.tagline,
      description: p.description,
      mesExample: p.dialogueExamples,
      avatar: p.avatar,
      gallery: List<String>.from(p.gallery),
      lorebookIds: List<String>.from(p.lorebookIds),
      // Wave CY.18.255 (FIX 2): tag this card as a Pyre-origin persona so a
      // round-trip import knows the text is ALREADY persona-POV and skips
      // the {{user}}↔{{char}} swap (see `_personaFromImportedCard`). Other
      // tools ignore the unknown `pyre` namespace. `buildCharaCardV2Json`
      // preserves this map and merges the tagline into it without clobbering
      // `kind`.
      extensions: <String, dynamic>{
        'pyre': <String, dynamic>{'kind': 'persona'},
      },
    );
    final personaBoundBooks = p.lorebookIds
        .map(personaStore.lorebookById)
        .whereType<Lorebook>()
        .where((b) => !b.deleted)
        .toList(growable: false);
    final personaMergedLorebook =
        mergeBoundLorebooksForExport(personaBoundBooks);
    final map = buildCharaCardV2Json(asCard, lorebook: personaMergedLorebook);
    final bytes =
        utf8.encode(const JsonEncoder.withIndent('  ').convert(map));

    final safeName = p.name
        .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
        .trim()
        .replaceAll(' ', '_');
    final filename = '${safeName.isEmpty ? 'persona' : safeName}.card.json';

    if (kIsWeb) {
      // Web has no filesystem — trigger a real browser download.
      downloadBytesToBrowser(bytes, filename, 'application/json');
      messenger.showSnackBar(
        SnackBar(content: Text('Downloading $filename')),
      );
      return;
    }

    final dir = await getApplicationDocumentsDirectory();
    final outDir = Directory('${dir.path}/PyreExports');
    if (!await outDir.exists()) await outDir.create(recursive: true);
    final file = File('${outDir.path}/$filename');
    await file.writeAsBytes(bytes);

    await deliverExport(
      messenger,
      [XFile(file.path, mimeType: 'application/json')],
      savedBanner: 'Exported — ${file.uri.pathSegments.last}',
      shareSubject: '${p.name} — Pyre persona (JSON)',
      shareText:
          'Persona exported from Pyre as a standard chara_card_v2 JSON.',
      saveBytes: bytes,
      saveFileName: file.uri.pathSegments.last,
      saveExtensions: const ['json'],
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Export failed: $e')),
    );
  }
}

Future<void> _pickAndImportCard(BuildContext context) async {
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['png', 'json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final f = result.files.single;
    final bytes = f.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read file bytes.')),
      );
      return;
    }
    // Audit 2026-06-04 [library-01]/[import-1-02]: sniff the content rather
    // than trust the picked extension. The old `.json` branch decoded bytes
    // with `String.fromCharCodes` (Latin-1), mojibaking accented/CJK/emoji
    // card text. `parseCharaCard` PNG-sniffs and otherwise UTF-8-decodes the
    // JSON, so non-ASCII names round-trip and a mislabelled .png/.json still
    // imports.
    final card = parseCharaCard(bytes);
    final character = characterFromCharaCard(card);
    // Wave CY.18.141: BotBooru gallery auto-import REMOVED (owner's request:
    // don't call our API, use our frontend). A file import has no live frontend
    // to read, so no gallery is offered here — galleries come from the rendered
    // page inside the Discover webview (Wave 142) or are added by hand.
    const List<String> galleryUrls = [];
    // Confirm with the user before saving — cards can contain prompt-
    // injection text in their description / system_prompt fields.
    if (!context.mounted) return;
    final choice = await confirmCardImport(
      context,
      character,
      galleryCount: galleryUrls.length,
    );
    if (!choice.import) {
      messenger.showSnackBar(const SnackBar(content: Text('Import cancelled.')));
      return;
    }
    if (choice.withGallery) {
      character.gallery = await downloadGalleryImages(galleryUrls);
    }
    // Wave CA: cards may carry an embedded character_book (the Gine
    // case). Ask the user how to handle it BEFORE persisting the
    // character so its lorebookIds round-trip cleanly.
    if (!context.mounted) return;
    await handleEmbeddedBookForCharacter(
      context: context,
      store: store,
      character: character,
      charaCardData: card.card,
    );
    // B-2 / H-6: externalise the inline avatar into the AttachmentStore so it
    // persists as a pyre:// ref, not inline base64.
    await externalizeCharacterImages(character);
    store.addCharacter(character);
    messenger.showSnackBar(
      SnackBar(content: Text('Imported ${character.name}')),
    );
  } catch (e) {
    messenger.showSnackBar(
      SnackBar(content: Text('Import failed: $e')),
    );
  }
}

// ---------------------------------------------------------------------------
// Pure, testable visibility logic for the Characters home screen.

/// Returns the subset of [all] characters that should be visible given the
/// current view state. Rules:
///
/// 1. Always exclude tombstoned (deleted:true) characters.
/// 2. If [activeFolderId] is set, show only the characters in that folder
///    (same as the pre-existing folder-scoped view).
/// 3. If [query] is non-empty, search across ALL characters regardless of
///    filing — so no card is unreachable by search.
/// 4. If no folder is active AND no query is typed (the home/default view),
///    show only characters that belong to ZERO live (non-deleted) folders.
///    Characters inside at least one live folder are hidden from the home
///    view; they live inside their folder tile.
///
/// The sort, tag filter, and favorites float remain the caller's
/// responsibility — this function is purely about which characters are in
/// scope.
List<Character> topLevelVisibleCharacters(
  List<Character> all,
  List<Folder> folders, {
  String? activeFolderId,
  String query = '',
}) {
  // Exclude tombstoned characters always.
  final live = all.where((c) => !c.deleted).toList();

  // --- Folder-scoped view ---
  if (activeFolderId != null) {
    Folder? folder;
    for (final f in folders) {
      if (f.id == activeFolderId) {
        folder = f;
        break;
      }
    }
    if (folder == null) {
      // Folder vanished (deleted elsewhere); return empty so caller can
      // fall back gracefully.
      return [];
    }
    final ids = folder.characterIds.toSet();
    return live.where((c) => ids.contains(c.id)).toList();
  }

  // --- Search-all when a query is active ---
  // Filed characters are not hidden from search — nothing is lost.
  if (query.isNotEmpty) {
    return live;
  }

  // --- Home view: hide filed characters ---
  // Compute the union of characterIds across all LIVE (non-deleted) folders.
  final filedIds = <String>{};
  for (final f in folders) {
    if (!f.deleted) {
      filedIds.addAll(f.characterIds);
    }
  }
  return live.where((c) => !filedIds.contains(c.id)).toList();
}

// ---------------------------------------------------------------------------

/// Wave CY.18.38: Characters list with sort + tag filter + folder
/// view + favorites section. Pre-Wave this was a flat list with only
/// search as filter — fine at 10-20 chars, terrible at 100+. The new
/// org system layers compose like this (in order):
///
///   1. Folder filter (if `charFolderId` set) → only ids in that folder
///   2. Tag filter (AND-logic chips) → only chars with all selected tags
///   3. Search query → name/tagline/tags/description substring
///   4. Sort (recent | created | alpha | chatted)
///   5. Favorites floated to the dedicated section at top
///
/// Each layer is opt-in; with everything off the user sees the old
/// flat list sorted by recency.
class _CharacterList extends StatelessWidget {
  final AppStore store;
  final String query;
  const _CharacterList({required this.store, this.query = ''});

  bool _matches(Character c) {
    if (query.isEmpty) return true;
    final hay = [
      c.name,
      c.tagline ?? '',
      c.tags.join(' '),
      c.description,
    ].join(' ').toLowerCase();
    return hay.contains(query);
  }

  /// Count of chats that include this character — used by the
  /// "Most chatted" sort.
  ///
  /// BATCH P2-ui (B): reads P1's memoized `chatCountByCharacter` map (one
  /// O(N_chats) pass, cached + invalidated on chat mutation) so the sort
  /// comparator is O(1) per lookup instead of rescanning ALL chats per
  /// comparison (the old O(N_chars · log N · N_chats) blow-up). Absent =
  /// no chats = 0.
  int _chatCount(Character c) => store.chatCountByCharacter[c.id] ?? 0;

  /// Last chat activity touching this character (max updatedAt across
  /// chats that contain them). 0 = never used → sorts to the bottom in
  /// recent mode.
  ///
  /// BATCH P2-ui (B): reads P1's memoized `lastUsedAtByCharacter` map; see
  /// `_chatCount` above for the rationale. Absent = never used = 0.
  int _lastUsedAt(Character c) => store.lastUsedAtByCharacter[c.id] ?? 0;

  List<Character> _applyFiltersAndSort() {
    // 1. Folder / home visibility: delegate to the pure helper which handles
    //    (a) folder-scoped view, (b) search-all override, (c) hide-filed-on-home.
    //    Tombstone exclusion is also done inside the helper.
    Iterable<Character> stream = topLevelVisibleCharacters(
      store.characters,
      store.folders,
      activeFolderId: store.charFolderId,
      query: query,
    );

    // 2. Tag filter (AND-logic across selected chips)
    if (store.charSelectedTags.isNotEmpty) {
      final wanted = store.charSelectedTags
          .map((t) => t.toLowerCase())
          .toSet();
      stream = stream.where((c) {
        final have = c.tags.map((t) => t.toLowerCase()).toSet();
        return wanted.every(have.contains);
      });
    }

    // 3. Search
    if (query.isNotEmpty) {
      stream = stream.where(_matches);
    }

    final list = stream.toList();

    // 4. Sort
    switch (store.charSortKey) {
      case 'created':
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case 'alpha':
        list.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case 'chatted':
        list.sort((a, b) => _chatCount(b).compareTo(_chatCount(a)));
        break;
      case 'recent':
      default:
        list.sort((a, b) => _lastUsedAt(b).compareTo(_lastUsedAt(a)));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    // Wave BK: drafts live in the Create sheet now, NOT in the
    // Characters list. The Characters list is for SAVED cards only.
    if (store.characters.isEmpty) {
      return const EmptyState(
        icon: Icons.person_outline,
        title: 'No characters yet',
        subtitle: 'Tap Create to import a Tavern Card from a URL or file.',
      );
    }

    final list = _applyFiltersAndSort();
    final favs = list.where((c) => c.favorite).toList();
    final rest = list.where((c) => !c.favorite).toList();
    final hasFilters = store.charSelectedTags.isNotEmpty ||
        store.charFolderId != null ||
        query.isNotEmpty;

    // BATCH P2-ui (A): virtualize. The old `ListView(children:[...])` built a
    // `_CharacterCard` (avatar decode + token chip) for EVERY filtered
    // character up-front, on every rebuild — the primary "more cards =
    // slower / OOM past ~100" surface. Flatten the favorites header + fav
    // rows + rest rows into a single typed item list and feed it to a
    // `ListView.builder` so only on-screen rows inflate. Scroll position is
    // preserved by the builder the same way the Chats tab already is.
    //
    // NOTE: `items` may be non-empty even when `list` is empty because
    // `_buildItems` prepends a Folders section on the home view. We gate the
    // empty state on `items.isEmpty` so the Folders section always renders.
    final items = _buildItems(favs, rest);

    // Decide what empty-state copy to show. On the home view with all
    // characters filed, a softer hint is shown inline (appended to items)
    // rather than replacing the entire body — the Folders section must stay
    // visible so the user can open their folders.
    final onHome = store.charFolderId == null && query.isEmpty;
    final liveFolders = store.folders.where((f) => !f.deleted).toList();
    if (list.isEmpty && onHome && liveFolders.isNotEmpty) {
      // All characters are in folders — append a gentle hint below the
      // Folders section so the screen doesn't look broken/blank.
      items.add(const _AllFiledHintItem());
    }

    return Column(
      children: [
        _OrgControlRow(store: store),
        if (store.charSelectedTags.isNotEmpty)
          _ActiveTagChipsRow(store: store),
        Expanded(
          child: items.isEmpty
              ? EmptyState(
                  icon: Icons.search_off,
                  title: 'No matches',
                  subtitle: hasFilters
                      ? 'Clear filters or change sort to see more.'
                      : 'Nothing matches your search.',
                )
              : ListView.builder(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                  itemCount: items.length,
                  itemBuilder: (context, i) => items[i].build(store),
                ),
        ),
      ],
    );
  }

  /// BATCH P2-ui (A): flatten the favorites section + the remaining cards into
  /// a single list of lazily-built rows for the `ListView.builder`. The
  /// favorites header is its own item (so it scrolls with the list and the
  /// collapse toggle still works); when collapsed, the fav rows are simply
  /// not appended.
  ///
  /// On the home view (no active folder, no query) a Folders section is
  /// prepended above the unfiled characters so filed items are reachable
  /// without opening the management sheet.
  List<_CharItem> _buildItems(List<Character> favs, List<Character> rest) {
    final items = <_CharItem>[];

    // --- Inline Folders section (home view only) ---
    final liveFolders =
        store.folders.where((f) => !f.deleted).toList();
    final onHome = store.charFolderId == null && query.isEmpty;
    if (onHome && liveFolders.isNotEmpty) {
      items.add(const _FolderSectionHeaderItem());
      for (final f in liveFolders) {
        items.add(_FolderTileItem(f));
      }
      // Gap between folders and the unfiled characters below (even if
      // the unfiled list is empty, the gap keeps the folders tidy).
      items.add(const _FolderSectionGapItem());
    }

    // --- Character rows ---
    if (favs.isNotEmpty) {
      items.add(_FavHeaderItem(favs.length));
      if (store.charFavoritesExpanded) {
        for (final c in favs) {
          items.add(_CardItem(c));
        }
      }
      items.add(const _GapItem());
    }
    for (final c in rest) {
      items.add(_CardItem(c));
    }
    return items;
  }
}

/// BATCH P2-ui (A): one lazily-built row in the virtualized Characters list.
/// Each concrete subtype renders itself given the [AppStore]; only the
/// on-screen items are ever built by the enclosing `ListView.builder`.
abstract class _CharItem {
  const _CharItem();
  Widget build(AppStore store);
}

/// The collapsible "FAVORITES (N)" header row.
class _FavHeaderItem extends _CharItem {
  final int count;
  const _FavHeaderItem(this.count);

  @override
  Widget build(AppStore store) => _FavoritesHeader(
        count: count,
        expanded: store.charFavoritesExpanded,
        onToggle: () =>
            store.setCharFavoritesExpanded(!store.charFavoritesExpanded),
      );
}

/// A character card row (+ its trailing 8px gap, matching the old spread).
class _CardItem extends _CharItem {
  final Character character;
  const _CardItem(this.character);

  @override
  Widget build(AppStore store) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _CharacterCard(store: store, character: character),
      );
}

/// A small spacer between the favorites section and the rest of the list.
class _GapItem extends _CharItem {
  const _GapItem();

  @override
  Widget build(AppStore store) => const SizedBox(height: 4);
}

/// Section header label for the inline Folders section on the home view.
class _FolderSectionHeaderItem extends _CharItem {
  const _FolderSectionHeaderItem();

  @override
  Widget build(AppStore store) => Padding(
        padding: const EdgeInsets.fromLTRB(0, 4, 0, 2),
        child: Text(
          'FOLDERS',
          style: TextStyle(
            color: EmberColors.textMid,
            fontSize: 11,
            fontWeight: FontWeight.w600,
            letterSpacing: 0.8,
          ),
        ),
      );
}

/// A folder row in the inline Folders section.
/// Tapping sets the active folder (same as tapping it in the folders sheet).
class _FolderTileItem extends _CharItem {
  final Folder folder;
  const _FolderTileItem(this.folder);

  @override
  Widget build(AppStore store) {
    final count = folder.characterIds.length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => store.setCharFolderId(folder.id),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          decoration: BoxDecoration(
            color: EmberColors.bgElevated,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: EmberColors.stroke),
          ),
          child: Row(
            children: [
              Icon(Icons.folder, color: EmberColors.primary, size: 20),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  folder.name,
                  style: TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              Text(
                '$count card${count == 1 ? "" : "s"}',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              const SizedBox(width: 6),
              Icon(Icons.chevron_right, color: EmberColors.textDim, size: 18),
            ],
          ),
        ),
      ),
    );
  }
}

/// Spacer between the Folders section and the unfiled characters below.
class _FolderSectionGapItem extends _CharItem {
  const _FolderSectionGapItem();

  @override
  Widget build(AppStore store) => const SizedBox(height: 8);
}

/// Shown on the home view when every character is filed in a folder.
/// Replaces the abrupt "No matches" full-screen empty state with a subtle
/// inline hint so the Folders section above stays visible and reachable.
class _AllFiledHintItem extends _CharItem {
  const _AllFiledHintItem();

  @override
  Widget build(AppStore store) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 24, horizontal: 8),
        child: Text(
          'All your characters are in folders.\n'
          'Open a folder above to chat.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: EmberColors.textDim,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      );
}

/// Wave CY.18.38: control row above the list. Sort dropdown +
/// Folders button (opens management sheet) + Tags button (opens tag
/// picker). When a folder is active, the row also shows a small "in
/// folder X" pill with a clear (X) affordance to drop back to All.
class _OrgControlRow extends StatelessWidget {
  final AppStore store;
  const _OrgControlRow({required this.store});

  String _sortLabel(String key) {
    switch (key) {
      case 'created':
        return 'Recently added';
      case 'alpha':
        return 'A → Z';
      case 'chatted':
        return 'Most chatted';
      case 'recent':
      default:
        return 'Recently used';
    }
  }

  @override
  Widget build(BuildContext context) {
    final folderName = store.charFolderId == null
        ? null
        : store.folders
            .firstWhere(
              (f) => f.id == store.charFolderId,
              orElse: () => Folder(id: '', name: ''),
            )
            .name;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 8,
        runSpacing: 8,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          // Sort
          PopupMenuButton<String>(
            tooltip: 'Sort',
            initialValue: store.charSortKey,
            onSelected: (k) => store.setCharSortKey(k),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'recent', child: Text('Recently used')),
              PopupMenuItem(value: 'created', child: Text('Recently added')),
              PopupMenuItem(value: 'alpha', child: Text('A → Z')),
              PopupMenuItem(value: 'chatted', child: Text('Most chatted')),
            ],
            child: _OrgChip(
              icon: Icons.sort,
              label: _sortLabel(store.charSortKey),
              trailingIcon: Icons.arrow_drop_down,
            ),
          ),
          // Folders
          InkWell(
            onTap: () => _showFoldersSheet(context, store),
            child: _OrgChip(
              icon: Icons.folder_outlined,
              label: folderName == null
                  ? (store.folders.isEmpty
                      ? 'Folders'
                      : 'Folders (${store.folders.length})')
                  : folderName.isEmpty
                      ? 'Folder ✕'
                      : '📁 $folderName',
              trailing: store.charFolderId != null
                  ? GestureDetector(
                      onTap: () => store.setCharFolderId(null),
                      child: const Icon(Icons.close, size: 14),
                    )
                  : null,
            ),
          ),
          // Tags
          InkWell(
            onTap: () => _showTagPickerSheet(context, store),
            child: _OrgChip(
              icon: Icons.tag,
              label: store.charSelectedTags.isEmpty
                  ? 'Tags'
                  : 'Tags (${store.charSelectedTags.length})',
            ),
          ),
        ],
      ),
    );
  }
}

class _OrgChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final IconData? trailingIcon;
  final Widget? trailing;
  const _OrgChip({
    required this.icon,
    required this.label,
    this.trailingIcon,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: EmberColors.bgElevated,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: EmberColors.stroke),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 14, color: EmberColors.textMid),
          const SizedBox(width: 6),
          Text(
            label,
            style:
                TextStyle(color: EmberColors.textHigh, fontSize: 12),
          ),
          if (trailingIcon != null) ...[
            const SizedBox(width: 2),
            Icon(trailingIcon, size: 14, color: EmberColors.textMid),
          ],
          if (trailing != null) ...[
            const SizedBox(width: 6),
            trailing!,
          ],
        ],
      ),
    );
  }
}

/// Row of active-tag chips with individual ✕ to remove, plus a
/// "Clear all" at the end. Only renders when the filter is non-empty.
class _ActiveTagChipsRow extends StatelessWidget {
  final AppStore store;
  const _ActiveTagChipsRow({required this.store});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        children: [
          for (final t in store.charSelectedTags)
            InputChip(
              label: Text('#$t'),
              labelStyle: const TextStyle(fontSize: 11),
              onDeleted: () => store.toggleCharSelectedTag(t),
              deleteIconColor: EmberColors.textMid,
              backgroundColor:
                  EmberColors.primary.withValues(alpha: 0.18),
              side: BorderSide(
                color: EmberColors.primary.withValues(alpha: 0.4),
              ),
              padding: EdgeInsets.zero,
              materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.compact,
            ),
          ActionChip(
            label: const Text('Clear all', style: TextStyle(fontSize: 11)),
            avatar: const Icon(Icons.close, size: 14),
            onPressed: () => store.clearCharSelectedTags(),
            padding: EdgeInsets.zero,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }
}

/// Collapsible "FAVORITES (N)" header that floats favorite chars to the top
/// of the list. Header state is persisted in the store.
///
/// BATCH P2-ui (A): this is now the HEADER ONLY — the favorite rows are
/// flattened into the parent `ListView.builder` (see `_buildItems`) so they
/// virtualize like every other row instead of being eagerly built inside a
/// `Column` here.
/// The collapsible "FAVORITES (N)" header. Shared by the Characters and
/// Personas lists (completeness-gaps: personas used to have a bare static
/// header). The caller supplies the live [count], the current [expanded]
/// state, and the toggle callback so the same widget drives either tab's
/// persisted collapse state.
class _FavoritesHeader extends StatelessWidget {
  final int count;
  final bool expanded;
  final VoidCallback onToggle;
  const _FavoritesHeader({
    required this.count,
    required this.expanded,
    required this.onToggle,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onToggle,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.star, size: 14, color: EmberColors.primary),
            const SizedBox(width: 6),
            Text(
              'FAVORITES ($count)',
              style: TextStyle(
                color: EmberColors.primary,
                fontWeight: FontWeight.w700,
                fontSize: 11,
                letterSpacing: 1.2,
              ),
            ),
            const Spacer(),
            Icon(
              expanded ? Icons.expand_less : Icons.expand_more,
              size: 18,
              color: EmberColors.textMid,
            ),
          ],
        ),
      ),
    );
  }
}

/// Wave CY.18.38: single character row. Adds favorite star toggle
/// (replaces nothing — sits between subtitle/trailing) and routes the
/// kebab through the existing `_showCharacterMenu` flow.
class _CharacterCard extends StatelessWidget {
  final AppStore store;
  final Character character;
  const _CharacterCard({required this.store, required this.character});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: AvatarBubble(
          dataUrl: character.avatar,
          fallback: character.name,
          tappableLightbox: true,
          // Non-destructive Recrop: tapping the (face-framed) thumbnail opens
          // the WHOLE uncropped original, not the crop. Null when never
          // recropped → AvatarBubble falls back to the full `avatar`.
          fullImageUrl: character.avatarOriginal,
        ),
        title: Text(character.name,
            style: const TextStyle(fontWeight: FontWeight.w600)),
        subtitle: _CharacterSubtitle(store: store, character: character),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                character.favorite ? Icons.star : Icons.star_border,
                color: character.favorite
                    ? EmberColors.primary
                    : EmberColors.textMid,
                size: 20,
              ),
              tooltip: character.favorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
              onPressed: () => store.toggleCharacterFavorite(character.id),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: Icon(Icons.more_vert,
                  color: EmberColors.textMid),
              tooltip: 'Character actions',
              onPressed: () =>
                  _showCharacterMenu(context, store, character),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        onTap: () => _showCharacterMenu(context, store, character),
      ),
    );
  }
}

/// Subtitle for a character row in the list. Mirrors the HTML behaviour:
/// prefers `tagline` (one liner), falls back to comma-joined `tags` with a
/// tiny location/tag icon, falls back to description first line.
///
/// Wave CM: also shows an approximate token-count chip on the right so
/// the user can spot at a glance which characters are heavy (e.g.
/// 8k+ token monsters that will eat their context window).
class _CharacterSubtitle extends StatelessWidget {
  final AppStore store;
  final Character character;
  const _CharacterSubtitle({required this.store, required this.character});

  @override
  Widget build(BuildContext context) {
    // BATCH P2-ui (E): use P1's memoized per-character token estimate (keyed
    // by id + content-hash) instead of re-summing every text field of the
    // card on each rebuild.
    final tokenLabel =
        formatTokenCount(store.approxTokensForCharacterCached(character));
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Expanded(child: _buildBody()),
        if (tokenLabel != null) ...[
          const SizedBox(width: 6),
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Text(
              tokenLabel,
              style: TextStyle(
                color: EmberColors.textDim,
                fontSize: 10,
                fontFeatures: [FontFeature.tabularFigures()],
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildBody() {
    if ((character.tagline ?? '').trim().isNotEmpty) {
      return Text(
        character.tagline!,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: EmberColors.textMid),
      );
    }
    if (character.tags.isNotEmpty) {
      return Row(
        children: [
          Icon(Icons.tag, size: 12, color: EmberColors.textDim),
          const SizedBox(width: 4),
          Expanded(
            child: Text(
              character.tags.join(', '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: EmberColors.textMid, fontSize: 13),
            ),
          ),
        ],
      );
    }
    final firstLine = character.description.split('\n').first.trim();
    return Text(
      firstLine.isEmpty ? '(no description)' : firstLine,
      maxLines: 2,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(color: EmberColors.textMid),
    );
  }
}

/// Wave CY.18.38: Personas tab. Lighter than Characters (no folders,
/// no tag filter — personas usually stay under ~15 per user). Just
/// sort + favorites + search.
class _PersonaList extends StatelessWidget {
  final AppStore store;
  final String query;
  const _PersonaList({required this.store, this.query = ''});

  bool _matches(Persona p) {
    if (query.isEmpty) return true;
    final hay =
        [p.name, p.tagline ?? '', p.description].join(' ').toLowerCase();
    return hay.contains(query);
  }

  String _sortLabel(String key) {
    switch (key) {
      case 'created':
        return 'Recently added';
      case 'alpha':
        return 'A → Z';
      case 'recent':
      default:
        return 'Recently used';
    }
  }

  /// BATCH P2-ui (B): last chat activity per persona, precomputed in ONE
  /// O(N_chats) pass. The old `_lastUsedAt` rescanned ALL chats per sort
  /// comparison (O(N_personas · log N · N_chats)). There's no store-level
  /// memoized persona map (persona N is intentionally small), so a single
  /// local pass per build is the proportionate fix. Personas with no chats
  /// are absent (callers treat absent as 0).
  Map<String, int> _lastUsedAtByPersona() {
    final m = <String, int>{};
    for (final ch in store.chats) {
      final pid = ch.personaId;
      if (pid == null) continue;
      final prev = m[pid];
      if (prev == null || ch.updatedAt > prev) m[pid] = ch.updatedAt;
    }
    return m;
  }

  List<Persona> _applyFiltersAndSort() {
    // Filter out tombstoned (deleted:true) records so a stray synced-in
    // tombstone can't render as a phantom persona (mirrors regex_rules_screen).
    final list =
        store.personas.where((p) => !p.deleted && _matches(p)).toList();
    switch (store.personaSortKey) {
      case 'created':
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
        break;
      case 'alpha':
        list.sort(
            (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
        break;
      case 'recent':
      default:
        final lastUsed = _lastUsedAtByPersona();
        list.sort((a, b) =>
            (lastUsed[b.id] ?? 0).compareTo(lastUsed[a.id] ?? 0));
        break;
    }
    return list;
  }

  @override
  Widget build(BuildContext context) {
    if (store.personas.isEmpty) {
      return const EmptyState(
        icon: Icons.face_outlined,
        title: 'No personas yet',
        subtitle: 'Create a persona to define how you appear in chats.',
      );
    }
    final filtered = _applyFiltersAndSort();
    final favs = filtered.where((p) => p.favorite).toList();
    final rest = filtered.where((p) => !p.favorite).toList();
    if (filtered.isEmpty) {
      return const EmptyState(
        icon: Icons.search_off,
        title: 'No matches',
        subtitle: 'Nothing matches your search.',
      );
    }
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: Align(
            alignment: Alignment.centerLeft,
            child: PopupMenuButton<String>(
              tooltip: 'Sort',
              initialValue: store.personaSortKey,
              onSelected: (k) => store.setPersonaSortKey(k),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'recent', child: Text('Recently used')),
                PopupMenuItem(
                    value: 'created', child: Text('Recently added')),
                PopupMenuItem(value: 'alpha', child: Text('A → Z')),
              ],
              child: _OrgChip(
                icon: Icons.sort,
                label: _sortLabel(store.personaSortKey),
                trailingIcon: Icons.arrow_drop_down,
              ),
            ),
          ),
        ),
        Expanded(
          // BATCH P2-ui (A): virtualize the persona list the same way as the
          // character list — only on-screen rows build. (N is small here, but
          // the eager `ListView(children:[...])` still built every row +
          // avatar on each rebuild; the builder keeps it consistent.)
          child: Builder(builder: (context) {
            final items = _buildPersonaItems(favs, rest);
            return ListView.builder(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              itemCount: items.length,
              itemBuilder: (context, i) => items[i].build(store),
            );
          }),
        ),
      ],
    );
  }

  /// BATCH P2-ui (A): flatten the favorites header + fav rows + rest rows into
  /// a single lazily-built item list for the `ListView.builder`.
  List<_PersonaItem> _buildPersonaItems(
      List<Persona> favs, List<Persona> rest) {
    final items = <_PersonaItem>[];
    if (favs.isNotEmpty) {
      items.add(_PersonaFavHeaderItem(favs.length));
      // Completeness-gaps: honor the persisted collapse state (parity with
      // the Characters list — favorites can be folded away).
      if (store.personaFavoritesExpanded) {
        for (final p in favs) {
          items.add(_PersonaCardItem(p));
        }
      }
    }
    for (final p in rest) {
      items.add(_PersonaCardItem(p));
    }
    return items;
  }
}

/// BATCH P2-ui (A): one lazily-built row in the virtualized Personas list.
abstract class _PersonaItem {
  const _PersonaItem();
  Widget build(AppStore store);
}

class _PersonaFavHeaderItem extends _PersonaItem {
  final int count;
  const _PersonaFavHeaderItem(this.count);

  @override
  Widget build(AppStore store) => _FavoritesHeader(
        count: count,
        expanded: store.personaFavoritesExpanded,
        onToggle: () => store
            .setPersonaFavoritesExpanded(!store.personaFavoritesExpanded),
      );
}

class _PersonaCardItem extends _PersonaItem {
  final Persona persona;
  const _PersonaCardItem(this.persona);

  @override
  Widget build(AppStore store) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: _PersonaCard(store: store, persona: persona),
      );
}

class _PersonaCard extends StatelessWidget {
  final AppStore store;
  final Persona persona;
  const _PersonaCard({required this.store, required this.persona});

  @override
  Widget build(BuildContext context) {
    final p = persona;
    final active = p.id == store.activePersonaId;
    final tokenLabel = formatTokenCount(approxTokensForPersona(p));
    final hasBody = (p.tagline?.isNotEmpty ?? false) ||
        p.description.isNotEmpty;
    return Card(
      child: ListTile(
        leading: AvatarBubble(
            dataUrl: p.avatar,
            fallback: p.name,
            tappableLightbox: true,
            // Non-destructive Recrop: tap opens the whole original, not the crop.
            fullImageUrl: p.avatarOriginal),
        title: Row(
          children: [
            Flexible(
              child: Text(p.name,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            if (active) ...[
              const SizedBox(width: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: EmberColors.primary.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                      color: EmberColors.primary.withValues(alpha: 0.5)),
                ),
                child: Text(
                  'DEFAULT',
                  style: TextStyle(
                    color: EmberColors.primary,
                    fontSize: 10,
                    fontWeight: FontWeight.w700,
                    letterSpacing: 0.6,
                  ),
                ),
              ),
            ],
          ],
        ),
        subtitle: !hasBody && tokenLabel == null
            ? null
            : Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      (p.tagline ?? '').isNotEmpty
                          ? p.tagline!
                          : p.description.split('\n').first.trim(),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: EmberColors.textMid),
                    ),
                  ),
                  if (tokenLabel != null) ...[
                    const SizedBox(width: 6),
                    Padding(
                      padding: const EdgeInsets.only(top: 1),
                      child: Text(
                        tokenLabel,
                        style: TextStyle(
                          color: EmberColors.textDim,
                          fontSize: 10,
                          fontFeatures: [FontFeature.tabularFigures()],
                        ),
                      ),
                    ),
                  ],
                ],
              ),
        trailing: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            IconButton(
              icon: Icon(
                p.favorite ? Icons.star : Icons.star_border,
                color: p.favorite ? EmberColors.primary : EmberColors.textMid,
                size: 20,
              ),
              tooltip: p.favorite
                  ? 'Remove from favorites'
                  : 'Add to favorites',
              onPressed: () => store.togglePersonaFavorite(p.id),
              visualDensity: VisualDensity.compact,
            ),
            IconButton(
              icon: Icon(Icons.more_vert,
                  color: EmberColors.textMid),
              tooltip: 'Persona actions',
              onPressed: () => _showPersonaMenu(context, store, p),
              visualDensity: VisualDensity.compact,
            ),
          ],
        ),
        // Wave CY.18.129: row TAP now opens the persona DETAILS view
        // (parity with the character details sheet — avatar + fields +
        // gallery strip, no "Start chat"). The kebab (trailing more_vert)
        // still opens the action menu (edit / set default / delete).
        onTap: () => showPersonaDetailsSheet(context, personaId: p.id),
      ),
    );
  }
}

void _showCharacterMenu(BuildContext context, AppStore store, Character c) {
  // Most recent chat with this character as the primary — drives Continue.
  final existingChat = () {
    final mine = store.chats
        .where((ch) => ch.primaryCharacterId == c.id)
        .toList()
      ..sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
    return mine.isEmpty ? null : mine.first;
  }();

  showMenuSheet<void>(
    context,
    itemsBuilder: (sheet) => [
          ListTile(
            leading: Icon(Icons.add_comment_outlined,
                color: EmberColors.primary),
            title: const Text('Start new chat'),
            onTap: () {
              Navigator.pop(sheet);
              startNewChatWithPersonaPrompt(context, c);
            },
          ),
          // 2026-07-05 (Gui): group creation reachable from the library
          // kebab too — mirrors the details sheet's "Group" action (same
          // gate: someone else to group with).
          if (store.characters.length > 1)
            ListTile(
              leading:
                  Icon(Icons.groups_outlined, color: EmberColors.primary),
              title: const Text('Start group chat'),
              subtitle: Text(
                'Pick the whole cast up front — ${c.name} is already in.',
                style: TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                startNewGroupChat(context, c);
              },
            ),
          if (existingChat != null)
            ListTile(
              leading: Icon(Icons.play_arrow_rounded,
                  color: EmberColors.primary),
              title: const Text('Continue chat'),
              subtitle: Text(
                'Resume "${c.name}" — ${existingChat.messages.length} msgs.',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                Navigator.of(context).push(MaterialPageRoute(
                  builder: (_) => ChatScreen(chatId: existingChat.id),
                ));
              },
            ),
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('View details'),
            onTap: () {
              Navigator.pop(sheet);
              showCharacterDetailsSheet(context, characterId: c.id);
            },
          ),
          ListTile(
            leading: const Icon(Icons.face_outlined),
            title: const Text('Add as persona'),
            subtitle: Text(
              "Creates a persona with this character's name + avatar.",
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () {
              Navigator.pop(sheet);
              final p = store.convertCharacterToPersona(c);
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Persona "${p.name}" created.')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export as PNG card'),
            subtitle: Text(
              'chara_card_v2 PNG, ready to upload to botbooru / chub / share.',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () async {
              Navigator.pop(sheet);
              await _exportCharacterAsPng(context, c);
            },
          ),
          // 1.2.1: standard chara_card_v2 JSON alongside the PNG export —
          // no avatar required, so an avatarless card can still be shared.
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export as JSON card'),
            subtitle: Text(
              'chara_card_v2 JSON, no avatar required.',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () async {
              Navigator.pop(sheet);
              await _exportCharacterAsJson(context, c);
            },
          ),
          // In-app Duplicate — mirrors the lorebook "Copy as new" / preset
          // "Copy (editable)" convention. Non-destructive, so no confirm
          // dialog; a fresh "<name> (copy)" appears right after the original.
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Duplicate'),
            subtitle: Text(
              'Make an editable copy of this character.',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () {
              Navigator.pop(sheet);
              final clone = store.duplicateCharacter(c.id);
              if (clone == null) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Duplicated as "${clone.name}".')),
              );
            },
          ),
          // Wave CY.18.38: "Add to folder" via a sub-sheet listing the
          // user's folders + a "create new" option.
          ListTile(
            leading: const Icon(Icons.folder_open_outlined),
            title: const Text('Add to folder…'),
            subtitle: Builder(builder: (_) {
              final memberOf = store.folders
                  .where((f) => f.characterIds.contains(c.id))
                  .map((f) => f.name)
                  .toList();
              if (memberOf.isEmpty) {
                return Text(
                  'Group this card with others.',
                  style: TextStyle(color: EmberColors.textMid, fontSize: 12),
                );
              }
              return Text(
                'In: ${memberOf.join(", ")}',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 12),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
            }),
            onTap: () async {
              Navigator.pop(sheet);
              await _showAddToFolderSheet(context, store, c);
            },
          ),
          Divider(color: EmberColors.stroke),
          ListTile(
            leading: Icon(Icons.delete_outline,
                color: EmberColors.danger),
            title: Text('Delete character',
                style: TextStyle(color: EmberColors.danger)),
            onTap: () async {
              Navigator.pop(sheet);
              final ok = await confirmDelete(
                context,
                title: 'Delete "${c.name}"?',
                message:
                    'The character and every chat with them will be lost forever.',
              );
              if (!ok) return;
              store.removeCharacter(c.id);
            },
          ),
        ],
  );
}

void _showPersonaMenu(BuildContext context, AppStore store, Persona p) {
  final isActive = p.id == store.activePersonaId;
  showMenuSheet<void>(
    context,
    itemsBuilder: (sheet) => [
          // Wave CY.18.138: mirror the character kebab — lead with
          // "View details" (the persona details sheet, where the Edit
          // button offers "Edit with AI" / "Edit manually") instead of
          // surfacing the two edit flows directly in the menu.
          ListTile(
            leading: const Icon(Icons.info_outline),
            title: const Text('View details'),
            onTap: () {
              Navigator.pop(sheet);
              showPersonaDetailsSheet(context, personaId: p.id);
            },
          ),
          if (!isActive)
            ListTile(
              leading: Icon(Icons.check_circle_outline,
                  color: EmberColors.primary),
              title: const Text('Set as default'),
              onTap: () {
                Navigator.pop(sheet);
                store.setActivePersona(p.id);
              },
            ),
          // Wave CY.18.250: export a persona as a chara_card_v2 PNG (mirrors
          // the character "Export as PNG card"). Builds a card from the
          // persona's shareable fields + its gallery.
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export as PNG'),
            subtitle: Text(
              'chara_card_v2 PNG (+ gallery), ready to share or re-import.',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () async {
              Navigator.pop(sheet);
              await _exportPersonaAsPng(context, p);
            },
          ),
          // 1.2.1: standard chara_card_v2 JSON alongside the PNG export —
          // no avatar required.
          ListTile(
            leading: const Icon(Icons.download_outlined),
            title: const Text('Export as JSON card'),
            subtitle: Text(
              'chara_card_v2 JSON, no avatar required.',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () async {
              Navigator.pop(sheet);
              await _exportPersonaAsJson(context, p);
            },
          ),
          // In-app Duplicate — same convention as the character menu.
          ListTile(
            leading: const Icon(Icons.copy_outlined),
            title: const Text('Duplicate'),
            subtitle: Text(
              'Make an editable copy of this persona.',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12),
            ),
            onTap: () {
              Navigator.pop(sheet);
              final clone = store.duplicatePersona(p.id);
              if (clone == null) return;
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(content: Text('Duplicated as "${clone.name}".')),
              );
            },
          ),
          Divider(color: EmberColors.stroke),
          ListTile(
            leading: Icon(Icons.delete_outline, color: EmberColors.danger),
            title: Text('Delete persona',
                style: TextStyle(color: EmberColors.danger)),
            onTap: () async {
              Navigator.pop(sheet);
              // Wave CY.1: special-case deletion of the default persona —
              // without an active persona, every new chat opens with no
              // user identity and Impersonate Me has nothing to lean on.
              final isDefault = p.id == store.activePersonaId;
              final ok = await confirmDelete(
                context,
                title: isDefault
                    ? 'Delete default persona "${p.name}"?'
                    : 'Delete "${p.name}"?',
                message: isDefault
                    ? 'This is your default persona. After deleting, new chats '
                        'will have no default persona until you set another one. '
                        'Existing chats fall back to whichever persona was active '
                        'when they were created. Are you sure?'
                    : 'The persona will be removed. Existing chats will fall '
                        'back to the default persona.',
              );
              if (!ok) return;
              store.removePersona(p.id);
            },
          ),
        ],
  );
}

Future<void> _showImportCharacterDialog(BuildContext context) async {
  final urlCtl = TextEditingController();
  final store = context.read<AppStore>();
  String? err;
  bool busy = false;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Import character'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Paste a chub.ai / botbooru.com character page, or a direct '
              'link to a Tavern Card v2 file (.png or .json) — e.g. a '
              'catbox or pixeldrain link.',
              style: TextStyle(color: EmberColors.textMid),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: urlCtl,
              autofocus: true,
              decoration: const InputDecoration(
                hintText: 'https://files.catbox.moe/abc123.png',
              ),
            ),
            if (err != null) ...[
              const SizedBox(height: 8),
              Text(err!, style: TextStyle(color: EmberColors.danger)),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: busy ? null : () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: busy
                ? null
                : () async {
                    setState(() {
                      busy = true;
                      err = null;
                    });
                    try {
                      // Manual URL import — the user is typing the URL
                      // themselves, so we don't demand a curated allowlist,
                      // but we DO require https, run an SSRF guard, and
                      // surface the card text for review before saving.
                      final input = urlCtl.text.trim();
                      final parsed = Uri.parse(input);
                      if (parsed.scheme != 'https') {
                        throw 'Only https:// URLs are accepted.';
                      }
                      // Wave CT: try the community-page resolver first so a
                      // chub.ai / botbooru.com page URL works, not just a
                      // direct file link. When the resolver already POSTed
                      // and got bytes back (chub case), reuse them instead
                      // of a follow-up GET — chub's endpoint only answers
                      // POST.
                      final resolved = await resolveCommunityUrl(input);
                      final Uint8List bytes;
                      // The URL we'll actually parse (extension picks the
                      // parser). Defaults to the resolved target / the
                      // pasted URL.
                      final Uri target = resolved?.pngUrl ?? parsed;
                      if (resolved?.bytes != null) {
                        bytes = resolved!.bytes!;
                      } else {
                        if (target.scheme != 'https') {
                          throw 'Only https:// URLs are accepted.';
                        }
                        // SSRF gate for the "paste ANY direct link" case.
                        // A botbooru/chub page resolves to a known CDN host
                        // and is always allowed. A direct PNG/JSON link
                        // (source == 'direct') is allowed when its host is
                        // on the curated file-host allowlist OR — for a
                        // truly arbitrary link — when the host is PUBLIC
                        // (isPublicHost blocks localhost / loopback /
                        // private / link-local IPv4+IPv6). This stops a
                        // pasted link from making the app fetch an internal
                        // address.
                        final host = target.host.toLowerCase();
                        final allowed = resolved != null &&
                                resolved.source != 'direct'
                            ? true
                            : (kCardFileHostAllowlist.contains(host) ||
                                isPublicHost(host));
                        if (!allowed) {
                          throw "Couldn't import — that link points to a "
                              'private or local address.';
                        }
                        // Wave CY.18.255 (audit FIX 4): DNS-rebinding guard.
                        // `isPublicHost` above is a literal-IP + name check
                        // that does NOT resolve DNS, so a hostname that
                        // RESOLVES to 127.0.0.1 / 169.254.169.254 / an RFC1918
                        // address would slip past it. Before fetching, resolve
                        // the host and reject if ANY resolved address is
                        // non-public. kIsWeb-gated (no dart:io on web; the
                        // typed-import path is native/desktop). The botbooru/
                        // chub CDN branch (`allowed == true` via a non-direct
                        // resolved source) still passes through this guard —
                        // those CDNs resolve to public addresses anyway.
                        if (!kIsWeb) {
                          await _assertHostResolvesPublic(target.host);
                        }
                        // Disable redirects + cap the body: a 3xx from the
                        // host could bounce us to an internal address
                        // (defeating the public-host check above) and an
                        // unbounded body is an OOM vector.
                        final resp = await fetchCappedNoRedirect(target);
                        if (resp.statusCode >= 400) {
                          // Wave CY.3: friendly 429/Retry-After,
                          // mostly to surface botbooru's rate limit
                          // as something other than "HTTP 429".
                          throw describeHttpFailure(resp,
                              host: friendlyHostName(target));
                        }
                        bytes = resp.bodyBytes;
                      }
                      // Audit 2026-06-04 [import-1-09]: pick the parser by
                      // SNIFFING the bytes, not the URL extension. The old
                      // `.json`-suffix test missed a RisuRealm `json-v2`
                      // download URL (no `.json` suffix) and any JSON served
                      // from an extension-less link. `parseCharaCard` reads
                      // the PNG signature and otherwise UTF-8-decodes the JSON
                      // (non-ASCII safe). A blob that isn't a valid v1/v2 card
                      // throws here and the import fails (we never save
                      // garbage).
                      final CharaCard card;
                      try {
                        card = parseCharaCard(bytes);
                      } catch (e) {
                        throw 'Not a valid character card: $e';
                      }
                      final character = characterFromCharaCard(card);
                      // Wave CY.18.141: BotBooru gallery auto-import REMOVED
                      // (owner's request: don't call our API, use our frontend).
                      // A typed URL has no live frontend to read, so no gallery
                      // is offered here.
                      const List<String> galleryUrls = [];
                      if (!ctx.mounted) return;
                      final choice = await confirmCardImport(
                        ctx,
                        character,
                        galleryCount: galleryUrls.length,
                      );
                      if (!choice.import) {
                        setState(() => busy = false);
                        return;
                      }
                      if (choice.withGallery) {
                        character.gallery =
                            await downloadGalleryImages(galleryUrls);
                      }
                      // Wave CA: handle embedded character_book.
                      if (!ctx.mounted) return;
                      await handleEmbeddedBookForCharacter(
                        context: ctx,
                        store: store,
                        character: character,
                        charaCardData: card.card,
                      );
                      // B-2 / H-6: externalise the inline avatar so it
                      // persists as a pyre:// ref, not inline base64.
                      await externalizeCharacterImages(character);
                      store.addCharacter(character);
                      if (ctx.mounted) Navigator.pop(ctx);
                    } catch (e) {
                      setState(() {
                        err = e.toString();
                        busy = false;
                      });
                    }
                  },
            child: busy
                ? const SizedBox(
                    height: 16,
                    width: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Import'),
          ),
        ],
      ),
    ),
  );
  urlCtl.dispose(); // H-3: dispose the URL-import controller on dialog close.
}

/// Wave CY.18.255 (audit FIX 4): DNS-rebinding SSRF guard for the typed
/// "Import by URL" path.
///
/// `isPublicHost` (resolvers.dart) is a pure literal-IP + name check that
/// does NOT resolve DNS, so a hostname pointing at an internal address
/// would pass it. This resolves [host] and throws if ANY resolved address
/// is non-public (loopback / RFC1918 / link-local / ULA, including the
/// cloud metadata endpoint 169.254.169.254). We reuse the exact existing
/// IP classification by feeding each resolved address's numeric string
/// back through `isPublicHost` (which routes literal IPs to its IPv4/IPv6
/// classifiers). Native-only — callers gate on `!kIsWeb`.
///
/// A lookup failure (offline / unknown host) is left to the subsequent
/// fetch to surface as a normal network error — we only HARD-block when a
/// resolved address is provably internal.
Future<void> _assertHostResolvesPublic(String host) async {
  final List<InternetAddress> addresses;
  try {
    addresses = await InternetAddress.lookup(host);
  } catch (_) {
    // Couldn't resolve — don't block on the guard; the capped fetch will
    // fail with a real network error if the host is truly unreachable.
    return;
  }
  for (final addr in addresses) {
    if (!isPublicHost(addr.address)) {
      throw "Couldn't import — that link resolves to a private or local "
          'address.';
    }
  }
}

// ---------------------------------------------------------------------------
// Wave CY.18.38 — folder management + tag picker + add-to-folder sheets

/// Bottom sheet listing the user's folders. Tap to make a folder the
/// active filter; kebab on each folder for rename/delete; "+ New
/// folder" at the bottom. Closing the sheet without a selection
/// leaves `charFolderId` unchanged.
Future<void> _showFoldersSheet(BuildContext context, AppStore store) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheet) {
      return StatefulBuilder(builder: (sheetCtx, setSheetState) {
        final folders = store.folders;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Folders',
                          style: TextStyle(
                            color: EmberColors.textHigh,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                      ),
                    ],
                  ),
                ),
                if (folders.isEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Text(
                      'No folders yet. Create one to group characters.',
                      style: TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        ListTile(
                          leading: Icon(Icons.folder_open,
                              color: EmberColors.textMid),
                          title: const Text('All characters'),
                          subtitle: Text(
                            '${store.characters.length} card${store.characters.length == 1 ? "" : "s"}',
                            style: const TextStyle(fontSize: 11),
                          ),
                          trailing: store.charFolderId == null
                              ? Icon(Icons.check_circle,
                                  color: EmberColors.primary, size: 18)
                              : null,
                          onTap: () {
                            store.setCharFolderId(null);
                            Navigator.of(sheetCtx).pop();
                          },
                        ),
                        Divider(height: 1, color: EmberColors.stroke),
                        for (final f in folders)
                          ListTile(
                            leading: Icon(Icons.folder,
                                color: EmberColors.primary),
                            title: Text(f.name),
                            subtitle: Text(
                              '${f.characterIds.length} card${f.characterIds.length == 1 ? "" : "s"}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            trailing: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (store.charFolderId == f.id)
                                  Padding(
                                    padding: EdgeInsets.only(right: 6),
                                    child: Icon(Icons.check_circle,
                                        color: EmberColors.primary,
                                        size: 18),
                                  ),
                                PopupMenuButton<String>(
                                  tooltip: 'Folder actions',
                                  onSelected: (action) async {
                                    if (action == 'rename') {
                                      final newName =
                                          await _promptFolderName(
                                              context, initial: f.name);
                                      if (newName != null &&
                                          newName.trim().isNotEmpty) {
                                        store.renameFolder(f.id, newName);
                                        setSheetState(() {});
                                      }
                                    } else if (action == 'delete') {
                                      final ok = await confirmDelete(
                                        context,
                                        title: 'Delete folder "${f.name}"?',
                                        message:
                                            'Characters in this folder stay '
                                            'in your library. Only the '
                                            'folder grouping is removed.',
                                      );
                                      if (ok) {
                                        store.deleteFolder(f.id);
                                        setSheetState(() {});
                                      }
                                    }
                                  },
                                  itemBuilder: (_) => const [
                                    PopupMenuItem(
                                        value: 'rename',
                                        child: Text('Rename')),
                                    PopupMenuItem(
                                        value: 'delete',
                                        child: Text('Delete')),
                                  ],
                                ),
                              ],
                            ),
                            onTap: () {
                              store.setCharFolderId(f.id);
                              Navigator.of(sheetCtx).pop();
                            },
                          ),
                      ],
                    ),
                  ),
                Divider(height: 1, color: EmberColors.stroke),
                ListTile(
                  leading: Icon(Icons.add,
                      color: EmberColors.primary),
                  title: const Text('New folder'),
                  onTap: () async {
                    final name = await _promptFolderName(context);
                    if (name != null && name.trim().isNotEmpty) {
                      store.createFolder(name);
                      setSheetState(() {});
                    }
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      });
    },
  );
}

/// Prompts the user for a folder name. Returns null on cancel, or
/// the trimmed name on confirm. Optional `initial` pre-fills the
/// field (rename flow).
Future<String?> _promptFolderName(BuildContext context,
    {String initial = ''}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text(initial.isEmpty ? 'New folder' : 'Rename folder'),
      content: TextField(
        controller: controller,
        autofocus: true,
        decoration: const InputDecoration(hintText: 'e.g. "Bathhouse OCs"'),
        onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
          child: const Text('Save'),
        ),
      ],
    ),
  );
  controller.dispose();
  if (result == null || result.isEmpty) return null;
  return result;
}

/// Tag picker bottom sheet. Lists every unique tag across the user's
/// characters with usage count, lets them toggle multiple at once,
/// commits to the store on apply. The Characters list reacts via
/// `context.watch` and re-renders with the new filter active.
Future<void> _showTagPickerSheet(
    BuildContext context, AppStore store) async {
  // Aggregate tag usage across the library.
  final usage = <String, int>{};
  for (final c in store.characters) {
    for (final t in c.tags) {
      final norm = t.trim();
      if (norm.isEmpty) continue;
      usage[norm] = (usage[norm] ?? 0) + 1;
    }
  }
  if (usage.isEmpty) {
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('No tags found on any character yet.')),
    );
    return;
  }
  final allTags = usage.keys.toList()
    ..sort((a, b) => usage[b]!.compareTo(usage[a]!));
  final initiallySelected = store.charSelectedTags.toSet();

  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheet) {
      final draft = Set<String>.from(initiallySelected);
      return StatefulBuilder(builder: (sheetCtx, setSheetState) {
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.8,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Filter by tags',
                          style: TextStyle(
                            color: EmberColors.textHigh,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: EdgeInsets.fromLTRB(20, 0, 20, 6),
                  child: Text(
                    'Tap to select. Multiple selections AND together '
                    '(card must have all selected tags).',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 11.5,
                      height: 1.4,
                    ),
                  ),
                ),
                Flexible(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
                    child: Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: [
                        for (final t in allTags)
                          FilterChip(
                            label: Text(
                              '#$t  ${usage[t]}',
                              style: const TextStyle(fontSize: 11.5),
                            ),
                            selected: draft.contains(t),
                            onSelected: (_) {
                              setSheetState(() {
                                if (draft.contains(t)) {
                                  draft.remove(t);
                                } else {
                                  draft.add(t);
                                }
                              });
                            },
                            visualDensity: VisualDensity.compact,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                            padding: EdgeInsets.zero,
                          ),
                      ],
                    ),
                  ),
                ),
                Divider(height: 1, color: EmberColors.stroke),
                Padding(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 16, vertical: 10),
                  child: Row(
                    children: [
                      TextButton(
                        onPressed: () =>
                            setSheetState(() => draft.clear()),
                        child: const Text('Clear all'),
                      ),
                      const Spacer(),
                      ElevatedButton(
                        onPressed: () {
                          // Replace the active selection with the
                          // sheet's draft set in one bump.
                          store.clearCharSelectedTags();
                          for (final t in draft) {
                            store.toggleCharSelectedTag(t);
                          }
                          Navigator.of(sheetCtx).pop();
                        },
                        child: Text('Apply (${draft.length})'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      });
    },
  );
}

/// Sheet that pops from the kebab's "Add to folder…" action. Lists
/// every folder with a checkbox showing whether the character is
/// already inside; tapping toggles membership. "+ Create new folder"
/// at the bottom.
Future<void> _showAddToFolderSheet(
    BuildContext context, AppStore store, Character c) async {
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (sheet) {
      return StatefulBuilder(builder: (sheetCtx, setSheetState) {
        final folders = store.folders;
        return SafeArea(
          top: false,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(sheetCtx).size.height * 0.75,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 12, 4),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          'Add "${c.name}" to folder',
                          style: TextStyle(
                            color: EmberColors.textHigh,
                            fontWeight: FontWeight.w600,
                            fontSize: 16,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 18),
                        onPressed: () => Navigator.of(sheetCtx).pop(),
                      ),
                    ],
                  ),
                ),
                if (folders.isEmpty)
                  Padding(
                    padding: EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: Text(
                      'No folders yet. Create one below to group cards.',
                      style: TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 13,
                        height: 1.45,
                      ),
                    ),
                  )
                else
                  Flexible(
                    child: ListView(
                      shrinkWrap: true,
                      children: [
                        for (final f in folders)
                          CheckboxListTile(
                            value: f.characterIds.contains(c.id),
                            onChanged: (v) {
                              if (v == true) {
                                store.addCharacterToFolder(f.id, c.id);
                              } else {
                                store.removeCharacterFromFolder(f.id, c.id);
                              }
                              setSheetState(() {});
                            },
                            title: Text(f.name),
                            subtitle: Text(
                              '${f.characterIds.length} card${f.characterIds.length == 1 ? "" : "s"}',
                              style: const TextStyle(fontSize: 11),
                            ),
                            controlAffinity:
                                ListTileControlAffinity.leading,
                          ),
                      ],
                    ),
                  ),
                Divider(height: 1, color: EmberColors.stroke),
                ListTile(
                  leading: Icon(Icons.add,
                      color: EmberColors.primary),
                  title: const Text('Create new folder + add'),
                  onTap: () async {
                    final name = await _promptFolderName(context);
                    if (name == null || name.trim().isEmpty) return;
                    final f = store.createFolder(name);
                    store.addCharacterToFolder(f.id, c.id);
                    setSheetState(() {});
                  },
                ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      });
    },
  );
}
