// On-device integration test for the anomaly/fraud alert stream (T25).
//
// Boots the full example app, waits for SDK init (which wires
// AdSafetyConfig.setAnomalySink(_emit) inside AdManager.initialize()), then
// proves a simulated CTR anomaly reaches AdManager().events on real hardware
// — not just the sink-level unit tests already covering the logic itself.
//
// Run with:
//   flutter test integration_test/anomaly_event_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'simulated CTR anomaly reaches AdManager().events via the wired sink',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final received = <AdAnomalyEvent>[];
    final sub = AdManager()
        .events
        .where((e) => e is AdAnomalyEvent)
        .cast<AdAnomalyEvent>()
        .listen(received.add);

    // The demo app's own AdSafetyParams (kDemoSafetyParams) sets
    // suspiciousCtrThreshold: 1.0 and maxClicksPerMinute: 999 — deliberately
    // permissive so manual demo-page tapping never trips the safety layer.
    // The CTR check only engages once totalImpressions >= 5; more clicks
    // than impressions still pushes CTR > 100%, so this stays a faithful
    // trigger against the real wired config instead of overriding it.
    AdSafetyConfig.resetForReinit();
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordBannerImpression();
    }
    for (var i = 0; i < 6; i++) {
      AdSafetyConfig.recordAdClick();
    }
    AdSafetyConfig.canShowFullscreenAd();
    await tester.pump();

    expect(received, hasLength(1));
    expect(received.single.reason, contains('CTR anomaly'));
    await sub.cancel();
  });
}
