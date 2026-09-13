// T194 on-device integration test — a CONFIRMED $0 eCPM (≥ warm-up
// samples, real average revenue is exactly 0) makes MonetizationArbitrator
// nudge VIP instead of failing open to showAd, and the maxVetoRate
// guardrail still protects against nudging forever — on a real device
// process, not just the pure-Dart unit tests in
// test/monetization_arbitrator_test.dart.
//
// Run with:
//   flutter test integration_test/t194_arbitrator_confirmed_zero_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdRevenueEvent _zeroRevenue() => const AdRevenueEvent(
      providerTag: '[real-device-smoke]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: 0,
      currencyCode: 'USD',
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'confirmed \$0 eCPM nudges VIP (not fail-open showAd), and the '
      'guardrail still recovers instead of nudging forever', (tester) async {
    final arb = MonetizationArbitrator(
        ecpmThresholdMicros: 5000000, maxVetoRate: 0.5, decisionWindowSize: 4);
    addTearDown(arb.dispose);

    for (var i = 0; i < 5; i++) {
      AdManager().debugEmit(_zeroRevenue());
    }
    await tester.pump();

    final first = arb.decideWithContext(AdSlotType.interstitial);
    expect(first.decision, ArbitratorDecision.nudgeVip,
        reason: 'a real, confirmed \$0 eCPM must nudge — not fail open as '
            '"no evidence", on a real device process');
    expect(first.trailingEcpmMicros, 0);
    expect(first.reason.toLowerCase(), contains('below threshold'));

    // Keep deciding for the same (still confirmed-zero) slot — the
    // guardrail (decisionWindowSize=4, maxVetoRate=0.5) must trip once
    // vetoes dominate the trailing window, forcing showAd rather than
    // nudging indefinitely.
    var sawGuardrailTrip = false;
    for (var i = 0; i < 10; i++) {
      final detail = arb.decideWithContext(AdSlotType.interstitial);
      if (detail.guardrailTripped) {
        sawGuardrailTrip = true;
        expect(detail.decision, ArbitratorDecision.showAd);
        break;
      }
    }
    expect(sawGuardrailTrip, isTrue,
        reason: 'confirmed-zero must still be a real veto signal the '
            'existing maxVetoRate safety net can act on — it must not '
            'nudge unconditionally forever');
  });
}
