import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/models.dart';
import '../services/chat_api.dart';
import '../theme.dart';

/// Bottom sheet that lists models from an OpenAI-compatible provider's
/// `/v1/models` endpoint, with a search box. Returns the picked id via
/// `Navigator.pop(context, id)`.
class ModelPickerSheet extends StatefulWidget {
  final ApiProvider provider;
  const ModelPickerSheet({super.key, required this.provider});

  @override
  State<ModelPickerSheet> createState() => _ModelPickerSheetState();
}

class _ModelPickerSheetState extends State<ModelPickerSheet> {
  List<String> _all = [];
  String _query = '';
  bool _loading = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _fetch();
  }

  Future<void> _fetch() async {
    final url = buildChatUrl(widget.provider.baseUrl, 'models');
    try {
      final resp = await http.get(
        Uri.parse(url),
        headers: {
          if (widget.provider.apiKey.isNotEmpty)
            'Authorization': 'Bearer ${widget.provider.apiKey}',
          ...widget.provider.headers,
        },
      );
      if (resp.statusCode >= 400) {
        throw 'HTTP ${resp.statusCode}: ${resp.body}';
      }
      final body = jsonDecode(resp.body);
      final list = (body is Map && body['data'] is List)
          ? (body['data'] as List)
          : (body is List ? body : const []);
      final ids = <String>[];
      for (final item in list) {
        if (item is Map && item['id'] is String) {
          ids.add(item['id'] as String);
        } else if (item is String) {
          ids.add(item);
        }
      }
      ids.sort();
      if (!mounted) return;
      setState(() {
        _all = ids;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _query.isEmpty
        ? _all
        : _all.where((m) => m.toLowerCase().contains(_query)).toList();

    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.7,
      maxChildSize: 0.92,
      minChildSize: 0.4,
      builder: (_, scroll) => Container(
        color: EmberColors.bgPanel,
        child: Column(
          children: [
            const SizedBox(height: 8),
            const SizedBox(
              width: 40,
              height: 4,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  color: EmberColors.stroke,
                  borderRadius: BorderRadius.all(Radius.circular(2)),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Row(
                children: [
                  const Text('Browse models',
                      style: TextStyle(
                          fontSize: 17, fontWeight: FontWeight.w600)),
                  const Spacer(),
                  IconButton(
                    icon: const Icon(Icons.refresh,
                        color: EmberColors.textMid),
                    onPressed: () {
                      setState(() {
                        _loading = true;
                        _error = null;
                      });
                      _fetch();
                    },
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: TextField(
                decoration: const InputDecoration(
                  hintText: 'Search…',
                  prefixIcon: Icon(Icons.search, size: 18),
                  isDense: true,
                ),
                onChanged: (v) => setState(() => _query = v.toLowerCase()),
              ),
            ),
            const SizedBox(height: 8),
            Expanded(
              child: _loading
                  ? const Center(
                      child: CircularProgressIndicator(
                          color: EmberColors.primary))
                  : _error != null
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(24),
                            child: Text(
                              _error!,
                              style: const TextStyle(
                                  color: EmberColors.danger),
                            ),
                          ),
                        )
                      : ListView.builder(
                          controller: scroll,
                          itemCount: filtered.length,
                          itemBuilder: (_, i) {
                            final id = filtered[i];
                            return ListTile(
                              dense: true,
                              title: Text(id,
                                  style: const TextStyle(
                                      fontFamily: 'monospace',
                                      fontSize: 13)),
                              onTap: () => Navigator.pop(context, id),
                            );
                          },
                        ),
            ),
          ],
        ),
      ),
    );
  }
}

Future<String?> showModelPicker(BuildContext context, ApiProvider provider) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    backgroundColor: EmberColors.bgPanel,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => ModelPickerSheet(provider: provider),
  );
}
