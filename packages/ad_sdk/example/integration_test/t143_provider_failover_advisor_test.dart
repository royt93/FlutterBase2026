// T143 on-device integration test — ProviderFailoverAdvisor tracks real
// consecutive AdLoadEvent failures through a real AdManager() session, and
// AdManager().applyProviderFailover() recommends the other provider once
// tripped, on a real device.
//
// Run with:
//   flutter test integration_test/t143_provider_failover_advisor_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'consecutive real load failures trip shouldFailoverNextSession, and '
      'applyProviderFailover() recommends the other provider, on a real '
      'device', (tester) async {
    final advisor = ProviderFailoverAdvisor(
        consecutiveFailureThreshold: 3, persist: false);
    AdManager().enableProviderFailoverAdvisor(advisor);
    addTearDown(() => AdManager().disableProviderFailoverAdvisor());
    await advisor.ready;

    // Must be a REAL provider tag ('[AppLovin]'/'[AdMob]') — an unknown tag
    // (e.g. a made-up fake tag) trips shouldFailoverNextSession but maps to
    // no AdProvider at all, so applyProviderFailover correctly leaves the
    // candidate unchanged for it (round-2 review finding: this test used
    // to use a fake tag and asserted a flip that the fixed code can no
    // longer produce for an unrecognized tag).
    for (var i = 0; i < 3; i++) {
      AdManager().debugEmit(const AdLoadEvent(
        providerTag: '[AppLovin]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: false,
      ));
    }
    await tester.pump();

    expect(advisor.shouldFailoverNextSession, isTrue);
    expect(advisor.failingProvider, AdProvider.appLovin);
    expect(
      AdManager().applyProviderFailover(AdProvider.appLovin, advisor: advisor),
      AdProvider.admob,
    );
    expect(
      AdManager().applyProviderFailover(AdProvider.admob, advisor: advisor),
      AdProvider.admob,
      reason: 'a candidate that is already the healthy provider must not '
          'be flipped back to the one that failed',
    );
  });
}
