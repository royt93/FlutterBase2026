import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Map<String, dynamic> _e(int value,
        {String currency = 'USD',
        String? id,
        String provider = '[AdMob]',
        String slot = 'interstitial'}) =>
    {
      'eventType': 'AdRevenueEvent',
      'valueMicros': value,
      'currencyCode': currency,
      'requestId': id,
      'providerTag': provider,
      'slotType': slot,
    };

void main() {
  test('requires minimum samples and detects zero/spike/currency', () {
    const detector = RevenueAnomalyDetector(minimumSamples: 5);
    expect(detector.analyze([_e(10), _e(10)]), isEmpty);
    final anomalies = detector.analyze([
      _e(10),
      _e(10),
      _e(10),
      _e(10),
      _e(0),
      _e(1000),
      _e(20, currency: 'EUR'),
    ]);
    expect(anomalies.map((a) => a.kind), contains(RevenueAnomalyKind.zeroEcpm));
    expect(anomalies.map((a) => a.kind), contains(RevenueAnomalyKind.spike));
    expect(anomalies.map((a) => a.kind),
        contains(RevenueAnomalyKind.currencyMismatch));
  });

  test('detects duplicate and cross-context request IDs', () {
    const detector = RevenueAnomalyDetector(minimumSamples: 1);
    final anomalies = detector.analyze([
      _e(10, id: 'r1'),
      _e(10, id: 'r1'),
      _e(10, id: 'r1', slot: 'rewarded'),
    ]);
    expect(anomalies.map((a) => a.kind),
        contains(RevenueAnomalyKind.duplicateImpression));
    expect(anomalies.map((a) => a.kind),
        contains(RevenueAnomalyKind.requestIdCollision));
  });

  test('invalid minimum samples fails fast', () {
    expect(() => RevenueAnomalyDetector(minimumSamples: 0), returnsNormally);
    expect(() => const RevenueAnomalyDetector(minimumSamples: 0).analyze([]),
        throwsArgumentError);
  });

  group('pipeline integration (round 59 audit fix)', () {
    // Round 59 audit finding: `_e()` above hand-builds its 'requestId' key
    // directly, so it kept passing even after `AdEventLog._eventExtra()`
    // stopped actually persisting `AdRevenueEvent.requestId` — the real
    // production path. This group runs the same scenario through the real
    // `AdEventLog.recordEvent()` serialization instead of a hand-built map,
    // so a future field this detector depends on can't silently go missing
    // from the persisted log again without a test catching it.
    late AdPreferences prefs;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      await prefs.clearAllData();
    });

    test(
        'requestId recorded via AdEventLog.recordEvent() survives into '
        'RevenueAnomalyDetector.analyze() and detects a real duplicate',
        () {
      final log = AdEventLog(prefs);
      for (var i = 0; i < 3; i++) {
        log.recordEvent(AdRevenueEvent(
          providerTag: '[AdMob]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          valueMicros: 10,
          currencyCode: 'USD',
          requestId: 'shared-request-id',
        ));
      }

      const detector = RevenueAnomalyDetector(minimumSamples: 1);
      final anomalies = detector.analyze(log.entries);

      expect(anomalies.map((a) => a.kind),
          contains(RevenueAnomalyKind.duplicateImpression));
    });
  });
}
