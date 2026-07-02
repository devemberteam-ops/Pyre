// E (#131): in-app viewer for the opt-in LLM diagnostics log. The log
// (see llm_debug_log.dart) captures every real LLM request + response as
// JSONL, tagged per feature, key-free. Before this screen it was export-only
// (Storage → Developer → "Export logs"); this makes it readable in-app so the
// user (or a helper) can see EXACTLY what Pyre sent and got back without
// leaving the app. Read-only over the same files the export/copy/clear
// actions already manage.

import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;

import '../services/llm_debug_log.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';

class LlmDebugLogViewerScreen extends StatefulWidget {
  /// Test seam: the raw-JSONL loader. Defaults to reading the on-disk log
  /// (`LlmDebugLog.instance.readAll`). Widget tests inject a stub that returns
  /// a canned string synchronously — real `dart:io` futures never complete
  /// under `pumpAndSettle`'s fake-async clock, so the production reader can't
  /// be driven directly in a widget test.
  final Future<String> Function()? loadRaw;

  const LlmDebugLogViewerScreen({super.key, this.loadRaw});

  @override
  State<LlmDebugLogViewerScreen> createState() =>
      _LlmDebugLogViewerScreenState();
}

class _LlmDebugLogViewerScreenState extends State<LlmDebugLogViewerScreen> {
  bool _loading = true;
  List<LlmLogEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() => _loading = true);
    final raw = await (widget.loadRaw ?? LlmDebugLog.instance.readAll)();
    if (!mounted) return;
    setState(() {
      _entries = parseLlmLog(raw);
      _loading = false;
    });
  }

  Future<void> _copyAll() async {
    final messenger = ScaffoldMessenger.of(context);
    final bytes = await LlmDebugLog.instance.copyToClipboard();
    if (!mounted) return;
    messenger.showSnackBar(
      SnackBar(
        content: Text(bytes == 0
            ? 'Nothing logged yet.'
            : 'Copied $bytes B of diagnostics to clipboard.'),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Future<void> _clear() async {
    final messenger = ScaffoldMessenger.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: const Text('Clear diagnostics log?'),
        content: const Text(
            'Deletes every captured request/response on this device. This '
            "can't be undone."),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    await LlmDebugLog.instance.clear();
    if (!mounted) return;
    messenger.showSnackBar(
      const SnackBar(content: Text('Diagnostics log cleared.')),
    );
    await _load();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('LLM diagnostics'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            icon: const Icon(Icons.refresh),
            onPressed: _loading ? null : _load,
          ),
          if (_entries.isNotEmpty) ...[
            IconButton(
              tooltip: 'Copy all',
              icon: const Icon(Icons.copy_all_outlined),
              onPressed: _copyAll,
            ),
            IconButton(
              tooltip: 'Clear',
              icon: const Icon(Icons.delete_sweep_outlined),
              onPressed: _clear,
            ),
          ],
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _entries.isEmpty
              ? Padding(
                  padding: const EdgeInsets.all(24),
                  child: EmptyState(
                    icon: Icons.bug_report_outlined,
                    title: 'No diagnostics yet',
                    subtitle:
                        'Turn on "Log raw LLM calls" in Storage → Developer, '
                        'reproduce the issue, then come back here to see '
                        'exactly what Pyre sent and got back.',
                  ),
                )
              : ListView.separated(
                  padding: const EdgeInsets.fromLTRB(12, 12, 12, 24),
                  itemCount: _entries.length,
                  separatorBuilder: (_, _) => const SizedBox(height: 8),
                  itemBuilder: (_, i) {
                    final e = _entries[i];
                    return e.isTrace
                        ? _TraceRow(entry: e)
                        : _CallTile(entry: e);
                  },
                ),
    );
  }
}

/// Feature → accent colour so the eye can group calls by pipeline at a glance.
Color _featureColor(String feature) {
  switch (feature) {
    case 'chat':
      return EmberColors.primary;
    case 'ltm':
      return const Color(0xFF7E9CD8);
    case 'livesheet':
      return const Color(0xFF98BB6C);
    case 'creator-architect':
    case 'creator-vision':
      return const Color(0xFFD8A657);
    case 'scene':
      return const Color(0xFFC77DBB);
    default:
      return EmberColors.textMid;
  }
}

String _formatTs(int ms) {
  if (ms <= 0) return '';
  final d = DateTime.fromMillisecondsSinceEpoch(ms);
  String two(int n) => n.toString().padLeft(2, '0');
  return '${d.year}-${two(d.month)}-${two(d.day)} '
      '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
}

String _formatDuration(int ms) {
  if (ms <= 0) return '';
  if (ms < 1000) return '${ms}ms';
  return '${(ms / 1000).toStringAsFixed(ms < 10000 ? 2 : 1)}s';
}

class _TraceRow extends StatelessWidget {
  final LlmLogEntry entry;
  const _TraceRow({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: EmberColors.textMid.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.chevron_right, size: 16, color: EmberColors.textMid),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              entry.trace ?? '',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.35,
              ),
            ),
          ),
          if (entry.ts > 0)
            Text(
              _formatTs(entry.ts).split(' ').last,
              style: TextStyle(
                color: EmberColors.textMid.withValues(alpha: 0.7),
                fontSize: 10,
              ),
            ),
        ],
      ),
    );
  }
}

class _CallTile extends StatelessWidget {
  final LlmLogEntry entry;
  const _CallTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    final c = entry.call!;
    final color = _featureColor(c.feature);
    final snippet = c.response.trim().replaceAll('\n', ' ');
    return Material(
      color: EmberColors.bgPanel,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute(builder: (_) => _CallDetailScreen(record: c)),
        ),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: color.withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      c.feature.isEmpty ? 'call' : c.feature,
                      style: TextStyle(
                        color: color,
                        fontSize: 11,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${c.provider} · ${c.model}',
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: EmberColors.textHigh,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                  if (c.durationMs > 0)
                    Text(
                      _formatDuration(c.durationMs),
                      style: TextStyle(
                          color: EmberColors.textMid, fontSize: 11),
                    ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                snippet.isEmpty ? '(empty response)' : snippet,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: snippet.isEmpty
                      ? EmberColors.textMid
                      : EmberColors.textMid,
                  fontSize: 12,
                  height: 1.35,
                  fontStyle: snippet.isEmpty ? FontStyle.italic : null,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  Text(
                    _formatTs(entry.ts),
                    style: TextStyle(
                      color: EmberColors.textMid.withValues(alpha: 0.7),
                      fontSize: 10,
                    ),
                  ),
                  const Spacer(),
                  if (c.finishReason != null && c.finishReason!.isNotEmpty)
                    Text(
                      c.finishReason!,
                      style: TextStyle(
                        color: c.finishReason == 'length'
                            ? const Color(0xFFE0A54B)
                            : EmberColors.textMid.withValues(alpha: 0.7),
                        fontSize: 10,
                      ),
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _CallDetailScreen extends StatelessWidget {
  final LlmCallRecord record;
  const _CallDetailScreen({required this.record});

  static const _pretty = JsonEncoder.withIndent('  ');

  String get _fullText {
    final buf = StringBuffer()
      ..writeln('feature: ${record.feature}')
      ..writeln('provider: ${record.provider}')
      ..writeln('model: ${record.model}')
      ..writeln('time: ${_formatTs(record.ts)}')
      ..writeln('duration: ${_formatDuration(record.durationMs)}');
    if (record.finishReason != null) {
      buf.writeln('finishReason: ${record.finishReason}');
    }
    if (record.parseOutcome != null) {
      buf.writeln('parseOutcome: ${record.parseOutcome}');
    }
    buf
      ..writeln()
      ..writeln('=== MESSAGES ===')
      ..writeln(_safe(record.messages))
      ..writeln()
      ..writeln('=== SAMPLING ===')
      ..writeln(_safe(record.sampling))
      ..writeln()
      ..writeln('=== RESPONSE ===')
      ..writeln(record.response);
    return buf.toString();
  }

  static String _safe(Object? o) {
    try {
      return _pretty.convert(o);
    } catch (_) {
      return '$o';
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _featureColor(record.feature);
    return Scaffold(
      appBar: AppBar(
        title: Text(record.feature.isEmpty ? 'Call' : record.feature),
        actions: [
          IconButton(
            tooltip: 'Copy all',
            icon: const Icon(Icons.copy_all_outlined),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: _fullText));
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(
                  content: Text('Copied this call to clipboard.'),
                  duration: Duration(seconds: 2),
                ),
              );
            },
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              _MetaChip(label: record.feature, color: color),
              _MetaChip(
                  label: '${record.provider} · ${record.model}',
                  color: EmberColors.textMid),
              if (record.durationMs > 0)
                _MetaChip(
                    label: _formatDuration(record.durationMs),
                    color: EmberColors.textMid),
              if (record.finishReason != null &&
                  record.finishReason!.isNotEmpty)
                _MetaChip(
                    label: 'finish: ${record.finishReason}',
                    color: record.finishReason == 'length'
                        ? const Color(0xFFE0A54B)
                        : EmberColors.textMid),
            ],
          ),
          if (_formatTs(record.ts).isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(_formatTs(record.ts),
                  style:
                      TextStyle(color: EmberColors.textMid, fontSize: 12)),
            ),
          if (record.parseOutcome != null && record.parseOutcome!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('parse: ${record.parseOutcome}',
                  style:
                      TextStyle(color: EmberColors.textMid, fontSize: 12)),
            ),
          const SizedBox(height: 16),
          _Section(title: 'Request messages', body: _safe(record.messages)),
          const SizedBox(height: 12),
          _Section(title: 'Sampling', body: _safe(record.sampling)),
          const SizedBox(height: 12),
          _Section(
            title: 'Response',
            body: record.response.isEmpty ? '(empty)' : record.response,
          ),
        ],
      ),
    );
  }
}

class _MetaChip extends StatelessWidget {
  final String label;
  final Color color;
  const _MetaChip({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
            color: color, fontSize: 11, fontWeight: FontWeight.w600),
      ),
    );
  }
}

class _Section extends StatelessWidget {
  final String title;
  final String body;
  const _Section({required this.title, required this.body});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              title,
              style: TextStyle(
                color: EmberColors.textHigh,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const Spacer(),
            IconButton(
              tooltip: 'Copy',
              visualDensity: VisualDensity.compact,
              icon: Icon(Icons.copy_outlined,
                  size: 16, color: EmberColors.textMid),
              onPressed: () {
                Clipboard.setData(ClipboardData(text: body));
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('Copied $title.'),
                    duration: const Duration(seconds: 2),
                  ),
                );
              },
            ),
          ],
        ),
        const SizedBox(height: 4),
        Container(
          width: double.infinity,
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: EmberColors.bgPanel,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: EmberColors.stroke),
          ),
          child: SelectableText(
            body,
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              fontFamily: 'monospace',
              height: 1.4,
            ),
          ),
        ),
      ],
    );
  }
}
