// T187 on-device integration test — AdDiagnostics.pendingRevenueChecks and
// .recentRevenueIntegrityIncidents reflect a real RevenueIntegrityLedger's
// live state and a real IncidentRecorder entry, on a real device process
// (not just the debugEmit-driven unit tests in test/ad_diagnostics_test.dart).
//
// Run with:
//   flutter test integration_test/t187_diagnostics_revenue_integrity_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _placement = AdPlacement.unspecified;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdManager().disableRevenueIntegrityLedger();
    AdManager().incidentRecorder.clear();
  });

  testWidgets(
      'a successful show with no matching revenue event becomes a pending '
      'check, then (past matchWindow) a recorded incident — both visible '
      'in AdManager().diagnostics() on a real device', (tester) async {
    AdManager().enableRevenueIntegrityLedger(
        RevenueIntegrityLedger(matchWindow: const Duration(milliseconds: 1)));

    expect(AdManager().diagnostics().pendingRevenueChecks, 0);
    expect(AdManager().diagnostics().recentRevenueIntegrityIncidents, 0);

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[AdMob]',
      type: AdSlotType.interstitial,
      placement: _placement,
      success: true,
    ));
    await tester.pump();
    await tester.pump();

    expect(AdManager().diagnostics().pendingRevenueChecks, 1,
        reason: 'a real successful show with no revenue event yet must be '
            'pending, on a real device event stream');

    // Real device clock, no fake_async — a genuine, if short, wait past
    // the 1ms matchWindow, then an unrelated event triggers the sweep
    // (RevenueIntegrityLedger only checks expiry when processing an event).
    await Future<void>.delayed(const Duration(milliseconds: 50));
    AdManager().debugEmit(const AdClickEvent(
      providerTag: '[AdMob]',
      type: AdSlotType.interstitial,
      placement: _placement,
    ));
    await tester.pump();
    await tester.pump();

    final d = AdManager().diagnostics();
    expect(d.pendingRevenueChecks, 0,
        reason: 'the expired pending show must have been swept');
    expect(d.recentRevenueIntegrityIncidents, 1,
        reason: 'the sweep must have recorded a real incident, on a real '
            'device, readable back through AdDiagnostics');
  });
}
