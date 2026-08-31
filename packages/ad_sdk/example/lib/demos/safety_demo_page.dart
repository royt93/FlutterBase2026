// T117 — safety demo page. Split out of main.dart.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import '../shared/layout_helpers.dart';

class SafetyDemoPage extends StatefulWidget {
  const SafetyDemoPage({super.key});

  @override
  State<SafetyDemoPage> createState() => _SafetyDemoPageState();
}

class _SafetyDemoPageState extends State<SafetyDemoPage> {
  final ValueNotifier<int> _refresh = ValueNotifier<int>(0);
  final ValueNotifier<bool> _arbitratorEnabled =
      ValueNotifier<bool>(AdManager().arbitrator != null);
  final ValueNotifier<bool> _fillRateMonitorEnabled =
      ValueNotifier<bool>(AdManager().fillRateMonitor != null);

  @override
  void dispose() {
    _refresh.dispose();
    _arbitratorEnabled.dispose();
    _fillRateMonitorEnabled.dispose();
    super.dispose();
  }

  AdSafetyParams get _activeParams =>
      AdManager().config?.safety ?? AdSafetyParams.auto;

  Widget _paramsCard(String title, AdSafetyParams p, {Color? color}) {
    return Card(
      color: color,
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title,
                style:
                    const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              'between=${p.minTimeBetweenFullscreenAds}ms\n'
              'session=${p.maxFullscreenAdsPerSession} / hour=${p.maxFullscreenAdsPerHour} / day=${p.maxFullscreenAdsPerDay}\n'
              'warmup=${p.minSessionDurationBeforeAd}ms / resume=${p.minTimeAppOpenResume}ms\n'
              'clicks/min=${p.maxClicksPerMinute} / ctr=${p.suspiciousCtrThreshold}\n'
              'rapidResume=${p.maxRapidResumesPerMinute} / dryRun=${p.dryRun}',
              style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    // Wrap with initRevision so destroy/reinit refreshes _activeParams display.
    return ValueListenableBuilder<int>(
      valueListenable: AdManager().initRevision,
      builder: (context, _, __) => _build(context),
    );
  }

  Widget _build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Safety demo')),
      body: ValueListenableBuilder<int>(
        valueListenable: _refresh,
        builder: (_, __, ___) => ListView(
          padding: bottomSafe(context, const EdgeInsets.all(16)),
          children: [
            _paramsCard(
              'Active params (demo: same for debug + release)',
              _activeParams,
              color: Colors.blue.shade50,
            ),
            const SizedBox(height: 12),
            _paramsCard(
                'Preset: AdSafetyParams.production', AdSafetyParams.production),
            const SizedBox(height: 8),
            _paramsCard('Preset: AdSafetyParams.debug', AdSafetyParams.debug),
            const SizedBox(height: 8),
            const Card(
              child: Padding(
                padding: EdgeInsets.all(12),
                child: Text(
                  'How to customize from your app:\n'
                  '\n'
                  '// 1) Use a built-in preset\n'
                  'safety: AdSafetyParams.debug\n'
                  '\n'
                  '// 2) Auto-pick (default — debug in dev, prod in release)\n'
                  'safety: AdSafetyParams.auto\n'
                  '\n'
                  '// 3) Override only the knobs you care about\n'
                  'safety: AdSafetyParams.production.copyWith(\n'
                  '  maxFullscreenAdsPerDay: 10,\n'
                  '  dryRun: kDebugMode,\n'
                  ')',
                  style: TextStyle(fontFamily: 'monospace', fontSize: 11),
                ),
              ),
            ),
            const Divider(height: 24),
            const Text('Live status',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            Text(AdSafetyConfig.getStatus(),
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(height: 12),
            const Text('Policy risk score (T24, dev/partner signal only)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ValueListenableBuilder<int>(
              valueListenable: AdManager().policyRiskScore,
              builder: (_, score, __) {
                final color = score < 30
                    ? Colors.green
                    : (score < 70 ? Colors.orange : Colors.red);
                return Row(
                  children: [
                    Container(
                      width: 12,
                      height: 12,
                      decoration:
                          BoxDecoration(color: color, shape: BoxShape.circle),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '$score / 100',
                      style: TextStyle(
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.bold,
                        color: color,
                      ),
                    ),
                  ],
                );
              },
            ),
            const SizedBox(height: 12),
            const Text('Smart Monetization Arbitrator (opt-in)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ValueListenableBuilder<bool>(
              valueListenable: _arbitratorEnabled,
              builder: (_, enabled, __) {
                final arbitrator = AdManager().arbitrator;
                if (!enabled || arbitrator == null) {
                  return const Text('disabled (default)',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11));
                }
                return Text(
                  'estimatedEcpm=${arbitrator.estimatedEcpmMicros}µ '
                  'vetoRate=${arbitrator.vetoRate.toStringAsFixed(2)}\n'
                  'perSlotThreshold: interstitial=8000000µ rewarded=3000000µ, '
                  'maxVetoRate=0.5',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                );
              },
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                AdManager().enableArbitrator(MonetizationArbitrator(
                  // Demo per-slot thresholds — rewarded ads tend to earn
                  // more than interstitials, so give interstitial a higher
                  // eCPM bar before nudging VIP. maxVetoRate is the
                  // guardrail: if >50% of decisions veto, it stops vetoing
                  // and falls back to showAd rather than starve the user.
                  perSlotThresholdMicros: const {
                    AdSlotType.interstitial: 8000000, // $8.00 eCPM
                    AdSlotType.rewarded: 3000000, // $3.00 eCPM
                  },
                  maxVetoRate: 0.5,
                ));
                _arbitratorEnabled.value = true;
                _refresh.value = _refresh.value + 1;
              },
              child:
                  const Text('Enable Smart Arbitrator (per-slot + guardrail)'),
            ),
            const SizedBox(height: 12),
            const Text('Fill-rate monitor (opt-in)',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            ValueListenableBuilder<bool>(
              valueListenable: _fillRateMonitorEnabled,
              builder: (_, enabled, __) {
                final monitor = AdManager().fillRateMonitor;
                if (!enabled || monitor == null) {
                  return const Text('fill-rate monitor disabled (default)',
                      style: TextStyle(fontFamily: 'monospace', fontSize: 11));
                }
                return Text(
                  'interstitial=${monitor.fillRate(AdSlotType.interstitial).toStringAsFixed(2)} '
                  'rewarded=${monitor.fillRate(AdSlotType.rewarded).toStringAsFixed(2)} '
                  'appOpen=${monitor.fillRate(AdSlotType.appOpen).toStringAsFixed(2)}',
                  style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
                );
              },
            ),
            const SizedBox(height: 8),
            FilledButton.tonal(
              onPressed: () {
                AdManager().enableFillRateMonitor(FillRateMonitor());
                _fillRateMonitorEnabled.value = true;
              },
              child: const Text('Enable Fill-rate Monitor'),
            ),
            const SizedBox(height: 12),
            const Text('Latest fullscreen check',
                style: TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 4),
            Builder(builder: (_) {
              final r = AdSafetyConfig.canShowFullscreenAd();
              return Text(
                'canShow=${r.canShow}\nreason=${r.reason}',
                style: const TextStyle(fontFamily: 'monospace', fontSize: 11),
              );
            }),
            const SizedBox(height: 16),
            FilledButton.tonal(
              onPressed: () {
                AdSafetyConfig.resetSessionCounters();
                _refresh.value = _refresh.value + 1;
              },
              child: const Text('Reset session counters'),
            ),
            const SizedBox(height: 8),
            FilledButton(
              onPressed: () => _refresh.value = _refresh.value + 1,
              child: const Text('Refresh'),
            ),
          ],
        ),
      ),
    );
  }
}
