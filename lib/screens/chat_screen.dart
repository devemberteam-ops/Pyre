import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:ui' show ImageFilter;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import 'package:share_plus/share_plus.dart';

import '../models/models.dart';
import '../services/chat_api.dart';
import '../services/chat_export.dart';
import '../services/chat_prompt_builder.dart';
import '../services/refusal_detector.dart';
import '../services/generation_keepalive.dart';
import '../services/lorebook_inject.dart';
import '../services/live_sheet.dart' as lsheet;
import '../services/memory.dart' as ltm;
import '../services/regex_rules.dart';
import '../services/scene_background.dart' as scenebg;
import '../services/story_roadmap.dart' as roadmap;
import '../services/token_estimate.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/avatar.dart';
import '../widgets/lightbox.dart';
import '../widgets/chat_text.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/fallback_prompt_card.dart';
import 'character_details_sheet.dart';
import 'chat_info_sheet.dart';
import 'chat_picker_screens.dart';
import 'chat_tree_screen.dart';
import 'customize_chat_sheet.dart';
import 'group_lorebooks_sheet.dart';
import 'live_sheet_screen.dart';
import 'memory_screen.dart';
import 'script_screen.dart';

/// Wave CY.18.50: true on Windows / Linux / macOS desktop builds. Used
/// to gate hover-only reveals (action toolbars on message bubbles)
/// that don't make sense on touch devices.
bool get _isDesktop {
  if (kIsWeb) return false;
  return Platform.isWindows || Platform.isLinux || Platform.isMacOS;
}

// kExplicitNoPersonaId is declared in models.dart (canonical location).

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
        return persona?.avatar ?? character?.avatar;
      case ChatBackgroundSource.characterAvatar:
        return character?.avatar;
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
    _streamSub?.cancel();
    _scrollCtl.removeListener(_onScroll);
    _scrollCtl.dispose();
    _inputCtl.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  /// Branch a user message: stash the current downstream under the source
  /// variant, add an empty variant, focus the input. Non-destructive —
  /// swiping back to the original variant restores its conversation tail.
  void _branchUserMessage(Chat chat, Message m) {
    // Never branch while a stream is in flight — the in-progress assistant
    // reply would be silently destroyed (we'd remove the message the
    // stream is writing into) and the rest of the response would land in
    // a dead bubble until onDone fires.
    if (_generating) return;
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
    // Wave CY.17: full-screen picker with search. Old bottom sheet
    // capped at 70% screen height and had no filter — unusable past
    // 10+ personas.
    final store = context.read<AppStore>();
    final current = _chatPersona(store, chat);
    final picked = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        builder: (_) => PersonaPickerScreen(
          title: 'Persona for this chat',
          subtitle: 'Only affects this chat. The global default '
              'persona in More → Personas is untouched.',
          selectedPersonaId: current?.id,
        ),
      ),
    );
    if (picked == null) return;
    if (picked == pickerNoPersonaSentinel) {
      store.setChatPersona(chat.id, kExplicitNoPersonaId);
    } else {
      store.setChatPersona(chat.id, picked);
    }
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
    // Pick the responder — explicit override, else primary
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
        characterId: character?.id,
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
    final turns = _buildTurns(store, chat);
    // Wave BM: foreground-service keep-alive so the OS doesn't kill
    // Pyre while the LLM streams (especially the slow first-token wait
    // on reasoning models). Matching stop() in onDone / failure paths.
    await GenerationKeepAlive.start();
    try {
      // Audit C2: cancel any prior subscription before re-arming. The
      // fallback retry path can reach here while an earlier stream for
      // this screen is technically still open (e.g. the user abandoned
      // a slow stream via the card); without this the old subscription
      // leaks and races the new one, writing into a stale slot.
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
          );
          _scrollToBottom();
        },
        // Wave CY.18.99: infra failures route to the fallback handler
        // (offers a switch when a candidate remains + toggle on),
        // falling through to the old snackbar otherwise.
        onError: (e) => _handleGenerationFailure(
          chatId: chat.id,
          assistantId: assistantId,
          error: e,
        ),
        onDone: () {
          unawaited(GenerationKeepAlive.stop());
          if (!mounted) return;
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
      unawaited(GenerationKeepAlive.stop());
      _handleGenerationFailure(
        chatId: chat.id,
        assistantId: assistantId,
        error: e,
      );
    }
  }

  /// Wave CY.18.99: infra-failure path. If another candidate remains and
  /// the toggle is on, show the infra fallback card instead of the plain
  /// error. Otherwise fall through to the existing snackbar+Retry UX.
  void _handleGenerationFailure({
    required String chatId,
    required String assistantId,
    required Object error,
  }) {
    unawaited(GenerationKeepAlive.stop());
    if (!mounted) return;
    final store = context.read<AppStore>();
    final hasNext = _fallbackIndex + 1 < _fallbackChain.length;
    final isApiError = error is ChatApiError;
    if (hasNext && isApiError && store.uiPrefs.askToSwitchOnFailure) {
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
    if (!eligible) {
      // Wave CY.18.173: run Live Sheet update AFTER the summariser resolves so
      // the two background LLM calls are serialised (never overlap on the same
      // provider). Wave CY.18.184: scene classifier chained after Live Sheet
      // (three background LLM calls serialised: summary → sheet → scene).
      _maybeAutoSummarize()
          .then((_) => _maybeAutoLiveSheetUpdate())
          .then((_) => _maybeUpdateSceneBackground());
      return;
    }
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
    // Wave CY.16: per-chat opt-out via the Memory menu. Manual
    // summarisation still works even when this is false (the
    // MemoryScreen "Summarise now" button bypasses the toggle) —
    // auto-trigger just respects it.
    if (!chat.memoryEnabled) return;
    if (!ltm.shouldSummarize(chat, memorySettings: store.memorySettings)) {
      return;
    }
    // Wave CY.18.6: prevent two summarisers running at once. The
    // summary call is long-running (often 10-30s); if the user sends
    // another message while it's in flight, the next onDone would
    // fire-and-forget a second summarise. Two parallel LLM calls to
    // the same provider can hit rate limits or, on proxies that
    // serialise requests per session, silently drop one — leaving
    // the user with a phantom "Generating…" on the chat reply.
    if (_summarising) return;
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
        // Wave CY.18.160: don't fail silently. generateCheckpoint returns
        // null when the LLM reply was empty / errored / offline — it
        // records the reason in MemoryErrors but, until now, the user got
        // ZERO feedback ("nothing fires at #25"). Surface the FIRST failure
        // per session as a transient SnackBar so the user knows it tried
        // and can act (switch provider, check Memory). Suppressed after the
        // first so a down provider doesn't snackbar-spam every message.
        if (!_autoSummariseFailureShown && mounted) {
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
      // A success clears the "shown" latch so a genuine LATER failure (e.g.
      // the provider goes down after working) surfaces again.
      _autoSummariseFailureShown = false;
      ltm.applyCheckpoint(chat, ckpt);
      store.notifyAndPersist();
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
        if (!_liveSheetFailureShown && mounted && lsheet.LiveSheetErrors.log.isNotEmpty) {
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
      store.notifyAndPersist();
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
        if (changed) store.notifyAndPersist();
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
        store.notifyAndPersist(); // persist the advanced watermarks
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
      store.notifyAndPersist();
    } finally {
      _sceneClassifying = false;
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


  void _finishWithError(String message, {Object? originalError}) {
    // Wave BM: belt-and-braces — drop keep-alive on any error path.
    // Safe to call even if start() was never reached.
    unawaited(GenerationKeepAlive.stop());
    if (!mounted) return;
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
        // Empty placeholder — drop it so the chat doesn't end with
        // a phantom assistant bubble. (deleteMessage handles the
        // case where the id no longer exists.)
        store.removeMessage(chat.id, _streamMessageId!);
      } else {
        // Partial — keep it (sentinels removed; <think> preserved for the
        // reasoning toggle). The user can read what was already generated;
        // the error info lives in the snackbar.
        store.updateMessageText(chat.id, _streamMessageId!, partial);
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
  List<ChatTurn> _buildTurns(AppStore store, Chat chat) {
    // Use the selected responder for the system prompt (so the right
    // character's voice is described). For >1 member chats, also include
    // a brief roster so the LLM knows the other personas in the scene.
    final responderId = _activeResponderId(chat);
    final character = responderId == null
        ? null
        : (chat.characterSnapshots[responderId] ??
            store.characterById(responderId));
    // Wave CX: honour chat.personaId, not the global default.
    final persona = _chatPersona(store, chat);
    final preset = store.activePreset;

    // Debug trace — visible in `flutter logs` while a generation runs.
    // Helps diagnose "why didn't my lorebook fire?" without inspecting
    // the prompt. One-line per fired entry plus a count summary. Mirrors
    // the same collect+scan the builder runs (pure functions, cheap), so
    // the trace reflects exactly what `buildChatPrompt` injected.
    final attached = collectBoundLorebooks(
      chat: chat,
      persona: persona,
      lookupBook: store.lorebookById,
      lookupCharacter: store.characterById,
      responderId: responderId,
    );
    final scan = scanLorebookHits(attached, chat.messages);
    if (scan.hits.isNotEmpty) {
      debugPrint(
          '[Lorebook] ${scan.hits.length}/${scan.totalScanned} '
          'entries fired this turn'
          '${scan.skippedDisabled > 0 ? " (${scan.skippedDisabled} disabled, skipped)" : ""}:');
      for (final t in scan.trace) {
        debugPrint('[Lorebook]   · $t');
      }
    } else if (attached.isNotEmpty) {
      debugPrint(
          '[Lorebook] no entries matched this turn '
          '(scanned ${scan.totalScanned} across ${attached.length} book(s))');
    }

    final inputs = ChatPromptInputs(
      chat: chat,
      character: character,
      persona: persona,
      preset: preset,
      responderId: responderId,
      beatsCap: store.scriptSettings.beatsCap,
      lookupCharacter: store.characterById,
      lookupBook: store.lorebookById,
      inFlightMessageId: _streamMessageId,
      regexRules: store.regexRules,
    );
    return buildChatPrompt(inputs).turns;
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
    _clearPendingFallback(); // audit C1
    // Wave CY.7: if the user tapped Stop BEFORE any tokens arrived,
    // the assistant message we pre-created is just dead UI (the
    // "Generating…" placeholder stayed forever). Remove it. If even
    // a byte arrived, keep the partial — the user might still want it.
    final store = context.read<AppStore>();
    final chat = _chat(store);
    final streamId = _streamMessageId;
    if (chat != null && streamId != null) {
      final idx = chat.messages.indexWhere((m) => m.id == streamId);
      // Strip <think> + Pyre sentinels before the emptiness test: a
      // reasoning-only / sentinel-only stop leaves text that LOOKS
      // non-empty (e.g. `<think>…</think>` or a bare finish-reason marker)
      // but renders as nothing, so it should be dropped as a phantom
      // bubble rather than kept.
      if (idx >= 0 &&
          stripStreamArtifacts(chat.messages[idx].text).trim().isEmpty) {
        store.removeMessage(chat.id, streamId, cascadeOverride: false);
      }
    }
    setState(() {
      _generating = false;
      _streamMessageId = null;
    });
    // The partial response is real text the user might want — flush so
    // it survives. (The debounce timer is still running otherwise.)
    store.flushPersist();
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
              subtitle: const Text(
                'Scenario change or your own opening message.',
                style:
                    TextStyle(color: EmberColors.textMid, fontSize: 12),
              ),
              onTap: () {
                Navigator.pop(sheet);
                _promptFillIn(chat);
              },
            ),
            // ── Memories ▸ ───────────────────────────────────────────
            Theme(
              data: Theme.of(context)
                  .copyWith(dividerColor: Colors.transparent),
              child: ExpansionTile(
                leading: const Icon(Icons.auto_awesome_motion,
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
                    onTap: () async {
                      Navigator.pop(sheet);
                      // Wave CY.18.5: chat tree returns the picked
                      // message id on pop. We scroll to that bubble so
                      // the user lands exactly where they tapped, not
                      // just on the right branch.
                      final targetId =
                          await Navigator.of(context).push<String>(
                        MaterialPageRoute(
                          builder: (_) =>
                              ChatTreeScreen(chatId: chat.id),
                        ),
                      );
                      if (!mounted ||
                          targetId == null ||
                          targetId.isEmpty) {
                        return;
                      }
                      // Give the rebuild triggered by the path-of-
                      // selectVariant calls one frame to settle before
                      // we measure offsets.
                      await Future<void>.delayed(
                          const Duration(milliseconds: 50));
                      if (!mounted) return;
                      _scrollToMessage(targetId);
                    },
                  ),
                  ListTile(
                    leading: const Icon(Icons.psychology_outlined),
                    title: const Text('Long-term Memory'),
                    subtitle: Builder(builder: (_) {
                      if (!chat.memoryEnabled) {
                        return const Text(
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
                        style: const TextStyle(
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
                          : 'Off — per-chat state tracking.',
                      style: const TextStyle(
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
                    leading: const Icon(Icons.map_outlined,
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
                leading: const Icon(Icons.more_horiz,
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
                  ListTile(
                    leading: const Icon(Icons.tune),
                    title: const Text('Customize chat'),
                    subtitle: const Text(
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
                    subtitle: const Text(
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
                      style: const TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      _showChatPersonaPicker(chat);
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
                    subtitle: const Text(
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
                    subtitle: const Text(
                      'Save as SillyTavern JSONL or full-fidelity Pyre JSON.',
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 12),
                    ),
                    onTap: () {
                      Navigator.pop(sheet);
                      _showExportChatSheet(chat, primary);
                    },
                  ),
                  const Divider(color: EmberColors.stroke),
                  ListTile(
                    leading: const Icon(Icons.delete_outline,
                        color: EmberColors.danger),
                    title: const Text('Delete chat',
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
              leading: const Icon(Icons.swap_horiz,
                  color: EmberColors.primary),
              title: const Text('SillyTavern JSONL'),
              subtitle: const Text(
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
              leading: const Icon(Icons.lock_outline,
                  color: EmberColors.primary),
              title: const Text('Pyre JSON (full fidelity)'),
              subtitle: const Text(
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
        await Clipboard.setData(ClipboardData(text: content));
        messenger.showSnackBar(SnackBar(
          content: Text(
              'Web: copied $ext to clipboard. Paste into a text editor and save.'),
        ));
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
      messenger.hideCurrentSnackBar();
      messenger.showSnackBar(SnackBar(
        content: Text('Exported — ${Uri.file(path).pathSegments.last}'),
        duration: const Duration(seconds: 4),
        action: SnackBarAction(
          label: 'Share',
          onPressed: () async {
            try {
              await Share.shareXFiles(
                [
                  XFile(path,
                      mimeType:
                          asSillyTavern ? 'application/x-ndjson' : 'application/json'),
                ],
                subject: 'Pyre chat — $characterName',
                text: asSillyTavern
                    ? 'SillyTavern-compatible chat export.'
                    : 'Full-fidelity Pyre chat backup.',
              );
            } catch (e) {
              messenger.showSnackBar(
                SnackBar(content: Text('Share failed: $e')),
              );
            }
          },
        ),
      ));
    } catch (e) {
      messenger.showSnackBar(
          SnackBar(content: Text('Export failed: $e')));
    }
  }

  Future<void> _showMessageMenu(Chat chat, Message m) async {
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    final isLast = chat.messages.isNotEmpty && chat.messages.last.id == m.id;
    final isChar = m.kind == MessageKind.char;
    final isUser = m.kind == MessageKind.user;

    await showModalBottomSheet<void>(
      context: context,
      backgroundColor: EmberColors.bgPanel,
      builder: (sheet) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isLast && (isChar || isUser))
              ListTile(
                leading: const Icon(Icons.play_arrow_rounded,
                    color: EmberColors.primary),
                title: const Text('Continue (extend this message)'),
                subtitle: isUser
                    ? const Text(
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
                leading: const Icon(Icons.refresh,
                    color: EmberColors.primary),
                title: const Text('Regenerate (new variant)'),
                onTap: () {
                  Navigator.pop(sheet);
                  _regenerateLast();
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
              subtitle: const Text(
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
            if (isUser || isChar) const Divider(color: EmberColors.stroke),
            // Label adapts to the active delete behaviour so the user
            // isn't blindsided when they have cascade-on and tap what
            // looks like a single-message delete.
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
                  // Cascade is destructive — confirm before nuking the
                  // tail of the conversation.
                  if (cascade) {
                    final ok = await confirmDelete(
                      context,
                      title: 'Delete this and all messages after?',
                      message:
                          'You\'ll lose this message and every reply that came after it.',
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
    await GenerationKeepAlive.start(); // Wave BM
    try {
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: turns,
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
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
          );
          _scrollToBottom();
        },
        // Wave CY.18.45: pass the raw error object so _finishWithError
        // can detect the typed ChatApiErrorKind (offline / timeout /
        // server) and render a friendly snackbar per kind.
        onError: (e) => _finishWithError(e.toString(), originalError: e),
        onDone: () {
          unawaited(GenerationKeepAlive.stop()); // Wave BM
          if (!mounted) return;
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          // Flush the debounced state — disk is idle now, save the final
          // text so a crash doesn't lose the just-generated variant.
          context.read<AppStore>().flushPersist();
        },
      );
    } catch (e) {
      unawaited(GenerationKeepAlive.stop()); // Wave BM
      _finishWithError(e.toString());
    }
  }

  /// Ask the model to draft a user message in the active persona's voice
  /// and STREAM it into the input field — the user watches it fill in
  /// real-time and can tweak before sending. Cancellable via the stop
  /// button while streaming.
  Future<void> _impersonateMe() async {
    if (_generating) return;
    _clearPendingFallback(); // audit C1
    final store = context.read<AppStore>();
    final chat = _chat(store);
    if (chat == null) return;
    final provider = store.activeProvider;
    if (provider == null) return;
    // Wave CX: honour chat.personaId (not the global default).
    final persona = _chatPersona(store, chat);
    final personaName = persona?.name ?? 'the user';
    final preset = store.activePreset;
    final turns = _buildTurns(store, chat);
    // Impersonation prompt — preset override if provided (ST presets define
    // it as `impersonation_prompt`), else our default.
    //
    // Wave CW: the previous default was too soft and went in as a tail
    // `system` turn — the model stayed in narrator/char role and kept
    // emitting NPC dialogue. New default is explicit about what's
    // allowed (user actions / thoughts / dialogue / sensations) and
    // what's NOT (NPC speech, world narration, scene advancement from
    // any other POV). Sent as a `user` turn with [OOC] prefix — RP
    // convention the model respects more reliably than tail systems.
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
    final impPrompt =
        (preset?.impersonationPrompt?.trim().isNotEmpty ?? false)
            ? preset!.impersonationPrompt!
                .replaceAll(
                  RegExp(r'\{\{user\}\}', caseSensitive: false),
                  personaName,
                )
                .replaceAll(
                  RegExp(r'\{\{char\}\}', caseSensitive: false),
                  speakerName,
                )
            : '[OOC: Drop out of narrator/character voice for ONE reply. '
                'Write the next message from $personaName\'s perspective '
                'only — what $personaName would type as their own '
                'character in this scene.\n\n'
                'ALLOWED in this reply:\n'
                '- $personaName\'s actions, gestures, body language\n'
                '- $personaName\'s thoughts and sensations\n'
                '- $personaName\'s dialogue\n\n'
                'FORBIDDEN in this reply:\n'
                '- ANY dialogue or action from ${speakerName.isNotEmpty ? speakerName : "the narrator"} or any NPC\n'
                '- World/scene narration of what other people do or '
                'how the environment reacts\n'
                '- Advancing the scene from anyone except $personaName\n'
                '- Prefixes like "$personaName:", "(impersonating)", or '
                'meta-commentary\n\n'
                'FORMATTING — match the chat\'s established pattern EXACTLY:\n\n'
                'GOOD example (this is the ONLY shape you produce):\n'
                '*She crosses her arms, eyes narrowing.*\n\n'
                '"You really expect me to believe that?"\n\n'
                '*Her foot taps once, twice, against the floorboard.*\n\n'
                'BAD examples (NEVER produce these):\n'
                '- "*She crosses her arms.* You really expect me to believe that? *Her foot taps.*"  ← asterisks engulfing dialogue\n'
                '- She crosses her arms, narrowing her eyes. "You really expect me to believe that?"  ← actions without asterisks\n'
                '- *She crosses her arms and says "You really expect me to believe that?"*  ← dialogue inside the asterisk block\n\n'
                'Rules pulled out:\n'
                '- EVERY spoken line is its own paragraph, wrapped in double quotes only — no asterisks around it.\n'
                '- Every action / body language / inner thought is its own paragraph, wrapped in *…* only — no dialogue inside the stars.\n'
                '- Blank line between every action paragraph and every dialogue paragraph. Alternating beats.\n'
                '- Keep it short — one to three of these blocks total.\n'
                '- Reply with the message body only, no preamble, no "[OOC: " framing.\n\n'
                'CRITICAL — no thinking out loud: output ONLY $personaName\'s '
                'in-character message. Do NOT write any analysis, planning, a '
                '"thinking process", numbered steps, or notes about these '
                'instructions — none of that may ever appear in your reply. '
                'Begin immediately with $personaName\'s first action or spoken '
                'line.$examplesNudge]';
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
    await GenerationKeepAlive.start(); // Wave BM
    try {
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
          unawaited(GenerationKeepAlive.stop()); // Wave BM
          if (mounted) {
            setState(() => _generating = false);
            messenger.showSnackBar(
              SnackBar(content: Text('Impersonate failed: $e')),
            );
          }
        },
        onDone: () {
          unawaited(GenerationKeepAlive.stop()); // Wave BM
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
          if (cleaned != _inputCtl.text) {
            _inputCtl.text = cleaned;
            _inputCtl.selection = TextSelection.collapsed(
              offset: cleaned.length,
            );
          }
          _inputFocus.requestFocus();
        },
      );
    } catch (e) {
      if (mounted) setState(() => _generating = false);
      messenger.showSnackBar(
        SnackBar(content: Text('Impersonate failed: $e')),
      );
    }
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
                  const Text(
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
                  const Text(
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
                          const TextStyle(color: EmberColors.textMid)),
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
                      final sys = StringBuffer();
                      if (responder != null) {
                        sys.writeln('You are ${responder.name}.');
                        if (responder.description.isNotEmpty) {
                          sys.writeln(
                              '\nDescription:\n${responder.description}');
                        }
                        if (responder.personality.isNotEmpty) {
                          sys.writeln(
                              '\nPersonality:\n${responder.personality}');
                        }
                      }
                      if (persona != null) {
                        sys.writeln(
                            '\nUser persona — ${persona.name}: ${persona.description}');
                        if (persona.dialogueExamples
                            .trim()
                            .isNotEmpty) {
                          sys.writeln(
                              '\n${persona.name}\'s dialogue examples:\n${persona.dialogueExamples.trim()}');
                        }
                      }
                      sys.writeln(
                          '\nWrite a fresh opening message — vivid, in-character, that begins with this scenario:\n\n$filled');
                      sys.writeln(
                          '\nUse *italics* for actions and "quotes" for dialogue. Output ONLY the opening message, no meta or explanation.');
                      Navigator.pop(ctx);
                      _streamFillInVariant(
                        chat,
                        responderId,
                        sys.toString().trim(),
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
    first.variants.add(text);
    first.selectedVariant = first.variants.length - 1;
    store.notifyAndPersist();
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

    // Wave CY.11 / CY.18.269: the scenario rides as an OOC turn so
    // `_buildTurns` re-sends it as `[OOC]: ...` every turn (it stays canon
    // instead of evaporating after the opener). BUT it must be BRANCH-SCOPED:
    // it belongs to the greeting variant this Fill-In creates. Inserting it at
    // index 0 (the old behaviour) put it BEFORE the branch point, so switching
    // to an alternate greeting left it behind — it leaked across every branch.
    // Built here, inserted AFTER the greeting once the variant exists, so it
    // lives in that variant's downstream tail and selectVariant owns it.
    final oocMsg = (scenarioForOoc != null && scenarioForOoc.trim().isNotEmpty)
        ? Message(
            id: newId('msg'),
            kind: MessageKind.ooc,
            variants: ['Scenario: ${scenarioForOoc.trim()}'],
          )
        : null;

    String firstId;
    int vIdx;
    final firstCharIdx = chat.messages
        .indexWhere((m) => m.kind == MessageKind.char);
    if (firstCharIdx < 0) {
      final m = Message(
        id: newId('msg'),
        kind: MessageKind.char,
        variants: [''],
        characterId: responderId,
      );
      store.addMessage(chat.id, m);
      firstId = m.id;
      vIdx = 0;
      // Empty chat: place the OOC right after the freshly-added greeting.
      if (oocMsg != null) {
        final gi = chat.messages.indexWhere((x) => x.id == m.id);
        if (gi >= 0) {
          chat.messages.insert(gi + 1, oocMsg);
          store.notifyAndPersist();
        }
      }
    } else {
      final firstChar = chat.messages[firstCharIdx];
      firstId = firstChar.id;
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
      // New empty variant is now selected → the OOC becomes its first
      // downstream message, so selectVariant's downstreamByVariant snapshot
      // owns it and switching greetings no longer leaks it across branches.
      if (oocMsg != null) {
        chat.messages.insert(firstCharIdx + 1, oocMsg);
        store.notifyAndPersist();
      }
    }
    _streamMessageId = firstId;
    _streamVariantIndex = vIdx;
    setState(() {
      _generating = true;
      _streamBuffer = '';
    });
    _scrollToBottom();
    await GenerationKeepAlive.start();
    final pinnedVariant = vIdx;
    try {
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: [
          ChatTurn('system', systemPrompt),
          ChatTurn('user', '[Begin the scene.]'),
        ],
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
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
          );
          _scrollToBottom();
        },
        // Wave CY.18.45: pass the raw error object so _finishWithError
        // can detect the typed ChatApiErrorKind (offline / timeout /
        // server) and render a friendly snackbar per kind.
        onError: (e) => _finishWithError(e.toString(), originalError: e),
        onDone: () {
          unawaited(GenerationKeepAlive.stop());
          if (!mounted) return;
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          context.read<AppStore>().flushPersist();
        },
      );
    } catch (e) {
      unawaited(GenerationKeepAlive.stop());
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
          store.notifyAndPersist();
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
  Future<void> _regenerateMessage(Chat chat, Message m) async {
    if (_generating) return;
    _clearPendingFallback(); // audit C1
    if (m.kind != MessageKind.char) return;
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
    final turns = _buildTurns(store, chat);
    final pinnedVariant = _streamVariantIndex;
    await GenerationKeepAlive.start(); // Wave BM
    try {
      _streamSub = streamChatCompletion(
        provider: provider,
        settings: store.modelSettings,
        preset: store.activePreset,
        messages: turns,
        debugTag: 'chat', // Wave CY.18.214 diagnostics tag
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
          );
          _scrollToBottom();
        },
        // Wave CY.18.45: pass the raw error object so _finishWithError
        // can detect the typed ChatApiErrorKind (offline / timeout /
        // server) and render a friendly snackbar per kind.
        onError: (e) => _finishWithError(e.toString(), originalError: e),
        onDone: () {
          unawaited(GenerationKeepAlive.stop()); // Wave BM
          if (!mounted) return;
          setState(() {
            _generating = false;
            _streamMessageId = null;
          });
          // Flush the debounced state — disk is idle now, save the final
          // text so a crash doesn't lose the just-generated variant.
          context.read<AppStore>().flushPersist();
        },
      );
    } catch (e) {
      unawaited(GenerationKeepAlive.stop()); // Wave BM
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
            AvatarBubble(
              dataUrl: character?.avatar,
              fallback: character?.name ?? '?',
              radius: 16,
              tappableLightbox: true,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    character?.name ?? 'Chat',
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
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
                      style: const TextStyle(
                        fontSize: 11,
                        color: EmberColors.textMid,
                        height: 1.2,
                      ),
                    ),
                ],
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
                ? const Center(
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
                      final speaker = m.characterId == null
                          ? character
                          : (chat.characterSnapshots[m.characterId!] ??
                              store.characterById(m.characterId!) ??
                              character);
                      final bubble = _MessageBubble(
                        message: m,
                        character: speaker,
                        chatSettings: settings,
                        persona: persona,
                        regexRules: store.regexRules,
                        messageIndex: i,
                        isStreaming: _streamMessageId == m.id,
                        showSpeakerName: chat.characterIds.length > 1,
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
                        // Every user message can be branched — same rewind
                        // semantics, but you also get an empty variant to
                        // type a different line.
                        onBranchUser: m.kind == MessageKind.user
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
                        child: inner,
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
                                      size: 14,
                                      color: EmberColors.primary),
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
                  ]),
          ),
          if (chat.characterIds.length > 1)
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
          _InputBar(
            controller: _inputCtl,
            focusNode: _inputFocus,
            generating: _generating,
            onSend: _send,
            onStop: _stop,
            onImpersonate: _impersonateMe,
            onAddOOC: () => _promptAuxAndAdd(chat, MessageKind.ooc, 'OOC'),
          ),
        ],
            ),
          ),
        ],
      ),
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

  const _MessageBubble({
    required this.message,
    required this.character,
    required this.isLast,
    required this.chatSettings,
    required this.persona,
    required this.regexRules,
    required this.messageIndex,
    this.isStreaming = false,
    this.showSpeakerName = false,
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
    final isUser = m.kind == MessageKind.user;
    final isAux = m.kind == MessageKind.ooc ||
        m.kind == MessageKind.scene ||
        m.kind == MessageKind.system;

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
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: EmberColors.bgElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: EmberColors.stroke),
            ),
            child: Text(
              // Wave CY.18.157: OOC/scene/system bubbles also substitute
              // {{user}}/{{char}} (the normal ChatText path already does) —
              // without this the placeholder rendered literally here, which
              // is exactly the bug Gui hit on an OOC scene-setup line.
              _fillNamePlaceholders(
                m.text,
                charName: widget.character?.name,
                personaName: widget.persona?.name,
              ),
              style: const TextStyle(
                color: EmberColors.textMid,
                fontStyle: FontStyle.italic,
                fontSize: 13,
              ),
              textAlign: TextAlign.center,
            ),
          ),
        ),
      );
    }

    final chatSettings = widget.chatSettings;
    final isEmptyVariant = m.text.isEmpty;

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
    final int? roleColorArgb =
        isUser ? chatSettings.userBubbleColor : chatSettings.aiBubbleColor;
    final Color bubbleBase =
        roleColorArgb != null ? Color(roleColorArgb) : EmberColors.bgPanel;
    final Color bubbleColor = isEmptyVariant
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
        : (isEmptyVariant
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
            minWidth: isEmptyVariant
                ? MediaQuery.of(context).size.width * 0.55
                : 0,
          ),
          child: isEmptyVariant
              ? Text(
                  isUser
                      ? 'Type your alternative reply…'
                      : 'Generating…',
                  style: const TextStyle(
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
                              style: const TextStyle(
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
                      : ChatText(
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
                          // byte-identical when no rules exist. Only
                          // normal user/AI bubbles reach here (aux
                          // bubbles return early above).
                          applyRegexRules(
                            _fillNamePlaceholders(
                              m.text,
                              charName: widget.character?.name,
                              personaName: widget.persona?.name,
                            ),
                            widget.regexRules,
                            stream: isUser
                                ? RegexStream.userInput
                                : RegexStream.aiOutput,
                            stage: RegexStage.display,
                          ),
                          hideReasoning: _reasoningOverride ??
                              chatSettings.hideReasoning,
                        ),
        ),
      ),
    );

    final persona = widget.persona;
    final avatar = isUser
        ? AvatarBubble(
            dataUrl: persona?.avatar,
            fallback: persona?.name ?? 'U',
            radius: 16,
            tappableLightbox: true,
          )
        : AvatarBubble(
            dataUrl: widget.character?.avatar,
            fallback: widget.character?.name ?? '?',
            radius: 16,
            tappableLightbox: true,
          );

    final variantCount = m.variants.length;
    final atLast = m.selectedVariant >= variantCount - 1;
    // The wiring (onRegenerate / onBranchUser) is what decides which
    // message gets the `+`. We don't gate by widget.isLast here — for the
    // user-branch case the latest user message often ISN'T the chat's
    // last message (the assistant reply sits below it).
    final canRegen = !isUser && widget.onRegenerate != null;
    // User messages get a `+` at the rightmost variant to BRANCH — re-roll
    // your own line. Tapping it freezes the current text as a variant and
    // gives you a blank one to write a new alternative.
    final canBranchUser = isUser && widget.onBranchUser != null;
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
        onPressed: () => widget.onSelectVariant!(m.selectedVariant - 1),
      );
    }

    // Right edge — `>` if there are forward variants to walk into, or `+`
    // on the last variant to add a new one (regen for char, branch for
    // user). Both share the same visibility gate as the left chevron:
    // tap the bubble to flash them on, they auto-hide after a few seconds.
    //
    // The `+` is suppressed on EMPTY variants — there's no point branching
    // a blank slot (the user hasn't even committed the current variant
    // yet) and it removes a confusing "create another empty" affordance.
    Widget? rightArrow() {
      if (!visible) return null;
      if (hasArrows && m.selectedVariant < variantCount - 1) {
        return _LateralChip(
          icon: Icons.chevron_right,
          onPressed: () =>
              widget.onSelectVariant!(m.selectedVariant + 1),
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
          style: const TextStyle(
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
    Widget? continuePill() => null;

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
        crossAxisAlignment:
            isUser ? CrossAxisAlignment.end : CrossAxisAlignment.start,
        children: [
          if (widget.showSpeakerName && !isUser && widget.character != null)
            Padding(
              padding: const EdgeInsets.only(left: 48, bottom: 4),
              child: Text(
                widget.character!.name,
                style: const TextStyle(
                  color: EmberColors.primary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.4,
                ),
              ),
            ),
          Row(
            mainAxisAlignment:
                isUser ? MainAxisAlignment.end : MainAxisAlignment.start,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: isUser
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
                left: isUser ? 0 : 48,
                right: isUser ? 48 : 0,
              ),
              child: variantCounter(),
            ),
          if (continuePill() != null) continuePill()!,
          // Footer row: assistant messages get token estimate + (optional)
          // per-message reasoning toggle + #N. User and aux messages get
          // just #N on their respective side. All hidden mid-stream and
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
                left: isUser ? 0 : (isAux ? 0 : 48),
                right: isUser ? 8 : 0,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.max,
                mainAxisAlignment: isUser
                    ? MainAxisAlignment.end
                    : (isAux
                        ? MainAxisAlignment.center
                        : MainAxisAlignment.start),
                children: [
                  if (!isUser && !isAux) ...[
                    Text(
                      formatApproxTokens(m.text) ?? '',
                      style: const TextStyle(
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
                                style: const TextStyle(
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
                    const Text(
                      '·',
                      style: TextStyle(
                          color: EmberColors.textDim, fontSize: 10),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Text(
                    '#${widget.messageIndex + 1}',
                    style: const TextStyle(
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
    return ClipRRect(
      borderRadius: borderRadius,
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: blurSigma, sigmaY: blurSigma),
        child: inner,
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
          style: const TextStyle(
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
            style: const TextStyle(
              fontFamily: 'monospace',
              color: EmberColors.primary,
              fontSize: 13,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              desc,
              style: const TextStyle(
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
        border: const Border(top: BorderSide(color: EmberColors.stroke)),
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

  const _InputBar({
    required this.controller,
    this.focusNode,
    required this.generating,
    required this.onSend,
    required this.onStop,
    required this.onImpersonate,
    required this.onAddOOC,
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
        border: const Border(top: BorderSide(color: EmberColors.stroke)),
      ),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      child: SafeArea(
        top: false,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_vert,
                  color: EmberColors.textMid),
              tooltip: 'Impersonate / OOC',
              enabled: !generating,
              color: EmberColors.bgElevated,
              onSelected: (value) {
                if (value == 'impersonate') onImpersonate();
                if (value == 'ooc') onAddOOC();
              },
              itemBuilder: (_) => const [
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
                  ? 'Chat ~$tokenLabel tokens — many models will reject this. Consider trimming old messages or starting a new chat.'
                  : 'Chat ~$tokenLabel tokens — long-term memory will summarise soon, but cost-per-turn climbs from here.',
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
              const Expanded(
                child: Divider(
                  color: EmberColors.stroke,
                  thickness: 1,
                  endIndent: 8,
                ),
              ),
              const Icon(Icons.psychology_outlined,
                  size: 14, color: EmberColors.primary),
              const SizedBox(width: 6),
              const Text(
                'Checkpoint',
                style: TextStyle(
                  color: EmberColors.primary,
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  letterSpacing: 0.3,
                ),
              ),
              const Expanded(
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
