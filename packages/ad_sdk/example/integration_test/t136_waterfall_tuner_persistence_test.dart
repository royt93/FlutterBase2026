// T136 (round 2 independent review, BLOCKER #3) on-device integration test
// — WaterfallTuner's samples must survive a real dispose()/new-instance
// boundary against the REAL platform SharedPreferences (not the mocked
// in-memory store the unit tests in test/waterfall_tuner_test.dart use),
// proving cross-session accumulation actually works on a real device, not
// just against a test double.
//
// Run with:
//   flutter test integration_test/t136_waterfall_tuner_persistence_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  void emitLoad(String provider, {required bool success}) {
    AdManager().debugEmit(AdLoadEvent(
      providerTag: provider,
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      success: success,
    ));
  }

  void emitRevenue(String provider, int valueMicros) {
    AdManager().debugEmit(AdRevenueEvent(
      providerTag: provider,
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      valueMicros: valueMicros,
      currencyCode: 'USD',
      networkName: null,
      precision: null,
      mediationWaterfall: null,
    ));
  }

  testWidgets(
      'samples recorded by one WaterfallTuner instance are still there for '
      'a brand-new instance, against the REAL platform SharedPreferences',
      (tester) async {
    final sessionA = WaterfallTuner();
    await tester.pump(const Duration(milliseconds: 200));

    // minSampleSize is 6, summed across both providers — 2 each (sum 4)
    // stays below it alone.
    for (var i = 0; i < 2; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 2; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await tester.pump(const Duration(milliseconds: 300));

    expect(
        sessionA.recommendation(
          type: AdSlotType.interstitial,
          placement: AdPlacement.home,
          currentProvider: '[AdMob]',
        ),
        isNull,
        reason: 'sanity: 2+2=4 attempts alone is below minSampleSize (6)');

    sessionA.dispose();

    // A brand-new instance — real app restart would look exactly like
    // this: same real on-device SharedPreferences file, different Dart
    // object.
    final sessionB = WaterfallTuner();
    await tester.pump(const Duration(milliseconds: 300)); // let its async load finish

    for (var i = 0; i < 2; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000);
    for (var i = 0; i < 2; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await tester.pump(const Duration(milliseconds: 300));

    final rec = sessionB.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );

    expect(rec, isNotNull,
        reason: 'session A\'s samples must still be readable from the REAL '
            'platform SharedPreferences by a brand-new WaterfallTuner — '
            'this is what proves cross-session accumulation works on a '
            'real device, not just against the mocked store the fast unit '
            'tests use');
    expect(rec!.recommendedProvider, '[AppLovin]');

    sessionB.dispose();
  });
}
