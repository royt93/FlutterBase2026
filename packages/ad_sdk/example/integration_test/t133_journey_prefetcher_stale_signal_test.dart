// T133 on-device integration test — a pending journey signal older than
// maxPendingSignalAge must be discarded, not folded into the rolling
// time-to-show average, using REAL wall-clock time on a real device (no
// debugClock injection here, unlike the fast unit tests in
// test/journey_prefetcher_test.dart).
//
// Run with:
//   flutter test integration_test/t133_journey_prefetcher_stale_signal_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a pending signal older than maxPendingSignalAge (real wall-clock '
      'time) is discarded, not recorded as a time-to-show sample',
      (tester) async {
    final prefetcher = JourneyPrefetcher(
      maxPendingSignalAge: const Duration(milliseconds: 300),
    );
    addTearDown(prefetcher.dispose);
    await prefetcher.ready;

    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    await tester.pump(const Duration(milliseconds: 500)); // past the 300ms TTL

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump();

    expect(
      prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial),
      isNull,
      reason: 'a signal older than the real 300ms TTL must be discarded as '
          'stale on a real device, not just in a debugClock-driven test',
    );

    // A fresh, prompt signal right after must still work normally.
    prefetcher.notifySignal('levelStarted', AdSlotType.interstitial);
    await tester.pump(const Duration(milliseconds: 50)); // well within TTL

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump();

    expect(
      prefetcher.averageTimeToShow('levelStarted', AdSlotType.interstitial),
      isNotNull,
      reason: 'a prompt, non-stale signal must still record a normal '
          'sample — the TTL must not have permanently wedged this key',
    );
  });
}
