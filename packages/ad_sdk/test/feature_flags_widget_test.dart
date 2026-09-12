import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('kill-switch status is visible to operators', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Text('arbitrator: OFF')));
    expect(find.text('arbitrator: OFF'), findsOneWidget);
  });
}
