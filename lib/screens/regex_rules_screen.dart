// Pyre 1.1 (F4) — Regex (find/replace) management UI.
//
// A list of rules (enable/disable + edit + delete + add-new + import from a
// SillyTavern regex .json), and a full-screen editor with a LIVE TEST box so
// the user sees the effect of their rule immediately.
//
// All transformation is NON-DESTRUCTIVE — see services/regex_rules.dart. This
// screen only manages the rule list in AppStore.

import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/regex_rules.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';

class RegexRulesScreen extends StatelessWidget {
  const RegexRulesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final rules =
        store.regexRules.where((r) => !r.deleted).toList(growable: false);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Regex (find/replace)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Import from SillyTavern…',
            onPressed: () => _importStRegexFile(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New rule',
            onPressed: () => _openEditor(context, null),
          ),
        ],
      ),
      body: rules.isEmpty
          ? EmptyState(
              icon: Icons.find_replace,
              title: 'No regex rules yet',
              subtitle:
                  'Regex rules rewrite chat text on the fly — strip a model\'s '
                  'quirk, reformat names, or hide tokens. They are '
                  'non-destructive: your stored messages never change, and '
                  'toggling a rule off restores the original instantly.',
              ctaLabel: 'Create',
              ctaIcon: Icons.add,
              onCta: () => _openEditor(context, null),
            )
          : ListView.separated(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              itemCount: rules.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, i) {
                final r = rules[i];
                return Card(
                  child: ListTile(
                    leading: const Icon(Icons.find_replace,
                        color: EmberColors.textMid),
                    title: Text(
                      r.name.isEmpty ? '(unnamed rule)' : r.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    subtitle: Text(
                      _subtitleFor(r),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: EmberColors.textMid),
                    ),
                    onTap: () => _openEditor(context, r),
                    trailing: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Switch(
                          value: r.enabled,
                          onChanged: (v) {
                            final edited = r.clone()..enabled = v;
                            context.read<AppStore>().updateRegexRule(edited);
                          },
                        ),
                        PopupMenuButton<String>(
                          icon: const Icon(Icons.more_vert,
                              color: EmberColors.textMid),
                          onSelected: (choice) async {
                            if (choice == 'edit') {
                              _openEditor(context, r);
                            } else if (choice == 'delete') {
                              final ok = await confirmDelete(
                                context,
                                title: 'Delete rule?',
                                message:
                                    'Remove "${r.name}"? This only deletes the '
                                    'rule — your messages are untouched.',
                              );
                              if (ok && context.mounted) {
                                context.read<AppStore>().removeRegexRule(r.id);
                              }
                            }
                          },
                          itemBuilder: (_) => const [
                            PopupMenuItem(value: 'edit', child: Text('Edit')),
                            PopupMenuItem(
                                value: 'delete', child: Text('Delete')),
                          ],
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
    );
  }

  static String _subtitleFor(RegexRule r) {
    final streamBits = <String>[];
    if (r.streams.contains(RegexStream.userInput)) streamBits.add('User');
    if (r.streams.contains(RegexStream.aiOutput)) streamBits.add('AI');
    final stageBits = <String>[];
    if (r.affectsDisplay) stageBits.add('display');
    if (r.affectsPrompt) stageBits.add('prompt');
    final flags = r.flags.isEmpty ? '' : '/${r.flags}';
    final pat = r.pattern.isEmpty ? '(empty)' : '/${r.pattern}$flags';
    return '$pat  ·  ${streamBits.join("+")}  ·  ${stageBits.join("+")}';
  }

  void _openEditor(BuildContext context, RegexRule? existing) {
    Navigator.of(context).push(MaterialPageRoute(
      builder: (_) => RegexRuleEditorScreen(existing: existing),
    ));
  }

  Future<void> _importStRegexFile(BuildContext context) async {
    final store = context.read<AppStore>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['json'],
        withData: true,
      );
      if (result == null || result.files.isEmpty) return;
      final bytes = result.files.first.bytes;
      if (bytes == null) {
        messenger.showSnackBar(
          const SnackBar(content: Text('Could not read the file.')),
        );
        return;
      }
      dynamic root;
      try {
        root = jsonDecode(utf8.decode(bytes));
      } catch (e) {
        messenger.showSnackBar(SnackBar(content: Text('Invalid JSON: $e')));
        return;
      }
      final parsed = parseStRegexScripts(root);
      if (parsed.isEmpty) {
        messenger.showSnackBar(const SnackBar(
            content: Text(
                'No SillyTavern regex scripts found in that file (expected a '
                'script object, an array of scripts, or {regexScripts: […]}).')));
        return;
      }
      for (final r in parsed) {
        store.addRegexRule(r);
      }
      messenger.showSnackBar(SnackBar(
        content: Text(
            'Imported ${parsed.length} rule${parsed.length == 1 ? "" : "s"}.'),
      ));
    } catch (e) {
      messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
    }
  }
}

/// Full-screen editor for a single [RegexRule] plus a live TEST box.
class RegexRuleEditorScreen extends StatefulWidget {
  final RegexRule? existing;
  const RegexRuleEditorScreen({super.key, this.existing});

  @override
  State<RegexRuleEditorScreen> createState() => _RegexRuleEditorScreenState();
}

class _RegexRuleEditorScreenState extends State<RegexRuleEditorScreen> {
  late final TextEditingController _name;
  // "Find" accepts either a raw pattern OR a `/pat/flags` literal. We keep the
  // raw text the user typed and split it via parseRegexLiteral on save + in
  // the live preview.
  late final TextEditingController _find;
  late final TextEditingController _replace;
  late final TextEditingController _trim;
  late final TextEditingController _sample;

  bool _userInput = true;
  bool _aiOutput = true;
  bool _affectsDisplay = true;
  bool _affectsPrompt = true;
  bool _enabled = true;

  // Live-test stream selector.
  RegexStream _testStream = RegexStream.aiOutput;

  @override
  void initState() {
    super.initState();
    final r = widget.existing;
    _name = TextEditingController(text: r?.name ?? '');
    // Show the rule back as a `/pat/flags` literal when it has flags, else the
    // raw pattern.
    final findText = r == null
        ? ''
        : (r.flags.isEmpty ? r.pattern : '/${r.pattern}/${r.flags}');
    _find = TextEditingController(text: findText);
    _replace = TextEditingController(text: r?.replacement ?? '');
    _trim = TextEditingController(text: (r?.trimStrings ?? const []).join('\n'));
    _sample = TextEditingController(
        text: 'The quick brown fox jumps over the lazy dog.');
    _userInput = r?.streams.contains(RegexStream.userInput) ?? true;
    _aiOutput = r?.streams.contains(RegexStream.aiOutput) ?? true;
    _affectsDisplay = r?.affectsDisplay ?? true;
    _affectsPrompt = r?.affectsPrompt ?? true;
    _enabled = r?.enabled ?? true;
    // Listen so the live preview updates as the user types.
    for (final c in [_find, _replace, _trim, _sample]) {
      c.addListener(_onChanged);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _find.dispose();
    _replace.dispose();
    _trim.dispose();
    _sample.dispose();
    super.dispose();
  }

  void _onChanged() => setState(() {});

  /// Build the in-progress rule from the current form fields (for preview /
  /// save). Always targets BOTH stages here so the live preview reflects the
  /// pattern regardless of the affects* toggles; the preview passes the chosen
  /// stage at call time.
  RegexRule _buildRuleForPreview() {
    final lit = parseRegexLiteral(_find.text);
    final trims = _trim.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    return RegexRule(
      name: _name.text,
      pattern: lit.pattern,
      flags: lit.flags,
      replacement: _replace.text,
      trimStrings: trims,
      streams: [
        if (_userInput) RegexStream.userInput,
        if (_aiOutput) RegexStream.aiOutput,
      ],
      // For the live preview we force BOTH stages true so the chosen-stage
      // call always sees the rule; the saved rule uses the real toggles.
      affectsDisplay: true,
      affectsPrompt: true,
      enabled: true,
    );
  }

  void _save() {
    final lit = parseRegexLiteral(_find.text);
    final trims = _trim.text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .toList();
    final streams = <RegexStream>[
      if (_userInput) RegexStream.userInput,
      if (_aiOutput) RegexStream.aiOutput,
    ];
    if (streams.isEmpty) {
      // A rule with no stream would never fire — default to both rather than
      // silently saving a dead rule.
      streams
        ..add(RegexStream.userInput)
        ..add(RegexStream.aiOutput);
    }
    final store = context.read<AppStore>();
    final existing = widget.existing;
    if (existing == null) {
      store.addRegexRule(RegexRule(
        name: _name.text.trim().isEmpty ? 'Rule' : _name.text.trim(),
        pattern: lit.pattern,
        flags: lit.flags,
        replacement: _replace.text,
        trimStrings: trims,
        streams: streams,
        affectsDisplay: _affectsDisplay,
        affectsPrompt: _affectsPrompt,
        enabled: _enabled,
      ));
    } else {
      final edited = existing.clone()
        ..name = _name.text.trim().isEmpty ? 'Rule' : _name.text.trim()
        ..pattern = lit.pattern
        ..flags = lit.flags
        ..replacement = _replace.text
        ..trimStrings = trims
        ..streams = streams
        ..affectsDisplay = _affectsDisplay
        ..affectsPrompt = _affectsPrompt
        ..enabled = _enabled;
      store.updateRegexRule(edited);
    }
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final previewRule = _buildRuleForPreview();
    final preview = applyRegexRules(
      _sample.text,
      [previewRule],
      stream: _testStream,
      stage: RegexStage.display,
    );
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.existing == null ? 'New rule' : 'Edit rule'),
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Save'),
          ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          TextField(
            controller: _name,
            decoration: const InputDecoration(
              labelText: 'Name',
              hintText: 'e.g. Strip stage directions',
            ),
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _find,
            decoration: const InputDecoration(
              labelText: 'Find',
              helperText: 'A regex. Accepts /pattern/flags or a raw pattern. '
                  'Flags: i (ignore case), g (replace all), m (multiline), '
                  's (dot matches newline).',
              helperMaxLines: 3,
            ),
            style: const TextStyle(fontFamily: 'monospace'),
            maxLines: null,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _replace,
            decoration: const InputDecoration(
              labelText: 'Replace',
              helperText: 'Use \$1..\$9 for capture groups and {{match}} for '
                  'the whole match.',
              helperMaxLines: 2,
            ),
            style: const TextStyle(fontFamily: 'monospace'),
            maxLines: null,
          ),
          const SizedBox(height: 14),
          TextField(
            controller: _trim,
            decoration: const InputDecoration(
              labelText: 'Trim strings (optional)',
              helperText: 'One per line. These substrings are stripped from the '
                  'matched text wherever {{match}} is used.',
              helperMaxLines: 2,
            ),
            maxLines: null,
          ),
          const SizedBox(height: 18),
          const Text('Applies to',
              style: TextStyle(
                  fontWeight: FontWeight.w600, color: EmberColors.textHigh)),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: _userInput,
            onChanged: (v) => setState(() => _userInput = v ?? false),
            title: const Text('User input (your / persona turns)'),
          ),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            controlAffinity: ListTileControlAffinity.leading,
            value: _aiOutput,
            onChanged: (v) => setState(() => _aiOutput = v ?? false),
            title: const Text('AI output (character turns)'),
          ),
          const SizedBox(height: 8),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _affectsDisplay,
            onChanged: (v) => setState(() => _affectsDisplay = v),
            title: const Text('Apply to displayed text'),
            subtitle: const Text('Transforms the chat bubble (storage untouched).'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _affectsPrompt,
            onChanged: (v) => setState(() => _affectsPrompt = v),
            title: const Text('Apply to prompt sent to model'),
            subtitle:
                const Text('Transforms history in-flight (storage untouched).'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            value: _enabled,
            onChanged: (v) => setState(() => _enabled = v),
            title: const Text('Enabled'),
          ),
          const Divider(height: 32, color: EmberColors.stroke),
          // ── Live test box ─────────────────────────────────────────────
          Row(
            children: [
              const Text('Test',
                  style: TextStyle(
                      fontWeight: FontWeight.w600,
                      color: EmberColors.textHigh)),
              const Spacer(),
              SegmentedButton<RegexStream>(
                segments: const [
                  ButtonSegment(
                      value: RegexStream.userInput, label: Text('User')),
                  ButtonSegment(
                      value: RegexStream.aiOutput, label: Text('AI')),
                ],
                selected: {_testStream},
                onSelectionChanged: (s) =>
                    setState(() => _testStream = s.first),
                showSelectedIcon: false,
              ),
            ],
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _sample,
            decoration: const InputDecoration(
              labelText: 'Sample text',
              border: OutlineInputBorder(),
            ),
            maxLines: null,
          ),
          const SizedBox(height: 10),
          const Text('Result',
              style: TextStyle(color: EmberColors.textMid, fontSize: 12)),
          const SizedBox(height: 4),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: EmberColors.bgElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: EmberColors.stroke),
            ),
            child: SelectableText(
              preview.isEmpty ? '(empty)' : preview,
              style: const TextStyle(color: EmberColors.textHigh),
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'The result previews the DISPLAY transform for the selected stream. '
            'It applies regardless of the toggles above so you can see the '
            'pattern work.',
            style: TextStyle(color: EmberColors.textDim, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
