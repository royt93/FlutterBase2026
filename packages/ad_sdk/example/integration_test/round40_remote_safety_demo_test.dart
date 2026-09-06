// Round-40 audit — the example app's RemoteSafetyDemoPage (T88) is the only
// place this SDK demos `RemoteAdSafetyProvider` end to end with a live
// destroy()+initialize() cycle. This confirms it actually works on a real
// device: wiring the provider, pushing a simulated remote value, and
// `refreshRemoteSafetyParams()` really lands in `AdSafetyConfig`'s live
// params — not just that the button doesn't crash.
//
// Run with:
//   flutter test integration_test/round40_remote_safety_demo_test.dart -d <device-or-sim-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
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
      'RemoteSafetyDemoPage wires a real provider and refreshRemoteSafetyParams '
      'applies its value to the live AdSafetyConfig', (tester) async {
    tester.view.physicalSize = const Size(1080, 4600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final tile = find.text('Remote safety provider (T88)');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue,
        reason: 'HomePage must list the remote safety provider tile');

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(find.text('Remote safety provider demo'), findsOneWidget);

    // Wire the provider for real — destroy()+initialize(remoteSafetyProvider:).
    await tester.tap(find.text('Apply provider (destroy + re-initialize)'));
    await _waitForInit(tester);
    await tester.pumpAndSettle(const Duration(seconds: 1));
    expect(tester.takeException(), isNull,
        reason: 'wiring the provider via destroy()+initialize() must not throw');
    expect(find.text('Provider already wired'), findsOneWidget,
        reason: 'button must flip once re-init actually completes');

    // Drag the slider to its maximum (50) — deterministic and distinguishable
    // from every built-in default (20).
    await tester.drag(find.byType(Slider), const Offset(2000, 0));
    await tester.pump();
    expect(find.textContaining('50'), findsWidgets,
        reason: 'slider must actually move the simulated remote value');

    await tester.tap(find.text('Push update (refreshRemoteSafetyParams)'));
    await tester.pumpAndSettle(const Duration(seconds: 2));

    expect(tester.takeException(), isNull,
        reason: 'refreshRemoteSafetyParams() must not throw with a real '
            'provider wired');
    expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 50,
        reason: 'the pushed simulated remote value must actually reach the '
            'live AdSafetyConfig — proving the whole demo wiring, not just '
            'that the buttons are inert');
  });
}
