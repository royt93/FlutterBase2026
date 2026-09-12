// On-device integration test for T174 — canShowAppOpenOnResumePeek() must
// not consume any of the real gate's one-shot state (cold-start flag,
// pending-resume gate, rolling resume-timestamp window) on a real device,
// same guarantee already proven in unit tests against the pure logic. No UI
// demo needed — this is an internal safety-gate API, exercised directly.
//
// Run with:
//   flutter test integration_test/r174_appopen_resume_peek_test.dart \
//     -d <device-or-sim-id>

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
      'repeated canShowAppOpenOnResumePeek() calls do not consume the '
      'cold-start flag or the pending-resume gate, on a real device',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    AdSafetyConfig.resetForReinit();

    // Cold start: peeking repeatedly must never consume the one-shot flag.
    for (var i = 0; i < 5; i++) {
      final peek = AdSafetyConfig.canShowAppOpenOnResumePeek();
      expect(peek.canShow, isFalse);
      expect(peek.reason, contains('cold start'));
    }
    final real1 = AdSafetyConfig.canShowAppOpenOnResume();
    expect(real1.canShow, isFalse,
        reason: 'T174 — on a real device, peeking must not have consumed '
            'the cold-start flag before this real call');
    expect(real1.reason, contains('cold start'));

    // Pending-resume gate: peeking repeatedly after a real background must
    // not consume it either — a later call must still see a genuine
    // (not spurious) resume.
    AdSafetyConfig.recordAppWentBackground();
    for (var i = 0; i < 5; i++) {
      final peek = AdSafetyConfig.canShowAppOpenOnResumePeek();
      expect(peek.reason, isNot(contains('spurious')));
    }
    final real2 = AdSafetyConfig.canShowAppOpenOnResume();
    expect(real2.reason, isNot(contains('spurious')),
        reason: 'T174 — on a real device, peeking must not have consumed '
            'the pending-resume gate before this real call');
    expect(tester.takeException(), isNull);
  });
}
