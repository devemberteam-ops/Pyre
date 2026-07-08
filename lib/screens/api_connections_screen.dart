import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import '../models/models.dart';
import '../services/chat_api.dart';
import '../services/hub_provider.dart';
import '../services/lan_client.dart';
import '../services/model_metadata.dart';
import '../services/prompt_post_processing.dart';
import '../services/resolvers.dart' show isProviderHostAllowed;
import '../state/app_store.dart';
import '../theme.dart';
import '../widgets/empty_state.dart';
import '../widgets/how_it_works_card.dart';
import 'model_picker_sheet.dart';
import 'smart_fallback_screen.dart';

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
      // 2026-07-07 (Gui): on the WEB build paired to a self-host hub, this
      // screen must show the SERVER's provider (its key lives on the hub, not
      // in this browser) — otherwise a fresh/incognito tab looks unconfigured
      // even though chat works and the whole switch-provider flow needs it
      // visible. So when paired on web, always render the list body (with the
      // hub card at top), never the bare "connect a provider" empty state.
      body: (store.providers.isEmpty &&
              !(kIsWeb && LanClient.instance.isPaired))
          // 2026-07-03: this is the make-or-break first screen (the app can't
          // write a reply without a provider). The old weak "Tap + to add an
          // OpenAI-compatible endpoint" jargon-line had no button and no hint
          // where a key comes from. Use the house empty-state with a real CTA.
          ? EmptyState(
              icon: Icons.cloud_outlined,
              title: 'Connect an AI provider',
              subtitle:
                  'Pyre needs an AI service to write replies — it brings no '
                  'model of its own. Add one (OpenRouter has free models to '
                  'start), then paste the API key from that service\'s site.',
              ctaLabel: 'Add a provider',
              onCta: () => _editProvider(context, null),
            )
          : Column(
              children: [
                if (kIsWeb && LanClient.instance.isPaired)
                  const Padding(
                    padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: _HubProviderCard(),
                  ),
                // 2026-07-03: the app's make-or-break screen was the only
                // major one without the house "How it works" explainer (regex,
                // fallback, memory, script all have one). Collapsed by default.
                const Padding(
                  padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: HowItWorksCard(
                    title: 'How connections work',
                    subtitle: 'BYOK — your key, your model, on your device.',
                    sections: [
                      HowItWorksSection('What a provider is', [
                        HowItWorksBlock.paragraph(
                            'Pyre brings no AI of its own — it connects to a '
                            'service that writes the replies (OpenRouter, '
                            'OpenAI, a local model…). You add the service and '
                            'paste **its** API key.'),
                      ]),
                      HowItWorksSection('Your key stays yours', [
                        HowItWorksBlock.paragraph(
                            'Keys are kept in your device\'s secure store, '
                            'never leave the device, and are left out of '
                            'backups unless you tick that box.'),
                      ]),
                      HowItWorksSection('Tapping + the order', [
                        HowItWorksBlock.bullet(
                            '**Tap a connection** to make it the one your '
                            'chats use (the CHAT badge moves to it).'),
                        HowItWorksBlock.bullet(
                            '**The list is the fallback order** — if one '
                            'fails or refuses, Pyre offers the next. Drag to '
                            'reorder.'),
                      ]),
                    ],
                  ),
                ),
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
                  Padding(
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
                                style: TextStyle(
                                    color: EmberColors.textMid,
                                    fontSize: 12),
                              ),
                              Text(
                                'model: ${p.model.isEmpty ? "(none)" : p.model}',
                                style: TextStyle(
                                    color: EmberColors.textMid,
                                    fontSize: 12),
                              ),
                            ],
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // 2026-07-03: kebab menu — matches the app's
                              // convention (characters/personas/lorebooks all
                              // use one) and un-stacks the edit dialog, which
                              // used to carry Delete + Duplicate among 5 piled
                              // action buttons.
                              PopupMenuButton<String>(
                                icon: Icon(Icons.more_vert,
                                    color: EmberColors.textMid),
                                onSelected: (choice) async {
                                  if (choice == 'edit') {
                                    _editProvider(context, p);
                                  } else if (choice == 'duplicate') {
                                    store.duplicateProvider(p.id);
                                  } else if (choice == 'delete') {
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (dctx) => AlertDialog(
                                        backgroundColor: EmberColors.bgPanel,
                                        title:
                                            const Text('Delete provider?'),
                                        content: Text(
                                          'Remove "${p.name}" and its saved '
                                          'API key from this device? This '
                                          'can\'t be undone.',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, false),
                                            child: const Text('Cancel'),
                                          ),
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(dctx, true),
                                            child: const Text('Delete',
                                                style: TextStyle(
                                                    color: Colors.redAccent)),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed == true) {
                                      store.removeProvider(p.id);
                                    }
                                  }
                                },
                                itemBuilder: (_) => const [
                                  PopupMenuItem(
                                      value: 'edit', child: Text('Edit')),
                                  PopupMenuItem(
                                      value: 'duplicate',
                                      child: Text('Duplicate')),
                                  PopupMenuItem(
                                      value: 'delete',
                                      child: Text('Delete',
                                          style: TextStyle(
                                              color: Colors.redAccent))),
                                ],
                              ),
                              // Drag handle (only useful with 2+; harmless
                              // with one). Explicit listener so the rest of
                              // the row stays tappable to set-as-CHAT.
                              if (store.providers.length >= 2)
                                ReorderableDragStartListener(
                                  index: idx,
                                  child: Padding(
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

/// Wave CY.18.99: collapsed "Advanced" section. The provider-fallback
/// feature now lives on its own [SmartFallbackScreen] (with a "How it
/// works" explainer + the master toggle) so it's discoverable and
/// documented; this is just the nav row that opens it. Collapsed by
/// default so a new user never feels they must touch it.
///
/// BEHAVIOUR UNCHANGED — the toggle still binds to
/// `uiPrefs.askToSwitchOnFailure`; it just moved to the dedicated screen.
class _AdvancedFallbackTile extends StatelessWidget {
  final AppStore store;
  const _AdvancedFallbackTile({required this.store});

  @override
  Widget build(BuildContext context) {
    final on = store.uiPrefs.askToSwitchOnFailure;
    return Theme(
      // Strip the default ExpansionTile divider lines for a cleaner look.
      data: Theme.of(context)
          .copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        title: const Text('Advanced',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        children: [
          ListTile(
            leading: Icon(Icons.alt_route, color: EmberColors.textMid),
            title: const Text('Smart provider fallback',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600)),
            subtitle: Text(
              on
                  ? 'On — if a provider fails or refuses, Pyre offers the '
                      'next one.'
                  : 'Off — a failed reply just surfaces the error.',
              style: TextStyle(
                  color: EmberColors.textMid, fontSize: 12, height: 1.4),
            ),
            trailing: Icon(Icons.chevron_right,
                color: EmberColors.textDim, size: 22),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => const SmartFallbackScreen()),
            ),
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
            Text(
              'By default every call uses your active chat provider. Pin a '
              'different one here for the Creator or for image analysis — '
              'e.g. DeepSeek for chat and creator text, Qwen-VL only for '
              'vision. Vision falls back to creator → chat.',
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
            // 2026-07-03 (Gui): the IMPERSONATE + GUIDE routes were cut —
            // they're the same text generation as chat, so a dedicated model
            // wasn't worth the two extra dropdowns. Both use the chat provider.
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

/// Small caption above a control in the add/edit-provider dialog. Two of the
/// dialog's controls were unlabeled pill rows a novice couldn't tell apart.
class _DialogFieldLabel extends StatelessWidget {
  final String text;
  const _DialogFieldLabel(this.text);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Text(
        text.toUpperCase(),
        style: TextStyle(
          color: EmberColors.textDim,
          fontSize: 10,
          fontWeight: FontWeight.w600,
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
  ApiFormat format,
) async {
  final messenger = ScaffoldMessenger.of(context);
  final base = urlCtl.text.trim();
  if (base.isEmpty) {
    messenger.showSnackBar(
        const SnackBar(content: Text('Fill in the base URL first.')));
    return;
  }
  // Mega-audit 2026-06-05 (H-7): SSRF gate. Refuse to probe a private /
  // internal host for an External/proxy provider (a synced/imported record
  // could point it there). The explicit Localhost kind stays allowed — a
  // local server (LM Studio/Ollama) is exactly what it's for.
  if (!isProviderHostAllowed(base,
      isLocalhostKind: kind == ProviderKind.localhost)) {
    messenger.showSnackBar(const SnackBar(
        content: Text('That URL points at a private or internal address. '
            'For a local server, set the type to Localhost.')));
    return;
  }
  final url = buildChatUrl(base, 'models');
  try {
    final resp = await http.get(
      Uri.parse(url),
      // 2026-07-03: match the provider's dialect — Anthropic needs
      // x-api-key + anthropic-version, not Bearer (a valid Claude key was
      // getting a bogus 401 here). Both OpenAI and Anthropic expose /models.
      headers: providerRestAuthHeaders(
          format: format, apiKey: keyCtl.text.trim()),
    );
    if (resp.statusCode >= 400) {
      // 2026-07-03: lead with a human, actionable hint per status class so a
      // novice knows whether it's the key, the URL, or the network — then the
      // scrubbed raw first line for anyone who wants the detail. (H-7 audit
      // [providers-01]: scrub reflected key/token before it hits the SnackBar.)
      final scrubbed = scrubProviderBody(
        resp.body.split('\n').first,
        apiKey: keyCtl.text.trim(),
      );
      final hint = (resp.statusCode == 401 || resp.statusCode == 403)
          ? 'The key was rejected — check you pasted the whole key.'
          : (resp.statusCode == 404)
              ? 'Nothing answered at this URL — check the Base URL.'
              : 'The provider returned an error.';
      messenger.showSnackBar(SnackBar(
          content: Text('$hint (HTTP ${resp.statusCode}: $scrubbed)')));
      return;
    }
    // Test only verifies the endpoint + key; it doesn't check the model name.
    final modelNote = modelCtl.text.trim().isEmpty
        ? ' — but no model is set yet, so pick one before chatting.'
        : '';
    messenger.showSnackBar(
      SnackBar(content: Text('Connection OK ✓$modelNote')),
    );
  } catch (e) {
    // A thrown exception here is a transport failure (DNS, socket, TLS,
    // timeout) — never an HTTP status — so the friendly cause is "couldn't
    // reach the server", not "bad key".
    messenger.showSnackBar(SnackBar(
        content: Text('Couldn\'t reach the server — check the URL and your '
            'connection. ($e)')));
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
  // Pyre 1.1.3: the wire format (OpenAI-compatible vs native Anthropic).
  ApiFormat format = existing?.format ?? ApiFormat.openai;
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
                // 2026-07-03: caption the two segmented controls — a novice
                // couldn't tell them apart (both were unlabeled pill rows).
                _DialogFieldLabel('Where it runs'),
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
                const SizedBox(height: 10),
                _DialogFieldLabel('API format'),
                SegmentedButton<ApiFormat>(
                  segments: const [
                    ButtonSegment(
                        value: ApiFormat.openai,
                        label: Text('OpenAI-compatible')),
                    ButtonSegment(
                        value: ApiFormat.anthropic, label: Text('Anthropic')),
                  ],
                  selected: {format},
                  showSelectedIcon: false,
                  onSelectionChanged: (s) {
                    setState(() {
                      format = s.first;
                      if (format == ApiFormat.anthropic &&
                          urlCtl.text.isEmpty) {
                        urlCtl.text = 'https://api.anthropic.com';
                      }
                    });
                  },
                ),
                if (format == ApiFormat.anthropic) ...[
                  const SizedBox(height: 6),
                  Text(
                    'Native Claude API — base URL https://api.anthropic.com, '
                    'paste your Anthropic key (sk-ant-…). Heads-up: Claude '
                    'refuses NSFW the same here as through any proxy.',
                    style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 11,
                        height: 1.4),
                  ),
                ],
                if (kind == ProviderKind.proxy) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: EmberColors.bgElevated,
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: EmberColors.stroke),
                    ),
                    child: Row(
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
                        // 2026-07-03: carry the format so the picker probes
                        // /models with the right dialect (Anthropic browse
                        // used to 401 with Bearer).
                        format: format,
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
                Padding(
                  padding: const EdgeInsets.only(top: 6),
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
                title: Text(
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
                      title: Text(
                        'Preload model on launch',
                        style: TextStyle(
                            fontSize: 13, color: EmberColors.textHigh),
                      ),
                      subtitle: Text(
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
                  Padding(
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
                  Align(
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
                      hintStyle: TextStyle(
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
                  Padding(
                    padding: const EdgeInsets.only(bottom: 4),
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
                  Text(
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
                  Align(
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
                  Text(
                    'Reshapes the message list to match strict model '
                    'requirements. Try Strict or Single user message if a '
                    'model (DeepSeek, GLM, Mistral…) ignores instructions. '
                    'Default None = standard OpenAI format.',
                    style: TextStyle(
                        color: EmberColors.textDim,
                        fontSize: 11,
                        height: 1.4),
                  ),
                  const _PostProcessingHelp(),
                ],
              ),
              ],
            ),
          ),
        ),
        actions: [
          // 2026-07-03: Delete + Duplicate moved to the list-row kebab (they
          // were 2 of 5 stacked action buttons here, with destructive Delete
          // in the pile). This dialog now closes with just Test / Cancel /
          // Save — its actual job.
          TextButton(
            onPressed: () => _testConnection(ctx, nameCtl, urlCtl, keyCtl,
                modelCtl, kind, format),
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
                p.format = format;
                // Wave CY.18.267: also force the second write when a non-default
                // post-processing mode (or non-OpenAI format) was picked, so it
                // persists immediately.
                if (extras.isNotEmpty ||
                    ctxWindow != null ||
                    !warmUp ||
                    postProcessing != PromptPostProcessing.none ||
                    format != ApiFormat.openai) {
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
                  ..promptPostProcessing = postProcessing
                  // Pyre 1.1.3: persist the wire format (OpenAI vs Anthropic).
                  ..format = format;
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
              // 2026-07-07 (Gui): on the WEB build, chat proxies through the
              // paired self-host hub, which needs THIS provider server-side.
              // Configuring it here in API Connections pushes it to the hub so
              // it "just works" — no separate screen. Silent no-op on native
              // (kIsWeb false) or against a desktop hub (unsupported → 404).
              // The typed key rides once to the hub, which stores it.
              if (kIsWeb) {
                unawaited(setHubProvider(
                  baseUrl: savedProvider.baseUrl,
                  model: savedProvider.model,
                  apiKey: keyCtl.text.trim(),
                ));
              }
              Navigator.pop(ctx);
            },
            child: Text(isNew ? 'Add' : 'Save'),
          ),
        ],
      ),
    ),
  );
  // C-6: dispose all 6 dialog controllers once it closes — notably keyCtl,
  // which would otherwise leave the API key string lingering in the heap.
  for (final c in <TextEditingController>[
    nameCtl, urlCtl, keyCtl, modelCtl, ctxCtl, extraParamsCtl,
  ]) {
    c.dispose();
  }
}

/// 2026-07-07 (Gui): on the WEB build paired to a self-host hub, the provider
/// (and its key) lives on the SERVER, not in this browser. This card surfaces
/// the server's current provider so a paired tab isn't confusingly empty —
/// chat works off it, and the switch-provider flow needs it visible. Reads the
/// masked /admin/provider; renders nothing against a desktop hub (404) or when
/// not paired.
class _HubProviderCard extends StatefulWidget {
  const _HubProviderCard();

  @override
  State<_HubProviderCard> createState() => _HubProviderCardState();
}

class _HubProviderCardState extends State<_HubProviderCard> {
  HubProviderResult? _res;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await fetchHubProvider();
    if (mounted) setState(() => _res = r);
  }

  @override
  Widget build(BuildContext context) {
    final res = _res;
    // Nothing to show until the probe resolves, or if this hub isn't a
    // headless self-host (a desktop hub manages its own providers).
    if (res == null || !res.supported) return const SizedBox.shrink();
    final s = res.status;
    final configured = s?.configured == true;

    return Card(
      color: EmberColors.bgElevated,
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(
              configured ? Icons.dns_outlined : Icons.cloud_off_outlined,
              size: 20,
              color: configured ? EmberColors.primary : EmberColors.textMid,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    configured
                        ? 'This server\'s AI provider'
                        : 'This server has no AI provider yet',
                    style: const TextStyle(
                        fontWeight: FontWeight.w600, fontSize: 14),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    configured
                        ? '${s!.model} · ${s.baseUrl}\n'
                            'Key set on the server ✓ — every paired device uses '
                            'it. Add or edit a connection below to change it.'
                        : 'Add a connection with + (top-right) and its API key '
                            'is saved on the server for every device that '
                            'connects.',
                    style: TextStyle(
                        color: EmberColors.textMid, fontSize: 12, height: 1.4),
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
              style: TextStyle(
                color: EmberColors.textMid,
                fontSize: 11,
              ),
            ),
          ),
          Expanded(
            // Pyre 1.1.3 (Gui, web): was a GestureDetector around a plain Text
            // — invisible tap-to-copy AND not selectable, so on web (esp. an
            // insecure-context LAN IP where the async clipboard is unavailable)
            // there was NO way to grab the snippet. SelectableText always allows
            // manual select + copy; the button below is the one-tap path.
            child: SelectableText(
              body,
              style: TextStyle(
                color: EmberColors.primary,
                fontSize: 11,
                fontFamily: 'monospace',
              ),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            iconSize: 16,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
            tooltip: 'Copy',
            icon: Icon(Icons.copy, color: EmberColors.textMid),
            onPressed: () async {
              try {
                await Clipboard.setData(ClipboardData(text: body));
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Copied.')),
                  );
                }
              } catch (_) {
                if (context.mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                        content: Text(
                            'Copy unavailable here — select the text and copy manually.')),
                  );
                }
              }
            },
          ),
        ],
      ),
    );
  }
}

/// Inline, collapsed help for the per-provider "Prompt post-processing"
/// dropdown. Post-processing is provider-scoped (it lives in each
/// provider's edit form), so it stays inline rather than becoming a
/// top-level menu — this expander just explains each mode in place.
class _PostProcessingHelp extends StatelessWidget {
  const _PostProcessingHelp();

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
      child: ExpansionTile(
        tilePadding: EdgeInsets.zero,
        childrenPadding: const EdgeInsets.only(top: 4, bottom: 4),
        title: Row(
          children: [
            Icon(Icons.help_outline, size: 15, color: EmberColors.primary),
            SizedBox(width: 6),
            Text('What do these modes do?',
                style: TextStyle(fontSize: 12, color: EmberColors.textMid)),
          ],
        ),
        children: const [
          _PostProcModeRow('None',
              'Send the message list as-is, standard OpenAI format. The '
              'right choice for most providers.'),
          _PostProcModeRow('Merge consecutive',
              'Combine back-to-back messages from the same role into one. '
              'Helps providers that reject two user (or two assistant) '
              'turns in a row.'),
          _PostProcModeRow('Semi-strict',
              'Merge consecutive turns and tidy the layout, but keep the '
              'system prompt separate. A gentle fit for picky models.'),
          _PostProcModeRow('Strict',
              'Force a clean user/assistant alternation with the system '
              'prompt folded in. Needed by some DeepSeek / GLM / '
              'Mistral-style endpoints that demand strict turn order.'),
          _PostProcModeRow('Single user message',
              'Flatten the whole conversation into one user message. The '
              'most aggressive option — use it when a model still ignores '
              'instructions under Strict.'),
        ],
      ),
    );
  }
}

/// One labelled mode line inside [_PostProcessingHelp].
class _PostProcModeRow extends StatelessWidget {
  final String name;
  final String body;
  const _PostProcModeRow(this.name, this.body);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text.rich(
        TextSpan(
          style: TextStyle(
              color: EmberColors.textMid, fontSize: 11, height: 1.4),
          children: [
            TextSpan(
                text: '$name — ',
                style: TextStyle(
                    color: EmberColors.textHigh,
                    fontWeight: FontWeight.w600)),
            TextSpan(text: body),
          ],
        ),
      ),
    );
  }
}
