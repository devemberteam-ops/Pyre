// Wave CY.18.176: Story Roadmap (Script) — pure functions, no LLM.
// Active beats are injected into the model context (later wave) with
// anti-rush framing so the AI builds toward them gradually.
import '../models/models.dart';

const _kRoadmapHeader =
    '--- Story roadmap (the writer\'s planned FUTURE developments — these have NOT happened yet) ---';
const _kRoadmapFraming =
    'Build these in GRADUALLY across many messages. Foreshadow and set up; '
    'advance at most a small step per reply, and only when the story organically '
    'reaches it. NEVER trigger a beat before the conditions written into it '
    '("when X happens…"), never resolve a whole beat in one reply, never collapse '
    'multiple beats together. You may hint at a beat obliquely, but do NOT state '
    'its SPECIFIC payload — the secret, the what, or the why — until that beat\'s '
    'written condition has actually been met in the story; keep the details '
    'withheld even if the conversation drifts toward the topic early. Anything '
    'already established in the story is done — keep it consistent, do not repeat '
    'or re-trigger it.';
const _kRoadmapFooter = '--- end roadmap ---';

/// Builds the context-injection block for active (non-done, non-blank) beats.
/// Returns an empty string when there is nothing to inject.
///
/// [beatsCap] — when > 0, only the FIRST [beatsCap] active beats are
/// included (controls context footprint when many beats have been queued).
/// 0 means unlimited.
String buildStoryRoadmapBlock(Chat chat, {int beatsCap = 0}) {
  var active = chat.storyBeats
      .where((b) => !b.done && b.text.trim().isNotEmpty)
      .toList();
  if (active.isEmpty) return '';
  if (beatsCap > 0 && active.length > beatsCap) {
    active = active.sublist(0, beatsCap);
  }
  final buf = StringBuffer();
  buf.writeln(_kRoadmapHeader);
  buf.writeln(_kRoadmapFraming);
  for (final b in active) {
    buf.writeln('- ${b.text.trim()}');
  }
  buf.write(_kRoadmapFooter);
  return buf.toString();
}

/// Appends a new active beat with [text] (trimmed) to [chat.storyBeats].
/// Returns the new [StoryBeat], or null if [text] is blank (no-op).
StoryBeat? appendStoryBeat(Chat chat, String text) {
  final trimmed = text.trim();
  if (trimmed.isEmpty) return null;
  final beat = StoryBeat(id: newId('beat'), text: trimmed);
  chat.storyBeats.add(beat);
  return beat;
}
