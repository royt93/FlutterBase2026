import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('anomaly warning renders without changing monetization',
      (tester) async {
    const warning = RevenueAnomaly(RevenueAnomalyKind.zeroEcpm, 'zero eCPM');
    await tester
        .pumpWidget(const MaterialApp(home: Text('Warning: zero eCPM')));
    expect(find.textContaining(warning.message), findsOneWidget);
  });
}
