import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform, visibleForTesting;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/chat_api.dart';
import '../services/chat_export.dart';
import '../services/web_download.dart';
import '../services/chat_prompt_builder.dart';
import '../services/refusal_detector.dart';
import '../services/generation_keepalive.dart';
import '../services/lorebook_inject.dart';
import '../services/live_sheet.dart' as lsheet;
import '../services/llm_debug_log.dart';
import '../services/memory.dart' as ltm;
import '../services/param_policy.dart'
    show isContextOverflowError, contextLimitFromError;
import '../services/preset_assembly.dart';
import '../services/regex_rules.dart';
import '../services/scene_background.dart' as scenebg;
import '../services/story_roadmap.dart' as roadmap;
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/gallery_strip.dart' show showImageSwipeViewer;
import '../widgets/lightbox.dart';
import '../widgets/chat_text.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/export_snack.dart';
import '../widgets/fallback_prompt_card.dart';
import 'character_details_sheet.dart';
import 'chat_info_sheet.dart';
import 'chat_picker_screens.dart';
import 'chat_tree_screen.dart';
import 'customize_chat_sheet.dart';
import 'group_lorebooks_sheet.dart';
import 'live_sheet_screen.dart';
import 'memory_screen.dart';
import 'presets_screen.dart';
import 'script_screen.dart';

/// Wave CY.18.50: true on Windows / Linux / macOS desktop builds. Used
/// to gate hover-only reveals (action toolbars on message bubbles)
/// that don't make sense on touch devices.
bool get _isDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

// kExplicitNoPersonaId is declared in models.dart (canonical location).

/// Fix 1 perf-regression test seam (2026-07): message-id → build count for
/// `_MessageBubbleState.build()`. Test-only signal that a non-streaming
/// bubble's count stays flat while the isolated streaming bubble's climbs;
/// production code never reads this. Call [debugResetBubbleBuildCounts]
/// between test cases.
@visibleForTesting
final Map<String, int> debugBubbleBuildCounts = <String, int>{};

/// Test-only: clear the per-message build-count seam above.
@visibleForTesting
void debugResetBubbleBuildCounts() => debugBubbleBuildCounts.clear();

/// Kinds that render as the centred AUX NOTE (no user-side bubble, no avatar,
/// no variant arrows) instead of a full chat bubble.
///
/// [MessageKind.system] — always was. [MessageKind.ooc] — RESTORED here
/// 2026-07 (owner: "OOC não deve aparecer assim, tem que voltar ao formato
/// antigo"), reversing the 1.1.3 de-risk-wave move to the full bubble. The
/// "read-only" in the name is about the VISUAL (no bubble controls inline) —
/// long-press on the note still opens the full message menu, which is gated
/// by `m.kind`, so OOC keeps Edit / Delete / Branch from the note, and the
/// aux branch renders the inline editor when editing. Scene stays a full
/// bubble (the owner only reverted OOC). Pure helper, tested in
/// test/ooc_message_behavior_test.dart.
bool isReadOnlyAuxKind(MessageKind k) =>
    k == MessageKind.system || k == MessageKind.ooc;

/// True on Android and iOS — used to gate haptic feedback calls so they never
/// fire on desktop or web (where `HapticFeedback` is a no-op or annoying).
bool get _isMobileForHaptics {
  if (kIsWeb) return false;
  return defaultTargetPlatform == TargetPlatform.android ||
      defaultTargetPlatform == TargetPlatform.iOS;
}

/// Slice D-3 (2026-07-02): the bounded retry cap for the reactive
/// context-recovery loop in [_ChatScreenState._runGenerationInto]. Combined
/// with [contextTrimFloor] (a second, independent stop condition — the
/// window can't shrink below the floor), this guarantees the loop always
/// terminates: either the attempt counter or the window size runs out.
const int kMaxContextTrims = 4;

/// Slice D-3: the hardcoded MINIMUM history-window size the reactive
/// context-recovery loop will ever request — never below the last message
/// of the replayed window (the current exchange's newest turn). This is the
/// real safety floor; `PlanSegment.droppable` (prompt_plan.dart) is inert and
/// must NOT be relied on. `windowLen <= 0` → floor is 0 (nothing to keep).
int contextTrimFloor(int windowLen) => windowLen <= 0 ? 0 : 1;

/// Slice D-3: compute the NEXT SMALLER history-window size after an overflow.
/// [currentWindowLen] is the number of history messages the failing request
/// just carried (the full post-recap window on the first attempt). Returns a
/// value strictly less than [currentWindowLen] (unless already at the floor,
/// in which case it returns the floor unchanged so the caller can detect "no
/// more room to shrink").
///
///   * [learnedLimitTokens] known (a real number parsed from the provider's
///     error, or previously learned) + [estimatedTokensPerMessage] > 0 →
///     PRECISE cut: shrink the window to roughly fit under the limit (using
///     the observed per-message token estimate), so the very next retry is
///     likely to succeed in one shot instead of slowly stepping down.
///   * Otherwise (no usable numbers) → HALVE the window — a robust default
///     that converges to the floor in at most `log2(N)` steps, well inside
///     [kMaxContextTrims] for any chat history a phone/desktop app manages.
///
/// Always monotone-shrinking and always clamped to
/// `[contextTrimFloor(currentWindowLen), currentWindowLen - 1]` (or exactly
/// the floor when [currentWindowLen] is already at/under it) — never grows,
/// never returns something >= the input.
int nextSmallerWindow(
  int currentWindowLen, {
  int? learnedLimitTokens,
  int? estimatedPromptTokens,
  double? estimatedTokensPerMessage,
}) {
  final floor = contextTrimFloor(currentWindowLen);
  if (currentWindowLen <= floor) return floor;

  int candidate;
  if (learnedLimitTokens != null &&
      learnedLimitTokens > 0 &&
      estimatedPromptTokens != null &&
      estimatedPromptTokens > 0 &&
      estimatedTokensPerMessage != null &&
      estimatedTokensPerMessage > 0) {
    // How many tokens we need to shed, converted to a message count via the
    // observed average — then subtract a bit extra (ceil, plus the shed
    // count itself) so we don't re-overflow by a rounding hair.
    final overBy = estimatedPromptTokens - learnedLimitTokens;
    if (overBy > 0) {
      final dropMessages =
          (overBy / estimatedTokensPerMessage).ceil() + 1; // +1 safety margin
      candidate = currentWindowLen - dropMessages;
    } else {
      // Estimate says we're already within budget — still take SOME action
      // (this function is only called after a real overflow) via a halve.
      candidate = (currentWindowLen / 2).floor();
    }
  } else {
    candidate = (currentWindowLen / 2).floor();
  }

  if (candidate >= currentWindowLen) candidate = currentWindowLen - 1;
  if (candidate < floor) candidate = floor;
  return candidate;
}

/// chat-core-2-05: build the one-shot system prompt for the Fill-In scenario
/// opener. Pure (no Flutter / no AppStore) so it can be unit-tested and so the
/// dialog closure stays thin.
///
/// The opener must run on the SAME baseline context the ongoing chat does, or
/// the generated greeting can contradict the lore / preset every later turn
/// enforces. So this folds in, in order:
///   1. the active preset's main (system) prompt, when set — sets the register;
///   2. the responder's canon (name / description / personality / scenario /
///      example dialogue);
///   3. the user persona;
///   4. the bound lorebook hits that fired this turn (`--- Lore ---`);
///   5. the user's typed scenario + the output instruction.
///
/// [filledScenario] is the user's scenario with `{{char}}`/`{{user}}` already
/// substituted. [loreHits] are the entries `scanLorebookHits` returned for the
/// chat. [presetMainPrompt] is the assembled active-preset system text (empty
/// for no preset). Empty sections are omitted (no stray headers).
String buildFillInOpenerPrompt({
  required Character? responder,
  required Persona? persona,
  required String filledScenario,
  required List<LoreEntry> loreHits,
  required String presetMainPrompt,
  String? jointPartyBlock,
}) {
  final sys = StringBuffer();
  // 1. Active preset main prompt first — it frames tone / register the rest of
  // the chat uses. (datamodel-...-02: {{wiAfter}} no longer advertised, but a
  // preset's own {{...}} tokens are intentionally left literal here — the
  // opener is a one-shot hand-built prompt, not the full builder pipeline.)
  if (presetMainPrompt.trim().isNotEmpty) {
    sys.writeln(presetMainPrompt.trim());
    sys.writeln();
  }
  // Party mode (2026-07, owner feedback: "a new greeting still opened as the
  // primary character only"): when the chat is a party, the caller passes the
  // SAME joint block every scene turn uses (buildJointPartyBlock — every
  // member's card + the narrator scene instruction) and it REPLACES the
  // single-responder canon below, so the generated opener sets up the whole
  // party from the very first message.
  if (jointPartyBlock != null && jointPartyBlock.trim().isNotEmpty) {
    sys.writeln(jointPartyBlock.trim());
  } else if (responder != null) {
    sys.writeln('You are ${responder.name}.');
    if (responder.description.isNotEmpty) {
      sys.writeln('\nDescription:\n${responder.description}');
    }
    if (responder.personality.isNotEmpty) {
      sys.writeln('\nPersonality:\n${responder.personality}');
    }
    // Fold in the card's own scenario field and dialogue examples so the
    // generated opener is consistent with the character's canon + voice.
    if (responder.scenario.trim().isNotEmpty) {
      sys.writeln('\nScenario:\n${responder.scenario.trim()}');
    }
    if (responder.mesExample.trim().isNotEmpty) {
      sys.writeln('\nExample dialogue:\n${responder.mesExample.trim()}');
    }
  }
  if (persona != null) {
    sys.writeln('\nUser persona — ${persona.name}: ${persona.description}');
    if (persona.dialogueExamples.trim().isNotEmpty) {
      sys.writeln(
          '\n${persona.name}\'s dialogue examples:\n${persona.dialogueExamples.trim()}');
    }
  }
  // 4. Bound lorebook hits — the same world facts the ongoing chat injects via
  // {{wiBefore}} / the inline "--- Lore ---" block, so the opener can't
  // contradict established lore.
  final loreParts = <String>[];
  for (final e in loreHits) {
    final c = e.content.trim();
    if (c.isNotEmpty) loreParts.add(c);
  }
  if (loreParts.isNotEmpty) {
    sys.writeln('\n--- Lore ---');
    sys.writeln(loreParts.join('\n'));
  }
  sys.writeln(
      '\nWrite a fresh opening message — vivid, in-character, that begins with this scenario:\n\n$filledScenario');
  sys.writeln(
      '\nUse *italics* for actions and "quotes" for dialogue. Output ONLY the opening message, no meta or explanation.');
  // C-4: the persona AND responder blocks are written RAW above, and personas
  // built via `buildPersonaFromCharacter` ALWAYS carry literal {{user}}/{{char}}
  // macros — so without this pass the opener-generation prompt ships those
  // macros to the model verbatim (only `filledScenario` was pre-substituted).
  // The ongoing-chat builder resolves them via a final global name-fill pass
  // (`fillNamePlaceholders`, chat_prompt_builder.dart); this separate one-shot
  // builder was missed. Apply the SAME name-only resolution over the whole
  // assembled prompt. Idempotent: `filledScenario` and the preset main prompt
  // hold no macros, so re-running is a no-op there. {{user}}=persona name,
  // {{char}}=responder name (matches the main path's resolution).
  return fillNamePlaceholders(
    sys.toString().trim(),
    charName: responder?.name,
    personaName: persona?.name,
  );
}

class ChatScreen extends StatefulWidget {
  final String chatId;
  const ChatScreen({super.key, required this.chatId});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

/// Wave CY.18.99: snapshot of a pending fallback offer. Held on the
/// chat-screen state while the inline card is showing; cleared on Keep
/// or after a switch fires.
class _PendingFallback {
  final FallbackReason reason;
  final String assistantId;
  final ApiProvider failed;
  final ApiProvider next;
  final ApiProvider? clean; // refusal case, only when `next` has a record
  const _PendingFallback({
    required this.reason,
    required this.assistantId,
    required this.failed,
    required this.next,
    this.clean,
  });
}

class _ChatScreenState extends State<ChatScreen> {
  final _scrollCtl = ScrollController();
  final _inputCtl = TextEditingController();
  final _inputFocus = FocusNode();
  StreamSubscription<String>? _streamSub;
  String _streamBuffer = '';
  bool _generating = false;
  String? _streamMessageId;

  // Fix 1 (2026-07 perf pass — whole-screen streaming jank): isolates the
  // ACTIVE streaming bubble's per-token repaints from the rest of the tree.
  // Lazily created the moment a generation starts (see `_streamingNotifier`),
  // read by the one `_MessageBubble` whose `isStreaming` is true (via
  // `ValueListenableBuilder`), and settled (one last flush, then disposed)
  // once the turn ends — see `_settleStreamingNotifier`. `_streamMessageId`
  // remains the single source of truth for WHICH bubble is streaming; this
  // notifier only carries WHAT that bubble should currently render, so the
  // two can never disagree about identity.
  ValueNotifier<String>? _streamingTextNotifier;

  /// The `AppStore` that owns the pending coalesced-flush timer for
  /// [_streamingTextNotifier], cached at CREATION time (always inside a live
  /// build/callback, so `context.read` is safe there). `dispose()` runs
  /// AFTER this element may already be deactivated in the unmount cascade —
  /// `context.read<AppStore>()` from inside `dispose()` throws ("looking up
  /// a deactivated widget's ancestor is unsafe"), so this cached reference
  /// is what lets teardown clean up the pending timer without touching
  /// `context` at all.
  AppStore? _streamingNotifierStore;

  /// Lazily creates (or reuses) the notifier for the current streaming turn.
  /// A context-recovery retry / smart-fallback retry re-enters the same
  /// generation method for the SAME `assistantId` — reusing the existing
  /// notifier (rather than tearing down and recreating one per attempt)
  /// means the `ValueListenableBuilder` never remounts mid-turn.
  ValueNotifier<String> _streamingNotifier() {
    _streamingNotifierStore ??= context.read<AppStore>();
    return _streamingTextNotifier ??= ValueNotifier<String>(_streamBuffer);
  }

  /// Settle the streaming turn: flush any pending coalesced update so the
  /// final chunk is visible, then drop the notifier. Safe to call multiple
  /// times / when no notifier exists. Called from every onDone / onError /
  /// Stop / settle path so the bubble always ends up reading the plain
  /// `message.text` again (via the next normal `notifyListeners()`) instead
  /// of being stuck on a disposed notifier.
  void _settleStreamingNotifier() {
    final notifier = _streamingTextNotifier;
    if (notifier == null) return;
    _streamingNotifierStore?.flushStreamingNotifier(notifier);
    _streamingNotifierStore = null;
    _streamingTextNotifier = null;
    notifier.dispose();
  }

  /// H-1: this screen's own outstanding GenerationKeepAlive refs (light —
  /// the chat path never uses heavy). Bumped by [_keepAliveStart] and
  /// dropped by [_keepAliveStop] so dispose() can release exactly what's
  /// still held when the user navigates away mid-stream. Cancelling an
  /// `async*` subscription fires neither onDone nor onError, so without
  /// this drain the global `_anyRefs` would stay > 0 forever and the
  /// SyncEngine would skip every push until app restart.
  int _keepAliveHeld = 0;
  Future<void> _keepAliveStart() {
    _keepAliveHeld++;
    return GenerationKeepAlive.start();
  }

  void _keepAliveStop() {
    if (_keepAliveHeld > 0) {
      _keepAliveHeld--;
      unawaited(GenerationKeepAlive.stop());
    }
  }

  /// Strip ONLY Pyre's end-of-stream sentinels (finish-reason +
  /// dropped-frame) from streamed chat text. Unlike `stripStreamArtifacts`
  /// this deliberately KEEPS `<think>…</think>` in the stored variant —
  /// ChatText hides it for display and the per-message reasoning toggle
  /// lets the user reveal it. We only want the ugly internal sentinels out
  /// of the persisted text so they never render literally.
  String _stripChatSentinels(String raw) => raw
      .replaceAll(pyreFinishSentinelRegex, '')
      .replaceAll(pyreDroppedFramesRegex, '');

  // Wave CY.18.99: smart provider fallback (send path). The chain is
  // built once per fresh user turn; the index walks it as the user
  // confirms each switch. _pendingFallback != null means a card is
  // showing in the message slot identified by its assistantId.
  List<ApiProvider> _fallbackChain = const [];
  int _fallbackIndex = 0;
  _PendingFallback? _pendingFallback;
  // Wave CY.18.99 (audit C4): dedupe refusal counting — bump a provider
  // at most once per assistant slot, so a user walking/retrying the same
  // turn doesn't inflate the self-learning "tends to censor" signal.
  final Set<String> _refusalCountedKeys = {};

  // Slice D-3 (2026-07-02): reactive context-recovery loop state, scoped to
  // ONE logical turn (reset in `_clearPendingFallback`, called at the top of
  // every generation entry point — mirrors `_fallbackChain`/`_fallbackIndex`
  // above). `_contextTrimWindow` null == "no trim requested yet" (the first
  // attempt on THIS provider uses whatever `_buildTurns`'s own pre-trim
  // read resolves, which is null unless a learned limit already applies);
  // once set it is the exact `maxHistoryMessages` the NEXT retry passes.
  // `_contextTrimAttempts` is the bounded-loop counter — capped at
  // `kMaxContextTrims`, a stop condition independent of the window floor.
  int? _contextTrimWindow;
  int _contextTrimAttempts = 0;

  /// Wave CY.18.5: stable GlobalKey per message id so we can scroll
  /// to a specific bubble (used when the user picks a node in the
  /// chat tree). Lazily populated by [_keyFor] inside itemBuilder.
  /// Pruned isn't strictly needed — stale keys for removed messages
  /// are tiny and the chat is bounded.
  final Map<String, GlobalKey> _messageKeys = {};
  GlobalKey _keyFor(String messageId) =>
      _messageKeys.putIfAbsent(messageId, () => GlobalKey());

  /// Wave CY.18.6: in-flight flag so a still-running auto-summarise
  /// doesn't kick off a SECOND parallel summarise (which would race
  /// the user's next chat turn for the same provider's rate limits
  /// and on some proxies silently lose one of the two requests). The
  /// LLM call inside generateCheckpoint is long-running; the flag
  /// stays set across its full await window.
  bool _summarising = false;
  // Wave CY.18.160: auto-summarise used to fail completely silently — a
  // null checkpoint (empty LLM reply / provider error / offline) just
  // returned with no UI feedback, so the user saw "nothing fires" with no
  // way to know it even tried. Surface the FIRST failure per chat session
  // as a transient SnackBar; reset on success so a later genuine failure
  // is shown again, but don't spam every message while a provider is down.
  bool _autoSummariseFailureShown = false;
  // Wave CY.18.173: Live Sheet auto-update serialisation latch + one-time
  // failure SnackBar (mirrors the summariser latches above).
  bool _liveSheetUpdating = false;
  bool _liveSheetFailureShown = false;
  // Wave CY.18.184: dynamic scene-background throttle + guards.
  static const int kSceneClassifyCooldown = 3; // char-turns between classifier calls
  bool _sceneClassifying = false;
  bool _sceneFailureShown = false;
  // Variant index pinned at stream start. Chunks keep landing here even
  // if the user navigates `<`/`>` mid-stream — otherwise they'd overwrite
  // whichever variant they swiped to.
  int? _streamVariantIndex;

  /// Which character should respond next. Defaults to the primary.
  String? _responderId;

  /// Guide (Part 2 — "Guide the reply"): a transient, ONE-SHOT instruction
  /// armed by the user for the NEXT Send. It is NEVER written to chat history,
  /// never persisted, never synced — it only rides as `ChatPromptInputs.guideNote`
  /// for a single generation. A dismissible chip above the input bar shows it's
  /// armed; sending consumes it (moved into `_inFlightGuide`, then cleared).
  String? _armedGuide;

  /// The guide actually threaded into the IN-FLIGHT generation. `_send` moves
  /// `_armedGuide` here at dispatch (clearing the armed slot so it's one-shot),
  /// and `_runGenerationInto` reads it. Keeping it separate from `_armedGuide`
  /// means a smart-fallback RETRY of the SAME turn still applies the guide
  /// (it's the same logical reply), while a brand-new Send won't accidentally
  /// reuse a stale guide. Cleared when the generation settles.
  String? _inFlightGuide;

  /// Wave CI: safe resolution of the active responder. Falls back to
  /// the chat's primary character when `_responderId` is null OR when
  /// the previously-chosen responder has been removed from the chat
  /// (via Customize → Remove from chat). Without this fallback the
  /// system prompt would keep describing a character no longer in
  /// `characterIds`, and the message attribution would silently
  /// drift. Returns null only when the chat has no characters at all
  /// (deletion edge case).
  String? _activeResponderId(Chat chat) {
    final r = _responderId;
    if (r != null && chat.characterIds.contains(r)) return r;
    return chat.primaryCharacterId;
  }

  /// Wave CK: resolve the dataUrl to use for the chat backdrop based
  /// on the active settings. Returns null when no backdrop should
  /// render (either explicit None, or the chosen source is missing
  /// its image — e.g. Persona Avatar selected but no persona is set
  /// or the persona has no avatar).
  String? _resolveBackdrop(
      Character? character, Persona? persona, ChatSettings settings,
      [Chat? chat]) {
    // Wave CY.18.156: a per-chat override wins over the global ChatSettings.
    // `chat.backgroundSource == null` → inherit the global source + the
    // global custom image. When the chat overrides the source, its OWN
    // custom image is used (so a per-chat custom doesn't leak the global one
    // and vice-versa).
    final source = chat?.backgroundSource ?? settings.backgroundSource;
    final customUrl = chat?.backgroundSource != null
        ? chat?.customBackgroundDataUrl
        : settings.customBackgroundDataUrl;
    switch (source) {
      case ChatBackgroundSource.none:
        return null;
      case ChatBackgroundSource.custom:
        return customUrl;
      case ChatBackgroundSource.personaAvatar:
        // Fall back to character avatar if the persona has no image —
        // better than leaving the chat naked and inconsistent.
        // Non-destructive Recrop: use the UNCROPPED original when one exists so
        // the backdrop shows the WHOLE image (the recropped thumbnail is for
        // the small circle, not a full-bleed background).
        return persona?.avatarOriginal ??
            persona?.avatar ??
            character?.avatarOriginal ??
            character?.avatar;
      case ChatBackgroundSource.characterAvatar:
        return character?.avatarOriginal ?? character?.avatar;
      case ChatBackgroundSource.dynamic:
        // Wave CY.18.184: resolve to a bundled asset path (rendered by
        // _BackdropImage's asset branch). null sceneBgFile -> no backdrop
        // yet (plain theme) until the first classifier call fires.
        return chat?.sceneBgFile == null
            ? null
            : 'asset:assets/scene_bg/images/${chat!.sceneBgFile}';
    }
  }

  /// True when the chat is scrolled within ~60px of the bottom. Auto-
  /// scroll (per-chunk during streaming and on new messages) is
  /// suppressed when false — see [_scrollToBottom].
  bool _stickToBottom = true;

  @override
  void initState() {
    super.initState();
    _scrollCtl.addListener(_onScroll);
    // Wave CY.18.163: open an existing conversation at the BOTTOM (latest
    // message), not the top. ChatScreen is pushed fresh per chat so this
    // runs once on entry; nothing has scrolled yet, so jumping is expected.
    _scrollToBottomOnOpen();
  }

  /// Jump to the newest message when the chat first opens.
  ///
  /// The message list is a lazy `ListView.builder` with variable-height
  /// bubbles, so `maxScrollExtent` is only an ESTIMATE on the first frame
  /// and GROWS as trailing items get measured (and as avatars / inline
  /// images settle). A single jump therefore lands short of the real
  /// bottom. We re-jump across successive frames until the extent stops
  /// growing (capped so it always terminates). Guarded by `_stickToBottom`
  /// so it bails the instant the user scrolls up during the settle.
  void _scrollToBottomOnOpen() {
    var tries = 0;
    var last = -1.0;
    void attempt() {
      if (!mounted || !_scrollCtl.hasClients || !_stickToBottom) return;
      final ext = _scrollCtl.position.maxScrollExtent;
      if (ext > _scrollCtl.position.pixels) _scrollCtl.jumpTo(ext);
      tries++;
      // Keep going only while the reachable bottom is still growing.
      if (tries < 10 && ext > last) {
        last = ext;
        WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
      }
    }

    WidgetsBinding.instance.addPostFrameCallback((_) => attempt());
  }

  void _onScroll() {
    if (!_scrollCtl.hasClients) return;
    final pos = _scrollCtl.position;
    // ≤60px overflow = nothing meaningful to scroll → treat as
    // at-bottom so the "Jump to bottom" pill never appears for tiny
    // chats with nowhere to jump.
    final atBottom = pos.maxScrollExtent <= 60 ||
        pos.maxScrollExtent - pos.pixels < 60;
    if (atBottom != _stickToBottom) {
      setState(() => _stickToBottom = atBottom);
    }
  }

  @override
  void dispose() {
    // H-1: release any keepalive refs this screen still holds. Cancelling
    // the subscription below never fires onDone/onError (the only places
    // _keepAliveStop runs), so drain the counter here to keep the global
    // refcount balanced. The loop decrements exactly what's outstanding —
    // no over-decrement.
    while (_keepAliveHeld > 0) {
      _keepAliveStop();
    }
    _streamSub?.cancel();
    // Fix 1: navigating away mid-stream must not leave the store holding a
    // pending coalesced-flush Timer that targets a notifier this screen is
    // about to drop (it would later fire `.value =` on a disposed
    // `ValueNotifier` and throw). Uses the STORE REFERENCE CACHED AT
    // CREATION TIME (`_streamingNotifierStore`), never `context.read` —
    // this element may already be deactivated by the time `dispose()` runs
    // in the unmount cascade, and `context.read<AppStore>()` here throws
    // ("looking up a deactivated widget's ancestor is unsafe").
    final pendingNotifier = _streamingTextNotifier;
    if (pendingNotifier != null) {
      _streamingNotifierStore?.flushStreamingNotifier(pendingNotifier);
      pendingNotifier.dispose();
      _streamingTextNotifier = null;
      _streamingNotifierStore = null;
    }
    _scrollCtl.removeListener(_onScroll);
    _scrollCtl.dispose();
    _inputCtl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Branch a user / OOC / scene message: stash the current downstream under
  /// the source variant, add an empty variant, focus the input for user
  /// messages. Non-destructive — swiping back to the original variant restores
  /// its conversation tail. Also used for OOC and Scene (same semantics).
  void _branchUserMessage(Chat chat, Message m) {
    // Never branch while a stream is in flight — the in-progress assistant
    // reply would be silently destroyed (we'd remove the message the
    // stream is writing into) and the rest of the response would land in
    // a dead bubble until onDone fires.
    if (_generating) return;
    // Sub-task B: haptic on add-variant (mobile only).
    if (_isMobileForHaptics) HapticFeedback.lightImpact();
    _clearPendingFallback(); // audit C1
    final store = context.read<AppStore>();
    final idx = chat.messages.indexWhere((x) => x.id == m.id);
    if (idx < 0) return;

    // Stash the existing tail under the CURRENT variant so it can be
    // restored if the user swipes back. Then remove it from the visible
    // chat — the new variant starts from a clean slate.
    if (idx < chat.messages.length - 1) {
      final tail = chat.messages.sublist(idx + 1);
      m.downstreamByVariant[m.selectedVariant] = List<Message>.from(tail);
      chat.messages.removeRange(idx + 1, chat.messages.length);
    }

    // Add a blank variant and select it so the bubble renders empty.
    // addVariant() also sets selectedVariant to the new index.
    store.addVariant(chat.id, m.id);
    _inputCtl.clear();
    _inputFocus.requestFocus();
  }

  Chat? _chat(AppStore store) {
    for (final c in store.chats) {
      if (c.id == widget.chatId) return c;
    }
    return null;
  }

  Character? _primaryCharacter(AppStore store, Chat chat) {
    final id = chat.primaryCharacterId;
    if (id == null) return null;
    return chat.characterSnapshots[id] ?? store.characterById(id);
  }

  /// Wave CX: bottom-sheet picker for changing the persona attached
  /// to THIS chat without touching the global default. Lists every
  /// persona in the library (with avatar + name + tagline) plus a
  /// "No persona" option for chats the user wants to run anonymous.
  /// Wave CY.15: kick off a fresh chat with [primary] from inside
  /// THIS chat (the "Start fresh chat" kebab). Routes through the
  /// shared helper so `askPersonaOnNewChat` is honoured the same way
  /// here as in every other entry point.
  Future<void> _startNewChatWithCharacter(Character primary) async {
    await startNewChatWithPersonaPrompt(
      context,
      primary,
      replace: true,
    );
  }

  Future<void> _showChatPersonaPicker(Chat chat) async {
    // Persona party (2026-07): MULTI-select. Pick one persona to play solo, or
    // several for a "persona party" — your messages then represent the whole
    // group (see buildJointPersonaBlock). Selection order = party order (first
    // = primary). A search field keeps it usable past 10+ personas.
    final store = context.read<AppStore>();
    final personas = store.personas.where((p) => !p.deleted).toList();
    // LinkedHashSet preserves selection order → the party's order + primary.
    final selected = <String>{...chat.effectivePersonaIds}
      ..removeWhere((id) => id == kExplicitNoPersonaId);
    var query = '';

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) {
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            final filtered = query.trim().isEmpty
                ? personas
                : personas
                    .where((p) =>
                        p.name.toLowerCase().contains(query.toLowerCase()))
                    .toList();
            final n = selected.length;
            final status = n == 0
                ? 'No persona'
                : n == 1
                    ? 'Solo — 1 persona'
                    : 'Persona party — $n personas (your messages = the '
                        'whole group)';
            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                    bottom: MediaQuery.of(sheetCtx).viewInsets.bottom),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Center(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 8, bottom: 8),
                        child: SizedBox(
                          width: 40,
                          height: 4,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: EmberColors.stroke,
                              borderRadius:
                                  const BorderRadius.all(Radius.circular(2)),
                            ),
                          ),
                        ),
                      ),
                    ),
                    Padding(
                      padding:
                          const EdgeInsets.fromLTRB(16, 4, 16, 2),
                      child: Text('Persona for this chat',
                          style: const TextStyle(
                              fontSize: 16, fontWeight: FontWeight.w600)),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: Text(
                        'Pick one to play solo, or several for a persona '
                        'party. Only affects this chat.',
                        style: TextStyle(
                            color: EmberColors.textMid,
                            fontSize: 12,
                            height: 1.3),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                      child: TextField(
                        onChanged: (v) => setSheetState(() => query = v),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: 'Search personas…',
                          prefixIcon: const Icon(Icons.search, size: 18),
                          border: const OutlineInputBorder(),
                        ),
                      ),
                    ),
                    Flexible(
                      child: ListView(
                        shrinkWrap: true,
                        children: [
                          for (final p in filtered)
                            CheckboxListTile(
                              value: selected.contains(p.id),
                              onChanged: (v) => setSheetState(() {
                                if (v == true) {
                                  selected.add(p.id);
                                } else {
                                  selected.remove(p.id);
                                }
                              }),
                              activeColor: EmberColors.primary,
                              controlAffinity:
                                  ListTileControlAffinity.trailing,
                              secondary: AvatarBubble(
                                dataUrl: p.avatar,
                                fallback: p.name,
                                radius: 16,
                              ),
                              title: Text(p.name),
                            ),
                        ],
                      ),
                    ),
                    const Divider(height: 1),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(status,
                                style: TextStyle(
                                    color: n > 1
                                        ? EmberColors.primary
                                        : EmberColors.textMid,
                                    fontSize: 12,
                                    fontWeight: n > 1
                                        ? FontWeight.w600
                                        : FontWeight.w400)),
                          ),
                          FilledButton(
                            style: FilledButton.styleFrom(
                              backgroundColor: EmberColors.primary,
                              foregroundColor: Colors.white,
                            ),
                            onPressed: () {
                              store.setChatPersonaParty(
                                  chat.id, selected.toList());
                              Navigator.of(sheet).pop();
                            },
                            child: const Text('Done'),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Wave 1.1 (F6): in-chat preset switcher. Lets the user see and swap the
  /// active preset (the system/main-prompt + sampling bundle) without leaving
  /// the conversation. The active preset is GLOBAL state — selecting a row
  /// drives `store.setActivePreset(id)`, the exact same method the full
  /// Presets screen uses — so the change takes effect on the NEXT message in
  /// every chat (no per-chat override). The locked "Pyre Default" appears and
  /// is selectable but its prompt text is never rendered (Waves 44/45/CY.18.10).
  Future<void> _showPresetSwitcher() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    // Local controller for the optional quick-edit field; only touched when
    // the active preset is unlocked. Disposed when the sheet closes.
    final quickEditCtl = TextEditingController();

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) {
        // StatefulBuilder so the radio check moves live and the quick-edit
        // expander can toggle without rebuilding the whole chat screen.
        bool quickEditOpen = false;
        return StatefulBuilder(
          builder: (sheetCtx, setSheetState) {
            // Read live from the store on every rebuild so an external change
            // (e.g. a backup restore) doesn't show a stale active marker.
            final liveStore = sheetCtx.watch<AppStore>();
            final presets = liveStore.visiblePresets;
            final activeId = liveStore.activePresetId;
            final active = liveStore.activePreset;

            return SafeArea(
              child: Padding(
                padding: EdgeInsets.only(
                  bottom: MediaQuery.of(sheetCtx).viewInsets.bottom,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: Padding(
                          padding: EdgeInsets.only(top: 8, bottom: 12),
                          child: SizedBox(
                            width: 40,
                            height: 4,
                            child: DecoratedBox(
                              decoration: BoxDecoration(
                                color: EmberColors.stroke,
                                borderRadius:
                                    BorderRadius.all(Radius.circular(2)),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 2),
                        child: Text(
                          'Preset',
                          style: TextStyle(
                              fontSize: 17, fontWeight: FontWeight.w600),
                        ),
                      ),
                      Padding(
                        padding: EdgeInsets.fromLTRB(20, 0, 20, 8),
                        child: Text(
                          'The system prompt + sampling bundle for this chat. '
                          'Takes effect on your next message.',
                          style: TextStyle(
                              color: EmberColors.textMid, fontSize: 12),
                        ),
                      ),
                      // Wave 1.1: RadioGroup ancestor + leading Radio rows —
                      // the non-deprecated pattern used elsewhere (e.g. the
                      // background-source picker in customize_chat_sheet.dart).
                      // Selecting a row drives `setActivePreset`, the SAME
                      // method the full Presets screen uses.
                      RadioGroup<String>(
                        groupValue: activeId,
                        onChanged: (id) {
                          if (id == null) return;
                          liveStore.setActivePreset(id);
                          final name = liveStore.activePreset?.name ?? '';
                          Navigator.pop(sheet);
                          messenger.showSnackBar(
                            SnackBar(content: Text('Switched to $name')),
                          );
                        },
                        child: Column(
                          children: [
                            for (final p in presets)
                              ListTile(
                                leading: Radio<String>(
                                  value: p.id,
                                  activeColor: EmberColors.primary,
                                ),
                                title: Row(
                                  children: [
                                    Flexible(
                                      child: Text(
                                        p.name,
                                        style: const TextStyle(
                                            fontWeight: FontWeight.w600),
                                      ),
                                    ),
                                    if (p.locked) ...[
                                      const SizedBox(width: 6),
                                      _PresetTag(label: 'DEFAULT'),
                                    ],
                                  ],
                                ),
                                // Respect the locked preset: never render its
                                // prompt text. Others get a one-line preview.
                                subtitle: Text(
                                  p.locked
                                      ? 'Built-in preset · tuned for creative roleplay'
                                      : _presetPreviewLine(p),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                      color: EmberColors.textMid,
                                      fontSize: 12),
                                ),
                                onTap: () {
                                  liveStore.setActivePreset(p.id);
                                  final name =
                                      liveStore.activePreset?.name ?? p.name;
                                  Navigator.pop(sheet);
                                  messenger.showSnackBar(
                                    SnackBar(
                                        content: Text('Switched to $name')),
                                  );
                                },
                              ),
                          ],
                        ),
                      ),
                      // OPTIONAL quick main-prompt tweak — only when the active
                      // preset is UNLOCKED *and FLAT* (H-8). For a MODULAR
                      // preset, `mainPrompt` is ignored by `assemblePreset`
                      // (it builds from blocks), so the quick-edit would be a
                      // silent no-op — gate it on the predicate and show a
                      // short note pointing to the Presets screen instead.
                      if (active != null &&
                          !active.locked &&
                          presetSupportsMainPromptQuickEdit(active)) ...[
                        Divider(color: EmberColors.stroke, height: 8),
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.edit_note,
                              color: EmberColors.textMid),
                          title: Text(
                            'Quick edit system prompt',
                            style: TextStyle(
                                fontSize: 13,
                                color: EmberColors.textHigh,
                                fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            'Edit "${active.name}" main prompt',
                            style: TextStyle(
                                color: EmberColors.textMid, fontSize: 11),
                          ),
                          trailing: Icon(
                            quickEditOpen
                                ? Icons.expand_less
                                : Icons.expand_more,
                            color: EmberColors.textMid,
                          ),
                          onTap: () {
                            setSheetState(() {
                              quickEditOpen = !quickEditOpen;
                              if (quickEditOpen) {
                                quickEditCtl.text = active.mainPrompt;
                              }
                            });
                          },
                        ),
                        if (quickEditOpen)
                          Padding(
                            padding: const EdgeInsets.fromLTRB(20, 0, 20, 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                TextField(
                                  controller: quickEditCtl,
                                  maxLines: 8,
                                  minLines: 4,
                                  style: const TextStyle(fontSize: 13),
                                  decoration: const InputDecoration(
                                    isDense: true,
                                    hintText: 'Main prompt sent before the '
                                        'chat history.',
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Align(
                                  alignment: Alignment.centerRight,
                                  child: ElevatedButton.icon(
                                    icon: const Icon(Icons.save_outlined,
                                        size: 16),
                                    label: const Text('Save'),
                                    onPressed: () {
                                      // Re-resolve the live preset by id in
                                      // case it changed while the field was
                                      // open; bail if it vanished or locked.
                                      final target = liveStore.activePreset;
                                      if (target == null || target.locked) {
                                        Navigator.pop(sheet);
                                        return;
                                      }
                                      target.mainPrompt =
                                          quickEditCtl.text.trim();
                                      liveStore.updatePreset(target);
                                      Navigator.pop(sheet);
                                      messenger.showSnackBar(
                                        SnackBar(
                                          content: Text(
                                              'Saved "${target.name}".'),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ] else if (active != null &&
                          !active.locked &&
                          !presetSupportsMainPromptQuickEdit(active)) ...[
                        // MODULAR preset: the in-chat main-prompt quick-edit
                        // would be ignored by assembly, so we don't offer it.
                        // Point the user at the Presets screen, where the
                        // block editor actually drives a modular preset.
                        Divider(color: EmberColors.stroke, height: 8),
                        ListTile(
                          dense: true,
                          leading: Icon(Icons.view_module_outlined,
                              color: EmberColors.textMid),
                          title: Text(
                            'Modular preset',
                            style: TextStyle(
                                fontSize: 13,
                                color: EmberColors.textHigh,
                                fontWeight: FontWeight.w500),
                          ),
                          subtitle: Text(
                            'Built from prompt blocks — edit it in the '
                            'Presets screen below.',
                            style: TextStyle(
                                color: EmberColors.textMid, fontSize: 11),
                          ),
                        ),
                      ],
                      Divider(color: EmberColors.stroke, height: 8),
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
                        child: OutlinedButton.icon(
                          icon: const Icon(Icons.tune, size: 16),
                          label: const Text('Manage presets'),
                          onPressed: () {
                            Navigator.pop(sheet);
                            navigator.push(MaterialPageRoute(
                              builder: (_) => const PresetsScreen(),
                            ));
                          },
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        );
      },
    );
    quickEditCtl.dispose();
  }

  /// One-line flattened preview of a preset's main prompt for the switcher.
  /// NEVER called for a locked preset (its prompt stays sealed) — the caller
  /// gates on `p.locked` first.
  String _presetPreviewLine(Preset p) {
    final src = p.mainPrompt.trim();
    if (src.isEmpty) return '(no system prompt)';
    final flat = src.replaceAll(RegExp(r'\s+'), ' ');
    if (p.source == 'sillytavern') return 'ST preset · $flat';
    return flat;
  }

  /// Wave CX: per-chat persona resolver. Each Chat snapshots its
  /// `personaId` at creation (via startChatWith). At runtime we honour
  /// that ID rather than the global activePersonaId, so changing the
  /// default persona elsewhere doesn't retroactively rewrite who the
  /// user is in every prior chat. Legacy chats with null personaId
  /// fall back to the global active persona (old behaviour preserved).
  ///
  /// Wave CY.17: respects the [kExplicitNoPersonaId] sentinel — when
  /// the user explicitly picks "No persona" in the new-chat picker
  /// (or the switch-persona picker), we store that sentinel instead of
  /// `null` so the fall-through to the global default doesn't sneak
  /// the default persona back into a chat the user wanted clean.
  Persona? _chatPersona(AppStore store, Chat chat) {
    final pid = chat.personaId;
    if (pid == kExplicitNoPersonaId) return null;
    if (pid != null) {
      for (final p in store.personas) {
        if (p.id == pid) return p;
      }
      // pid points at a deleted persona — fall through to the global
      // active so the user has SOMEONE to play as.
    }
    return store.activePersona;
  }

  Future<void> _send() async {
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    final text = _inputCtl.text.trim();
    if (_generating) return;
    // Sub-task B: haptic on send (mobile only).
    if (_isMobileForHaptics) HapticFeedback.lightImpact();
    // Audit C1: a new send supersedes any pending fallback card from a
    // previous turn. _send re-inits the chain just before it streams.
    _clearPendingFallback();

    // Slash command interception — handled locally, no LLM round-trip.
    // Only runs when the user actually typed something; an empty send is
    // a "let the character take another turn" gesture, not a command.
    if (text.isNotEmpty && _handleSlashCommand(text, store, chat)) {
      _inputCtl.clear();
      return;
    }

    _inputCtl.clear();

    // Guide (Part 2 — "Guide the reply"): consume the armed one-shot guide for
    // THIS send only. Move it into `_inFlightGuide` (read by every
    // `_runGenerationInto` for this turn, incl. smart-fallback retries of the
    // same slot) and clear the armed slot immediately so it never carries over
    // to a later Send. A plain send with nothing armed sets `_inFlightGuide`
    // to null, so a stale guide can never leak across distinct sends. The
    // guide is ephemeral — it is NOT appended to `chat.messages` here; it only
    // becomes an in-prompt system note via `_buildTurns`→`buildChatPrompt`.
    _inFlightGuide = _armedGuide;
    if (_armedGuide != null) {
      setState(() => _armedGuide = null);
    }

    // Wave CY.5: empty send is intentional — it means "scene continues
    // without me". Skip appending a user message and let the responder
    // take another turn off the existing context. Useful when an NPC
    // monologue is unfolding, or the user is watching a scenario play
    // out before stepping back in. We DON'T fall through this path with
    // text added: a non-empty input still pushes a user turn first.
    if (text.isNotEmpty) {
      // If the last message is an EMPTY user message (a freshly-branched
      // variant waiting for content), fill it in place instead of
      // appending a new one. That's the back end of the `+`-on-user-
      // message UX.
      final last =
          chat.messages.isNotEmpty ? chat.messages.last : null;
      if (last != null &&
          last.kind == MessageKind.user &&
          last.text.trim().isEmpty) {
        store.updateMessageText(chat.id, last.id, text);
      } else {
        store.addMessage(
          chat.id,
          Message(
            id: newId('msg'),
            kind: MessageKind.user,
            variants: [text],
          ),
        );
      }
    }

    // Start a fresh assistant turn for the just-appended user message.
    await _startFreshAssistantTurn(store, chat);
  }

  /// Wave CY.18.154: open a fresh assistant turn at the chat tip and run the
  /// first fallback candidate. Extracted verbatim from `_send` so the Retry
  /// path (`_retryGeneration`) can reuse it. The caller must already have
  /// appended whatever user / scene / OOC turn this reply responds to.
  Future<void> _startFreshAssistantTurn(AppStore store, Chat chat) async {
    // Start assistant turn (empty, will stream into it)
    final assistantId = newId('msg');
    _streamMessageId = assistantId;
    _streamVariantIndex = 0; // fresh message has one variant at index 0
    // Party mode (2026-07): a group chat with the flag on voices the WHOLE
    // party in one scene message — there is no single responder to pin, so
    // the message carries `characterId: null` (see _MessageBubble's
    // `showSpeakerName`/avatar handling, which only skips the single-author
    // affordance when `chat.partyMode` is also true — a party-mode-off
    // group message with a null characterId, a pre-existing edge case,
    // keeps falling back to the primary character exactly as before).
    final isPartyTurn = chat.partyMode && chat.characterIds.length > 1;
    // Pick the responder — explicit override, else primary. Unused for a
    // party turn (kept so _activeResponderId's fallback bookkeeping doesn't
    // change), but the message itself pins no single author.
    final responderId = _activeResponderId(chat);
    final character = responderId == null
        ? null
        : (chat.characterSnapshots[responderId] ??
            store.characterById(responderId));
    store.addMessage(
      chat.id,
      Message(
        id: assistantId,
        kind: MessageKind.char,
        characterId: isPartyTurn ? null : character?.id,
        variants: [''],
      ),
    );
    setState(() {
      _generating = true;
      _streamBuffer = '';
    });
    _scrollToBottom();

    // Wave CY.18.99: build the fallback chain from the top and run the first
    // candidate. Streaming + outcome handling lives in _runGenerationInto so
    // the fallback-retry path reuses it verbatim.
    _fallbackIndex = 0;
    _fallbackChain = store.chatFallbackChain();
    await _runGenerationInto(assistantId);
  }

  /// Wave CY.18.154: the snackbar "Retry" action after a generation error.
  /// Pre-fix this called `_regenerateLast()` unconditionally, which BAILED in
  /// the common case: on an error with an empty buffer, `_finishWithError`
  /// removes the placeholder, so the chat tip is the USER turn and
  /// `_regenerateLast` (CHAR-tip only) did nothing — Retry was a dead button
  /// after the single most visible failure. Now:
  ///  - CHAR tip (error left a partial reply) → regenerate it as a variant;
  ///  - USER / scene / OOC tip → open a fresh assistant turn for it.
  Future<void> _retryGeneration() async {
    if (_generating) return;
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null || chat.messages.isEmpty) return;
    final last = chat.messages.last;
    if (last.kind == MessageKind.char) {
      return _regenerateMessage(chat, last);
    }
    _clearPendingFallback();
    await _startFreshAssistantTurn(store, chat);
  }

  /// Wave CY.18.99: open a stream into [assistantId] using the provider
  /// at the current `_fallbackIndex` of `_fallbackChain`. Shared by the
  /// initial send and every fallback retry. `_buildTurns` already skips
  /// `_streamMessageId`, so the failed/refused content in the slot is
  /// never fed back as context.
  Future<void> _runGenerationInto(String assistantId) async {
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;

    final provider = (_fallbackChain.isNotEmpty &&
            _fallbackIndex >= 0 &&
            _fallbackIndex < _fallbackChain.length)
        ? _fallbackChain[_fallbackIndex]
        : store.activeProvider;
    if (provider == null) {
      _finishWithError(
          'No provider configured. Open "More → API Connections".');
      return;
    }

    _streamMessageId = assistantId;
    final pinnedVariant = _streamVariantIndex;
    // Thread the in-flight one-shot guide (if any). It survives a smart-
    // fallback retry of the SAME turn (we keep `_inFlightGuide` set across
    // retries) and is cleared once the turn settles in `_finishGeneration`-
    // style cleanup below.
    //
    // Slice D-3: `_contextTrimWindow` is null on the first attempt against
    // THIS provider (so `_buildTurns`'s own pre-trim read against the
    // learned-limit cache decides), and is the exact shrunk window on a
    // context-recovery retry (set below, just before we recurse).
    final turns = _buildTurns(
      store,
      chat,
      guide: _inFlightGuide,
      maxHistoryMessages: _contextTrimWindow,
      provider: provider,
    );
    // Wave BM: foreground-service keep-alive so the OS doesn't kill
    // Pyre while the LLM streams (especially the slow first-token wait
    // on reasoning models). Matching stop() in onDone / failure paths.
    await _keepAliveStart();
    try {
      // Audit C2: cancel any prior subscription before re-arming. The
      // fallback retry path can reach here while an earlier stream for
      // this screen is technically still open (e.g. the user abandoned
      // a slow stream via the card); without this the old subscription
      // leaks and races the new one, writing into a stale slot. Awaiting
      // the cancel is what closes that race, so it stays synchronous here.
      //
      // Slice D-3 note: the context-recovery retry ALSO re-enters this
      // method — but from inside the OLD subscription's own `onError`
      // dispatch, and `await`-ing that subscription's `cancel()` from
      // inside its own callback hangs (observed as a real hang in the
      // recovery widget test). That case is handled AT THE SOURCE instead:
      // `_tryContextRecoveryOrFail` drops `_streamSub` (the erroring,
      // already-terminal handle) BEFORE it recurses, so on a recovery retry
      // `_streamSub` is null by the time we reach here and this `cancel()`
      // is a no-op — leaving the normal abandoned-stream path's protective
      // synchronous cancel completely untouched.
      await _streamSub?.cancel();
      _streamSub = null;
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: turns,
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
        // Party mode: one generation voices the whole party in a scene, so
        // the single-character max_tokens ceiling scales with member count.
        partyMemberCount: (chat.partyMode && chat.characterIds.length > 1)
            ? chat.characterIds.length
            : 1,
      ).listen(
        (chunk) {
          if (!mounted) return;
          _streamBuffer += chunk;
          // Pin to the variant we started streaming into — if the user
          // taps a variant arrow mid-stream, selectedVariant changes
          // but we keep writing to the original target. Strip Pyre's
          // stream sentinels (finish-reason / dropped-frame) before
          // persisting so they never land in the stored variant or
          // render literally; <think> stays in the buffer (ChatText
          // hides it for display + the per-message reasoning toggle).
          store.updateMessageText(
            chat.id,
            assistantId,
            _stripChatSentinels(_streamBuffer),
            variantIndex: pinnedVariant,
            streamingNotifier: _streamingNotifier(),
          );
          _scrollToBottom();
        },
        // Wave CY.18.99: infra failures route to the fallback handler
        // (offers a switch when a candidate remains + toggle on),
        // falling through to the old snackbar otherwise. Slice D-3 sits IN
        // FRONT of that: a real context-overflow 4xx is trimmed-and-retried
        // on THIS provider first (the user's chosen provider before any
        // switch), and only falls through to `_handleGenerationFailure` once
        // the recovery attempt cap or the window floor is hit.
        onError: (e) => _tryContextRecoveryOrFail(
          chat: chat,
          assistantId: assistantId,
          error: e,
          turnsSent: turns,
          provider: provider,
        ),
        onDone: () {
          _keepAliveStop();
          if (!mounted) return;
          // Fix 1: the turn is settling — flush the last coalesced chunk to
          // the notifier and drop it BEFORE the final `notifyListeners()`
          // below (via `flushPersist`), so the bubble's very last frame is
          // painted through the isolated path and every subsequent rebuild
          // goes back to reading `message.text` directly (no dangling
          // ValueListenableBuilder on a disposed notifier).
          _settleStreamingNotifier();
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          // Final state is worth a disk write right now (rather than
          // waiting on the debounce) so the just-streamed message
          // survives a crash or app kill.
          context.read<AppStore>().flushPersist();
          // Wave CY.18.99: classify the reply — empty/refusal may offer
          // a fallback card. When it doesn't, auto-summarize as before.
          _maybeOfferFallbackAfterDone(chat.id, assistantId);
        },
      );
    } catch (e) {
      _keepAliveStop();
      _tryContextRecoveryOrFail(
        chat: chat,
        assistantId: assistantId,
        error: e,
        turnsSent: turns,
        provider: provider,
      );
    }
  }

  /// Slice D-3 (2026-07-02): the bounded context-recovery gate. Runs BEFORE
  /// `_handleGenerationFailure` on every stream error. Fires the trim+retry
  /// ONLY when ALL of these hold — otherwise falls straight through to the
  /// existing, unchanged failure path:
  ///   - [error] is a `ChatApiError` with a 4xx `statusCode` (never 5xx —
  ///     a server-side fault is not a length problem);
  ///   - `isContextOverflowError(error.message)` — a REAL overflow
  ///     phrasing, never a param-shape or auth/rate-limit rejection
  ///     (disjoint by construction — see param_policy.dart);
  ///   - the attempt count is still under [kMaxContextTrims];
  ///   - the window can still shrink (hasn't already hit
  ///     [contextTrimFloor]) — the SECOND, independent stop condition.
  /// Both stops are checked so the loop provably terminates: the attempt
  /// counter is a hard ceiling regardless of window arithmetic, and the
  /// floor check means even a pathological `nextSmallerWindow` result can
  /// never spin — the moment the window stops shrinking, this recognizes it
  /// (`candidate >= currentWindowLen`) and falls through.
  void _tryContextRecoveryOrFail({
    required Chat chat,
    required String assistantId,
    required Object error,
    required List<ChatTurn> turnsSent,
    required ApiProvider provider,
  }) {
    if (error is ChatApiError) {
      final status = error.statusCode;
      final isOverflow4xx = status != null &&
          status >= 400 &&
          status < 500 &&
          isContextOverflowError(error.message);
      if (isOverflow4xx && _contextTrimAttempts < kMaxContextTrims) {
        final store = context.read<AppStore>();
        // Ground truth from the provider when it printed a number;
        // otherwise fall back to this attempt's own estimated size minus a
        // safety margin so we still learn SOMETHING conservative from a
        // silent-number overflow.
        final parsed = contextLimitFromError(error.message).maxTokens;
        final estimatedThisAttempt =
            turnsSent.fold<int>(0, (n, t) => n + approxTokens(t.content));
        const safetyMargin = 256;
        final fallbackLimit =
            (estimatedThisAttempt - safetyMargin).clamp(1, 1 << 30);
        store.recordContextLimit(
          provider.id,
          provider.model,
          parsed ?? fallbackLimit,
        );

        // The CURRENT window size actually sent — either the explicit trim
        // window from a prior retry, or (first attempt) the full post-recap
        // window length.
        final windowStart =
            ltm.firstUncoveredIndex(chat).clamp(0, chat.messages.length);
        final fullWindowLen = chat.messages.length - windowStart;
        final currentWindowLen = _contextTrimWindow ?? fullWindowLen;
        final floor = contextTrimFloor(currentWindowLen);

        if (currentWindowLen > floor) {
          final nextWindow = nextSmallerWindow(
            currentWindowLen,
            learnedLimitTokens: parsed ?? fallbackLimit,
            estimatedPromptTokens: estimatedThisAttempt,
            estimatedTokensPerMessage: currentWindowLen > 0
                ? estimatedThisAttempt / currentWindowLen
                : null,
          );
          if (nextWindow < currentWindowLen) {
            _contextTrimWindow = nextWindow;
            _contextTrimAttempts++;
            // Drop the erroring subscription handle BEFORE recursing. In the
            // streaming case we are inside this very subscription's `onError`
            // dispatch; the stream already delivered a terminal error so it
            // can emit nothing more. Nulling `_streamSub` now means the
            // re-entrant `_runGenerationInto` sees no prior subscription to
            // `await cancel()` on — which would hang from inside the callback
            // — while the normal abandoned-stream path keeps its synchronous
            // cancel. Fire-and-forget the actual cancel for tidiness.
            final erroring = _streamSub;
            _streamSub = null;
            unawaited(erroring?.cancel());
            // Overflow 4xx bodies are returned BEFORE any SSE chunk is ever
            // emitted (the provider rejects the request outright), so the
            // buffer is empty here in practice — reset defensively anyway so
            // a retry into the same assistant slot can never concatenate
            // stray partial text from a pathological provider.
            _streamBuffer = '';
            unawaited(_runGenerationInto(assistantId));
            return;
          }
        }
        // Window can't shrink further — fall through to the existing
        // failure path (the window-floor stop condition).
      }
    }
    _handleGenerationFailure(
      chatId: chat.id,
      assistantId: assistantId,
      error: error,
    );
  }

  /// Wave CY.18.99: infra-failure path. If another candidate remains and
  /// the toggle is on, show the infra fallback card instead of the plain
  /// error. Otherwise fall through to the existing snackbar+Retry UX.
  void _handleGenerationFailure({
    required String chatId,
    required String assistantId,
    required Object error,
  }) {
    _keepAliveStop();
    if (!mounted) return;
    final store = context.read<AppStore>();
    final hasNext = _fallbackIndex + 1 < _fallbackChain.length;
    final isApiError = error is ChatApiError;
    if (hasNext && isApiError && store.uiPrefs.askToSwitchOnFailure) {
      // Fix 1: this turn's stream is done (either settling into the
      // fallback card, which is a NEW UI branch, not a notifier reader, or
      // about to fall through to `_finishWithError` below) — drop the
      // notifier here so a subsequent `_retryWithNextCandidate` creates a
      // fresh one for its own attempt instead of inheriting a stale value.
      _settleStreamingNotifier();
      setState(() {
        _generating = false;
        _streamMessageId = null;
        _pendingFallback = _PendingFallback(
          reason: FallbackReason.infra,
          assistantId: assistantId,
          failed: _fallbackChain[_fallbackIndex],
          next: _fallbackChain[_fallbackIndex + 1],
        );
      });
      return;
    }
    _finishWithError(error.toString(), originalError: error);
  }

  /// Wave CY.18.99: after a clean stream finish, classify the reply.
  /// Empty or likely-refusal + another candidate + toggle on → show the
  /// card. Anything else → resume the normal post-done bookkeeping
  /// (auto-summarize).
  /// Fire-and-forget the post-turn background memory pipeline: auto-summarise →
  /// Live Sheet → scene background, serialised so the three LLM calls never
  /// overlap on one provider. Every stage is fully self-guarded (shouldSummarize
  /// / per-feature latches / mounted), so this is safe + idempotent to call from
  /// EVERY assistant-turn completion path.
  ///
  /// LTM fix 2026-06-04: this chain previously lived ONLY inside the fresh-send
  /// onDone AND only in the `!eligible` branch — so chats whose replies tripped
  /// the smart-fallback refusal classifier never checkpointed (the "auto-memory
  /// fires in some chats, never in others" instability).
  ///
  /// Mega-audit 2026-06-04 (chat-core-1-02): it is now ALSO invoked from every
  /// other assistant-turn completion path — Continue (`_continueLast`),
  /// Regenerate / Regenerate-with-guide (`_regenerateMessage`), Fill-In
  /// (`_streamFillInVariant`), Impersonate (`_runImpersonation`), and a kept
  /// partial reply in `_stop`. Each stage is fully self-guarded
  /// (shouldSummarize counts only NEW char messages past the anchor, per-feature
  /// latches, mounted), so firing it from a path that produced no new turn
  /// (e.g. a Continue that only extended an existing message, or an Impersonate
  /// that only wrote to the input box) is a cheap idempotent no-op. The win is
  /// the per-turn scene-background classifier, which now refreshes on those
  /// paths too instead of lagging until the next fresh send.
  void _runAutoMemoryChain() {
    _maybeAutoSummarize()
        .then((_) => _maybeAutoLiveSheetUpdate())
        .then((_) => _maybeUpdateSceneBackground());
  }

  void _maybeOfferFallbackAfterDone(String chatId, String assistantId) {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final hasNext = _fallbackIndex + 1 < _fallbackChain.length;
    // Classify the STRIPPED reply, not the raw buffer. A reasoning-only
    // turn (buffer == `<think>…</think><<__PYRE_FINISH__:stop__>>`) is
    // visibly empty to the user, but the raw buffer is non-empty and was
    // misclassified `ok`, so the empty/refusal fallback never offered a
    // switch. stripStreamArtifacts removes <think> + both sentinels so an
    // empty/refusal reply is detected correctly.
    final verdict = classifyResponse(stripStreamArtifacts(_streamBuffer));
    final eligible = store.uiPrefs.askToSwitchOnFailure &&
        hasNext &&
        verdict != ResponseVerdict.ok;
    // LTM fix 2026-06-04 — DECOUPLED from the smart-fallback decision: the
    // auto-memory chain runs after EVERY clean finish now, NOT only when the
    // fallback path declined the turn. It used to live inside `if (!eligible)`,
    // so in any chat whose replies the refusal classifier judged non-ok (short
    // / unusual markup — varies by character + provider) the summariser was
    // silently skipped turn after turn while other chats checkpointed fine →
    // "auto-memory works in some chats, never in others". The fallback card
    // (below) is now an independent, additional offer.
    unawaited(LlmDebugLog.instance
        .trace('ltm.auto: dispatching (fallbackEligible=$eligible)'));
    _runAutoMemoryChain();
    if (!eligible) return;
    final failed = _fallbackChain[_fallbackIndex];
    final next = _fallbackChain[_fallbackIndex + 1];
    ApiProvider? clean;
    if (verdict == ResponseVerdict.likelyRefusal) {
      // Audit C4: count this provider's refusal at most once per
      // assistant slot, so retrying the same turn doesn't inflate the
      // self-learning signal. Key by provider+slot.
      final refusalKey = '${failed.id}@$assistantId';
      if (!_refusalCountedKeys.contains(refusalKey)) {
        _refusalCountedKeys.add(refusalKey);
        store.bumpRefusal(failed.id);
      }
      // Only suggest a clean alternative if `next` itself has a record.
      // Audit C3: search only the FORWARD tail (after the current index)
      // so the suggestion can never jump back to an already-tried
      // provider.
      if ((store.providerRefusals[next.id] ?? 0) > 0) {
        clean = store.cleanestChatAlternative(
            nextId: next.id, afterIndex: _fallbackIndex);
      }
    }
    setState(() {
      _pendingFallback = _PendingFallback(
        // Empty replies reuse the infra copy ("didn't respond") — it is,
        // functionally, no usable reply.
        reason: verdict == ResponseVerdict.likelyRefusal
            ? FallbackReason.refusal
            : FallbackReason.infra,
        assistantId: assistantId,
        failed: failed,
        next: next,
        clean: clean,
      );
    });
  }

  /// Wave CY.18.99: advance the chain and re-run the generation into the
  /// SAME assistant slot. Clean-alternative jumps the index to that
  /// provider; otherwise steps to the next candidate.
  void _retryWithNextCandidate({required bool useClean}) {
    final pf = _pendingFallback;
    if (pf == null) return;
    int targetIndex;
    if (useClean && pf.clean != null) {
      targetIndex = _fallbackChain.indexWhere((p) => p.id == pf.clean!.id);
      if (targetIndex < 0) targetIndex = _fallbackIndex + 1;
    } else {
      targetIndex = _fallbackIndex + 1;
    }
    final store = context.read<AppStore>();
    final chat = _chat(store);
    setState(() {
      _pendingFallback = null;
      _fallbackIndex = targetIndex;
      _generating = true;
      _streamBuffer = '';
      _streamMessageId = pf.assistantId;
    });
    // Slice D-3 (2026-07-02, review-caught): switching to a DIFFERENT provider
    // must start the context-recovery loop fresh. This is a generation entry
    // point exactly like _send/_retryGeneration/_stop/_regenerateMessage — but
    // it deliberately can't route through _clearPendingFallback (that clears
    // the fallback chain this method is walking), so it was the one entry point
    // that never reset the trim state. Without this, the NEW provider inherits
    // the OLD provider's shrunk `_contextTrimWindow` (a window sized for a
    // different, possibly much smaller, real context limit → the new provider
    // gets a needlessly-truncated history) plus a depleted attempt budget.
    _contextTrimWindow = null;
    _contextTrimAttempts = 0;
    // Clear the failed/refused content from the slot so it isn't shown
    // during the new stream (buildTurns already skips _streamMessageId).
    if (chat != null) {
      store.updateMessageText(chat.id, pf.assistantId, '',
          variantIndex: _streamVariantIndex);
    }
    _runGenerationInto(pf.assistantId);
  }

  /// Wave CY.18.99: build the inline fallback card for [pf]. Rendered in
  /// the message list below the matching assistant bubble.
  Widget _buildFallbackCard(_PendingFallback pf) {
    return FallbackPromptCard(
      reason: pf.reason,
      failedName: pf.failed.name,
      nextName: pf.next.name,
      cleanName: pf.clean?.name,
      onTryNext: () => _retryWithNextCandidate(useClean: false),
      onTryClean:
          pf.clean == null ? null : () => _retryWithNextCandidate(useClean: true),
      onKeep: () => setState(() => _pendingFallback = null),
    );
  }

  /// Wave CY.18.99 (audit C1): dismiss any showing fallback card and
  /// reset the chain walk. Called at the top of EVERY other generation /
  /// edit entry point — otherwise a stale card (and its now-meaningless
  /// `_fallbackIndex` / `assistantId`) survives into an unrelated turn
  /// and a later "Try X" tap would stream into the wrong slot. Safe to
  /// call when nothing is pending (no-op).
  void _clearPendingFallback() {
    // Slice D-3: a fresh generation entry point always starts this turn's
    // context-recovery loop over (mirrors the fallback-chain reset below —
    // a NEW turn must never inherit a shrunk window or attempt count from
    // an unrelated previous turn).
    _contextTrimWindow = null;
    _contextTrimAttempts = 0;
    if (_pendingFallback == null && _fallbackChain.isEmpty) return;
    _fallbackChain = const [];
    _fallbackIndex = 0;
    if (_pendingFallback != null) {
      setState(() => _pendingFallback = null);
    }
  }

  /// Fire-and-forget — if the chat has accumulated enough messages past the
  /// last valid checkpoint anchor for the current branch, ask the LLM
  /// for a fresh checkpoint and append it to the chain.
  Future<void> _maybeAutoSummarize() async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    // SILENT export-only breadcrumb at entry: mounted / memoryEnabled / latch.
    // These are the first three gates and any one of them can silently abort
    // a 2nd+ checkpoint.
    unawaited(LlmDebugLog.instance.trace(
        'ltm.auto: entry mounted=$mounted memoryEnabled=${chat.memoryEnabled} '
        'summarising=$_summarising'));
    // Wave CY.16: per-chat opt-out via the Memory menu. Manual
    // summarisation still works even when this is false (the
    // MemoryScreen "Summarise now" button bypasses the toggle) —
    // auto-trigger just respects it.
    if (!chat.memoryEnabled) return;
    // Compute the decision WITH ITS NUMBERS for the breadcrumb. This is the
    // diagnostic companion to shouldSummarize — same boolean verdict, plus the
    // intermediates — so we trace exactly why it did/didn't fire.
    final decision =
        ltm.summarizeDecision(chat, memorySettings: store.memorySettings);
    unawaited(LlmDebugLog.instance.trace(
        'ltm.auto: shouldSummarize=${decision.shouldSummarize} '
        'lastAnchor=${decision.lastAnchor} '
        'newCharMsgs=${decision.newCharMsgs}/${decision.threshold} '
        'validCkpts=${decision.validCount} totalMsgs=${decision.totalMessages}'));
    if (!decision.shouldSummarize) {
      return;
    }
    // Wave CY.18.6: prevent two summarisers running at once. The
    // summary call is long-running (often 10-30s); if the user sends
    // another message while it's in flight, the next onDone would
    // fire-and-forget a second summarise. Two parallel LLM calls to
    // the same provider can hit rate limits or, on proxies that
    // serialise requests per session, silently drop one — leaving
    // the user with a phantom "Generating…" on the chat reply.
    if (_summarising) {
      // SILENT breadcrumb: prime suspect — a stuck latch blocks every 2nd+
      // checkpoint while shouldSummarize keeps reporting true.
      unawaited(
          LlmDebugLog.instance.trace('ltm.auto: skipped (latch busy)'));
      return;
    }
    final provider = store.activeProvider;
    if (provider == null) return;
    _summarising = true;
    try {
      final ckpt = await ltm.generateCheckpoint(
        chat: chat,
        provider: provider,
        settings: store.modelSettings,
        memorySettings: store.memorySettings,
      );
      if (ckpt == null) {
        // SILENT breadcrumb: the checkpoint did not materialise. The reason
        // (if any) sits in MemoryErrors; surface it greppably in the export.
        unawaited(LlmDebugLog.instance.trace(
            'ltm.auto: generateCheckpoint returned null (reason='
            '${ltm.MemoryErrors.log.isNotEmpty ? ltm.MemoryErrors.log.first : 'none'})'));
        // Wave CY.18.160: don't fail silently. generateCheckpoint returns
        // null when the LLM reply was empty / errored / offline — it
        // records the reason in MemoryErrors but, until now, the user got
        // ZERO feedback ("nothing fires at #25"). Surface the FIRST failure
        // per session as a transient SnackBar so the user knows it tried
        // and can act (switch provider, check Memory). Suppressed after the
        // first so a down provider doesn't snackbar-spam every message.
        //
        // C1 (service-level lock): when generateCheckpoint returned null
        // because a MANUAL checkpoint (from MemoryScreen) is already in
        // flight, the lock is still held and MemoryErrors has NO new entry
        // for this call — so the failure toast would be misleading. Skip it;
        // the manual path's own UI already covers the user-facing feedback.
        if (!_autoSummariseFailureShown &&
            mounted &&
            !ltm.isCheckpointInFlight(chat.id)) {
          _autoSummariseFailureShown = true;
          final reason = ltm.MemoryErrors.log.isNotEmpty
              // Drop the internal "generateCheckpoint failed: " op prefix so
              // the snackbar doesn't read "checkpoint failed — … failed: …".
              ? ltm.MemoryErrors.log.first
                  .replaceFirst(RegExp(r'^generateCheckpoint failed: '), '')
              : 'the model returned no usable text';
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Memory checkpoint failed — $reason. '
                'Auto-summary will keep retrying as you chat.',
                style: const TextStyle(fontSize: 13),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              backgroundColor: const Color(0xFF3a1d1d),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
            ),
          );
        }
        return;
      }
      // SILENT breadcrumb: a checkpoint was produced and is about to be
      // appended at this anchor.
      unawaited(LlmDebugLog.instance.trace(
          'ltm.auto: checkpoint CREATED (anchor=${ckpt.anchorMessageIdx})'));
      // A success clears the "shown" latch so a genuine LATER failure (e.g.
      // the provider goes down after working) surfaces again.
      _autoSummariseFailureShown = false;
      ltm.applyCheckpoint(chat, ckpt);
      store.touchChat(chat); // F1: bump mtime so the checkpoint syncs
    } finally {
      _summarising = false;
    }
  }

  /// Wave CY.18.173: Fire-and-forget — if the Live Sheet is enabled and
  /// enough assistant turns have elapsed since the last snapshot, ask the
  /// LLM for a new state snapshot and append it to the chat's snapshot list.
  /// Serialised AFTER _maybeAutoSummarize via .then() at the call site so the
  /// two LLM calls never overlap on the same provider.
  Future<void> _maybeAutoLiveSheetUpdate() async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    if (!chat.liveSheetEnabled) return;
    if (!lsheet.shouldUpdateLiveSheet(chat, store.liveSheetSettings)) return;
    if (_liveSheetUpdating) return;
    final provider = store.activeProvider;
    if (provider == null) return;
    _liveSheetUpdating = true;
    try {
      final snap = await lsheet.generateLiveSheetUpdate(
        chat: chat,
        provider: provider,
        settings: store.modelSettings,
        liveSheetSettings: store.liveSheetSettings,
      );
      if (snap == null) {
        // null = NO_CHANGE (normal) OR an error. Only surface a SnackBar when the
        // error log actually has an entry this session, once, to avoid spamming
        // on normal no-change cycles. (Mirrors the Wave 160 memory SnackBar.)
        //
        // LS-2 (service-level lock): when generateLiveSheetUpdate returned null
        // because a MANUAL update/seed (from LiveSheetScreen) is already in
        // flight for this chat, the lock is still held and LiveSheetErrors has
        // NO new entry for this call — so the failure toast would be
        // misleading. Skip it; the manual path's own UI already covers the
        // user-facing feedback (mirrors the memory.dart C1 skip above).
        if (!_liveSheetFailureShown &&
            mounted &&
            !lsheet.isLiveSheetInFlight(chat.id) &&
            lsheet.LiveSheetErrors.log.isNotEmpty) {
          _liveSheetFailureShown = true;
          final reason = lsheet.LiveSheetErrors.log.first
              .replaceFirst(RegExp(r'^generateLiveSheetUpdate failed: '), '');
          ScaffoldMessenger.of(context).showSnackBar(SnackBar(
            content: Text(
              'Live Sheet update failed — $reason. It will keep retrying as you chat.',
              style: const TextStyle(fontSize: 13),
              maxLines: 4,
              overflow: TextOverflow.ellipsis,
            ),
            backgroundColor: const Color(0xFF3a1d1d),
            behavior: SnackBarBehavior.floating,
            duration: const Duration(seconds: 6),
          ));
        }
        return;
      }
      _liveSheetFailureShown = false;
      lsheet.appendLiveSheetSnapshot(chat, snap);
      store.touchChat(chat); // F1: bump mtime so the snapshot syncs
    } finally {
      _liveSheetUpdating = false;
    }
  }

  /// Wave CY.18.184: fire-and-forget — when the chat uses the dynamic
  /// background source, follow the scene. A free keyword pre-pass runs every
  /// turn; the LLM classifier runs only on a keyword miss, deduped by the
  /// recent-window key and throttled by [kSceneClassifyCooldown] char-turns.
  /// Any failure is a no-op (keep the current backdrop). [force] (the manual
  /// "Set background now" button) bypasses dedup + cooldown.
  Future<void> _maybeUpdateSceneBackground({bool force = false}) async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    final effectiveSource =
        chat.backgroundSource ?? store.chatSettings.backgroundSource;
    if (effectiveSource != ChatBackgroundSource.dynamic) return;

    final manifest = await scenebg.loadSceneManifest();
    if (manifest == null) return;
    if (!mounted) return;

    final recentText = _sceneRecentText(chat);
    if (recentText.trim().isEmpty) return;

    // 1. Free keyword pre-pass (every turn). Instant switch only on a CONFIDENT
    // hit (multi-word phrase or a high-priority distinctive place); a weak lone
    // generic word ("ravine", "cave") falls through to the LLM classifier.
    final kwSlug = scenebg.confidentKeywordPrePass(manifest, recentText);
    if (kwSlug != null) {
      final cat = manifest.categoryBySlug(kwSlug);
      if (cat != null) {
        // The world's aesthetic ('modern' default) is only meaningful once the
        // classifier has established it. Until then (still the default 'modern'
        // AND the classifier never ran — empty watermark key), DON'T trust it
        // for the image pick: a fantasy chat opening with "throne room"/"tavern"
        // would otherwise lock a MODERN-aesthetic image. Pass 'unknown' so
        // pickSceneImage prefers world-agnostic ('natural') candidates and only
        // falls back to modern when nothing else exists. Once the classifier has
        // run, the established sceneSetting is honoured normally.
        final effectiveSetting = (chat.sceneSetting == 'modern' &&
                chat.sceneLastClassifyKey.isEmpty)
            ? 'unknown'
            : chat.sceneSetting;
        final file = scenebg.pickSceneImage(
            cat, effectiveSetting, 'unknown',
            scenebg.weatherCueFromText(recentText), chat.id);
        var changed = false;
        if (file != null && file != chat.sceneBgFile) {
          chat.sceneBgFile = file;
          changed = true;
        }
        // Wave CY.18.197: keep the tracked location current on a keyword hit
        // (the pre-pass only yields a slug, so use the category's display name).
        if (chat.sceneLocation != cat.name) {
          chat.sceneLocation = cat.name;
          changed = true;
        }
        // Advance the cooldown watermark (the message COUNT, not the window
        // key) so the next keyword-MISS turn doesn't immediately pay for an LLM
        // call — the cooldown reflects "turns since we last touched the scene",
        // and a keyword hit IS touching the scene. Leave sceneLastClassifyKey
        // alone: that's the "classifier already ran on this window" dedup, and
        // the classifier did NOT run here.
        if (chat.sceneLastClassifyMsgCount != chat.messages.length) {
          chat.sceneLastClassifyMsgCount = chat.messages.length;
          changed = true;
        }
        if (changed) store.touchChat(chat); // F1: scene fields sync
      }
      if (!force) return; // keyword hit short-circuits the classifier this turn
    }

    // 2. Classifier path (keyword miss, or forced). Dedup + cooldown.
    final key = scenebg.sceneWindowKey(recentText);
    if (!force) {
      if (key == chat.sceneLastClassifyKey) return; // already classified this window
      if (chat.messages.length - chat.sceneLastClassifyMsgCount <
          kSceneClassifyCooldown) {
        return; // cooling down
      }
    }
    if (_sceneClassifying) return;
    final provider = store.activeProvider;
    if (provider == null) return;

    // Audit fix 3: service-level in-flight lock. The widget-local
    // _sceneClassifying bool above only guards THIS screen instance against
    // itself; it can't see the manual "Detect location" button in
    // customize_chat_sheet.dart running concurrently for the same chat. Skip
    // (rather than race) when another classify+apply pass already holds the
    // lock for this chat.
    if (!scenebg.acquireSceneClassifyLock(chat.id)) {
      debugPrint('[SceneBg] auto-classify skipped — already in flight for ${chat.id}');
      return;
    }

    _sceneClassifying = true;
    try {
      final verdict = await scenebg.classifyScene(
        manifest: manifest,
        recentText: recentText,
        provider: provider,
        settings: store.modelSettings,
        // Wave CY.18.197: anchor the classifier on the tracked scene so it only
        // moves the background on a real location change (anti-drift).
        currentLocation: chat.sceneLocation,
        currentSetting: chat.sceneSetting,
      );
      if (!mounted) return;
      // Always advance the watermarks so a failing provider doesn't re-hit
      // every turn (cooldown handles the retry cadence).
      chat.sceneLastClassifyKey = key;
      chat.sceneLastClassifyMsgCount = chat.messages.length;

      if (verdict == null) {
        // Surface the first failure once (mirrors the LiveSheet snackbar).
        if (!_sceneFailureShown && scenebg.SceneErrors.log.isNotEmpty) {
          _sceneFailureShown = true;
          final reason = scenebg.SceneErrors.log.first
              .replaceFirst(RegExp(r'^classifyScene failed: '), '');
          if (mounted) {
            ScaffoldMessenger.of(context).showSnackBar(SnackBar(
              content: Text(
                'Scene background couldn\'t update — $reason. It will keep trying as you chat.',
                style: const TextStyle(fontSize: 13),
                maxLines: 4,
                overflow: TextOverflow.ellipsis,
              ),
              backgroundColor: const Color(0xFF3a1d1d),
              behavior: SnackBarBehavior.floating,
              duration: const Duration(seconds: 6),
            ));
          }
        }
        store.touchChat(chat); // F1: persist+sync the advanced watermarks
        return;
      }
      _sceneFailureShown = false;

      // Sticky setting: only overwrite when the classifier is sure of one.
      if (verdict.setting != 'unknown') chat.sceneSetting = verdict.setting;

      final decision = scenebg.decideSwitch(verdict,
          hasCurrent: chat.sceneBgFile != null);
      String? targetSlug;
      switch (decision.kind) {
        case scenebg.SceneDecisionKind.keep:
          break;
        case scenebg.SceneDecisionKind.neutral:
          targetSlug = manifest.fallbackSlug;
          break;
        case scenebg.SceneDecisionKind.setLocation:
          targetSlug = decision.slug;
          break;
      }
      if (targetSlug != null) {
        final cat = manifest.categoryBySlug(targetSlug);
        if (cat != null) {
          final file = scenebg.pickSceneImage(
              cat, chat.sceneSetting, verdict.timeOfDay,
              scenebg.weatherCueFromText(recentText), chat.id);
          if (file != null) chat.sceneBgFile = file;
          // Wave CY.18.197: on a confident MOVE, update the tracked location
          // note (prefer the model's free-text phrase, fall back to the
          // category display name). Skip on the neutral establish-a-backdrop
          // path so we don't overwrite the note with the fallback's name.
          if (decision.kind == scenebg.SceneDecisionKind.setLocation) {
            chat.sceneLocation = verdict.locationNote.isNotEmpty
                ? verdict.locationNote
                : cat.name;
          }
        }
      }
      store.touchChat(chat); // F1: scene fields + watermarks sync
    } finally {
      _sceneClassifying = false;
      scenebg.releaseSceneClassifyLock(chat.id);
    }
  }

  /// Last ~4 RP messages (user/char/scene) joined for the scene classifier,
  /// with {{user}}/{{char}} substituted via [_fillNamePlaceholders]
  /// (Wave CY.18.157 helper) so the narration reads naturally.
  String _sceneRecentText(Chat chat) {
    final store = context.read<AppStore>();
    final character = _primaryCharacter(store, chat);
    final persona = _chatPersona(store, chat);
    final msgs = chat.messages
        .where((m) =>
            m.kind == MessageKind.user ||
            m.kind == MessageKind.char ||
            m.kind == MessageKind.scene)
        .toList();
    final tail = msgs.length <= 4 ? msgs : msgs.sublist(msgs.length - 4);
    final buf = StringBuffer();
    for (final m in tail) {
      buf.writeln(_fillNamePlaceholders(
        m.text,
        charName: character?.name,
        personaName: persona?.name,
      ));
    }
    return buf.toString().trim();
  }


  /// Drop the just-streamed assistant placeholder when it finished empty
  /// (an error with no tokens, or Stop before the first byte). VARIANT-AWARE:
  /// if a regenerate / fill-in added this as a NEW variant on top of real
  /// ones, drop only that variant (which restores the prior variant and the
  /// branch that followed it). Only a genuinely single-variant placeholder (a
  /// fresh send) is removed wholesale. Audit 2026-06-04 (Critical): calling
  /// removeMessage on a multi-variant message deletes EVERY good variant AND
  /// the entire downstream conversation — silent data loss under the default
  /// (onlyThis) delete setting.
  void _dropEmptyStreamPlaceholder(AppStore store, Chat chat, String messageId) {
    final mi = chat.messages.indexWhere((m) => m.id == messageId);
    if (mi < 0) return;
    if (chat.messages[mi].variants.length > 1) {
      store.removeMessageVariant(chat.id, messageId);
    } else {
      store.removeMessage(chat.id, messageId, cascadeOverride: false);
    }
  }

  void _finishWithError(String message, {Object? originalError}) {
    // Wave BM: belt-and-braces — drop keep-alive on any error path.
    // Safe to call even if start() was never reached.
    _keepAliveStop();
    if (!mounted) return;
    // Fix 1: this is a terminal path for the current stream — settle the
    // notifier before writing the partial text below via the normal
    // (non-isolated) `store.updateMessageText`, so that write's global
    // notify is what the bubble ultimately renders from.
    _settleStreamingNotifier();
    // Wave CH+CI: parse the friendly error message out of ChatApiError
    // JSON bodies and surface it as a transient SnackBar instead of
    // polluting the in-progress message bubble. Previous behavior
    // appended the raw error to the partial reply which (a) mixed
    // unrelated content into the RP, (b) made retries awkward
    // because the "message" now contains both partial RP and JSON
    // error blob. New behavior: keep the bubble clean (partial only,
    // or delete the empty placeholder), and show the error as a
    // brief banner with a Retry action.
    //
    // Wave CY.18.45: when the original error is a typed `ChatApiError`,
    // pick a friendly per-kind message instead of running it through
    // the JSON-error parser (offline/timeout exceptions don't have a
    // JSON body to extract from).
    String friendly;
    if (originalError is ChatApiError) {
      switch (originalError.kind) {
        case ChatApiErrorKind.offline:
          friendly = 'You appear to be offline. Check your connection '
              'and tap Retry.';
          break;
        case ChatApiErrorKind.timeout:
          friendly = originalError.message;
          break;
        case ChatApiErrorKind.server:
        case ChatApiErrorKind.other:
          friendly = _friendlyApiError(message);
          break;
      }
    } else {
      friendly = _friendlyApiError(message);
    }
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (_streamMessageId != null && chat != null) {
      // Strip Pyre's stream sentinels before deciding emptiness + before
      // persisting: a sentinel-only phantom bubble (e.g. a reasoning-only
      // reply that emitted just `<<__PYRE_FINISH__:stop__>>`) would
      // otherwise look non-empty and be kept as a literal-marker bubble.
      final partial = _stripChatSentinels(_streamBuffer);
      if (stripStreamArtifacts(_streamBuffer).trim().isEmpty) {
        // Empty placeholder — drop it so the chat doesn't end with a phantom
        // assistant bubble. Variant-aware (see _dropEmptyStreamPlaceholder):
        // a regenerate that errors empty must NOT nuke the original reply +
        // its branch.
        _dropEmptyStreamPlaceholder(store, chat, _streamMessageId!);
      } else {
        // Partial — keep it (sentinels removed; <think> preserved for the
        // reasoning toggle). The user can read what was already generated;
        // the error info lives in the snackbar. Audit 2026-06-04: write to the
        // PINNED stream variant, not selectedVariant — if the user swiped
        // variants mid-stream, the unindexed write would clobber whichever
        // variant they landed on.
        store.updateMessageText(chat.id, _streamMessageId!, partial,
            variantIndex: _streamVariantIndex);
      }
    }
    setState(() {
      _generating = false;
      _streamMessageId = null;
    });
    context.read<AppStore>().flushPersist();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          friendly,
          style: const TextStyle(fontSize: 13),
          maxLines: 4,
          overflow: TextOverflow.ellipsis,
        ),
        backgroundColor: const Color(0xFF3a1d1d),
        behavior: SnackBarBehavior.floating,
        duration: const Duration(seconds: 8),
        action: SnackBarAction(
          label: 'Retry',
          textColor: EmberColors.primary,
          onPressed: () {
            // Wave CY.18.154: route through _retryGeneration — handles both a
            // partial CHAR tip (regenerate as a variant) AND the common
            // USER-tip case (the empty placeholder was removed on error),
            // where the old _regenerateLast() silently no-op'd.
            if (!mounted) return;
            _retryGeneration();
          },
        ),
      ),
    );
  }

  /// Wave CI: extract the human-readable message out of a
  /// ChatApiError JSON body — same shapes covered by the creator's
  /// _formatApiError (OpenAI / OpenRouter / DeepSeek / Anthropic /
  /// FastAPI). Returns the raw string when nothing parses.
  String _friendlyApiError(String raw) {
    final apiMatch =
        RegExp(r'ChatApiError\((\d+)\):\s*(.*)$', dotAll: true)
            .firstMatch(raw);
    if (apiMatch == null) return raw;
    final status = apiMatch.group(1);
    final body = apiMatch.group(2)!;
    String? friendly;
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
    } catch (_) {/* leave friendly null */}
    return friendly == null ? raw : '$friendly (HTTP $status)';
  }

  /// Wave CY.18.210: this is now a THIN SHIM. The prompt assembly was
  /// extracted verbatim into the pure, testable `buildChatPrompt` in
  /// `services/chat_prompt_builder.dart` (turns + a labeled segment
  /// breakdown). This method resolves the inputs from the store EXACTLY
  /// as before (responder/snapshot/persona/preset/lorebooks), keeps the
  /// lorebook debug trace (a logging side-effect that has no influence on
  /// the assembled turns, so it stays widget-side), and returns the
  /// builder's `.turns`. Behaviour is byte-identical — proven by the
  /// regression net in `test/chat_prompt_builder_test.dart` + the full
  /// existing suite.
  /// [guide], when non-null/blank AND the Guide feature is enabled, is the
  /// ONE-SHOT guidance note injected into THIS prompt only (ephemeral — it is
  /// never added to `chat.messages`, never persisted). The injection itself is
  /// the pure `injectGuide` inside `buildChatPrompt`; here we just resolve the
  /// position from settings and pass the note through.
  List<ChatTurn> _buildTurns(AppStore store, Chat chat,
      {String? guide,
      bool includePostHistory = true,
      int? maxHistoryMessages,
      ApiProvider? provider}) {
    // Use the selected responder for the system prompt (so the right
    // character's voice is described). For >1 member chats, also include
    // a brief roster so the LLM knows the other personas in the scene.
    final responderId = _activeResponderId(chat);
    final character = responderId == null
        ? null
        : (chat.characterSnapshots[responderId] ??
            store.characterById(responderId));
    // Wave CX: honour chat.personaId, not the global default.
    final basePersona = _chatPersona(store, chat);
    // Persona party: resolve the FULL roster of the user's active personas.
    // Empty unless the chat is actually a persona party, so single-persona
    // chats pass [] and the assembled prompt stays byte-identical.
    final personaParty = chat.isPersonaParty
        ? [
            for (final id in chat.effectivePersonaIds) store.personaById(id)
          ].whereType<Persona>().toList()
        : const <Persona>[];
    // In a party the primary persona is the first roster member (drives the
    // backdrop + the builder's `persona != null` gate); otherwise the single
    // chat persona, unchanged.
    final persona =
        personaParty.isNotEmpty ? personaParty.first : basePersona;
    final preset = store.activePreset;

    // Motor Fase 1 (Slice A / Tier-1 #9): the number of BOUND books, only
    // needed for the "no entries matched" debug line's book count — the
    // actual scan (and its roll) now comes from `buildChatPrompt`'s result
    // below, so there is exactly ONE `scanLorebookHits` call per turn (no
    // more independent, possibly-disagreeing probability roll here).
    final attachedBookCount = collectBoundLorebooks(
      chat: chat,
      persona: persona,
      lookupBook: store.lorebookById,
      lookupCharacter: store.characterById,
      responderId: responderId,
    ).length;

    // Guide: only honour the one-shot note when the feature is enabled. A
    // null/blank note makes `buildChatPrompt`/`injectGuide` a no-op, so the
    // assembled turns stay byte-identical for every non-guided generation.
    final guideSettings = store.guideSettings;
    final guideNote = (guideSettings.enabled &&
            guide != null &&
            guide.trim().isNotEmpty)
        ? guide
        : null;

    // Slice D-3 (2026-07-02): pre-trim read. When the caller didn't already
    // pick a window (a retry after a real overflow — see
    // `_runGenerationInto`), consult the LEARNED limit for this
    // provider+model. If we know a real limit AND a cheap estimate of this
    // prompt already exceeds it, pick an initial window so the FIRST request
    // has a shot at fitting (no wasted round-trip on a model we've already
    // seen overflow). `provider == null` (a call site that didn't pass one,
    // or no learned entry) → `resolvedMaxHistoryMessages` stays exactly
    // [maxHistoryMessages] (null on every ordinary call) → byte-identical.
    var resolvedMaxHistoryMessages = maxHistoryMessages;
    int? learnedLimitTokens;
    if (maxHistoryMessages == null && provider != null) {
      learnedLimitTokens =
          store.learnedContextLimits['${provider.id}|${provider.model}'];
      if (learnedLimitTokens != null && learnedLimitTokens > 0) {
        final windowStart =
            ltm.firstUncoveredIndex(chat).clamp(0, chat.messages.length);
        final windowLen = chat.messages.length - windowStart;
        final estimated = _estimatePromptTokens(store, chat, character,
            persona, preset, windowStart);
        if (estimated > learnedLimitTokens && windowLen > 0) {
          final perMessage = windowLen > 0 ? estimated / windowLen : 0.0;
          resolvedMaxHistoryMessages = nextSmallerWindow(
            windowLen + 1, // +1 so the result can equal windowLen at most
            learnedLimitTokens: learnedLimitTokens,
            estimatedPromptTokens: estimated,
            estimatedTokensPerMessage: perMessage == 0 ? null : perMessage,
          );
        }
      }
    }

    final inputs = ChatPromptInputs(
      chat: chat,
      character: character,
      persona: persona,
      personaParty: personaParty,
      preset: preset,
      responderId: responderId,
      beatsCap: store.scriptSettings.beatsCap,
      lookupCharacter: store.characterById,
      lookupBook: store.lorebookById,
      inFlightMessageId: _streamMessageId,
      regexRules: store.regexRules,
      guideNote: guideNote,
      guidePosition: guideSettings.injectionPosition,
      includePostHistory: includePostHistory,
      // Party mode: `chat.partyMode` is the single source of truth (default
      // false -> byte-identical assembly, unaffected by anything below).
      partyMode: chat.partyMode,
      maxHistoryMessages: resolvedMaxHistoryMessages,
      learnedContextLimitTokens: learnedLimitTokens,
    );
    final result = buildChatPrompt(inputs);

    // Debug trace — visible in `flutter logs` while a generation runs. Helps
    // diagnose "why didn't my lorebook fire?" without inspecting the prompt.
    // One-line per fired entry plus a count summary. Reads the SAME scan
    // `buildChatPrompt` used to assemble the turns above (not a fresh
    // re-scan), so the trace can never disagree with what was actually
    // injected for a probabilistic entry.
    final scan = result.scan;
    if (scan.hits.isNotEmpty) {
      debugPrint(
          '[Lorebook] ${scan.hits.length}/${scan.totalScanned} '
          'entries fired this turn'
          '${scan.skippedDisabled > 0 ? " (${scan.skippedDisabled} disabled, skipped)" : ""}:');
      for (final t in scan.trace) {
        debugPrint('[Lorebook]   · $t');
      }
    } else if (attachedBookCount > 0) {
      debugPrint(
          '[Lorebook] no entries matched this turn '
          '(scanned ${scan.totalScanned} across $attachedBookCount book(s))');
    }

    return result.turns;
  }

  /// Slice D-3 (2026-07-02): a CONSERVATIVE, deliberately simple (chars/4-ish,
  /// via the existing [approxTokens] heuristic) estimate of this turn's
  /// outgoing prompt size — card + persona + the post-recap history window
  /// starting at [windowStart]. Used ONLY to decide whether an initial
  /// pre-trim is worth attempting against a known learned limit; it never
  /// feeds into the actual assembled prompt (that stays `buildChatPrompt`'s
  /// job). Deliberately does not attempt lorebook / preset / live-sheet /
  /// roadmap precision — those are comparatively small and the estimate only
  /// needs to be in the right ballpark to pick a starting window before the
  /// real (ground-truth) provider error takes over via the retry loop.
  int _estimatePromptTokens(
    AppStore store,
    Chat chat,
    Character? character,
    Persona? persona,
    Preset? preset,
    int windowStart,
  ) {
    var total = 0;
    if (character != null) total += approxTokensForCharacter(character);
    if (persona != null) total += approxTokensForPersona(persona);
    if (preset != null) {
      total += approxTokens(preset.mainPrompt) +
          approxTokens(preset.postHistoryInstructions);
    }
    for (var i = windowStart; i < chat.messages.length; i++) {
      total += approxTokens(chat.messages[i].text);
    }
    return total;
  }

  /// Wave CY.18.5: scroll the chat list until [messageId]'s bubble is
  /// centered on screen. Used when the user picks a node in the chat
  /// tree — the tree screen pops with the target id and we land there.
  ///
  /// Two-step strategy because ListView.builder lazily instantiates
  /// items: first jump to an approximate offset by index fraction so
  /// the target is built, then use `Scrollable.ensureVisible` via the
  /// per-message GlobalKey for pixel-precise centering.
  Future<void> _scrollToMessage(String messageId) async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    final idx = chat.messages.indexWhere((m) => m.id == messageId);
    if (idx < 0) return;

    // Disable sticky-bottom so the post-scroll auto-scroll machinery
    // doesn't yank us back down. The user explicitly aimed at this
    // message; respect that.
    _stickToBottom = false;

    if (_scrollCtl.hasClients && chat.messages.length > 1) {
      final maxOffset = _scrollCtl.position.maxScrollExtent;
      final fraction = idx / (chat.messages.length - 1);
      final approx = (maxOffset * fraction).clamp(0.0, maxOffset);
      await _scrollCtl.animateTo(
        approx,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOutCubic,
      );
    }

    // Allow a frame for the ListView to actually mount the target bubble
    // before we look up its render box via the GlobalKey.
    await Future<void>.delayed(const Duration(milliseconds: 40));
    if (!mounted) return;
    final key = _messageKeys[messageId];
    final ctx = key?.currentContext;
    if (ctx == null || !ctx.mounted) return;
    await Scrollable.ensureVisible(
      ctx,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOutCubic,
      alignment: 0.35, // sits a bit above center — easier to read forward
    );
  }

  void _scrollToBottom({bool force = false}) {
    // Respect manual scroll — the user dragged up to re-read or copy;
    // don't yank them back during streaming. The floating "↓ Jump to
    // bottom" pill is how they re-enable follow.
    if (!force && !_stickToBottom) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollCtl.hasClients) return;
      // During streaming, every chunk would otherwise spawn a 200ms
      // animateTo() that fights the previous one — 30+ overlapping
      // animations per second causes severe jank. Use jumpTo() during
      // streams; only animate when the user does something interactive
      // (send a new message, switch variant, etc.).
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

  void _stop() {
    _streamSub?.cancel();
    // Fix 1: user-initiated stop is always terminal for the current
    // notifier — settle it before the emptiness check below reads the
    // model text back out (the model write itself was always synchronous,
    // so this doesn't change what text Stop sees/keeps).
    _settleStreamingNotifier();
    _clearPendingFallback(); // audit C1
    // Wave CY.7: if the user tapped Stop BEFORE any tokens arrived,
    // the assistant message we pre-created is just dead UI (the
    // "Generating…" placeholder stayed forever). Remove it. If even
    // a byte arrived, keep the partial — the user might still want it.
    final store = context.read<AppStore>();
    final chat = _chat(store);
    final streamId = _streamMessageId;
    // chat-core-1-02: track whether Stop KEPT a real partial assistant reply
    // (vs dropping an empty placeholder or stopping an input-box impersonation,
    // where streamId is null). A kept partial is a real char turn, so the
    // post-turn memory pipeline should re-check it like any other completion.
    var keptPartial = false;
    if (chat != null && streamId != null) {
      final idx = chat.messages.indexWhere((m) => m.id == streamId);
      // Strip <think> + Pyre sentinels before the emptiness test: a
      // reasoning-only / sentinel-only stop leaves text that LOOKS
      // non-empty (e.g. `<think>…</think>` or a bare finish-reason marker)
      // but renders as nothing, so it should be dropped as a phantom
      // bubble rather than kept.
      if (idx >= 0 &&
          stripStreamArtifacts(chat.messages[idx].text).trim().isEmpty) {
        // Variant-aware drop (audit 2026-06-04 Critical): a Stop-before-first-
        // token on a regenerate must drop only the new empty variant, never
        // the whole message (which would take every prior variant + branch).
        _dropEmptyStreamPlaceholder(store, chat, streamId);
      } else if (idx >= 0) {
        // A non-empty partial was kept — it's a real assistant turn.
        keptPartial = true;
      }
    }
    setState(() {
      _generating = false;
      _streamMessageId = null;
    });
    // The partial response is real text the user might want — flush so
    // it survives. (The debounce timer is still running otherwise.)
    store.flushPersist();
    // chat-core-1-02: a kept partial is a completed assistant turn, so re-check
    // the post-turn memory pipeline (self-guarded/idempotent — see
    // _runAutoMemoryChain). Dropped placeholders / input-box impersonations
    // (streamId null) leave keptPartial false and skip it.
    if (keptPartial) _runAutoMemoryChain();
  }

  Future<void> _showChatKebab(Chat chat, Character? primary) async {
    final store = context.read<AppStore>();
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      // Wave CY.18.159: scroll-controlled + a scrollable body so this ~10-item
      // menu always fits the window — on shorter desktop windows it was
      // clipping "Delete chat" off the bottom. isScrollControlled lets the
      // sheet use the full available height; SingleChildScrollView scrolls any
      // overflow instead of letting it bleed past the window edge.
      isScrollControlled: true,
      builder: (sheet) => SafeArea(
        child: SingleChildScrollView(
          child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // Wave CY.18.194: restructured into two inline ExpansionTile
            // groups (Memories ▸ / More options ▸) so the ~12-item flat
            // list reads as a tidy menu. Top two actions stay flat (most
            // common); everything else is grouped + expand-in-place.
            if (primary != null)
              ListTile(
                leading: const Icon(Icons.add_comment_outlined),
                title: const Text('New chat with this character'),
                onTap: () async {
                  Navigator.pop(sheet);
                  await _startNewChatWithCharacter(primary);
                },
              ),
            ListTile(
              leading: const Icon(Icons.edit_note),
              title: const Text('Fill-In-Your-Own'),
              subtitle: Text(
                'Scenario change or your own opening message.',
                style:
                    TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                _promptFillIn(chat);
              },
            ),
            // Rename chat moved INTO "More options ▸" (Gui) — keeps the
            // top level to just the high-traffic New chat / Fill-In actions.
            // ── Memories ▸ ───────────────────────────────────────────
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: Icon(Icons.auto_awesome_motion,
                    color: EmberColors.textMid),
                // Wave CY.18.200: experimental badge on the Memories group.
                title: Row(
                  children: [
                    const Text('Memories'),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: EmberColors.primary.withValues(alpha: 0.13),
                        borderRadius: BorderRadius.circular(5),
                      ),
                      child: Text(
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
                iconColor: EmberColors.textHigh,
                collapsedIconColor: EmberColors.textMid,
                textColor: EmberColors.textHigh,
                collapsedTextColor: EmberColors.textHigh,
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding:
                    const EdgeInsets.only(left: 16, bottom: 4),
                children: [
                  ListTile(
                    leading: const Icon(Icons.account_tree_outlined),
                    title: const Text('Chat Tree'),
                    onTap: () {
                      Navigator.pop(sheet);
                      // Shared with the AppBar tree button (Wave CY.18.5
                      // scroll-to-picked-message behaviour lives there now).
                      _openChatTree(chat);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.psychology_outlined),
                    title: const Text('Checkpoints'),
                    subtitle: Builder(builder: (_) {
                      if (!chat.memoryEnabled) {
                        return Text(
                          'Off — auto-summariser disabled for this chat.',
                          style: TextStyle(
                              color: EmberColors.textMid, fontSize: 12),
                        );
                      }
                      final valid = ltm.findValidCheckpoints(chat);
                      final label = valid.isEmpty
                          ? 'On — no checkpoints yet.'
                          : 'On — ${valid.length} checkpoint${valid.length == 1 ? "" : "s"} '
                              'on this branch.';
                      return Text(
                        label,
                        style: TextStyle(
                            color: EmberColors.textMid, fontSize: 12),
                      );
                    }),
                    onTap: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => MemoryScreen(chatId: chat.id),
                      ));
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.checklist_rtl),
                    title: const Text('Live Sheet'),
                    subtitle: Text(
                      chat.liveSheetEnabled
                          ? 'On — tracking entity state.'
                          : 'Off — state tracking disabled for this chat.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => LiveSheetScreen(chatId: chat.id),
                      ));
                    },
                  ),
                  ListTile(
                    leading: Icon(Icons.map_outlined,
                        color: EmberColors.textMid),
                    title: const Text('Script'),
                    onTap: () {
                      Navigator.pop(sheet);
                      Navigator.of(context).push(MaterialPageRoute(
                        builder: (_) => ScriptScreen(chatId: chat.id),
                      ));
                    },
                  ),
                ],
              ),
            ),
            // ── More options ▸ ───────────────────────────────────────
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: Icon(Icons.more_horiz,
                    color: EmberColors.textMid),
                title: const Text('More options'),
                iconColor: EmberColors.textHigh,
                collapsedIconColor: EmberColors.textMid,
                textColor: EmberColors.textHigh,
                collapsedTextColor: EmberColors.textHigh,
                tilePadding: const EdgeInsets.symmetric(horizontal: 16),
                childrenPadding:
                    const EdgeInsets.only(left: 16, bottom: 4),
                children: [
                  // Rename chat lives here now (moved out of the top level).
                  ListTile(
                    leading: const Icon(Icons.drive_file_rename_outline),
                    title: const Text('Rename chat'),
                    subtitle: Text(
                      'Name this chat to tell it apart from others.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      _renameChatPrompt(chat, primary);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Chat background'),
                    subtitle: Text(
                      'Background & scene.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      showCustomizeChatSheet(context, chat.id);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.groups_outlined),
                    title: const Text('Group chat & Lorebooks'),
                    subtitle: Text(
                      'Members + attached lorebooks.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      showGroupAndLorebooksSheet(context, chat.id);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.switch_account_outlined),
                    title: const Text('Switch persona for this chat'),
                    subtitle: Text(
                      _chatPersona(store, chat)?.name == null
                          ? 'No persona attached'
                          : 'Currently: ${_chatPersona(store, chat)!.name}',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      _showChatPersonaPicker(chat);
                    },
                  ),
                  // Wave 1.1 (F6): quick preset switch without leaving the
                  // chat. The active preset is GLOBAL state (store.activePresetId),
                  // so the subtitle reflects whatever's active right now.
                  ListTile(
                    leading: const Icon(Icons.layers_outlined),
                    title: const Text('Preset'),
                    subtitle: Text(
                      'Preset · ${store.activePreset?.name ?? "None"}',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      _showPresetSwitcher();
                    },
                  ),
                  if (primary != null)
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: const Text('Character details'),
                      onTap: () {
                        Navigator.pop(sheet);
                        showCharacterDetailsSheet(
                          context,
                          characterId: primary.id,
                          chatId: chat.id,
                        );
                      },
                    ),
                  ListTile(
                    leading: const Icon(Icons.toll),
                    title: const Text('Token breakdown'),
                    subtitle: Text(
                      'See where your context budget is going.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      showChatInfoSheet(context, chat.id);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.download_outlined),
                    title: const Text('Export chat'),
                    subtitle: Text(
                      'Save as SillyTavern JSONL or full-fidelity Pyre JSON.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      _showExportChatSheet(chat, primary);
                    },
                  ),
                  Divider(color: EmberColors.stroke),
                  ListTile(
                    leading: Icon(Icons.delete_outline,
                        color: EmberColors.danger),
                    title: Text('Delete chat',
                        style: TextStyle(color: EmberColors.danger)),
                    onTap: () async {
                      Navigator.pop(sheet);
                      final ok = await confirmDelete(
                        context,
                        title: 'Delete chat?',
                        message:
                            'This conversation and all its messages will be lost forever.',
                      );
                      if (!ok || !mounted) return;
                      store.removeChat(chat.id);
                      if (mounted) Navigator.of(context).pop();
                    },
                  ),
                ],
              ),
            ),
          ],
          ),
        ),
      ),
    );
  }

  /// Completeness-gaps: rename (or clear) the chat's manual title. Mirrors
  /// the Creator's `_renameSessionPrompt` (Cancel / Reset / Save). The dialog
  /// pre-fills with the current effective label (manual title or character
  /// name); "Reset" clears the override back to the derived label.
  Future<void> _renameChatPrompt(Chat chat, Character? primary) async {
    final fallback = primary?.name ?? 'Chat';
    final ctl = TextEditingController(text: chat.displayTitle(fallback));
    final renamed = await showDialog<String?>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Rename chat'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          decoration: const InputDecoration(hintText: 'Chat title'),
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
    ctl.dispose(); // H-3: dispose the rename controller once the dialog closes.
    if (renamed == null) return;
    if (!mounted) return;
    context.read<AppStore>().renameChat(chat.id, renamed.isEmpty ? null : renamed);
  }

  /// Wave CY.13: export the chat to disk. Two formats:
  ///  - SillyTavern JSONL (portable; opens in ST / chub clients)
  ///  - Pyre JSON (full fidelity — variants, branches, snapshots)
  /// On native we write to PyreExports/ and offer the OS share sheet.
  /// On web we fall back to clipboard since there is no file system.
  Future<void> _showExportChatSheet(Chat chat, Character? primary) async {
    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.fromLTRB(20, 16, 20, 8),
              child: Align(
                alignment: Alignment.centerLeft,
                child: Text(
                  'Export chat',
                  style: TextStyle(
                      fontSize: 17, fontWeight: FontWeight.w600),
                ),
              ),
            ),
            ListTile(
              leading: Icon(Icons.swap_horiz,
                  color: EmberColors.primary),
              title: const Text('SillyTavern JSONL'),
              subtitle: Text(
                'Portable — opens in SillyTavern, chub.ai, and most '
                'Tavern-compatible clients. Lossy on variants and '
                'branches.',
                style:
                    TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                _doExportChat(chat, primary, asSillyTavern: true);
              },
            ),
            ListTile(
              leading: Icon(Icons.lock_outline,
                  color: EmberColors.primary),
              title: const Text('Pyre JSON (full fidelity)'),
              subtitle: Text(
                'Full backup — keeps every variant, branch, and '
                "snapshot. Other clients won't recognise it.",
                style:
                    TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                _doExportChat(chat, primary, asSillyTavern: false);
              },
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    );
  }

  Future<void> _doExportChat(Chat chat, Character? primary,
      {required bool asSillyTavern}) async {
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final persona = _chatPersona(store, chat);
      final userName = persona?.name ?? 'User';
      final characterName = primary?.name ??
          (chat.characterIds.isNotEmpty
              ? (chat.characterSnapshots[chat.characterIds.first]?.name ??
                  store.characterById(chat.characterIds.first)?.name ??
                  'Character')
              : 'Character');
      final content = asSillyTavern
          ? chatToSillyTavernJsonl(
              chat: chat,
              userName: userName,
              characterName: characterName,
            )
          : chatToPyreJson(chat);
      final stem = safeExportStem(characterName.isEmpty
          ? 'chat'
          : '${characterName}_chat');
      final ext = asSillyTavern ? 'jsonl' : 'json';

      if (kIsWeb) {
        final filename = '$stem.$ext';
        final mime = asSillyTavern ? 'application/x-ndjson' : 'application/json';
        downloadBytesToBrowser(
            Uint8List.fromList(utf8.encode(content)), filename, mime);
        messenger.showSnackBar(
            SnackBar(content: Text('Exported — $filename')));
        return;
      }

      final dir = await getApplicationDocumentsDirectory();
      final path = await writeExportFile(
        baseDir: dir,
        stem: stem,
        extension: ext,
        content: content,
      );
      if (!mounted) return;
      // Drop any lingering banner first (opening the OS share sheet
      // pauses a live SnackBar's dismiss timer) and show the filename
      // only, not the whole path, so the bar stays compact.
      // Deliver per platform: on mobile the documents dir is app-private and
      // invisible, so we open the share sheet directly (otherwise the export
      // "goes nowhere"); on desktop we show the saved-path confirmation + a
      // self-dismissing Share button. See widgets/export_snack.dart.
      await deliverExport(
        messenger,
        [
          XFile(path,
              mimeType: asSillyTavern
                  ? 'application/x-ndjson'
                  : 'application/json'),
        ],
        savedBanner: 'Exported — ${Uri.file(path).pathSegments.last}',
        shareSubject: 'Pyre chat — $characterName',
        shareText: asSillyTavern
            ? 'SillyTavern-compatible chat export.'
            : 'Full-fidelity Pyre chat backup.',
        // Mobile: real "Save to device" (SAF) for the chat file.
        saveBytes: Uint8List.fromList(utf8.encode(content)),
        saveFileName: Uri.file(path).pathSegments.last,
        saveExtensions: [ext],
      );
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _showMessageMenu(Chat chat, Message m) async {
    // Sub-task B: haptic on long-press toolbar open (mobile only).
    if (_isMobileForHaptics) HapticFeedback.selectionClick();
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    final isLast = chat.messages.isNotEmpty && chat.messages.last.id == m.id;
    final isChar = m.kind == MessageKind.char;
    final isUser = m.kind == MessageKind.user;
    // OOC and Scene behave like user messages — they get the divider before
    // delete and are treated as user-side in the menu.
    final isUserSide = isUser ||
        m.kind == MessageKind.ooc ||
        m.kind == MessageKind.scene;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLast && (isChar || isUser))
              ListTile(
                leading: Icon(Icons.play_arrow_rounded,
                    color: EmberColors.primary),
                title: const Text('Continue (extend this message)'),
                subtitle: isUser
                    ? Text(
                        'Have the model extend your own message in '
                        'your persona\'s voice.',
                        style: TextStyle(
                            color: EmberColors.textMid, fontSize: 12),
                      )
                    : null,
                onTap: () {
                  Navigator.pop(sheet);
                  _continueLast();
                },
              ),
            if (isChar && isLast)
              ListTile(
                leading: Icon(Icons.refresh,
                    color: EmberColors.primary),
                title: const Text('Regenerate (new variant)'),
                onTap: () {
                  Navigator.pop(sheet);
                  _regenerateLast();
                },
              ),
            // Guide (Part 2 — Action 2): guided re-roll. Same regenerate path,
            // but with a one-shot guide threaded into THIS generation only.
            // Gated on the Guide feature being enabled (matches the input ⊕
            // affordance). Last-char-message only, like plain Regenerate.
            if (isChar && isLast && store.guideSettings.enabled)
              ListTile(
                leading: Icon(Icons.auto_fix_high_outlined,
                    color: EmberColors.primary),
                title: const Text('Regenerate with a guide'),
                subtitle: Text(
                  'Re-roll this reply with a one-shot instruction.',
                  style: TextStyle(
                      color: EmberColors.textMid, fontSize: 12),
                ),
                onTap: () {
                  Navigator.pop(sheet);
                  _regenerateWithGuide(chat, m);
                },
              ),
            ListTile(
              leading: const Icon(Icons.copy),
              title: const Text('Copy text'),
              onTap: () async {
                Navigator.pop(sheet);
                await Clipboard.setData(ClipboardData(text: m.text));
                messenger.showSnackBar(
                  const SnackBar(content: Text('Copied.')),
                );
              },
            ),
            // Wave CY.16: Select text now flips the bubble itself
            // into a "select mode" where its body renders as a
            // SelectableText right in place. Long-press anywhere
            // inside the bubble triggers Android's native selection
            // handles. Tap outside or hit the X to leave the mode.
            ListTile(
              leading: const Icon(Icons.text_fields_outlined),
              title: const Text('Select text'),
              subtitle: Text(
                'Drag-select a snippet directly on the bubble.',
                style: TextStyle(
                    color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                _enterSelectMode(m);
              },
            ),
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit text'),
              onTap: () {
                Navigator.pop(sheet);
                _editMessageText(chat, m);
              },
            ),
            if (isUserSide || isChar) Divider(color: EmberColors.stroke),
            // Label adapts to the active delete behaviour so the user
            // isn't blindsided when they have cascade-on and tap what
            // looks like a single-message delete.
            Builder(builder: (_) {
              final cascade = store.chatSettings.cascadeDelete;
              return ListTile(
                leading: Icon(Icons.delete_outline,
                    color: EmberColors.danger),
                title: Text(
                  cascade ? 'Delete this and after' : 'Delete just this',
                  style: TextStyle(color: EmberColors.danger),
                ),
                subtitle: cascade
                    ? Text(
                        'Chat Settings → Delete behavior is on "This and after".',
                        style: TextStyle(
                            color: EmberColors.textMid, fontSize: 11),
                      )
                    : null,
                onTap: () async {
                  Navigator.pop(sheet);
                  // Cascade is destructive — confirm before nuking the
                  // tail of the conversation.
                  if (cascade) {
                    // chat-core-2-02: the action below is variant-aware — a
                    // multi-variant message only loses the CURRENT branch
                    // (the message + sibling variants survive). Match the
                    // confirm copy to what actually happens so the user
                    // isn't told "and every reply after" when the gentler
                    // per-variant removal will run.
                    final multiVariant = m.variants.length > 1;
                    final ok = await confirmDelete(
                      context,
                      title: multiVariant
                          ? 'Delete this version and its replies?'
                          : 'Delete this and all messages after?',
                      message: multiVariant
                          ? 'This message has alternate versions — only the '
                              'current one and the replies under it are '
                              'removed. The other versions are kept.'
                          : 'You\'ll lose this message and every reply that '
                              'came after it.',
                    );
                    if (!ok) return;
                  }
                  // Wave CY.8 / CY.14: if the message has multiple
                  // variants, we ALWAYS prefer dropping just the
                  // current variant — never the whole horizontal
                  // axis. removeMessageVariant already handles the
                  // tail (it's the downstream of the variant being
                  // dropped), so it naturally satisfies the "this and
                  // after" intent for the selected branch while
                  // preserving sibling variants. Single-variant
                  // messages fall through to the full removal.
                  if (m.variants.length > 1) {
                    store.removeMessageVariant(chat.id, m.id);
                  } else {
                    store.removeMessage(chat.id, m.id);
                  }
                },
              );
            }),
          ],
        ),
      ),
    );
  }


  /// Continue the last assistant message by streaming more text into the
  /// SAME variant (in contrast to [_regenerateLast] which adds a new one).
  Future<void> _continueLast() async {
    if (_generating) return;
    _clearPendingFallback(); // audit C1
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null || chat.messages.isEmpty) return;
    final last = chat.messages.last;
    // Wave CY.15: Continue is valid for both char and user messages.
    // Char → extend the assistant's turn (classic behavior). User →
    // extend the user's message in the persona's voice (impersonate-
    // with-prefix). OOCs / scenes / system aren't extendable.
    if (last.kind != MessageKind.char && last.kind != MessageKind.user) {
      return;
    }
    final isUserExtend = last.kind == MessageKind.user;

    _streamMessageId = last.id;
    // Pin the variant we're continuing — if the user swipes mid-stream
    // we still extend the right one rather than overwriting the new one.
    _streamVariantIndex = last.selectedVariant;
    _streamBuffer = last.text;
    setState(() => _generating = true);

    final provider = store.activeProvider;
    if (provider == null) {
      _finishWithError(
          'No provider configured. Open "More → API Connections".');
      return;
    }
    final turns = _buildTurns(store, chat);
    // Continue nudge — preset override if provided (ST presets define it
    // as `continue_nudge_prompt`), else our default.
    final preset = store.activePreset;
    final speakerName = _primaryCharacter(store, chat)?.name ?? '';
    // Wave CY.14: pull the tail of the current text into the nudge so
    // the model can't "helpfully restart" the message after the user
    // edited it. Just saying "continue" was leaving room for models
    // to regenerate from the original — quoting the exact ending forces
    // the model to extend from the edited words.
    final tail = last.text.length > 240
        ? '…${last.text.substring(last.text.length - 240)}'
        : last.text;
    // Wave CY.15: for user-side extension, swap the nudge so the model
    // continues the USER's message in the persona's voice instead of
    // a char-side continuation. We deliberately do not honour
    // continueNudgePrompt for the user case — those preset prompts
    // assume a char speaker.
    // Party scene continuation: the tip is a Narrator-voiced scene message
    // (characterId == null) covering the whole party. The default char nudge
    // below resumes in the PRIMARY character's voice, collapsing the scene —
    // so use the narrator-aware nudge that keeps voicing everyone.
    final isPartyScene = chat.partyMode &&
        chat.characterIds.length > 1 &&
        last.characterId == null;
    final String nudge;
    if (isUserExtend) {
      final persona = _chatPersona(store, chat);
      final userName = persona?.name ?? 'the user';
      nudge = '[OOC: Extend $userName\'s last message EXACTLY from where '
          'it stops. These are the literal final words — do NOT rewrite, '
          'do NOT repeat them, do NOT switch into ${speakerName.isEmpty ? "the character" : speakerName}\'s '
          'voice:\n\n'
          '"""\n$tail\n"""\n\n'
          'Pick up with the very next word, staying in $userName\'s '
          'voice. Match cadence, tense, and formatting. Reply with the '
          'continuation only — no preamble, no quotes wrapping the whole '
          'output, no narrator framing.]';
    } else if (isPartyScene) {
      final persona = _chatPersona(store, chat);
      final memberNames = [
        for (final id in chat.characterIds)
          (chat.characterSnapshots[id] ?? store.characterById(id))?.name ?? '',
      ];
      nudge = buildPartyContinueNudge(
        tail: tail,
        memberNames: memberNames,
        userName: persona?.name ?? 'the user',
      );
    } else {
      nudge = (preset?.continueNudgePrompt?.trim().isNotEmpty ?? false)
          ? preset!.continueNudgePrompt!
              .replaceAll(
                RegExp(r'\{\{lastChatMessage\}\}', caseSensitive: false),
                last.text,
              )
              .replaceAll(
                RegExp(r'\{\{char\}\}', caseSensitive: false),
                speakerName,
              )
          : '(Continue the previous assistant message EXACTLY from where '
              'it stops. These are the literal final words of that '
              'message — do NOT rewrite them, do NOT repeat them, do NOT '
              'regenerate from scratch:\n\n'
              '"""\n$tail\n"""\n\n'
              'Pick up with the very next word. Preserve voice, tense, '
              'and formatting. Output only the continuation, no preamble.)';
    }
    turns.add(ChatTurn('user', nudge));

    final pinnedVariant = _streamVariantIndex;
    await _keepAliveStart(); // Wave BM
    try {
      // chat-core-1-10: cancel any prior subscription before re-arming
      // (mirrors `_runGenerationInto`'s audit-C2 guard) so a desync where a
      // stream is live while `_generating` is false can't leak/race the old
      // sub into a stale slot.
      await _streamSub?.cancel();
      _streamSub = null;
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: turns,
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
        // Party mode: one generation voices the whole party in a scene, so
        // the single-character max_tokens ceiling scales with member count.
        partyMemberCount: (chat.partyMode && chat.characterIds.length > 1)
            ? chat.characterIds.length
            : 1,
      ).listen(
        (chunk) {
          if (!mounted) return;
          _streamBuffer += chunk;
          // Continue appends onto the EXISTING message text, so a Pyre
          // sentinel emitted mid-stream would otherwise end up buried in
          // the middle of the prose (not just at the tail). Strip the
          // sentinels before persisting; <think> stays for the toggle.
          store.updateMessageText(
            chat.id,
            last.id,
            _stripChatSentinels(_streamBuffer),
            variantIndex: pinnedVariant,
            streamingNotifier: _streamingNotifier(),
          );
          _scrollToBottom();
        },
        // Wave CY.18.45: pass the raw error object so _finishWithError
        // can detect the typed ChatApiErrorKind (offline / timeout /
        // server) and render a friendly snackbar per kind.
        onError: (e) => _finishWithError(e.toString(), originalError: e),
        onDone: () {
          _keepAliveStop(); // Wave BM
          if (!mounted) return;
          _settleStreamingNotifier();
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          // Flush the debounced state — disk is idle now, save the final
          // text so a crash doesn't lose the just-generated variant.
          context.read<AppStore>().flushPersist();
          // chat-core-1-02: re-check the post-turn memory pipeline after a
          // Continue too (self-guarded/idempotent — see _runAutoMemoryChain).
          _runAutoMemoryChain();
        },
      );
    } catch (e) {
      _keepAliveStop(); // Wave BM
      _finishWithError(e.toString());
    }
  }

  /// Ask the model to draft a user message in the active persona's voice
  /// and STREAM it into the input field — the user watches it fill in
  /// real-time and can tweak before sending. Cancellable via the stop
  /// button while streaming.
  ///
  /// Guide (Part 2 — Action 3): when the Guide feature is enabled this is the
  /// guided upgrade. It first opens a small sheet to collect an optional
  /// outline (pre-filled with the current input draft) + a narrative
  /// perspective, then expands that into the user's message. With the feature
  /// off it streams the classic impersonation immediately (unchanged).
  /// Classic "Impersonate me" — ALWAYS one-tap: no sheet, no outline, no
  /// perspective. Gui asked to keep this DECOUPLED from "Guide my message" so
  /// it matches the old (1.0) behaviour that worked on safety-default models.
  /// The guided upgrade lives in [_guideMyMessage], a separate menu item.
  Future<void> _impersonateMe() async {
    if (_generating) return;
    return _runImpersonation();
  }

  /// "Guide my message" — the guided upgrade of Impersonate: collect an outline
  /// (seeded from whatever is in the input box) + a perspective, then write the
  /// user's message expanding that outline. A SEPARATE menu item from the
  /// one-tap [_impersonateMe]; only surfaced when the Guide feature is enabled.
  Future<void> _guideMyMessage() async {
    if (_generating) return;
    final store = context.read<AppStore>();
    final draft = _inputCtl.text.trim();
    final choice = await _promptGuidedImpersonation(
      initialOutline: draft,
      initialPerspective: store.guideSettings.defaultPerspective,
    );
    if (choice == null || !mounted) return; // cancelled
    await _runImpersonation(
      outline: choice.outline,
      perspective: choice.perspective,
    );
  }

  /// The streaming core shared by classic Impersonate Me and its guided
  /// upgrade. [outline]/[perspective] are the guided affordances (both null →
  /// classic behaviour). Output streams into the input box for review; the
  /// reasoning-leak strip (Wave 153) is reused verbatim. The instruction turn
  /// is ephemeral — it is NEVER added to `chat.messages`.
  Future<void> _runImpersonation({
    String? outline,
    GuidePerspective? perspective,
  }) async {
    if (_generating) return;
    _clearPendingFallback(); // audit C1
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    // Feature (A): per-function provider routing. A GUIDED call (outline /
    // perspective came from "Guide my message") uses the guide provider; a plain
    // "Impersonate me" uses the impersonate provider. Both fall back to the chat
    // provider when no override is set — so the default behaviour is unchanged.
    final isGuided = outline != null || perspective != null;
    final provider =
        isGuided ? store.guideProvider : store.impersonateProvider;
    if (provider == null) {
      // Was a SILENT return — the tap looked like a no-op. Match the main
      // send path's toast so the user knows why nothing happened. (Guide /
      // impersonate providers both fall back to the chat provider, so a null
      // here means no provider is configured at all.)
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('No provider configured. Open "More → API Connections".'),
        ),
      );
      return;
    }
    // Wave CX: honour chat.personaId (not the global default).
    final persona = _chatPersona(store, chat);
    final personaName = persona?.name ?? 'the user';
    final preset = store.activePreset;
    // Impersonate/Guide fix: drop the preset's post-history (char-voice
    // "stay in character") instructions — they contradict the OOC "write as
    // {{user}}" turn appended just below, which triggered refusals.
    final turns = _buildTurns(store, chat, includePostHistory: false);
    // Impersonation prompt — preset override if provided (ST presets define
    // it as `impersonation_prompt`), else our default. Wave CW tuned the
    // default; Wave CX.1 added the examples nudge. Guide Part 2 extracted the
    // assembly into the pure `buildImpersonationPrompt` so the outline +
    // perspective riders are unit-testable.
    final speakerName = _primaryCharacter(store, chat)?.name ?? '';
    // Wave CX.1: if the persona has dialogue examples, give the
    // model an explicit nudge to match them. The examples are already
    // in the system prompt via _buildTurns, but pointing at them in
    // the OOC line dramatically improves voice-matching consistency.
    final hasPersonaExamples =
        persona?.dialogueExamples.trim().isNotEmpty ?? false;
    final examplesNudge = hasPersonaExamples
        ? '\n\nMatch $personaName\'s dialogue cadence and voice from the '
            '"$personaName\'s dialogue style" examples shown in your '
            'system context. Same diction, same sentence length, same '
            'kind of action beats.'
        : '';
    final impPrompt = buildImpersonationPrompt(
      personaName: personaName,
      speakerName: speakerName,
      // Group awareness: name EVERY member so the written message can engage
      // the whole scene — the single speakerName framing made Impersonate
      // react to only the primary character. Snapshot-first, like every
      // other member resolution.
      memberNames: [
        for (final id in chat.characterIds)
          (chat.characterSnapshots[id] ?? store.characterById(id))?.name ?? '',
      ],
      presetImpersonationPrompt: preset?.impersonationPrompt,
      examplesNudge: examplesNudge,
      outline: outline,
      perspective: perspective,
    );
    // User-role turn so the model treats it as the latest user
    // instruction, not optional context.
    turns.add(ChatTurn('user', impPrompt));
    final messenger = ScaffoldMessenger.of(context);
    _inputCtl.clear();
    setState(() {
      _generating = true;
      _streamBuffer = '';
      // Reuse the streaming machinery — the buffer is the same one used
      // by message streams, but we redirect chunks into the input field.
      _streamMessageId = null;
    });
    await _keepAliveStart(); // Wave BM
    try {
      // chat-core-1-10: cancel any prior subscription before re-arming
      // (mirrors `_runGenerationInto`'s audit-C2 guard) for defense in depth
      // against a live-stream / `_generating==false` desync.
      await _streamSub?.cancel();
      _streamSub = null;
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: turns,
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
      ).listen(
        (chunk) {
          _streamBuffer += chunk;
          // Wave CY.18.153: strip reasoning + Pyre stream sentinels LIVE so a
          // reasoning model's <think> chain-of-thought never visibly scrolls
          // into the user's input box. onDone re-runs the strip
          // authoritatively (it also covers the "model wrapped EVERYTHING in
          // one <think>" case, which can only be detected once </think>
          // arrives).
          _inputCtl.text = ChatText.stripReasoning(_streamBuffer
              .replaceAll(pyreFinishSentinelRegex, '')
              .replaceAll(pyreDroppedFramesRegex, ''));
          // Keep cursor pinned at the end so the input scrolls with the
          // stream instead of hiding fresh tokens off-screen.
          _inputCtl.selection = TextSelection.collapsed(
            offset: _inputCtl.text.length,
          );
        },
        onError: (e) {
          _keepAliveStop(); // Wave BM
          if (mounted) {
            setState(() => _generating = false);
            messenger.showSnackBar(
              SnackBar(content: Text('Impersonate failed: $e')),
            );
          }
        },
        onDone: () {
          _keepAliveStop(); // Wave BM
          if (!mounted) return;
          setState(() => _generating = false);
          // Wave CY.18.153: authoritative final strip — reasoning blocks +
          // Pyre stream sentinels removed before the impersonation settles as
          // the user's editable text (covers the wrapped-everything case the
          // live strip can't, plus the finish_reason / dropped-frames
          // markers). Then trim trailing whitespace.
          final cleaned = ChatText.stripReasoning(_streamBuffer
                  .replaceAll(pyreFinishSentinelRegex, '')
                  .replaceAll(pyreDroppedFramesRegex, ''))
              .trimRight();
          // Reasoning-only fallback: a thinking model can put its ENTIRE
          // output inside <think>…</think>, so after the strip `cleaned` is
          // empty even though the stream produced tokens. Left unhandled the
          // input box just goes blank and the action looks broken. Tell the
          // user instead of silently clearing.
          final streamedSomething = _streamBuffer.trim().isNotEmpty;
          if (cleaned.isEmpty && streamedSomething) {
            messenger.showSnackBar(
              const SnackBar(
                content: Text(
                    'The model replied with only reasoning — nothing to '
                    'insert. Try again, or lower its reasoning effort.'),
              ),
            );
          }
          if (cleaned != _inputCtl.text) {
            _inputCtl.text = cleaned;
            _inputCtl.selection = TextSelection.collapsed(
              offset: cleaned.length,
            );
          }
          _inputFocus.requestFocus();
          // chat-core-1-02: invoked for parity across completion paths. An
          // Impersonate only writes to the input box (no new char turn), so the
          // chain's own guards make this a cheap no-op — but it keeps the
          // per-turn scene-bg / memory re-check consistent if state changed.
          _runAutoMemoryChain();
        },
      );
    } catch (e) {
      if (mounted) setState(() => _generating = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Impersonate failed: $e')),
      );
    }
  }

  /// Guide (Part 2): shared one-line prompt for a guidance instruction.
  /// Returns the trimmed text, or null if the user cancelled / left it blank.
  /// Used by both "Guide the reply" (arm for next Send) and "Regenerate with a
  /// guide". The text is transient — the caller passes it through the prompt
  /// build for ONE generation; it is never written to history.
  Future<String?> _promptGuideLine({
    required String title,
    required String hint,
    String confirmLabel = 'Apply',
  }) async {
    final ctl = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text(title),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 4,
          minLines: 1,
          textCapitalization: TextCapitalization.sentences,
          textInputAction: TextInputAction.done,
          onSubmitted: (v) {
            final t = v.trim();
            if (t.isNotEmpty) Navigator.pop(ctx, t);
          },
          decoration: InputDecoration(
            hintText: hint,
            border: const OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final t = ctl.text.trim();
              if (t.isEmpty) return;
              Navigator.pop(ctx, t);
            },
            child: Text(confirmLabel),
          ),
        ],
      ),
    );
    ctl.dispose(); // H-3: dispose the guide-line controller on dialog close.
    final t = result?.trim();
    return (t == null || t.isEmpty) ? null : t;
  }

  /// Guide (Part 2 — Action 1): arm a one-shot guide for the NEXT Send. Shows a
  /// dismissible chip above the input bar; consumed (and cleared) by `_send`.
  Future<void> _armGuideForReply() async {
    final guide = await _promptGuideLine(
      title: 'Guide the reply',
      hint: 'How should the next reply go?',
      confirmLabel: 'Arm guide',
    );
    if (guide == null || !mounted) return;
    setState(() => _armedGuide = guide);
  }

  /// Guide (Part 2 — Action 2): prompt for a one-shot guide, then regenerate
  /// [m] as a new variant with that guidance applied for this call only.
  Future<void> _regenerateWithGuide(Chat chat, Message m) async {
    if (_generating) return;
    final guide = await _promptGuideLine(
      title: 'Regenerate with a guide',
      hint: 'Steer this re-roll (e.g. "make her more reluctant")',
      confirmLabel: 'Regenerate',
    );
    if (guide == null || !mounted) return;
    await _regenerateMessage(chat, m, guide: guide);
  }

  /// Guide (Part 2 — Action 3): the "Guide my message" sheet. Collects an
  /// optional outline (pre-filled with the current input draft) + a narrative
  /// perspective, then returns both. Returns null if the user cancelled. The
  /// outline is transient — it only seeds the model and is never persisted.
  Future<({String? outline, GuidePerspective perspective})?>
      _promptGuidedImpersonation({
    required String initialOutline,
    required GuidePerspective initialPerspective,
  }) async {
    final outlineCtl = TextEditingController(text: initialOutline);
    var perspective = initialPerspective;
    final result = await showModalBottomSheet<
        ({String? outline, GuidePerspective perspective})>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      isScrollControlled: true,
      builder: (sheet) => StatefulBuilder(
        builder: (sheet, setLocal) => Padding(
          // Lift the sheet above the keyboard when the outline field focuses.
          padding: EdgeInsets.only(
            left: 16,
            right: 16,
            top: 16,
            bottom: 16 + MediaQuery.viewInsetsOf(sheet).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Guide my message',
                  style: TextStyle(
                    color: EmberColors.textHigh,
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  'Jot a rough outline and the model expands it into a full '
                  'message in your voice — or leave it blank to have it draft '
                  'one for you. It lands in the input box to review before you '
                  'send.',
                  style: TextStyle(color: EmberColors.textMid, fontSize: 12),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: outlineCtl,
                  autofocus: true,
                  minLines: 2,
                  maxLines: 6,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Outline (optional)',
                    hintText: 'e.g. refuse the offer, but leave the door open',
                    border: OutlineInputBorder(),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  'Perspective',
                  style: TextStyle(
                      color: EmberColors.textMid, fontSize: 12),
                ),
                const SizedBox(height: 6),
                SegmentedButton<GuidePerspective>(
                  segments: const [
                    ButtonSegment(
                        value: GuidePerspective.first, label: Text('First')),
                    ButtonSegment(
                        value: GuidePerspective.second, label: Text('Second')),
                    ButtonSegment(
                        value: GuidePerspective.third, label: Text('Third')),
                  ],
                  selected: {perspective},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) =>
                      setLocal(() => perspective = s.first),
                  style: ButtonStyle(
                    backgroundColor:
                        WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? EmberColors.primary
                          : EmberColors.bgElevated;
                    }),
                    foregroundColor:
                        WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? Colors.white
                          : EmberColors.textMid;
                    }),
                  ),
                ),
                const SizedBox(height: 18),
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(sheet),
                      child: const Text('Cancel'),
                    ),
                    const SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        final o = outlineCtl.text.trim();
                        Navigator.pop(
                          sheet,
                          (
                            outline: o.isEmpty ? null : o,
                            perspective: perspective,
                          ),
                        );
                      },
                      child: const Text('Write it'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
    outlineCtl
        .dispose(); // H-3: dispose the outline controller on sheet close.
    return result;
  }

  Future<void> _promptAuxAndAdd(
      Chat chat, MessageKind kind, String title) async {
    final ctl = TextEditingController();
    final store = context.read<AppStore>();
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text('Add $title'),
        content: TextField(
          controller: ctl,
          autofocus: true,
          maxLines: 6,
          minLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(border: OutlineInputBorder()),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel')),
          ElevatedButton(
            onPressed: () {
              final t = ctl.text.trim();
              if (t.isEmpty) return;
              store.addMessage(
                chat.id,
                Message(id: newId('msg'), kind: kind, variants: [t]),
              );
              Navigator.pop(ctx);
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
    // chat-core-2-09: dispose the dialog-local controller on close (mirrors
    // the preset switcher's quickEditCtl) so each open doesn't leak one.
    ctl.dispose();
  }

  /// liveoaktripper: the chat tree / branching was buried in the per-message
  /// kebab → users couldn't find it. This is the shared "open the tree" action,
  /// now reused by BOTH the kebab entry AND a first-class AppBar button.
  /// Pushes [ChatTreeScreen]; on pop it returns the message id the user picked
  /// there, and we scroll the transcript to that bubble (Wave CY.18.5 behaviour,
  /// preserved verbatim).
  Future<void> _openChatTree(Chat chat) async {
    final targetId = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => ChatTreeScreen(chatId: chat.id),
      ),
    );
    if (!mounted || targetId == null || targetId.isEmpty) return;
    // Give the rebuild triggered by the path-of-selectVariant calls one frame
    // to settle before we measure offsets.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    if (!mounted) return;
    _scrollToMessage(targetId);
  }


  Future<void> _promptFillIn(Chat chat) async {
    final store = context.read<AppStore>();
    final responderId = _activeResponderId(chat);
    final responder = responderId == null
        ? null
        : (chat.characterSnapshots[responderId] ??
            store.characterById(responderId));
    final scenarioCtl = TextEditingController();
    final customCtl = TextEditingController();
    int tab = 0; // 0 = scenario, 1 = custom
    String? status;

    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          backgroundColor: EmberColors.bgPanel,
          title: const Text('Fill-In-Your-Own'),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<int>(
                  segments: const [
                    ButtonSegment(value: 0, label: Text('Scenario')),
                    ButtonSegment(value: 1, label: Text('Custom message')),
                  ],
                  selected: {tab},
                  onSelectionChanged: (s) =>
                      setLocal(() => tab = s.first),
                  style: ButtonStyle(
                    backgroundColor:
                        WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? EmberColors.primary
                          : EmberColors.bgElevated;
                    }),
                    foregroundColor:
                        WidgetStateProperty.resolveWith((states) {
                      return states.contains(WidgetState.selected)
                          ? Colors.white
                          : EmberColors.textMid;
                    }),
                  ),
                ),
                const SizedBox(height: 12),
                if (tab == 0) ...[
                  Text(
                    'The model writes a new opening message contextualised to your scenario. It becomes a new variant of the first message — swipe between greetings.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: scenarioCtl,
                    maxLines: 6,
                    minLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText:
                          'e.g. "Late evening, the tavern is closing. {{char}} is the last patron…"',
                    ),
                  ),
                ] else ...[
                  Text(
                    'Your text becomes a new first-message variant. Use the arrows on the opening message to switch.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: customCtl,
                    maxLines: 8,
                    minLines: 4,
                    textCapitalization: TextCapitalization.sentences,
                    decoration: const InputDecoration(
                      hintText:
                          'Type the opening exactly as the character would say it…',
                    ),
                  ),
                ],
                if (status != null) ...[
                  const SizedBox(height: 8),
                  Text(status!,
                      style:
                          TextStyle(color: EmberColors.textMid)),
                ],
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            ElevatedButton(
              onPressed: () {
                      if (tab == 1) {
                        final t = customCtl.text.trim();
                        if (t.isEmpty) return;
                        _attachVariantToFirst(chat, responderId, t);
                        Navigator.pop(ctx);
                        return;
                      }
                      final scenario = scenarioCtl.text.trim();
                      if (scenario.isEmpty) {
                        // Wave CY.12: empty scenario is treated as
                        // "just retry the opener" — the user tapped
                        // Add as variant after either changing their
                        // mind about typing a scenario, or deliberately
                        // wanting a fresh roll on the existing setup.
                        // Falls through to the normal regen path.
                        Navigator.pop(ctx);
                        final i = chat.messages.indexWhere(
                            (m) => m.kind == MessageKind.char);
                        if (i >= 0) {
                          _regenerateMessage(chat, chat.messages[i]);
                        }
                        return;
                      }
                      final provider = store.activeProvider;
                      if (provider == null) {
                        setLocal(() => status =
                            'No provider configured.');
                        return;
                      }
                      // Wave CY.10: close the dialog IMMEDIATELY and
                      // stream the opening into the chat instead of
                      // blocking the dialog with a spinner until the
                      // full reply lands. Building the system prompt
                      // happens up here (still synchronously) so the
                      // closing pop has everything it needs.
                      final persona = _chatPersona(store, chat);
                      final userName = persona?.name ?? 'You';
                      final filled = scenario
                          .replaceAll('{{char}}',
                              responder?.name ?? 'the character')
                          .replaceAll('{{user}}', userName);
                      // chat-core-2-05 (deferred portion): collect the SAME
                      // bound-lorebook hits the ongoing chat injects, plus the
                      // active preset's assembled main prompt, so the generated
                      // opener doesn't contradict the lore/preset every later
                      // turn enforces. Mirrors the builder's collect+scan
                      // (pure, cheap).
                      final attached = collectBoundLorebooks(
                        chat: chat,
                        persona: persona,
                        lookupBook: store.lorebookById,
                        lookupCharacter: store.characterById,
                        responderId: responderId,
                      );
                      final loreScan =
                          scanLorebookHits(attached, chat.messages);
                      final activePreset = store.activePreset;
                      final presetMain = activePreset == null
                          ? ''
                          : assemblePreset(activePreset).systemPrompt;
                      final sys = buildFillInOpenerPrompt(
                        responder: responder,
                        persona: persona,
                        filledScenario: filled,
                        loreHits: loreScan.hits,
                        presetMainPrompt: presetMain,
                        // Party mode: the opener sets up the WHOLE party
                        // (same joint block as every later scene turn).
                        jointPartyBlock: (chat.partyMode &&
                                chat.characterIds.length > 1)
                            ? buildJointPartyBlock(
                                chat: chat,
                                persona: persona,
                                lookupCharacter: store.characterById,
                              )
                            : null,
                      );
                      Navigator.pop(ctx);
                      _streamFillInVariant(
                        chat,
                        responderId,
                        sys,
                        provider,
                        // Wave CY.11: keep the raw scenario in the
                        // chat history as an OOC above the first
                        // message. Without this, the scenario lived
                        // only in the one-shot system prompt used to
                        // generate the opener — the model followed it
                        // for a message or two and then forgot. As an
                        // OOC turn it's re-sent every round, so the
                        // scenario stays canon for the whole chat.
                        scenarioForOoc: filled,
                      );
                    },
              child: const Text('Add as variant'),
            ),
          ],
        ),
      ),
    );
    // chat-core-2-09: dispose the dialog-local controllers on close (mirrors
    // the preset switcher's quickEditCtl) so each open doesn't leak two.
    scenarioCtl.dispose();
    customCtl.dispose();
  }

  /// Push the text as a new variant of the first message (creates the
  /// first message if the chat is empty). Mirrors HTML's `attachVariantToFirst`.
  void _attachVariantToFirst(Chat chat, String? responderId, String text) {
    final store = context.read<AppStore>();
    if (chat.messages.isEmpty) {
      store.addMessage(
        chat.id,
        Message(
          id: newId('msg'),
          kind: MessageKind.char,
          characterId: responderId,
          variants: [text],
        ),
      );
      return;
    }
    final first = chat.messages.first;
    // chat-core-2-01 (2026-06-04): before selecting the new greeting variant,
    // stash the currently-visible downstream tail under the OLD variant and
    // hide it — exactly the dance selectVariant / _regenerateMessage /
    // _streamFillInVariant do. Without it the old conversation tail stays
    // physically below the new (empty) greeting variant; a later swipe then
    // stashes that foreign tail under the WRONG variant and the original
    // greeting's whole conversation appears to vanish (recoverable, but
    // mis-associated). Snapshotting it here keeps each variant's tail with the
    // variant it belongs to, so the new custom greeting opens on a clean slate.
    if (chat.messages.length > 1) {
      final tail = chat.messages.sublist(1);
      first.downstreamByVariant[first.selectedVariant] =
          List<Message>.from(tail);
      chat.messages.removeRange(1, chat.messages.length);
    }
    first.variants.add(text);
    first.selectedVariant = first.variants.length - 1;
    store.touchChat(chat); // F1: greeting-variant edit syncs
  }

  /// Wave CY.10: stream a new opening-message variant into the chat
  /// using the Fill-In Scenario system prompt. Previously the Fill-In
  /// dialog blocked on `completeChat` and stayed frozen with a spinner
  /// until the full reply landed — the user had to wait staring at it.
  /// Now we close the dialog immediately, spawn an empty variant on
  /// the first message (or create the first message if the chat was
  /// empty), and stream into it so the scene unfolds visibly in the
  /// chat the user already dismissed back to.
  Future<void> _streamFillInVariant(
      Chat chat,
      String? responderId,
      String systemPrompt,
      ApiProvider provider,
      {String? scenarioForOoc}) async {
    final store = context.read<AppStore>();

    // Wave CY.11: the scenario rides as an OOC turn so `_buildTurns` re-sends
    // it as `[OOC]: ...` every turn (it stays canon instead of evaporating
    // after the opener).
    //
    // 2026-07 (owner): the note now sits ABOVE the greeting ("assim que ele é
    // criado, ele fica abaixo da primeira mensagem do char sendo que deveria
    // ficar em cima") — scenario first, then the scene, both visually and in
    // the replayed prompt. This deliberately REVERSES CY.18.269's
    // branch-scoping (which parked it in the variant's downstream tail so it
    // couldn't leak across greeting branches): the scenario is now CHAT-LEVEL
    // canon — it applies to every greeting variant and stays until the next
    // Fill-In REPLACES it (`_removeScenarioNotesAbove` below dedupes, so at
    // most one scenario note ever sits above the greeting).
    final oocMsg = (scenarioForOoc != null && scenarioForOoc.trim().isNotEmpty)
        ? Message(
            id: newId('msg'),
            kind: MessageKind.ooc,
            variants: ['Scenario: ${scenarioForOoc.trim()}'],
          )
        : null;

    // Remove previous Fill-In scenario notes sitting above the greeting so a
    // re-run replaces the old scenario instead of stacking a second note.
    // Deliberately narrow: only OOC messages ABOVE the first char message
    // whose text carries the Fill-In's own 'Scenario: ' prefix — a manual
    // user OOC (any position, any text) is never touched.
    void removeScenarioNotesAbove() {
      final gi =
          chat.messages.indexWhere((m) => m.kind == MessageKind.char);
      if (gi <= 0) return;
      final toRemove = <String>{
        for (var i = 0; i < gi; i++)
          if (chat.messages[i].kind == MessageKind.ooc &&
              chat.messages[i].text.startsWith('Scenario: '))
            chat.messages[i].id,
      };
      if (toRemove.isEmpty) return;
      chat.messages.removeWhere((m) => toRemove.contains(m.id));
    }

    // Party mode (2026-07, owner feedback): a greeting GENERATED in a party
    // chat is a party scene — it must render as one ("Narrator" header +
    // stacked member avatars), not as the primary character. So the greeting
    // message carries `characterId: null`, same as every scene turn. Safe for
    // the pre-existing card-written variant that shares this message: with
    // party mode OFF a null-characterId group message falls back to the
    // PRIMARY character's rendering (the long-standing edge-case path), which
    // is exactly who it was attributed to before — nothing is lost either way.
    final isPartyScene = chat.partyMode && chat.characterIds.length > 1;
    String firstId;
    int vIdx;
    final firstCharIdx = chat.messages
        .indexWhere((m) => m.kind == MessageKind.char);
    if (firstCharIdx < 0) {
      final m = Message(
        id: newId('msg'),
        kind: MessageKind.char,
        variants: [''],
        characterId: isPartyScene ? null : responderId,
      );
      store.addMessage(chat.id, m);
      firstId = m.id;
      vIdx = 0;
      // Place the scenario note ABOVE the freshly-added greeting (owner
      // 2026-07 — scenario first, then the scene), replacing any older one.
      if (oocMsg != null) {
        removeScenarioNotesAbove();
        final gi = chat.messages.indexWhere((x) => x.id == m.id);
        if (gi >= 0) {
          chat.messages.insert(gi, oocMsg);
          store.touchChat(chat); // F1: OOC-message insert syncs
        }
      }
    } else {
      final firstChar = chat.messages[firstCharIdx];
      firstId = firstChar.id;
      // Party mode: the freshly-generated greeting variant is a party scene —
      // drop the single-author pin so it renders as one (see the note above;
      // the card-written variant sharing this message degrades gracefully:
      // party OFF falls back to the primary character's rendering).
      if (isPartyScene && firstChar.characterId != null) {
        firstChar.characterId = null;
        store.touchChat(chat); // attribution change must persist + sync
      }
      // Hide any existing tail under the current variant so the new streaming
      // variant has a clean slate — same dance as regen. The OOC isn't inserted
      // yet, so the OLD variant's stashed tail never captures it.
      if (firstCharIdx < chat.messages.length - 1) {
        final tail = chat.messages.sublist(firstCharIdx + 1);
        firstChar.downstreamByVariant[firstChar.selectedVariant] =
            List<Message>.from(tail);
        chat.messages.removeRange(firstCharIdx + 1, chat.messages.length);
      }
      vIdx = store.addVariant(chat.id, firstId);
      if (vIdx < 0) return;
      // Place the scenario note ABOVE the greeting (owner 2026-07 — chat-
      // level canon, see the block comment above), replacing any previous
      // Fill-In note so re-runs never stack. Index recomputed by id: the
      // dedupe sweep may have shifted positions.
      if (oocMsg != null) {
        removeScenarioNotesAbove();
        final gi = chat.messages.indexWhere((x) => x.id == firstId);
        if (gi >= 0) {
          chat.messages.insert(gi, oocMsg);
          store.touchChat(chat); // F1: OOC-message insert syncs
        }
      }
    }
    _streamMessageId = firstId;
    _streamVariantIndex = vIdx;
    setState(() {
      _generating = true;
      _streamBuffer = '';
    });
    _scrollToBottom();
    await _keepAliveStart();
    final pinnedVariant = vIdx;
    try {
      // chat-core-1-10: cancel any prior subscription before re-arming
      // (mirrors `_runGenerationInto`'s audit-C2 guard) for defense in depth
      // against a live-stream / `_generating==false` desync.
      await _streamSub?.cancel();
      _streamSub = null;
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: [
          ChatTurn('system', systemPrompt),
          ChatTurn('user', '[Begin the scene.]'),
        ],
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
        // Party mode: one generation voices the whole party in a scene, so
        // the single-character max_tokens ceiling scales with member count.
        partyMemberCount: (chat.partyMode && chat.characterIds.length > 1)
            ? chat.characterIds.length
            : 1,
      ).listen(
        (chunk) {
          if (!mounted) return;
          _streamBuffer += chunk;
          // Strip Pyre stream sentinels before persisting so they never
          // land in the stored variant; <think> stays for the toggle.
          store.updateMessageText(
            chat.id,
            firstId,
            _stripChatSentinels(_streamBuffer),
            variantIndex: pinnedVariant,
            streamingNotifier: _streamingNotifier(),
          );
          _scrollToBottom();
        },
        // Wave CY.18.45: pass the raw error object so _finishWithError
        // can detect the typed ChatApiErrorKind (offline / timeout /
        // server) and render a friendly snackbar per kind.
        onError: (e) => _finishWithError(e.toString(), originalError: e),
        onDone: () {
          _keepAliveStop();
          if (!mounted) return;
          _settleStreamingNotifier();
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          context.read<AppStore>().flushPersist();
          // chat-core-1-02: re-check the post-turn memory pipeline after a
          // Fill-In opener too (self-guarded/idempotent — see
          // _runAutoMemoryChain). On an empty chat this seeds the per-turn
          // scene-background classifier for the brand-new greeting.
          _runAutoMemoryChain();
        },
      );
    } catch (e) {
      _keepAliveStop();
      // Wave CY.18.45: same typed-error passthrough as the streaming
      // listener — caller-side classification stays intact.
      _finishWithError(e.toString(), originalError: e);
    }
  }

  // Wave CY.16: edit + select are now inline modes on the bubble
  // itself, not modals. We track which message is in each mode via
  // these state vars; the bubble checks its own id against them and
  // renders the appropriate UI.
  String? _editingMessageId;
  String? _selectingMessageId;

  void _editMessageText(Chat chat, Message m) {
    // Exit any other inline mode first so only one is active at a time.
    setState(() {
      _selectingMessageId = null;
      _editingMessageId = m.id;
    });
  }

  void _commitMessageEdit(Chat chat, Message m, String newText) {
    context.read<AppStore>().updateMessageText(chat.id, m.id, newText);
    setState(() => _editingMessageId = null);
  }

  void _cancelMessageEdit() {
    setState(() => _editingMessageId = null);
  }

  void _enterSelectMode(Message m) {
    setState(() {
      _editingMessageId = null;
      _selectingMessageId = m.id;
    });
  }

  void _exitSelectMode() {
    setState(() => _selectingMessageId = null);
  }

  /// Returns true if the input was a recognised slash command.
  bool _handleSlashCommand(String text, AppStore store, Chat chat) {
    if (!text.startsWith('/')) return false;
    final parts = text.split(RegExp(r'\s+'));
    final cmd = parts.first.toLowerCase();
    final rest = parts.length > 1 ? parts.sublist(1).join(' ') : '';

    switch (cmd) {
      case '/direction':
        if (rest.trim().isEmpty) return false;
        final beat = roadmap.appendStoryBeat(chat, rest);
        if (beat != null) {
          store.touchChat(chat); // F1: story beat add syncs
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Added to script')),
          );
        }
        return true;
      case '/ooc':
        if (rest.isEmpty) return false;
        store.addMessage(
          chat.id,
          Message(id: newId('msg'), kind: MessageKind.ooc, variants: [rest]),
        );
        return true;
      case '/scene':
        if (rest.isEmpty) return false;
        store.addMessage(
          chat.id,
          Message(id: newId('msg'), kind: MessageKind.scene, variants: [rest]),
        );
        return true;
      case '/sys':
      case '/system':
        if (rest.isEmpty) return false;
        store.addMessage(
          chat.id,
          Message(
              id: newId('msg'), kind: MessageKind.system, variants: [rest]),
        );
        return true;
      case '/clear':
        // Wipe all messages but keep the chat metadata. Confirm first —
        // this nukes the entire conversation history with no undo.
        () async {
          final ok = await confirmDelete(
            context,
            title: 'Clear all messages?',
            message:
                'Every message in this chat will be erased. The chat itself stays.',
            confirmLabel: 'Clear',
          );
          if (!ok) return;
          for (final m in [...chat.messages]) {
            store.removeMessage(chat.id, m.id);
          }
        }();
        return true;
      case '/help':
        _showSlashHelpDialog();
        return true;
    }
    return false;
  }

  void _showSlashHelpDialog() {
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Slash commands'),
        content: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            _SlashRow(cmd: '/direction <text>', desc: 'Add a future beat to the story roadmap (no bubble).'),
            _SlashRow(cmd: '/ooc <text>', desc: 'Add an out-of-character aside.'),
            _SlashRow(cmd: '/scene <text>', desc: 'Insert a scene-change narration.'),
            _SlashRow(cmd: '/sys <text>', desc: 'System-role insert (one-off instruction).'),
            _SlashRow(cmd: '/clear', desc: 'Remove every message in this chat.'),
            _SlashRow(cmd: '/help', desc: 'Show this list.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  /// Generate a brand-new variant of the last assistant message — kept as
  /// a thin wrapper for the menu / Continue-pill action sites that always
  /// target the tip.
  Future<void> _regenerateLast() async {
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null || chat.messages.isEmpty) return;
    final last = chat.messages.last;
    if (last.kind != MessageKind.char) return;
    return _regenerateMessage(chat, last);
  }

  /// Regenerate ANY assistant message: stash the current downstream under
  /// the source variant (so swiping back restores it) and stream a new
  /// variant in place. Non-destructive — the old continuation is preserved
  /// on the variant it belonged to.
  /// [guide], when set (and the Guide feature is enabled), is the ONE-SHOT
  /// guidance applied to THIS regeneration only ("Regenerate with a guide").
  /// It is threaded into the prompt build for this single call and never saved
  /// to history — the resulting variant is just normal text.
  Future<void> _regenerateMessage(Chat chat, Message m, {String? guide}) async {
    if (_generating) return;
    _clearPendingFallback(); // audit C1
    if (m.kind != MessageKind.char) return;
    // Sub-task B: haptic on regenerate (mobile only).
    if (_isMobileForHaptics) HapticFeedback.lightImpact();
    final store = context.read<AppStore>();
    final idx = chat.messages.indexWhere((x) => x.id == m.id);
    if (idx < 0) return;

    // Stash the existing tail under the CURRENT variant so it can be
    // restored if the user swipes back. Then hide it from the visible
    // chat — the new variant will stream into a clean slate.
    if (idx < chat.messages.length - 1) {
      final tail = chat.messages.sublist(idx + 1);
      m.downstreamByVariant[m.selectedVariant] = List<Message>.from(tail);
      chat.messages.removeRange(idx + 1, chat.messages.length);
    }

    // Add an empty variant and stream into it.
    final vIdx = store.addVariant(chat.id, m.id);
    if (vIdx < 0) return;
    _streamMessageId = m.id;
    _streamVariantIndex = vIdx;
    setState(() {
      _generating = true;
      _streamBuffer = '';
    });

    final provider = store.activeProvider;
    if (provider == null) {
      _finishWithError(
          'No provider configured. Open "More → API Connections".');
      return;
    }
    final turns = _buildTurns(store, chat, guide: guide);
    final pinnedVariant = _streamVariantIndex;
    await _keepAliveStart(); // Wave BM
    try {
      // chat-core-1-10: cancel any prior subscription before re-arming
      // (mirrors `_runGenerationInto`'s audit-C2 guard) so a desync where a
      // stream is live while `_generating` is false can't leak/race the old
      // sub into a stale slot.
      await _streamSub?.cancel();
      _streamSub = null;
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: turns,
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
        // Party mode: one generation voices the whole party in a scene, so
        // the single-character max_tokens ceiling scales with member count.
        partyMemberCount: (chat.partyMode && chat.characterIds.length > 1)
            ? chat.characterIds.length
            : 1,
      ).listen(
        (chunk) {
          if (!mounted) return;
          _streamBuffer += chunk;
          // Strip Pyre stream sentinels before persisting so they never
          // land in the regenerated variant; <think> stays for the toggle.
          store.updateMessageText(
            chat.id,
            m.id,
            _stripChatSentinels(_streamBuffer),
            variantIndex: pinnedVariant,
            streamingNotifier: _streamingNotifier(),
          );
          _scrollToBottom();
        },
        // Wave CY.18.45: pass the raw error object so _finishWithError
        // can detect the typed ChatApiErrorKind (offline / timeout /
        // server) and render a friendly snackbar per kind.
        onError: (e) => _finishWithError(e.toString(), originalError: e),
        onDone: () {
          _keepAliveStop(); // Wave BM
          if (!mounted) return;
          _settleStreamingNotifier();
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          // Flush the debounced state — disk is idle now, save the final
          // text so a crash doesn't lose the just-generated variant.
          context.read<AppStore>().flushPersist();
          // chat-core-1-02: re-check the post-turn memory pipeline after a
          // Regenerate / Regenerate-with-guide too (self-guarded/idempotent —
          // see _runAutoMemoryChain). A regen adds a variant rather than a new
          // message, so the summariser is a no-op, but the per-turn scene-bg
          // classifier refreshes for the freshly-selected variant.
          _runAutoMemoryChain();
        },
      );
    } catch (e) {
      _keepAliveStop(); // Wave BM
      _finishWithError(e.toString());
    }
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final chat = _chat(store);
    if (chat == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: Text('Chat not found')),
      );
    }
    final character = _primaryCharacter(store, chat);
    // Wave CK + CX: backdrop resolution uses the chat-bound persona,
    // not the global default.
    final persona = _chatPersona(store, chat);
    // Group-aware header: a multi-character chat must show WHO is in it, not
    // just the primary character. Resolve every member (per-chat snapshot
    // first, then the library — same order as everywhere else) so the app bar
    // can show the stacked avatar cluster + joined names.
    final isGroupChat = chat.characterIds.length > 1;
    final groupMembers = isGroupChat
        ? [
            for (final id in chat.characterIds)
              chat.characterSnapshots[id] ?? store.characterById(id)
          ].whereType<Character>().toList()
        : const <Character>[];
    // Fallback title when the chat is untitled: joined member names for a
    // group, else the single character's name (unchanged for 1:1 chats).
    final headerFallback = groupMembers.length > 1
        ? groupChatHeaderTitle([for (final m in groupMembers) m.name])
        : (character?.name ?? 'Chat');
    // The chat's bubble opacity drives both message bubbles AND the
    // top/bottom chrome (app bar + input bar) so the character art shows
    // through everywhere instead of being clipped to a narrow band.
    final bubbleAlpha = store.chatSettings.bubbleAlpha;
    // Clamp the bottom vignette to the user's bubble setting too, so the
    // bottom of the screen doesn't go pitch-black when they pick a high
    // opacity (would fight with the input bar's matching translucency).
    final bottomVignette = (bubbleAlpha * 0.85).clamp(0.0, 0.7);
    // Because we extend the body behind the AppBar (so the backdrop image
    // continues to the very top of the screen), the message ListView would
    // otherwise scroll its first items UNDER the translucent app bar and
    // bleed through the title/back-button. Push content down by the status
    // bar + app bar height so messages always start visually below the bar.
    final topInset =
        MediaQuery.of(context).padding.top + kToolbarHeight;

    // Wave CY.18.33: keyboard inset that the body needs to manually
    // honour now that Scaffold's auto-resize is disabled (see
    // `resizeToAvoidBottomInset: false` below). Without this, the
    // input bar would sit BEHIND the keyboard. With it applied as
    // bottom padding to the content Column (NOT the backdrop), the
    // backdrop image stays glued to the screen while the chat ListView
    // and input bar lift above the keyboard cleanly.
    final keyboardInset = MediaQuery.viewInsetsOf(context).bottom;

    return Scaffold(
      // The backdrop image extends behind the app bar so the character
      // art is continuous all the way to the status bar.
      extendBodyBehindAppBar: true,
      // Wave CY.18.33 (Bug #1): disable Scaffold's default keyboard
      // resize. Pre-Wave, opening the keyboard shrank the body Stack,
      // which in turn shrank the Positioned.fill backdrop — the
      // background image visibly stretched/squashed every keystroke.
      // We now pad the content Column manually by the keyboard inset
      // so input + messages lift cleanly while the backdrop layer
      // stays the full size of the screen.
      resizeToAvoidBottomInset: false,
      appBar: AppBar(
        titleSpacing: 0,
        // Match the message-bubble translucency so the app bar reads as
        // part of the same "glass" surface — not a wall above the chat.
        backgroundColor:
            EmberColors.bgDeep.withValues(alpha: bubbleAlpha),
        // Kill Material 3 auto-tint that would otherwise punch the alpha back.
        surfaceTintColor: Colors.transparent,
        elevation: 0,
        scrolledUnderElevation: 0,
        title: Row(
          children: [
            // Group chat: stacked avatar cluster (tap → swipe the party's
            // photos), mirroring the party scene message. 1:1 chat: the
            // single tappable avatar (unchanged).
            if (groupMembers.length > 1)
              _PartyAvatarCluster(members: groupMembers, radius: 16)
            else
              AvatarBubble(
                dataUrl: character?.avatar,
                fallback: character?.name ?? '?',
                radius: 16,
                tappableLightbox: true,
                // Non-destructive Recrop: tap shows the full uncropped image.
                fullImageUrl: character?.avatarOriginal ?? character?.avatar,
              ),
            const SizedBox(width: 10),
            Expanded(
              // Facilidade (owner 2026-07): tapping the TITLE opens the
              // Group chat & Lorebooks sheet directly — members + party mode
              // in one tap instead of kebab → More options → Group chat.
              // Works for 1:1 chats too (that sheet is where you ADD the
              // second character, i.e. the gateway to forming a group). The
              // avatar/cluster keeps its own tap (full image / party photos).
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => showGroupAndLorebooksSheet(context, chat.id),
                child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Completeness-gaps: show the manual chat title when set,
                  // else the derived name (joined member names for a group,
                  // else the single character name). When a title overrides
                  // it, the derived name moves to the subtitle so identity
                  // isn't lost.
                  Text(
                    chat.displayTitle(headerFallback),
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  if (chat.title != null &&
                      chat.title!.trim().isNotEmpty &&
                      headerFallback.isNotEmpty)
                    Text(
                      headerFallback,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: EmberColors.textMid,
                        height: 1.2,
                      ),
                    ),
                  // Wave CY.14: show the active (chat-bound) persona
                  // under the chat name so the user always sees who
                  // they're playing as. Hidden if there's no persona
                  // attached — empty subtitle would just waste space.
                  if (persona != null)
                    Text(
                      'as ${persona.name}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: EmberColors.textMid,
                        height: 1.2,
                      ),
                    ),
                ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            tooltip: 'Chat actions',
            onPressed: () => _showChatKebab(chat, character),
          ),
        ],
      ),
      body: Stack(
        children: [
          // Wave CK: backdrop now obeys ChatSettings.backgroundSource.
          //   - characterAvatar (default): same as the legacy
          //     behaviour, the primary character's portrait.
          //   - personaAvatar: the active persona's avatar; falls
          //     back to character avatar when no persona is set.
          //   - custom: a user-uploaded base64 image.
          //   - none: no backdrop at all (plain dark theme).
          if (_resolveBackdrop(character, persona, store.chatSettings, chat) !=
              null) ...[
            Positioned.fill(
              child: IgnorePointer(
                child: Opacity(
                  // Wave CY.18.156: per-chat opacity override wins over global.
                  opacity: chat.backgroundOpacity ??
                      store.chatSettings.backgroundOpacity,
                  child: _BackdropImage(
                    dataUrl: _resolveBackdrop(
                        character, persona, store.chatSettings, chat)!,
                    // Wave CY.18.203: per-chat fit override wins over global.
                    fit: boxFitFor(chat.backgroundFit ??
                        store.chatSettings.backgroundFit),
                  ),
                ),
              ),
            ),
            Positioned.fill(
              child: IgnorePointer(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      begin: Alignment.topCenter,
                      end: Alignment.bottomCenter,
                      colors: [
                        // Very soft darkening under the translucent app bar
                        // so text stays legible without making the bar feel solid.
                        EmberColors.bgDeep.withValues(alpha: 0.22),
                        EmberColors.bgDeep.withValues(alpha: 0.0),
                        EmberColors.bgDeep.withValues(alpha: 0.0),
                        EmberColors.bgDeep.withValues(alpha: bottomVignette),
                      ],
                      stops: const [0.0, 0.12, 0.72, 1.0],
                    ),
                  ),
                ),
              ),
            ),
          ],
          // Wave CY.18.33: wrap the foreground Column in a Padding
          // that consumes the keyboard height as bottom padding. The
          // backdrop layer above sits OUTSIDE this padding (full
          // screen, never resized). Net effect: keyboard pushes
          // messages + input up, background stays fixed.
          Padding(
            padding: EdgeInsets.only(bottom: keyboardInset),
            child: Column(
        children: [
          Expanded(
            child: chat.messages.isEmpty
                ? Center(
                    child: Padding(
                      padding: EdgeInsets.all(32),
                      child: Text(
                        'Say something to start the conversation.',
                        textAlign: TextAlign.center,
                        style: TextStyle(color: EmberColors.textMid),
                      ),
                    ),
                  )
                : Stack(children: [
                    Builder(builder: (_) {
                      // Wave CY.18: precompute the set of message
                      // indexes that have a memory-checkpoint anchor
                      // on the current branch, so we can drop an
                      // inline "checkpoint" divider after each one
                      // without scanning the whole list per bubble.
                      final validCheckpoints =
                          ltm.findValidCheckpoints(chat);
                      final anchorIdxs = <int>{
                        for (final c in validCheckpoints) c.anchorMessageIdx
                      };
                      return ListView.builder(
                    controller: _scrollCtl,
                    // Top padding clears the translucent AppBar so the
                    // first message doesn't slide under the title row.
                    // Bottom keeps the regular 8px gap.
                    padding: EdgeInsets.fromLTRB(12, topInset + 8, 12, 8),
                    itemCount: chat.messages.length,
                    itemBuilder: (_, i) {
                      final m = chat.messages[i];
                      final isLast = i == chat.messages.length - 1;
                      final hasCheckpoint = anchorIdxs.contains(i);
                      // Read shared values once at the list level so they
                      // become immutable parameters for each bubble — no
                      // per-bubble context.watch, no global rebuilds on
                      // each streaming chunk.
                      final settings = store.chatSettings;
                      // Wave CX: per-chat persona, not global default.
                      final persona = _chatPersona(store, chat);
                      // In group chats, prefer the message's recorded
                      // character so each bubble shows the correct speaker.
                      //
                      // Party mode: a char message with `characterId == null`
                      // in a party-mode chat is a deliberate "party scene"
                      // message (no single author — see
                      // `_startFreshAssistantTurn`) and must render WITHOUT
                      // falling back to a single character. A `characterId
                      // == null` message in a chat where party mode is OFF
                      // is a pre-existing, unrelated edge case (e.g. no
                      // responder was resolvable) — that keeps falling back
                      // to `character` exactly as before.
                      final isPartySceneMessage =
                          chat.partyMode && m.characterId == null;
                      final speaker = isPartySceneMessage
                          ? null
                          : (m.characterId == null
                              ? character
                              : (chat.characterSnapshots[m.characterId!] ??
                                  store.characterById(m.characterId!) ??
                                  character));
                      // OWNER DECISION (2026-07): a party-scene bubble's
                      // header shows every member's name (joined/abbreviated)
                      // and the avatar is a stacked cluster of their
                      // portraits — resolved once here (same lookup order as
                      // every other speaker resolution: per-chat snapshot
                      // first, then the library). Unresolvable ids are
                      // skipped rather than crashing.
                      final partyMembers = isPartySceneMessage
                          ? [
                              for (final id in chat.characterIds)
                                chat.characterSnapshots[id] ??
                                    store.characterById(id)
                            ].whereType<Character>().toList(growable: false)
                          : const <Character>[];
                      final isThisBubbleStreaming =
                          _streamMessageId == m.id;
                      final bubble = _MessageBubble(
                        message: m,
                        character: speaker,
                        chatSettings: settings,
                        persona: persona,
                        regexRules: store.regexRules,
                        messageIndex: i,
                        isStreaming: isThisBubbleStreaming,
                        // Fix 1: only the ACTIVE streaming bubble gets the
                        // isolation notifier — every other bubble's `null`
                        // means its `_MessageBubbleState` renders `message.text`
                        // directly, completely unaffected by streaming ticks.
                        streamingText: isThisBubbleStreaming
                            ? _streamingNotifier()
                            : null,
                        showSpeakerName: chat.characterIds.length > 1,
                        isPartySceneMessage: isPartySceneMessage,
                        partyMembers: partyMembers,
                        isLast: isLast,
                        isEditing: _editingMessageId == m.id,
                        isSelecting: _selectingMessageId == m.id,
                        onCommitEdit: (text) =>
                            _commitMessageEdit(chat, m, text),
                        onCancelEdit: _cancelMessageEdit,
                        onExitSelect: _exitSelectMode,
                        onSelectVariant: (idx) {
                          context
                              .read<AppStore>()
                              .selectVariant(chat.id, m.id, idx);
                        },
                        // Every assistant message can be regenerated — older
                        // ones rewind the chat to that turn (drops what comes
                        // after) and stream a new variant in place.
                        //
                        // Wave CY.8: when + is pressed on the chat's
                        // FIRST char message (the `first_mes` /
                        // alternate-greeting slot), route to the
                        // Fill-In sheet instead of a blind regen. The
                        // user is usually trying to swap the scenario
                        // opener, not re-roll the model on an
                        // already-curated greeting — and a regen here
                        // adds a sibling variant that can't easily be
                        // undone (and used to take the original with
                        // it on delete pre-CY.8).
                        onRegenerate: m.kind == MessageKind.char
                            ? (chat.messages.first.id == m.id
                                ? () => _promptFillIn(chat)
                                : () => _regenerateMessage(chat, m))
                            : null,
                        // User, OOC, and Scene messages can all be branched —
                        // same rewind semantics: stash the downstream, add an
                        // empty variant to write a different version of the
                        // message or note. The empty branch for OOC/Scene is
                        // filled in via inline edit (long-press → Edit text).
                        onBranchUser: (m.kind == MessageKind.user ||
                                m.kind == MessageKind.ooc ||
                                m.kind == MessageKind.scene)
                            ? () => _branchUserMessage(chat, m)
                            : null,
                        // Continue only on the tip: it extends the current
                        // variant in place, which is meaningless mid-chat.
                        onContinue: (m.kind == MessageKind.char && isLast)
                            ? () => _continueLast()
                            : null,
                        onDelete: () {
                          // Wave CY.8: respect variant boundaries —
                          // a multi-variant message gets its current
                          // variant dropped, not the whole message.
                          // Cascade pref still wins for the menu path;
                          // this inline call is the gentler one.
                          final s = context.read<AppStore>();
                          if (m.variants.length > 1) {
                            s.removeMessageVariant(chat.id, m.id);
                          } else {
                            s.removeMessage(chat.id, m.id);
                          }
                        },
                        onLongPress: () => _showMessageMenu(chat, m),
                        // Wave CY.18.50: direct edit action for the
                        // hover toolbar — same effect as picking
                        // "Edit text" from the long-press menu.
                        onEdit: () => _editMessageText(chat, m),
                      );
                      // Wave CY.18: drop a tappable "checkpoint"
                      // divider AFTER the bubble whose index matches
                      // a valid checkpoint's anchor. Tapping opens
                      // the full Memory screen where the user can
                      // read / retry / delete each entry.
                      //
                      // Wave CY.18.5: outer KeyedSubtree carries the
                      // stable GlobalKey for this message so the
                      // chat-tree "scroll to message" flow can locate
                      // the bubble via ensureVisible.
                      // Wave CY.18.99: the fallback offer card renders
                      // below the assistant bubble whose generation just
                      // failed / was refused. Keyed by assistantId so it
                      // attaches to the right slot. This is a NEW render
                      // branch — there's no pre-existing in-bubble error
                      // row it replaces (today's error UX is a SnackBar).
                      final showFallbackCard = _pendingFallback != null &&
                          _pendingFallback!.assistantId == m.id;
                      final inner = (!hasCheckpoint && !showFallbackCard)
                          ? bubble
                          : Column(
                              crossAxisAlignment:
                                  CrossAxisAlignment.stretch,
                              children: [
                                bubble,
                                if (hasCheckpoint)
                                  _CheckpointDivider(
                                    onTap: () {
                                      Navigator.of(context)
                                          .push(MaterialPageRoute(
                                        builder: (_) =>
                                            MemoryScreen(chatId: chat.id),
                                      ));
                                    },
                                  ),
                                if (showFallbackCard)
                                  _buildFallbackCard(_pendingFallback!),
                              ],
                            );
                      return KeyedSubtree(
                        key: _keyFor(m.id),
                        // Fix 5 (2026-07 perf pass): give every list item
                        // its own compositing layer. Without this, a height
                        // change on the streaming bubble (text growing a
                        // line) forces Skia to repaint the whole ListView
                        // viewport's paint layer, including every sibling
                        // bubble on screen, each token. `RepaintBoundary`
                        // isolates that to just this item's layer.
                        child: RepaintBoundary(child: inner),
                      );
                    },
                  );
                    }),
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
                          shape: StadiumBorder(
                            side: BorderSide(color: EmberColors.stroke),
                          ),
                          child: InkWell(
                            customBorder: const StadiumBorder(),
                            onTap: () {
                              setState(() => _stickToBottom = true);
                              _scrollToBottom(force: true);
                            },
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                  horizontal: 12, vertical: 8),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.arrow_downward,
                                      size: 14,
                                      color: EmberColors.primary),
                                  const SizedBox(width: 6),
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
                  ]),
          ),
          // Party mode: HIDDEN — there's no single responder to pick when
          // the whole party answers together in one scene message.
          if (chat.characterIds.length > 1 && !chat.partyMode)
            _ResponderChips(
              chat: chat,
              store: store,
              selectedId: _activeResponderId(chat),
              onChanged: (id) => setState(() => _responderId = id),
              // Wave CY.18.44: lock the responder during streaming so
              // the in-flight bubble's avatar / name don't get swapped
              // out from under the reply currently being authored.
              disabled: _generating,
            ),
          _ChatSizeBanner(messages: chat.messages),
          // Guide (Part 2 — Action 1): the dismissible "armed guide" chip. Only
          // shows when a one-shot guide is armed AND the feature is enabled.
          // It's a transient UI cue — the guide lives only in `_armedGuide`
          // (State), never in the chat model.
          if (_armedGuide != null && store.guideSettings.enabled)
            _ArmedGuideChip(
              guide: _armedGuide!,
              onCancel: () => setState(() => _armedGuide = null),
            ),
          _InputBar(
            controller: _inputCtl,
            focusNode: _inputFocus,
            generating: _generating,
            onSend: _send,
            onStop: _stop,
            onImpersonate: _impersonateMe,
            onAddOOC: () => _promptAuxAndAdd(chat, MessageKind.ooc, 'OOC'),
            // System note is opt-in (Chat Settings → System note). Pass the
            // callback only when enabled → the ⋮ item is hidden by default.
            onAddSys: store.chatSettings.systemNoteEnabled
                ? () =>
                    _promptAuxAndAdd(chat, MessageKind.system, 'system note')
                : null,
            onGuideReply:
                store.guideSettings.enabled ? _armGuideForReply : null,
            onGuideMessage:
                store.guideSettings.enabled ? _guideMyMessage : null,
          ),
        ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The app-bar title for an untitled GROUP chat: the members' names joined
/// with " · " (blank names skipped, empty when none). The header's
/// `TextOverflow.ellipsis` truncates an over-long roster and the stacked
/// avatar cluster carries the "+N" overflow visually, so no abbreviation is
/// baked in here. A 1:1 chat keeps using the single character name.
String groupChatHeaderTitle(List<String> memberNames) =>
    memberNames.map((n) => n.trim()).where((n) => n.isNotEmpty).join(' · ');

/// Party mode v1 (2026-07, OWNER DECISION): a stacked "messenger group"
/// avatar cluster for a party-scene bubble — up to 3 overlapping mini
/// portraits (the classic 2-3 circle stack), reusing [AvatarBubble] per
/// circle for image resolution/decoding/fallback-initial (no hand-rolled
/// image loading). A party larger than 3 collapses the 3rd slot into a
/// "+N" disc instead of a portrait. Sized to occupy roughly the same
/// footprint as the normal single avatar ([radius] * 2 square) so bubble
/// layout doesn't shift between a single-responder message and a scene one.
class _PartyAvatarCluster extends StatelessWidget {
  final List<Character> members;
  final double radius;

  const _PartyAvatarCluster({required this.members, required this.radius});

  @override
  Widget build(BuildContext context) {
    // Mini-avatar radius: smaller than the normal single avatar so 2-3 of
    // them overlapping still reads as one compact cluster.
    final miniRadius = radius * 0.62;
    final miniDiameter = miniRadius * 2;
    // Overlap amount — how far each subsequent circle shifts right.
    final step = miniDiameter * 0.62;
    const maxVisible = 3;
    final visibleCount =
        members.length <= maxVisible ? members.length : maxVisible;
    final overflow = members.length - maxVisible;

    Widget ring(Widget child) => Container(
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: EmberColors.bgDeep, width: 1.5),
          ),
          child: child,
        );

    // Tapping any member's photo opens the fullscreen viewer and lets the
    // user swipe through the WHOLE party's photos (owner ask: "abrir a imagem
    // e rodar as fotos"). Full-res `avatarOriginal` (falling back to the
    // thumbnail) so the lightbox shows the uncropped picture, mirroring the
    // single-avatar tap. Members with no image become a broken-image page
    // rather than shifting the swipe indices out of sync with the cluster.
    final memberRefs = [
      for (final m in members) (m.avatarOriginal ?? m.avatar ?? ''),
    ];
    void openAt(BuildContext context, int index) => showImageSwipeViewer(
          context,
          refs: memberRefs,
          initialIndex: index,
          ownerName: (index >= 0 && index < members.length)
              ? members[index].name
              : '',
        );

    final circles = <Widget>[];
    for (var i = 0; i < visibleCount; i++) {
      final isLastSlot = i == maxVisible - 1;
      final showOverflowDisc = isLastSlot && overflow > 0;
      circles.add(Positioned(
        left: step * i,
        child: GestureDetector(
          // The overflow disc opens at slot i too — that index is the FIRST
          // hidden member, so a swipe-right reveals the rest of the party.
          onTap: () => openAt(context, i),
          child: ring(showOverflowDisc
              ? CircleAvatar(
                  radius: miniRadius,
                  backgroundColor: EmberColors.bgElevated,
                  child: Text(
                    '+$overflow',
                    style: TextStyle(
                      color: EmberColors.textHigh,
                      fontWeight: FontWeight.w600,
                      fontSize: miniRadius * 0.62,
                    ),
                  ),
                )
              : AvatarBubble(
                  dataUrl: members[i].avatar,
                  fallback: members[i].name,
                  radius: miniRadius,
                )),
        ),
      ));
    }

    // Total width: the last circle's left offset + its own diameter.
    final width = step * (visibleCount - 1) + miniDiameter;
    return SizedBox(
      width: width < miniDiameter ? miniDiameter : width,
      height: miniDiameter,
      child: Stack(children: circles),
    );
  }
}

/// Wave CY.15: substitute `{{user}}` / `{{char}}` (case-insensitive)
/// in any message text before display. Cards stored in chub /
/// SillyTavern format use these placeholders heavily in first_mes
/// and alternate_greetings; without this they'd render literally
/// in the chat bubble. `null` names fall back to safe defaults so a
/// chat with no persona still produces readable text.
/// Wave CY.18.210: delegates to the pure `fillNamePlaceholders` in
/// `chat_prompt_builder.dart` (one source) — used by the bubble-render +
/// impersonate paths in this screen as well as the (now-extracted) turn
/// builder.
String _fillNamePlaceholders(
  String text, {
  String? charName,
  String? personaName,
}) =>
    fillNamePlaceholders(text, charName: charName, personaName: personaName);

class _MessageBubble extends StatefulWidget {
  final Message message;
  final Character? character;
  final bool isLast;
  final bool showSpeakerName;
  final VoidCallback? onRegenerate;
  final VoidCallback? onBranchUser;
  final ValueChanged<int>? onSelectVariant;
  final VoidCallback? onDelete;
  final VoidCallback? onLongPress;
  final VoidCallback? onContinue;
  /// Wave CY.18.50: edit action handler. Parent puts the bubble into
  /// `isEditing` mode by setting `_editingMessageId = m.id` in its
  /// state. Exposed as a separate callback so the hover-revealed
  /// action toolbar can trigger inline-edit with one click instead
  /// of routing through the long-press menu.
  final VoidCallback? onEdit;
  // Settings + persona are passed in (not watched per-bubble) so that a
  // streaming notify on the store doesn't rebuild EVERY bubble — only the
  // one whose message changed via its widget identity.
  final ChatSettings chatSettings;
  final Persona? persona;
  /// Pyre 1.1 (F4): the user's regex find/replace rules, passed in once at
  /// the list level (like [chatSettings]) so a streaming notify doesn't
  /// rebuild every bubble. Applied at the DISPLAY stage to normal user/AI
  /// bubbles only (aux bubbles untouched). Empty list → render byte-identical.
  final List<RegexRule> regexRules;
  // True while this exact message is the active streaming target. Used to
  // suppress mid-stream affordances (the Continue pill in particular —
  // every chunk leaves the message looking "truncated" until the final
  // punctuation arrives).
  final bool isStreaming;

  /// Fix 1 (2026-07 perf pass): non-null ONLY for the one bubble whose
  /// [isStreaming] is true. When set, the bubble's `ChatText` is wrapped in
  /// a `ValueListenableBuilder` reading THIS notifier instead of `message.
  /// text` directly, so a streaming tick repaints only this bubble instead
  /// of the whole list rebuilding via `context.watch<AppStore>()`. `null`
  /// for every other bubble — those keep reading `message.text` exactly as
  /// before, unaffected by streaming ticks.
  final ValueNotifier<String>? streamingText;
  // Wave CY.16: inline edit / select modes driven by parent state.
  final bool isEditing;
  final bool isSelecting;
  final ValueChanged<String>? onCommitEdit;
  final VoidCallback? onCancelEdit;
  final VoidCallback? onExitSelect;

  /// Wave CY.18.7: 1-indexed position in the chat's linearised
  /// message list. Surfaced as "#N" in the bubble footer so the
  /// user can see at a glance which message they're looking at —
  /// useful now that the auto-summariser fires every N messages
  /// (default 20) and the user wants to know how close they are.
  final int messageIndex;

  /// Party mode v1 (2026-07): true for a char message with no single author
  /// (`characterId == null`) in a party-mode chat — a "the whole party
  /// spoke" scene message. `character` is null for these (the parent never
  /// falls back to a single speaker); this flag switches the header to the
  /// joined member names and the avatar to a stacked mini-avatar cluster
  /// (see [partyMembers]) instead of the normal single name/portrait. False
  /// for every other bubble (including the pre-existing, unrelated
  /// `characterId == null` edge case when party mode is off).
  final bool isPartySceneMessage;

  /// Party mode v1: every resolved member of the chat, in `characterIds`
  /// order — used ONLY when [isPartySceneMessage] is true, to build the
  /// joined-names header and the stacked avatar cluster. Empty otherwise.
  final List<Character> partyMembers;

  const _MessageBubble({
    required this.message,
    required this.character,
    required this.isLast,
    required this.chatSettings,
    required this.persona,
    required this.regexRules,
    required this.messageIndex,
    this.isStreaming = false,
    this.streamingText,
    this.showSpeakerName = false,
    this.isPartySceneMessage = false,
    this.partyMembers = const <Character>[],
    this.onRegenerate,
    this.onBranchUser,
    this.onSelectVariant,
    this.onDelete,
    this.onLongPress,
    this.onContinue,
    this.onEdit,
    this.isEditing = false,
    this.isSelecting = false,
    this.onCommitEdit,
    this.onCancelEdit,
    this.onExitSelect,
  });

  @override
  State<_MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<_MessageBubble> {
  // Controls whether the variant arrow row + branch/regen `+` chip is
  // shown. Tap the bubble (mobile) to flash controls for a few seconds;
  // they auto-hide. On desktop, hover holds them visible without a timer.
  bool _showControls = false;
  Timer? _hideTimer;

  /// Per-message reasoning visibility override. null = follow the
  /// global Chat Settings toggle. true / false = the user has
  /// explicitly opened (or closed) the reasoning block for this
  /// specific bubble using the small "Show / Hide reasoning" link.
  bool? _reasoningOverride;

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  /// Show the lateral chips and arm the auto-hide. Tapping again resets
  /// the timer so the user gets a fresh window to interact.
  void _flashControls() {
    _hideTimer?.cancel();
    setState(() => _showControls = true);
    _hideTimer = Timer(const Duration(seconds: 3), () {
      if (!mounted) return;
      setState(() => _showControls = false);
    });
  }

  @override
  Widget build(BuildContext context) {
    final m = widget.message;
    // Fix 1 perf-regression test seam ONLY: counts how many times THIS
    // bubble's build() runs, keyed by message id, so a widget test can
    // assert a non-streaming sibling's build count stays flat while the
    // isolated streaming bubble's climbs — proving the isolation without
    // reaching into private state. Zero runtime cost otherwise (a plain map
    // increment).
    debugBubbleBuildCounts.update(
      m.id,
      (n) => n + 1,
      ifAbsent: () => 1,
    );
    final isUser = m.kind == MessageKind.user;
    // Only system is truly read-only / aux (centred italic note, no controls).
    // OOC and Scene fall through to the full bubble path (Sub-task A).
    final isAux = isReadOnlyAuxKind(m.kind);
    // OOC and Scene are user-authored and live on the user side of the
    // conversation. This flag drives alignment, avatar, and color selection.
    final isUserSide = isUser ||
        m.kind == MessageKind.ooc ||
        m.kind == MessageKind.scene;
    // Whether this is an OOC or Scene note — used to add a small label chip
    // so the user can still tell them apart from plain user messages.
    final isOoc = m.kind == MessageKind.ooc;
    final isScene = m.kind == MessageKind.scene;

    if (isAux) {
      return GestureDetector(
        onLongPress: widget.onLongPress,
        // Wave CY.18.49: right-click on desktop / two-finger tap on
        // trackpad mirrors long-press. The handler is the same so
        // every action available via long-press is available via
        // right-click; no UX divergence between mobile and desktop.
        onSecondaryTap: widget.onLongPress,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: EmberColors.bgElevated,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: EmberColors.stroke),
                ),
                // The "Edit text" action flips edit mode for aux bubbles.
                child: widget.isEditing
                    ? _InlineMessageEditor(
                        initialText: m.text,
                        onCommit: widget.onCommitEdit ?? (_) {},
                        onCancel: widget.onCancelEdit ?? () {},
                      )
                    : Text(
                        // Wave CY.18.157: aux bubbles also substitute
                        // {{user}}/{{char}} at display time.
                        _fillNamePlaceholders(
                          m.text,
                          charName: widget.character?.name,
                          personaName: widget.persona?.name,
                        ),
                        style: TextStyle(
                          color: EmberColors.textMid,
                          fontStyle: FontStyle.italic,
                          fontSize: 13,
                        ),
                        textAlign: TextAlign.center,
                      ),
              ),
              // 2026-07 (owner): branched aux notes (OOC) get the same
              // variant NAVIGATION regular messages have — a compact
              // centred `< n/N >` row, always visible when there is more
              // than one variant (no tap-to-flash dance on the small note).
              // Branching itself stays in the long-press menu.
              if (m.variants.length > 1 && widget.onSelectVariant != null)
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _LateralChip(
                        icon: Icons.chevron_left,
                        onPressed: m.selectedVariant > 0
                            ? () {
                                if (_isMobileForHaptics) {
                                  HapticFeedback.selectionClick();
                                }
                                widget
                                    .onSelectVariant!(m.selectedVariant - 1);
                              }
                            : null,
                      ),
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6),
                        child: Text(
                          '${m.selectedVariant + 1}/${m.variants.length}',
                          style: TextStyle(
                              color: EmberColors.textMid, fontSize: 10),
                        ),
                      ),
                      _LateralChip(
                        icon: Icons.chevron_right,
                        onPressed: m.selectedVariant < m.variants.length - 1
                            ? () {
                                if (_isMobileForHaptics) {
                                  HapticFeedback.selectionClick();
                                }
                                widget
                                    .onSelectVariant!(m.selectedVariant + 1);
                              }
                            : null,
                      ),
                    ],
                  ),
                ),
            ],
          ),
        ),
      );
    }

    final chatSettings = widget.chatSettings;
    final isEmptyVariant = m.text.isEmpty;
    // Fix (2026-07-02 streaming regression): the ACTIVE streaming bubble
    // starts with an empty variant but must NOT render the static empty-slot
    // placeholder — its live text arrives via the `streamingText` notifier,
    // not `m.text`, and (because the isolated streaming path skips the global
    // notify) this build never re-runs to flip an `m.text.isEmpty` gate. So
    // every empty-slot VISUAL (ghost colour/border/min-width + the
    // "Generating…" child) is gated on the bubble NOT being the streaming
    // target; the VLB branch below then owns the placeholder-vs-live decision.
    final showsStaticPlaceholder =
        isEmptyVariant && widget.streamingText == null;

    // Wave CY.7: an empty variant that is NEITHER the streaming target
    // NOR the last message in the chat is an abandoned slot — the user
    // branched, didn't fill it in, and moved on (added an OOC, sent
    // new content, etc.). Rendering "Type your alternative reply…" /
    // "Generating…" in the middle of an active conversation looks
    // broken. Hide the whole bubble in that case. The variant still
    // exists in the data model and shows up again if the user
    // explicitly navigates back to it via the arrows on the previous
    // message in the variant set.
    if (isEmptyVariant && !widget.isStreaming && !widget.isLast) {
      return const SizedBox.shrink();
    }

    // ---------------------------------------------------------------------
    // Pyre 1.1 — F2: chat bubble customization.
    //
    // Resolve the user-tunable look here so the build below stays readable.
    // Every default reproduces the legacy appearance exactly (bgPanel base,
    // radius 12, no extra border, no blur) — see ChatSettings docs.
    // ---------------------------------------------------------------------
    // OOC and Scene are user-authored, so they use the user bubble colour.
    final int? roleColorArgb =
        isUserSide ? chatSettings.userBubbleColor : chatSettings.aiBubbleColor;
    final Color bubbleBase =
        roleColorArgb != null ? Color(roleColorArgb) : EmberColors.bgPanel;
    final Color bubbleColor = showsStaticPlaceholder
        ? bubbleBase.withValues(alpha: chatSettings.bubbleAlpha * 0.35)
        : bubbleBase.withValues(alpha: chatSettings.bubbleAlpha);
    final BorderRadius bubbleRadius =
        BorderRadius.circular(chatSettings.bubbleCornerRadius);
    // A user-set border (width > 0) wins. Otherwise keep the legacy logic:
    // the empty-variant "ghost slot" gets its faint outline, filled bubbles
    // get none.
    final Border? bubbleBorder = chatSettings.bubbleBorderWidth > 0
        ? Border.all(
            color: chatSettings.bubbleBorderColor != null
                ? Color(chatSettings.bubbleBorderColor!)
                : EmberColors.stroke,
            width: chatSettings.bubbleBorderWidth,
          )
        : (showsStaticPlaceholder
            ? Border.all(
                color: EmberColors.stroke.withValues(alpha: 0.6),
                width: 1,
              )
            : null);
    final double bubbleBlur = chatSettings.bubbleBlurSigma;
    final double bubbleTextScale = chatSettings.bubbleTextScale;

    final bubble = GestureDetector(
      onTap: _flashControls,
      onLongPress: widget.onLongPress,
      // Wave CY.18.49: desktop right-click opens the same menu as
      // long-press. `onSecondaryTap` covers Win/Linux/Mac mouse and
      // mac trackpad two-finger tap.
      onSecondaryTap: widget.onLongPress,
      child: MouseRegion(
        onEnter: (_) {
          // Hover holds controls open without a timer — desktop only.
          _hideTimer?.cancel();
          setState(() => _showControls = true);
        },
        // Wave CY.18.158: hide-on-exit moved to the OUTER MouseRegion that
        // wraps the whole bubble+chips Stack. Previously THIS inner region's
        // onExit fired the moment the cursor moved onto a floating chip (the
        // chips sit in the chipOverhang padding, OUTSIDE this region) — so the
        // "+"/arrows flickered away as you reached for them.
        child: _BubbleSurface(
          color: bubbleColor,
          borderRadius: bubbleRadius,
          border: bubbleBorder,
          blurSigma: bubbleBlur,
          textScale: bubbleTextScale,
          constraints: BoxConstraints(
            maxWidth: MediaQuery.of(context).size.width * 0.92,
            // When the variant is blank (e.g. a freshly-branched user line
            // waiting for input), give the bubble a generous minimum width
            // so it reads as a "ghost message slot" instead of a tiny "…"
            // dot floating at the screen edge.
            minWidth: showsStaticPlaceholder
                ? MediaQuery.of(context).size.width * 0.55
                : 0,
          ),
          child: showsStaticPlaceholder
              ? Text(
                  isUser
                      ? 'Type your alternative reply…'
                      : (isUserSide
                          ? 'Type your note…'
                          : 'Generating…'),
                  style: TextStyle(
                    color: EmberColors.textDim,
                    fontStyle: FontStyle.italic,
                    fontSize: 13,
                  ),
                )
              : widget.isEditing
                  ? _InlineMessageEditor(
                      initialText: m.text,
                      onCommit: widget.onCommitEdit ?? (_) {},
                      onCancel: widget.onCancelEdit ?? () {},
                    )
                  : widget.isSelecting
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            SelectableText(
                              // Same name substitution as the read-only
                              // path so selection produces text the
                              // user can actually paste somewhere.
                              _fillNamePlaceholders(
                                m.text,
                                charName: widget.character?.name,
                                personaName: widget.persona?.name,
                              ),
                              style: TextStyle(
                                color: EmberColors.textHigh,
                                fontSize: 14,
                                height: 1.4,
                              ),
                            ),
                            const SizedBox(height: 6),
                            Align(
                              alignment: Alignment.centerRight,
                              child: TextButton.icon(
                                icon: const Icon(Icons.close, size: 14),
                                label: const Text('Done',
                                    style: TextStyle(fontSize: 12)),
                                style: TextButton.styleFrom(
                                  foregroundColor: EmberColors.primary,
                                  padding: const EdgeInsets.symmetric(
                                      horizontal: 8, vertical: 0),
                                  minimumSize: const Size(0, 24),
                                  tapTargetSize:
                                      MaterialTapTargetSize.shrinkWrap,
                                ),
                                onPressed: widget.onExitSelect,
                              ),
                            ),
                          ],
                        )
                      : Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // Sub-task A: small label badge so OOC / Scene
                            // remain distinguishable from plain user messages
                            // even though they share alignment and controls.
                            if (isOoc || isScene)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 4),
                                child: Text(
                                  isOoc ? 'OOC' : 'Scene',
                                  style: TextStyle(
                                    color: EmberColors.primary,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w700,
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                            // Fix 1 (2026-07 perf pass): when this bubble is
                            // the active streaming target, `widget.
                            // streamingText` isolates its per-token repaints
                            // — only the `ValueListenableBuilder` below
                            // rebuilds on each coalesced flush, not the rest
                            // of this bubble (avatar, footer, controls) and
                            // definitely not any OTHER bubble. Every
                            // non-streaming bubble (the overwhelming
                            // majority during a generation) takes the plain
                            // `ChatText(m.text, ...)` branch, reading
                            // `message.text` directly exactly as before.
                            if (widget.streamingText != null)
                              ValueListenableBuilder<String>(
                                valueListenable: widget.streamingText!,
                                builder: (context, liveText, _) {
                                  // Streaming placeholder: while the notifier
                                  // is still empty (the first-token wait, which
                                  // can be long on reasoning models) show
                                  // "Generating…" — the same affordance the
                                  // static empty-variant branch used to give.
                                  // The old code relied on `m.text.isEmpty` +
                                  // a per-token GLOBAL notify to flip that
                                  // placeholder into live text; the isolated
                                  // path skips the global notify, so the flip
                                  // has to happen HERE, driven by the live
                                  // notifier value instead.
                                  if (liveText.isEmpty) {
                                    return Text(
                                      'Generating…',
                                      style: TextStyle(
                                        color: EmberColors.textDim,
                                        fontStyle: FontStyle.italic,
                                        fontSize: 13,
                                      ),
                                    );
                                  }
                                  return ChatText(
                                    // Same display-stage pipeline as the
                                    // non-streaming branch below — name-fill
                                    // then regex — just fed from the live
                                    // notifier value instead of `m.text` so
                                    // formatting (italics/quotes/markdown)
                                    // renders identically while streaming.
                                    applyRegexRules(
                                      _fillNamePlaceholders(
                                        liveText,
                                        charName: widget.character?.name,
                                        personaName: widget.persona?.name,
                                      ),
                                      widget.regexRules,
                                      stream: isUserSide
                                          ? RegexStream.userInput
                                          : RegexStream.aiOutput,
                                      stage: RegexStage.display,
                                    ),
                                    hideReasoning: _reasoningOverride ??
                                        chatSettings.hideReasoning,
                                    isStreaming: true,
                                  );
                                },
                              )
                            else
                              ChatText(
                                // Wave CY.15: substitute {{user}} / {{char}}
                                // at display time. Cards (especially
                                // first_mes / alternate_greetings) routinely
                                // contain those placeholders and they need
                                // to render as real names — same way they're
                                // already filled in the system prompt via
                                // _buildTurns.
                                //
                                // Pyre 1.1 (F4): non-destructive DISPLAY-stage
                                // regex on top (after name-fill). Empty rules
                                // list → identity, so the rendered text is
                                // byte-identical when no rules exist.
                                applyRegexRules(
                                  _fillNamePlaceholders(
                                    m.text,
                                    charName: widget.character?.name,
                                    personaName: widget.persona?.name,
                                  ),
                                  widget.regexRules,
                                  stream: isUserSide
                                      ? RegexStream.userInput
                                      : RegexStream.aiOutput,
                                  stage: RegexStage.display,
                                ),
                                hideReasoning: _reasoningOverride ??
                                    chatSettings.hideReasoning,
                              ),
                          ],
                        ),
        ),
      ),
    );

    final persona = widget.persona;
    // OOC and Scene are user-authored — show the persona avatar on the right,
    // same as a normal user message. Never show the character avatar for them.
    final avatar = isUserSide
        ? AvatarBubble(
            dataUrl: persona?.avatar,
            fallback: persona?.name ?? 'U',
            radius: 16,
            tappableLightbox: true,
            // Non-destructive Recrop: tap shows the full uncropped image.
            fullImageUrl: persona?.avatarOriginal ?? persona?.avatar,
          )
        : (widget.isPartySceneMessage
            // Party mode (OWNER DECISION 2026-07): a stacked mini-avatar
            // cluster instead of one portrait — see `_PartyAvatarCluster`.
            ? _PartyAvatarCluster(members: widget.partyMembers, radius: 16)
            : AvatarBubble(
                dataUrl: widget.character?.avatar,
                fallback: widget.character?.name ?? '?',
                radius: 16,
                tappableLightbox: true,
                fullImageUrl: widget.character?.avatarOriginal ??
                    widget.character?.avatar,
              ));

    final variantCount = m.variants.length;
    final atLast = m.selectedVariant >= variantCount - 1;
    // The wiring (onRegenerate / onBranchUser) is what decides which
    // message gets the `+`. We don't gate by widget.isLast here — for the
    // user-branch case the latest user message often ISN'T the chat's
    // last message (the assistant reply sits below it).
    // OOC/Scene never regenerate (they're user-authored), so canRegen stays
    // false for them: the parent wires onRegenerate: null for those kinds.
    final canRegen = !isUserSide && widget.onRegenerate != null;
    // User/OOC/Scene all support the "+" branch affordance — add an empty
    // variant to write a different version of the note or message.
    final canBranchUser = isUserSide && widget.onBranchUser != null;
    final hasArrows = variantCount > 1;
    // Tap / hover toggles visibility, and `_flashControls()` is also
    // armed by `didUpdateWidget` when streaming on this bubble ends —
    // that gives the user ~3s to see the new variant arrows after a
    // retry settles. We deliberately do NOT show arrows during
    // streaming (Wave CY.9): the chips floating beside a half-rendered
    // message looked busy and partially hid the text mid-flow.
    final visible = _showControls;

    // Left chevron — go to previous variant. Shown only when >1 variant
    // AND we're not at index 0 AND controls are visible.
    Widget? leftArrow() {
      if (!hasArrows || !visible || m.selectedVariant <= 0) return null;
      return _LateralChip(
        icon: Icons.chevron_left,
        onPressed: () {
          // Sub-task B: haptic on variant swipe (mobile only).
          if (_isMobileForHaptics) HapticFeedback.selectionClick();
          widget.onSelectVariant!(m.selectedVariant - 1);
        },
      );
    }

    // Right edge — `>` if there are forward variants to walk into, or `+`
    // on the last variant to add a new one (regen for char, branch for
    // user/ooc/scene). Both share the same visibility gate as the left
    // chevron: tap the bubble to flash them on, they auto-hide.
    //
    // The `+` is suppressed on EMPTY variants — there's no point branching
    // a blank slot (the user hasn't even committed the current variant
    // yet) and it removes a confusing "create another empty" affordance.
    Widget? rightArrow() {
      if (!visible) return null;
      if (hasArrows && m.selectedVariant < variantCount - 1) {
        return _LateralChip(
          icon: Icons.chevron_right,
          onPressed: () {
            // Sub-task B: haptic on variant swipe (mobile only).
            if (_isMobileForHaptics) HapticFeedback.selectionClick();
            widget.onSelectVariant!(m.selectedVariant + 1);
          },
        );
      }
      if (atLast &&
          (canRegen || canBranchUser) &&
          m.text.trim().isNotEmpty) {
        return _LateralChip(
          icon: Icons.add,
          accent: true,
          onPressed:
              canBranchUser ? widget.onBranchUser : widget.onRegenerate,
        );
      }
      return null;
    }

    // Variant counter below the bubble (only when there's a choice to make).
    // We surface the counter when the user has multiple variants OR when
    // they can branch (so the chip is still discoverable on a 1-variant msg).
    Widget? variantCounter() {
      if (!visible) return null;
      if (!hasArrows) return null;
      return Padding(
        padding: const EdgeInsets.only(top: 2),
        child: Text(
          '${m.selectedVariant + 1}/$variantCount',
          style: TextStyle(
              color: EmberColors.textMid, fontSize: 10),
        ),
      );
    }

    // Wave CY.17: removed the floating "Continue" pill. The heuristic
    // (`_looksTruncated`) couldn't reliably tell a stop-truncation from
    // a fancy structured ending (lists with `----` separators, stat
    // blocks, end-of-scene horizontal rules) — so the pill flashed
    // false-positive on a lot of clean replies. Continue still lives
    // in the long-press menu where it's user-triggered intentionally.
    // chat-core-1-13 (2026-06-04): removed the dead `continuePill()` helper
    // (always returned null) and its call site below.

    // Compose the bubble with optional lateral arrow chips overlapping
    // its right edge (HTML positions them like floating affordances on
    // the side, not below the message).
    //
    // The chips are anchored at `right: 0` / `left: 0` (i.e. at the
    // Stack's edge), and the bubble is given a matching internal pad so
    // the chip visually overlaps the bubble's edge (half inside the
    // bubble, half outside it — the chub-style "floating" look).
    //
    // Padding is RESERVED PERMANENTLY (regardless of whether chips are
    // currently visible) so the bubble's width never changes when the
    // chips fade in/out — otherwise the text would reflow and squeeze
    // every time the user taps to show controls.
    //
    // Also: positioning chips OUTSIDE the Stack's bounds (e.g. `right: -10`)
    // makes them visually appear but Flutter's default RenderBox.hitTest
    // rejects taps outside `size`, even with `clipBehavior: Clip.none`.
    // Keeping them inside Stack bounds via this padding means the entire
    // chip is tappable.
    Widget bubbleWithLateralChips() {
      final right = rightArrow();
      final left = leftArrow();
      // Reserved width per side; matches half the 36px chip so the chip
      // sits centered on the bubble's edge.
      const chipOverhang = 18.0;
      // Wave CY.18.158: ONE MouseRegion around the WHOLE Stack (bubble + the
      // floating +/arrow chips) so hovering a chip counts as "still inside"
      // and it no longer flickers away. The chips live in the chipOverhang
      // padding at the Stack edges — inside the Stack's bounds, so this region
      // covers them. The inner bubble region only SHOWS on enter; this outer
      // one owns hide-on-exit for the entire interactive area.
      return MouseRegion(
        onEnter: (_) {
          _hideTimer?.cancel();
          setState(() => _showControls = true);
        },
        onExit: (_) => setState(() => _showControls = false),
        child: Stack(
          clipBehavior: Clip.none,
          children: [
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: chipOverhang),
              child: bubble,
            ),
            if (left != null)
              Positioned(left: 0, top: 0, bottom: 0,
                  child: Center(child: left)),
            if (right != null)
              Positioned(right: 0, top: 0, bottom: 0,
                  child: Center(child: right)),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 12),
      child: Column(
        // OOC/Scene align to the end (user side) same as a regular user msg.
        crossAxisAlignment:
            isUserSide ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (widget.showSpeakerName &&
              !isUserSide &&
              (widget.character != null || widget.isPartySceneMessage))
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: 4),
              child: Text(
                // Party mode (owner decision 2026-07, revised after live
                // testing): no single speaker — the header reads "Narrator"
                // (matches the prompt-side framing, where the preset's
                // {{char}} resolves to Narrator and the joint instruction
                // casts the model as the scene's narrator). WHO is in the
                // party is already shown by the stacked avatar cluster.
                widget.character?.name ??
                    (widget.isPartySceneMessage ? 'Narrator' : ''),
                key: const Key('speakerNameHeader'),
                style: TextStyle(
                  color: EmberColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          Row(
            mainAxisAlignment:
                isUserSide ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: isUserSide
                ? [
                    Flexible(child: bubbleWithLateralChips()),
                    const SizedBox(width: 8),
                    avatar,
                  ]
                : [
                    avatar,
                    const SizedBox(width: 8),
                    Flexible(child: bubbleWithLateralChips()),
                  ],
          ),
          if (variantCounter() != null)
            Padding(
              padding: EdgeInsets.only(
                left: isUserSide ? 0 : 48,
                right: isUserSide ? 48 : 0,
              ),
              child: variantCounter(),
            ),
          // Footer row: assistant messages get token estimate + (optional)
          // per-message reasoning toggle + #N. User/OOC/Scene messages get
          // just #N on their (right) side. All hidden mid-stream and
          // on empty variants. Reasoning toggle only appears if the body
          // has a <think> block — R1-style models, no-op for plain text.
          //
          // Wave CY.18.7: added the #N counter so the user can see how
          // close they are to the next auto-checkpoint (which fires
          // every N messages).
          if (!widget.isStreaming &&
              !isEmptyVariant &&
              m.text.trim().isNotEmpty)
            Padding(
              padding: EdgeInsets.only(
                top: 2,
                left: isUserSide ? 0 : 48,
                right: isUserSide ? 8 : 0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: isUserSide
                    ? MainAxisAlignment.end
                    : MainAxisAlignment.start,
                children: [
                  if (!isUserSide) ...[
                    Text(
                      formatApproxTokens(m.text) ?? '',
                      style: TextStyle(
                          color: EmberColors.textDim, fontSize: 10),
                    ),
                    if (ChatText.containsReasoning(m.text)) ...[
                      const SizedBox(width: 10),
                      GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onTap: () {
                          final currentlyHidden = _reasoningOverride ??
                              widget.chatSettings.hideReasoning;
                          setState(() =>
                              _reasoningOverride = !currentlyHidden);
                        },
                        child: Builder(builder: (_) {
                          final hidden = _reasoningOverride ??
                              widget.chatSettings.hideReasoning;
                          return Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                hidden
                                    ? Icons.expand_more
                                    : Icons.expand_less,
                                size: 12,
                                color: EmberColors.textMid,
                              ),
                              const SizedBox(width: 2),
                              Text(
                                hidden
                                    ? 'Show reasoning'
                                    : 'Hide reasoning',
                                style: TextStyle(
                                    color: EmberColors.textMid,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500),
                              ),
                            ],
                          );
                        }),
                      ),
                    ],
                    const SizedBox(width: 8),
                    Text(
                      '·',
                      style: TextStyle(
                          color: EmberColors.textDim, fontSize: 10),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '#${widget.messageIndex + 1}',
                    style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 10,
                        fontFeatures: [FontFeature.tabularFigures()]),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

/// Pyre 1.1 — F2: a [TextScaler] that multiplies an existing scaler by a
/// constant factor, so the bubble "size" control composes WITH (rather than
/// replaces) the ambient/system text scale.
class _ComposedTextScaler extends TextScaler {
  final TextScaler _base;
  final double _factor;
  const _ComposedTextScaler(this._base, this._factor);

  @override
  double scale(double fontSize) => _base.scale(fontSize) * _factor;

  // `textScaleFactor` is abstract on TextScaler and must be implemented, but
  // the member itself is deprecated — ignore the lint where we delegate to it.
  @override
  double get textScaleFactor =>
      // ignore: deprecated_member_use
      _base.textScaleFactor * _factor;
}

/// Pyre 1.1 — F2: the visible message-bubble surface.
///
/// Pulled out of [_MessageBubble.build] so the customization wiring (color,
/// corner radius, border, optional backdrop blur, text scaling) lives in one
/// place. With the default values it renders exactly like the old inline
/// `Container` did: a single decorated box, no blur, text at 1.0×.
///
/// When [blurSigma] > 0 the bubble's translucent fill is layered OVER a
/// [BackdropFilter] so the chat background behind the bubble is frosted —
/// the frost (and the fill, and the content) are all clipped to the rounded
/// rect via the same [ClipRRect], so nothing bleeds past the corners.
class _BubbleSurface extends StatelessWidget {
  final Color color;
  final BorderRadius borderRadius;
  final Border? border;
  final double blurSigma;
  final double textScale;
  final BoxConstraints constraints;
  final Widget child;

  const _BubbleSurface({
    required this.color,
    required this.borderRadius,
    required this.border,
    required this.blurSigma,
    required this.textScale,
    required this.constraints,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    // Scale ONLY the bubble's own content. At the 1.0 default we add NO
    // wrapper at all, so the ambient (incl. system accessibility) text scale
    // passes through untouched — the bubble renders identically to before.
    // For a non-default scale we compose our multiplier ON TOP of whatever
    // scaler is already in effect (system scale × bubble scale).
    Widget content = child;
    if (textScale != 1.0) {
      final mq = MediaQuery.of(context);
      content = MediaQuery(
        data: mq.copyWith(
          textScaler: _ComposedTextScaler(mq.textScaler, textScale),
        ),
        child: content,
      );
    }

    final inner = Container(
      constraints: constraints,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: color,
        borderRadius: borderRadius,
        border: border,
      ),
      child: content,
    );

    if (blurSigma <= 0) return inner;

    // Frost the area behind the bubble, clipped to its rounded rect.
    //
    // The RepaintBoundary isolates the blur into its own composited layer so it
    // isn't re-sampled against the moving backdrop on every scroll frame.
    // Without it, a per-bubble BackdropFilter inside the scrolling message list
    // flickers on some (GPU-dependent) devices. It's purely a compositing hint
    // — zero visual change — that stabilises the frost during scroll.
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: borderRadius,
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
          child: inner,
        ),
      ),
    );
  }
}

/// Wave CY.16: inline message editor — replaces the bubble's body
/// with a TextField + Save / Cancel buttons. Lives entirely inside
/// the bubble layout so the user keeps their place in the chat (no
/// modal context switch). The parent _ChatScreenState tracks which
/// message is currently in edit mode via `_editingMessageId`.
class _InlineMessageEditor extends StatefulWidget {
  final String initialText;
  final ValueChanged<String> onCommit;
  final VoidCallback onCancel;
  const _InlineMessageEditor({
    required this.initialText,
    required this.onCommit,
    required this.onCancel,
  });

  @override
  State<_InlineMessageEditor> createState() => _InlineMessageEditorState();
}

class _InlineMessageEditorState extends State<_InlineMessageEditor> {
  late final TextEditingController _ctl;

  @override
  void initState() {
    super.initState();
    _ctl = TextEditingController(text: widget.initialText);
  }

  @override
  void dispose() {
    _ctl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        TextField(
          controller: _ctl,
          maxLines: 12,
          minLines: 3,
          autofocus: true,
          textCapitalization: TextCapitalization.sentences,
          style: TextStyle(
              color: EmberColors.textHigh, fontSize: 14, height: 1.4),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding:
                EdgeInsets.symmetric(horizontal: 10, vertical: 8),
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: widget.onCancel,
              style: TextButton.styleFrom(
                foregroundColor: EmberColors.textMid,
                padding: const EdgeInsets.symmetric(
                    horizontal: 10, vertical: 0),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 4),
            ElevatedButton(
              onPressed: () => widget.onCommit(_ctl.text),
              style: ElevatedButton.styleFrom(
                backgroundColor: EmberColors.primary,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                    horizontal: 14, vertical: 0),
                minimumSize: const Size(0, 28),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    );
  }
}

/// Wave 1.1 (F6): tiny primary-tinted pill used in the in-chat preset
/// switcher to flag the locked "Pyre Default" preset. Mirrors the `_Pill`
/// style on the full Presets screen so the two surfaces read consistently.
class _PresetTag extends StatelessWidget {
  final String label;
  const _PresetTag({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: EmberColors.primary.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: EmberColors.primary.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: EmberColors.primary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

class _LateralChip extends StatelessWidget {
  final IconData icon;
  final VoidCallback? onPressed;
  final bool accent;
  const _LateralChip({
    required this.icon,
    required this.onPressed,
    this.accent = false,
  });

  @override
  Widget build(BuildContext context) {
    final bg = accent ? EmberColors.primary : EmberColors.bgElevated;
    final fg = accent ? Colors.white : EmberColors.textMid;
    return Material(
      color: bg,
      elevation: 4,
      shadowColor: Colors.black.withValues(alpha: 0.5),
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onPressed,
        // 36px visible target — more generous for thumbs while still
        // reading as a small floating chip on the bubble edge.
        child: SizedBox(
          width: 36,
          height: 36,
          child: Icon(icon, size: 18, color: fg),
        ),
      ),
    );
  }
}

/// Renders an avatar `data:` URL as a full-bleed background.
///
/// Wave CY.1: caches the decoded bytes per `dataUrl` so a chat with a
/// backdrop doesn't re-base64-decode the (typically multi-hundred-KB)
/// avatar on every parent rebuild — and every streaming chunk on the
/// chat screen IS a parent rebuild.
class _BackdropImage extends StatelessWidget {
  final String dataUrl;
  // Wave CY.18.203: caller-supplied BoxFit; defaults to cover (legacy behaviour).
  final BoxFit fit;
  const _BackdropImage({required this.dataUrl, this.fit = BoxFit.cover});

  static final Map<String, Uint8List?> _decodeCache = <String, Uint8List?>{};
  // Cap the cache so swapping backdrops between many chats doesn't
  // pin the entire history in memory. LRU is overkill — drop everything
  // when we exceed the soft cap; the first build after eviction pays
  // one decode again, which is still fine.
  static const int _maxCacheEntries = 8;

  Uint8List? _decode() {
    final cached = _decodeCache[dataUrl];
    if (cached != null) return cached;
    if (_decodeCache.containsKey(dataUrl)) {
      // Cached failure — don't retry decoding the same broken URL.
      return null;
    }
    if (!dataUrl.startsWith('data:')) {
      _decodeCache[dataUrl] = null;
      return null;
    }
    final comma = dataUrl.indexOf(',');
    if (comma < 0) {
      _decodeCache[dataUrl] = null;
      return null;
    }
    try {
      final bytes = Uint8List.fromList(base64Decode(dataUrl.substring(comma + 1)));
      if (_decodeCache.length >= _maxCacheEntries) _decodeCache.clear();
      _decodeCache[dataUrl] = bytes;
      return bytes;
    } catch (_) {
      _decodeCache[dataUrl] = null;
      return null;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Wave CY.18.184: bundled scene-background asset (dynamic mode). AssetImage
    // throws ASYNCHRONOUSLY on a missing asset, so an errorBuilder is required
    // for the "never crash → fall back to plain theme" guarantee.
    // Wave CY.18.203: for cover (default) and fill we top-anchor the image so
    // portrait art keeps the face visible; for contain and fitWidth we centre
    // so letterboxing is symmetric rather than one-sided.
    final alignment = (fit == BoxFit.contain || fit == BoxFit.fitWidth)
        ? Alignment.center
        : Alignment.topCenter;
    if (dataUrl.startsWith('asset:')) {
      return Image.asset(
        dataUrl.substring('asset:'.length),
        fit: fit,
        gaplessPlayback: true,
        alignment: alignment,
        errorBuilder: (_, e, st) => const SizedBox.shrink(),
      );
    }
    // Inline base64 (custom background): keep the cached decode — this widget
    // rebuilds on every streamed chunk / keystroke, and re-decoding a large
    // data: URL each frame would jank.
    if (dataUrl.startsWith('data:')) {
      final bytes = _decode();
      if (bytes == null) return const SizedBox.shrink();
      return Image.memory(
        bytes,
        fit: fit,
        gaplessPlayback: true,
        alignment: alignment,
      );
    }
    // Wave CY.18.268: everything else — a `pyre://attachment/<hash>` ref
    // (the character/persona AVATAR background, the default source since the
    // Wave 64 attachment migration), an http URL, or raw base64 — resolves
    // through the SAME single-source-of-truth resolver avatars + galleries
    // use, so an avatar background renders identically to its thumbnail.
    // Before this branch, _BackdropImage only knew data: + asset:, so every
    // avatar-sourced backdrop silently fell through to a blank theme.
    final provider = Lightbox.resolveImage(dataUrl);
    if (provider == null) return const SizedBox.shrink();
    return Image(
      image: provider,
      fit: fit,
      gaplessPlayback: true,
      alignment: alignment,
      errorBuilder: (_, e, st) => const SizedBox.shrink(),
    );
  }
}


class _SlashRow extends StatelessWidget {
  final String cmd;
  final String desc;
  const _SlashRow({required this.cmd, required this.desc});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            cmd,
            style: TextStyle(
              fontFamily: 'monospace',
              color: EmberColors.primary,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              desc,
              style: TextStyle(
                  color: EmberColors.textMid, fontSize: 13, height: 1.4),
            ),
          ),
        ],
      ),
    );
  }
}

class _ResponderChips extends StatelessWidget {
  final Chat chat;
  final AppStore store;
  final String? selectedId;
  final ValueChanged<String> onChanged;
  /// Wave CY.18.44: disable the chips while a generation is streaming.
  /// Pre-Wave, tapping a different responder MID-STREAM changed
  /// `_responderId`, which re-read the active character snapshot on the
  /// next rebuild — and the streaming bubble's avatar / name visibly
  /// shifted to the NEW responder even though the in-flight reply was
  /// being authored by the OLD one. The actual `Message.characterId`
  /// was pinned at stream start, but the visual attribution was lying
  /// to the user. We freeze the picker until the stream completes so
  /// the rendered character matches the spoken one.
  final bool disabled;

  const _ResponderChips({
    required this.chat,
    required this.store,
    required this.selectedId,
    required this.onChanged,
    this.disabled = false,
  });

  @override
  Widget build(BuildContext context) {
    final bubbleAlpha = context.watch<AppStore>().chatSettings.bubbleAlpha;
    return Container(
      decoration: BoxDecoration(
        color: EmberColors.bgDeep.withValues(alpha: bubbleAlpha),
        border: Border(top: BorderSide(color: EmberColors.stroke)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: chat.characterIds.map((id) {
            final c = chat.characterSnapshots[id] ?? store.characterById(id);
            final isSelected = id == selectedId;
            return Padding(
              padding: const EdgeInsets.only(right: 6),
              child: GestureDetector(
                // Wave CY.18.44: no-op the tap when the chat is mid-
                // stream. We keep the chip visually in place so the
                // layout doesn't jump; just stop accepting changes
                // until the in-flight turn finishes.
                onTap: disabled ? null : () => onChanged(id),
                child: Opacity(
                  opacity: disabled ? 0.55 : 1.0,
                  child: Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: isSelected
                        ? EmberColors.primary.withValues(alpha: 0.22)
                        : EmberColors.bgPanel,
                    borderRadius: BorderRadius.circular(999),
                    border: Border.all(
                      color: isSelected
                          ? EmberColors.primary
                          : EmberColors.stroke,
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      AvatarBubble(
                        dataUrl: c?.avatar,
                        fallback: c?.name ?? '?',
                        radius: 11,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        c?.name ?? '?',
                        style: TextStyle(
                          fontSize: 12,
                          color: isSelected
                              ? EmberColors.textHigh
                              : EmberColors.textMid,
                          fontWeight: isSelected
                              ? FontWeight.w600
                              : FontWeight.w500,
                        ),
                      ),
                    ],
                  ),
                ),    // closes Container
                ),    // Wave CY.18.44: closes Opacity wrapper
              ),     // closes GestureDetector
            );      // closes Padding
          }).toList(),
        ),
      ),
    );
  }
}

class _InputBar extends StatelessWidget {
  final TextEditingController controller;
  final FocusNode? focusNode;
  final bool generating;
  final VoidCallback onSend;
  final VoidCallback onStop;
  final VoidCallback onImpersonate;
  final VoidCallback onAddOOC;
  // liveoaktripper request: a one-tap "system note" insert (the `/sys`
  // command as a button). NULLABLE + gated: only passed (non-null) when
  // ChatSettings.systemNoteEnabled is on, so the item is HIDDEN by default
  // and the menu stays uncluttered (Gui: "quase ninguém vai usar").
  final VoidCallback? onAddSys;
  // Guide (Part 2): "Guide the reply" menu entry. Only surfaced when the
  // feature is enabled (callback non-null).
  final VoidCallback? onGuideReply;
  // "Guide my message" — the guided upgrade of Impersonate (outline +
  // perspective). DECOUPLED from one-tap "Impersonate me". Only surfaced when
  // the Guide feature is enabled (callback non-null).
  final VoidCallback? onGuideMessage;

  const _InputBar({
    required this.controller,
    this.focusNode,
    required this.generating,
    required this.onSend,
    required this.onStop,
    required this.onImpersonate,
    required this.onAddOOC,
    this.onAddSys,
    this.onGuideReply,
    this.onGuideMessage,
  });

  // Wave CY.15: kebab is now driven by [PopupMenuButton] which
  // handles positioning entirely on its own (anchored to the button,
  // flips above when there's no room below, accounts for keyboard
  // and safe area automatically). Previously we computed the position
  // by hand from the button's global rect — that math was fragile and
  // produced floating-in-middle-of-screen popups when the keyboard
  // was open AND in some no-keyboard layouts on certain device sizes.

  @override
  Widget build(BuildContext context) {
    final bubbleAlpha = context.watch<AppStore>().chatSettings.bubbleAlpha;
    return Container(
      decoration: BoxDecoration(
        // Match the bubble translucency so the input bar feels like part of
        // the same surface as the messages, not a wall below them.
        color: EmberColors.bgPanel.withValues(alpha: bubbleAlpha),
        border: Border(top: BorderSide(color: EmberColors.stroke)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            PopupMenuButton<String>(
              icon: Icon(Icons.more_vert,
                  color: EmberColors.textMid),
              tooltip: 'Guide / Impersonate / OOC / System',
              enabled: !generating,
              color: EmberColors.bgElevated,
              onSelected: (value) {
                if (value == 'guide') onGuideReply?.call();
                if (value == 'guidemsg') onGuideMessage?.call();
                if (value == 'impersonate') onImpersonate();
                if (value == 'ooc') onAddOOC();
                if (value == 'sys') onAddSys?.call();
              },
              itemBuilder: (_) => [
                // Guide (Part 2 — Action 1): arm a one-shot guide for the next
                // Send. Only present when the Guide feature is enabled.
                if (onGuideReply != null)
                  PopupMenuItem<String>(
                    value: 'guide',
                    child: Row(children: [
                      Icon(Icons.explore_outlined,
                          size: 16, color: EmberColors.textMid),
                      SizedBox(width: 10),
                      Text('Guide the reply'),
                    ]),
                  ),
                // "Guide my message" — guided Impersonate (outline +
                // perspective). Separate item from one-tap Impersonate below;
                // only present when the Guide feature is enabled.
                if (onGuideMessage != null)
                  PopupMenuItem<String>(
                    value: 'guidemsg',
                    child: Row(children: [
                      Icon(Icons.edit_note_outlined,
                          size: 16, color: EmberColors.textMid),
                      SizedBox(width: 10),
                      Text('Guide my message'),
                    ]),
                  ),
                PopupMenuItem<String>(
                  value: 'impersonate',
                  child: Row(children: [
                    Icon(Icons.person_outline,
                        size: 16, color: EmberColors.textMid),
                    SizedBox(width: 10),
                    Text('Impersonate me'),
                  ]),
                ),
                PopupMenuItem<String>(
                  value: 'ooc',
                  child: Row(children: [
                    Icon(Icons.chat_bubble_outline,
                        size: 16, color: EmberColors.textMid),
                    SizedBox(width: 10),
                    Text('Add OOC'),
                  ]),
                ),
                // liveoaktripper: surface the `/sys` command as a button — a
                // one-off system-role instruction. HIDDEN unless enabled in
                // Chat Settings → System note (then onAddSys is non-null).
                if (onAddSys != null)
                  PopupMenuItem<String>(
                    value: 'sys',
                    child: Row(children: [
                      Icon(Icons.smart_toy_outlined,
                          size: 16, color: EmberColors.textMid),
                      SizedBox(width: 10),
                      Text('Add system note'),
                    ]),
                  ),
              ],
            ),
            Expanded(
              // Wave CY.18.52: desktop Enter-to-send convention. On
              // Windows / Linux / macOS, a bare Enter sends the
              // message immediately (matches Discord, Slack, every
              // major chat app). Shift+Enter still inserts a
              // newline because CallbackShortcuts only catches the
              // exact SingleActivator pattern (no shift). On mobile
              // the wrapper is a pass-through and Enter behaves as
              // before (newline; tap send button to commit).
              child: CallbackShortcuts(
                bindings: _isDesktop
                    ? <ShortcutActivator, VoidCallback>{
                        const SingleActivator(LogicalKeyboardKey.enter):
                            () {
                          // Don't send mid-stream — onStop owns that
                          // case via the stop button. Empty input
                          // also no-ops (onSend should already guard
                          // but the shortcut shouldn't even fire a
                          // bunk send).
                          if (generating) return;
                          if (controller.text.trim().isEmpty) return;
                          onSend();
                        },
                      }
                    : const <ShortcutActivator, VoidCallback>{},
                child: TextField(
                  controller: controller,
                  focusNode: focusNode,
                  minLines: 1,
                  maxLines: 6,
                  // Wave CY.15: enable sentence-style autocap so the
                  // first letter after a period gets capitalised
                  // automatically — matches default Android keyboard
                  // behaviour that users expect everywhere else.
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    hintText: 'Enter your message…',
                    isDense: true,
                  ),
                  textInputAction: TextInputAction.newline,
                ),
              ),
            ),
            const SizedBox(width: 6),
            if (generating)
              IconButton.filled(
                onPressed: onStop,
                style: IconButton.styleFrom(
                  backgroundColor: EmberColors.danger,
                ),
                icon: const Icon(Icons.stop, color: Colors.white),
              )
            else
              IconButton.filled(
                onPressed: onSend,
                style: IconButton.styleFrom(
                  backgroundColor: EmberColors.primary,
                ),
                icon: const Icon(Icons.arrow_upward, color: Colors.white),
              ),
          ],
        ),
      ),
    );
  }
}

/// Inline warning above the chat input when the transcript has piled
/// up enough characters to start crowding common LLM context windows.
/// Soft warning at ~15k tokens, hard at ~30k. Hidden below that.
/// Long-term memory's auto-summarize covers the gap eventually, but
/// the user still needs to know mid-session that cost is climbing.
///
/// Wave CY.1: caches totalChars and only walks the messages list when
/// a cheap signature (n / last-variant-length / selected-variant)
/// changes. Without this, every streaming chunk on a 100-message chat
/// re-walked the entire list to add a handful of characters to the
/// last variant.
class _ChatSizeBanner extends StatefulWidget {
  final List<Message> messages;
  const _ChatSizeBanner({required this.messages});

  static const int _softThreshold = 60 * 1000;   // ~15k tokens
  static const int _hardThreshold = 120 * 1000;  // ~30k tokens

  @override
  State<_ChatSizeBanner> createState() => _ChatSizeBannerState();
}

class _ChatSizeBannerState extends State<_ChatSizeBanner> {
  int _cachedTotal = 0;
  String? _cachedSig;
  // Wave CY.17: auto-hide after ~10s of being shown. The banner is
  // a "heads-up" not a permanent label — users complained it stuck
  // forever once the chat passed 15k tokens, eating screen space.
  // Hidden state is per-mount: reopen chat → banner reappears (then
  // hides again after 10s). Re-shown if the chat crosses into the
  // hard threshold even after being dismissed (more urgent warning).
  bool _hiddenAfterTimeout = false;
  Timer? _hideTimer;
  bool _wasHard = false;

  void _scheduleHide() {
    _hideTimer?.cancel();
    _hideTimer = Timer(const Duration(seconds: 10), () {
      if (!mounted) return;
      setState(() => _hiddenAfterTimeout = true);
    });
  }

  @override
  void dispose() {
    _hideTimer?.cancel();
    super.dispose();
  }

  String _signature() {
    final msgs = widget.messages;
    if (msgs.isEmpty) return '0';
    final last = msgs.last;
    final lastLen = (last.variants.isNotEmpty &&
            last.selectedVariant >= 0 &&
            last.selectedVariant < last.variants.length)
        ? last.variants[last.selectedVariant].length
        : 0;
    return '${msgs.length}|$lastLen|${last.selectedVariant}';
  }

  int _computeTotal() {
    var totalChars = 0;
    for (final m in widget.messages) {
      // Sum the selected variant only — that's what the LLM sees on
      // the next turn. Other variants live on the side and don't
      // contribute to per-turn context cost.
      if (m.variants.isNotEmpty &&
          m.selectedVariant >= 0 &&
          m.selectedVariant < m.variants.length) {
        totalChars += m.variants[m.selectedVariant].length;
      }
    }
    return totalChars;
  }

  @override
  Widget build(BuildContext context) {
    final sig = _signature();
    if (sig != _cachedSig) {
      _cachedTotal = _computeTotal();
      _cachedSig = sig;
    }
    final totalChars = _cachedTotal;
    if (totalChars < _ChatSizeBanner._softThreshold) {
      // Below threshold — reset hidden state so a future cross
      // re-arms the heads-up.
      if (_hiddenAfterTimeout || _hideTimer != null) {
        _hiddenAfterTimeout = false;
        _hideTimer?.cancel();
        _hideTimer = null;
        _wasHard = false;
      }
      return const SizedBox.shrink();
    }
    final hard = totalChars >= _ChatSizeBanner._hardThreshold;
    // First time over threshold → arm the 10s auto-hide. Re-arm when
    // the chat crosses from soft into hard (more urgent message).
    if (_hideTimer == null && !_hiddenAfterTimeout) {
      _scheduleHide();
      _wasHard = hard;
    } else if (hard && !_wasHard) {
      // Promoted to hard threshold — show the banner again briefly.
      _hiddenAfterTimeout = false;
      _scheduleHide();
      _wasHard = true;
    }
    if (_hiddenAfterTimeout) return const SizedBox.shrink();
    final tokens = (totalChars / 4).round();
    final tokenLabel = tokens < 1000
        ? '$tokens'
        : '${(tokens / 1000).toStringAsFixed(tokens < 10000 ? 1 : 0)}k';
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: (hard ? EmberColors.danger : Color(0xFFE9A35A))
            .withValues(alpha: 0.12),
        border: Border(
          top: BorderSide(
            color: (hard ? EmberColors.danger : Color(0xFFE9A35A))
                .withValues(alpha: 0.35),
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      child: Row(
        children: [
          Icon(
            hard ? Icons.error_outline : Icons.warning_amber_outlined,
            color: hard ? EmberColors.danger : Color(0xFFE9A35A),
            size: 14,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hard
                  ? 'Chat ~$tokenLabel tokens — many models will reject this. Consider trimming old messages or starting a new chat.'
                  : 'Chat ~$tokenLabel tokens — Checkpoints will summarise soon, but cost-per-turn climbs from here.',
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

/// Guide (Part 2 — Action 1): the dismissible "armed guide" cue rendered
/// directly above the input bar. Shows the user that a one-shot guide is
/// armed for their next Send and lets them cancel it (✕). The guide string is
/// owned by the chat-screen State (`_armedGuide`) — this widget is purely a
/// display + cancel affordance; it never touches the chat model.
class _ArmedGuideChip extends StatelessWidget {
  final String guide;
  final VoidCallback onCancel;
  const _ArmedGuideChip({required this.guide, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: EmberColors.primary.withValues(alpha: 0.12),
        border: Border(
          top: BorderSide(
            color: EmberColors.primary.withValues(alpha: 0.35),
          ),
        ),
      ),
      padding: const EdgeInsets.fromLTRB(14, 6, 6, 6),
      child: Row(
        children: [
          Icon(Icons.explore_outlined,
              color: EmberColors.primary, size: 14),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Guiding next reply: $guide',
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: EmberColors.textHigh,
                fontSize: 11,
                height: 1.3,
              ),
            ),
          ),
          IconButton(
            onPressed: onCancel,
            tooltip: 'Cancel guide',
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            icon: Icon(Icons.close, color: EmberColors.textMid),
          ),
        ],
      ),
    );
  }
}

// Wave CY.18.12: _BranchBreadcrumb removed entirely. It floated a
// "Branch from msg N" chip at the top of the chat whenever the
// current path diverged from main, but the chat tree + per-message
// variant arrows already conveyed branch state, and the rename
// dialog was opt-in so the chip stayed anonymous in practice.
// Net visual noise. `Chat.branchNames` was removed from the data
// model in the same wave — see models/models.dart.

/// Wave CY.18: thin inline divider rendered between message bubbles
/// whenever a memory checkpoint anchors at that position on the
/// current branch. The Material icon mirrors the "Memory" tile in the
/// More menu so the affordance reads as a continuation of that flow.
/// Tapping pushes the full Memory screen so the user can read / retry
/// / delete the checkpoint(s).
class _CheckpointDivider extends StatelessWidget {
  final VoidCallback onTap;
  const _CheckpointDivider({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          child: Row(
            children: [
              Expanded(
                child: Divider(
                  color: EmberColors.stroke,
                  thickness: 1,
                  endIndent: 8,
                ),
              ),
              Icon(Icons.psychology_outlined,
                  size: 14, color: EmberColors.primary),
              const SizedBox(width: 6),
              Text(
                'Checkpoint',
                style: TextStyle(
                  color: EmberColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              Expanded(
                child: Divider(
                  color: EmberColors.stroke,
                  thickness: 1,
                  indent: 8,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
