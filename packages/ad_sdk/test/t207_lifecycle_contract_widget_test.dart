import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('widget mount/unmount around destroy does not throw',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(body: Text('lifecycle')),
    ));
    expect(find.text('lifecycle'), findsOneWidget);
    await AdManager().destroy();
    await tester.pumpWidget(const SizedBox.shrink());
    expect(tester.takeException(), isNull);
  });
}
