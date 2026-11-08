import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('signed-key demo clarifies redemption requires internet', (
    tester,
  ) async {
    await tester.pumpWidget(const MaterialApp(home: VipDemoPage()));

    expect(
      find.text(
        'Signed keys (offline verification; internet required to redeem)',
      ),
      findsOneWidget,
    );
    expect(find.textContaining('offline, forge-proof'), findsNothing);
  });
}
