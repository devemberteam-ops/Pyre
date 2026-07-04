// Pure lorebook-entry draft extraction: architect reply → [EntryDraft]s.
//
// Extracted from the standalone LorebookCreatorScreen when that screen was
// removed (2026-07-03, owner decision — the main AI Creator's in-canvas
// lorebook mode superseded it). The Creator canvas is now the sole consumer;
// the logic stays pure and unit-testable (test/lorebook_creator_test.dart).

import '../models/models.dart';
import 'chat_api.dart' show pyreDroppedFramesRegex, pyreFinishSentinelRegex;
import 'creator_json.dart' show extractJsonObject;
import 'lorebook_architect_prompts.dart' show stripBuildEntryMarker;
import 'lorebook_entry_schema.dart' show entryJsonToLoreEntry;

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
/// A single bare-object reply still parses (first-entry compatibility);
/// the list form means a model that emits five entries after one marker
/// does not silently lose four of them.
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
/// lorebook-creator reply. Keeps `<think>` blocks intact; ChatText hides them
/// for display, while the parser can still recover JSON if a model placed it
/// near reasoning text.
String stripLorebookStreamArtifacts(String raw) => raw
    .replaceAll(pyreFinishSentinelRegex, '')
    .replaceAll(pyreDroppedFramesRegex, '');

String lorebookCreatorDisplayText(String raw) =>
    stripBuildEntryMarker(stripLorebookStreamArtifacts(raw)).trim();
