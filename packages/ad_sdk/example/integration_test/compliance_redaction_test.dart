// T110 on-device integration test — ComplianceReport.redacted() must strip
// the fields a profile declares, using a report built from the app's own
// real event log (not a hand-built ComplianceReport).
//
// Run with:
//   flutter test integration_test/compliance_redaction_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
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
      'supportSafe profile strips consentCountry/placement from a real report',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final report = AdManager().exportComplianceReport();
    final redacted = report.redacted(ReportRedactionProfile.supportSafe);

    for (final entry in redacted.events) {
      expect(entry.containsKey('consentCountry'), isFalse,
          reason: 'supportSafe must strip consentCountry');
      expect(entry.containsKey('placement'), isFalse,
          reason: 'supportSafe must strip placement');
    }
    expect(tester.takeException(), isNull);
  });
}
