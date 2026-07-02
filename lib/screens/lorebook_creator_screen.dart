// Wave CY.18.122 (Lorebook Creator, Wave 2): per-entry AI lorebook builder.
//
// A chat-driven screen that iterates "chat about one topic → architect
// emits [[BUILD_ENTRY]] + JSON → map to LoreEntry → save → loop".
//
// This is a FRESH minimal chat shell — it does NOT import or touch
// character_assistant_screen.dart. It mirrors the architect-streaming
// pattern (streamChatCompletion + creatorProvider + keepalive), but built
// cleanly for this use-case.
//
// OWNED FILES: this file only.
// CONSUMED (not modified): lorebook_architect_prompts, lorebook_entry_schema,
//   lorebook_entry_build, creator_json, chat_api, generation_keepalive,
//   theme, models, app_store.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, TextInputAction;
import 'package:provider/provider.dart';
import 'package:syncfusion_flutter_pdf/pdf.dart';

import '../models/models.dart';
import '../services/chat_api.dart'
    show
        ChatApiError,
        ChatTurn,
        pyreDroppedFramesRegex,
        pyreFinishSentinelRegex,
        streamChatCompletion;
import '../services/creator_json.dart' show extractJsonObject;
import '../services/generation_keepalive.dart';
import '../services/image_describe.dart' show encodeImageDataUrl;
import '../services/image_resize.dart' show downscaleIfNeeded;
import '../services/lorebook_architect_prompts.dart';
import '../services/lorebook_entry_schema.dart' show entryJsonToLoreEntry;
import '../services/png_parser.dart'
    show CharaCard, parseCharaCardJson, parseCharaCardPng;
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/chat_text.dart';

// ─────────────────────────────────────────────────────────────────────────────
// Pure helper: reply → draft extraction (extracted so tests can hit it directly
// without a Flutter widget pump).
// ─────────────────────────────────────────────────────────────────────────────

/// The structured data from a [[BUILD_ENTRY]] reply, or null if the JSON
/// could not be extracted.
class EntryDraft {
  final LoreEntry entry;

  /// The `comment` label from the JSON, if the model emitted one.
  final String? comment;

  EntryDraft({required this.entry, this.comment});
}

/// Extract an [EntryDraft] from an architect reply that contains
/// [[BUILD_ENTRY]] + a JSON object.
///
/// Returns null if no parseable JSON object is found.
/// Pure and unit-testable — no Flutter / store dependencies.
EntryDraft? extractEntryDraftFromReply(String raw) {
  final drafts = extractEntryDraftsFromReply(raw);
  return drafts.isEmpty ? null : drafts.first;
}

/// Extract every [EntryDraft] from a modern `{"entries":[...]}` reply.
///
/// The old standalone creator still previews one draft at a time, so
/// [extractEntryDraftFromReply] remains as the first-entry compatibility
/// wrapper. Embedded Creator builds use this list form so a model that emits
/// five entries after one marker does not silently lose four of them.
List<EntryDraft> extractEntryDraftsFromReply(String raw) {
  final json = extractJsonObject(stripLorebookStreamArtifacts(raw));
  if (json == null) return const <EntryDraft>[];
  final rawEntries = json['entries'];
  if (rawEntries is List) {
    final drafts = <EntryDraft>[];
    for (final rawEntry in rawEntries) {
      if (rawEntry is! Map) continue;
      final entryJson = rawEntry.cast<String, dynamic>();
      final entry = entryJsonToLoreEntry(entryJson);
      if (entry.keys.isEmpty && entry.content.trim().isEmpty) continue;
      drafts.add(
        EntryDraft(
          entry: entry,
          comment: entryJson['comment'] is String
              ? entryJson['comment'] as String
              : null,
        ),
      );
    }
    return drafts;
  }
  final comment = json['comment'] is String ? json['comment'] as String : null;
  final entry = entryJsonToLoreEntry(json);
  if (entry.keys.isEmpty && entry.content.trim().isEmpty) {
    return const <EntryDraft>[];
  }
  return [EntryDraft(entry: entry, comment: comment)];
}

/// Remove Pyre's internal stream sentinels before rendering or parsing a
/// lorebook-creator reply. Keeps `<think>` blocks intact; [ChatText] hides them
/// for display, while the parser can still recover JSON if a model placed it
/// near reasoning text.
String stripLorebookStreamArtifacts(String raw) => raw
    .replaceAll(pyreFinishSentinelRegex, '')
    .replaceAll(pyreDroppedFramesRegex, '');

String lorebookCreatorDisplayText(String raw) =>
    stripBuildEntryMarker(stripLorebookStreamArtifacts(raw)).trim();

// ─────────────────────────────────────────────────────────────────────────────
// Screen
// ─────────────────────────────────────────────────────────────────────────────

/// A chat-driven lorebook entry builder.
///
/// [targetBook] — an existing [Lorebook] to append entries to.
///   When null, a new lorebook is created on the FIRST save (using the name
///   supplied at construction or a default "AI Lorebook" fallback).
///
/// [initialBookName] — pre-filled book name when [targetBook] is null.
///   The user can still rename the book later via the normal lorebook editor.
///
/// [onBookCreated] — optional callback fired ONCE when a new lorebook is
///   created on first save (i.e. when [targetBook] was null). The caller
///   receives the new book's id so it can bind it to a character/persona.
///   Not called when [targetBook] was already provided.
///
/// [createHidden] — when true, the new lorebook is created with
///   [Lorebook.hidden] = true (card-only/embedded, decluttered from the
///   Lorebooks list). Default false (shared/reusable). Only takes effect
///   when [targetBook] is null (a new book is being created).
class LorebookCreatorScreen extends StatefulWidget {
  final Lorebook? targetBook;
  final String? initialBookName;

  /// Fired once when a NEW lorebook is created on first-entry save.
  /// Pass null to ignore (standalone entry points).
  final void Function(String newBookId)? onBookCreated;

  /// Whether the newly created book should be hidden (embedded/card-only).
  /// Ignored when [targetBook] is already provided.
  final bool createHidden;

  const LorebookCreatorScreen({
    super.key,
    this.targetBook,
    this.initialBookName,
    this.onBookCreated,
    this.createHidden = false,
  });

  @override
  State<LorebookCreatorScreen> createState() => _LorebookCreatorScreenState();
}

// One chat message in our minimal chat shell.
class _Msg {
  final String role; // 'system' | 'user' | 'assistant'
  String content;
  bool isError;
  List<CreatorAttachment> attachments;
  _Msg(
    this.role,
    this.content, {
    this.isError = false,
    List<CreatorAttachment>? attachments,
  }) : attachments = attachments ?? <CreatorAttachment>[];

  _Msg copy() => _Msg(
    role,
    content,
    isError: isError,
    attachments: [
      for (final a in attachments)
        CreatorAttachment(
          kind: a.kind,
          filename: a.filename,
          imageDataUrl: a.imageDataUrl,
          extracted: a.extracted,
        ),
    ],
  );
}

class _PendingAttachment {
  final String kind; // 'image' | 'card' | 'doc'
  final String filename;
  Uint8List? imageBytes;
  String? extracted;
  Future<void>? analysing;
  String? error;

  _PendingAttachment({
    required this.kind,
    required this.filename,
    this.imageBytes,
    this.extracted,
  });
}

class _RetrySnapshot {
  final List<_Msg> messages;
  final EntryDraft? draft;
  final String? draftKeys;
  final String? draftContent;
  final bool draftConstant;

  _RetrySnapshot({
    required this.messages,
    required this.draft,
    required this.draftKeys,
    required this.draftContent,
    required this.draftConstant,
  });
}

class _LorebookCreatorScreenState extends State<LorebookCreatorScreen> {
  static const int _kLorebookMaxTokensFloor = 32768;

  // ── State ──────────────────────────────────────────────────────────────────

  final List<_Msg> _msgs = [];
  final TextEditingController _inputCtl = TextEditingController();
  final ScrollController _scrollCtl = ScrollController();
  final List<_PendingAttachment> _pendingAttachments = [];

  // The resolved target book (null until first save when targetBook==null).
  Lorebook? _book;

  // The in-progress assistant streaming message.
  _Msg? _streamingMsg;

  bool _generating = false;
  String _streamBuffer = '';
  int _streamGen = 0;
  StreamSubscription<String>? _streamSub;
  int _keepAliveHeld = 0;

  static const int _bigFileThreshold = 200 * 1000;

  // Draft panel: populated when a [[BUILD_ENTRY]] is detected in the reply.
  EntryDraft? _draft;
  // Editable controllers for the draft panel.
  TextEditingController? _draftKeysCtl;
  TextEditingController? _draftContentCtl;
  bool _draftConstant = false;

  // Creator-parity affordance: retry restores the conversation/draft state to
  // just before the last model call and reruns it, instead of making the user
  // manually delete a bad architect turn.
  _RetrySnapshot? _lastRetry;

  // ── Lifecycle ──────────────────────────────────────────────────────────────

  @override
  void initState() {
    super.initState();
    _book = widget.targetBook;
    // Seed the system turn (not shown in the UI — only in the turn list).
    _msgs.add(_Msg('system', kLorebookEntryArchitectPrompt));
    // Post the architect's opening greeting right away.
    WidgetsBinding.instance.addPostFrameCallback((_) => _sendGreeting());
  }

  @override
  void dispose() {
    _streamSub?.cancel();
    // Drain any held keep-alives so the foreground service doesn't orphan.
    for (var i = 0; i < _keepAliveHeld; i++) {
      unawaited(GenerationKeepAlive.stop(heavy: true));
    }
    _keepAliveHeld = 0;
    _inputCtl.dispose();
    _scrollCtl.dispose();
    _draftKeysCtl?.dispose();
    _draftContentCtl?.dispose();
    super.dispose();
  }

  // ── Keep-alive ─────────────────────────────────────────────────────────────

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

  // ── Scroll ─────────────────────────────────────────────────────────────────

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollCtl.hasClients) {
        _scrollCtl.animateTo(
          _scrollCtl.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  // ── Desktop detection ──────────────────────────────────────────────────────

  bool get _isDesktop {
    switch (Theme.of(context).platform) {
      case TargetPlatform.windows:
      case TargetPlatform.linux:
      case TargetPlatform.macOS:
        return true;
      default:
        return false;
    }
  }

  // ── Build the turn list for the model (system + conversation) ──────────────

  List<ChatTurn> _buildTurns() {
    return [
      for (final m in _msgs)
        if (m.content.trim().isNotEmpty || m.attachments.isNotEmpty)
          ChatTurn(
            m.role == 'user'
                ? 'user'
                : m.role == 'assistant'
                ? 'assistant'
                : 'system',
            _composeTurnContent(m),
            imageDataUrls: [
              for (final a in m.attachments)
                if (a.kind == 'image' && a.imageDataUrl != null)
                  a.imageDataUrl!,
            ],
          ),
    ];
  }

  String _composeTurnContent(_Msg m) {
    final content = m.role == 'assistant'
        ? ChatText.stripReasoningStrict(m.content)
        : m.content;
    if (m.attachments.isEmpty) return content;
    final blocks = <String>[];
    for (final a in m.attachments) {
      if (a.extracted.trim().isNotEmpty) {
        blocks.add(a.extracted.trim());
      } else if (a.kind == 'image') {
        blocks.add(
          'Reference image `${a.filename}` attached. Treat visual details as '
          'authoritative context for the lorebook entry being designed.',
        );
      }
    }
    if (content.trim().isNotEmpty) blocks.add(content.trim());
    return blocks.join('\n\n');
  }

  // ── Streaming ──────────────────────────────────────────────────────────────

  /// Send the architect's opening greeting (user doesn't type this — we
  /// kick it off as the first model turn with an invisible trigger user message).
  Future<void> _sendGreeting() async {
    if (!mounted) return;
    final store = context.read<AppStore>();
    final bookName = _book?.name ?? widget.initialBookName ?? 'AI Lorebook';
    // Invisible trigger so the model introduces itself.
    final triggerMsg = _Msg(
      'user',
      'Hi! I want to build a lorebook called "$bookName". '
          'Please greet me briefly and ask what the first entry should cover.',
    );
    _msgs.add(triggerMsg);
    await _stream(store);
  }

  /// Send a user message from the input bar.
  Future<void> _sendUserMessage(AppStore store) async {
    final text = _inputCtl.text.trim();
    if ((text.isEmpty && _pendingAttachments.isEmpty) || _generating) return;
    final pending = List<_PendingAttachment>.from(_pendingAttachments);
    for (final p in pending) {
      if (p.analysing != null) await p.analysing;
    }
    if (!mounted) return;
    _inputCtl.clear();

    // Detect deterministic /entry command — inject a build trigger turn.
    final isBuildCmd = isBuildEntryCommand(text);
    final attachments = pending
        .map(
          (p) => CreatorAttachment(
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
          ),
        )
        .toList();
    final userMsg = _Msg(
      'user',
      isBuildCmd ? '/entry' : text,
      attachments: attachments,
    );
    setState(() {
      _pendingAttachments.clear();
      _msgs.add(userMsg);
    });
    _scrollToBottom();
    await _stream(store);
  }

  Future<void> _stream(AppStore store) async {
    if (!mounted) return;

    final provider = store.creatorProvider;
    if (provider == null) {
      setState(() {
        _msgs.add(
          _Msg(
            'assistant',
            '⚠ No provider configured. Go to More → API Connections to add one.',
            isError: true,
          ),
        );
      });
      _scrollToBottom();
      return;
    }

    // Creator sampling settings (creatorTemperature + creatorMaxTokens).
    // Match the main Creator's upper range so reasoning models do not spend
    // the whole reply budget before emitting the entry JSON.
    final maxTokens =
        store.modelSettings.creatorMaxTokens < _kLorebookMaxTokensFloor
        ? _kLorebookMaxTokensFloor
        : store.modelSettings.creatorMaxTokens;
    final settings = ModelSettings.fromJson(store.modelSettings.toJson())
      ..temperature = store.modelSettings.creatorTemperature
      ..maxTokens = maxTokens;

    final turns = _buildTurns();
    _lastRetry = _captureRetrySnapshot();

    // Streaming message placeholder.
    final reply = _Msg('assistant', '');
    setState(() {
      _generating = true;
      _streamBuffer = '';
      _streamingMsg = reply;
      _msgs.add(reply);
    });
    _scrollToBottom();

    await _keepAliveStart();

    final myGen = ++_streamGen;

    try {
      _streamSub =
          streamChatCompletion(
            provider: provider,
            settings: settings,
            messages: turns,
            preset: null,
            debugTag: 'lorebook-creator',
          ).listen(
            (chunk) {
              if (!mounted || myGen != _streamGen) return;
              _streamBuffer += chunk;
              // Strip the marker from DISPLAY; keep it in _streamBuffer for detection.
              setState(() {
                reply.content = lorebookCreatorDisplayText(_streamBuffer);
              });
              _scrollToBottom();
            },
            onError: (Object e) {
              if (!mounted || myGen != _streamGen) return;
              final errMsg = e is ChatApiError ? e.message : e.toString();
              setState(() {
                _generating = false;
                _streamingMsg = null;
                reply.content = '⚠ Error: $errMsg';
                reply.isError = true;
              });
              _keepAliveStop();
              _scrollToBottom();
            },
            onDone: () async {
              if (!mounted || myGen != _streamGen) return;

              final markerPresent = hasBuildEntryMarker(_streamBuffer);
              final displayText = lorebookCreatorDisplayText(_streamBuffer);

              setState(() {
                _generating = false;
                _streamingMsg = null;
                reply.content = displayText.isEmpty
                    ? '⚠ The model returned an empty response. Try again, or '
                          'switch the creator provider in More → API Connections.'
                    : displayText;
              });
              _keepAliveStop();
              _scrollToBottom();

              // If the marker fired, extract the draft panel.
              if (markerPresent) {
                await _processBuildEntry(_streamBuffer, store);
              }
            },
          );
    } on ChatApiError catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _streamingMsg = null;
        reply.content = '⚠ Error: ${e.message}';
        reply.isError = true;
      });
      _keepAliveStop();
      _scrollToBottom();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _generating = false;
        _streamingMsg = null;
        reply.content = '⚠ Error: $e';
        reply.isError = true;
      });
      _keepAliveStop();
      _scrollToBottom();
    }
  }

  // ── Entry extraction ────────────────────────────────────────────────────────

  Future<void> _processBuildEntry(String raw, AppStore store) async {
    final draft = extractEntryDraftFromReply(raw);
    if (draft == null) {
      // Extraction failed — post a gentle inline notice (not a dialog).
      if (!mounted) return;
      setState(() {
        _msgs.add(
          _Msg(
            'assistant',
            "I couldn't read the entry draft from that reply — the JSON may have been malformed. "
                'Just ask me to try again, or type /entry to re-trigger the build.',
            isError: true,
          ),
        );
      });
      _scrollToBottom();
      return;
    }
    // Populate the editable draft panel.
    _draftKeysCtl?.dispose();
    _draftContentCtl?.dispose();
    setState(() {
      _draft = draft;
      _draftKeysCtl = TextEditingController(text: draft.entry.keys.join(', '));
      _draftContentCtl = TextEditingController(text: draft.entry.content);
      _draftConstant = draft.entry.constant;
    });
  }

  // ── Save draft entry ────────────────────────────────────────────────────────

  Future<void> _saveDraft(AppStore store) async {
    if (_draft == null) return;

    // Collect user-edited values.
    final keys = (_draftKeysCtl?.text ?? '')
        .split(',')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final content = _draftContentCtl?.text ?? '';
    final constant = _draftConstant;

    // Build a fresh LoreEntry from the draft with any edits applied.
    final entry = LoreEntry(
      id: _draft!.entry.id, // keep the id assigned by entryJsonToLoreEntry
      keys: keys,
      content: content,
      constant: constant,
    );

    // If no target book yet, create one now.
    if (_book == null) {
      final bookName = widget.initialBookName?.trim().isNotEmpty == true
          ? widget.initialBookName!
          : 'AI Lorebook';
      final book = Lorebook(
        id: newId('lore'),
        name: bookName,
        hidden: widget.createHidden,
      );
      store.addLorebook(book);
      setState(() => _book = book);
      // Notify the caller so they can bind this book to their entity.
      widget.onBookCreated?.call(book.id);
    }

    // Append the entry.
    final book = _book!;
    book.entries.add(entry);
    store.updateLorebook(book);

    // Determine a display label for the confirmation.
    final label = entry.keys.isNotEmpty ? entry.keys.first : 'entry';

    // Clear the draft panel.
    _draftKeysCtl?.dispose();
    _draftContentCtl?.dispose();
    setState(() {
      _draft = null;
      _draftKeysCtl = null;
      _draftContentCtl = null;
      _draftConstant = false;
      _lastRetry = null;
    });

    // Post an inline confirmation and invite the next topic.
    final confirmMsg = _Msg(
      'assistant',
      'Saved "$label" to "${book.name}". '
          'What should the next entry cover?',
    );
    setState(() => _msgs.add(confirmMsg));
    _scrollToBottom();
  }

  // ── Stop ───────────────────────────────────────────────────────────────────

  void _stop() {
    _streamSub?.cancel();
    _streamSub = null;
    _streamGen++; // stale callbacks no-op
    if (_generating) {
      final streaming = _streamingMsg;
      setState(() {
        _generating = false;
        _streamingMsg = null;
        if (streaming != null && streaming.content.isEmpty) {
          _msgs.remove(streaming);
        }
      });
    }
    _keepAliveStop();
  }

  Future<void> _attachImage() async {
    if (_generating) return;
    final messenger = ScaffoldMessenger.of(context);
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
          // Best-effort only. If downscale fails, send the original bytes.
        } finally {
          pending.analysing = null;
          if (mounted) setState(() {});
        }
      }();
      pending.analysing = downscaleFut;
      setState(() => _pendingAttachments.add(pending));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Attach failed: $e')));
    }
  }

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
        messenger.showSnackBar(
          SnackBar(content: Text('Not a valid chara_card_v2 file: $e')),
        );
        return;
      }
      final pretty = const JsonEncoder.withIndent('  ').convert(card.raw);
      final extracted =
          'Reference character/scenario card `${f.name}` attached. Treat its '
          'world, cast, style, and existing character_book/lore as '
          'authoritative context for the lorebook entry being designed:\n\n'
          '```json\n$pretty\n```';
      if (!await _confirmLargeAttachment(extracted, 'reference card')) return;
      setState(() {
        _pendingAttachments.add(
          _PendingAttachment(
            kind: 'card',
            filename: f.name,
            extracted: extracted,
          ),
        );
      });
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Attach failed: $e')));
    }
  }

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
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('Could not parse the PDF: $e')),
          );
          return;
        }
        if (content.trim().isEmpty) {
          messenger.showSnackBar(
            const SnackBar(
              content: Text(
                'PDF appears to be image-only. Paste the relevant text as a .txt or .md instead.',
              ),
              duration: Duration(seconds: 6),
            ),
          );
          return;
        }
      } else {
        try {
          content = utf8.decode(bytes);
        } catch (e) {
          messenger.showSnackBar(
            SnackBar(content: Text('File is not valid UTF-8 text: $e')),
          );
          return;
        }
      }
      final extracted =
          'Reference document `${f.name}` attached. Treat it as authoritative '
          'source material for the lorebook entry being designed:\n\n'
          '```\n$content\n```';
      if (!await _confirmLargeAttachment(extracted, 'reference document')) {
        return;
      }
      setState(() {
        _pendingAttachments.add(
          _PendingAttachment(
            kind: 'doc',
            filename: f.name,
            extracted: extracted,
          ),
        );
      });
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Attach failed: $e')));
    }
  }

  Future<bool> _confirmLargeAttachment(String extracted, String label) async {
    if (extracted.length <= _bigFileThreshold || !mounted) return true;
    return confirmDelete(
      context,
      title: 'Big $label',
      message:
          'This $label is ${(extracted.length / 1000).toStringAsFixed(0)}k chars '
          '(~${(extracted.length / 4 / 1000).toStringAsFixed(0)}k tokens). '
          'Some models may reject the request. Pyre never truncates the full '
          'content. Continue?',
      confirmLabel: 'Attach',
      cancelLabel: 'Cancel',
    );
  }

  void _removePending(_PendingAttachment a) {
    setState(() => _pendingAttachments.remove(a));
  }

  _RetrySnapshot _captureRetrySnapshot() {
    return _RetrySnapshot(
      messages: [for (final m in _msgs) m.copy()],
      draft: _draft,
      draftKeys: _draftKeysCtl?.text,
      draftContent: _draftContentCtl?.text,
      draftConstant: _draftConstant,
    );
  }

  Future<void> _retryLastTurn(AppStore store) async {
    final snap = _lastRetry;
    if (snap == null || _generating) return;
    _stop();
    _draftKeysCtl?.dispose();
    _draftContentCtl?.dispose();
    setState(() {
      _msgs
        ..clear()
        ..addAll([for (final m in snap.messages) m.copy()]);
      _draft = snap.draft;
      _draftKeysCtl = snap.draftKeys == null
          ? null
          : TextEditingController(text: snap.draftKeys);
      _draftContentCtl = snap.draftContent == null
          ? null
          : TextEditingController(text: snap.draftContent);
      _draftConstant = snap.draftConstant;
      _streamingMsg = null;
      _streamBuffer = '';
    });
    _scrollToBottom();
    await _stream(store);
  }

  // ── UI ─────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final book = _book ?? widget.targetBook;
    final bookName = book?.name ?? widget.initialBookName ?? 'AI Lorebook';
    final entryCount = book?.entries.length ?? 0;

    return Scaffold(
      backgroundColor: EmberColors.bgDeep,
      appBar: AppBar(
        backgroundColor: EmberColors.bgPanel,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Lorebook Creator',
              style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 16),
            ),
            Text(
              '$entryCount entr${entryCount == 1 ? "y" : "ies"} in $bookName',
              style: TextStyle(
                fontSize: 12,
                color: EmberColors.textMid,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        actions: [
          if (!_generating && _lastRetry != null)
            IconButton(
              icon: Icon(Icons.replay_outlined, color: EmberColors.primary),
              tooltip: 'Retry last turn',
              onPressed: () => _retryLastTurn(store),
            ),
          if (_generating)
            IconButton(
              icon: Icon(
                Icons.stop_circle_outlined,
                color: EmberColors.primary,
              ),
              tooltip: 'Stop',
              onPressed: _stop,
            ),
        ],
      ),
      body: Column(
        children: [
          // ── Chat ─────────────────────────────────────────────────────────
          Expanded(child: _buildChatList()),
          // ── Draft panel (appears when [[BUILD_ENTRY]] fires) ─────────────
          if (_draft != null) _buildDraftPanel(store),
          // ── Input bar ────────────────────────────────────────────────────
          _buildInputBar(store),
        ],
      ),
    );
  }

  Widget _buildChatList() {
    // Filter out the system prompt — never shown.
    final visible = _msgs.where((m) => m.role != 'system').toList();
    if (visible.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    return ListView.builder(
      controller: _scrollCtl,
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
      itemCount: visible.length,
      itemBuilder: (context, i) {
        final msg = visible[i];
        return _buildBubble(msg);
      },
    );
  }

  Widget _buildBubble(_Msg msg) {
    final isUser = msg.role == 'user';
    final isStreaming = msg == _streamingMsg;
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: isUser
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          if (!isUser) ...[
            CircleAvatar(
              radius: 14,
              backgroundColor: EmberColors.primary.withValues(alpha: 0.2),
              child: Icon(
                Icons.auto_awesome,
                size: 14,
                color: EmberColors.primary,
              ),
            ),
            const SizedBox(width: 8),
          ],
          Flexible(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              decoration: BoxDecoration(
                color: isUser
                    ? EmberColors.primary.withValues(alpha: 0.15)
                    : EmberColors.bgPanel,
                borderRadius: BorderRadius.only(
                  topLeft: const Radius.circular(14),
                  topRight: const Radius.circular(14),
                  bottomLeft: isUser
                      ? const Radius.circular(14)
                      : const Radius.circular(4),
                  bottomRight: isUser
                      ? const Radius.circular(4)
                      : const Radius.circular(14),
                ),
                border: msg.isError
                    ? Border.all(
                        color: EmberColors.danger.withValues(alpha: 0.5),
                      )
                    : null,
              ),
              child: isStreaming && msg.content.isEmpty
                  ? Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        SizedBox(
                          width: 14,
                          height: 14,
                          child: CircularProgressIndicator(
                            strokeWidth: 1.5,
                            color: EmberColors.primary,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Generating…',
                          style: TextStyle(color: EmberColors.textDim),
                        ),
                      ],
                    )
                  : Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (msg.attachments.isNotEmpty) ...[
                          _SentAttachmentRow(attachments: msg.attachments),
                          if (msg.content.trim().isNotEmpty)
                            const SizedBox(height: 8),
                        ],
                        if (msg.content.trim().isNotEmpty)
                          ChatText(
                            msg.content,
                            baseStyle: TextStyle(
                              color: msg.isError
                                  ? EmberColors.danger
                                  : EmberColors.textHigh,
                              fontSize: 14,
                            ),
                          ),
                      ],
                    ),
            ),
          ),
          if (isUser) ...[
            const SizedBox(width: 8),
            CircleAvatar(
              radius: 14,
              backgroundColor: EmberColors.primary.withValues(alpha: 0.25),
              child: Icon(Icons.person, size: 14, color: EmberColors.primary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildDraftPanel(AppStore store) {
    if (_draft == null || _draftKeysCtl == null || _draftContentCtl == null) {
      return const SizedBox.shrink();
    }
    final comment = _draft!.comment;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      decoration: BoxDecoration(
        color: EmberColors.bgPanel,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: EmberColors.primary.withValues(alpha: 0.4),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          // Header
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 4),
            child: Row(
              children: [
                Icon(
                  Icons.library_books_outlined,
                  size: 16,
                  color: EmberColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  'Entry draft',
                  style: TextStyle(
                    color: EmberColors.primary,
                    fontWeight: FontWeight.w600,
                    fontSize: 13,
                  ),
                ),
                if (comment != null && comment.isNotEmpty) ...[
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      '· $comment',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 11,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
          // Fields
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: TextField(
              controller: _draftKeysCtl,
              minLines: 1,
              maxLines: 3,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Trigger keywords',
                helperText: 'Comma-separated',
                labelStyle: TextStyle(color: EmberColors.textMid, fontSize: 12),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 4),
            child: TextField(
              controller: _draftContentCtl,
              minLines: 3,
              maxLines: 8,
              style: const TextStyle(fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Content to inject',
                labelStyle: TextStyle(color: EmberColors.textMid, fontSize: 12),
                isDense: true,
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(6, 0, 14, 2),
            child: StatefulBuilder(
              builder: (ctx, setLocal) => Material(
                type: MaterialType.transparency,
                child: CheckboxListTile(
                  title: const Text(
                    'Always inject (constant)',
                    style: TextStyle(fontSize: 13),
                  ),
                  value: _draftConstant,
                  dense: true,
                  activeColor: EmberColors.primary,
                  contentPadding: const EdgeInsets.only(left: 8),
                  onChanged: (v) => setState(() => _draftConstant = v ?? false),
                ),
              ),
            ),
          ),
          // Save button
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 12),
            child: SizedBox(
              width: double.infinity,
              child: ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: EmberColors.primary,
                  foregroundColor: Colors.white,
                ),
                icon: const Icon(Icons.save_outlined, size: 18),
                label: Text(
                  _book == null ? 'Save to new lorebook' : 'Save to lorebook',
                ),
                onPressed: () => _saveDraft(store),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInputBar(AppStore store) {
    return SafeArea(
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 6, 8, 8),
        decoration: BoxDecoration(
          color: EmberColors.bgPanel,
          border: Border(
            top: BorderSide(color: EmberColors.stroke, width: 0.5),
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingAttachments.isNotEmpty)
              _PendingChipsRow(
                pending: _pendingAttachments,
                onRemove: _removePending,
              ),
            Row(
              children: [
                PopupMenuButton<String>(
                  tooltip: 'Attach',
                  icon: Icon(
                    Icons.add_circle_outline,
                    color: EmberColors.textMid,
                    size: 26,
                  ),
                  enabled: !_generating,
                  onSelected: (v) {
                    switch (v) {
                      case 'image':
                        _attachImage();
                        break;
                      case 'card':
                        _attachCard();
                        break;
                      case 'doc':
                        _attachDocument();
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
                  child: _isDesktop
                      ? CallbackShortcuts(
                          bindings: {
                            const SingleActivator(
                              LogicalKeyboardKey.enter,
                            ): () {
                              if (!_generating &&
                                  (_inputCtl.text.trim().isNotEmpty ||
                                      _pendingAttachments.isNotEmpty)) {
                                _sendUserMessage(store);
                              }
                            },
                          },
                          child: _inputField(store),
                        )
                      : _inputField(store),
                ),
                const SizedBox(width: 6),
                _generating
                    ? IconButton(
                        icon: Icon(
                          Icons.stop_circle_outlined,
                          color: EmberColors.primary,
                        ),
                        tooltip: 'Stop',
                        onPressed: _stop,
                      )
                    : IconButton(
                        icon: Icon(Icons.send, color: EmberColors.primary),
                        tooltip: 'Send',
                        onPressed:
                            (_inputCtl.text.trim().isNotEmpty ||
                                _pendingAttachments.isNotEmpty)
                            ? () => _sendUserMessage(store)
                            : null,
                      ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _inputField(AppStore store) {
    return TextField(
      controller: _inputCtl,
      minLines: 1,
      maxLines: 5,
      textInputAction: _isDesktop
          ? TextInputAction.newline
          : TextInputAction.newline,
      enabled: !_generating,
      decoration: InputDecoration(
        hintText: 'Describe a topic, attach references, or type /entry…',
        hintStyle: TextStyle(color: EmberColors.textDim, fontSize: 14),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: EmberColors.stroke),
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(10),
          borderSide: BorderSide(color: EmberColors.stroke),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
        isDense: true,
      ),
      onChanged: (_) => setState(() {}), // refresh send button enabled state
    );
  }
}

class _PendingChipsRow extends StatelessWidget {
  final List<_PendingAttachment> pending;
  final void Function(_PendingAttachment) onRemove;
  const _PendingChipsRow({required this.pending, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(0, 0, 0, 8),
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

class _PendingChip extends StatelessWidget {
  final _PendingAttachment item;
  final VoidCallback onRemove;
  const _PendingChip({required this.item, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    final isImage = item.kind == 'image' && item.imageBytes != null;
    return Container(
      decoration: BoxDecoration(
        color: EmberColors.bgDeep,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: item.error != null ? EmberColors.danger : EmberColors.stroke,
        ),
      ),
      child: Stack(
        clipBehavior: Clip.none,
        children: [
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
                  errorBuilder: (_, _, _) => Icon(
                    Icons.broken_image_outlined,
                    color: EmberColors.textDim,
                  ),
                ),
              ),
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
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
                      style: TextStyle(
                        color: EmberColors.textHigh,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
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
                          EmberColors.primary,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          Positioned(
            right: -6,
            top: -6,
            child: Material(
              color: EmberColors.bgPanel,
              shape: CircleBorder(side: BorderSide(color: EmberColors.stroke)),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onRemove,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(
                    Icons.close,
                    size: 12,
                    color: EmberColors.textMid,
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _SentAttachmentRow extends StatelessWidget {
  final List<CreatorAttachment> attachments;
  const _SentAttachmentRow({required this.attachments});

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final a in attachments)
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5),
            decoration: BoxDecoration(
              color: EmberColors.bgDeep.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: EmberColors.stroke),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  a.kind == 'image'
                      ? Icons.image_outlined
                      : a.kind == 'card'
                      ? Icons.badge_outlined
                      : Icons.description_outlined,
                  size: 14,
                  color: EmberColors.textMid,
                ),
                const SizedBox(width: 5),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 150),
                  child: Text(
                    a.filename,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: EmberColors.textMid, fontSize: 11),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
