// Integration test for T173 hardening — the compiled example app's active
// provider must advertise banner error self-collapse via adapter capability,
// not via BannerAdWidget hardcoding provider checks.
//
// Run with AdMob:
//   flutter test integration_test/r173_banner_self_collapse_capability_test.dart \
//     -d <device-or-sim-id> --dart-define=AD_PROVIDER_ADMOB=true

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

  testWidgets('active provider exposes banner error self-collapse capability',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    const isAdMob = bool.fromEnvironment('AD_PROVIDER_ADMOB');
    expect(
      AdManager().collapsesBannerOnError,
      isAdMob,
      reason: 'AdMob must opt in to T173 self-collapse preservation; '
          'non-AdMob providers must keep the safe default false.',
    );
    expect(tester.takeException(), isNull);
  });
}
