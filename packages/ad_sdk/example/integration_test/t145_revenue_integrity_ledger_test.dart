// T145 on-device integration test — RevenueIntegrityLedger flags a real
// successful show with no matching revenue event, through a real
// AdManager() session, on a real device.
//
// Run with:
//   flutter test integration_test/t145_revenue_integrity_ledger_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a successful show with no matching revenue event within the window '
      'is flagged via AdManager().incidentRecorder, on a real device',
      (tester) async {
    AdManager().incidentRecorder.clear();
    final ledger = RevenueIntegrityLedger(
      matchWindow: const Duration(milliseconds: 50),
    );
    addTearDown(ledger.dispose);

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump();
    expect(ledger.pendingCount, 1);

    await Future<void>.delayed(const Duration(milliseconds: 80));
    // A second event drives the expiry sweep (the ledger is purely
    // event-driven, no internal Timer).
    AdManager().debugEmit(const AdClickEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
    ));
    await tester.pump();

    expect(ledger.pendingCount, 0);
    expect(AdManager().incidentRecorder.entries, hasLength(1));
    expect(AdManager().incidentRecorder.entries.single.label,
        contains('[RealDeviceFake]'));
  });

  testWidgets(
      'a matching revenue event within the window clears the pending show '
      '— no incident, on a real device', (tester) async {
    AdManager().incidentRecorder.clear();
    final ledger = RevenueIntegrityLedger(
      matchWindow: const Duration(seconds: 60),
    );
    addTearDown(ledger.dispose);

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    AdManager().debugEmit(const AdRevenueEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: 1000,
      currencyCode: 'USD',
    ));
    await tester.pump();

    expect(ledger.pendingCount, 0);
    expect(AdManager().incidentRecorder.entries, isEmpty);
  });
}
