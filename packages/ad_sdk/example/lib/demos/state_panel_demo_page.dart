// T117 — state panel demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';

import '../config/demo_config.dart';
import '../shared/layout_helpers.dart';

class StatePanelDemoPage extends StatelessWidget {
  const StatePanelDemoPage({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    final adapter = AdManager().adapter;
    return Scaffold(
      appBar: AppBar(title: const Text('Slot state panel')),
      body: ListView(
        padding: bottomSafe(context, const EdgeInsets.all(16)),
        children: [
          if (adapter != null) ...[
            Text('Provider: ${adapter.tag}',
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 18)),
            const SizedBox(height: 12),
            _slotCard('App Open', adapter.appOpenSlot),
            _slotCard('Interstitial', adapter.interstitialSlot),
            _slotCard('Rewarded', adapter.rewardedSlot),
            // T65 (phase 2): banner is now keyed per BannerAdWidget instance
            // — no single slot to show here, same as mrec/native already.
          ] else
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 32),
              child: Center(child: Text('SDK not initialised yet')),
            ),
          const Divider(height: 32),
          const Text(
            'Lifecycle test',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          FilledButton.tonal(
            onPressed: adapter == null
                ? null
                : () async {
                    await AdManager().destroy();
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                            content: Text('SDK destroyed — adapter null')),
                      );
                    }
                  },
            child: const Text('Destroy SDK'),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: () async {
              await AdManager().initialize(
                config: DemoConfig.instance.build(),
                onComplete: (_, __) {},
              );
              if (context.mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('SDK re-initialized')),
                );
              }
            },
            child: const Text('Re-initialize SDK'),
          ),
          if (kDebugMode) ...[
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () => _openAdInspector(context),
              child: const Text(
                kProvider == AdProvider.appLovin
                    ? 'Open AppLovin mediation debugger'
                    : 'Open AdMob ad inspector',
              ),
            ),
          ],
        ],
      ),
    );
  }

  // Both providers ship their own native debug UI — no need to build one.
  void _openAdInspector(BuildContext context) {
    if (kProvider == AdProvider.appLovin) {
      AppLovinMAX.showMediationDebugger();
      return;
    }
    MobileAds.instance.openAdInspector((error) {
      if (error != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Ad inspector error: ${error.message}')),
        );
      }
    });
  }

  Widget _slotCard(String label, AdSlot slot) {
    return ValueListenableBuilder<AdSlotState>(
      valueListenable: slot.state,
      builder: (_, state, __) => Card(
        child: ListTile(
          title: Text(label),
          subtitle: Text(
            'state=${state.name}\n'
            'fails=${slot.consecutiveFailures}\n'
            'lastError=${slot.lastErrorAt?.toIso8601String() ?? '—'}\n'
            'lastLoaded=${slot.lastLoadedAt?.toIso8601String() ?? '—'}',
          ),
          trailing: _badge(state),
        ),
      ),
    );
  }

  Widget _badge(AdSlotState s) {
    final color = switch (s) {
      AdSlotState.idle => Colors.grey,
      AdSlotState.loading => Colors.blue,
      AdSlotState.ready => Colors.green,
      AdSlotState.showing => Colors.purple,
      AdSlotState.cooldown => Colors.orange,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(s.name,
          style: TextStyle(color: color, fontWeight: FontWeight.bold)),
    );
  }
}
