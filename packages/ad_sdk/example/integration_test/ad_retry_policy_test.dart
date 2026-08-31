// T108 on-device integration test — a per-slot AdRetryPolicy set on the real
// adapter's AdSlot must not break normal operation, and must be readable
// back (proves the field is wired through the real adapter, not just the
// AdSlot class in isolation).
//
// Run with:
//   flutter test integration_test/ad_retry_policy_test.dart -d <device-or-sim-id>

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

  testWidgets(
      'AdRetryPolicy assigned to the real adapter\'s rewarded slot round-trips',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final adapter = AdManager().adapter;
    expect(adapter, isNotNull, reason: 'adapter must be live post-init');

    const policy = AdRetryPolicy(
      jitterFraction: 0.2,
      resetOnConnectivityRestored: true,
    );
    adapter!.rewardedSlot.retryPolicy = policy;
    addTearDown(() => adapter.rewardedSlot.retryPolicy = null);

    expect(adapter.rewardedSlot.retryPolicy, same(policy));
    expect(tester.takeException(), isNull);
  });
}
