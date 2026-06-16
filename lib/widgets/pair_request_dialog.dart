// Desktop-only "Allow this device to pair?" dialog for the confirm-pairing
// flow (release/1.1.3). Shown on the HOST when a web/device hits
// POST /pair/request. The user's Allow click is the security gate — a
// malicious cross-origin / DNS-rebound page can only make this dialog appear;
// without an Allow tap nothing is paired and no bearer is minted.

import 'package:flutter/material.dart';

import '../services/pairing_requests.dart';
import '../services/pyre_server.dart';

Future<void> showPairRequestDialog(
    BuildContext context, PendingPairRequest req) async {
  await showDialog<void>(
    context: context,
    // Explicit choice required — a stray tap outside must not auto-resolve.
    barrierDismissible: false,
    builder: (ctx) {
      return AlertDialog(
        title: const Text('Allow this device to pair?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
                'A device wants to pair with this PC and read/write your '
                'library over the local network.'),
            const SizedBox(height: 14),
            Text('From:  ${req.requesterLabel}',
                style: const TextStyle(fontWeight: FontWeight.w600)),
            if (req.deviceName.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text('Name:  ${req.deviceName.trim()}'),
              ),
            const SizedBox(height: 14),
            Text(
              'Only allow this if you just opened Pyre in a browser yourself. '
              'If you weren’t expecting it, tap Deny.',
              style: TextStyle(
                  fontSize: 12.5,
                  color: Theme.of(ctx).colorScheme.onSurfaceVariant),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () {
              PyreServer.instance.denyPairRequest(req.requestId);
              Navigator.of(ctx).pop();
            },
            child: const Text('Deny'),
          ),
          TextButton(
            onPressed: () async {
              final nav = Navigator.of(ctx);
              await PyreServer.instance.approvePairRequest(req.requestId);
              nav.pop();
            },
            style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.primary),
            child: const Text('Allow'),
          ),
        ],
      );
    },
  );
}
