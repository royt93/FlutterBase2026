// Tests for AdManager.diagnostics() and its pure waterfall-indexing helper
// AdDiagnostics.lastWaterfallBySlotFrom (T41 brainstorm — one-shot
// mediation-waterfall + fill-rate + arbitrator snapshot).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

AdRevenueEvent _rev(int micros, {List<String>? waterfall}) => AdRevenueEvent(
      providerTag: '[AdMob]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: micros,
      currencyCode: 'USD',
      mediationWaterfall: waterfall,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AdDiagnostics.lastWaterfallBySlotFrom (pure)', () {
    test('empty entries → empty map', () {
      expect(AdDiagnostics.lastWaterfallBySlotFrom(const []), isEmpty);
    });

    test('ignores non-AdRevenueEvent entries and entries without a waterfall',
        () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {'eventType': 'AdLoadEvent', 'slotType': 'interstitial'},
        {'eventType': 'AdRevenueEvent', 'slotType': 'interstitial'},
      ]);
      expect(result, isEmpty);
    });

    test('keeps only the most recent waterfall per slot (oldest-first input)',
        () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'interstitial',
          'mediationWaterfall': ['com.old.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'rewarded',
          'mediationWaterfall': ['com.rewarded.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'interstitial',
          'mediationWaterfall': ['com.new.adapter', 'com.other.adapter'],
        },
      ]);

      expect(result[AdSlotType.interstitial],
          ['com.new.adapter', 'com.other.adapter']);
      expect(result[AdSlotType.rewarded], ['com.rewarded.adapter']);
    });
  });

  group('AdManager().diagnostics()', () {
    tearDown(() {
      AdManager().disableArbitrator();
      AdManager().disableFillRateMonitor();
    });

    test('nothing enabled → empty fillRate map, null arbitrator fields', () {
      final d = AdManager().diagnostics();
      expect(d.fillRateBySlot, isEmpty);
      expect(d.arbitratorEstimatedEcpmMicros, isNull);
      expect(d.arbitratorVetoRate, isNull);
    });

    test('fillRateMonitor enabled → every slot type present, defaults to 1.0',
        () {
      AdManager().enableFillRateMonitor(FillRateMonitor());
      final d = AdManager().diagnostics();
      expect(d.fillRateBySlot.keys.toSet(), AdSlotType.values.toSet());
      expect(d.fillRateBySlot[AdSlotType.interstitial], 1.0,
          reason: 'no load attempts observed yet for this slot');
    });

    test('fillRateMonitor reflects fed AdLoadEvents', () async {
      AdManager().enableFillRateMonitor(FillRateMonitor());
      AdManager().debugEmit(const AdLoadEvent(
        providerTag: '[AdMob]',
        type: AdSlotType.rewarded,
        placement: AdPlacement.unspecified,
        success: false,
      ));
      await Future<void>.delayed(Duration.zero);

      final d = AdManager().diagnostics();
      expect(d.fillRateBySlot[AdSlotType.rewarded], 0.0);
    });

    test('arbitrator enabled → estimatedEcpm/vetoRate populated', () async {
      AdManager().enableArbitrator(MonetizationArbitrator());
      AdManager().debugEmit(_rev(2000000));
      await Future<void>.delayed(Duration.zero);

      final d = AdManager().diagnostics();
      expect(d.arbitratorEstimatedEcpmMicros, 2000000);
      expect(d.arbitratorVetoRate, isNotNull);
    });
  });
}
