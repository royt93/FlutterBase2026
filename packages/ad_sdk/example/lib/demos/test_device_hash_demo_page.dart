// T117 — test device hash demo page. Split out of main.dart.
import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class TestDeviceHashDemoPage extends StatelessWidget {
  const TestDeviceHashDemoPage({super.key});

  Future<void> _copy(BuildContext context, String label, String value) async {
    await Clipboard.setData(ClipboardData(text: value));
    if (!context.mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text('$label copied to clipboard')));
  }

  @override
  Widget build(BuildContext context) {
    final gaid = AdManager().currentDeviceGaid;
    final hint = AdManager().adMobTestDeviceHashHint();
    return Scaffold(
      appBar: AppBar(title: const Text('AdMob test-device hash')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Current device GAID',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            SelectableText(
                gaid.isEmpty ? '(empty — init not done yet, or LAT on)' : gaid),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy GAID (not the AdMob hash!)'),
              onPressed:
                  gaid.isEmpty ? null : () => _copy(context, 'GAID', gaid),
            ),
            const SizedBox(height: 20),
            Text('adMobTestDeviceHashHint()',
                style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 4),
            Expanded(child: SingleChildScrollView(child: SelectableText(hint))),
            const SizedBox(height: 8),
            ElevatedButton.icon(
              icon: const Icon(Icons.copy),
              label: const Text('Copy hint text'),
              onPressed: () => _copy(context, 'Hint', hint),
            ),
          ],
        ),
      ),
    );
  }
}
