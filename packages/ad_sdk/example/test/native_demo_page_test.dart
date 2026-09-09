// Widget test for NativeDemoPage's T152 watchdog-recovery buttons. The
// buttons need a real, initialised adapter to do anything meaningful (see
// test/admob_widget_load_watchdog_test.dart in the SDK package itself for
// the full real-adapter proof of the underlying fix) — this only pins the
// pre-init fallback path doesn't crash the page.

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
}
