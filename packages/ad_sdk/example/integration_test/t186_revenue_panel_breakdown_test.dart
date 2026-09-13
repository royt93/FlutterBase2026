// T186 on-device integration test — RevenuePanel's per-AdSlotType
// breakdown renders correctly on a real device/screen.
//
// Run with:
//   flutter test integration_test/t186_revenue_panel_breakdown_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdRevenueEvent _revenue(AdSlotType type, int valueMicros) => AdRevenueEvent(
      providerTag: '[RealDeviceFake]',
      type: type,
      placement: AdPlacement.unspecified,
      valueMicros: valueMicros,
      currencyCode: 'USD',
    );

Future<void> _emitAndSettle(WidgetTester tester, AdEvent event) async {
  AdManager().debugEmit(event);
  await tester.pump();
  await tester.pump();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'interstitial and rewarded revenue each get their own breakdown '
      'row, and the session total is their sum, on a real device',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: Scaffold(
        body: Center(
          child: RevenuePanel(debugModeOverride: true, showDecimals: true),
        ),
      ),
    ));
    await tester.pump();

    await _emitAndSettle(
        tester, _revenue(AdSlotType.interstitial, 1230000)); // $1.23
    await _emitAndSettle(tester, _revenue(AdSlotType.rewarded, 4560000)); // $4.56

    expect(find.text('\$5.7900'), findsOneWidget,
        reason: 'session total: 1.23 + 4.56 = 5.79');
    expect(find.text('interstitial'), findsOneWidget);
    expect(find.text('rewarded'), findsOneWidget);
    expect(find.text('\$1.2300  /  1 imp'), findsOneWidget);
    expect(find.text('\$4.5600  /  1 imp'), findsOneWidget);
  });
}
