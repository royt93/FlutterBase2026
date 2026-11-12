// Round-39 audit (MINOR) — the example app never demonstrated
// VipRevocationProvider/refreshRevocationList wiring at all, so a partner
// copying this example verbatim could ship VIP-code revocation completely
// inert without realising it. VipDemoPage now has a "Refresh revocation
// list (CRL)" button (demo_crl_provider.dart's DemoCrlProvider) — this
// confirms it actually works end to end on a real device: tapping it calls
// through to VipManager.refreshRevocationList and neither crashes nor blocks
// the page. Without --dart-define=VIP_CRL_URL the provider is a no-op.
//
// Run with:
//   flutter test integration_test/round39_vip_crl_demo_button_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

import 'scroll_helpers.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised) return;
  }
  fail('SDK must finish initialising on device');
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('the CRL demo button calls refreshRevocationList without crashing '
      'or blocking the page', (tester) async {
    // Same synthetic tall viewport as vip_api_playground_test.dart — the
    // HomePage demo list is viewport-lazy at default phone height.
    tester.view.physicalSize = const Size(1080, 4000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('VIP API playground');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(
      foundTile,
      isTrue,
      reason: 'HomePage must list the VIP API playground tile',
    );

    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.text('VIP demo'), findsOneWidget);

    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    await tester.pump();

    final crlButton = find.text('Refresh revocation list (CRL)');
    await tester.scrollUntilVisibleAndSettle(
      crlButton,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(crlButton);
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(
      tester.takeException(),
      isNull,
      reason: 'tapping the CRL demo button must never throw',
    );
    // T273: the snackbar text depends on whether --dart-define=VIP_CRL_URL is
    // set. Without it (this test's default) the provider is a no-op and says so.
    expect(
      find.textContaining('No VIP_CRL_URL set'),
      findsOneWidget,
      reason: 'the demo snackbar must confirm the call actually ran',
    );
  });
}
