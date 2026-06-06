// AI-assisted character builder.
//
// Architecture (Wave H):
//
//   - One CreatorSession in AppStore per in-progress card. The drawer
//     on the left lists them; each row's title is derived from the
//     canvas's `name` field (so once the model names the character,
//     the session in the drawer renames itself). Sessions persist.
//
//   - Single chat screen with a CANVAS toggle in the app bar. The
//     canvas reflects the current chara_card_v2 `data` block AT ALL
//     TIMES — empty fields are shown so the user can see what's still
//     missing. There is no "Generate card now" button.
//
//   - The conversational architect phase only chats; the card itself is
//     produced by the deterministic structured-JSON build pipeline
//     (`creator_build.dart`), fired by the `[[BUILD_SHEET]]` marker or
//     the `/build` command. (The old per-turn `kCardUpdaterPrompt`
//     canvas-updater was retired with the structured build.)
//
//   - Single `+` button replaces the three separate attach icons. Tap
//     it to pick image / card / document. Same handlers as before.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart'
    show Clipboard, ClipboardData, LogicalKeyboardKey, TextInputAction;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/models.dart';
import '../services/attachment_store.dart';
import '../services/chat_api.dart';
import '../services/chat_prompt_builder.dart';
import '../services/creator_cascade.dart';
// Wave CY.18.231 (Creator Structured Build): the deterministic JSON
// pipeline that replaces the `<<SHEET>>`-marker cascade. `CreatorMode`
// lives only in creator_schema.dart (this file uses `CreatorTurn` from
// chat_prompt_builder.dart, a different type — no collision), but we
// import it with an `as cs` prefix anyway for an unambiguous, future-proof
// call site (cs.CreatorMode, cs.batchesFor, …).
import '../services/creator_schema.dart' as cs;
import '../services/creator_render.dart';
import '../services/creator_build.dart';
import '../services/creator_build_prompts.dart';
import '../services/creator_json.dart'
    show extractJsonObject, extractJsonAfterReasoning;
import '../services/card_import.dart';
import '../services/image_describe.dart';
import '../services/image_resize.dart';
import '../services/generation_keepalive.dart';
import '../services/png_encoder.dart';
import '../services/png_parser.dart';
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/chat_text.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/lorebook_binding_section.dart';
// Wave CQ: avatar_crop_screen + character_edit_screen no longer
// referenced from this file. The forced crop was removed (image goes
// in as-is) and the "Save & open editor" save-action was retired.
import 'character_creator_help_screen.dart';
import 'chat_picker_screens.dart';

/// Whether the Creator chat input should be LOCKED for a session in the
/// given ([mode], [flow]) state.
///
/// The input is locked while the user hasn't chosen what to build yet:
///   - `mode == null`            → still on the greeting / mode picker.
///   - non-'edit' mode, no flow  → mode chosen but flow not yet picked.
///
/// 'edit' mode (character "Edit with AI", and — post creator-01 fix —
/// persona "Edit with AI", which seeds `flow = 'freeform'`) is NEVER
/// locked: the user types a change immediately. Pure + unit-tested so the
/// persona-edit dead-end (mode='persona', flow=null → permanently locked)
/// can't silently regress.
bool creatorInputLocked({required String? mode, required String? flow}) {
  if (mode == null) return true;
  if (mode != 'edit' && flow == null) return true;
  return false;
}

class CharacterAssistantScreen extends StatefulWidget {
  /// Wave CS: when set, the screen opens a fresh Creator session
  /// pre-loaded with this character's data (canvas filled, contextual
  /// assistant greeting). Saves UPDATE this character in place rather
  /// than creating a new one. Used by the "Edit with AI" entry point
  /// in the Characters tab.
  final String? editingCharacterId;

  /// Persona Creator: when true, the screen opens a fresh session in
  /// PERSONA mode (building the user's self-insert), skipping the
  /// character/scenario chooser. Used by the "Build with AI" entry on
  /// the Personas tab.
  final bool personaMode;

  /// Persona Creator: when set, opens a fresh PERSONA-mode session
  /// pre-loaded with this persona's fields. Saves UPDATE this persona
  /// in place. Used by the "Edit with AI" entry on a persona. Implies
  /// persona mode regardless of [personaMode].
  final String? editingPersonaId;

  const CharacterAssistantScreen({
    super.key,
    this.editingCharacterId,
    this.personaMode = false,
    this.editingPersonaId,
  });

  @override
  State<CharacterAssistantScreen> createState() =>
      _CharacterAssistantScreenState();
}

/// One attachment the user is staging next to the input bar.
///
/// Lives ONLY in screen state; once the user hits send it becomes a
/// [CreatorAttachment] on the persisted message. For images, the
/// vision analysis runs in the background — [extracted] is null until
/// it completes (or [error] is set if the call failed). The chip
/// shows a spinner overlay while [analysing] is non-null.
class _PendingAttachment {
  final String kind; // 'image' | 'card' | 'doc'
  final String filename;
  /// Raw image bytes (already downscaled to ≤1280px JPEG). Held in
  /// memory ONLY while staged — the chip renders directly from
  /// these via Image.memory, skipping the base64 round-trip that
  /// was making 5MB attaches take seconds on the main thread. Once
  /// the user sends, these get encoded into [CreatorAttachment]'s
  /// data URL for persistence.
  Uint8List? imageBytes;
  /// Material to feed the LLM at send time — vision profile (images),
  /// chara_card_v2 JSON pretty-print (cards), document text (docs).
  /// Null while a vision call is still in flight.
  String? extracted;
  /// In-flight vision call. Awaited at send time if the user hits
  /// send before it finishes. Null for card / doc (filled synchronously).
  Future<void>? analysing;
  /// Last error from the vision API, if it failed. Allows the user to
  /// dismiss the chip and continue or just send the image without
  /// the structured profile.
  String? error;

  _PendingAttachment({
    required this.kind,
    required this.filename,
    this.imageBytes,
    this.extracted,
  });
}

class _CharacterAssistantScreenState
    extends State<CharacterAssistantScreen> {
  /// Wave CV: the opening message now offers a CHOICE — character vs
  /// scenario — surfaced as two buttons rendered inline under this
  /// message. The chat input is locked until the user picks. After the
  /// pick, [_chosenFlowGreeting] is appended explaining the flow
  /// specific to that mode.
  ///
  /// This message also acts as priming for the model when the model
  /// finally reads it back (it sits as the first assistant turn).
  /// Keeping it short and choice-focused — the deeper flow detail comes
  /// in the follow-up greeting once the mode is locked.
  static const String _greeting =
      "Hey — I'm Pyre's Character Creator. I can build two things with "
      "you:\n\n"
      "  • **A character** — one persona for roleplay: name, look, "
      "voice, personality, and the contradictions that make them feel "
      "real.\n"
      "  • **A scenario** — a whole setting with a narrator that voices "
      "its NPCs, built around the world, the cast, and the opening "
      "scene.\n\n"
      "Pick one below — I focus on one at a time, since the two need "
      "pretty different cards.\n\n"
      "**Heads-up on timing:** once you say go, I write the whole card "
      "in one pass — usually **3-5 minutes** depending on your "
      "provider. The app isn't frozen, it's working; keep it open or "
      "minimize it (Pyre keeps generating in the background).";

  /// Wave CY.18.101: the guided greetings (_characterFlowGreeting /
  /// _scenarioFlowGreeting) were removed with the guided flow. Only the
  /// freeform greetings below remain, shown directly by _chooseMode.

  /// Wave CY.18.27: freeform follow-up for the CHARACTER flow.
  /// Same block structure as guided, but no per-block pauses — the
  /// architect cascades through all required blocks in one go after
  /// the user signals build readiness.
  static const String _characterFreeformGreeting =
      "Locked in on a **character**. Here's how it works:\n\n"
      "First we just talk through who we're making — name, vibe, age, "
      "looks, the little contradictions that make them feel real. When "
      "you're ready (or I'll nudge you once there's enough to go on), "
      "say the word and I'll write the whole card in one go — you "
      "don't have to confirm anything along the way.\n\n"
      "**Heads-up on timing:** the full write-up usually takes "
      "**3-5 minutes** depending on your provider — I'm composing the "
      "entire card without stopping for input. Pyre keeps working in "
      "the background, so you can minimise the app or screen-off; just "
      "don't kill the process.\n\n"
      "Drop a name, a vibe, an image, a card, or a document — or just "
      "describe what's in your head and I'll find the angle.";

  /// Wave CY.18.27: freeform-mode follow-up for the SCENARIO flow.
  static const String _scenarioFreeformGreeting =
      "Locked in on a **scenario**. Here's how it works:\n\n"
      "First we talk through the premise, the tone, and who's in it. "
      "When you're ready, say the word (any language works) and I'll "
      "write the whole thing in one go — the world and its rules, the "
      "cast, the opening scene, and everything the narrator needs to "
      "run it. Want alternate openings? Just ask.\n\n"
      "**Heads-up on timing:** the full write-up usually takes "
      "**3-5 minutes** depending on your provider. Pyre keeps working "
      "in the background, so you can minimise the app safely — just "
      "don't kill the process.\n\n"
      "Drop a premise, a vibe, a reference, or a fragment of a scene "
      "— I'll pitch a tone, a place, and the first hook, and you tell "
      "me where to push.";

  /// Persona Creator: greeting for a fresh CREATE-a-persona session.
  /// A persona is the user's self-insert — kept light and personal.
  static const String _personaCreateGreeting =
      "Let's build your **persona** — that's *you* in the story, the "
      "\"you\" a character talks to. The persona gets a full sheet, "
      "just like a character: a real look, a voice, a personality, a "
      "history.\n\n"
      "Let's shape it together first — start anywhere: a name (or alter "
      "ego), a vibe, an appearance, how you talk. I'll ask one thing at "
      "a time. When it's looking right I'll check with you before "
      "building the sheet — or just say \"you decide\" and I'll run with "
      "it.";

  /// Persona Creator: greeting when EDITING an existing persona with AI.
  // creator-01 (mega audit 2026-06-04): dropped the "tap Apply changes"
  // instruction — that button was removed in Wave 242 and never existed
  // on this screen. Point at conversational readiness / /build, mirroring
  // the character Edit-with-AI greeting.
  static const String _personaEditGreeting =
      "I've loaded your persona — every field's in the Sheet. Tell me what "
      "you want to change (\"make me more sarcastic\", \"add that I'm a "
      "night-shift nurse\", \"rewrite how I talk\"). When you're ready, just "
      "say so (or type **/build**) and I'll rebuild the sheet with your "
      "change applied — everything else stays put.";

  final _scrollCtl = ScrollController();
  final _inputCtl = TextEditingController();
  final _inputFocus = FocusNode();
  final _scaffoldKey = GlobalKey<ScaffoldState>();

  /// Toggle: false = chat view, true = canvas view. Top-right button
  /// flips between them. The canvas is ALWAYS available — it just
  /// shows the current (possibly partial) sheet.
  bool _showCanvas = false;

  bool _generating = false;

  /// H-1: this screen's own outstanding GenerationKeepAlive(heavy) refs.
  /// Bumped by [_keepAliveStart] and dropped by [_keepAliveStop] so
  /// dispose() can release exactly what's still held when the user
  /// navigates away mid-stream. Cancelling the architect `async*`
  /// subscription fires neither onDone nor onError (the only places stop
  /// runs for it), so without this drain the global heavy refcount —
  /// and on Android the foreground service + notification — would stay
  /// up forever. The creator only ever uses the heavy keepalive.
  int _keepAliveHeld = 0;
  Future<void> _keepAliveStart() {
    _keepAliveHeld++;
    return GenerationKeepAlive.start(heavy: true);
  }

  void _keepAliveStop() {
    if (_keepAliveHeld > 0) {
      _keepAliveHeld--;
      unawaited(GenerationKeepAlive.stop(heavy: true));
    }
  }

  /// True while the structured canvas-update call is in flight (kicked
  /// off after every chat turn). Doesn't block the user from chatting,
  /// just shows a subtle indicator on the canvas tab.
  bool _updatingCanvas = false;
  String _streamBuffer = '';
  StreamSubscription<String>? _streamSub;
  /// Wave CY.18.44: generation counter for the active stream. Every time
  /// we create a new subscription (initial turn, continuation, retry,
  /// canvas updater) we bump this and capture it in the closure. Each
  /// callback (onData / onDone / onError) checks `gen == _streamGen`
  /// before mutating state. If the user tapped Stop and we started a
  /// new stream, the OLD stream's callbacks no-op cleanly instead of
  /// writing to the new stream's `_streamBuffer` / `reply` / setState.
  /// Pre-Wave a continuation could fire its `onDone` AFTER the user
  /// stopped + restarted, corrupting the new turn with the old turn's
  /// finish-reason sentinel + buffer state.
  int _streamGen = 0;

  /// The session we're editing right now. We always have one — created
  /// in initState if the store had none, or restored from
  /// activeCreatorSessionId if it did.
  String? _sessionId;

  /// Attachments staged for the NEXT message the user sends. The chip
  /// row above the text input renders these; [_send] flushes them
  /// into the outgoing CreatorMessage and clears the list.
  final List<_PendingAttachment> _pendingAttachments = [];

  /// True when the chat view is scrolled within ~60px of the bottom.
  /// Auto-scroll (per-chunk and on new messages) is suppressed when
  /// false — the user has scrolled up to read something and we
  /// shouldn't yank them away. A floating "→  pill restores the
  /// follow-bottom behaviour.
  bool _stickToBottom = true;

  /// Canvas keys that just changed (per the most recent updater
  /// call). Used by [_CanvasFieldsView] to highlight changed fields
  /// in amber for ~3s so the user can SEE what the updater touched.
  Set<String> _recentlyChangedCanvasKeys = const <String>{};
  Timer? _changedHighlightTimer;

  @override
  void initState() {
    super.initState();
    _scrollCtl.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrapSession());
  }

  /// Decide whether we're "at bottom" each time the scroll position
  /// changes. We DON'T setState if the value didn't change, otherwise
  /// the screen would rebuild every pixel of scroll.
  ///
  /// "At bottom" also covers the case where there's nothing to scroll
  /// at all (`maxScrollExtent` ≤ 60). Without that guard, a fresh
  /// session with just the greeting could transiently flag the user
  /// as off-bottom during initial layout and leave the "Jump to
  /// bottom" pill stuck on screen with nowhere to jump.
  void _onScroll() {
    if (!_scrollCtl.hasClients) return;
    final pos = _scrollCtl.position;
    final atBottom = pos.maxScrollExtent <= 60 ||
        pos.maxScrollExtent - pos.pixels < 60;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
    }
  }

  void _bootstrapSession() {
    final store = context.read<AppStore>();

    // Persona Creator — EDIT an existing persona with AI. Fresh session,
    // mode='persona', canvas pre-loaded from the persona.
    final personaEditId = widget.editingPersonaId;
    if (personaEditId != null) {
      Persona? persona;
      for (final x in store.personas) {
        if (x.id == personaEditId) {
          persona = x;
          break;
        }
      }
      if (persona != null) {
        final s = store.newCreatorSession();
        s.mode = 'persona';
        s.editingPersonaId = personaEditId;
        // creator-01 (mega audit 2026-06-04): seed flow='freeform' so the
        // input is NOT locked. `creatorInputLocked` locks any non-'edit'
        // mode whose flow is null, so leaving flow null here (the old
        // behaviour) made persona "Edit with AI" a permanent dead end —
        // greyed-out input, no flow chips (chips only render when mode is
        // null), no reachable unlock path. Like the character Edit-with-AI
        // session, edits are conversational + applied per-turn via /build;
        // freeform is the right flow (there is no cascade to auto-fire).
        s.flow = 'freeform';
        store.renameCreatorSession(s.id, persona.name);
        store.updateCreatorSessionCanvas(s.id, _personaToCanvas(persona));
        store.updateCreatorSessionMessages(s.id, [
          CreatorMessage(role: 'assistant', content: _personaEditGreeting),
        ]);
        setState(() {
          _sessionId = s.id;
          _showCanvas = false; // chat-first (Wave 114)
        });
        return;
      }
      // Persona missing (deleted between tap and mount) — fall through.
    }

    // Persona Creator — CREATE a new persona with AI. Fresh session,
    // mode='persona', flow='freeform' (the completeness cascade drives
    // the build), empty canvas, chat-first.
    if (widget.personaMode) {
      final s = store.newCreatorSession();
      s.mode = 'persona';
      s.flow = 'freeform';
      store.updateCreatorSessionMessages(s.id, [
        CreatorMessage(role: 'assistant', content: _personaCreateGreeting),
      ]);
      setState(() {
        _sessionId = s.id;
        _showCanvas = false; // chat-first (Wave 114)
      });
      return;
    }

    // Wave CS: "Edit with AI" entry — ALWAYS start a fresh session
    // pre-loaded with the target character's canvas and a contextual
    // greeting. Doesn't reuse `activeCreatorSession` because the user
    // is editing a specific character, not resuming a draft.
    final editId = widget.editingCharacterId;
    if (editId != null) {
      final character = store.characterById(editId);
      if (character != null) {
        final s = store.newCreatorSession();
        // Mutate the session in-place — the store holds the same
        // reference, and the subsequent updateCreatorSessionCanvas
        // call will _bump() so the mutation lands on disk.
        s.editingCharacterId = editId;
        // Wave CV: Edit with AI runs on the free-form editor prompt,
        // not the character/scenario block architects.
        s.mode = 'edit';
        store.renameCreatorSession(s.id, character.name);
        store.updateCreatorSessionCanvas(
            s.id, _characterToCanvas(character));
        store.updateCreatorSessionMessages(s.id, [
          CreatorMessage(
            role: 'assistant',
            content:
                'I\'ve loaded **${character.name}** — every field is in '
                'the sheet already. Tell me what you want to change '
                '(examples: "make her younger", "rewrite the scenario to '
                'be in a fantasy setting", "tone down the NSFW tags", '
                '"add a sister character to the background"). When you\'re '
                'ready, just say so (or type **/build**) and I\'ll rebuild '
                'the sheet with your change applied — everything else stays put.',
          ),
        ]);
        setState(() {
          _sessionId = s.id;
          // Wave CY.18.113: chat-first on open — even in Edit With AI
          // the greeting ("tell me what you want to change") and the
          // input box live in the chat, so that's the actionable
          // surface. The user taps "Sheet" (or the mini-sheet preview)
          // to see the loaded card. (Reverts Wave CY.18.16/.22's
          // sheet-first default.)
          _showCanvas = false;
        });
        return;
      }
      // Character missing (deleted between tap and screen mount) —
      // fall through to default behaviour.
    }
    var s = store.activeCreatorSession;
    if (s == null) {
      // No previous session — make one and seed the greeting.
      s = store.newCreatorSession();
      store.updateCreatorSessionMessages(s.id, [
        CreatorMessage(role: 'assistant', content: _greeting),
      ]);
      _prepopulateCreatorOnCanvas(store, s.id);
    } else if (s.messages.isEmpty) {
      // Session existed (e.g. drawer "+") but never got opened — seed.
      store.updateCreatorSessionMessages(s.id, [
        CreatorMessage(role: 'assistant', content: _greeting),
      ]);
      _prepopulateCreatorOnCanvas(store, s.id);
    } else {
      // Wave CY.18.23: migration for sessions created BEFORE Wave
      // CY.18.16 — those didn't get the runtime creator pre-fill at
      // bootstrap, so the canvas's `creator` field stays empty (or
      // worse, ends up with a literal `{{creator}}` from older
      // updater runs). Top it up lazily on first open — _prepopulate
      // is a no-op when the field already has a non-empty value, so
      // sessions that did inherit it via Wave CY.18.16 stay
      // untouched.
      _prepopulateCreatorOnCanvas(store, s.id);
    }
    setState(() {
      _sessionId = s!.id;
      // Wave CY.18.113: open on the chat, not the sheet. The sheet
      // starts empty and the chat (greeting + input) is where the user
      // actually acts — landing on a blank sheet read as confusing.
      // The "Sheet" toggle / mini-sheet preview switches over anytime.
      // (Reverts Wave CY.18.16's sheet-first default.)
      _showCanvas = false;
    });

  }

  /// Wave CY.18.16: runtime-injected creator name. The user's
  /// BotBooru username (set in More → BotBooru Profile) gets dropped
  /// into the canvas's `creator` field at session bootstrap so the
  /// Sheet panel shows it from turn 0 — and so the architect's
  /// canvas-state injection includes it on every turn, avoiding any
  /// risk of the model emitting a `Creator:` label that duplicates
  /// or overrides what the runtime owns. No-op if the user hasn't
  /// set a username yet OR the canvas already has one (e.g. Edit
  /// with AI sessions that loaded from an existing character).
  void _prepopulateCreatorOnCanvas(AppStore store, String sessionId) {
    final username = store.botbooruUsername.trim();
    if (username.isEmpty) return;
    CreatorSession? session;
    for (final s in store.creatorSessions) {
      if (s.id == sessionId) {
        session = s;
        break;
      }
    }
    if (session == null) return;
    final existing = session.canvas['creator'];
    if (existing is String) {
      final trimmed = existing.trim();
      // Wave CY.18.23: also treat a literal `{{creator}}` token as
      // "needs filling" — pre-Wave updater runs (Wave CL) wrote that
      // placeholder into the canvas, and the migrated user would
      // otherwise see the raw `{{creator}}` survive forever.
      if (trimmed.isNotEmpty && trimmed != '{{creator}}') return;
    }
    store.updateCreatorSessionCanvas(sessionId, {
      ...session.canvas,
      'creator': username,
    });
  }

  /// Wave CS: convert a Character into the canvas Map shape used by
  /// the Creator session. Mirrors the keys read by `_commitSave`'s
  /// `parseCharaCardJson` path — so a save right after load is a
  /// no-op round-trip. Avatar bytes stay on the Character record
  /// (canvas only holds the chara_card_v2 `data` block, no images).
  Map<String, dynamic> _characterToCanvas(Character c) {
    return <String, dynamic>{
      'name': c.name,
      if (c.tagline != null && c.tagline!.isNotEmpty) 'tagline': c.tagline,
      'description': c.description,
      'personality': c.personality,
      'scenario': c.scenario,
      'first_mes': c.firstMes,
      'mes_example': c.mesExample,
      'system_prompt': c.systemPrompt,
      'post_history_instructions': c.postHistoryInstructions,
      'alternate_greetings': List<String>.from(c.alternateGreetings),
      'tags': List<String>.from(c.tags),
      'creator': c.creator,
      'character_version': c.characterVersion,
      'creator_notes': c.creatorNotes,
      'extensions': Map<String, dynamic>.from(c.extensions),
    };
  }

  /// Persona Creator: map a Persona onto a creator canvas for "Edit with
  /// AI". Personas are simple — only name, description, dialogue
  /// examples (→ `mes_example`), and an optional tagline live on the
  /// sheet. The avatar is carried separately (prefilled into the save
  /// sheet, not the canvas, which holds no image bytes).
  Map<String, dynamic> _personaToCanvas(Persona p) {
    return <String, dynamic>{
      'name': p.name,
      'description': p.description,
      'mes_example': p.dialogueExamples,
      if (p.tagline != null && p.tagline!.isNotEmpty) 'tagline': p.tagline,
    };
  }

  @override
  void dispose() {
    // H-1: release any heavy keepalive refs this screen still holds.
    // Cancelling the architect subscription below never fires
    // onDone/onError (the only places _keepAliveStop runs for it), so
    // drain the counter here — otherwise the global heavy refcount + the
    // Android foreground service would stay alive forever. The loop drops
    // exactly what's outstanding (no over-decrement).
    while (_keepAliveHeld > 0) {
      _keepAliveStop();
    }
    _streamSub?.cancel();
    _changedHighlightTimer?.cancel();
    _scrollCtl.removeListener(_onScroll);
    _scrollCtl.dispose();
    _inputCtl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Helper: messages of the active session (or empty list if no
  /// session has been bootstrapped yet — only true for one frame).
  List<CreatorMessage> _sessionMessages(AppStore store) {
    final s = store.activeCreatorSession;
    return s?.messages ?? const <CreatorMessage>[];
  }

  Map<String, dynamic> _sessionCanvas(AppStore store) {
    final s = store.activeCreatorSession;
    return s?.canvas ?? const <String, dynamic>{};
  }

  /// True when a canvas field has been meaningfully filled by the
  /// updater (non-empty string / list / map). Empty defaults render
  /// as "—  in the canvas view.
  static bool _isFilled(dynamic v) {
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  // ── Creator sampling overrides ──────────────────────────────────
  //
  // Each creator API call has a different "shape" of expected output
  // and therefore wants different sampling. We can't change
  // ModelSettings in-place (it's the chat-side defaults too), so we
  // clone the user's settings via JSON round-trip and rewrite just
  // the fields we care about. Cheap — one tiny Map allocation per
  // turn — and keeps the chat-side defaults untouched.

  ModelSettings _creatorChatSettings(ModelSettings base) {
    return ModelSettings.fromJson(base.toJson())
      ..temperature = base.creatorTemperature
      ..maxTokens = base.creatorMaxTokens;
  }

  /// H-11: vision output-token FLOOR. A clinical single-character profile
  /// runs ~1-1.5k tokens, but a 3-character ENSEMBLE (GROUP COMPOSITION +
  /// CHARACTER A/B/C + GROUP DYNAMICS + UNCERTAINTIES + NEXT) can run
  /// 2.5-4k, and on a reasoning model the separated `<think>` channel adds
  /// more on top. The vision call borrows `creatorMaxTokens`, which the
  /// user can drag as low as 1024 — well under an ensemble's needs — and
  /// there is DELIBERATELY no continuation loop (reverted in Wave 117). So
  /// we clamp vision's cap UP to a generous floor while still honouring a
  /// higher user setting. 8192 comfortably covers a 3-char ensemble plus
  /// reasoning overhead without capping a user who set creatorMaxTokens
  /// higher for heavy-reasoning models.
  static const int _kVisionMaxTokensFloor = 8192;

  ModelSettings _visionSettings(ModelSettings base) {
    final cap = base.creatorMaxTokens < _kVisionMaxTokensFloor
        ? _kVisionMaxTokensFloor
        : base.creatorMaxTokens;
    return ModelSettings.fromJson(base.toJson())
      ..temperature = base.visionTemperature
      ..maxTokens = cap;
  }

  void _scrollToBottom({bool force = false}) {
    // Respect manual scroll: if the user dragged away from the bottom,
    // don't yank them back during streaming. The floating "→ Jump to
    // bottom" pill lets them re-enable follow.
    if (!force && !_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      if (_generating) {
        _scrollCtl.jumpTo(_scrollCtl.position.maxScrollExtent);
      } else {
        _scrollCtl.animateTo(
          _scrollCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  void _persistMessages(AppStore store, List<CreatorMessage> messages) {
    final id = _sessionId;
    if (id == null) return;
    store.updateCreatorSessionMessages(id, messages);
  }

  // ---------------------------------------------------------------------------
  // Wave CY.18.231 — Creator Structured Build
  //
  // The deterministic structured-JSON pipeline (creator_build.dart). Fired BY
  // MESSAGE (Wave CY.18.242): when the architect emits the `[[BUILD_SHEET]]`
  // marker (auto-fired in onDone) or the user types `/build` — NOT inline after
  // each chat turn, and no longer behind a floating button.
  // For each batch of card fields it asks the model (JSON-object response
  // format) to return that batch as one JSON object, then renders the whole
  // card deterministically (creator_render.dart) into the canvas. There is NO
  // completeness loop / SHEET-marker cascade — completeness is guaranteed by
  // the batch maps; absent fields surface as a soft missing-required note.

  /// Map the session's mode STRING to the structured-build enum. Returns null
  /// for the modes this build does NOT handle ('edit' / null).
  cs.CreatorMode? _structuredModeFromString(String? m) {
    switch (m) {
      case 'character':
        return cs.CreatorMode.character;
      case 'scenario':
        return cs.CreatorMode.scenario;
      case 'persona':
        return cs.CreatorMode.persona;
      default:
        return null; // 'edit' / null → not a structured build
    }
  }

  /// Resolve the structured-build mode for ANY session, including EDIT
  /// sessions (which carry `mode == 'edit'` / `'persona'` + an editing id but
  /// must still build through the deterministic pipeline). Create sessions
  /// resolve via `_structuredModeFromString`.
  ///
  /// A character-EDIT session (`mode == 'edit'`) can hold EITHER a character
  /// card OR a scenario/narrator card — they share the same edit entry point.
  /// We disambiguate by sniffing the loaded Description: scenario cards carry
  /// `<Narrator>` / `<Scene Setup>` XML sections that a character card never
  /// has, so their presence routes the rebuild through the scenario schema.
  cs.CreatorMode? _underlyingBuildMode(CreatorSession session) {
    if (session.editingPersonaId != null) return cs.CreatorMode.persona;
    if (session.mode == 'edit') {
      final desc = (session.canvas['description'] ?? '').toString();
      if (desc.contains('<Narrator>') || desc.contains('<Scene Setup>')) {
        return cs.CreatorMode.scenario;
      }
      return cs.CreatorMode.character;
    }
    return _structuredModeFromString(session.mode);
  }

  /// True when this session is editing an existing card (persona / character /
  /// scenario) rather than creating a fresh one. Drives the edit framing in
  /// the structured build (preserve-unmentioned-fields).
  bool _isEditSession(CreatorSession s) =>
      s.editingPersonaId != null ||
      s.editingCharacterId != null ||
      s.mode == 'edit';

  /// True when the build is currently available: a buildable mode, at least
  /// one user message, and nothing in flight. Wave CY.18.242: the floating
  /// "Build the sheet" pill was removed — this now gates the muted "/build"
  /// helper hint near the input (the build itself is fired by the
  /// `[[BUILD_SHEET]]` marker or the `/build` command).
  bool _canStructuredBuild(AppStore store) {
    if (_structuredBuilding || _generating) return false;
    final session = store.activeCreatorSession;
    if (session == null) return false;
    if (_underlyingBuildMode(session) == null) return false;
    return session.messages
        .any((m) => m.role == 'user' && m.kind == null);
  }

  /// Index (in the active session's messages) of the build-status line this
  /// flow appended, so `_updateBuildStatus` can rewrite it in place. -1 = none.
  int _buildStatusIndex = -1;

  /// Append a transient build-status line (styled as a `freeformWarning`) and
  /// remember its index for in-place updates.
  void _appendBuildStatus(AppStore store, String text) {
    final messages = List<CreatorMessage>.from(_sessionMessages(store));
    messages.add(CreatorMessage(
      role: 'assistant',
      kind: 'freeformWarning',
      content: text,
    ));
    _buildStatusIndex = messages.length - 1;
    _persistMessages(store, messages);
    store.flushPersist();
    if (mounted) setState(() {});
    _scrollToBottom();
  }

  /// Rewrite the build-status line appended by `_appendBuildStatus` (or append
  /// a fresh one if it's gone — e.g. after a session switch).
  void _updateBuildStatus(AppStore store, String text) {
    final messages = List<CreatorMessage>.from(_sessionMessages(store));
    if (_buildStatusIndex >= 0 &&
        _buildStatusIndex < messages.length &&
        messages[_buildStatusIndex].kind == 'freeformWarning') {
      messages[_buildStatusIndex].content = text;
      _persistMessages(store, messages);
      store.flushPersist();
      if (mounted) setState(() {});
      _scrollToBottom();
      return;
    }
    _appendBuildStatus(store, text);
  }

  /// Run the deterministic structured build for the active session and merge
  /// the rendered card into the canvas. Best-effort: any field that comes back
  /// empty is surfaced as a soft note — never a retry loop.
  Future<void> _runStructuredBuildFlow() async {
    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;
    final session = store.activeCreatorSession;
    if (session == null) return;
    final cs.CreatorMode? mode = _underlyingBuildMode(session);
    if (mode == null) return;
    if (_structuredBuilding || _generating) return;

    // Audit 2026-06-04 (Creator M2): a session switch/delete during this
    // (long, multi-pass) build must abort it cleanly — otherwise its
    // progress-status + image-prompt bubbles land in the WRONG (now-active)
    // session, and the merged canvas read from the now-active session would
    // be written onto this build's session id. Capture the generation token
    // up front; `_abortInFlightStream()` bumps `_streamGen` on a switch/delete,
    // so a `myGen != _streamGen` mismatch means "the session changed — bail".
    // Every write site below (pass-status update, final canvas + done-status,
    // image-prompt offer) is gated on `myGen == _streamGen`.
    final myGen = _streamGen;

    // EDIT MODE: decompose the loaded card's Description back into the schema
    // field map so the build can carry each field's CURRENT value forward and
    // preserve everything the user didn't ask to change. Empty for create.
    final Map<String, String> existing;
    // FIX (foreign card): a card NOT built by Pyre (plain prose, W++, markdown
    // headings, a JSON blob) decomposes to a near-empty schema map because
    // `_decomposeLabeled` only matches Pyre's canonical labels. If we let the
    // build run on that, it re-invents the whole Description from scratch and
    // the user's imported content is silently discarded. Detect the foreign
    // case (a non-empty Description that yielded fewer than a couple of KNOWN
    // schema fields) and preserve the ORIGINAL Description verbatim, so the
    // rebuilt Description never overwrites it (the build may still edit the
    // other top-level fields — first_mes, scenario, tags — in place).
    String foreignDescription = '';
    if (_isEditSession(session)) {
      final existingDesc =
          (_sessionCanvas(store)['description'] ?? '').toString();
      existing = existingDesc.trim().isEmpty
          ? <String, String>{}
          : decomposeDescription(existingDesc, mode);
      // Only the labeled (character / persona) path is at risk — the scenario
      // path round-trips its `<Tag>` sections via the merge branch. Count how
      // many KNOWN schema-field keys the decompose recognised; < 2 on a
      // non-empty Description means the card uses a convention Pyre can't
      // parse → treat it as foreign and keep the raw Description.
      if (existingDesc.trim().isNotEmpty && mode != cs.CreatorMode.scenario) {
        final knownKeys =
            cs.schemaFor(mode).map((f) => f.key).toSet();
        final recognised =
            existing.keys.where(knownKeys.contains).length;
        if (recognised < 2) foreignDescription = existingDesc;
      }
      // Audit 2026-06-04 (High): seed the top-level `scenario` from the canvas
      // so an edit REFINES it in place instead of inventing a fresh one. Adding
      // `scenario` to the character schema (the "Creator didn't produce a
      // Scenario" fix) put it in the edit batches, but `existing` is built only
      // from the decomposed Description — which never carries the top-level
      // scenario — so the model got no current value and regenerated from
      // scratch, silently discarding the user's scenario on every edit.
      // (Character mode only; scenario mode round-trips it via the merge
      // branch and isn't affected.)
      if (mode == cs.CreatorMode.character) {
        final curScenario =
            (_sessionCanvas(store)['scenario'] ?? '').toString();
        if (curScenario.trim().isNotEmpty) {
          existing['scenario'] = curScenario;
        }
      }
    } else {
      existing = <String, String>{};
    }

    final provider = store.creatorProvider;
    if (provider == null) {
      _appendBuildStatus(
          store,
          '⚠ No provider configured. Open "More → API Connections" to add '
          'one, then ask me to build the sheet again (or type /build).');
      return;
    }
    final settings = _creatorChatSettings(store.modelSettings);

    // Phase-1 transcript → ChatTurns. Skip transient cue/warning messages
    // (kind != null) and any empty turn.
    final msgs = _sessionMessages(store);
    final transcript = <ChatTurn>[
      for (final m in msgs)
        if (m.kind == null && _composeTurnContent(m).trim().isNotEmpty)
          ChatTurn(m.role == 'assistant' ? 'assistant' : 'user',
              _composeTurnContent(m)),
    ];

    final batches = cs.batchesFor(mode);
    setState(() => _structuredBuilding = true);
    _appendBuildStatus(
        store,
        '⏳  Building the sheet… this runs in a few passes and can take a '
        'couple of minutes. Keep the app open.');

    var batchIndex = 0;
    // BLOCKER 1: latch when a provider rejects `response_format`. The transport
    // already retries-without-extras on a param-shape 4xx, so the build never
    // dies — but without this latch EVERY batch would pay that wasted 4xx +
    // retry round-trip. Once we see one rejection, drop `response_format` for
    // the rest of THIS build (extractJsonObject tolerates prose/fenced JSON, so
    // structured mode degrades gracefully, not fatally).
    var jsonModeUnsupported = false;
    try {
      final fields = await runStructuredBuild(
        batches: batches,
        // Back off between retries so a transient provider throttle (empty
        // reply) can recover before the next attempt.
        retryDelay: const Duration(seconds: 5),
        buildTurns: (keys, decided) {
          // Advance the displayed pass only on a FRESH full batch — a targeted
          // missing-key re-request (a subset of a batch) reuses the same pass.
          final isFreshBatch = batches.any((b) =>
              b.length == keys.length && b.every((k) => keys.contains(k)));
          if (isFreshBatch) {
            batchIndex++;
            // Creator M2: only update the on-screen status if THIS build's
            // session is still active — otherwise the pass counter would
            // write into whatever session the user switched to.
            if (myGen == _streamGen) {
              _updateBuildStatus(store,
                  '⏳  Filling the sheet… pass $batchIndex of ${batches.length}.');
            }
          }
          return buildBatchTurns(
            mode: mode,
            batchKeys: keys,
            transcript: transcript,
            // Edit framing only when editing — create passes null so its
            // prompt stays byte-identical to before.
            existingFields: existing.isEmpty ? null : existing,
            // FIX #3 carry-forward: keep later passes consistent with the facts
            // decided in earlier passes (empty on the first pass).
            priorFields: decided.isEmpty ? null : decided,
            // Wave CY.18.265: user-chosen desired Description size (char +
            // persona). Standard = the original ~5k aim.
            descriptionSize: store.modelSettings.creatorDescriptionSize,
          );
        },
        call: (turns) async {
          // Capture the reasoning-inclusive text alongside the normal
          // reasoning-STRIPPED content. A reasoning model (Qwen / Venice)
          // sometimes emits its JSON answer in the reasoning channel, so
          // `content` (and thus `text` here) comes back empty → empty batch →
          // hollow card. When the normal content has NO parseable JSON object,
          // fall back to the reasoning-inclusive text so the build's
          // `extractJsonObject` can recover the object the model put there.
          // The content-has-JSON path is unchanged (`text` returned verbatim);
          // the chat-display path never touches this (it streams directly).
          final rawSink = StringBuffer();
          final text = await completeChatStreamed(
            provider: provider,
            settings: settings,
            messages: turns,
            // BLOCKER 1: skip `response_format` once a provider has rejected it
            // on THIS build (the latch below), so we don't 4xx every batch.
            extraBody: jsonModeUnsupported
                ? null
                : const {
                    'response_format': {'type': 'json_object'}
                  },
            debugTag: 'creator-structured',
            rawSink: rawSink,
            // Latch the param fallback so subsequent batches stop sending it.
            onParamFallback: () => jsonModeUnsupported = true,
          );
          if (extractJsonObject(text) != null) return text;
          // The JSON lived in the reasoning channel (wrapped in <think>…). The
          // build's _runBatch will run stripStreamArtifacts() on whatever we
          // return — which would strip those <think> tags and lose the object
          // again — so return the EXTRACTED object re-encoded as a bare JSON
          // string (no <think>), which survives the strip and re-parses.
          // HIGH 5: prefer the object AFTER the final </think> so we recover the
          // model's FINAL answer, never a half-formed chain-of-thought DRAFT
          // object it sketched inside the reasoning channel.
          final fromReasoning = extractJsonAfterReasoning(rawSink.toString());
          if (fromReasoning != null) return jsonEncode(fromReasoning);
          return text; // nothing parseable either way — let the build retry
        },
      );

      if (!mounted) return;
      // Creator M2: if the user switched/deleted the session while the build
      // ran, bail BEFORE touching the canvas. The merge below reads
      // `_sessionCanvas(store)` (the LIVE active session) and would otherwise
      // write the now-active session's canvas onto the build's session id —
      // corrupting both. Dropping the result is the safe choice (the
      // instruction accepts "lost if the session changed"); a re-run rebuilds.
      if (myGen != _streamGen) return;

      // CRITICAL 4: a scenario card with a duplicate `<Tag>` (e.g. two
      // `<World>` blocks → world / world#2) decomposes `#N` variants into
      // `existing`, but the edit batches only re-request BASE keys, so the model
      // never returns world#2. Carry those duplicate-suffix keys forward so the
      // edit re-render reproduces the duplicate instead of dropping it.
      final buildFields = (_isEditSession(session) &&
              mode == cs.CreatorMode.scenario &&
              existing.isNotEmpty)
          ? carryForwardDuplicateTags(fields, existing)
          : fields;

      // Render deterministically → canvas. Merge non-null rendered keys into
      // the current session canvas (preserve anything already there, e.g. a
      // user-typed name or an attached avatar).
      final rendered = renderCard(buildFields, mode);
      final canvas = Map<String, dynamic>.from(_sessionCanvas(store));
      final editing = _isEditSession(session);
      rendered.forEach((k, v) {
        if (v == null) return;
        // Wave CY.18.269: in EDIT mode, never let a rebuilt field BLANK a field
        // that already had content. A model that "only adds one thing" but
        // drops/empties another field must not wipe the user's existing data —
        // keep the original when the rebuild came back empty.
        if (editing) {
          final newEmpty =
              (v is String && v.trim().isEmpty) || (v is List && v.isEmpty);
          final orig = canvas[k];
          final hadContent = (orig is String && orig.trim().isNotEmpty) ||
              (orig is List && orig.isNotEmpty);
          if (newEmpty && hadContent) return;
        }
        canvas[k] = v;
      });
      // FIX (foreign card): the imported Description couldn't be decomposed, so
      // the rebuilt one would be re-invented prose — restore the raw original
      // verbatim instead of overwriting the user's content. Other rebuilt
      // fields (first_mes, scenario, tags) still apply above.
      if (foreignDescription.trim().isNotEmpty) {
        canvas['description'] = foreignDescription;
      }
      store.updateCreatorSessionCanvas(id, canvas);
      store.flushPersist();

      // Soft missing-required note (informational — NEVER a retry loop).
      final missing = missingRequired(fields, mode);
      final doneMsg = missing.isEmpty
          ? '✓  Card\'s ready. Open the Sheet tab to review, tweak, or Save.'
          : '✓  Card built. A few fields came back empty '
              '(${missing.join(', ')}) — you can re-run the build or fill them '
              'by hand in the Sheet tab.';
      _updateBuildStatus(store, doneMsg);
      if (mounted) setState(() => _showCanvas = true); // surface the Sheet

      // After a CLEAN build of a fresh card (not an edit), proactively offer to
      // draft an image prompt. The architect's existing "image prompt"
      // affordance generates it when the user replies — no extra LLM call here.
      // A SEPARATE real assistant bubble (kind null) so it renders normally and
      // is NOT swallowed by `_updateBuildStatus`'s single tracked status line.
      if (missing.isEmpty && !editing) {
        final offer = mode == cs.CreatorMode.scenario
            ? 'Want a **key-art image prompt** for the card thumbnail? Say the '
                'word and I\'ll draft one (natural-language + danbooru tags) you '
                'can paste into your image generator.'
            : 'Want an **image prompt** to make an avatar? Just ask — I\'ll '
                'draft one: a natural-language version (for GPT Image / '
                'Midjourney / Flux) plus danbooru tags (for SDXL / Pony / '
                'Illustrious). Portrait works best.';
        final messages = List<CreatorMessage>.from(_sessionMessages(store));
        messages.add(CreatorMessage(role: 'assistant', content: offer));
        _persistMessages(store, messages);
        store.flushPersist();
        if (mounted) setState(() {});
        _scrollToBottom();
      }
    } catch (e) {
      // Creator M2: don't write the error bubble into a session the user
      // switched to mid-build.
      if (myGen == _streamGen) {
        _updateBuildStatus(
            store,
            '⚠ The build hit a problem (${e.toString()}). Whatever was filled '
            'is in the Sheet tab — you can re-run the build.');
      }
    } finally {
      if (mounted) setState(() => _structuredBuilding = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Sending a turn

  /// Send a chat turn through the assistant. Flushes staged attachments
  /// into the outgoing message AND runs the vision API for any image
  /// attachments NOW (so the user's typed text guides the analysis).
  /// When an image profile becomes the assistant turn, we DON'T also
  /// run the regular chat call — that double-assistant turn was what
  /// triggered the "empty response" errors before.
  Future<void> _send() async {
    final text = _inputCtl.text.trim();
    // C-2 (CRITICAL): a normal send during an in-flight structured build must
    // NOT proceed. `_runConversation` bumps `_streamGen`, which makes the build
    // bail at its `myGen != _streamGen` guard BEFORE writing the canvas /
    // done-status, silently discarding the whole build (the "pass N of M"
    // bubble freezes forever, the sheet stays empty). Block the send outright
    // while building (the input bar is also disabled — belt and suspenders).
    // Predicate lives in creator_cascade.dart so it's unit-testable.
    if (creatorSendBlocked(
      trimmedText: text,
      hasPendingAttachments: _pendingAttachments.isNotEmpty,
      generating: _generating,
      structuredBuilding: _structuredBuilding,
    )) {
      return;
    }

    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;

    // Wave CY.18.242: deterministic `/build` command — the safety-net trigger
    // for the structured build if the architect ever forgets the
    // `[[BUILD_SHEET]]` marker. When the user's outgoing message is exactly
    // `/build` (or `/build the sheet`), don't send it to the architect — fire
    // the build directly (guarded) and surface a tiny confirmation.
    if (isBuildCommand(text) && _pendingAttachments.isEmpty) {
      _inputCtl.clear();
      final messenger = ScaffoldMessenger.of(context);
      if (_structuredBuilding || _generating) {
        messenger.showSnackBar(
            const SnackBar(content: Text('Already building the sheet…')));
        return;
      }
      final session = store.activeCreatorSession;
      if (session == null || _underlyingBuildMode(session) == null) {
        messenger.showSnackBar(const SnackBar(
            content: Text('Nothing to build yet — start a character, '
                'scenario, or persona first.')));
        return;
      }
      messenger.showSnackBar(
          const SnackBar(content: Text('Building the sheet…')));
      unawaited(_runStructuredBuildFlow());
      return;
    }

    setState(() => _generating = true);

    final pending = List<_PendingAttachment>.from(_pendingAttachments);

    // Wait for any background downscale work so the vision call uses
    // the smaller bytes.
    for (final p in pending) {
      if (p.analysing != null) {
        await p.analysing;
      }
    }
    if (!mounted) return;

    _inputCtl.clear();

    // Build the user-facing attachment list. Images carry only the
    // thumbnail data URL; their `extracted` stays empty on the
    // persisted attachment (vision profile is a separate assistant
    // turn). Cards / docs still carry their extracted text (folded
    // into the user's outgoing text by _composeTurnContent).
    final attachments = pending
        .map((p) => CreatorAttachment(
              kind: p.kind,
              filename: p.filename,
              imageDataUrl: p.imageBytes == null
                  ? null
                  : encodeImageDataUrl(p.imageBytes!),
              extracted: p.kind == 'image'
                  ? ''
                  : (p.extracted ??
                      (p.error != null
                          ? '(Attachment `${p.filename}` could not be parsed: ${p.error}.)'
                          : '')),
            ))
        .toList();

    final newMessages = List<CreatorMessage>.from(_sessionMessages(store));

    // Persist the user turn IMMEDIATELY so the bubble appears before
    // the vision call (which can take 5-15s on a 5MB photo).
    newMessages.add(CreatorMessage(
      role: 'user',
      content: text,
      attachments: attachments,
    ));

    // Per image, drop an empty assistant placeholder right away so
    // the user sees a "…" bubble while the vision call runs instead
    // of a silent wait. We fill the content in-place once each call
    // returns. Reference equality is enough — the bubble re-renders
    // from the same CreatorMessage instance.
    final imagePending = pending
        .where((p) => p.kind == 'image' && p.imageBytes != null)
        .toList();
    final placeholders = <CreatorMessage>[];
    for (var i = 0; i < imagePending.length; i++) {
      final ph = CreatorMessage(role: 'assistant', content: '');
      newMessages.add(ph);
      placeholders.add(ph);
    }
    _persistMessages(store, newMessages);
    setState(() {
      _pendingAttachments.clear();
      _streamBuffer = '';
    });
    _scrollToBottom();

    // Fire vision API calls in parallel — passing the user's typed
    // text as guidance so the model can bias which details to
    // emphasise. Update the matching placeholder in-place as each
    // call returns; the bubble's ChatText will redraw.
    //
    // For the vision provider, prefer the dedicated vision override
    // (store.visionProvider). It falls back to creator → chat. Lets
    // the user pin a multimodal model (Qwen-VL, Pixtral, Venice qwen,
    // Claude, GPT) for vision while keeping a stronger text model
    // (DeepSeek-V4, etc.) for the rest of the creator flow.
    final visionProv = store.visionProvider;
    if (imagePending.isNotEmpty) {
      if (visionProv == null) {
        for (final ph in placeholders) {
          ph.content =
              '⚠ No provider configured. Open More → API Connections.';
        }
        _persistMessages(store, newMessages);
        if (mounted) setState(() {});
      } else {
        // Wave CY.18.21: capture the session id at dispatch time so
        // a late-resolving vision call CANNOT write its profile
        // into a DIFFERENT session the user switched to in the
        // meantime. Pre-Wave: `_persistMessages` read live
        // `_sessionId`, so if the user opened another session
        // while the vision call was in flight, the profile landed
        // in the WRONG session's messages.
        final dispatchSessionId = _sessionId;
        final futures = <Future<void>>[];
        for (var i = 0; i < imagePending.length; i++) {
          final p = imagePending[i];
          final placeholder = placeholders[i];
          futures.add(() async {
            try {
              final profile = await describeCharacterImage(
                provider: visionProv,
                settings: _visionSettings(store.modelSettings),
                imageBytes: p.imageBytes!,
                userNote: text,
              );
              // Persist profile back to the SAME session it was
              // dispatched from, regardless of whether the user
              // navigated away. The placeholder reference is the
              // same CreatorMessage instance held in that session's
              // messages list, so mutating its content + persisting
              // by id is enough — no setState needed if !mounted.
              placeholder.content = profile;
              if (dispatchSessionId != null) {
                store.updateCreatorSessionMessages(
                    dispatchSessionId, newMessages);
              }
              if (!mounted) return;
              setState(() {});
              _scrollToBottom();
            } catch (e) {
              placeholder.content =
                  '⚠ Could not analyse `${p.filename}`: $e\n\nSwitch the creator provider to a vision-capable one (Venice qwen, Pixtral, Qwen-VL, Claude / GPT) in More → API Connections.';
              if (dispatchSessionId != null) {
                store.updateCreatorSessionMessages(
                    dispatchSessionId, newMessages);
              }
              if (!mounted) return;
              setState(() {});
            }
          }());
        }
        await Future.wait(futures);
      }
    }

    if (!mounted) return;

    // When an image profile became the assistant message, skip the
    // regular chat call — the profile ends with its own NEXT line
    // that hands the turn back to the user. Running the chat call
    // here would (a) waste tokens re-narrating and (b) cause empty
    // responses on strict providers that reject two consecutive
    // assistant turns. Cards / docs without images still need a
    // chat-model reply because their extracted is folded into the
    // user's text.
    if (imagePending.isNotEmpty) {
      setState(() => _generating = false);
      context.read<AppStore>().flushPersist();
    } else {
      await _runConversation();
    }
  }

  /// Wave CY.18.231: in-flight flag for the structured build. Guards the build
  /// against double-fire (the `[[BUILD_SHEET]]` marker auto-fire + the `/build`
  /// command both check it) and is independent of `_generating` (which gates
  /// the architect chat stream).
  bool _structuredBuilding = false;


  /// One-shot per-turn system-prompt override. When non-null,
  /// `_runConversation` uses THIS as the architect/system prompt for the
  /// NEXT turn, then clears it (single-use). Currently nothing sets it
  /// (the review-pass that used it was removed with the marker cascade);
  /// kept as a hook so a future one-shot prompt swap can use it without
  /// disturbing the normal architect prompt selection.
  String? _systemPromptOverride;

  /// Wave CV: handler for the inline "Build character / Build scenario"
  /// buttons that render under the opening greeting when the session
  /// has no mode yet. Locks the mode on the session, appends the
  /// flow-specific follow-up greeting, unlocks the input.
  ///
  /// Wave CY.18.27: now sets `mode` but DEFERS appending the follow-up
  /// greeting until the user also picks `flow` (guided vs freeform).
  /// The mode-choice row collapses, the flow-choice row appears, and
  /// only after both stages land does the flow-specific greeting
  /// emerge with the unlocked input. This is the two-stage selector
  /// the design called for.
  void _chooseMode(String mode) {
    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;
    final session = store.creatorSessions.firstWhere(
      (s) => s.id == id,
      orElse: () => CreatorSession(id: ''),
    );
    if (session.id.isEmpty) return;
    if (session.mode != null) return; // already chosen — no-op
    session.mode = mode;
    // Wave CY.18.101: guided flow removed — freeform is the only flow.
    // _chooseMode now locks flow='freeform' and appends the freeform
    // greeting immediately (the second-stage flow picker is gone).
    session.flow = 'freeform';
    final followUp = mode == 'scenario'
        ? _scenarioFreeformGreeting
        : _characterFreeformGreeting;
    final updated = List<CreatorMessage>.from(session.messages)
      ..add(CreatorMessage(role: 'assistant', content: followUp));
    store.updateCreatorSessionMessages(id, updated);
    setState(() {});
  }

  // Wave CY.18.101: _chooseFlow removed (guided flow deleted). _chooseMode
  // now locks flow='freeform' and appends the freeform greeting directly.

  /// Wave CV: pick the architect prompt that matches the session's
  /// mode. Legacy sessions (no `mode` set) default to the character
  /// architect — that's what the runtime was hardcoded to before this
  /// wave, so existing drafts keep working.
  ///
  /// Wave CY.18.10: appends the user's free-form addendum from
  /// [ModelSettings.creatorPromptAddendum] at the very end so power
  /// users can nudge the architect without being able to break the
  /// structural core. Empty addendum = original prompt unchanged.
  ///
  /// Wave CY.18.30: ALSO appends the user's "About Me" from the
  /// BotBooru Profile screen, in its own clearly-labelled section.
  /// Two distinct concepts on purpose:
  ///   - ABOUT THE CREATOR (botbooruAboutMe): WHO the user is — soft
  ///     context the architect can use to tailor pitches ("she usually
  ///     makes slice-of-life teacher cards → propose a warm sensei").
  ///     Tagged as soft so the architect doesn't echo it in chat or
  ///     leak it into SHEET fields.
  ///   - USER ADDITIONS (creatorPromptAddendum): WHAT the user wants
  ///     enforced — hard architect rules ("always respond in PT-BR",
  ///     "skip Block 6 unless asked").
  /// Order matters: About Me first (context-setting), then Additions
  /// (rules on top of context). Either section is omitted when its
  /// source is empty so the base prompt stays untouched for users who
  /// haven't configured anything.
  /// Wave CY.18.210: delegates to the pure `creatorArchitectPrompt` in
  /// `chat_prompt_builder.dart` (one source for the per-mode architect
  /// assembly). This method only resolves the store-side inputs (the active
  /// session's mode + the forkable CreatorPreset's per-mode override fields
  /// + the user additions addendum); the prompt-string composition (base
  /// selection, freeform appendix for block modes, addendum framing) lives
  /// in the builder. Behaviour is byte-identical.


  /// Conversation turn — uses the architect prompt that matches the
  /// session's mode (Wave CV) as the system message. Streams the
  /// assistant's reply into a new message slot and persists each chunk.
  Future<void> _runConversation() async {
    final store = context.read<AppStore>();
    final provider = store.creatorProvider;
    final id = _sessionId;
    if (id == null) return;
    if (provider == null) {
      _finishWithError(
          'No provider configured. Open "More → API Connections".');
      return;
    }
    final messages = List<CreatorMessage>.from(_sessionMessages(store));
    // Wave CV.20: snapshot the canvas BEFORE this turn fires so Retry
    // can revert any writes the turn ended up making. Deep copy via
    // jsonEncode/Decode — canvas values can be nested Maps/Lists, and
    // a shallow copy would let later mutations leak back into the
    // snapshot.
    final canvasBefore =
        jsonDecode(jsonEncode(_sessionCanvas(store))) as Map<String, dynamic>;
    final reply = CreatorMessage(
      role: 'assistant',
      content: '',
      canvasSnapshot: canvasBefore,
    );
    messages.add(reply);
    _persistMessages(store, messages);

    // Wave BA + BR: the canvas snapshot is appended to the architect
    // prompt as a SINGLE system message (some OpenAI-compat providers drop
    // multi-system requests), then the conversation follows.
    // Wave CV: architect prompt switches by session mode.
    // A one-shot `_systemPromptOverride`, when set, wins for THIS turn and
    // is then consumed.
    // Wave CY.18.210: the turn assembly now delegates to the pure
    // `buildCreatorArchitectTurns` (one source the harness shares). The
    // store-side resolution (override consumption, the active preset's
    // per-mode prompt fields, the addendum, the session mode + canvas)
    // stays here; the string/turn composition lives in the builder.
    final override = _systemPromptOverride;
    _systemPromptOverride = null;
    final preset = store.activeCreatorPreset;
    final turns = buildCreatorArchitectTurns(
      canvas: _sessionCanvas(store),
      conversation: [
        for (final m in messages.sublist(0, messages.length - 1))
          CreatorTurn(m.role, _composeTurnContent(m)),
      ],
      mode: store.activeCreatorSession?.mode,
      characterPrompt: preset?.characterPrompt,
      scenarioPrompt: preset?.scenarioPrompt,
      editPrompt: preset?.editPrompt,
      addendum: store.modelSettings.creatorPromptAddendum,
      systemPromptOverride: override,
    );

    await _streamArchitectTurn(
      store: store,
      turns: turns,
      messages: messages,
      reply: reply,
    );
  }

  /// Wave AZ: the actual SSE streaming pump for an architect turn.
  /// Factored out so the auto-continue loop can re-enter it with a
  /// continuation message appended without duplicating setup code.
  Future<void> _streamArchitectTurn({
    required AppStore store,
    required List<ChatTurn> turns,
    required List<CreatorMessage> messages,
    required CreatorMessage reply,
  }) async {
    final provider = store.creatorProvider;
    if (provider == null) {
      _finishWithError(
          'No provider configured. Open "More → API Connections".', reply: reply);
      return;
    }

    // Wave BM: start the foreground-service keep-alive so the OS
    // doesn't kill us mid-generation when the user minimizes. The
    // matching stop() lives in onDone / onError so a crash mid-stream
    // can't leave the persistent notification orphaned.
    // Wave CY.18.35: heavy:true — Creator block emissions take 1-2 min
    // each (3-5 min for a Freeform cascade). The notification is
    // necessary here; chat streams skip it.
    await _keepAliveStart();

    // Wave CY.18.44: capture stream-generation token so onData / onError
    // / onDone callbacks can detect if a NEWER stream has superseded
    // this one (user tapped Stop + restarted, or _abortInFlightStream
    // fired for a session switch). Stale callbacks no-op cleanly.
    final myGen = ++_streamGen;
    try {
      _streamSub = streamChatCompletion(
        provider: provider,
        // Apply creator-specific temperature + max_tokens overrides
        // so the design conversation can be tuned independently of
        // the regular chat (see ModelSettings.creatorTemperature etc.).
        settings: _creatorChatSettings(store.modelSettings),
        // Wave CY.18.125: NULL, not the RP preset. `_samplingPayload`
        // resolves max_tokens as `preset?.maxTokens ?? settings.maxTokens`,
        // so passing the active RP preset (whose reply cap is ~1-2k)
        // OVERRODE the creator's creatorMaxTokens (12000) and capped every
        // block at the RP limit → cut at finish_reason=length right before
        // `<<BLOCK_END>>` → the truncation/continuation-exhaust loop. The
        // creator's sampling lives in _creatorChatSettings; the preset
        // injects NO prompt content here (only sampling), so dropping it is
        // a sampling-only change — mirrors the sheet-update + vision paths.
        preset: null,
        messages: turns,
        // creator-07 (mega audit 2026-06-04): dropped the vestigial
        // `stop: ['<<BLOCK_END>>']`. The freeform architect appendix is
        // conversation-only and no longer instructs the model to emit
        // `<<BLOCK_END>>` (the deterministic JSON build owns formatting),
        // so the stop sequence never fired — dead + misleading. The
        // _sanitiseBlockMarker scrub below still strips any stray marker a
        // model emits on its own, so removing the server-side stop is safe.
        debugTag: 'creator-architect', // Wave CY.18.214 diagnostics tag
      ).listen(
        (chunk) {
          if (!mounted || myGen != _streamGen) return;
          _streamBuffer += chunk;
          // Creator Structured Build: Phase-1 is pure conversation. Stream
          // the architect's reply live, stripping any stray control markers
          // so they never leak into chat. The card data is produced
          // separately by the deterministic JSON build pipeline.
          reply.content = _sanitiseBlockMarker(_streamBuffer);
          _persistMessages(store, messages);
          _scrollToBottom();
        },
        // Wave CY.18.44: mounted-guard the onError hop. Symmetric with
        // the onDone handler below — that one starts with `if (!mounted)
        // return;` so a stream error fired AFTER the user navigated
        // away from the creator screen now no-ops cleanly instead of
        // calling _finishWithError, which would touch setState /
        // persistMessages on a disposed widget.
        onError: (e) {
          if (!mounted || myGen != _streamGen) return;
          // Wave CY.18.45: pass originalError so offline/timeout
          // exceptions surface as friendly user messages instead of
          // raw SocketException toString().
          _finishWithError(e.toString(), reply: reply, originalError: e);
        },
        onDone: () async {
          if (!mounted || myGen != _streamGen) return;

          // Creator Structured Build: Phase-1 stays conversational. The
          // card data is produced by the deterministic JSON pipeline. It is
          // fired BY MESSAGE (Wave CY.18.242) — when the architect decides the
          // user has signalled readiness it emits the ASCII marker
          // `[[BUILD_SHEET]]` on its own final line. Detect its presence in the
          // RAW buffer (so we still know to fire even though `_sanitiseBlockMarker`
          // already strips it for display), then render the cleaned reply.
          final markerPresent = detectAndStripBuildMarker(_streamBuffer).found;
          final text = _sanitiseBlockMarker(_streamBuffer);
          reply.content = text.trim().isEmpty
              ? '⚠ The model returned an empty response. Try again, or '
                  'switch the creator provider in More → API Connections.'
              : text;
          _persistMessages(store, messages);
          setState(() => _generating = false);
          context.read<AppStore>().flushPersist();
          _keepAliveStop();

          // Auto-fire the structured build when the architect emitted the
          // marker. `_runStructuredBuildFlow` self-guards (it returns early on
          // `_structuredBuilding` / `_generating`, and on a non-buildable mode
          // — so the marker is a no-op outside a build session) so it can't
          // double-fire. Works in BOTH create and edit mode —
          // `_runStructuredBuildFlow` branches on `editing` internally.
          if (markerPresent && !_structuredBuilding) {
            unawaited(_runStructuredBuildFlow());
          }
        },
      );
    } catch (e) {
      _finishWithError(e.toString(), reply: reply, originalError: e);
    }
  }



  /// Flatten a CreatorMessage's attachments + text into the single
  /// string the LLM sees. Attachments are prepended (each as its own
  /// labeled block) so the model has context BEFORE the user's actual
  /// prose. Empty extracted blocks (e.g. when an image vision call
  /// failed) are skipped — the model would just be confused otherwise.
  String _composeTurnContent(CreatorMessage m) {
    if (m.attachments.isEmpty) return m.content;
    final blocks = <String>[];
    for (final a in m.attachments) {
      if (a.extracted.trim().isEmpty) continue;
      blocks.add(a.extracted);
    }
    if (m.content.trim().isNotEmpty) {
      blocks.add(m.content);
    } else if (blocks.isEmpty) {
      // Edge: an image attached but vision failed AND user typed nothing.
      // Surface a placeholder so the assistant turn isn't empty.
      blocks.add(
          '(User attached ${m.attachments.length} file(s) but did not type anything.)');
    }
    return blocks.join('\n\n');
  }

  /// Scrub the `<<BLOCK_END>>` marker (and any partial-prefix tail that
  /// streaming might leave dangling — `<<BLOCK_EN`, `<<BLOCK`, `<<B`,
  /// `<<`) from the streaming buffer so the user never sees it.
  ///
  /// The marker is the hard-stop sentinel the Character Architect
  /// prompt tells the model to emit at the end of each block; the
  /// OpenAI `stop` parameter normally cuts generation off before any
  /// of it reaches us. But some providers ignore the param, and even
  /// when honoured the model can emit a partial fragment before the
  /// server fires — so we belt-and-braces on the client side too.
  ///
  /// Why prefix-aware: during streaming the buffer's tail can be a
  /// partial marker (the SSE chunk that completes it hasn't arrived
  /// yet). If we only stripped the full literal, we'd flash `<<BLO`
  /// in the UI for one frame before the next chunk lands.
  /// Strip every complete `<<BLOCK_END>>` and `<<SHEET>>` occurrence —
  /// these are control tokens and shouldn't appear in the chat-visible
  /// brief at all. Both get replaced with a newline so adjacent prose
  /// stays separated.
  static final RegExp _blockEndMarker = RegExp(
    r'\s*<<(?:BLOCK_END|SHEET)>>\s*',
    multiLine: true,
  );

  /// Tail-aware partial-marker strip. Matches the dangling
  /// `<`, `<<`, `<<B`, `<<BL`, ..., `<<BLOCK_END>`, `<<S`, `<<SH`,
  /// `<<SHE`, ..., `<<SHEET>` that streaming can leave at the end
  /// of the buffer between SSE chunks. Without this the UI flashes
  /// the partial marker for one frame before the next chunk arrives.
  static final RegExp _blockEndTail = RegExp(r'\s*<{1,2}[A-Z_]*>{0,2}$');

  /// Wave BB: strip `<think>...</think>` reasoning blocks AND any
  /// dangling `<think>` opener at end of buffer. These come from R1 /
  /// Qwen3+ models via the streaming parser wrapping reasoning_content
  /// for the existing chat-side `<think>` hiding. In the Creator brief
  /// we just want them gone — the chat bubble there is a user-facing
  /// announcement, not a Chat tab with reasoning toggle UX.
  static final RegExp _thinkBlock =
      RegExp(r'<think>[\s\S]*?</think>', multiLine: true);
  static final RegExp _thinkOpenTail =
      RegExp(r'<think>[\s\S]*$', multiLine: true);

  String _sanitiseBlockMarker(String raw) {
    // Strip every complete occurrence anywhere in the buffer first…
    var s = raw.replaceAll(_blockEndMarker, '\n');
    // …then any partial prefix dangling at the very end of the stream.
    s = s.replaceFirst(_blockEndTail, '');
    // Wave CP: also strip `<<SHEET>>` from the brief side. The splitter
    // uses it as a boundary marker — anything before the FIRST `<<SHEET>>`
    // is brief — but if the model writes `<<SHEET>>` inline in prose
    // OR Wave CF moves structured content back into the brief side, the
    // literal marker can leak into chat. It's a control token, never
    // user-facing.
    s = s.replaceAll('<<SHEET>>', '');
    // Wave BB: strip <think>...</think> entirely from the brief, plus
    // any unclosed <think>... still streaming.
    s = s.replaceAll(_thinkBlock, '');
    s = s.replaceFirst(_thinkOpenTail, '');
    // Wave BY: strip the finish_reason sentinel emitted by
    // streamChatCompletion at end-of-stream. The marker is for
    // runtime use (truncation detection) — never user-facing.
    s = s.replaceAll(pyreFinishSentinelRegex, '');
    // Wave CY.18.242: strip the build-sheet trigger marker so it never
    // flashes in chat while streaming. `detectAndStripBuildMarker` does the
    // same removal — we mirror it here for the live buffer. The build auto-fire
    // in `onDone` detects the marker from the RAW `_streamBuffer`, so stripping
    // it here for display doesn't lose the signal.
    final marker = detectAndStripBuildMarker(s);
    s = marker.text;
    return s.trim();
  }

  // ---------------------------------------------------------------------------
  // Attach handlers

  /// Soft cap above which we ask the user to confirm before sending.
  static const int _bigFileThreshold = 200 * 1000;

  /// Pick a chara_card_v2 PNG/JSON, parse the embedded metadata, and
  /// STAGE it as a pending attachment. The actual LLM turn doesn't
  /// fire until the user hits send — so they can type context first.
  Future<void> _attachCard() async {
    if (_generating) return;
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
      CharaCard card;
      try {
        card = ext == 'json'
            ? parseCharaCardJson(utf8.decode(bytes))
            : parseCharaCardPng(bytes);
      } catch (e) {
        messenger.showSnackBar(SnackBar(
            content: Text('Not a valid chara_card_v2 file: $e')));
        return;
      }
      final pretty = const JsonEncoder.withIndent('  ').convert(card.raw);
      final extracted =
          'Reference card I attached (full chara_card_v2 metadata from '
          '`${f.name}`):\n\n```json\n$pretty\n```\n\n'
          'Treat this as authoritative context. If I ask for edits, '
          'apply them to this card; if I ask for a new card "in this '
          'style", use it as inspiration.';

      if (extracted.length > _bigFileThreshold && mounted) {
        final ok = await confirmDelete(
          context,
          title: 'Big reference card',
          message:
              'This card is ${(extracted.length / 1000).toStringAsFixed(0)}k chars '
              '(~${(extracted.length / 4 / 1000).toStringAsFixed(0)}k tokens). '
              'Some models may reject the request. Pyre never truncates — '
              'the full content will be sent. Continue?',
          confirmLabel: 'Attach',
          cancelLabel: 'Cancel',
        );
        if (!ok) return;
      }

      setState(() {
        _pendingAttachments.add(_PendingAttachment(
          kind: 'card',
          filename: f.name,
          extracted: extracted,
        ));
      });
      // Wave AY: the unified _greeting already explains attachments are
      // welcome. No need to swap the greeting on attach — the chip row
      // above the input + the user's typed context tell the story.
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Attach failed: $e')),
      );
    }
  }

  /// Pick a reference image and stage it. Attach is INSTANT — the
  /// chip appears as soon as the picker returns. The vision API call
  /// happens at SEND time (so the user's typed text can guide the
  /// analysis); downscaling happens in the background between attach
  /// and send so the vision call has the smaller payload ready.
  Future<void> _attachImage() async {
    if (_generating) return;
    final store = context.read<AppStore>();
    final provider = store.creatorProvider;
    final messenger = ScaffoldMessenger.of(context);
    if (provider == null) {
      messenger.showSnackBar(
        const SnackBar(
            content: Text(
                'No provider configured. Open "More → API Connections".')),
      );
      return;
    }
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['png', 'jpg', 'jpeg', 'webp', 'gif'],
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
      // Stage with the RAW (un-downscaled) bytes immediately so the
      // chip appears instantly. Downscale in the background; the
      // vision call (deferred until send) will use whichever bytes
      // are current at that point.
      final pending = _PendingAttachment(
        kind: 'image',
        filename: f.name,
        imageBytes: bytes,
      );
      final downscaleFut = () async {
        try {
          final downscaled = await downscaleIfNeeded(bytes);
          if (!mounted) return;
          if (!identical(downscaled, bytes)) {
            setState(() => pending.imageBytes = downscaled);
          }
        } catch (_) {
          // Downscale is best-effort — if it fails, vision call
          // uses the original bytes. No UI surfacing needed.
        } finally {
          pending.analysing = null;
        }
      }();
      pending.analysing = downscaleFut;
      setState(() => _pendingAttachments.add(pending));
      // Wave AY: greeting is now static (see _greeting).
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Attach failed: $e')),
      );
    }
  }

  /// Pick a markdown / plain-text / PDF document and STAGE it. Text is
  /// extracted synchronously (or via Syncfusion for PDFs); the LLM
  /// only sees it at send time.
  Future<void> _attachDocument() async {
    if (_generating) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['md', 'txt', 'pdf'],
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
      String content;
      if (ext == 'pdf') {
        try {
          final doc = PdfDocument(inputBytes: bytes);
          content = PdfTextExtractor(doc).extractText();
          doc.dispose();
          if (content.trim().isEmpty) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                    'PDF appears to be image-only (scanned). Pyre can\'t OCR it — paste the relevant text as a .txt or .md instead.'),
                duration: Duration(seconds: 6),
              ),
            );
            return;
          }
        } catch (e) {
          messenger.showSnackBar(SnackBar(
              content: Text('Could not parse the PDF: $e')));
          return;
        }
      } else {
        try {
          content = utf8.decode(bytes);
        } catch (e) {
          messenger.showSnackBar(SnackBar(
              content: Text('File is not valid UTF-8 text: $e')));
          return;
        }
      }

      final extracted =
          'Reference document (`${f.name}`, full contents below — treat as authoritative context for the character/scenario I\'m building):\n\n```\n$content\n```';

      if (extracted.length > _bigFileThreshold && mounted) {
        final ok = await confirmDelete(
          context,
          title: 'Big reference document',
          message:
              'This file is ${(extracted.length / 1000).toStringAsFixed(0)}k chars '
              '(~${(extracted.length / 4 / 1000).toStringAsFixed(0)}k tokens). '
              'Some models may reject the request. Pyre never truncates — '
              'the full content will be sent. Continue?',
          confirmLabel: 'Attach',
          cancelLabel: 'Cancel',
        );
        if (!ok) return;
      }

      setState(() {
        _pendingAttachments.add(_PendingAttachment(
          kind: 'doc',
          filename: f.name,
          extracted: extracted,
        ));
      });
      // Wave AY: greeting is now static (see _greeting).
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Attach failed: $e')),
      );
    }
  }

  void _removePending(_PendingAttachment a) {
    setState(() => _pendingAttachments.remove(a));
  }

  /// Inline edit on a single Sheet field. String fields get a
  /// multi-line text editor, list fields get a textarea (one item per
  /// line). The bypass goes straight to the canvas — no LLM call —
  /// for surgical fixes when the updater got something subtly wrong.
  Future<void> _editCanvasField(String key, dynamic current) async {
    final id = _sessionId;
    if (id == null) return;
    // Wave BD: alternate_greetings has its own dedicated editor — a
    // proper list of multi-line textareas with add/delete buttons.
    // The generic "one item per line" editor mangles paragraph-style
    // content because each greeting is 3-5 paragraphs of formatted
    // prose, not a single line.
    if (key == 'alternate_greetings') {
      await _editAlternateGreetings(current is List
          ? current.map((e) => '$e').toList()
          : <String>[]);
      return;
    }
    final isList = current is List;
    final isMap = current is Map;
    final initial = isList
        ? (current).map((e) => '$e').join('\n')
        : isMap
            ? const JsonEncoder.withIndent('  ').convert(current)
            : '${current ?? ''}';
    final ctl = TextEditingController(text: initial);
    final saved = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text('Edit ${_humanLabel(key)}'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              if (isList)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'One item per line.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 11),
                  ),
                )
              else if (isMap)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    'JSON object. Invalid JSON keeps the previous value.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 11),
                  ),
                ),
              TextField(
                controller: ctl,
                autofocus: true,
                minLines: 4,
                maxLines: 16,
                style: TextStyle(
                  fontFamily:
                      isMap ? 'monospace' : null,
                  fontSize: 13,
                ),
                decoration:
                    const InputDecoration(border: OutlineInputBorder()),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Dispose the controller now the dialog future has resolved — every exit
    // path below (cancel, invalid JSON, success) returns without touching it
    // again (mirrors the alt-greetings editor's controller cleanup).
    ctl.dispose();
    if (saved == null) return;
    if (!mounted) return;
    final store = context.read<AppStore>();
    final canvas = Map<String, dynamic>.from(_sessionCanvas(store));
    if (isList) {
      canvas[key] = saved
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();
    } else if (isMap) {
      try {
        final v = jsonDecode(saved);
        if (v is Map<String, dynamic>) {
          canvas[key] = v;
        } else {
          // Drop invalid JSON — keep previous.
          return;
        }
      } catch (_) {
        return;
      }
    } else {
      canvas[key] = saved;
    }
    store.updateCreatorSessionCanvas(id, canvas);
    // Show the highlight too — same affordance as an updater run.
    setState(() => _recentlyChangedCanvasKeys = {key});
    _changedHighlightTimer?.cancel();
    _changedHighlightTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _recentlyChangedCanvasKeys = const <String>{});
    });
  }

  /// Wave BD: dedicated editor for `alternate_greetings`. Renders one
  /// multi-line textarea per greeting with add/delete affordances —
  /// the user never has to think about `---` separators, JSON arrays,
  /// or any other plumbing.
  Future<void> _editAlternateGreetings(List<String> initial) async {
    final id = _sessionId;
    if (id == null) return;
    // Local working copy. We use a StatefulBuilder inside the dialog
    // so add / delete refresh the list without rebuilding the parent.
    final greetings = List<String>.from(initial.isEmpty ? [''] : initial);
    final controllers = <TextEditingController>[
      for (final g in greetings) TextEditingController(text: g),
    ];
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => Dialog(
          backgroundColor: EmberColors.bgPanel,
          insetPadding: const EdgeInsets.symmetric(
              horizontal: 16, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: 560,
              maxHeight: MediaQuery.of(ctx).size.height * 0.85,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Alternative Greetings',
                          style: TextStyle(
                            color: EmberColors.textHigh,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        color: EmberColors.textMid,
                        onPressed: () => Navigator.pop(ctx, false),
                      ),
                    ],
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
                  child: Text(
                    'Extra opening scenes the runtime can pick between. '
                    'Each one stands alone — same **bold** / *italic* '
                    'discipline as the canonical first message.',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontSize: 12,
                      height: 1.4,
                    ),
                  ),
                ),
                Flexible(
                  child: ListView.separated(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 16),
                    shrinkWrap: true,
                    itemCount: controllers.length,
                    separatorBuilder: (_, _) =>
                        const SizedBox(height: 12),
                    itemBuilder: (_, i) => Container(
                      padding: const EdgeInsets.fromLTRB(12, 8, 6, 12),
                      decoration: BoxDecoration(
                        color: EmberColors.bgDeep,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: EmberColors.stroke),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Expanded(
                                child: Text(
                                  'GREETING ${i + 1}',
                                  style: TextStyle(
                                    color: EmberColors.primary
                                        .withValues(alpha: 0.8),
                                    fontWeight: FontWeight.w700,
                                    fontSize: 10,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ),
                              IconButton(
                                icon: const Icon(
                                    Icons.delete_outline,
                                    size: 18),
                                color: EmberColors.textMid,
                                tooltip: 'Remove this greeting',
                                onPressed: controllers.length > 1
                                    ? () {
                                        setLocal(() {
                                          controllers[i].dispose();
                                          controllers.removeAt(i);
                                        });
                                      }
                                    : null,
                              ),
                            ],
                          ),
                          TextField(
                            controller: controllers[i],
                            minLines: 4,
                            maxLines: 12,
                            style: const TextStyle(
                              color: EmberColors.textHigh,
                              fontSize: 13,
                              height: 1.4,
                            ),
                            decoration: InputDecoration(
                              hintText:
                                  '*She glances up from the counter.* '
                                  '**"Back again?"**',
                              hintStyle: const TextStyle(
                                color: EmberColors.textDim,
                                fontSize: 12,
                              ),
                              filled: true,
                              fillColor: EmberColors.bgPanel,
                              isDense: true,
                              contentPadding: const EdgeInsets.symmetric(
                                  horizontal: 10, vertical: 10),
                              border: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide:
                                    BorderSide(color: EmberColors.stroke),
                              ),
                              enabledBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide:
                                    BorderSide(color: EmberColors.stroke),
                              ),
                              focusedBorder: OutlineInputBorder(
                                borderRadius: BorderRadius.circular(6),
                                borderSide: BorderSide(
                                  color: EmberColors.primary
                                      .withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
                  child: SizedBox(
                    width: double.infinity,
                    child: OutlinedButton.icon(
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('Add greeting'),
                      onPressed: () {
                        setLocal(() {
                          controllers.add(TextEditingController());
                        });
                      },
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, false),
                        child: const Text('Cancel'),
                      ),
                      const SizedBox(width: 4),
                      ElevatedButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: const Text('Save'),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final committed = saved == true;
    final values = controllers.map((c) => c.text.trim()).toList();
    for (final c in controllers) {
      c.dispose();
    }
    if (!committed || !mounted) return;
    final store = context.read<AppStore>();
    final canvas = Map<String, dynamic>.from(_sessionCanvas(store));
    canvas['alternate_greetings'] =
        values.where((v) => v.isNotEmpty).toList();
    store.updateCreatorSessionCanvas(id, canvas);
    setState(() => _recentlyChangedCanvasKeys = {'alternate_greetings'});
    _changedHighlightTimer?.cancel();
    _changedHighlightTimer = Timer(const Duration(seconds: 2), () {
      if (!mounted) return;
      setState(() => _recentlyChangedCanvasKeys = const <String>{});
    });
  }

  static String _humanLabel(String key) {
    switch (key) {
      case 'name':
        return 'name';
      case 'description':
        return 'description';
      case 'personality':
        return 'personality';
      case 'scenario':
        return 'scenario';
      case 'first_mes':
        return 'first message';
      case 'mes_example':
        return 'message examples';
      case 'creator_notes':
        return 'creator notes';
      case 'system_prompt':
        return 'system prompt';
      case 'post_history_instructions':
        return 'post-history instructions';
      case 'alternate_greetings':
        return 'alternate greetings';
      case 'tags':
        return 'tags';
      case 'creator':
        return 'creator';
      case 'character_version':
        return 'version';
      case 'extensions':
        return 'extensions';
      default:
        return key;
    }
  }

  /// User-initiated cancel. Aborts the active stream subscription
  /// (whatever the model has streamed so far stays in the bubble)
  /// and flushes the partial reply to disk right away so a quick
  /// "back" press doesn't lose it.
  ///
  /// Wave CY.18.44: also nuke the stream-state scratch (`_streamBuffer`,
  /// `_continuationAttempts`, `_continuationLog`, `_updatingCanvas`).
  /// Pre-Wave, only `_abortInFlightStream` cleared these; user-initiated
  /// Stop kept the partial buffer + continuation counter around, so if
  /// the next turn fired a SHEET emission it would (a) parse the OLD
  /// partial buffer as part of the new response — contaminating the
  /// canvas with leftovers from the cancelled turn — and (b) use a non-
  /// zero `_continuationAttempts` budget against the new turn,
  /// truncating the retry window. Reset both so a stopped-then-resumed
  /// turn behaves like a fresh start.
  void _stop() {
    _streamSub?.cancel();
    _streamSub = null;
    // Wave CY.18.44: bump generation so any in-flight callbacks from the
    // cancelled stream (or its pending continuations / canvas updater)
    // become no-ops if they fire after this point.
    _streamGen++;
    _keepAliveStop();
    setState(() => _generating = false);
    context.read<AppStore>().flushPersist();
    _streamBuffer = '';
    _updatingCanvas = false;
  }

  /// Wave CY.18.20: hard-reset stream state when the user navigates
  /// between sessions (switch / create / delete) mid-generation.
  /// Without this, the in-flight stream keeps appending chunks to
  /// the FORMER session's messages via the `reply` reference it
  /// closed over — silently corrupting both sessions (the old one
  /// gets a half-baked reply written into the wrong index after the
  /// list mutated, the new one shows "Generating…" forever because
  /// `_generating` was never cleared). Cancels the stream subscription,
  /// drops the keep-alive, and clears the generating flag + stream
  /// buffer + continuation counter so the new session starts clean.
  void _abortInFlightStream() {
    // Audit 2026-06-04 (Creator M2): a structured build is ALSO in-flight
    // work that a session switch/delete must tear down — but it doesn't use
    // `_streamSub` (it runs through `completeChatStreamed` internally) and
    // leaves `_generating` false (it tracks `_structuredBuilding` instead).
    // So the old `_streamSub == null && !_generating` early-return skipped it
    // entirely: the build kept running and its status/offer bubbles landed in
    // the now-active session. Treat an in-flight build as a reason NOT to
    // early-return so we bump `_streamGen` (tripping the build's `myGen` guard)
    // and clear `_structuredBuilding` (so the new session isn't locked out).
    if (_streamSub == null && !_generating && !_structuredBuilding) return;
    _streamSub?.cancel();
    _streamSub = null;
    // Wave CY.18.44: bump generation — abort means we're tearing down
    // for a session switch / delete, and any callback from the OLD
    // stream that fires after this point must not touch state belonging
    // to whatever session is now active.
    _streamGen++;
    _keepAliveStop();
    // Flush whatever's been streamed so far so it survives — that
    // belongs to the FORMER session (the one we're about to leave).
    context.read<AppStore>().flushPersist();
    _streamBuffer = '';
    _generating = false;
    _updatingCanvas = false;
    // Creator M2: drop the build lock so `_canStructuredBuild` / the
    // `[[BUILD_SHEET]]` marker can start a fresh build in the new session.
    // The aborted build's `finally` will also set this false — harmless.
    _structuredBuilding = false;
  }

  // ---------------------------------------------------------------------------
  // Long-press message actions

  /// Long-press menu on any creator message. Same shape as the chat
  /// screen's — Copy / Quote / Edit / Delete / Retry — adapted to the
  /// creator's lack of variants (one content per message; no
  /// alternate-greeting / regenerate-as-variant flow).
  Future<void> _showMessageMenu(CreatorMessage m) async {
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    final messages = _sessionMessages(store);
    final index = messages.indexOf(m);
    if (index < 0) return;
    final isLast = index == messages.length - 1;
    final isUser = m.role == 'user';
    final isAssistant = m.role == 'assistant';
    final canRetry = isAssistant &&
        isLast &&
        !_generating &&
        messages.length >= 2 &&
        messages[messages.length - 2].role == 'user';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (canRetry)
              ListTile(
                leading: const Icon(Icons.refresh,
                    color: EmberColors.primary),
                title: const Text('Retry (regenerate this reply)'),
                onTap: () {
                  Navigator.pop(sheet);
                  _retry();
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () async {
                Navigator.pop(sheet);
                await Clipboard.setData(ClipboardData(text: m.content));
                messenger.showSnackBar(
                    const SnackBar(content: Text('Copied.')));
              },
            ),
            if (isUser)
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('Edit + re-run from here'),
                subtitle: const Text(
                  'Replaces your message and drops everything that came after — the assistant generates a fresh reply.',
                  style: TextStyle(
                      color: EmberColors.textMid, fontSize: 11),
                ),
                onTap: () {
                  Navigator.pop(sheet);
                  _editUserMessage(m);
                },
              ),
            const Divider(color: EmberColors.stroke),
            Builder(builder: (_) {
              final cascade = store.chatSettings.cascadeDelete;
              return ListTile(
                leading: const Icon(Icons.delete_outline,
                    color: EmberColors.danger),
                title: Text(
                  cascade ? 'Delete this and after' : 'Delete just this',
                  style: const TextStyle(color: EmberColors.danger),
                ),
                subtitle: cascade
                    ? const Text(
                        'Chat Settings → Delete behavior is on "This and after".',
                        style: TextStyle(
                            color: EmberColors.textMid, fontSize: 11),
                      )
                    : null,
                onTap: () async {
                  Navigator.pop(sheet);
                  if (cascade) {
                    final ok = await confirmDelete(
                      context,
                      title: 'Delete this and all messages after?',
                      message:
                          'You\'ll lose this message and every reply that came after it.',
                    );
                    if (!ok) return;
                  }
                  _deleteMessage(m, cascade: cascade);
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  /// Open an inline editor for a USER message. On save, truncate the
  /// session at this point and re-run the conversation — same pattern
  /// as ChatGPT / Claude's "edit + re-submit" flow.
  Future<void> _editUserMessage(CreatorMessage m) async {
    final store = context.read<AppStore>();
    final messages = _sessionMessages(store);
    final index = messages.indexOf(m);
    if (index < 0) return;
    final ctl = TextEditingController(text: m.content);
    final newText = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Edit your message'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          minLines: 3,
          maxLines: 8,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save & re-run'),
          ),
        ],
      ),
    );
    ctl.dispose(); // H-3: dispose the edit-message controller on dialog close.
    if (newText == null || newText.isEmpty) return;
    if (!mounted) return;
    // Truncate everything after this user message, then update its
    // content. Attachments stay (the user is editing the text, not the
    // attached image/card/doc).
    final truncated = List<CreatorMessage>.from(messages.sublist(0, index));
    truncated.add(CreatorMessage(
      role: 'user',
      content: newText,
      attachments: m.attachments,
    ));
    _persistMessages(store, truncated);
    setState(() {
      _generating = true;
      _streamBuffer = '';
    });
    _scrollToBottom();
    await _runConversation();
  }

  /// Delete a message. Cascade = drop everything from this index
  /// onwards (matches the chat_screen / lin-conversation behaviour).
  void _deleteMessage(CreatorMessage m, {required bool cascade}) {
    final store = context.read<AppStore>();
    final messages = List<CreatorMessage>.from(_sessionMessages(store));
    final index = messages.indexOf(m);
    if (index < 0) return;
    if (cascade) {
      messages.removeRange(index, messages.length);
    } else {
      messages.removeAt(index);
    }
    _persistMessages(store, messages);
  }

  /// Drop the last assistant message and re-run the conversation from
  /// the same state. The previous user turn (with its attachments)
  /// stays in place, so the model gets the exact same prompt and
  /// streams a fresh reply into a new empty placeholder.
  Future<void> _retry() async {
    if (_generating) return;
    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;
    final messages = List<CreatorMessage>.from(_sessionMessages(store));
    if (messages.isEmpty || messages.last.role != 'assistant') return;
    // Wave CV.20: restore the pre-turn canvas snapshot before
    // re-firing, so the new attempt starts from a clean state instead
    // of stacking on top of whatever fields the old attempt wrote.
    // Legacy assistant messages (saved before this wave) have no
    // snapshot — skip the restore in that case.
    //
    // Wave CY: deep-copy via jsonEncode/Decode. Map.from is a SHALLOW
    // copy — the restored canvas would otherwise share nested List /
    // Map references with the stored snapshot, so any later mutation
    // (model edits, user tweaks) would corrupt the snapshot itself
    // and defeat the whole point of being able to retry cleanly.
    final snapshot = messages.last.canvasSnapshot;
    if (snapshot != null) {
      final restored = jsonDecode(jsonEncode(snapshot)) as Map<String, dynamic>;
      store.updateCreatorSessionCanvas(id, restored);
    }
    // Drop the assistant reply we're retrying.
    messages.removeLast();

    // Wave BN: if the assistant we just dropped was a FAILED vision
    // turn (the preceding user message has an image attachment but
    // the vision profile never landed), retry the VISION call — not
    // the architect chat. Falling through to _runConversation here
    // (the old behaviour) would make DeepSeek hallucinate a generic
    // description because the architect has no eyes. The whole
    // point of the vision-then-architect split is that vision lays
    // down the clinical visual ground truth.
    final lastUser = messages.isNotEmpty &&
            messages.last.role == 'user'
        ? messages.last
        : null;
    final imageAttachment = lastUser?.attachments.firstWhere(
      (a) => a.kind == 'image' && a.imageDataUrl != null,
      orElse: () => CreatorAttachment(
          kind: '', filename: '', imageDataUrl: null, extracted: ''),
    );
    final hasImageToReanalyse =
        imageAttachment != null && imageAttachment.imageDataUrl != null;

    _persistMessages(store, messages);
    setState(() {
      _generating = true;
      _streamBuffer = '';
    });
    _scrollToBottom();

    if (hasImageToReanalyse) {
      await _retryVisionTurn(
        store: store,
        messages: messages,
        userTurn: lastUser!,
        imageAttachment: imageAttachment,
      );
    } else {
      await _runConversation();
    }
  }

  /// Wave BN: re-run the vision pipeline on the SAME image attachment
  /// from the preceding user turn. Decodes the bytes back out of the
  /// stored data URL, fires `describeCharacterImage` with the dedicated
  /// vision provider (falls back to creator → activeProvider), and
  /// appends the resulting profile as a fresh assistant message —
  /// same shape as the original successful path. Keep-alive wraps the
  /// call so a background-minimised retry doesn't get killed mid-way.
  Future<void> _retryVisionTurn({
    required AppStore store,
    required List<CreatorMessage> messages,
    required CreatorMessage userTurn,
    required CreatorAttachment imageAttachment,
  }) async {
    final visionProv = store.visionProvider;
    if (visionProv == null) {
      _finishWithError(
        'No vision provider configured. Open More → API Connections.',
      );
      return;
    }
    Uint8List bytes;
    try {
      bytes = base64Decode(imageAttachment.imageDataUrl!.split(',').last);
    } catch (e) {
      _finishWithError(
        'Could not decode the image bytes for retry: $e',
      );
      return;
    }
    final placeholder = CreatorMessage(role: 'assistant', content: '');
    final newMessages = List<CreatorMessage>.from(messages)..add(placeholder);
    _persistMessages(store, newMessages);
    await _keepAliveStart();
    try {
      final profile = await describeCharacterImage(
        provider: visionProv,
        settings: _visionSettings(store.modelSettings),
        imageBytes: bytes,
        userNote: userTurn.content,
      );
      if (!mounted) return;
      placeholder.content = profile;
      _persistMessages(store, newMessages);
      setState(() => _generating = false);
      _scrollToBottom();
      context.read<AppStore>().flushPersist();
    } catch (e) {
      if (!mounted) return;
      placeholder.content =
          '⚠ Could not analyse `${imageAttachment.filename}`: $e\n\n'
          'Switch the creator provider to a vision-capable one '
          '(Venice qwen, Pixtral, Qwen-VL, Claude / GPT) in More → '
          'API Connections.';
      _persistMessages(store, newMessages);
      setState(() => _generating = false);
    } finally {
      _keepAliveStop();
    }
  }

  /// Surface a stream / network error in the chat. When [reply] is the
  /// empty assistant placeholder we added at turn-start, mutate it in
  /// place — otherwise we'd leave a "…" floating above the actual
  /// error and the chat would look broken.
  ///
  /// Wave CH: parses ChatApiError JSON payloads so insufficient-credits,
  /// rate-limit, content-filter, etc. surface as the actual upstream
  /// message instead of raw JSON. The full original body is appended
  /// inside `<<PYRE_ERR_DETAILS>>...<<PYRE_ERR_DETAILS_END>>` markers
  /// so the renderer can offer a "Show full error" collapsible — the
  /// info is still there, just hidden by default.
  void _finishWithError(String message,
      {CreatorMessage? reply, Object? originalError}) {
    // Wave BM: drop the keep-alive refcount — stream is dead, no
    // reason to keep the foreground notification up. Safe even if
    // start() was never called (refcount clamps at zero).
    _keepAliveStop();
    if (!mounted) return;
    final store = context.read<AppStore>();
    final messages = List<CreatorMessage>.from(_sessionMessages(store));
    // Wave CY.18.45: short-circuit on typed network errors so the user
    // gets "you appear to be offline" instead of a fully-formatted JSON
    // error block for an exception that didn't have a JSON body.
    final String formatted;
    if (originalError is ChatApiError &&
        (originalError.kind == ChatApiErrorKind.offline ||
            originalError.kind == ChatApiErrorKind.timeout)) {
      formatted = originalError.kind == ChatApiErrorKind.offline
          ? 'You appear to be offline. Check your connection and tap '
              'Retry.'
          : originalError.message;
    } else {
      formatted = _formatApiError(message);
    }
    if (reply != null && reply.content.isEmpty) {
      reply.content = formatted;
    } else {
      messages.add(CreatorMessage(role: 'assistant', content: formatted));
    }
    _persistMessages(store, messages);
    setState(() => _generating = false);
    _scrollToBottom();
  }

  /// Wave CH: turn a raw exception string into a user-readable error
  /// message. Handles ChatApiError JSON bodies from the most common
  /// OpenAI-compatible shapes:
  ///   - `{ "error": { "message": "...", "type": "...", "code": "..." } }`
  ///     (OpenAI, OpenRouter, DeepSeek, Anthropic)
  ///   - `{ "message": "..." }` (Some Risu, Chub routes)
  ///   - `{ "detail": "..." }` (FastAPI-style)
  /// Falls back to the raw text when nothing parses.
  ///
  /// Returns markdown — friendly headline + the original full text
  /// wrapped in `<<PYRE_ERR_DETAILS>>...<<PYRE_ERR_DETAILS_END>>`
  /// so the renderer can collapse it.
  String _formatApiError(String raw) {
    String? friendly;
    String? statusTag;
    final apiMatch =
        RegExp(r'ChatApiError\((\d+)\):\s*(.*)$', dotAll: true)
            .firstMatch(raw);
    if (apiMatch != null) {
      final status = apiMatch.group(1)!;
      final body = apiMatch.group(2)!;
      statusTag = 'HTTP $status';
      try {
        final parsed = jsonDecode(body);
        if (parsed is Map) {
          final err = parsed['error'];
          if (err is Map && err['message'] is String) {
            friendly = err['message'] as String;
          } else if (err is String) {
            friendly = err;
          } else if (parsed['message'] is String) {
            friendly = parsed['message'] as String;
          } else if (parsed['detail'] is String) {
            friendly = parsed['detail'] as String;
          }
        }
      } catch (_) {/* not JSON — leave friendly null */}
    }
    final headline = friendly ?? raw;
    final tag = statusTag != null ? ' ($statusTag)' : '';
    return '⚠ $headline$tag\n\n'
        '<<PYRE_ERR_DETAILS>>$raw<<PYRE_ERR_DETAILS_END>>';
  }

  // ---------------------------------------------------------------------------
  // Save & refine
  //
  // Saving has two flavours, both reachable from a bottom sheet:
  //   - "Save to library" — adds the character to the store and pushes
  //     the regular editor (where the user can tweak before exporting).
  //   - "Save & export PNG" — also writes a chara_card_v2 PNG with the
  //     picked avatar bytes embedded, then opens the share sheet so the
  //     user can upload it to botbooru / Discord / wherever in one tap.
  //
  // Picking an avatar is OPTIONAL for the library save. The PNG export
  // path is greyed out until an image is picked, since chara_card_v2
  // PNGs need real image bytes to embed metadata into.

  Future<void> _saveCard() async {
    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;
    final canvas = _sessionCanvas(store);
    final messenger = ScaffoldMessenger.of(context);
    if (canvas.isEmpty ||
        (canvas['name'] is! String) ||
        (canvas['name'] as String).trim().isEmpty) {
      messenger.showSnackBar(const SnackBar(
        content: Text(
            'Sheet needs at least a name before saving. Keep chatting — it\'ll fill in.'),
      ));
      return;
    }
    // Persona Creator: a persona-mode session saves a Persona, not a
    // Character. The save sheet is simpler (name + avatar + one "Save
    // persona" button) and prefills the avatar from the persona being
    // edited.
    final session = store.activeCreatorSession;
    final isPersona = session?.mode == 'persona';
    if (isPersona) {
      final editPersonaId = session?.editingPersonaId;
      String? personaAvatarUrl;
      List<String> personaLorebookIds = const <String>[];
      if (editPersonaId != null) {
        for (final p in store.personas) {
          if (p.id == editPersonaId) {
            personaAvatarUrl = p.avatar;
            personaLorebookIds = List<String>.from(p.lorebookIds);
            break;
          }
        }
      }
      // Wave CY.18.217: when EDITING an existing persona, ask whether to
      // overwrite the original or save the result as a new copy (so the
      // original persona is left untouched). Create-from-scratch sessions
      // (editPersonaId == null) skip the prompt and always add new.
      _SaveMode saveMode = _SaveMode.copy;
      if (editPersonaId != null) {
        final picked = await _askSaveMode(isPersona: true);
        if (picked == null) return; // user cancelled
        saveMode = picked;
      }
      if (!mounted) return;
      await showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        backgroundColor: EmberColors.bgPanel,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
        ),
        builder: (_) => _SaveCardSheet(
          canvas: canvas,
          existingAvatarDataUrl: personaAvatarUrl,
          personaMode: true,
          initialLorebookIds: personaLorebookIds,
          onSubmit: ({
            required Uint8List? avatarPng,
            required _SaveAction action,
            required List<String> lorebookIds,
          }) =>
              _commitSavePersona(
            canvas: canvas,
            avatarPng: avatarPng,
            saveAsCopy: saveMode == _SaveMode.copy,
            lorebookIds: lorebookIds,
          ),
        ),
      );
      return;
    }
    // Wave CV.16: when editing an existing character, prefill the
    // save-sheet avatar slot from the original card so the user isn't
    // asked to re-pick. The save-sheet still allows replacing it.
    final editTargetId = store.activeCreatorSession?.editingCharacterId;
    final existingChar =
        editTargetId != null ? store.characterById(editTargetId) : null;
    final existingAvatarUrl = existingChar?.avatar;
    final existingCharLorebookIds = existingChar != null
        ? List<String>.from(existingChar.lorebookIds)
        : const <String>[];
    // Wave CY.18.217: editing an existing character (or scenario card —
    // scenario cards ARE Characters) prompts for overwrite vs save-as-copy
    // BEFORE the save sheet. Create-from-scratch (editTargetId == null)
    // always adds new, so no prompt.
    _SaveMode charSaveMode = _SaveMode.copy;
    if (editTargetId != null) {
      final picked = await _askSaveMode(isPersona: false);
      if (picked == null) return; // user cancelled
      charSaveMode = picked;
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: EmberColors.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => _SaveCardSheet(
        canvas: canvas,
        existingAvatarDataUrl: existingAvatarUrl,
        initialLorebookIds: existingCharLorebookIds,
        onSubmit: ({
          required Uint8List? avatarPng,
          required _SaveAction action,
          required List<String> lorebookIds,
        }) =>
            _commitSave(
          canvas: canvas,
          avatarPng: avatarPng,
          action: action,
          saveAsCopy: charSaveMode == _SaveMode.copy,
          lorebookIds: lorebookIds,
        ),
      ),
    );
  }

  /// Wave CY.18.217: when saving an EDITED card, ask whether to overwrite
  /// the original in place or fork a new copy (leaving the original
  /// untouched). Returns null if the user dismisses the dialog. The
  /// "Save as a copy" option is presented first / as the safer choice
  /// for edits of bundled or imported cards.
  Future<_SaveMode?> _askSaveMode({required bool isPersona}) {
    final noun = isPersona ? 'persona' : 'card';
    return showDialog<_SaveMode>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Save your edits'),
        content: Text(
          'You\'re editing an existing $noun. Overwrite the original, or '
          'save your changes as a new copy and leave the original $noun '
          'untouched?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, _SaveMode.overwrite),
            child: const Text('Overwrite original'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, _SaveMode.copy),
            child: const Text('Save as a copy'),
          ),
        ],
      ),
    );
  }

  /// Persona Creator: build a Persona from the canvas + chosen avatar,
  /// persist it (update-in-place when editing, else add), and pop back
  /// to the Personas list. No PNG export / start-chat / library actions
  /// — those are character-only.
  Future<void> _commitSavePersona({
    required Map<String, dynamic> canvas,
    required Uint8List? avatarPng,
    // Lorebook bindings chosen in the save sheet — the single source of truth
    // for ALL paths (fresh create now CAN bind; edit is seeded with the
    // original's bindings so default behaviour is preserved + editable).
    required List<String> lorebookIds,
    // Wave CY.18.217: when true (edit mode + user chose "Save as a copy"),
    // fork a brand-new persona instead of updating the original in place.
    bool saveAsCopy = false,
  }) async {
    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);
    final session = store.activeCreatorSession;

    var name = (canvas['name'] is String)
        ? (canvas['name'] as String).trim()
        : '';
    final description =
        canvasText(canvas['description']).trim();
    final dialogue = canvasText(canvas['mes_example']).trim();
    final taglineRaw = canvasText(canvas['tagline']).trim();
    final tagline = taglineRaw.isEmpty ? null : taglineRaw;
    // B-2 / H-6: externalise the chosen avatar into the AttachmentStore so the
    // persona persists a pyre:// ref, not inline base64 (web → data: fallback).
    final avatarUrl =
        avatarPng != null ? await externalizeImageBytes(avatarPng) : null;

    final editTargetId = session?.editingPersonaId;
    Persona? existing;
    if (editTargetId != null) {
      for (final p in store.personas) {
        if (p.id == editTargetId) {
          existing = p;
          break;
        }
      }
    }

    // Wave CY.18.217: "Save as a copy" — leave `existing` aside so we
    // fall into the add-new branch, but inherit the original's avatar /
    // lorebooks / gallery so the fork is a faithful copy. Suffix the name
    // with " (copy)" so it's distinguishable in the Personas list.
    if (saveAsCopy && existing != null) {
      name = withCopyNameSuffix(name.isEmpty ? existing.name : name);
      final created = Persona(
        id: newId('persona'),
        name: name,
        tagline: tagline,
        description: description,
        dialogueExamples: dialogue,
        avatar: avatarUrl ?? existing.avatar,
        lorebookIds: List<String>.from(lorebookIds),
        gallery: List<String>.from(existing.gallery),
      );
      store.addPersona(created);
      store.markCreatorSessionSaved(id, created.id);
      store.flushPersist();
      if (!mounted) return;
      store.setActiveTab('characters');
      Navigator.of(context).pop();
      if (mounted) Navigator.of(context).pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('Saved $name as a new persona.'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    if (existing != null) {
      // Update in place — preserve id / createdAt / lorebooks / gallery /
      // favorite; keep the old avatar when the user didn't pick a new one.
      final updated = Persona(
        id: existing.id,
        name: name.isEmpty ? existing.name : name,
        tagline: tagline,
        description: description,
        dialogueExamples: dialogue,
        avatar: avatarUrl ?? existing.avatar,
        lorebookIds: List<String>.from(lorebookIds),
        gallery: List<String>.from(existing.gallery),
        createdAt: existing.createdAt,
        favorite: existing.favorite,
      );
      store.updatePersona(updated);
      store.markCreatorSessionSaved(id, updated.id);
    } else {
      final created = Persona(
        id: newId('persona'),
        name: name.isEmpty ? 'You' : name,
        tagline: tagline,
        description: description,
        dialogueExamples: dialogue,
        avatar: avatarUrl,
        lorebookIds: List<String>.from(lorebookIds),
      );
      store.addPersona(created);
      store.markCreatorSessionSaved(id, created.id);
    }
    store.flushPersist();

    if (!mounted) return;
    // Pop the save modal first, then the assistant screen, landing on the
    // Characters tab (Personas segment lives there).
    store.setActiveTab('characters');
    Navigator.of(context).pop();
    if (mounted) Navigator.of(context).pop();
    messenger.showSnackBar(
      SnackBar(
        content: Text('Saved ${name.isEmpty ? 'persona' : name} '
            'to your personas.'),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 3),
      ),
    );
  }

  /// Build the Character, persist it, then run the user's chosen
  /// follow-up action (start a chat / open editor / export PNG).
  /// Called from the bottom sheet — has full context already.
  Future<void> _commitSave({
    required Map<String, dynamic> canvas,
    required Uint8List? avatarPng,
    required _SaveAction action,
    // Lorebook bindings chosen in the save sheet — the single source of truth
    // for ALL paths. Fresh builds can now bind a world (the gap this closes);
    // edit/copy are seeded with the original's bindings so default behaviour
    // is preserved and the user can re-bind in the same sheet.
    required List<String> lorebookIds,
    // Wave CY.18.217: when true (edit mode + user chose "Save as a copy"),
    // mint a brand-new character instead of overwriting the original. The
    // original card (and any chats pointing at it) are left untouched.
    bool saveAsCopy = false,
  }) async {
    final store = context.read<AppStore>();
    final id = _sessionId;
    if (id == null) return;
    final messenger = ScaffoldMessenger.of(context);

    final wrapped = <String, dynamic>{
      'spec': 'chara_card_v2',
      'spec_version': '2.0',
      'data': canvas,
    };
    Character c;
    try {
      final cc = parseCharaCardJson(jsonEncode(wrapped));
      c = characterFromCharaCard(cc);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not build card from canvas: $e')),
      );
      return;
    }
    // Wave BC: prefer the user's botbooru username (set in More →     // BotBooru Profile) so cards built in the Creator carry the
    // botbooru identity when uploaded back. Falls back to the active
    // persona's name, then a generic label.
    //
    // Wave CL: the architect prompt explicitly tells the model NOT
    // to emit a `Creator:` label (the runtime owns it). So `c.creator`
    // is virtually always empty at this point, and the previous
    // replaceAll on the literal `{{creator}}` token was a no-op for
    // every real card. Now we AUTO-FILL c.creator when empty, and
    // still honour the placeholder for the rare card that has it.
    final creatorName = store.botbooruUsername.isNotEmpty
        ? store.botbooruUsername
        : (store.activePersona?.name ?? 'a Pyre user');
    c = Character.fromJson(c.toJson())
      ..creator = c.creator.trim().isEmpty
          ? creatorName
          : c.creator.replaceAll('{{creator}}', creatorName);
    if (avatarPng != null) {
      // B-2 / H-6: externalise the chosen avatar into the AttachmentStore so
      // the character persists a pyre:// ref, not inline base64 (web → data:).
      c.avatar = await externalizeImageBytes(avatarPng);
    }
    // Wave CY.18.36: mark this character as Pyre-built so the Profile
    // screen's "Cards created" stat counts it. Skipped on Edit-with-AI
    // sessions below — those route through `updateCharacter` and the
    // original character's createdInPyre flag is preserved (an
    // imported card edited via the AI editor doesn't become "created
    // in Pyre"; it was still imported).
    c.createdInPyre = true;
    // Lorebook bindings from the save sheet apply to EVERY path (fresh create,
    // overwrite, copy, and the deleted-mid-session fallback). The canvas never
    // carries lorebookIds, so this is the only place they're set — closing the
    // gap where a fresh Creator build could never bind a world.
    c.lorebookIds = List<String>.from(lorebookIds);
    // Wave CS: "Edit with AI" session — UPDATE the existing character
    // in place rather than creating a new one. Preserves the original
    // character id (so existing chats keep pointing at it), the original
    // createdAt, and the original avatar when the user didn't pick a
    // new one this session.
    final editTarget = store.activeCreatorSession?.editingCharacterId;
    if (editTarget != null && !saveAsCopy) {
      final original = store.characterById(editTarget);
      if (original != null) {
        c.id = original.id;
        c.createdAt = original.createdAt;
        // (lorebookIds already set from the save sheet above.)
        // Wave CY.18.36: Edit-with-AI doesn't change provenance — if
        // the original was imported, it stays imported (createdInPyre
        // = false). My new-card-default of true above gets overwritten
        // here on the edit path.
        c.createdInPyre = original.createdInPyre;
        // Keep original avatar when the user didn't pick a new one
        // — the canvas doesn't carry avatar bytes.
        if (avatarPng == null && c.avatar == null) {
          c.avatar = original.avatar;
        }
        // Audit 2026-06-05: the canvas rebuild drops gallery / favorite /
        // talkativeness (none round-trip through the chara_card `data` block),
        // so without restoring them an AI overwrite silently WIPED the card's
        // extra gallery images, un-starred a favourited card, and dropped
        // talkativeness. The persona edit path already restored its extras
        // from `existing`; mirror that here. keepFavorite: true — an in-place
        // overwrite IS the same record, so its star carries over.
        restoreCanvasDroppedExtras(c, original, keepFavorite: true);
        store.updateCharacter(c);
        store.markCreatorSessionSaved(id, c.id);
      } else {
        // Original was deleted mid-session — fall back to creating new.
        store.addCharacter(c);
        store.markCreatorSessionSaved(id, c.id);
      }
    } else if (editTarget != null && saveAsCopy) {
      // Wave CY.18.217: "Save as a copy" — fork a NEW card, leaving the
      // original untouched. `c` already carries a fresh id (minted by
      // characterFromCharaCard) and the edited fields. Inherit the
      // original's lorebook bindings + avatar (when the user didn't pick
      // a new one) so the copy is faithful, suffix the name with
      // " (copy)", and ADD it (NOT update).
      final original = store.characterById(editTarget);
      // (lorebookIds already set from the save sheet above.)
      if (original != null) {
        if (avatarPng == null && c.avatar == null) {
          c.avatar = original.avatar;
        }
        // A faithful fork carries the original's extra art + talkativeness
        // (dropped by the canvas rebuild). keepFavorite: false — a fresh copy
        // is its own new record and intentionally starts unstarred.
        restoreCanvasDroppedExtras(c, original, keepFavorite: false);
      }
      c.name = withCopyNameSuffix(c.name);
      // A forked copy made in Pyre is genuinely a new Pyre-built card,
      // so the createdInPyre = true default above stands (no override).
      store.addCharacter(c);
      store.markCreatorSessionSaved(id, c.id);
    } else {
      store.addCharacter(c);
      store.markCreatorSessionSaved(id, c.id);
    }

    switch (action) {
      case _SaveAction.startChat:
        // Default action — land the user straight in a fresh chat
        // with the character they just built. Closes the loop:
        // create → test → return to refine if needed.
        //
        // Wave CY.18.1: route through the shared helper so the
        // per-chat persona picker honours askPersonaOnNewChat here
        // too (previously bypassed when finishing in the creator).
        if (!mounted) return;
        await startNewChatWithPersonaPrompt(context, c, replace: true);
        break;
      case _SaveAction.library:
        // Wave CQ: just persist and bounce back to the Characters tab.
        // No editor (the user JUST finished building — opening the
        // editor immediately was busywork), no chat. Confirmation
        // surfaces via snackbar on the destination screen.
        //
        // Wave CV.16: previous `popUntil((r) => r.isFirst)` could over-
        // pop when navigating from inside a modal sheet stack, leaving
        // the user on a black screen after the SaveCardSheet's own
        // post-await `pop()` ran. Use explicit pops: one for the sheet
        // (modal), one for the assistant screen. The sheet's own pop
        // is no-op via `mounted=false` once the assistant screen unmounts.
        if (!mounted) return;
        store.setActiveTab('characters');
        // Pop the save modal first.
        Navigator.of(context).pop();
        // Then close the assistant screen, landing on Characters.
        if (mounted) Navigator.of(context).pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text('Saved ${c.name} to your characters.'),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 3),
          ),
        );
        break;
      case _SaveAction.exportPng:
        // Two paths: web (no filesystem → clipboard data URL),
        // native (write to PyreExports + share sheet). Mirrors the
        // export logic in characters_screen.dart so the user gets
        // the same UX whether they export from the list or from
        // the creator.
        if (avatarPng == null) {
          messenger.showSnackBar(const SnackBar(
            content: Text('Pick an avatar before exporting as PNG.'),
          ));
          return;
        }
        try {
          final pngBytes = encodeCharaCardPng(c, avatarPng);
          final safeName = c.name
              .replaceAll(RegExp(r'[^A-Za-z0-9 _\-.]'), '')
              .trim()
              .replaceAll(' ', '_');
          final filename =
              '${safeName.isEmpty ? 'card' : safeName}.card.png';
          if (kIsWeb) {
            final dataUrl =
                'data:image/png;base64,${base64Encode(pngBytes)}';
            await Clipboard.setData(ClipboardData(text: dataUrl));
            messenger.showSnackBar(const SnackBar(
                content: Text(
                    'Web: copied PNG as data URL to clipboard. Paste into an image editor to save.')));
          } else {
            final dir = await getApplicationDocumentsDirectory();
            final outDir = Directory('${dir.path}/PyreExports');
            if (!await outDir.exists()) {
              await outDir.create(recursive: true);
            }
            final file = File('${outDir.path}/$filename');
            await file.writeAsBytes(pngBytes);
            try {
              await Share.shareXFiles(
                [XFile(file.path, mimeType: 'image/png')],
                subject: '${c.name} — Pyre card',
                text: 'Character card exported from Pyre.',
              );
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(
                    content: Text(
                        'Share failed: $e — file saved to ${file.path}')),
              );
            }
          }
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('PNG export failed: $e')),
          );
        }
        break;
    }
  }

  // ---------------------------------------------------------------------------
  // Session drawer actions

  void _switchSession(String id) {
    // Wave CY.18.20: drop any in-flight stream BEFORE we change
    // `_sessionId` so the stream's closed-over reply reference
    // can't keep appending to the FORMER session after we leave.
    _abortInFlightStream();
    final store = context.read<AppStore>();
    store.setActiveCreatorSession(id);
    setState(() {
      _sessionId = id;
      // Wave CY.18.113: chat-first on session switch too, consistent
      // with open — land in the conversation; tap "Sheet" to review
      // the card. (Reverts Wave CY.18.16's sheet-first default.)
      _showCanvas = false;
      _streamBuffer = '';
    });
    Navigator.of(context).pop(); // close drawer
    _scrollToBottom();
  }

  void _createNewSession() {
    // Wave CY.18.20: same rationale as `_switchSession` — abort
    // any stream that's still writing into the prior session
    // before we mint a new one.
    _abortInFlightStream();
    final store = context.read<AppStore>();
    final s = store.newCreatorSession();
    store.updateCreatorSessionMessages(s.id, [
      CreatorMessage(role: 'assistant', content: _greeting),
    ]);
    _prepopulateCreatorOnCanvas(store, s.id);
    setState(() {
      _sessionId = s.id;
      // Wave CY.18.113: chat-first (see _switchSession). A brand-new
      // session has an empty sheet anyway — the greeting + input live
      // in the chat.
      _showCanvas = false;
      _streamBuffer = '';
    });
    Navigator.of(context).pop(); // close drawer
  }

  Future<void> _renameSessionPrompt(CreatorSession s) async {
    final ctl = TextEditingController(text: s.derivedTitle());
    final renamed = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Rename session'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Session title'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, null),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, ''),
            child: const Text('Reset'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, ctl.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    ctl.dispose(); // H-3: dispose the session-rename controller on dialog close.
    if (renamed == null) return;
    if (!mounted) return;
    final store = context.read<AppStore>();
    store.renameCreatorSession(s.id, renamed.isEmpty ? null : renamed);
  }

  Future<void> _deleteSessionPrompt(CreatorSession s) async {
    final ok = await confirmDelete(
      context,
      title: 'Delete session?',
      message:
          'This deletes the conversation and the canvas for "${s.derivedTitle()}". Saved characters are NOT removed.',
      confirmLabel: 'Delete',
    );
    if (!ok) return;
    if (!mounted) return;
    final store = context.read<AppStore>();
    final wasActive = s.id == _sessionId;
    // Wave CY.18.20: deleting the active session mid-generation
    // would orphan the stream onto a session that no longer
    // exists in the store, so the next chunk's `_persistMessages`
    // crashes on a null lookup. Abort before the removeCreatorSession.
    if (wasActive) _abortInFlightStream();
    store.removeCreatorSession(s.id);
    if (wasActive) {
      // Activate whatever's left, or bootstrap a fresh one.
      final next = store.activeCreatorSession;
      if (next != null) {
        setState(() {
          _sessionId = next.id;
          // Wave CY.18.113: chat-first when landing on a session after
          // delete, consistent with bootstrap / switch.
          _showCanvas = false;
        });
      } else {
        _bootstrapSession();
        // _bootstrapSession already sets _showCanvas = true.
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Build

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      key: _scaffoldKey,
      appBar: AppBar(
        // Wave CY.18.200: experimental badge next to the title.
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Wave 271: Flexible + ellipsis so a narrow screen (small
            // logical width or a large system font scale) TRUNCATES the
            // title instead of overflowing the title slot and painting on
            // top of the actions — that overflow was what made the title,
            // the "(experimental)" badge and the Sheet/Chat toggle collide
            // into garbled overlapping text on small phones.
            const Flexible(
              child: Text(
                'Character Creator',
                overflow: TextOverflow.ellipsis,
                softWrap: false,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: EmberColors.primary.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(5),
              ),
              child: const Text(
                'experimental',
                style: TextStyle(
                  color: EmberColors.primary,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ),
        // Two icons in the leading slot: the standard back arrow
        // (lost when we set `leading` on its own — Flutter only
        // auto-adds a BackButton when leading is null) plus the
        // sessions hamburger. leadingWidth bumped so they don't
        // squeeze the title.
        automaticallyImplyLeading: false,
        leadingWidth: 88,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const BackButton(),
            IconButton(
              tooltip: 'Sessions',
              icon: const Icon(Icons.menu),
              onPressed: () => _scaffoldKey.currentState?.openDrawer(),
            ),
          ],
        ),
        actions: [
          TextButton.icon(
            icon: Icon(
              _showCanvas ? Icons.chat_bubble_outline : Icons.article_outlined,
              color: EmberColors.primary,
              size: 16,
            ),
            label: Text(
              _showCanvas ? 'Chat' : 'Sheet',
              style: const TextStyle(color: EmberColors.primary),
            ),
            onPressed: () => setState(() => _showCanvas = !_showCanvas),
          ),
          if (_updatingCanvas)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 8),
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          IconButton(
            tooltip: 'Creator help',
            icon: const Icon(Icons.help_outline, size: 20),
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => const CharacterCreatorHelpScreen(),
              ),
            ),
          ),
        ],
      ),
      drawer: _SessionsDrawer(
        store: store,
        currentSessionId: _sessionId,
        onSelect: _switchSession,
        onNewSession: _createNewSession,
        onRename: _renameSessionPrompt,
        onDelete: _deleteSessionPrompt,
      ),
      body: _showCanvas ? _buildCanvas(store) : _buildChat(store),
    );
  }

  Widget _buildChat(AppStore store) {
    final chatSettings = store.chatSettings;
    final messages = _sessionMessages(store);
    final canvas = _sessionCanvas(store);
    return Column(
      children: [
        _SheetStatusPill(
          canvas: canvas,
          session: store.activeCreatorSession,
          onTap: () => setState(() => _showCanvas = true),
        ),
        Expanded(
          child: Stack(
            children: [
          // SelectionArea makes every Text / Text.rich inside the
          // subtree selectable without needing to convert each widget
          // to SelectableText individually. Long-press to start, drag
          // handles to extend, system context menu for copy / share.
          SelectionArea(
            child: ListView.builder(
            controller: _scrollCtl,
            padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            itemCount: messages.length,
            itemBuilder: (_, i) {
              final m = messages[i];
              // Wave CY.18.27: freeform synthetic-cue messages are
              // RUNTIME-INTERNAL — they live in the message list (so
              // retry / reload reconstruct the conversation correctly
              // and the model sees them as user turns when next
              // streaming) but the user should never see them in chat.
              // Render as zero-height shrinkers.
              if (m.kind == 'freeformCue') {
                return const SizedBox.shrink();
              }
              // Wave CY.18.27: freeform warning bubble — rendered as
              // a distinct system-info card, not an assistant bubble,
              // so the user can tell at a glance "this is from Pyre,
              // not from the architect".
              if (m.kind == 'freeformWarning') {
                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: _FreeformWarningCard(text: m.content),
                );
              }
              final isUser = m.role == 'user';
              // Retry sits below the LAST assistant message — and only
              // if the previous message is a user turn (so it can
              // actually be retried; an LLM responding to its own
              // greeting would just confuse the model).
              final isLast = i == messages.length - 1;
              final showRetry = isLast &&
                  !isUser &&
                  !_generating &&
                  messages.length >= 2 &&
                  messages[messages.length - 2].role == 'user';
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 6),
                child: Column(
                  crossAxisAlignment: isUser
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: isUser
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Flexible(
                          // No GestureDetector here on purpose: SelectionArea
                          // (wrapping the ListView) needs the long-press to
                          // start native text selection. Actions are reachable
                          // via the small "⋯" icon in the footer below.
                          child: Container(
                            constraints: BoxConstraints(
                              maxWidth:
                                  MediaQuery.of(context).size.width * 0.85,
                            ),
                            padding: const EdgeInsets.symmetric(
                                horizontal: 14, vertical: 10),
                            decoration: BoxDecoration(
                              color: isUser
                                  ? EmberColors.primary
                                      .withValues(alpha: 0.18)
                                  : EmberColors.bgPanel,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isUser
                                    ? EmberColors.primary
                                        .withValues(alpha: 0.4)
                                    : EmberColors.stroke,
                              ),
                            ),
                            child: _MessageBody(
                              message: m,
                              hideReasoning: chatSettings.hideReasoning,
                            ),
                          ),
                        ),
                      ],
                    ),
                    // Wave CV: mode-choice buttons under the opening
                    // greeting. Rendered only when this is the first
                    // assistant message AND the session has no mode
                    // yet (i.e. the user hasn't picked character vs
                    // scenario). The "Edit with AI" entry point
                    // pre-stamps mode='edit' so this never renders
                    // there, and legacy drafts get 'character' from
                    // the fromJson migration.
                    if (i == 0 &&
                        !isUser &&
                        store.activeCreatorSession?.mode == null)
                      _ModeChoiceRow(
                        onPickCharacter: () => _chooseMode('character'),
                        onPickScenario: () => _chooseMode('scenario'),
                      ),
                    // Wave CY.18.101: stage-2 flow picker removed —
                    // _chooseMode locks freeform directly.
                    // Footer row — token count (assistant only) +
                    // Retry (last assistant with prior user) + the
                    // overflow "⋯" button that opens the message
                    // action menu. Right-aligned for user messages,
                    // left-aligned for assistant. We can't reuse a
                    // long-press anymore — SelectionArea owns that
                    // for native text selection.
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Row(
                        mainAxisAlignment: isUser
                            ? MainAxisAlignment.end
                            : MainAxisAlignment.start,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Wave CY.18.93: per-message token chip
                          // removed. It estimated only the visible
                          // assistant text, not the actual tokens
                          // billed (which include system prompt,
                          // attachments, hidden updater calls, etc).
                          // Number bore no useful relationship to
                          // real provider spend — misleading enough
                          // that taking it out beats keeping a
                          // wrong-but-precise-looking figure on
                          // every reply.
                          if (showRetry)
                            TextButton.icon(
                              style: TextButton.styleFrom(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 8, vertical: 0),
                                minimumSize: const Size(0, 26),
                                tapTargetSize:
                                    MaterialTapTargetSize.shrinkWrap,
                                foregroundColor: EmberColors.textMid,
                              ),
                              icon: const Icon(Icons.refresh, size: 14),
                              label: const Text('Retry',
                                  style: TextStyle(fontSize: 12)),
                              onPressed: _retry,
                            ),
                          InkWell(
                            customBorder: const CircleBorder(),
                            onTap: () => _showMessageMenu(m),
                            child: const Padding(
                              padding: EdgeInsets.all(6),
                              child: Icon(
                                Icons.more_horiz,
                                size: 16,
                                color: EmberColors.textMid,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          ),
              // Defence in depth: the state-tracked flag can lag a
              // frame behind the actual scroll metrics (controller
              // listeners fire on pixel changes, not on viewport /
              // content-size changes). Check the live controller
              // here so the pill never appears when there's nothing
              // to scroll to.
              if (!_stickToBottom &&
                  _scrollCtl.hasClients &&
                  _scrollCtl.position.hasContentDimensions &&
                  _scrollCtl.position.maxScrollExtent > 60)
                Positioned(
                  right: 16,
                  bottom: 12,
                  child: Material(
                    color: EmberColors.bgPanel,
                    elevation: 4,
                    shape: const StadiumBorder(
                      side: BorderSide(color: EmberColors.stroke),
                    ),
                    child: InkWell(
                      customBorder: const StadiumBorder(),
                      onTap: () {
                        setState(() => _stickToBottom = true);
                        _scrollToBottom(force: true);
                      },
                      child: const Padding(
                        padding: EdgeInsets.symmetric(
                            horizontal: 12, vertical: 8),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.arrow_downward,
                                size: 14, color: EmberColors.primary),
                            SizedBox(width: 6),
                            Text('Jump to bottom',
                                style: TextStyle(
                                    color: EmberColors.primary,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
        _SessionSizeBanner(messages: messages),
        // Wave CY.18.242 (Build by message): the floating "Build the sheet" /
        // "Apply changes" pill was removed. The structured build is now
        // triggered conversationally — the architect emits `[[BUILD_SHEET]]`
        // when the user signals readiness (auto-fired + stripped in `onDone`),
        // or the user types `/build`. A one-line muted hint near the input
        // keeps the `/build` fallback discoverable, shown only for a buildable
        // mode and hidden while a build (or chat turn) is in flight.
        if (_canStructuredBuild(store))
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 4, 16, 0),
            child: Text(
              'Tell me when to build the sheet, or type /build',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 11,
                color: EmberColors.textDim,
              ),
            ),
          ),
        _InputBar(
          controller: _inputCtl,
          focusNode: _inputFocus,
          // C-2 (CRITICAL): treat an in-flight structured build like a normal
          // generation for the input bar — disable Enter-to-send + the send
          // button (shows the Stop control) so a mid-build send can't bump
          // `_streamGen` and make the build discard its result. `onStop` /
          // `_abortInFlightStream` already clears `_structuredBuilding`.
          generating: _generating || _structuredBuilding,
          // Wave CV: lock the input until the user picks character vs
          // scenario via the buttons in the opening greeting. Doesn't
          // apply to edit-mode sessions (which start with mode='edit'
          // already locked in) or legacy character drafts (which the
          // fromJson migration tags as 'character').
          // Wave CY.18.27: ALSO lock when mode is character/scenario
          // but flow hasn't been picked yet (the flow chips replaced
          // the mode chips in the same bubble).
          modeLocked: () {
            final s = store.activeCreatorSession;
            if (s == null) return true;
            return creatorInputLocked(mode: s.mode, flow: s.flow);
          }(),
          pending: _pendingAttachments,
          onRemovePending: _removePending,
          onSend: _send,
          onStop: _stop,
          onAttachCard: _attachCard,
          onAttachImage: _attachImage,
          onAttachDocument: _attachDocument,
        ),
      ],
    );
  }

  Widget _buildCanvas(AppStore store) {
    final canvas = _sessionCanvas(store);
    final hasAnything = canvas.values.any(_isFilled);
    return Column(
      children: [
        Expanded(
          child: hasAnything
              ? _CanvasFieldsView(
                  canvas: canvas,
                  changedKeys: _recentlyChangedCanvasKeys,
                  onEdit: _editCanvasField,
                  mode: store.activeCreatorSession?.mode,
                )
              : const Center(
                  child: Padding(
                    padding: EdgeInsets.all(32),
                    child: Text(
                      'Sheet is empty. Keep chatting — the card sheet fills in as you reveal more about the character. Every turn refreshes it automatically.',
                      textAlign: TextAlign.center,
                      style: TextStyle(color: EmberColors.textMid),
                    ),
                  ),
                ),
        ),
        Container(
          decoration: const BoxDecoration(
            color: EmberColors.bgPanel,
            border: Border(top: BorderSide(color: EmberColors.stroke)),
          ),
          padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
          child: SafeArea(
            top: false,
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    icon: const Icon(Icons.chat_bubble_outline, size: 16),
                    label: const Text('Keep chatting'),
                    onPressed: () => setState(() => _showCanvas = false),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton.icon(
                    icon: const Icon(Icons.check, size: 16),
                    label: Text(
                      store.activeCreatorSession?.mode == 'persona'
                          ? 'Save persona'
                          : 'Save card',
                    ),
                    onPressed: _saveCard,
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}

// =============================================================================
// Sessions drawer

class _SessionsDrawer extends StatefulWidget {
  final AppStore store;
  final String? currentSessionId;
  final void Function(String id) onSelect;
  final VoidCallback onNewSession;
  final Future<void> Function(CreatorSession s) onRename;
  final Future<void> Function(CreatorSession s) onDelete;

  const _SessionsDrawer({
    required this.store,
    required this.currentSessionId,
    required this.onSelect,
    required this.onNewSession,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_SessionsDrawer> createState() => _SessionsDrawerState();
}

class _SessionsDrawerState extends State<_SessionsDrawer> {
  final _searchCtl = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _searchCtl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final all = widget.store.creatorSessionsByRecency;
    final sessions = _query.isEmpty
        ? all
        : all.where((s) =>
            s.derivedTitle().toLowerCase().contains(_query.toLowerCase())).toList();
    return Drawer(
      backgroundColor: EmberColors.bgPanel,
      child: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 8, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Row(
                      children: [
                        const Text(
                          'Sessions',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                              horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: EmberColors.bgDeep,
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(color: EmberColors.stroke),
                          ),
                          child: Text(
                            '${all.length}',
                            style: const TextStyle(
                              color: EmberColors.textMid,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('New'),
                    onPressed: widget.onNewSession,
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
              child: TextField(
                controller: _searchCtl,
                onChanged: (v) => setState(() => _query = v.trim()),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  hintText: 'Search sessions…',
                  hintStyle: const TextStyle(fontSize: 13),
                  prefixIcon: const Icon(Icons.search,
                      size: 16, color: EmberColors.textMid),
                  suffixIcon: _query.isEmpty
                      ? null
                      : IconButton(
                          icon: const Icon(Icons.close,
                              size: 14, color: EmberColors.textMid),
                          onPressed: () {
                            _searchCtl.clear();
                            setState(() => _query = '');
                          },
                        ),
                  isDense: true,
                  contentPadding:
                      const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                ),
              ),
            ),
            const Divider(color: EmberColors.stroke, height: 1),
            Expanded(
              child: sessions.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(24),
                        child: Text(
                          _query.isEmpty
                              ? 'No sessions yet. Start chatting and one will appear here.'
                              : 'No sessions match "$_query".',
                          textAlign: TextAlign.center,
                          style: const TextStyle(
                              color: EmberColors.textDim),
                        ),
                      ),
                    )
                  : ListView.builder(
                      itemCount: sessions.length,
                      itemBuilder: (_, i) {
                        final s = sessions[i];
                        final isActive = s.id == widget.currentSessionId;
                        final saved = s.savedCharacterId != null;
                        return ListTile(
                          dense: true,
                          selected: isActive,
                          selectedTileColor:
                              EmberColors.primary.withValues(alpha: 0.10),
                          leading: s.pinned
                              ? const Icon(Icons.push_pin,
                                  size: 14, color: EmberColors.primary)
                              : null,
                          title: Text(
                            s.derivedTitle(),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: isActive
                                  ? FontWeight.w700
                                  : FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            _relTime(s.updatedAt) +
                                (saved ? ' · saved' : ''),
                            style: const TextStyle(
                                color: EmberColors.textDim, fontSize: 11),
                          ),
                          trailing: PopupMenuButton<String>(
                            tooltip: 'Session',
                            icon: const Icon(Icons.more_vert,
                                size: 18, color: EmberColors.textMid),
                            onSelected: (v) async {
                              if (v == 'rename') {
                                await widget.onRename(s);
                              } else if (v == 'delete') {
                                await widget.onDelete(s);
                              } else if (v == 'pin') {
                                widget.store.toggleCreatorSessionPin(s.id);
                              }
                            },
                            itemBuilder: (_) => [
                              PopupMenuItem(
                                value: 'pin',
                                child: Row(
                                  children: [
                                    Icon(
                                      s.pinned
                                          ? Icons.push_pin
                                          : Icons.push_pin_outlined,
                                      size: 16,
                                    ),
                                    const SizedBox(width: 8),
                                    Text(s.pinned ? 'Unpin' : 'Pin to top'),
                                  ],
                                ),
                              ),
                              const PopupMenuItem(
                                  value: 'rename', child: Text('Rename')),
                              const PopupMenuItem(
                                  value: 'delete', child: Text('Delete')),
                            ],
                          ),
                          onTap: () => widget.onSelect(s.id),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }

  static String _relTime(int millis) {
    final diff =
        DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(millis));
    if (diff.inMinutes < 1) return 'just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 30) return '${diff.inDays}d ago';
    return '${(diff.inDays / 30).floor()}mo ago';
  }
}

// =============================================================================
// Canvas — pretty per-field renderer

class _CanvasFieldsView extends StatefulWidget {
  final Map<String, dynamic> canvas;
  final Set<String> changedKeys;
  final void Function(String key, dynamic current) onEdit;
  /// Persona Creator: the session mode. When 'persona', the sheet shows
  /// only the persona fields (name / description / dialogue examples /
  /// tagline) and hides the character-only fields + the Advanced
  /// section. null/'character'/'scenario'/'edit' keep the full layout.
  final String? mode;
  const _CanvasFieldsView({
    required this.canvas,
    required this.changedKeys,
    required this.onEdit,
    this.mode,
  });

  @override
  State<_CanvasFieldsView> createState() => _CanvasFieldsViewState();
}

class _CanvasFieldsViewState extends State<_CanvasFieldsView> {
  /// Wave AZ: the "Advanced" section is collapsed by default. It holds
  /// the chara_card_v2 fields that 99% of users never touch — empty
  /// `personality` (folded into description by spec), prompt overrides,
  /// alternate greetings, the extensions blob, etc. Tapping the header
  /// expands; state is local so flipping to chat and back preserves it.
  bool _advancedExpanded = false;

  @override
  Widget build(BuildContext context) {
    // Persona Creator: a persona is just name + description + dialogue
    // examples + an optional tagline — render ONLY those, no scenario /
    // first_mes / tags / creator_notes, and no Advanced section. The
    // mes_example field is relabelled "Dialogue examples" for personas
    // (see _labelFor's personaMode branch).
    if (widget.mode == 'persona') {
      const personaOrder = <String>[
        'name',
        'description',
        'mes_example',
        'tagline',
      ];
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          for (final key in personaOrder)
            _CanvasField(
              fieldKey: key,
              label: _labelFor(key, personaMode: true),
              value: _renderValueForKey(key, widget.canvas[key]),
              highlighted: widget.changedKeys.contains(key),
              onEdit: () => widget.onEdit(key, widget.canvas[key]),
            ),
        ],
      );
    }
    // VISIBLE by default — the fields the user actually fills.
    // Wave BC: `tagline` added (Block 5).
    // Wave BH: tagline moved to AFTER tags. It's card-listing
    // metadata (one-liner pitch for the catalog), not core identity —
    // grouping it with tags + creator_notes reads as a coherent
    // "card metadata" block at the bottom of the sheet.
    const mainOrder = <String>[
      'name',
      'description',
      'scenario',
      'first_mes',
      'mes_example',
      'tags',
      'tagline',
      'creator_notes',
    ];
    // ADVANCED — collapsed behind a tap. `personality` lives here
    // because it's intentionally always empty (the spec concatenates
    // description + personality at runtime; we keep everything in
    // description). Power-user fields live here too.
    // Wave BJ: dropped `extensions` (raw JSON blob), `talkativeness`
    // (ST-specific weighting field), and depth_prompt — all niche
    // chara_card_v2 surface area that the vast majority of users
    // never touch. Imported cards still carry the values on-disk;
    // we just don't surface a UI for editing them.
    const advancedOrder = <String>[
      'personality',
      'system_prompt',
      'post_history_instructions',
      'alternate_greetings',
      'creator',
      'character_version',
    ];
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
      children: [
        for (final key in mainOrder)
          _CanvasField(
            fieldKey: key,
            label: _labelFor(key),
            value: _renderValueForKey(key, widget.canvas[key]),
            highlighted: widget.changedKeys.contains(key),
            onEdit: () => widget.onEdit(key, widget.canvas[key]),
          ),
        // Collapsible Advanced header. Closed by default — opens on tap.
        Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () => setState(() => _advancedExpanded = !_advancedExpanded),
            borderRadius: BorderRadius.circular(8),
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
              child: Row(
                children: [
                  Icon(
                    _advancedExpanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 18,
                    color: EmberColors.textMid,
                  ),
                  const SizedBox(width: 6),
                  const Text(
                    'ADVANCED SETTINGS',
                    style: TextStyle(
                      color: EmberColors.textMid,
                      fontWeight: FontWeight.w700,
                      fontSize: 11,
                      letterSpacing: 1.2,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        if (_advancedExpanded)
          for (final key in advancedOrder)
            _CanvasField(
              fieldKey: key,
              label: _labelFor(key),
              value: _renderValueForKey(key, widget.canvas[key]),
              highlighted: widget.changedKeys.contains(key),
              onEdit: () => widget.onEdit(key, widget.canvas[key]),
            ),
      ],
    );
  }

  /// Wave AZ item 4: inject blank lines before top-level section
  /// headers in the description field so the dense label dump renders
  /// with visual breathing room. The on-disk content is unchanged —
  /// this is purely presentational.
  static const _descriptionSectionHeaders = <String>[
    'Detailed Features:',
    'Clothing:',
    'Alternative Clothing:',
    'Intimate Details:',
    'General Appearance:',
    'Core Traits:',
    'Abilities:',
    'Background:',
  ];

  dynamic _renderValueForKey(String key, dynamic raw) {
    if (key != 'description' || raw is! String) return raw;
    var out = raw;
    for (final header in _descriptionSectionHeaders) {
      // Replace ONLY when the header sits at the start of a line that
      // isn't already preceded by a blank line. Two-step: ensure the
      // header is on its own line, then prepend a blank line.
      out = out.replaceAllMapped(
        RegExp('(\\n)(${RegExp.escape(header)})'),
        (m) => '\n\n${m.group(2)}',
      );
    }
    // Collapse any triple-newlines we may have produced when the model
    // ALREADY left a blank line before the header.
    out = out.replaceAll(RegExp(r'\n{3,}'), '\n\n');
    return out;
  }

  String _labelFor(String key, {bool personaMode = false}) {
    // Persona Creator: the dialogue field reads as "Dialogue examples"
    // (it's the persona's own speech samples), not "Message examples".
    if (personaMode && key == 'mes_example') return 'Dialogue examples';
    switch (key) {
      case 'name':
        return 'Name';
      case 'description':
        return 'Description';
      case 'personality':
        return 'Personality';
      case 'scenario':
        return 'Scenario';
      case 'first_mes':
        return 'First message';
      case 'mes_example':
        return 'Message examples';
      case 'creator_notes':
        return 'Creator notes';
      case 'system_prompt':
        return 'System prompt';
      case 'post_history_instructions':
        return 'Post-history instructions';
      case 'alternate_greetings':
        return 'Alternate greetings';
      case 'tags':
        return 'Tags';
      case 'creator':
        return 'Creator';
      case 'character_version':
        return 'Version';
      case 'extensions':
        return 'Extensions';
      default:
        return key;
    }
  }
}

class _CanvasField extends StatelessWidget {
  final String fieldKey;
  final String label;
  final dynamic value;
  final bool highlighted;
  final VoidCallback onEdit;
  const _CanvasField({
    required this.fieldKey,
    required this.label,
    required this.value,
    required this.highlighted,
    required this.onEdit,
  });

  @override
  Widget build(BuildContext context) {
    final empty = value == null ||
        (value is String && value.trim().isEmpty) ||
        (value is List && value.isEmpty) ||
        (value is Map && value.isEmpty);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 280),
      margin: const EdgeInsets.only(bottom: 14),
      padding: highlighted
          ? const EdgeInsets.fromLTRB(10, 8, 10, 10)
          : const EdgeInsets.fromLTRB(0, 0, 0, 0),
      decoration: highlighted
          ? BoxDecoration(
              color: const Color(0xFFE9A35A).withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: const Color(0xFFE9A35A).withValues(alpha: 0.45),
                width: 1,
              ),
            )
          : null,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              Expanded(
                child: Text(
                  label.toUpperCase(),
                  style: const TextStyle(
                    color: EmberColors.primary,
                    fontWeight: FontWeight.w700,
                    fontSize: 11,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
              InkWell(
                onTap: onEdit,
                customBorder: const CircleBorder(),
                child: const Padding(
                  padding: EdgeInsets.all(4),
                  child: Icon(
                    Icons.edit_outlined,
                    size: 14,
                    color: EmberColors.textMid,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          if (empty)
            const Text(
              '—',
              style: TextStyle(color: EmberColors.textDim, fontSize: 13),
            )
          else if (value is List && fieldKey == 'alternate_greetings')
            // Wave BD: alternate_greetings are MULTI-PARAGRAPH strings
            // (each is an opening scene), not short labels like tags.
            // Render each as its own numbered card with the prose
            // showing through — chip-style would shove paragraphs into
            // pill containers and look horrible.
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < value.length; i++)
                  Padding(
                    padding: EdgeInsets.only(
                        bottom: i == value.length - 1 ? 0 : 10),
                    child: Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: EmberColors.bgPanel,
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: EmberColors.stroke),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'GREETING ${i + 1}',
                            style: TextStyle(
                              color: EmberColors.primary
                                  .withValues(alpha: 0.8),
                              fontWeight: FontWeight.w700,
                              fontSize: 10,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const SizedBox(height: 6),
                          SelectableText(
                            '${value[i]}',
                            style: const TextStyle(
                              color: EmberColors.textHigh,
                              fontSize: 13,
                              height: 1.45,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
              ],
            )
          else if (value is List)
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final v in value)
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: EmberColors.bgPanel,
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(color: EmberColors.stroke),
                    ),
                    child: Text('$v',
                        style: const TextStyle(
                            color: EmberColors.textMid, fontSize: 12)),
                  )
              ],
            )
          else if (value is Map)
            SelectableText(
              const JsonEncoder.withIndent('  ').convert(value),
              style: const TextStyle(
                fontFamily: 'monospace',
                fontSize: 12,
                color: EmberColors.textMid,
              ),
            )
          else
            SelectableText(
              '$value',
              style: const TextStyle(
                color: EmberColors.textHigh,
                fontSize: 13,
                height: 1.45,
              ),
            ),
        ],
      ),
    );
  }
}

// =============================================================================
// Wave CV: mode-choice row — two big buttons rendered inline under the
// opening greeting. Picks character or scenario architect for this
// session. Once a choice is made, the buttons go away (the renderer
// only emits this widget while `session.mode == null`).

class _ModeChoiceRow extends StatelessWidget {
  final VoidCallback onPickCharacter;
  final VoidCallback onPickScenario;
  const _ModeChoiceRow({
    required this.onPickCharacter,
    required this.onPickScenario,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 12, 0, 4),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          ElevatedButton.icon(
            icon: const Icon(Icons.person_outline, size: 18),
            label: const Text('Build a character'),
            style: ElevatedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onPressed: onPickCharacter,
          ),
          OutlinedButton.icon(
            icon: const Icon(Icons.menu_book_outlined, size: 18),
            label: const Text('Build a scenario'),
            style: OutlinedButton.styleFrom(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            ),
            onPressed: onPickScenario,
          ),
        ],
      ),
    );
  }
}

/// Wave CY.18.27: runtime info bubble injected once per freeform
/// session, right after Block 1 lands and the cascade engages. Distinct
/// styling (info icon + outlined panel, not a chat bubble) so the user
/// reads it as a system notice, not as architect output.
class _FreeformWarningCard extends StatelessWidget {
  final String text;
  const _FreeformWarningCard({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      decoration: BoxDecoration(
        color: const Color(0xFFE9A35A).withValues(alpha: 0.10),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: const Color(0xFFE9A35A).withValues(alpha: 0.45),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.hourglass_top_outlined,
            size: 18,
            color: Color(0xFFE9A35A),
          ),
          const SizedBox(width: 10),
          Expanded(
            // Wave CY.18.27: this file doesn't import flutter_markdown
            // (MarkdownBody lives in chat-screen / message-bubble
            // contexts) — strip the `**` markers and render as plain
            // text so the bubble doesn't need a new dependency. The
            // info bubble is short enough that bold loss is fine.
            child: Text(
              text.replaceAll('**', ''),
              style: const TextStyle(
                color: EmberColors.textHigh,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// Wave CY.18.101: _FlowChoiceRow widget removed with the guided flow.

// =============================================================================
// Input bar — single `+` popup for attachments, then text field + send

/// True on desktop platforms (Windows/Linux/macOS); false on web and
/// mobile. Gates the Creator's desktop-only Enter-to-send shortcut —
/// on Android, Enter must insert a newline, never send.
bool get _isDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final bool generating;
  /// Wave CV: when true the entire input is disabled with a "pick a
  /// flow above" placeholder. Used at the start of a fresh session
  /// before the user has chosen character vs scenario.
  final bool modeLocked;
  final List<_PendingAttachment> pending;
  final void Function(_PendingAttachment) onRemovePending;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onAttachCard;
  final VoidCallback onAttachImage;
  final VoidCallback onAttachDocument;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.generating,
    required this.modeLocked,
    required this.pending,
    required this.onRemovePending,
    required this.onSend,
    required this.onStop,
    required this.onAttachCard,
    required this.onAttachImage,
    required this.onAttachDocument,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: const BoxDecoration(
        color: EmberColors.bgPanel,
        border: Border(top: BorderSide(color: EmberColors.stroke)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (pending.isNotEmpty)
              _PendingChipsRow(pending: pending, onRemove: onRemovePending),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
            // Single `+` button — popup with named attach options. Mirrors
            // the ChatGPT mobile pattern.
            PopupMenuButton<String>(
              tooltip: 'Attach',
              icon: const Icon(Icons.add_circle_outline,
                  color: EmberColors.textMid, size: 26),
              enabled: !generating && !modeLocked,
              onSelected: (v) {
                switch (v) {
                  case 'image':
                    onAttachImage();
                    break;
                  case 'card':
                    onAttachCard();
                    break;
                  case 'doc':
                    onAttachDocument();
                    break;
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(
                  value: 'image',
                  child: Row(
                    children: [
                      Icon(Icons.image_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Attach image'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'card',
                  child: Row(
                    children: [
                      Icon(Icons.badge_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Attach character card'),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'doc',
                  child: Row(
                    children: [
                      Icon(Icons.description_outlined, size: 18),
                      SizedBox(width: 10),
                      Text('Attach document'),
                    ],
                  ),
                ),
              ],
            ),
            Expanded(
              // Wave CY.18.113: desktop Enter-to-send, mirroring the
              // chat input (Wave CY.18.52). On Windows/Linux/macOS a
              // bare Enter sends; Shift+Enter still inserts a newline
              // (CallbackShortcuts only catches the no-modifier
              // SingleActivator). On Android/mobile the bindings map is
              // empty, so Enter inserts a newline as expected and the
              // send button is the only way to commit.
              child: CallbackShortcuts(
                bindings: _isDesktop
                    ? <ShortcutActivator, VoidCallback>{
                        const SingleActivator(LogicalKeyboardKey.enter): () {
                          // No-op mid-stream (stop button owns that),
                          // while the input is locked (pick-a-flow), or
                          // on empty input.
                          if (generating) return;
                          if (modeLocked) return;
                          if (controller.text.trim().isEmpty) return;
                          onSend();
                        },
                      }
                    : const <ShortcutActivator, VoidCallback>{},
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  enabled: !modeLocked,
                  minLines: 1,
                  maxLines: 6,
                  textInputAction: TextInputAction.newline,
                  decoration: InputDecoration(
                    hintText: modeLocked
                        ? 'Choose a flow above to begin…'
                        : 'Reply to the assistant…',
                    isDense: true,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (generating)
              // Stop button (replaces send) while a stream is alive —
              // tap aborts the request, partial reply stays in the
              // bubble. Without this the user has no way to cancel a
              // generation that's clearly going off the rails.
              IconButton.filled(
                onPressed: onStop,
                style: IconButton.styleFrom(
                  backgroundColor: EmberColors.danger,
                ),
                icon: const Icon(Icons.stop, color: Colors.white),
                tooltip: 'Stop generating',
              )
            else
              IconButton.filled(
                onPressed: modeLocked ? null : onSend,
                style: IconButton.styleFrom(
                  backgroundColor: modeLocked
                      ? EmberColors.stroke
                      : EmberColors.primary,
                ),
                icon: const Icon(Icons.arrow_upward, color: Colors.white),
              ),
          ],
        ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// _MessageBody — renders a CreatorMessage in a chat bubble. For user
// messages with attachments, shows thumbnails / chips ABOVE the prose
// (the bubble owns the layout; the chips and text are siblings in a
// Column). Assistant messages and old-format user messages with empty
// attachments render exactly as before.

class _MessageBody extends StatefulWidget {
  final CreatorMessage message;
  final bool hideReasoning;
  const _MessageBody({required this.message, required this.hideReasoning});

  @override
  State<_MessageBody> createState() => _MessageBodyState();
}

class _MessageBodyState extends State<_MessageBody> {
  /// null = follow the global Chat Settings toggle (widget.hideReasoning).
  /// true / false = per-message override the user set with the link.
  bool? _override;
  /// Wave CH: Pyre runtime trail (added by _formatContinuationTrail) is
  /// noisy diagnostic info — collapsed by default, user taps to expand.
  bool _trailExpanded = false;
  /// Wave CH: API error details (raw body wrapped in
  /// `<<PYRE_ERR_DETAILS>>`) collapsed by default behind the friendly
  /// summary.
  bool _errDetailsExpanded = false;

  /// Wave CH: matches the leading runtime-trail blockquote that
  /// `_formatContinuationTrail` emits. Starts with `> _Pyre runtime — `,
  /// continues over consecutive `> ...` lines, and ends right before
  /// the next blank line / non-blockquote content.
  static final _trailRegex = RegExp(
    r'^>\s*_Pyre runtime —[^\n]*(?:\n>[^\n]*)*',
    caseSensitive: false,
  );

  /// Wave CH: matches the API-error-details envelope.
  static final _errDetailsRegex = RegExp(
    r'<<PYRE_ERR_DETAILS>>([\s\S]*?)<<PYRE_ERR_DETAILS_END>>',
  );

  @override
  Widget build(BuildContext context) {
    final hasAttachments = widget.message.attachments.isNotEmpty;
    final rawText = widget.message.content;
    final hasText = rawText.trim().isNotEmpty;
    if (!hasAttachments && !hasText) {
      return const Text('…',
          style: TextStyle(color: EmberColors.textDim));
    }
    final hideReasoning = _override ?? widget.hideReasoning;
    final hasReasoning = ChatText.containsReasoning(rawText);

    // Wave CH: pre-split the content into three layers, each rendered
    // independently:
    //   - runtime trail (collapsed by default, "Show runtime details")
    //   - api-error details (collapsed by default, "Show full error")
    //   - main body (the actual brief / chat reply / error headline)
    String trail = '';
    String errDetails = '';
    var mainBody = rawText;
    final trailMatch = _trailRegex.firstMatch(mainBody);
    if (trailMatch != null) {
      trail = trailMatch.group(0)!;
      mainBody = mainBody.substring(trailMatch.end).trimLeft();
    }
    final errMatch = _errDetailsRegex.firstMatch(mainBody);
    if (errMatch != null) {
      errDetails = errMatch.group(1)!.trim();
      mainBody = mainBody.replaceRange(
        errMatch.start,
        errMatch.end,
        '',
      ).trim();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hasAttachments)
          Padding(
            padding: EdgeInsets.only(bottom: hasText ? 8 : 0),
            child: _AttachmentBubbleRow(attachments: widget.message.attachments),
          ),
        if (trail.isNotEmpty)
          _CollapsibleNoteBlock(
            collapsedLabel: 'Show runtime details',
            expandedLabel: 'Hide runtime details',
            icon: Icons.tune,
            expanded: _trailExpanded,
            onTap: () => setState(() => _trailExpanded = !_trailExpanded),
            content: trail,
          ),
        if (mainBody.trim().isNotEmpty)
          ChatText(mainBody, hideReasoning: hideReasoning),
        if (errDetails.isNotEmpty)
          _CollapsibleNoteBlock(
            collapsedLabel: 'Show full error',
            expandedLabel: 'Hide full error',
            icon: Icons.bug_report_outlined,
            expanded: _errDetailsExpanded,
            onTap: () =>
                setState(() => _errDetailsExpanded = !_errDetailsExpanded),
            content: '```\n$errDetails\n```',
          ),
        if (hasReasoning)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => setState(() => _override = !hideReasoning),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    hideReasoning ? Icons.expand_more : Icons.expand_less,
                    size: 13,
                    color: EmberColors.textMid,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    hideReasoning
                        ? 'Show reasoning'
                        : 'Hide reasoning',
                    style: const TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 11,
                        fontWeight: FontWeight.w500),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}

/// Wave CH: small toggle row + collapsible content panel. Used for
/// runtime trails and API error details — same UX as "Show reasoning"
/// (chevron + label, content hidden by default). Lives on the same
/// markdown rendering pipeline as the main body via ChatText.
class _CollapsibleNoteBlock extends StatelessWidget {
  final String collapsedLabel;
  final String expandedLabel;
  final IconData icon;
  final bool expanded;
  final VoidCallback onTap;
  final String content;

  const _CollapsibleNoteBlock({
    required this.collapsedLabel,
    required this.expandedLabel,
    required this.icon,
    required this.expanded,
    required this.onTap,
    required this.content,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: onTap,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, size: 13, color: EmberColors.textMid),
                const SizedBox(width: 4),
                Text(
                  expanded ? expandedLabel : collapsedLabel,
                  style: const TextStyle(
                    color: EmberColors.textMid,
                    fontSize: 11,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(width: 2),
                Icon(
                  expanded ? Icons.expand_less : Icons.expand_more,
                  size: 13,
                  color: EmberColors.textMid,
                ),
              ],
            ),
          ),
          if (expanded)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: ChatText(content),
            ),
        ],
      ),
    );
  }
}

class _AttachmentBubbleRow extends StatefulWidget {
  final List<CreatorAttachment> attachments;
  const _AttachmentBubbleRow({required this.attachments});

  @override
  State<_AttachmentBubbleRow> createState() => _AttachmentBubbleRowState();
}

class _AttachmentBubbleRowState extends State<_AttachmentBubbleRow> {
  /// Hidden by default. The extracted block (vision profile / card
  /// JSON / doc text) is the same material the LLM sees — useful for
  /// the user to spot-check, but visually noisy if always-open.
  bool _expanded = false;

  /// Cache decoded bytes per attachment instance. Without this every
  /// rebuild (every chunk during streaming, every scroll event that
  /// recycles this item) calls base64Decode → creates a new Uint8List
  /// → Flutter's image cache misses → the thumbnail flickers as the
  /// PNG decodes again. Holding the same Uint8List reference makes
  /// MemoryImage's cache key stable.
  final Map<CreatorAttachment, Uint8List> _decoded = {};

  Uint8List _bytesFor(CreatorAttachment a) {
    return _decoded[a] ??=
        base64Decode(a.imageDataUrl!.split(',').last);
  }

  @override
  Widget build(BuildContext context) {
    // Images render as a row of inline thumbnails; card / doc as a
    // compact icon + filename row so the user always knows what was
    // attached without dumping the JSON / doc text into the bubble.
    final hasExtracted = widget.attachments.any((a) => a.extracted.trim().isNotEmpty);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final a in widget.attachments)
              if (a.kind == 'image' && a.imageDataUrl != null)
                GestureDetector(
                  onTap: () => _openImageViewer(context, a),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.memory(
                      _bytesFor(a),
                      width: 160,
                      height: 160,
                      fit: BoxFit.cover,
                      // Keep the previous frame on screen if the cache
                      // ever does have to redecode — no flash to blank.
                      gaplessPlayback: true,
                      errorBuilder: (_, _, _) => Container(
                        width: 160,
                        height: 160,
                        color: EmberColors.bgDeep,
                        child: const Icon(Icons.broken_image_outlined,
                            color: EmberColors.textDim),
                      ),
                    ),
                  ),
                )
              else
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 10, vertical: 6),
                  decoration: BoxDecoration(
                    color: EmberColors.bgDeep,
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: EmberColors.stroke),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        a.kind == 'card'
                            ? Icons.badge_outlined
                            : Icons.description_outlined,
                        size: 14,
                        color: EmberColors.textMid,
                      ),
                      const SizedBox(width: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxWidth: 180),
                        child: Text(
                          a.filename,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: EmberColors.textHigh,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
          ],
        ),
        if (hasExtracted)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: GestureDetector(
              onTap: () => setState(() => _expanded = !_expanded),
              behavior: HitTestBehavior.opaque,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _expanded
                        ? Icons.expand_less
                        : Icons.expand_more,
                    size: 14,
                    color: EmberColors.textMid,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    _expanded
                        ? 'Hide attachment details'
                        : 'Show attachment details',
                    style: const TextStyle(
                        color: EmberColors.textMid, fontSize: 11),
                  ),
                ],
              ),
            ),
          ),
        if (hasExtracted && _expanded)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: EmberColors.bgDeep,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: EmberColors.stroke),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < widget.attachments.length; i++) ...[
                    if (i > 0) const Divider(color: EmberColors.stroke, height: 16),
                    Text(
                      widget.attachments[i].filename,
                      style: const TextStyle(
                          color: EmberColors.primary,
                          fontSize: 10,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6),
                    ),
                    const SizedBox(height: 4),
                    SelectableText(
                      widget.attachments[i].extracted.trim().isEmpty
                          ? '(no extracted content)'
                          : widget.attachments[i].extracted,
                      style: const TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 12,
                        height: 1.4,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
      ],
    );
  }

  void _openImageViewer(BuildContext context, CreatorAttachment a) {
    if (a.imageDataUrl == null) return;
    Navigator.of(context).push(MaterialPageRoute(
      fullscreenDialog: true,
      builder: (_) => Scaffold(
        backgroundColor: Colors.black,
        appBar: AppBar(
          backgroundColor: Colors.black,
          iconTheme: const IconThemeData(color: Colors.white),
          title: Text(a.filename,
              style: const TextStyle(color: Colors.white, fontSize: 14)),
        ),
        body: InteractiveViewer(
          minScale: 0.5,
          maxScale: 5,
          child: Center(
            child: Image.memory(
              _bytesFor(a),
              fit: BoxFit.contain,
              gaplessPlayback: true,
            ),
          ),
        ),
      ),
    ));
  }
}

// =============================================================================
// _PendingChipsRow — horizontal row of staged attachments above the
// text input. Each chip has a thumb / icon, the filename, and a tiny
// X to remove. Image chips show a spinner overlay while the vision
// analysis is still in flight.

class _PendingChipsRow extends StatelessWidget {
  final List<_PendingAttachment> pending;
  final void Function(_PendingAttachment) onRemove;
  const _PendingChipsRow({required this.pending, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final p in pending) ...[
              _PendingChip(item: p, onRemove: () => onRemove(p)),
              const SizedBox(width: 8),
            ],
          ],
        ),
      ),
    );
  }
}

class _PendingChip extends StatefulWidget {
  final _PendingAttachment item;
  final VoidCallback onRemove;
  const _PendingChip({required this.item, required this.onRemove});

  @override
  State<_PendingChip> createState() => _PendingChipState();
}

class _PendingChipState extends State<_PendingChip> {
  @override
  Widget build(BuildContext context) {
    final item = widget.item;
    // Pending attachments hold raw bytes directly — no base64 round
    // trip, no decode cost on rebuild. The bytes reference is stable
    // (Wave AF) so MemoryImage's cache key doesn't change unless we
    // actively swap the bytes (e.g. after downscale completes).
    final isImage = item.kind == 'image' && item.imageBytes != null;
    return Container(
      decoration: BoxDecoration(
        color: EmberColors.bgDeep,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: item.error != null
              ? EmberColors.danger
              : EmberColors.stroke,
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Body
          if (isImage)
            ClipRRect(
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: 56,
                height: 56,
                child: Image.memory(
                  item.imageBytes!,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const Icon(
                      Icons.broken_image_outlined,
                      color: EmberColors.textDim),
                ),
              ),
            )
          else
            Padding(
              padding:
                  const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    item.kind == 'card'
                        ? Icons.badge_outlined
                        : Icons.description_outlined,
                    size: 16,
                    color: EmberColors.textMid,
                  ),
                  const SizedBox(width: 6),
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 140),
                    child: Text(
                      item.filename,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          color: EmberColors.textHigh, fontSize: 12),
                    ),
                  ),
                ],
              ),
            ),
          // Spinner overlay for images still being analysed by vision API
          if (isImage && item.analysing != null)
            Positioned.fill(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(10),
                child: ColoredBox(
                  color: Colors.black54,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(
                            EmberColors.primary),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          // Error badge — small ! corner so the user knows the LLM
          // won't get a structured profile for this attachment.
          if (item.error != null)
            Positioned(
              left: 4,
              bottom: 4,
              child: Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: EmberColors.danger,
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text('!',
                    style: TextStyle(
                        color: Colors.white,
                        fontSize: 10,
                        fontWeight: FontWeight.w700)),
              ),
            ),
          // X to remove. Sits OUTSIDE the chip's stroke so the tap
          // target doesn't compete with the chip body itself.
          Positioned(
            right: -6,
            top: -6,
            child: Material(
              color: EmberColors.bgPanel,
              shape: const CircleBorder(
                side: BorderSide(color: EmberColors.stroke),
              ),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: widget.onRemove,
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close,
                      size: 12, color: EmberColors.textMid),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Save sheet — avatar pick + Save / Save & export PNG buttons.
//
// Opens from the canvas footer. The avatar is OPTIONAL for the library
// save but REQUIRED for the PNG export (chara_card_v2 PNGs need real
// image bytes to embed metadata into). Cropping reuses the existing
// avatar_crop_screen.dart so the output is always a 256x256 PNG.

// =============================================================================
// Context-size banner — sits above the input when the session has
// piled up enough chars to start crowding common context windows.
// Only renders past a soft threshold (~60k chars ≈ 15k tokens), so
// short sessions never see it. Suggests starting a new session and
// saving the current one — long sessions burn money on every turn
// because the whole transcript replays.

class _SessionSizeBanner extends StatelessWidget {
  final List<CreatorMessage> messages;
  const _SessionSizeBanner({required this.messages});

  static const int _softThreshold = 60 * 1000;   // chars (~15k tokens)
  static const int _hardThreshold = 120 * 1000;  // chars (~30k tokens)

  @override
  Widget build(BuildContext context) {
    var totalChars = 0;
    for (final m in messages) {
      totalChars += m.content.length;
      for (final a in m.attachments) {
        totalChars += a.extracted.length;
      }
    }
    if (totalChars < _softThreshold) return const SizedBox.shrink();
    final hard = totalChars >= _hardThreshold;
    final tokens = (totalChars / 4).round();
    final tokenLabel = tokens < 1000
        ? '$tokens'
        : '${(tokens / 1000).toStringAsFixed(tokens < 10000 ? 1 : 0)}k';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: (hard ? EmberColors.danger : const Color(0xFFE9A35A))
            .withValues(alpha: 0.12),
        border: Border(
          top: BorderSide(
            color: (hard ? EmberColors.danger : const Color(0xFFE9A35A))
                .withValues(alpha: 0.35),
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          Icon(
            hard ? Icons.error_outline : Icons.warning_amber_outlined,
            color: hard ? EmberColors.danger : const Color(0xFFE9A35A),
            size: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hard
                  ? 'Session ~$tokenLabel tokens — many models will reject this. Save the card and start a new session.'
                  : 'Session ~$tokenLabel tokens — approaching common context limits. Consider saving + starting fresh.',
              style: TextStyle(
                color: hard
                    ? EmberColors.danger
                    : EmberColors.textHigh,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// =============================================================================
// Sticky sheet-status pill — sits above the chat ListView so the user
// always knows the sheet state without flipping to the Sheet tab.
// Counts non-empty canvas fields (plus tag count) and shows the name
// if one's been committed. Tap = flip to the Sheet view.

class _SheetStatusPill extends StatelessWidget {
  final Map<String, dynamic> canvas;
  final VoidCallback onTap;
  /// Wave CY.18.200: active creator session, used to show a mode badge.
  final CreatorSession? session;
  const _SheetStatusPill({
    required this.canvas,
    required this.onTap,
    this.session,
  });

  @override
  Widget build(BuildContext context) {
    final name = (canvas['name'] is String)
        ? (canvas['name'] as String).trim()
        : '';
    // Count "filled" fields the same way the Sheet view does so the
    // two views agree. Skip empty string / empty list / empty map.
    // Wave BB: only count the seven visible-by-default fields — the
    // Advanced-tray fields (personality, system_prompt, extensions, etc.)
    // are intentionally empty by spec, so counting them as "missing"
    // capped the pill at 6-7/14 forever even on complete cards.
    // Wave CY.18.222: the field set is MODE-AWARE. Personas have a much
    // smaller schema (no scenario/first_mes/tags/creator_notes), so counting
    // a persona canvas against the 8 character fields showed a misleading
    // "4/8". Persona sessions count against the persona field list.
    final tracked = _pillTrackedFields(session);
    final filled =
        tracked.where((k) => _isPillFilled(canvas[k])).length;
    final total = tracked.length;
    final tagsRaw = canvas['tags'];
    final tagsCount = (tagsRaw is List) ? tagsRaw.length : 0;
    final hasAny = filled > 0;
    // Wave CY.18.200: mode badge.
    final modeLabel = creatorModeLabel(
      mode: session?.mode,
      editingPersonaId: session?.editingPersonaId,
    );
    return Material(
      color: EmberColors.bgPanel,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: const BoxDecoration(
            border: Border(
              bottom: BorderSide(color: EmberColors.stroke),
            ),
          ),
          padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
          child: Row(
            children: [
              Container(
                width: 26,
                height: 26,
                decoration: BoxDecoration(
                  color: EmberColors.primary.withValues(alpha: 0.12),
                  borderRadius: BorderRadius.circular(7),
                ),
                child: const Icon(
                  Icons.article_outlined,
                  color: EmberColors.primary,
                  size: 15,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Wave CY.18.200: name row + optional mode badge.
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Flexible(
                          child: Text(
                            name.isEmpty ? 'Untitled' : name,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: hasAny
                                  ? EmberColors.textHigh
                                  : EmberColors.textDim,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (modeLabel != null) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 2),
                            decoration: BoxDecoration(
                              color: EmberColors.primary.withValues(alpha: 0.13),
                              borderRadius: BorderRadius.circular(5),
                            ),
                            child: Text(
                              modeLabel,
                              style: const TextStyle(
                                color: EmberColors.primary,
                                fontSize: 10,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    // Wave CQ: live token count alongside the filled
                    // count so the user can see card weight as they
                    // build it. Empty cards skip the suffix entirely
                    // to avoid a stray " · ~0 tokens" line.
                    Builder(builder: (_) {
                      final tokenLabel =
                          formatTokenCount(approxTokensForCanvas(canvas));
                      return Text(
                        '$filled/$total fields'
                        '${tagsCount > 0 ? ' · $tagsCount tags' : ''}'
                        '${tokenLabel != null ? ' · $tokenLabel' : ''}',
                        style: const TextStyle(
                          color: EmberColors.textDim,
                          fontSize: 11,
                        ),
                      );
                    }),
                  ],
                ),
              ),
              const Icon(
                Icons.chevron_right,
                size: 18,
                color: EmberColors.textDim,
              ),
            ],
          ),
        ),
      ),
    );
  }

  static bool _isPillFilled(dynamic v) {
    if (v == null) return false;
    if (v is String) return v.trim().isNotEmpty;
    if (v is List) return v.isNotEmpty;
    if (v is Map) return v.isNotEmpty;
    return true;
  }

  // The visible-by-default chara_card_v2 keys used for the "X/Y fields"
  // pill counter. Wave BB realignment: only the seven main fields the
  // user actually fills are counted. Advanced-tray fields (personality —
  // always empty by spec — system_prompt, post_history_instructions,
  // alternate_greetings, creator, character_version, extensions) are
  // excluded so the pill reaches `7/7` on a complete card instead of
  // capping at `7/14`.
  static const _trackedFields = <String>[
    'name',
    'description',
    'scenario',
    'first_mes',
    'mes_example',
    'tagline',
    'tags',
    'creator_notes',
  ];

  // Wave CY.18.222: personas only carry these fields on the canvas (see
  // `_personaToCanvas`) — name, description, tagline, and dialogue examples
  // (`mes_example`). They have no scenario / first message / tags /
  // creator-notes, so the pill counts a persona against this list to avoid a
  // misleading "X/8".
  static const _personaTrackedFields = <String>[
    'name',
    'description',
    'tagline',
    'mes_example',
  ];

  /// Picks the field set the pill counts against, based on the session mode.
  /// Persona sessions (create or "Edit persona") use the smaller persona
  /// schema; everything else (character / scenario / edit-card) uses the
  /// full character field set. Static + null-tolerant so it can be unit
  /// tested without a State instance.
  static List<String> _pillTrackedFields(CreatorSession? session) {
    final isPersona =
        session?.mode == 'persona' || session?.editingPersonaId != null;
    return isPersona ? _personaTrackedFields : _trackedFields;
  }
}

/// What the save sheet asks `_commitSave` to do after persisting
/// the Character. Default action is [startChat] — closes the create
/// loop so the user can immediately try the card they just built.
/// Wave CQ: `openEditor` retired — landing back in the manual editor
/// immediately after finishing the card via the Creator was a confusing
/// double-step. Replaced with `library`: persists the card and pops
/// back to the Characters tab with a snackbar confirmation.
enum _SaveAction { startChat, library, exportPng }

/// Wave CY.18.217: when SAVING an edited card (character / scenario /
/// persona), the user chooses whether to overwrite the original in place
/// or fork a brand-new copy that leaves the original untouched. The
/// " (copy)" name suffix lives in `withCopyNameSuffix` (creator_cascade.dart).
enum _SaveMode { overwrite, copy }

class _SaveCardSheet extends StatefulWidget {
  final Map<String, dynamic> canvas;
  /// Wave CV.16: in edit mode the existing character's avatar (as a
  /// `data:image/...;base64,...` URL) is prefilled so the user isn't
  /// asked to re-pick. Null on create flow.
  final String? existingAvatarDataUrl;
  /// Persona Creator: when true the sheet shows ONE "Save persona"
  /// button (no start-chat / PNG-export / library actions, no PNG
  /// helper text) and the action passed to [onSubmit] is always
  /// [_SaveAction.library] (the persona save path ignores the action).
  final bool personaMode;

  /// Bindings to pre-select. Seeded from the card/persona being EDITED (so the
  /// existing bindings are preserved + shown), or empty for a fresh build —
  /// which is the gap this closes: a brand-new Creator card can now bind a
  /// lorebook at save time instead of having to reopen the manual editor.
  final List<String> initialLorebookIds;

  final Future<void> Function({
    required Uint8List? avatarPng,
    required _SaveAction action,
    required List<String> lorebookIds,
  }) onSubmit;

  const _SaveCardSheet({
    required this.canvas,
    required this.onSubmit,
    this.existingAvatarDataUrl,
    this.personaMode = false,
    this.initialLorebookIds = const <String>[],
  });

  @override
  State<_SaveCardSheet> createState() => _SaveCardSheetState();
}

class _SaveCardSheetState extends State<_SaveCardSheet> {
  /// Newly-picked avatar bytes for this save. When null AND
  /// [widget.existingAvatarDataUrl] is present (edit mode), the save
  /// path keeps the original avatar untouched.
  Uint8List? _avatar;
  bool _saving = false;

  /// Wave CV.16: decode the existing avatar URL to bytes for preview.
  /// Cached so we don't decode on every rebuild.
  Uint8List? _existingAvatarBytes;

  /// Lorebook bindings chosen in this sheet. Seeded from
  /// [widget.initialLorebookIds] (existing card on edit; empty on a fresh
  /// build) and the single source of truth handed to the commit path.
  late List<String> _lorebookIds =
      List<String>.from(widget.initialLorebookIds);

  @override
  void initState() {
    super.initState();
    final url = widget.existingAvatarDataUrl;
    if (url != null && url.startsWith('data:')) {
      final comma = url.indexOf(',');
      if (comma > 0) {
        try {
          _existingAvatarBytes = base64Decode(url.substring(comma + 1));
        } catch (_) {/* leave null */}
      }
    }
  }

  /// The bytes the preview should render — newly picked wins, else the
  /// existing avatar (edit-mode preserve).
  Uint8List? get _previewBytes => _avatar ?? _existingAvatarBytes;

  /// True when we have an image available to ship with PNG export
  /// (either freshly picked or the existing card's avatar).
  bool get _hasAvatarForExport => _previewBytes != null;

  Future<void> _pickAvatar() async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.image,
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.single.bytes;
      if (bytes == null) return;
      if (!mounted) return;
      // Wave CQ: no longer FORCE a crop on initial pick. botbooru and
      // most card hosts show full bot art uncropped; the user can
      // still recrop manually if the face isn't centered well via the
      // separate Recrop action. Image goes in as-is.
      setState(() => _avatar = bytes);
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Could not pick image: $e')),
      );
    }
  }

  Future<void> _submit({required _SaveAction action}) async {
    if (_saving) return;
    setState(() => _saving = true);
    try {
      // Wave CV.16: in edit mode (no new pick but existing avatar
      // present), pass the existing bytes through so the save path
      // and PNG export both have the image without the user having
      // to re-pick.
      await widget.onSubmit(
          avatarPng: _previewBytes, action: action, lorebookIds: _lorebookIds);
      // Wave CV.16: the library / startChat actions handle navigation
      // themselves (popping sheet + assistant screen). Only attempt
      // the sheet pop if we're still mounted AND the route is still
      // around (e.g. the exportPng path returned without navigating).
      if (mounted && Navigator.canPop(context)) {
        Navigator.of(context).pop();
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = (widget.canvas['name'] is String)
        ? (widget.canvas['name'] as String).trim()
        : 'Untitled';
    final tagsRaw = widget.canvas['tags'];
    final tags = (tagsRaw is List) ? tagsRaw : const [];
    final filledFields = widget.canvas.values.where((v) {
      if (v == null) return false;
      if (v is String) return v.trim().isNotEmpty;
      if (v is List) return v.isNotEmpty;
      if (v is Map) return v.isNotEmpty;
      return true;
    }).length;

    return Padding(
      padding: EdgeInsets.only(
        bottom: MediaQuery.of(context).viewInsets.bottom,
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Grabber
            Padding(
              padding: const EdgeInsets.only(top: 8, bottom: 8),
              child: Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: EmberColors.stroke,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  // Avatar slot — tap to pick / re-crop.
                  GestureDetector(
                    onTap: _saving ? null : _pickAvatar,
                    child: Container(
                      width: 72,
                      height: 72,
                      decoration: BoxDecoration(
                        color: EmberColors.bgDeep,
                        border: Border.all(
                          color: _previewBytes == null
                              ? EmberColors.stroke
                              : EmberColors.primary.withValues(alpha: 0.6),
                          width: _previewBytes == null ? 1 : 2,
                        ),
                        borderRadius: BorderRadius.circular(12),
                        image: _previewBytes != null
                            ? DecorationImage(
                                image: MemoryImage(_previewBytes!),
                                fit: BoxFit.cover,
                              )
                            : null,
                      ),
                      child: _previewBytes == null
                          ? const Center(
                              child: Icon(Icons.add_a_photo_outlined,
                                  color: EmberColors.textMid, size: 26),
                            )
                          : null,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          name.isEmpty
                              ? (widget.personaMode
                                  ? 'Untitled persona'
                                  : 'Untitled character')
                              : name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 2),
                        Text(
                          '$filledFields fields filled'
                          '${tags.isNotEmpty ? ' · ${tags.length} tags' : ''}',
                          style: const TextStyle(
                            color: EmberColors.textDim,
                            fontSize: 12,
                          ),
                        ),
                        const SizedBox(height: 6),
                        TextButton.icon(
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 6, vertical: 0),
                            minimumSize: const Size(0, 28),
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          icon: Icon(
                            _previewBytes == null
                                ? Icons.image_outlined
                                : Icons.crop,
                            size: 14,
                            color: EmberColors.primary,
                          ),
                          label: Text(
                            _previewBytes == null
                                ? 'Pick avatar image'
                                : 'Change image',
                            style: const TextStyle(
                              color: EmberColors.primary,
                              fontSize: 12,
                            ),
                          ),
                          onPressed: _saving ? null : _pickAvatar,
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            // Lorebook binding — closes the gap where a fresh Creator build
            // could never bind a world (you had to save, then reopen the
            // manual editor). Shown only when lorebooks exist; seeded with the
            // card's current bindings on edit. Hidden when there's nothing to
            // bind to keep the sheet uncluttered.
            if (context.watch<AppStore>().lorebooks.isNotEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                child: LorebookBindingSection(
                  selectedIds: _lorebookIds,
                  label: widget.personaMode
                      ? 'Persona lorebooks'
                      : 'Linked lorebooks',
                  sublabel:
                      'Bind a world so it travels with this ${widget.personaMode ? 'persona' : 'card'} '
                      '(optional — you can change this later in the editor).',
                  onChanged: (ids) => setState(() => _lorebookIds = ids),
                ),
              ),
            const Divider(color: EmberColors.stroke, height: 1),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 14, 16, 16),
              child: widget.personaMode
                  // Persona Creator: ONE simple "Save persona" action. No
                  // start-chat / PNG-export / library — those are
                  // character-only. The persona save path ignores the
                  // _SaveAction (passes library by convention).
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.person_outline, size: 16),
                            label: const Text('Save persona'),
                            onPressed: _saving
                                ? null
                                : () => _submit(action: _SaveAction.library),
                          ),
                        ),
                        const SizedBox(height: 4),
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            'The avatar is optional — you can pick one now '
                            'or add it later from the Personas list.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                              color: EmberColors.textDim,
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        // Default action — saves the card AND drops the
                        // user straight into a chat with it. Closes the
                        // create → test loop without an extra tap.
                        SizedBox(
                          width: double.infinity,
                          child: ElevatedButton.icon(
                            icon: const Icon(Icons.chat_bubble_outline,
                                size: 16),
                            label: const Text('Save & start chat'),
                            onPressed: _saving
                                ? null
                                : () =>
                                    _submit(action: _SaveAction.startChat),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: OutlinedButton.icon(
                            icon: const Icon(Icons.ios_share, size: 16),
                            label: Text(!_hasAvatarForExport
                                ? 'Save & export PNG (pick image first)'
                                : 'Save & export PNG'),
                            onPressed: (_saving || !_hasAvatarForExport)
                                ? null
                                : () =>
                                    _submit(action: _SaveAction.exportPng),
                          ),
                        ),
                        const SizedBox(height: 8),
                        SizedBox(
                          width: double.infinity,
                          child: TextButton.icon(
                            icon: const Icon(Icons.library_add_outlined,
                                size: 16),
                            // Wave CQ: was "Save & open editor" — replaced
                            // because landing in the editor IMMEDIATELY
                            // after finishing the card via Creator is
                            // busywork. New action just saves and goes
                            // back to Characters.
                            label: const Text('Just save it'),
                            onPressed: _saving
                                ? null
                                : () => _submit(action: _SaveAction.library),
                          ),
                        ),
                        const SizedBox(height: 4),
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          child: Text(
                            !_hasAvatarForExport
                                ? 'PNG export needs an avatar image so the chara_card_v2 metadata can be embedded.'
                                : 'PNG is saved to PyreExports and opened in your share sheet.',
                            textAlign: TextAlign.center,
                            style: const TextStyle(
                              color: EmberColors.textDim,
                              fontSize: 11,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
