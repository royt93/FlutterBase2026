// T117 — interstitial demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class InterstitialDemoPage extends AdScreen {
  const InterstitialDemoPage({super.key});

  @override
  State<InterstitialDemoPage> createState() => _InterstitialDemoPageState();
}

class _InterstitialDemoPageState extends AdScreenState<InterstitialDemoPage> {
  final ValueNotifier<int> _shownCount = ValueNotifier<int>(0);
  final ValueNotifier<String> _lastResult = ValueNotifier<String>('—');

  @override
  void dispose() {
    _shownCount.dispose();
    _lastResult.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Interstitial demo')),
      body: Padding(
        padding: bottomSafe(context, const EdgeInsets.all(24)),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<int>(
              valueListenable: _shownCount,
              builder: (_, c, __) => Text('Shown: $c times',
                  style: const TextStyle(
                      fontSize: 22, fontWeight: FontWeight.bold)),
            ),
            const SizedBox(height: 8),
            ValueListenableBuilder<String>(
              valueListenable: _lastResult,
              builder: (_, r, __) =>
                  Text('Last: $r', style: const TextStyle(color: Colors.grey)),
            ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: () {
                // `placement` tags the impression for revenue analytics — it
                // flows into `AdShowEvent.placement` / `AdRevenueEvent`. Use a
                // preset (home/shop/levelComplete/gameOver/settings) or
                // `AdPlacement.custom('my_screen')`.
                showInterstitialAd(
                  placement: AdPlacement.levelComplete,
                  onDone: (shown) {
                    _lastResult.value = shown ? 'shown ✅' : 'skipped/blocked ❌';
                    if (shown) _shownCount.value = _shownCount.value + 1;
                  },
                );
              },
              child: const Text('Show interstitial (placement: levelComplete)'),
            ),
            const SizedBox(height: 12),
            const Text(
              'SDK runs: pre-check (canShowInterstitial) → 1 s loading dialog → '
              'native show. If safety blocks, "skipped" returns immediately.',
              style: TextStyle(color: Colors.grey),
            ),
          ],
        ),
      ),
    );
  }
}
