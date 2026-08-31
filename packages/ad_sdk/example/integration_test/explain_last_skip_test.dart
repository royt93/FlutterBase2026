// T119 on-device integration test — AdManager().explainLastSkip(AdSlotType)
// must return a human-readable reason after a real skip happens (here: a VIP
// member skip, the cheapest real skip to trigger without a native ad unit).
//
// Run with:
//   flutter test integration_test/explain_last_skip_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('explainLastSkip reports the real reason after a VIP skip',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip;
    expect(vip, isNotNull, reason: 'VipManager must be ready post-init');
    await vip!.addVip(key: 'T119_INTEGRATION_TEST', duration: const Duration(days: 1));
    addTearDown(() => vip.revokeAll());

    await AdManager().loadInterstitial();
    await tester.pump(const Duration(milliseconds: 200));

    final reason = AdManager().explainLastSkip(AdSlotType.interstitial);
    expect(reason, isNotNull,
        reason: 'a real VIP-gated skip must leave an explainable reason');
    expect(reason!.toLowerCase(), contains('vip'));
    expect(tester.takeException(), isNull);
  });
}
