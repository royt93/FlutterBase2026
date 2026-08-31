// T111 on-device integration test — AdManager().refreshRemoteSafetyParams()
// must be safe to call post-init and must not throw even with no
// RemoteAdSafetyProvider configured (fail-open, keeps current params).
//
// Run with:
//   flutter test integration_test/remote_safety_refresh_test.dart -d <device-or-sim-id>

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
      'refreshRemoteSafetyParams() is safe to call on a real running SDK',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    await AdManager().refreshRemoteSafetyParams();
    await tester.pump(const Duration(milliseconds: 200));

    expect(tester.takeException(), isNull,
        reason: 'no remote provider configured — must fail open, not throw');
  });
}
