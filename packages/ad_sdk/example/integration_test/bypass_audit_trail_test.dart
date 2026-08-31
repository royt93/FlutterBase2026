// T128 on-device integration test — AdManager().bypassAuditTrail must be a
// live, reachable object on the real running SDK, and calling
// showAppOpenAd(bypassSafety: true) must not throw even when no app-open ad
// is loaded yet.
//
// Run with:
//   flutter test integration_test/bypass_audit_trail_test.dart -d <device-or-sim-id>

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

  testWidgets('bypassAuditTrail is reachable and bypassSafety call is safe',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final before = AdManager().bypassAuditTrail.entries.length;

    await AdManager()
        .showAppOpenAd(bypassSafety: true, onAdDismiss: (_) {});
    await tester.pump(const Duration(milliseconds: 200));

    // Whether or not an app-open ad happened to be ready, the trail object
    // itself must stay usable and entries must never shrink.
    expect(AdManager().bypassAuditTrail.entries.length,
        greaterThanOrEqualTo(before));
    expect(tester.takeException(), isNull);
  });
}
