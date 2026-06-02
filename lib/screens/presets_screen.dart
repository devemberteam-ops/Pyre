import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/st_preset_import.dart';
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/setting_slider.dart';

class PresetsScreen extends StatelessWidget {
  const PresetsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final visible = store.visiblePresets;
    // The locked default is never listed and never previewable.
    // The "Default" pill on the active row only shows when the locked default
    // is actually selected — no other surface exposes its contents.

    return Scaffold(
      appBar: AppBar(
        title: const Text('Presets'),
        actions: [
          IconButton(
            icon: const Icon(Icons.file_upload_outlined),
            tooltip: 'Import SillyTavern preset',
            onPressed: () => _importSillyTavern(context),
          ),
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'New preset',
            onPressed: () => _editPreset(context, null),
          ),
        ],
      ),
      // Wave CY.18.192: the global sampling defaults (max tokens,
      // temperature, top-p, top-k) used to live on the now-deleted
      // Model Settings screen. They moved here, into a "Default
      // generation" card at the top — these are the fallback values
      // applied whenever a preset leaves a field blank (the per-preset
      // overrides live inside the preset editor below). The card scrolls
      // with the list so a long preset list doesn't pin it off-screen.
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          const _DefaultGenerationCard(),
          const SizedBox(height: 16),
          const _SectionLabel('PRESETS'),
          const SizedBox(height: 8),
          for (final p in visible) ...[
            Builder(
              builder: (context) {
                final active = p.id == store.activePresetId;
                return Card(
                  child: ListTile(
                    leading: CircleAvatar(
                      radius: 20,
                      backgroundColor: p.locked
                          ? EmberColors.primary.withValues(alpha: 0.22)
                          : EmberColors.bgElevated,
                      child: Icon(
                        p.locked ? Icons.lock_outline : Icons.layers_outlined,
                        size: 18,
                        color: p.locked
                            ? EmberColors.primary
                            : (active
                                ? EmberColors.primary
                                : EmberColors.textMid),
                      ),
                    ),
                    title: Row(
                      children: [
                        Flexible(
                          child: Text(p.name,
                              style: const TextStyle(
                                  fontWeight: FontWeight.w600)),
                        ),
                        if (active) ...[
                          const SizedBox(width: 6),
                          _Pill(label: 'ACTIVE'),
                        ],
                        if (p.locked) ...[
                          const SizedBox(width: 6),
                          _Pill(label: 'DEFAULT'),
                        ],
                      ],
                    ),
                    subtitle: Text(
                      p.locked
                          ? 'Built-in preset · tuned for creative roleplay'
                          : _previewLine(p),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: EmberColors.textMid),
                    ),
                    trailing: IconButton(
                      icon: const Icon(Icons.more_vert,
                          color: EmberColors.textMid),
                      tooltip: 'Preset actions',
                      onPressed: () => _openPresetKebab(context, p),
                    ),
                    onTap: () => store.setActivePreset(p.id),
                  ),
                );
              },
            ),
            const SizedBox(height: 8),
          ],
        ],
      ),
    );
  }
}

/// Wave CY.18.192: small uppercase section label, matches the inline
/// header style used elsewhere (Creator, Chat Settings).
class _SectionLabel extends StatelessWidget {
  final String text;
  const _SectionLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Text(
        text,
        style: const TextStyle(
          color: EmberColors.primary,
          fontWeight: FontWeight.w700,
          fontSize: 11,
          letterSpacing: 1.2,
        ),
      ),
    );
  }
}

/// Wave CY.18.192: global sampling defaults, moved here from the deleted
/// Model Settings screen. These bind to the global `ModelSettings` — the
/// fallback used by `_samplingPayload` (chat_api.dart) whenever the active
/// preset leaves a field null (`preset?.x ?? settings.x`). The per-preset
/// overrides still live in the preset editor; this card is the base layer.
///
/// Stateful so it can hold transient per-slider drag values, keeping the
/// thumb smooth during a drag without persisting on every tick (mirror of
/// the opacity-slider pattern in customize_chat_sheet.dart). Live values
/// are always read from `store.modelSettings` — no persistent draft that
/// could go stale when modelSettings changes externally (backup/merge
/// restore, factory reset, LAN sync pull).
class _DefaultGenerationCard extends StatefulWidget {
  const _DefaultGenerationCard();

  @override
  State<_DefaultGenerationCard> createState() => _DefaultGenerationCardState();
}

class _DefaultGenerationCardState extends State<_DefaultGenerationCard> {
  // Transient per-slider drag values. Non-null only while the user is
  // actively dragging that slider; cleared + committed on onChangeEnd.
  double? _dragMaxTokens;
  double? _dragTemp;
  double? _dragTopP;
  double? _dragTopK;

  @override
  Widget build(BuildContext context) {
    // The active preset can OVERRIDE any of these sampling values when
    // sending the request — we show a "PRESET OVERRIDE" badge on each
    // slider whose preset value differs, so the user isn't confused
    // about why their default "isn't taking effect".
    final store = context.watch<AppStore>();
    final ms = store.modelSettings;
    final preset = store.activePreset;

    // Effective display value: transient drag value if dragging, else live.
    final dispMaxTokens = _dragMaxTokens ?? ms.maxTokens.toDouble();
    final dispTemp      = _dragTemp      ?? ms.temperature;
    final dispTopP      = _dragTopP      ?? ms.topP;
    final dispTopK      = _dragTopK      ?? ms.topK.toDouble();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const _SectionLabel('DEFAULT GENERATION'),
        const Padding(
          padding: EdgeInsets.fromLTRB(4, 4, 4, 0),
          child: Text(
            'Defaults used when a preset leaves a field blank. '
            'Edit a preset to override per-preset.',
            style: TextStyle(
              color: EmberColors.textMid,
              fontSize: 12,
              height: 1.4,
            ),
          ),
        ),
        if (preset != null &&
            [
              preset.temperature,
              preset.topP,
              preset.topK,
              preset.maxTokens,
            ].any((v) => v != null))
          Card(
            margin: const EdgeInsets.symmetric(vertical: 6),
            color: EmberColors.bgElevated,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                children: [
                  const Icon(Icons.info_outline,
                      size: 18, color: EmberColors.primary),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      'Preset "${preset.name}" overrides some of these values when active. Overridden sliders show the preset value as the effective one.',
                      style: const TextStyle(
                        color: EmberColors.textMid,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        SliderCard(
          label: 'Max Response Tokens',
          subtitle:
              'Maximum tokens in a response; too small may cause truncation.',
          value: dispMaxTokens,
          min: 64,
          max: 4096,
          divisions: 63,
          display: dispMaxTokens.round().toString(),
          onChanged: (v) => setState(() => _dragMaxTokens = v),
          onChangeEnd: (v) {
            final updated = store.modelSettings.copy()
              ..maxTokens = v.round();
            store.updateModelSettings(updated);
            setState(() => _dragMaxTokens = null);
          },
          // Only mark as overridden when the preset value DIFFERS from
          // the default — identical values would just confuse the user.
          overrideValue: (preset?.maxTokens != null &&
                  preset!.maxTokens != ms.maxTokens)
              ? preset.maxTokens.toString()
              : null,
        ),
        SliderCard(
          label: 'Temperature',
          subtitle: 'Script-adherent  ~  Wildly imaginative',
          value: dispTemp,
          min: 0,
          max: 2,
          divisions: 40,
          display: dispTemp.toStringAsFixed(2),
          onChanged: (v) => setState(() => _dragTemp = v),
          onChangeEnd: (v) {
            final updated = store.modelSettings.copy()
              ..temperature = v;
            store.updateModelSettings(updated);
            setState(() => _dragTemp = null);
          },
          overrideValue: (preset?.temperature != null &&
                  (preset!.temperature! - ms.temperature).abs() > 0.001)
              ? preset.temperature!.toStringAsFixed(2)
              : null,
        ),
        SliderCard(
          label: 'Top-P',
          subtitle: 'Personality Single-faceted  ~  Multi-faceted',
          value: dispTopP,
          min: 0,
          max: 1,
          divisions: 20,
          display: dispTopP.toStringAsFixed(2),
          onChanged: (v) => setState(() => _dragTopP = v),
          onChangeEnd: (v) {
            final updated = store.modelSettings.copy()
              ..topP = v;
            store.updateModelSettings(updated);
            setState(() => _dragTopP = null);
          },
          overrideValue: (preset?.topP != null &&
                  (preset!.topP! - ms.topP).abs() > 0.001)
              ? preset.topP!.toStringAsFixed(2)
              : null,
        ),
        SliderCard(
          label: 'Top-K',
          subtitle: 'Dialogue Style Fixed  ~  Variable  (0 = disabled)',
          value: dispTopK,
          min: 0,
          max: 100,
          divisions: 100,
          display: dispTopK.round().toString(),
          onChanged: (v) => setState(() => _dragTopK = v),
          onChangeEnd: (v) {
            final updated = store.modelSettings.copy()
              ..topK = v.round();
            store.updateModelSettings(updated);
            setState(() => _dragTopK = null);
          },
          overrideValue: (preset?.topK != null && preset!.topK != ms.topK)
              ? preset.topK.toString()
              : null,
        ),
      ],
    );
  }
}

String _previewLine(Preset p) {
  final src = p.mainPrompt.trim();
  if (src.isEmpty) return '(no system prompt)';
  final flat = src.replaceAll(RegExp(r'\s+'), ' ');
  if (p.source == 'sillytavern') return 'ST preset · $flat';
  return flat;
}

class _Pill extends StatelessWidget {
  final String label;
  const _Pill({required this.label});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: EmberColors.primary.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
        border:
            Border.all(color: EmberColors.primary.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: const TextStyle(
          color: EmberColors.primary,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

Future<void> _openPresetKebab(BuildContext context, Preset p) async {
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.of(context);
  await showModalBottomSheet<void>(
    context: context,
    backgroundColor: EmberColors.bgPanel,
    builder: (sheet) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.check_circle_outline,
                color: EmberColors.primary),
            title: const Text('Select (activate now)'),
            onTap: () {
              Navigator.pop(sheet);
              store.setActivePreset(p.id);
              messenger.showSnackBar(
                SnackBar(content: Text('"${p.name}" is now active.')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.vertical_align_top),
            title: const Text('Move to top'),
            onTap: () {
              Navigator.pop(sheet);
              final all = [...store.presets]..removeWhere((x) => x.id == p.id);
              store.presets
                ..clear()
                ..addAll([p, ...all]);
              store.notifyAndPersist();
            },
          ),
          // Wave CY.18.10: View / Copy / Export are now available for
          // ALL presets including the Pyre Default. The pre-Play-Store
          // "sealed" treatment is gone — the contents are visible (in
          // read-only View) and clonable so users can fork the default
          // as a starting point. Edit and Delete remain locked-only-off
          // so the original default stays intact as a reference point.
          ListTile(
            leading: const Icon(Icons.visibility_outlined),
            title: const Text('View details'),
            onTap: () {
              Navigator.pop(sheet);
              _showPresetDetails(context, p);
            },
          ),
          ListTile(
            leading: const Icon(Icons.copy),
            title: const Text('Copy (editable)'),
            onTap: () {
              Navigator.pop(sheet);
              final clone = Preset(
                id: newId('preset'),
                name: '${p.name} (copy)',
                mainPrompt: p.mainPrompt,
                postHistoryInstructions: p.postHistoryInstructions,
                impersonationPrompt: p.impersonationPrompt,
                continueNudgePrompt: p.continueNudgePrompt,
                temperature: p.temperature,
                topP: p.topP,
                topK: p.topK,
                maxTokens: p.maxTokens,
                frequencyPenalty: p.frequencyPenalty,
                presencePenalty: p.presencePenalty,
                minP: p.minP,
                topA: p.topA,
                repetitionPenalty: p.repetitionPenalty,
              );
              store.addPreset(clone);
              messenger.showSnackBar(
                const SnackBar(content: Text('Copied as editable preset.')),
              );
            },
          ),
          ListTile(
            leading: const Icon(Icons.file_download_outlined),
            title: const Text('Export JSON'),
            onTap: () async {
              Navigator.pop(sheet);
              final json = const JsonEncoder.withIndent('  ')
                  .convert(p.toJson());
              await Clipboard.setData(ClipboardData(text: json));
              messenger.showSnackBar(
                const SnackBar(content: Text('Preset JSON copied.')),
              );
            },
          ),
          // Edit and Delete remain hidden for the locked preset so
          // there's always a known-good fallback the user can copy
          // from. To "edit" the default, copy it and edit the clone.
          if (!p.locked)
            ListTile(
              leading: const Icon(Icons.edit_outlined),
              title: const Text('Edit'),
              onTap: () {
                Navigator.pop(sheet);
                _editPreset(context, p);
              },
            ),
          if (!p.locked)
            ListTile(
              leading: const Icon(Icons.delete_outline,
                  color: EmberColors.danger),
              title: const Text('Delete',
                  style: TextStyle(color: EmberColors.danger)),
              onTap: () async {
                Navigator.pop(sheet);
                final ok = await confirmDelete(
                  context,
                  title: 'Delete "${p.name}"?',
                  message:
                      'The preset will be removed. Chats using it will fall back to the default preset.',
                );
                if (!ok) return;
                store.removePreset(p.id);
              },
            ),
        ],
      ),
    ),
  );
}

/// Wave CY.18.10: read-only viewer for any preset (especially the
/// locked default, which has no other surface to expose its
/// contents). Renders each field as a labelled, selectable text
/// block. The user can long-press to copy individual sections.
Future<void> _showPresetDetails(BuildContext context, Preset p) async {
  await Navigator.of(context).push(
    MaterialPageRoute(builder: (_) => _PresetDetailsScreen(preset: p)),
  );
}

/// Wave CY.18.24: was a StatelessWidget that captured the Preset by
/// value — meaning a backup restore (or any other external mutation)
/// while this screen was on top showed STALE data until pop+reopen.
/// Now reads the live preset from the store on every build by id,
/// falling back to the last-known snapshot if the preset was deleted
/// while detail was open. Watches AppStore so writes anywhere refresh.
class _PresetDetailsScreen extends StatelessWidget {
  final Preset preset;
  const _PresetDetailsScreen({required this.preset});

  /// Resolve the live preset from the store; fall back to the
  /// snapshot we were constructed with if it's gone (e.g. backup
  /// restore wiped the list mid-view).
  Preset _live(AppStore store) {
    for (final p in store.presets) {
      if (p.id == preset.id) return p;
    }
    return preset;
  }

  Widget _section(String title, String? value, {bool monospace = true}) {
    if (value == null || value.trim().isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            title.toUpperCase(),
            style: const TextStyle(
              color: EmberColors.primary,
              fontWeight: FontWeight.w700,
              fontSize: 11,
              letterSpacing: 1.1,
            ),
          ),
          const SizedBox(height: 6),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: EmberColors.bgElevated,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: EmberColors.stroke, width: 1),
            ),
            child: SelectableText(
              value,
              style: TextStyle(
                color: EmberColors.textHigh,
                fontSize: 12,
                height: 1.45,
                fontFamily: monospace ? 'monospace' : null,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _samplingRowFor(BuildContext context, Preset p) {
    final samp = <String, dynamic>{
      'temperature': p.temperature,
      'top_p': p.topP,
      'top_k': p.topK,
      'max_tokens': p.maxTokens,
      'frequency_penalty': p.frequencyPenalty,
      'presence_penalty': p.presencePenalty,
      'min_p': p.minP,
      'top_a': p.topA,
      'repetition_penalty': p.repetitionPenalty,
    }..removeWhere((_, v) => v == null);
    if (samp.isEmpty) return const SizedBox.shrink();
    final lines =
        samp.entries.map((e) => '${e.key}: ${e.value}').join('\n');
    return _section('Sampling overrides', lines);
  }

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    final live = _live(store);
    return Scaffold(
      appBar: AppBar(
        title: const Text('Preset details'),
        actions: [
          if (live.locked)
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 12),
              child: Center(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.lock_outline,
                        size: 14, color: EmberColors.primary),
                    SizedBox(width: 4),
                    Text(
                      'READ-ONLY',
                      style: TextStyle(
                        color: EmberColors.primary,
                        fontSize: 10,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 1.1,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  live.name,
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.w700),
                ),
              ),
              if (live.locked)
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 8, vertical: 4),
                  decoration: BoxDecoration(
                    color: EmberColors.primary.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'DEFAULT',
                    style: TextStyle(
                      color: EmberColors.primary,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 1.0,
                    ),
                  ),
                ),
            ],
          ),
          if (live.locked) ...[
            const SizedBox(height: 6),
            const Text(
              'The built-in default — sealed against edits and deletion '
              'so it stays as a known-good fallback. Use "Copy '
              '(editable)" from the kebab to fork it into a custom '
              'preset you can modify freely.',
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
          const SizedBox(height: 18),
          _section('Main prompt', live.mainPrompt),
          _section('Post-history instructions',
              live.postHistoryInstructions),
          _section('Impersonate prompt', live.impersonationPrompt),
          _section('Continue nudge', live.continueNudgePrompt),
          _samplingRowFor(context, live),
        ],
      ),
    );
  }
}

Future<void> _importSillyTavern(BuildContext context) async {
  final store = context.read<AppStore>();
  final messenger = ScaffoldMessenger.of(context);
  try {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) {
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not read file bytes.')),
      );
      return;
    }
    final text = utf8.decode(bytes);
    final imported = parseSillyTavernPreset(text);
    store.addPreset(imported.preset);
    store.setActivePreset(imported.preset.id);
    final parts = <String>['${imported.promptCount} prompts merged'];
    if (imported.preset.postHistoryInstructions.trim().isNotEmpty) {
      parts.add('post-history block captured');
    }
    if (imported.preset.impersonationPrompt != null) {
      parts.add('impersonate override');
    }
    if (imported.preset.continueNudgePrompt != null) {
      parts.add('continue override');
    }
    if (imported.skipped.isNotEmpty) {
      parts.add('skipped: ${imported.skipped.join(", ")}');
    }
    messenger.showSnackBar(SnackBar(
      duration: const Duration(seconds: 6),
      content: Text(
        'Imported "${imported.preset.name}" — ${parts.join(" · ")}',
      ),
    ));
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Import failed: $e')));
  }
}

Future<void> _editPreset(BuildContext context, Preset? existing) async {
  final store = context.read<AppStore>();
  // Identity + prompts
  final nameCtl = TextEditingController(text: existing?.name ?? 'New preset');
  final mainCtl = TextEditingController(text: existing?.mainPrompt ?? '');
  final postCtl =
      TextEditingController(text: existing?.postHistoryInstructions ?? '');
  final impCtl =
      TextEditingController(text: existing?.impersonationPrompt ?? '');
  final cntCtl =
      TextEditingController(text: existing?.continueNudgePrompt ?? '');

  // Sampling — every field is an OPTIONAL override of the global
  // "Default generation" defaults (the card at the top of this screen).
  // Empty string means "use the user's global default".
  String fmt(num? v) => v == null ? '' : v.toString();
  final tempCtl = TextEditingController(text: fmt(existing?.temperature));
  final topPCtl = TextEditingController(text: fmt(existing?.topP));
  final topKCtl = TextEditingController(text: fmt(existing?.topK));
  final tokensCtl = TextEditingController(text: fmt(existing?.maxTokens));
  final freqCtl =
      TextEditingController(text: fmt(existing?.frequencyPenalty));
  final presCtl = TextEditingController(text: fmt(existing?.presencePenalty));
  final minPCtl = TextEditingController(text: fmt(existing?.minP));
  final topACtl = TextEditingController(text: fmt(existing?.topA));
  final repCtl =
      TextEditingController(text: fmt(existing?.repetitionPenalty));

  Widget sectionHeader(String text) => Padding(
        padding: const EdgeInsets.only(top: 18, bottom: 6),
        child: Text(
          text.toUpperCase(),
          style: const TextStyle(
            color: EmberColors.primary,
            fontWeight: FontWeight.w700,
            fontSize: 11,
            letterSpacing: 1.2,
          ),
        ),
      );

  Widget hint(String text) => Padding(
        padding: const EdgeInsets.only(top: 2, bottom: 4),
        child: Text(
          text,
          style: const TextStyle(color: EmberColors.textMid, fontSize: 12),
        ),
      );

  Widget numField(
    TextEditingController ctl, {
    required String label,
    required String hint,
  }) =>
      TextField(
        controller: ctl,
        keyboardType:
            const TextInputType.numberWithOptions(decimal: true, signed: true),
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          isDense: true,
        ),
      );

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: EmberColors.bgPanel,
      title: Text(existing == null ? 'New preset' : 'Edit preset'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              sectionHeader('Identity'),
              TextField(
                controller: nameCtl,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              sectionHeader('Prompts'),
              hint('Main prompt — sent BEFORE the chat history.'),
              TextField(
                controller: mainCtl,
                maxLines: 8,
                minLines: 4,
                decoration: const InputDecoration(
                  hintText:
                      'Supports {{char}}, {{user}}, {{description}}, {{personality}}, {{scenario}}, {{persona}}, {{mesExample}}, {{wiBefore}}, {{wiAfter}}.',
                ),
              ),
              const SizedBox(height: 12),
              hint(
                  'Post-history — appended AFTER the chat as a final reminder (jailbreak / prefill).'),
              TextField(
                controller: postCtl,
                maxLines: 5,
                minLines: 2,
                decoration: const InputDecoration(
                  hintText: 'Optional. Same template tokens as Main.',
                ),
              ),
              const SizedBox(height: 12),
              hint(
                  'Impersonate prompt — used by the "Impersonate me" action to draft the next user message.'),
              TextField(
                controller: impCtl,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  hintText:
                      'Optional. Supports {{user}}, {{char}}. Default: write next message as the persona.',
                ),
              ),
              const SizedBox(height: 12),
              hint(
                  'Continue nudge — used by Continue to extend a truncated reply.'),
              TextField(
                controller: cntCtl,
                maxLines: 3,
                minLines: 2,
                decoration: const InputDecoration(
                  hintText:
                      'Optional. Supports {{char}}, {{lastChatMessage}}.',
                ),
              ),
              sectionHeader('Sampling overrides'),
              hint(
                  'Each field overrides your global default (set in Default generation above) only when filled. Leave blank to use the global default.'),
              Row(children: [
                Expanded(
                    child: numField(tempCtl,
                        label: 'Temperature', hint: '0.0 – 2.0')),
                const SizedBox(width: 12),
                Expanded(
                    child: numField(topPCtl,
                        label: 'Top-P', hint: '0.0 – 1.0')),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: numField(topKCtl,
                        label: 'Top-K', hint: 'int, 0 = off')),
                const SizedBox(width: 12),
                Expanded(
                    child: numField(tokensCtl,
                        label: 'Max tokens', hint: 'int')),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: numField(freqCtl,
                        label: 'Frequency penalty', hint: '−2.0 – 2.0')),
                const SizedBox(width: 12),
                Expanded(
                    child: numField(presCtl,
                        label: 'Presence penalty', hint: '−2.0 – 2.0')),
              ]),
              const SizedBox(height: 12),
              Row(children: [
                Expanded(
                    child: numField(minPCtl,
                        label: 'Min-P', hint: '0.0 – 1.0')),
                const SizedBox(width: 12),
                Expanded(
                    child: numField(topACtl,
                        label: 'Top-A', hint: '0.0 – 1.0')),
              ]),
              const SizedBox(height: 12),
              numField(repCtl,
                  label: 'Repetition penalty', hint: '1.0 – 1.5 typical'),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            // Parse helpers — empty string means "no override" (null).
            double? d(TextEditingController c) {
              final t = c.text.trim();
              if (t.isEmpty) return null;
              return double.tryParse(t);
            }

            int? i(TextEditingController c) {
              final t = c.text.trim();
              if (t.isEmpty) return null;
              return int.tryParse(t);
            }

            String? s(TextEditingController c) {
              final t = c.text.trim();
              return t.isEmpty ? null : t;
            }

            if (existing == null) {
              store.addPreset(Preset(
                id: newId('preset'),
                name: nameCtl.text.trim().isEmpty
                    ? 'Preset'
                    : nameCtl.text.trim(),
                mainPrompt: mainCtl.text.trim(),
                postHistoryInstructions: postCtl.text.trim(),
                impersonationPrompt: s(impCtl),
                continueNudgePrompt: s(cntCtl),
                temperature: d(tempCtl),
                topP: d(topPCtl),
                topK: i(topKCtl),
                maxTokens: i(tokensCtl),
                frequencyPenalty: d(freqCtl),
                presencePenalty: d(presCtl),
                minP: d(minPCtl),
                topA: d(topACtl),
                repetitionPenalty: d(repCtl),
              ));
            } else {
              existing
                ..name = nameCtl.text.trim()
                ..mainPrompt = mainCtl.text.trim()
                ..postHistoryInstructions = postCtl.text.trim()
                ..impersonationPrompt = s(impCtl)
                ..continueNudgePrompt = s(cntCtl)
                ..temperature = d(tempCtl)
                ..topP = d(topPCtl)
                ..topK = i(topKCtl)
                ..maxTokens = i(tokensCtl)
                ..frequencyPenalty = d(freqCtl)
                ..presencePenalty = d(presCtl)
                ..minP = d(minPCtl)
                ..topA = d(topACtl)
                ..repetitionPenalty = d(repCtl);
              store.updatePreset(existing);
            }
            Navigator.pop(ctx);
          },
          child: Text(existing == null ? 'Create' : 'Save'),
        ),
      ],
    ),
  );
}
