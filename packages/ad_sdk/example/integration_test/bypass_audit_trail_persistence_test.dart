// T155 — on-device proof that BypassAuditTrail actually round-trips
// through the REAL native SharedPreferences plugin (not the in-memory
// mock every unit test uses), not just that AdManager's own trail object
// keeps its entries for the lifetime of one process (already covered by
// integration_test/bypass_audit_trail_test.dart).
//
// A genuine "kill the process and relaunch" cannot be automated through
// `flutter test` — a single test file/process never truly dies mid-run.
// The strongest automatable proof instead: construct a SEPARATE, fresh
// BypassAuditTrail (one that never recorded anything itself) and attach()
// it to the same real on-device storage AdManager's own trail just wrote
// to — if the real plugin channel round-trip works, it reads back the
// entry. This is the same pattern test/bypass_audit_trail_test.dart proves
// against the in-memory mock, run here against the real platform channel.
// A human tester should still do the real kill-and-relaunch check once
// (see ComplianceDemoPage's own "Bypass audit trail (T155)" card).
//
// Run with:
//   flutter test integration_test/bypass_audit_trail_persistence_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
// Internal on purpose — a real consuming app has no access to AdPreferences
// either; this test needs it directly to prove the real plugin round-trip.
// ignore: implementation_imports
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a fresh BypassAuditTrail attached to the same real device storage '
      'reloads an entry the live one just persisted', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tag = 'device_test_${DateTime.now().millisecondsSinceEpoch}';
    AdManager().bypassAuditTrail.record(
        kind: 'bypassSafety', callSiteTag: tag, type: AdSlotType.appOpen);
    await AdManager().bypassAuditTrail.flush();

    final prefs = await AdPreferences.getInstance();
    final reloaded = BypassAuditTrail();
    reloaded.attach(prefs);

    expect(reloaded.entries.any((e) => e.callSiteTag == tag), isTrue,
        reason: 'T155 — a separate BypassAuditTrail instance reading the '
            'SAME real on-device SharedPreferences storage must see an '
            'entry the live trail just persisted, proving the real '
            '(not mocked) plugin round-trip actually reaches disk');
    expect(tester.takeException(), isNull);
  });
}
