// T135 on-device integration test — RevenuePanel's USD total must not
// silently mix in a non-USD AdRevenueEvent's raw numeric value.
//
// Run with:
//   flutter test integration_test/t135_revenue_panel_currency_guard_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdRevenueEvent _revenue(int valueMicros, String currencyCode) =>
    AdRevenueEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: valueMicros,
      currencyCode: currencyCode,
    );

Future<void> _emitAndSettle(WidgetTester tester, AdEvent event) async {
  AdManager().debugEmit(event);
  await tester.pump();
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a non-USD AdRevenueEvent does not get added into the USD total on '
      'a real device', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Center(
          child: const RevenuePanel(
              debugModeOverride: true, showDecimals: true),
        ),
      ),
    ));
    await tester.pump();

    await _emitAndSettle(tester, _revenue(1500000, 'USD')); // $1.50
    expect(find.text('\$1.5000'), findsOneWidget);

    await _emitAndSettle(tester, _revenue(2000000, 'EUR')); // must be skipped
    expect(find.text('\$1.5000'), findsOneWidget,
        reason: 'a non-USD event must still not be mixed into the USD '
            'total on a real device — this must not have become 3.5000');
  });
}
