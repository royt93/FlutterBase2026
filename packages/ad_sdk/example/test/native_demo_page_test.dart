// Widget test for NativeDemoPage's T152 watchdog-recovery buttons and T154's
// IndexedStack visibility demo. Both need a real, initialised adapter to do
// anything meaningful (see test/admob_widget_load_watchdog_test.dart and
// native_ad_widget_test.dart in the SDK package itself for the full
// real-adapter proof of each underlying fix) — this only pins the pre-init
// fallback path doesn't crash the page, and that the tab toggle itself
// works without throwing.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets(
      'Simulate watchdog timeout before SDK init shows a friendly message, '
      'not a crash', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NativeDemoPage()));
    await tester.pump();

    await tester.tap(find.text('Simulate watchdog timeout'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.textContaining('not initialised'), findsOneWidget);
  });

  testWidgets(
      'T154 — switching IndexedStack tabs before SDK init does not crash',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: NativeDemoPage()));
    await tester.pump();

    expect(find.text('Tab 1 — nothing here'), findsOneWidget);

    await tester.tap(find.text('Tab 2 (native ad)'));
    await tester.pump();

    expect(tester.takeException(), isNull);

    await tester.tap(find.text('Tab 1 (no ad)'));
    await tester.pump();

    expect(tester.takeException(), isNull);
    expect(find.text('Tab 1 — nothing here'), findsOneWidget);
  });
}
