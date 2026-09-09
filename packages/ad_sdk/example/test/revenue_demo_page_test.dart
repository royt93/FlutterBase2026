// Widget test for RevenueDemoPage (main.dart:1691).
//
// The page just wraps RevenuePanel (already covered in ad_manager_core_test)
// plus static explainer text — this test only asserts the page's own scaffold
// renders correctly pre-init, with the panel at its zero-events default.

import 'package:ad_sdk_example/main.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('shows the revenue panel at its zero-events default',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RevenueDemoPage()));
    await tester.pump();

    expect(find.text('Revenue dashboard'), findsOneWidget);
    expect(find.text('Session Revenue'), findsOneWidget);
    expect(find.text('\$0.0000'), findsOneWidget);
    expect(find.text('0 impressions'), findsOneWidget);
  });

  // T150 — pins the demo added for the revenue-integrity-ledger type-match
  // fix: a revenue event for one ad format must not clear a pending show
  // of a different format at the same placement.
  testWidgets(
      'simulating a same-placement banner+interstitial show then '
      'interstitial-only revenue leaves 1 pending (the banner)',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RevenueDemoPage()));
    await tester.pump();

    await tester.tap(find.text('Simulate 2 shows\n(banner + interstitial)'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('Pending: 2'), findsOneWidget);

    await tester.tap(find.text('Simulate revenue\n(interstitial only)'));
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('Pending: 1'), findsOneWidget,
        reason: 'the banner\'s pending show must not be cleared by the '
            'interstitial\'s revenue event — T150');
  });

  // T150 (codex re-review) — tapping "Simulate 2 shows" more than once used
  // to keep appending to the same ledger, so a second tap left 4 pending
  // (not 2), silently invalidating what the status text advertises.
  testWidgets(
      'tapping "Simulate 2 shows" a second time still reports 2 pending, '
      'not 4', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: RevenueDemoPage()));
    await tester.pump();

    final button = find.text('Simulate 2 shows\n(banner + interstitial)');
    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('Pending: 2'), findsOneWidget);

    await tester.tap(button);
    await tester.pump(const Duration(milliseconds: 10));
    expect(find.textContaining('Pending: 2'), findsOneWidget,
        reason: 'a second tap must start a fresh sequence, not accumulate '
            'on top of the first — T150');
  });
}
