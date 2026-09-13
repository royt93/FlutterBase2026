// On-device integration test for the T208 audit fix — AdManager()
// .applyProviderFailover() must gate the half-open circuit-breaker window
// through ProviderFailoverAdvisor.allowHalfOpenProbe(), not silently let
// every caller through once the cooldown elapses. No UI needed — this is a
// pure decision-helper API, exercised directly on the real device process.
//
// Run with:
//   flutter test \
//     integration_test/r208_circuit_breaker_half_open_probe_test.dart \
//     -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'half-open window on a real device: exactly one '
      'applyProviderFailover() call gets the real provider back, a second '
      'concurrent call still fails over', (tester) async {
    var now = DateTime.now();
    final advisor = ProviderFailoverAdvisor(
      consecutiveFailureThreshold: 1,
      persist: false,
      cooldown: const Duration(seconds: 5),
      now: () => now,
    );
    AdManager().enableProviderFailoverAdvisor(advisor);
    addTearDown(() => AdManager().disableProviderFailoverAdvisor());
    await advisor.ready;

    AdManager().debugEmit(const AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: false,
    ));
    await tester.pump();
    expect(advisor.circuitState, ProviderCircuitState.open);
    expect(
      AdManager().applyProviderFailover(AdProvider.appLovin, advisor: advisor),
      AdProvider.admob,
      reason: 'open: always fails over',
    );

    now = now.add(const Duration(seconds: 6));
    expect(advisor.circuitState, ProviderCircuitState.halfOpen);

    final first =
        AdManager().applyProviderFailover(AdProvider.appLovin, advisor: advisor);
    expect(first, AdProvider.appLovin,
        reason: 'T208 — the first call in the half-open window is the '
            'designated probe and must get the real, previously-failing '
            'provider back, on a real device process');

    final second =
        AdManager().applyProviderFailover(AdProvider.appLovin, advisor: advisor);
    expect(second, AdProvider.admob,
        reason: 'T208 — the probe slot is already claimed; a second call '
            'in the same window must still fail over — this is the exact '
            'production bug fixed here (the old code let every caller '
            'through, not just one)');
    expect(tester.takeException(), isNull);
  });
}
