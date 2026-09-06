// T138 on-device integration test — MonetizationArbitrator.decideWithContext()
// returns the same decision decide() would, plus a non-empty reason, using
// real AdManager().debugEmit() revenue events on a real device.
//
// Run with:
//   flutter test integration_test/t138_arbitrator_decide_with_context_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdRevenueEvent _rev(int valueMicros) => AdRevenueEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: valueMicros,
      currencyCode: 'USD',
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'decideWithContext() reports a low-eCPM nudgeVip with a real reason '
      'string, on a real device', (tester) async {
    final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
    addTearDown(arb.dispose);

    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(_rev(100)); // well below the $5 eCPM threshold
    }
    await tester.pump();

    final detail = arb.decideWithContext(AdSlotType.interstitial);

    expect(detail.decision, ArbitratorDecision.nudgeVip);
    expect(detail.reason, isNotEmpty);
    expect(detail.trailingEcpmMicros, 100000);
    expect(detail.thresholdMicros, 5000000);
    expect(detail.guardrailTripped, isFalse);
  });

  testWidgets(
      'a registered VIP-likelihood estimator is invoked even with zero '
      'trailing eCPM, on a real device (regression this session caught '
      'and fixed itself, via an unrelated crash-guard test)',
      (tester) async {
    final arb = MonetizationArbitrator();
    addTearDown(arb.dispose);

    var calls = 0;
    arb.registerVipLikelihoodEstimator(() {
      calls++;
      return 0.9;
    });

    arb.decideWithContext(AdSlotType.interstitial);

    expect(calls, 1,
        reason: 'the registered estimator must be invoked unconditionally, '
            'matching decide()\'s pre-T138 behavior, even when this slot '
            'has zero trailing eCPM evidence');
  });
}
