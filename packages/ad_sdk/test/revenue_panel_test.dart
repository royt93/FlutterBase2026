// T135 — RevenuePanel's running total is named/labeled as USD (`_totalUsd`,
// a bare `$` prefix in the UI) but used to add ANY AdRevenueEvent.value
// regardless of AdEvent.currencyCode — a non-USD event's raw numeric value
// got silently added into the USD total, showing a wrong number with no
// indication anything was off.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget host(Widget child) =>
      MaterialApp(home: Scaffold(body: Center(child: child)));

  AdRevenueEvent revenue(int valueMicros, String currencyCode) =>
      AdRevenueEvent(
        providerTag: '[Fake]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        valueMicros: valueMicros,
        currencyCode: currencyCode,
      );

  // AdManager().events is a plain (non-sync) broadcast StreamController, so
  // delivery to RevenuePanel's listener needs a microtask turn — one
  // `pump()` flushes that turn (running _onEvent, which calls setState()
  // internally via ValueListenableBuilder) but the resulting rebuild isn't
  // drawn until the FRAME after that, hence the second `pump()`.
  Future<void> emitAndSettle(WidgetTester tester, AdEvent event) async {
    AdManager().debugEmit(event);
    await tester.pump();
    await tester.pump();
  }

  testWidgets('a USD AdRevenueEvent is added to the total normally',
      (tester) async {
    await tester.pumpWidget(
        host(const RevenuePanel(debugModeOverride: true, showDecimals: true)));
    await tester.pump();

    await emitAndSettle(tester, revenue(1500000, 'USD')); // $1.50

    expect(find.text('\$1.5000'), findsOneWidget);
  });

  testWidgets(
      'a non-USD AdRevenueEvent is NOT added to the USD total — the '
      'displayed number must not silently mix currencies', (tester) async {
    await tester.pumpWidget(
        host(const RevenuePanel(debugModeOverride: true, showDecimals: true)));
    await tester.pump();

    await emitAndSettle(tester, revenue(1500000, 'USD')); // $1.50
    await emitAndSettle(
        tester, revenue(2000000, 'EUR')); // €2.00 — must be skipped

    expect(find.text('\$1.5000'), findsOneWidget,
        reason: 'the EUR event\'s raw numeric value (2.0) must not have '
            'been added to the USD total (which would show 3.5000) — a '
            'different currency is not directly addable to a USD sum');
  });

  testWidgets(
      'a non-USD event is still counted as an impression (only the '
      'revenue total skips it)', (tester) async {
    await tester.pumpWidget(
        host(const RevenuePanel(debugModeOverride: true, compact: true)));
    await tester.pump();

    await emitAndSettle(tester, revenue(2000000, 'EUR'));

    expect(find.textContaining('1 imp'), findsOneWidget,
        reason: 'impression count is currency-agnostic — only the revenue '
            'sum itself must guard against mixing currencies');
  });

  testWidgets('multiple non-USD events in a row do not accumulate into '
      'the USD total either', (tester) async {
    await tester.pumpWidget(
        host(const RevenuePanel(debugModeOverride: true, showDecimals: true)));
    await tester.pump();

    await emitAndSettle(tester, revenue(2000000, 'EUR'));
    await emitAndSettle(tester, revenue(3000000, 'JPY'));

    expect(find.text('\$0.0000'), findsOneWidget);
  });
}
