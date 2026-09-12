import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('stress report renders after a mount storm', (tester) async {
    final report =
        const AdStressHarness().run(events: 1000, maxBufferedEvents: 32);
    await tester.pumpWidget(MaterialApp(
      home: Text('buffer=${report.maxBuffered} dropped=${report.dropped}'),
    ));
    expect(find.textContaining('buffer=32'), findsOneWidget);
    expect(report.withinBound, isTrue);
  });
}
