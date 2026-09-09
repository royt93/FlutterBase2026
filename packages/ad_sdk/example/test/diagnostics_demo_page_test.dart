// Widget test for DiagnosticsDemoPage's T151 button — proves
// AdDiagnostics.lastWaterfallBySlotFrom() no longer throws on a corrupted
// compliance-log entry, which used to crash this whole page.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets(
      'Simulate corrupted log entry does not throw and shows the valid '
      'entry survived', (tester) async {
    SharedPreferences.setMockInitialValues({});
    await tester.pumpWidget(const MaterialApp(home: DiagnosticsDemoPage()));

    await tester.tap(find.text('Simulate corrupted log entry (T151)'));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a corrupted slotType entry must not crash the page — '
            'T151');
    expect(find.textContaining('did NOT throw'), findsOneWidget);
    expect(find.textContaining('interstitial'), findsOneWidget,
        reason: 'the valid entry alongside the corrupted one must still '
            'be present in the result');
    expect(find.textContaining('not_a_real_slot_type'), findsNothing,
        reason: 'the corrupted entry itself must not appear in the result');
  });
}
