// Smoke tests for the exported UI widgets (DebugAdOverlay, RevenuePanel,
// TopToast) — they must render / show without throwing, even with no
// initialised SDK and no revenue events. Animated widgets use pump() rather
// than pumpAndSettle() because they run repeating animations.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  testWidgets('RevenuePanel renders with no events', (tester) async {
    await tester.pumpWidget(host(const RevenuePanel()));
    await tester.pump();
    expect(find.byType(RevenuePanel), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('RevenuePanel(compact) renders', (tester) async {
    await tester.pumpWidget(host(const RevenuePanel(compact: true)));
    await tester.pump();
    expect(tester.takeException(), isNull);
  });

  testWidgets('DebugAdOverlay renders (debug build) without throwing',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Stack(children: [SizedBox.expand(), DebugAdOverlay()]),
    ));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(tester.takeException(), isNull);
  });

  testWidgets('TopToast.show overlays a toast and auto-dismisses', (tester) async {
    await tester.pumpWidget(host(Builder(
      builder: (context) => ElevatedButton(
        onPressed: () =>
            TopToast.show(context, icon: Icons.info_outline, message: 'hello'),
        child: const Text('toast'),
      ),
    )));
    await tester.tap(find.text('toast'));
    await tester.pump(); // insert overlay
    await tester.pump(const Duration(milliseconds: 400)); // play in-animation
    expect(find.text('hello'), findsOneWidget);
    // Past the 3 s display + out-animation: it removes itself, no pending timer.
    await tester.pump(const Duration(seconds: 4));
    expect(tester.takeException(), isNull);
  });

  testWidgets('unmounting RevenuePanel disposes cleanly', (tester) async {
    await tester.pumpWidget(host(const RevenuePanel()));
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pump();
    expect(find.byType(RevenuePanel), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
