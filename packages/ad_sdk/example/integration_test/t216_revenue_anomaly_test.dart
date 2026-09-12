import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('T216 Android smoke: event replay detects anomalies',
      (tester) async {
    final entries = List<Map<String, dynamic>>.generate(
        5,
        (_) => {
              'eventType': 'AdRevenueEvent',
              'valueMicros': 10,
              'currencyCode': 'USD',
            })
      ..add({
        'eventType': 'AdRevenueEvent',
        'valueMicros': 0,
        'currencyCode': 'USD'
      });
    final anomalies = const RevenueAnomalyDetector().analyze(entries);
    expect(anomalies.any((a) => a.kind == RevenueAnomalyKind.zeroEcpm), isTrue);
  });
}
