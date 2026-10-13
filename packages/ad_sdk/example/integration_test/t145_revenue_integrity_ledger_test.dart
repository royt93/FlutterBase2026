// T145 on-device integration test — RevenueIntegrityLedger flags a real
// successful show with no matching revenue event, through a real
// AdManager() session, on a real device.
//
// Run with:
//   flutter test integration_test/t145_revenue_integrity_ledger_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'a show past its wall-clock deadline expires on resume without another event',
    (tester) async {
      AdManager().incidentRecorder.clear();
      var now = DateTime(2026, 1, 1);
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 10),
        debugClock: () => now,
      );
      AdManager().enableRevenueIntegrityLedger(ledger);
      addTearDown(AdManager().disableRevenueIntegrityLedger);

      AdManager().debugEmit(
        const AdShowEvent(
          providerTag: '[ResumeWallClock]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ),
      );
      await tester.pump();
      expect(ledger.pendingCount, 1);

      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(seconds: 11));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, hasLength(1));
      expect(
        AdManager().incidentRecorder.entries.single.label,
        contains('[ResumeWallClock]'),
      );
    },
  );

  testWidgets('a show before its wall-clock deadline stays pending on resume', (
    tester,
  ) async {
    AdManager().incidentRecorder.clear();
    var now = DateTime(2026, 1, 1);
    final ledger = RevenueIntegrityLedger(
      matchWindow: const Duration(seconds: 10),
      debugClock: () => now,
    );
    addTearDown(ledger.dispose);

    AdManager().debugEmit(
      const AdShowEvent(
        providerTag: '[ResumeBeforeDeadline]',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ),
    );
    await tester.pump();
    now = now.add(const Duration(seconds: 9));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();

    expect(ledger.pendingCount, 1);
    expect(AdManager().incidentRecorder.entries, isEmpty);
  });

  testWidgets(
    'a real deadline expiring while lifecycle is paused is swept on resume',
    (tester) async {
      AdManager().incidentRecorder.clear();
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 8),
      );
      AdManager().enableRevenueIntegrityLedger(ledger);
      addTearDown(AdManager().disableRevenueIntegrityLedger);

      AdManager().debugEmit(
        const AdShowEvent(
          providerTag: '[PixelSleepWindow]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ),
      );
      await tester.pump();
      expect(ledger.pendingCount, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);

      await Future<void>.delayed(const Duration(seconds: 12));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, hasLength(1));
      expect(
        AdManager().incidentRecorder.entries.single.label,
        contains('[PixelSleepWindow]'),
      );
    },
  );

  testWidgets(
    'a successful show with no matching revenue event expires while idle '
    'on a real device',
    (tester) async {
      AdManager().incidentRecorder.clear();
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(milliseconds: 50),
      );
      addTearDown(ledger.dispose);

      AdManager().debugEmit(
        const AdShowEvent(
          providerTag: '[RealDeviceFake]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ),
      );
      await tester.pump();
      expect(ledger.pendingCount, 1);

      await Future<void>.delayed(const Duration(milliseconds: 100));
      await tester.pump();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, hasLength(1));
      expect(
        AdManager().incidentRecorder.entries.single.label,
        contains('[RealDeviceFake]'),
      );
    },
  );

  testWidgets(
    'a matching revenue event within the window clears the pending show '
    '— no incident, on a real device',
    (tester) async {
      AdManager().incidentRecorder.clear();
      final ledger = RevenueIntegrityLedger(
        matchWindow: const Duration(seconds: 60),
      );
      addTearDown(ledger.dispose);

      AdManager().debugEmit(
        const AdShowEvent(
          providerTag: '[RealDeviceFake]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          success: true,
        ),
      );
      AdManager().debugEmit(
        const AdRevenueEvent(
          providerTag: '[RealDeviceFake]',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          valueMicros: 1000,
          currencyCode: 'USD',
        ),
      );
      await tester.pump();

      expect(ledger.pendingCount, 0);
      expect(AdManager().incidentRecorder.entries, isEmpty);
    },
  );
}
