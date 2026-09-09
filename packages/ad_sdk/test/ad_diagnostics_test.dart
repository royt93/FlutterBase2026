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

    // T151 — a persisted compliance-log entry can outlive an SDK version
    // (an old slotType name), be corrupted, or have a field manually edited.
    // This is the sole reader of that log that used AdSlotType.values.byName
    // directly instead of a safe tryParse-style lookup — every other reader
    // in the package (ad_event_log.dart's own _load(), WaterfallTuner's
    // _Key.tryParse) skips a malformed entry instead of throwing, precisely
    // because this data is untrusted persisted state, not an in-memory
    // invariant.
    test(
        'a garbage/unknown slotType entry is skipped, not thrown — valid '
        'entries around it still process', () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'interstitial',
          'mediationWaterfall': ['com.before.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'not_a_real_slot_type',
          'mediationWaterfall': ['com.garbage.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          'slotType': 'rewarded',
          'mediationWaterfall': ['com.after.adapter'],
        },
      ]);

      expect(result[AdSlotType.interstitial], ['com.before.adapter']);
      expect(result[AdSlotType.rewarded], ['com.after.adapter']);
      expect(result.length, 2,
          reason: 'the garbage slotType must not appear under any key');
    });

    test('a null/missing slotType entry is skipped, not thrown', () {
      final result = AdDiagnostics.lastWaterfallBySlotFrom([
        {
          'eventType': 'AdRevenueEvent',
          'slotType': null,
          'mediationWaterfall': ['com.orphan.adapter'],
        },
        {
          'eventType': 'AdRevenueEvent',
          // slotType key entirely absent, not just null.
          'mediationWaterfall': ['com.also.orphan'],
        },
      ]);

      expect(result, isEmpty);
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
      // T58: valueMicros is per-impression revenue; eCPM is per-1000, so a
      // realistic 2_000 micros/impression reports as a $2.00 eCPM.
      AdManager().debugEmit(_rev(2000));
      await Future<void>.delayed(Duration.zero);

      final d = AdManager().diagnostics();
      expect(d.arbitratorEstimatedEcpmMicros, 2000000);
      expect(d.arbitratorVetoRate, isNotNull);
    });
  });
}
