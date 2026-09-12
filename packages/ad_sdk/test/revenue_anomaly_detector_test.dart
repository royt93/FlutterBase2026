import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
