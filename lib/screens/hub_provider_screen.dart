// 2026-07-07 (Gui): configure the SELF-HOST hub's provider from the app UI —
// so a non-technical self-hoster sets the API key in the app, never in a
// compose/env file. Only meaningful when connected to a headless hub (the
// screen probes /admin/provider and degrades gracefully otherwise).
import 'package:flutter/material.dart';

import '../services/hub_provider.dart';
import '../services/lan_client.dart';
import '../theme.dart';
import '../widgets/how_it_works_card.dart';

class HubProviderScreen extends StatefulWidget {
  const HubProviderScreen({super.key});

  @override
  State<HubProviderScreen> createState() => _HubProviderScreenState();
}

class _HubProviderScreenState extends State<HubProviderScreen> {
  final _url = TextEditingController();
  final _model = TextEditingController();
  final _key = TextEditingController();

  bool _loading = true;
  bool _saving = false;
  bool _supported = true;
  bool _obscureKey = true;
  String? _error;
  HubProviderStatus? _status;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _url.dispose();
    _model.dispose();
    _key.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final res = await fetchHubProvider();
    if (!mounted) return;
    setState(() {
      _loading = false;
      _supported = res.supported;
      _error = res.error;
      _status = res.status;
      if (res.status != null) {
        _url.text = res.status!.baseUrl;
        _model.text = res.status!.model;
      }
    });
  }

  Future<void> _save() async {
    final url = _url.text.trim();
    final model = _model.text.trim();
    if (url.isEmpty || model.isEmpty) {
      setState(() => _error = 'Base URL and model are required.');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    final res = await setHubProvider(
      baseUrl: url,
      model: model,
      apiKey: _key.text, // blank → hub keeps its stored key
    );
    if (!mounted) return;
    setState(() {
      _saving = false;
      _supported = res.supported;
      _error = res.error;
      if (res.status != null) {
        _status = res.status;
        _key.clear(); // never keep the typed key around
      }
    });
    if (res.error == null && res.status != null && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Saved. Every connected device uses it.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Server provider')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              children: [
                const HowItWorksCard(
                  title: 'How the self-host provider works',
                  subtitle: 'One key, set here, shared by everyone connected.',
                  sections: [
                    HowItWorksSection('WHAT THIS IS', [
                      HowItWorksBlock.paragraph(
                          'This sets the API the shared server uses. Enter it '
                          'once here — everyone who connects chats through the '
                          'server, so they never configure a key themselves.'),
                      HowItWorksBlock.bullet(
                          'The key is stored **on the server**, not in the '
                          'browser.'),
                      HowItWorksBlock.bullet(
                          'On a public server, put HTTPS in front so the key '
                          'isn\'t sent over the network in the clear.'),
                    ]),
                  ],
                ),
                const SizedBox(height: 12),
                if (!_supported) _unsupportedNote() else ..._form(),
              ],
            ),
    );
  }

  Widget _unsupportedNote() => Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: EmberColors.bgElevated,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: EmberColors.stroke),
        ),
        child: Text(
          LanClient.instance.isPaired
              ? 'The connected server doesn\'t support setting its provider '
                  'from the app (it\'s a desktop hub — configure the provider '
                  'in that PC\'s API Connections instead).'
              : 'Connect to a self-host server first (More → Connect to a PC / '
                  'server), then set its provider here.',
          style: TextStyle(color: EmberColors.textMid, fontSize: 13, height: 1.4),
        ),
      );

  List<Widget> _form() {
    final s = _status;
    return [
      if (s != null)
        Padding(
          padding: const EdgeInsets.only(bottom: 12),
          child: Row(
            children: [
              Icon(
                s.configured ? Icons.check_circle : Icons.error_outline,
                size: 18,
                color: s.configured ? EmberColors.primary : EmberColors.danger,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.configured
                      ? 'Configured — chat is ready for every connected device.'
                          '${s.source == 'env' ? ' (currently from the server\'s env file)' : ''}'
                      : 'Not configured yet — chat won\'t work until you set '
                          'this.',
                  style: TextStyle(
                      color: s.configured
                          ? EmberColors.textMid
                          : EmberColors.danger,
                      fontSize: 12,
                      height: 1.3),
                ),
              ),
            ],
          ),
        ),
      TextField(
        controller: _url,
        decoration: const InputDecoration(
          labelText: 'API base URL',
          hintText: 'https://api.openai.com/v1',
        ),
        keyboardType: TextInputType.url,
        autocorrect: false,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _model,
        decoration: const InputDecoration(
          labelText: 'Model',
          hintText: 'gpt-4o-mini',
        ),
        autocorrect: false,
      ),
      const SizedBox(height: 12),
      TextField(
        controller: _key,
        obscureText: _obscureKey,
        autocorrect: false,
        enableSuggestions: false,
        decoration: InputDecoration(
          labelText: 'API key',
          hintText: (s?.hasKey ?? false)
              ? 'Blank keeps it (same provider) — a new URL needs its own key'
              : 'sk-…',
          suffixIcon: IconButton(
            icon: Icon(_obscureKey ? Icons.visibility : Icons.visibility_off),
            onPressed: () => setState(() => _obscureKey = !_obscureKey),
          ),
        ),
      ),
      if (_error != null)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Text(_error!,
              style: TextStyle(color: EmberColors.danger, fontSize: 13)),
        ),
      const SizedBox(height: 20),
      FilledButton(
        onPressed: _saving ? null : _save,
        child: _saving
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2))
            : const Text('Save to server'),
      ),
    ];
  }
}
