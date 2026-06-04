import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chat_api.dart';
import '../services/model_metadata.dart';
import '../services/prompt_post_processing.dart';
import '../state/app_store.dart';
import '../theme.dart';
import 'model_picker_sheet.dart';

class ApiConnectionsScreen extends StatelessWidget {
  const ApiConnectionsScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final store = context.watch<AppStore>();
    return Scaffold(
      appBar: AppBar(
        title: const Text('API Connections'),
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'Add provider',
            onPressed: () => _editProvider(context, null),
          ),
        ],
      ),
      body: store.providers.isEmpty
          ? const Center(
              child: Padding(
                padding: EdgeInsets.all(32),
                child: Text(
                  'No providers configured.\nTap + to add an OpenAI-compatible endpoint.',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: EmberColors.textMid),
                ),
              ),
            )
          : Column(
              children: [
                // Fixed header: the per-feature override card (only with
                // 2+ providers) + a gentle one-line fallback explainer.
                if (store.providers.length >= 2)
                  Padding(
                    padding:
                        const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _CreatorProviderCard(store: store),
                  ),
                if (store.providers.length >= 2 &&
                    store.uiPrefs.askToSwitchOnFailure)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(20, 12, 20, 4),
                    child: Text(
                      'If a provider fails or refuses, Pyre offers to '
                      'switch to the next one. Drag to set the order — '
                      'the CHAT provider is always tried first.',
                      style: TextStyle(
                          color: EmberColors.textDim, fontSize: 12,
                          height: 1.4),
                    ),
                  ),
                // The provider list IS the fallback order. Reorderable.
                Expanded(
                  child: ReorderableListView.builder(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 8),
                    buildDefaultDragHandles: false,
                    itemCount: store.providers.length,
                    // onReorder's classic (oldIndex,newIndex) contract
                    // is what reorderProvider implements (standard
                    // newIndex-- adjustment internally). onReorderItem
                    // pre-adjusts, which would double it.
                    // ignore: deprecated_member_use
                    onReorder: store.reorderProvider,
                    itemBuilder: (_, idx) {
                      final p = store.providers[idx];
                      final active = p.id == store.activeProviderId;
                      final isCreator = p.id == store.creatorProviderId;
                      final isVision = p.id == store.visionProviderId;
                      final initial = p.name.isNotEmpty
                          ? p.name.characters.first.toUpperCase()
                          : '?';
                      return Card(
                        key: ValueKey(p.id),
                        margin: const EdgeInsets.only(bottom: 8),
                        child: ListTile(
                          leading: CircleAvatar(
                            radius: 20,
                            backgroundColor: active
                                ? EmberColors.primary
                                : EmberColors.bgElevated,
                            child: Text(
                              initial,
                              style: TextStyle(
                                color: active
                                    ? Colors.white
                                    : EmberColors.textMid,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
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
                              if (active) ...[
                                const SizedBox(width: 6),
                                _ProviderBadge(
                                  label: 'CHAT',
                                  color: EmberColors.primary,
                                ),
                              ],
                              if (isCreator) ...[
                                const SizedBox(width: 6),
                                _ProviderBadge(
                                  label: 'CREATOR',
                                  color: Colors.amber,
                                ),
                              ],
                              if (isVision) ...[
                                const SizedBox(width: 6),
                                _ProviderBadge(
                                  label: 'VISION',
                                  color: const Color(0xFF6FBEFF),
                                ),
                              ],
                            ],
                          ),
                          subtitle: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                p.baseUrl,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                    color: EmberColors.textMid,
                                    fontSize: 12),
                              ),
                              Text(
                                'model: ${p.model.isEmpty ? "(none)" : p.model}',
                                style: const TextStyle(
                                    color: EmberColors.textMid,
                                    fontSize: 12),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              IconButton(
                                icon: const Icon(Icons.edit_outlined,
                                    color: EmberColors.textMid),
                                tooltip: 'Edit',
                                onPressed: () => _editProvider(context, p),
                              ),
                              // Drag handle (only useful with 2+; harmless
                              // with one). Explicit listener so the rest of
                              // the row stays tappable to set-as-CHAT.
                              if (store.providers.length >= 2)
                                ReorderableDragStartListener(
                                  index: idx,
                                  child: const Padding(
                                    padding: EdgeInsets.only(left: 2),
                                    child: Icon(Icons.drag_handle,
                                        color: EmberColors.textDim),
                                  ),
                                ),
                            ],
                          ),
                          onTap: () => store.setActiveProvider(p.id),
                        ),
                      );
                    },
                  ),
                ),
                // Advanced — collapsed. One toggle for the whole feature.
                _AdvancedFallbackTile(store: store),
              ],
            ),
    );
  }
}

/// Wave CY.18.99: collapsed "Advanced" section with the single master
/// toggle for the provider-fallback prompt. Collapsed by default so a
/// new user never feels they must touch it.
class _AdvancedFallbackTile extends StatelessWidget {
  final AppStore store;
  const _AdvancedFallbackTile({required this.store});

  @override
  Widget build(BuildContext context) {
    return Theme(
      // Strip the default ExpansionTile divider lines for a cleaner look.
      data: Theme.of(context)
          .copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Advanced',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          SwitchListTile(
            value: store.uiPrefs.askToSwitchOnFailure,
            onChanged: store.setAskToSwitchOnFailure,
            title: const Text('Ask to switch providers when one fails',
                style: TextStyle(fontSize: 14)),
            subtitle: const Text(
              'When a provider errors or refuses, Pyre offers to retry '
              'the reply on another configured provider. Off: never asks.',
              style: TextStyle(
                  color: EmberColors.textMid, fontSize: 12, height: 1.4),
            ),
            activeThumbColor: EmberColors.primary,
          ),
        ],
      ),
    );
  }
}

/// Card at the top of the providers list with the two override
/// dropdowns. By default everything inherits the chat-active
/// provider — a common setup. Power users split:
///   - "DeepSeek for chat + creator text quality (no vision)"
///   - "Venice qwen for vision only (multimodal but worse prose)"
/// Vision falls back to creator → chat when not set explicitly.
class _CreatorProviderCard extends StatelessWidget {
  final AppStore store;
  const _CreatorProviderCard({required this.store});

  @override
  Widget build(BuildContext context) {
    final creatorId = store.creatorProviderId;
    final visionId = store.visionProviderId;
    return Card(
      color: EmberColors.bgElevated,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Row(
              children: [
                Icon(Icons.auto_awesome,
                    color: Colors.amber, size: 16),
                SizedBox(width: 8),
                Text(
                  'Per-feature provider overrides',
                  style: TextStyle(
                      fontWeight: FontWeight.w600, fontSize: 13),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'By default every call uses your active chat provider. '
              'Pin a different one here for specific features — e.g. '
              'DeepSeek for chat and creator text, Qwen-VL only for '
              'image analysis. Vision falls back to creator → chat.',
              style: TextStyle(
                  color: EmberColors.textMid, fontSize: 11, height: 1.4),
            ),
            const SizedBox(height: 12),
            // Creator provider — used for the design conversation and
            // canvas updates inside Character Creator.
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'CREATOR',
                style: TextStyle(
                  color: Colors.amber,
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            DropdownButtonFormField<String?>(
              initialValue: creatorId,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Same as chat provider'),
                ),
                for (final p in store.providers)
                  DropdownMenuItem<String?>(
                    value: p.id,
                    child: Text(p.name),
                  ),
              ],
              onChanged: (id) => store.setCreatorProvider(id),
            ),
            const SizedBox(height: 14),
            // Vision provider — used for image-analysis calls (the
            // creator's vision call when you attach a reference image,
            // and any future image attach in chat).
            const Padding(
              padding: EdgeInsets.only(bottom: 4),
              child: Text(
                'VISION',
                style: TextStyle(
                  color: Color(0xFF6FBEFF),
                  fontWeight: FontWeight.w700,
                  fontSize: 10,
                  letterSpacing: 1.2,
                ),
              ),
            ),
            DropdownButtonFormField<String?>(
              initialValue: visionId,
              decoration: const InputDecoration(
                isDense: true,
                contentPadding: EdgeInsets.symmetric(
                    horizontal: 12, vertical: 8),
              ),
              items: [
                const DropdownMenuItem<String?>(
                  value: null,
                  child: Text('Same as creator provider'),
                ),
                for (final p in store.providers)
                  DropdownMenuItem<String?>(
                    value: p.id,
                    child: Text(p.name),
                  ),
              ],
              onChanged: (id) => store.setVisionProvider(id),
            ),
          ],
        ),
      ),
    );
  }
}

/// Small coloured pill used on each provider row to mark whether it's
/// the active CHAT provider, the CREATOR override, or both.
class _ProviderBadge extends StatelessWidget {
  final String label;
  final Color color;
  const _ProviderBadge({required this.label, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: color.withValues(alpha: 0.5)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}

Future<void> _testConnection(
  BuildContext context,
  TextEditingController nameCtl,
  TextEditingController urlCtl,
  TextEditingController keyCtl,
  TextEditingController modelCtl,
  ProviderKind kind,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final base = urlCtl.text.trim();
  if (base.isEmpty) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Fill in the base URL first.')));
    return;
  }
  final url = buildChatUrl(base, 'models');
  try {
    final resp = await http.get(
      Uri.parse(url),
      headers: {
        if (keyCtl.text.trim().isNotEmpty)
          'Authorization': 'Bearer ${keyCtl.text.trim()}',
      },
    );
    if (resp.statusCode >= 400) {
      messenger.showSnackBar(SnackBar(
          content:
              Text('HTTP ${resp.statusCode}: ${resp.body.split("\n").first}')));
      return;
    }
    messenger.showSnackBar(
      const SnackBar(content: Text('Connection OK ✓')),
    );
  } catch (e) {
    messenger.showSnackBar(SnackBar(content: Text('Test failed: $e')));
  }
}

/// Curated list of OpenAI-compatible providers commonly used for roleplay.
///
/// Order matters — first item is the recommended default for newcomers.
/// Each entry pre-fills Name + Base URL + a sensible default model when
/// the user taps its chip in the editor. The URL field stays editable so
/// power users can still type a custom endpoint (or paste a Mancer /
/// Infermatic / Arli / personal proxy URL not listed here).
class _ProviderPreset {
  final String label;
  final String name;
  final String baseUrl;
  final String defaultModel;
  const _ProviderPreset({
    required this.label,
    required this.name,
    required this.baseUrl,
    required this.defaultModel,
  });
}

const List<_ProviderPreset> _providerPresets = [
  _ProviderPreset(
    label: 'OpenRouter',
    name: 'OpenRouter',
    baseUrl: 'https://openrouter.ai/api/v1',
    // The community standard free DeepSeek route as of mid-2026.
    defaultModel: 'deepseek/deepseek-chat-v3-0324:free',
  ),
  _ProviderPreset(
    label: 'Chub Soji',
    name: 'Chub Soji',
    baseUrl: 'https://mars.chub.ai/chub/soji/v1',
    defaultModel: 'soji',
  ),
  _ProviderPreset(
    label: 'Venice',
    name: 'Venice',
    baseUrl: 'https://api.venice.ai/api/v1',
    defaultModel: 'venice-uncensored',
  ),
  _ProviderPreset(
    label: 'NanoGPT',
    name: 'NanoGPT',
    baseUrl: 'https://nano-gpt.com/api/v1',
    defaultModel: '',
  ),
  _ProviderPreset(
    label: 'Featherless',
    name: 'Featherless',
    baseUrl: 'https://api.featherless.ai/v1',
    defaultModel: '',
  ),
  _ProviderPreset(
    label: 'Infermatic',
    name: 'Infermatic',
    baseUrl: 'https://api.totalgpt.ai/v1',
    defaultModel: '',
  ),
  _ProviderPreset(
    label: 'Arli AI',
    name: 'Arli AI',
    baseUrl: 'https://api.arliai.com/v1',
    defaultModel: '',
  ),
  _ProviderPreset(
    label: 'DeepSeek',
    name: 'DeepSeek',
    baseUrl: 'https://api.deepseek.com',
    // V4 Flash replaced the older `deepseek-chat` as the default tier
    // sometime in early 2026; older tutorials still mention the old name.
    defaultModel: 'deepseek-v4-flash',
  ),
  _ProviderPreset(
    label: 'OpenAI',
    name: 'OpenAI',
    baseUrl: 'https://api.openai.com',
    defaultModel: 'gpt-4o-mini',
  ),
];

Future<void> _editProvider(BuildContext context, ApiProvider? existing) async {
  final store = context.read<AppStore>();
  final isNew = existing == null;
  final nameCtl = TextEditingController(text: existing?.name ?? 'New provider');
  final urlCtl = TextEditingController(text: existing?.baseUrl ?? '');
  final keyCtl = TextEditingController(text: existing?.apiKey ?? '');
  final modelCtl = TextEditingController(text: existing?.model ?? '');
  // Wave CY.18.100: manual context-window override (tokens). Empty =
  // auto-detect from /models. Lets the user force a value for providers
  // that don't expose a context-length field.
  final ctxCtl = TextEditingController(
    text: existing?.contextWindow?.toString() ?? '',
  );
  final extraParamsCtl = TextEditingController(
    text: (existing?.extraParams.isNotEmpty ?? false)
        ? const JsonEncoder.withIndent('  ').convert(existing!.extraParams)
        : '',
  );
  ProviderKind kind = existing?.kind ?? ProviderKind.external_;
  // Wave CY.18.120: preload-on-launch toggle (localhost only). Mutated via
  // setState alongside `kind`, persisted onto the saved ApiProvider below.
  bool warmUp = existing?.warmUpOnLaunch ?? true;
  // Wave CY.18.267: SillyTavern-style outgoing-message reshaping. Default
  // none = today's behaviour. Persisted onto the saved ApiProvider below.
  PromptPostProcessing postProcessing =
      existing?.promptPostProcessing ?? PromptPostProcessing.none;
  String? extraParamsError;

  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setState) => AlertDialog(
        backgroundColor: EmberColors.bgPanel,
        title: Text(isNew ? 'Add provider' : 'Edit provider'),
        content: SizedBox(
          width: 380,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SegmentedButton<ProviderKind>(
                  segments: const [
                    ButtonSegment(
                      value: ProviderKind.external_,
                      label: Text('External'),
                    ),
                    ButtonSegment(
                      value: ProviderKind.proxy,
                      label: Text('Proxy'),
                    ),
                    ButtonSegment(
                      value: ProviderKind.localhost,
                      label: Text('Localhost'),
                    ),
                  ],
                  selected: {kind},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) {
                    setState(() {
                      kind = s.first;
                      if (kind == ProviderKind.localhost &&
                          urlCtl.text.isEmpty) {
                        urlCtl.text = 'http://127.0.0.1:5001';
                      }
                    });
                  },
                ),
                if (kind == ProviderKind.proxy) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: EmberColors.bgElevated,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: EmberColors.stroke),
                    ),
                    child: const Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(Icons.info_outline,
                            size: 16, color: EmberColors.textMid),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Proxies are URLs shared in Discord servers or forums that relay requests to a model the host pays for. Paste the URL + the password they gave you.',
                            style: TextStyle(
                                color: EmberColors.textMid,
                                fontSize: 11,
                                height: 1.4),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                TextField(
                  controller: nameCtl,
                  decoration: const InputDecoration(labelText: 'Name'),
                ),
                const SizedBox(height: 12),
                // Base URL with a dropdown of community-known providers.
                // Picking from the dropdown only fills the URL field — the
                // user can still type a custom endpoint freely. We also
                // backfill Name + default Model when those are still empty
                // (so picking "OpenRouter" on a fresh row sets all three,
                // but doesn't clobber a name the user already wrote).
                TextField(
                  controller: urlCtl,
                  decoration: InputDecoration(
                    labelText: 'Base URL',
                    hintText: 'https://api.openai.com',
                    suffixIcon: kind == ProviderKind.external_
                        ? Builder(
                            builder: (btnCtx) => IconButton(
                              icon: const Icon(Icons.arrow_drop_down),
                              tooltip: 'Pick from common providers',
                              onPressed: () async {
                                final box = btnCtx.findRenderObject()
                                    as RenderBox?;
                                final overlay = Overlay.of(btnCtx)
                                    .context
                                    .findRenderObject()! as RenderBox;
                                if (box == null) return;
                                final pos = RelativeRect.fromRect(
                                  Rect.fromPoints(
                                    box.localToGlobal(Offset.zero,
                                        ancestor: overlay),
                                    box.localToGlobal(
                                        box.size.bottomRight(Offset.zero),
                                        ancestor: overlay),
                                  ),
                                  Offset.zero & overlay.size,
                                );
                                final picked =
                                    await showMenu<_ProviderPreset>(
                                  context: btnCtx,
                                  position: pos,
                                  color: EmberColors.bgPanel,
                                  items: [
                                    for (final preset in _providerPresets)
                                      PopupMenuItem<_ProviderPreset>(
                                        value: preset,
                                        child: Text(preset.label),
                                      ),
                                  ],
                                );
                                if (picked != null) {
                                  setState(() {
                                    if (nameCtl.text.trim().isEmpty ||
                                        nameCtl.text.trim() ==
                                            'New provider') {
                                      nameCtl.text = picked.name;
                                    }
                                    urlCtl.text = picked.baseUrl;
                                    if (modelCtl.text.trim().isEmpty &&
                                        picked.defaultModel.isNotEmpty) {
                                      modelCtl.text = picked.defaultModel;
                                    }
                                  });
                                }
                              },
                            ),
                          )
                        : null,
                  ),
                ),
              const SizedBox(height: 12),
              TextField(
                controller: keyCtl,
                obscureText: true,
                decoration: InputDecoration(
                  labelText: kind == ProviderKind.proxy
                      ? 'Proxy password'
                      : 'API key',
                  helperText: kind == ProviderKind.localhost
                      ? 'Optional — local servers (LM Studio, Ollama) usually '
                          'ignore this. Leave blank.'
                      : null,
                  helperMaxLines: 2,
                ),
              ),
              const SizedBox(height: 12),
              Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: TextField(
                      controller: modelCtl,
                      decoration: const InputDecoration(
                        labelText: 'Model',
                        hintText: 'gpt-4o-mini',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  OutlinedButton.icon(
                    icon: const Icon(Icons.search, size: 14),
                    label: const Text('Browse'),
                    onPressed: () async {
                      // Build an in-flight provider so the picker can call
                      // /v1/models even before the row is saved.
                      final temp = ApiProvider(
                        id: 'pick',
                        name: nameCtl.text.trim(),
                        kind: kind,
                        baseUrl: urlCtl.text.trim(),
                        apiKey: keyCtl.text.trim(),
                        model: modelCtl.text.trim(),
                      );
                      if (temp.baseUrl.isEmpty) {
                        ScaffoldMessenger.of(ctx).showSnackBar(
                          const SnackBar(
                              content:
                                  Text('Fill in the base URL first.')),
                        );
                        return;
                      }
                      final picked = await showModelPicker(ctx, temp);
                      if (picked != null) {
                        setState(() => modelCtl.text = picked);
                      }
                    },
                  ),
                ],
              ),
              if (kind == ProviderKind.localhost)
                const Padding(
                  padding: EdgeInsets.only(top: 6),
                  child: Text(
                    'Browse lists the models on your server. LM Studio / '
                    'Ollama auto-load whichever one you pick — you don\'t '
                    'have to load it there first. (Some servers ignore the '
                    'name and just use the one already loaded.)',
                    style: TextStyle(fontSize: 11, color: EmberColors.textMid),
                  ),
                ),
              const SizedBox(height: 16),
              ExpansionTile(
                tilePadding: EdgeInsets.zero,
                childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
                shape: const Border(),
                collapsedShape: const Border(),
                title: const Text(
                  'Advanced',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                    color: EmberColors.textMid,
                  ),
                ),
                children: [
                  // Wave CY.18.120: preload-on-launch toggle — localhost
                  // providers only (warm-up is meaningless for hosted APIs
                  // that never cold-load). Fires a tiny request on app start
                  // and right after saving so the first real message doesn't
                  // wait for the model to JIT-load.
                  if (kind == ProviderKind.localhost) ...[
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        'Preload model on launch',
                        style: TextStyle(
                            fontSize: 13, color: EmberColors.textHigh),
                      ),
                      subtitle: const Text(
                        'Fires a tiny request to load the model on app start '
                        'and right after saving, so the first real message '
                        'doesn\'t wait for a cold load. Local servers only.',
                        style: TextStyle(
                            fontSize: 11,
                            height: 1.4,
                            color: EmberColors.textDim),
                      ),
                      value: warmUp,
                      activeThumbColor: EmberColors.primary,
                      onChanged: (v) => setState(() => warmUp = v),
                    ),
                    const SizedBox(height: 8),
                  ],
                  // Wave CY.18.100: manual context-window override.
                  TextField(
                    controller: ctxCtl,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(
                      labelText: 'Context window (tokens) — optional',
                      hintText: 'auto-detected; e.g. 128000',
                    ),
                  ),
                  const Padding(
                    padding: EdgeInsets.only(top: 4, bottom: 14),
                    child: Text(
                      'Leave empty to auto-detect from the provider. Set a '
                      'value only if the usage bar shows "unknown" — it '
                      'overrides auto-detection.',
                      style: TextStyle(
                          color: EmberColors.textDim,
                          fontSize: 11,
                          height: 1.4),
                    ),
                  ),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Extra request body parameters (JSON)',
                        style: TextStyle(
                          fontSize: 12,
                          color: EmberColors.textMid,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  TextField(
                    controller: extraParamsCtl,
                    minLines: 4,
                    maxLines: 10,
                    style: const TextStyle(
                        fontFamily: 'monospace', fontSize: 12),
                    decoration: InputDecoration(
                      hintText: '{\n'
                          '  "reasoning": {"effort": "none"}\n'
                          '}',
                      hintStyle: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: EmberColors.textDim),
                      errorText: extraParamsError,
                      border: const OutlineInputBorder(),
                    ),
                    onChanged: (_) {
                      if (extraParamsError != null) {
                        setState(() => extraParamsError = null);
                      }
                    },
                  ),
                  const SizedBox(height: 8),
                  const Padding(
                    padding: EdgeInsets.only(bottom: 4),
                    child: Text(
                      'Spread into every chat request to this provider. '
                      'Use it to pass provider-specific knobs Pyre doesn\'t '
                      'model directly — most commonly to disable reasoning:',
                      style: TextStyle(
                          color: EmberColors.textDim,
                          fontSize: 11,
                          height: 1.4),
                    ),
                  ),
                  const _ParamHint(
                    label: 'Qwen 3.x',
                    body: '{"reasoning": {"effort": "none"}}',
                  ),
                  const _ParamHint(
                    label: 'OpenAI o-series / Grok 4',
                    body: '{"reasoning_effort": "low"}',
                  ),
                  const _ParamHint(
                    label: 'DeepSeek R1 (some gateways)',
                    body: '{"include_reasoning": false}',
                  ),
                  const _ParamHint(
                    label: 'HF Qwen-coder + others',
                    body: '{"enable_thinking": false}',
                  ),
                  const SizedBox(height: 4),
                  const Text(
                    'Pyre-managed fields (model, messages, stream, '
                    'temperature, top_p, max_tokens, penalties) take '
                    'precedence — anything else here is forwarded as-is.',
                    style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 10,
                        height: 1.4),
                  ),
                  // Wave CY.18.267 (Pyre 1.1): SillyTavern-style prompt
                  // post-processing. Reshapes the outgoing message array to
                  // match strict OpenAI-compatible models. Default None =
                  // standard OpenAI format (no change).
                  const SizedBox(height: 16),
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Prompt post-processing',
                        style: TextStyle(
                          fontSize: 12,
                          color: EmberColors.textMid,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  DropdownButtonFormField<PromptPostProcessing>(
                    initialValue: postProcessing,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      contentPadding: EdgeInsets.symmetric(
                          horizontal: 12, vertical: 8),
                    ),
                    items: const [
                      DropdownMenuItem(
                        value: PromptPostProcessing.none,
                        child: Text('None (default)'),
                      ),
                      DropdownMenuItem(
                        value: PromptPostProcessing.mergeConsecutive,
                        child: Text('Merge consecutive'),
                      ),
                      DropdownMenuItem(
                        value: PromptPostProcessing.semiStrict,
                        child: Text('Semi-strict'),
                      ),
                      DropdownMenuItem(
                        value: PromptPostProcessing.strict,
                        child: Text('Strict'),
                      ),
                      DropdownMenuItem(
                        value: PromptPostProcessing.singleUser,
                        child: Text('Single user message'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) {
                        setState(() => postProcessing = v);
                      }
                    },
                  ),
                  const SizedBox(height: 6),
                  const Text(
                    'Reshapes the message list to match strict model '
                    'requirements. Try Strict or Single user message if a '
                    'model (DeepSeek, GLM, Mistral…) ignores instructions. '
                    'Default None = standard OpenAI format.',
                    style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 11,
                        height: 1.4),
                  ),
                ],
              ),
              ],
            ),
          ),
        ),
        actions: [
          // Wave CY.18.266: delete an existing provider. There was no UI to
          // remove a provider anywhere before — only add/edit/reorder. Calls
          // store.removeProvider (records a tombstone so a LAN-synced delete
          // propagates, and drops the key from OS-secure storage).
          if (!isNew)
            TextButton(
              onPressed: () async {
                final confirmed = await showDialog<bool>(
                  context: ctx,
                  builder: (dctx) => AlertDialog(
                    backgroundColor: EmberColors.bgPanel,
                    title: const Text('Delete provider?'),
                    content: Text(
                      'Remove "${existing.name}" and its saved API key from '
                      'this device? This can\'t be undone.',
                    ),
                    actions: [
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, false),
                        child: const Text('Cancel'),
                      ),
                      TextButton(
                        onPressed: () => Navigator.pop(dctx, true),
                        child: const Text('Delete',
                            style: TextStyle(color: Colors.redAccent)),
                      ),
                    ],
                  ),
                );
                if (confirmed != true) return;
                store.removeProvider(existing.id);
                if (ctx.mounted) Navigator.pop(ctx);
              },
              child: const Text('Delete',
                  style: TextStyle(color: Colors.redAccent)),
            ),
          TextButton(
            onPressed: () => _testConnection(ctx, nameCtl, urlCtl, keyCtl,
                modelCtl, kind),
            child: const Text('Test'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              // Parse extra params (must be valid JSON object or empty).
              // Invalid JSON keeps the dialog open with an inline error
              // so the user can fix it instead of silently losing data.
              final raw = extraParamsCtl.text.trim();
              Map<String, dynamic> extras = {};
              if (raw.isNotEmpty) {
                try {
                  final decoded = jsonDecode(raw);
                  if (decoded is! Map) {
                    setState(() => extraParamsError =
                        'Extra params must be a JSON object');
                    return;
                  }
                  extras = decoded.cast<String, dynamic>();
                } catch (e) {
                  setState(() => extraParamsError = 'Invalid JSON: $e');
                  return;
                }
              }
              // Wave CY.18.100: parse the optional manual context window.
              // Empty / invalid → null (auto-detect).
              final ctxRaw = ctxCtl.text.trim();
              final ctxWindow =
                  ctxRaw.isEmpty ? null : int.tryParse(ctxRaw);
              // Wave CY.18.120: hold the persisted provider so we can fire
              // a warm-up off it after the store write (local + opted-in).
              final ApiProvider savedProvider;
              if (isNew) {
                final p = store.addProvider(
                  name: nameCtl.text.trim().isEmpty
                      ? 'Provider'
                      : nameCtl.text.trim(),
                  kind: kind,
                  baseUrl: urlCtl.text.trim(),
                  apiKey: keyCtl.text.trim(),
                  model: modelCtl.text.trim(),
                );
                // Wave CY.18.120: addProvider doesn't take warmUpOnLaunch, so
                // set it here and persist. Only force a second write when the
                // value diverges from the default-true (or extras/ctx are set)
                // to avoid a redundant store bump on the common case.
                p.warmUpOnLaunch = warmUp;
                // Wave CY.18.267: also force the second write when a non-default
                // post-processing mode was picked, so it persists immediately.
                if (extras.isNotEmpty ||
                    ctxWindow != null ||
                    !warmUp ||
                    postProcessing != PromptPostProcessing.none) {
                  p.extraParams = extras;
                  p.contextWindow = ctxWindow;
                  p.promptPostProcessing = postProcessing;
                  store.updateProvider(p);
                }
                savedProvider = p;
              } else {
                existing
                  ..name = nameCtl.text.trim()
                  ..baseUrl = urlCtl.text.trim()
                  ..apiKey = keyCtl.text.trim()
                  ..model = modelCtl.text.trim()
                  ..kind = kind
                  ..extraParams = extras
                  ..contextWindow = ctxWindow
                  ..warmUpOnLaunch = warmUp
                  // Wave CY.18.267: persist the post-processing mode.
                  ..promptPostProcessing = postProcessing;
                store.updateProvider(existing);
                savedProvider = existing;
              }
              // Drop any cached auto-detected window — model/url/override
              // may have changed.
              invalidateContextWindowCache(
                  isNew ? '' : existing.id);
              // Wave CY.18.120: kick off a model preload right after saving a
              // local provider that opted in, so adding/editing it immediately
              // starts the (slow) JIT load instead of waiting for the first
              // real message. Fire-and-forget — warmUpProvider swallows errors.
              if (kind == ProviderKind.localhost &&
                  warmUp &&
                  modelCtl.text.trim().isNotEmpty) {
                unawaited(warmUpProvider(savedProvider));
              }
              Navigator.pop(ctx);
            },
            child: Text(isNew ? 'Add' : 'Save'),
          ),
        ],
      ),
    ),
  );
}

/// Small two-column hint inside the Advanced section — a model family
/// label and a copy-pasteable JSON snippet that disables reasoning for
/// that family. Tap the snippet to copy it to clipboard.
class _ParamHint extends StatelessWidget {
  final String label;
  final String body;
  const _ParamHint({required this.label, required this.body});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 130,
            child: Text(
              '$label:',
              style: const TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            child: GestureDetector(
              onTap: () async {
                await Clipboard.setData(ClipboardData(text: body));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied.')),
                  );
                }
              },
              child: Text(
                body,
                style: const TextStyle(
                  color: EmberColors.primary,
                  fontSize: 11,
                  fontFamily: 'monospace',
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
