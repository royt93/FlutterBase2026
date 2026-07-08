// On-device integration test for the policy risk score (T24).
//
// Boots the full example app, waits for SDK init, then proves
// AdManager().policyRiskScore is reachable and reactive against the real
// native SDK (not just the null-safe pre-init path already covered by the
// headless widget test).
//
// Run with:
//   flutter test integration_test/policy_risk_score_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('policyRiskScore is a bounded, reactive score post-init',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final score = AdManager().policyRiskScore.value;
    expect(score, inInclusiveRange(0, 100));
    expect(AdSafetyConfig.getPolicyRiskScore(), score);
  });

  testWidgets('Safety demo page renders the live policy risk score',
      (tester) async {
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Safety status');
    var foundTile = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the Safety status tile');

    await tester.scrollUntilVisible(tile, 200,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(tile);
    await tester.pumpAndSettle();

    expect(find.textContaining('Policy risk score'), findsOneWidget);
    expect(find.textContaining('/ 100'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
