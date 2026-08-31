// T122 — WaterfallTuner unit tests, driven via AdManager().debugEmit (no
// real network/adapter needed — this class only ever reads the event
// stream, it never issues a request of its own).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late WaterfallTuner tuner;

  setUp(() {
    tuner = WaterfallTuner();
  });

  tearDown(() {
    tuner.dispose();
  });

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

  test('no recommendation with fewer than minSampleSize attempts', () async {
    emitLoad('[AdMob]', success: true);
    emitLoad('[AppLovin]', success: true);
    await Future<void>.delayed(Duration.zero);

    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
    );
  });

  test(
      'recommends switching when the OTHER provider clearly out-fills and '
      'out-earns the current one', () async {
    // AdMob (current): fills half the time, low eCPM.
    for (var i = 0; i < 6; i++) {
      emitLoad('[AdMob]', success: i.isEven);
    }
    emitRevenue('[AdMob]', 1000); // $0.001

    // AppLovin: fills every time, much higher eCPM.
    for (var i = 0; i < 6; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000); // $0.05
    await Future<void>.delayed(Duration.zero);

    final rec = tuner.recommendation(
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      currentProvider: '[AdMob]',
    );

    expect(rec, isNotNull);
    expect(rec!.recommendedProvider, '[AppLovin]');
    expect(rec.currentProvider, '[AdMob]');
    expect(rec.recommendedScore, greaterThan(rec.currentScore));
  });

  test('no recommendation when the current provider is already better',
      () async {
    for (var i = 0; i < 6; i++) {
      emitLoad('[AdMob]', success: true);
    }
    emitRevenue('[AdMob]', 50000);

    for (var i = 0; i < 6; i++) {
      emitLoad('[AppLovin]', success: i.isEven);
    }
    emitRevenue('[AppLovin]', 1000);
    await Future<void>.delayed(Duration.zero);

    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
    );
  });

  test('dispose() stops listening — events after dispose do not move the '
      'score', () async {
    tuner.dispose();
    for (var i = 0; i < 10; i++) {
      emitLoad('[AppLovin]', success: true);
    }
    emitRevenue('[AppLovin]', 50000);
    await Future<void>.delayed(Duration.zero);

    // No crash, and (implicitly) nothing was recorded — re-querying a
    // disposed tuner is safe and just keeps returning null.
    expect(
      tuner.recommendation(
        type: AdSlotType.interstitial,
        placement: AdPlacement.home,
        currentProvider: '[AdMob]',
      ),
      isNull,
    );
  });
}
