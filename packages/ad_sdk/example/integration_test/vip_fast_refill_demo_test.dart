// T148 — VipDemoPage's "End VIP now" button (fast-refill proof) actually
// ends VIP on a real device without throwing, and the debug overlay is
// present to observe the reload it triggers. The exact load-call ordering
// (all four fullscreen formats reload together, not three) is already
// pinned precisely in test/fast_refill_rewarded_interstitial_test.dart at
// the unit level; this proves the demo button itself is wired to the real
// SDK, not just that it compiles.
//
// An independent codex re-review of the first version of this file caught
// that relying on the ephemeral first-install VIP grace made the test
// silently no-op (still reported "passed") on every device that had already
// used up its one-time grace — which includes any repeated run on the same
// device. Grants its own deterministic VIP entry via the real addVip() API
// instead, so the button is always present and always exercised.
//
// Run with:
//   flutter test integration_test/vip_fast_refill_demo_test.dart -d <device-or-sim-id>

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

  testWidgets('End VIP now ends a real VIP grant', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip;
    expect(vip, isNotNull, reason: 'SDK must expose a VipManager once init');
    // Deterministic — do not depend on the one-time first-install grace,
    // which is already gone on any device this test has run on before.
    await vip!.addVip(key: 'T148_DEMO', duration: const Duration(hours: 1));
    expect(vip.isActive, isTrue, reason: 'sanity: the grant must be active');

    // "VIP / redeem" navigates to VipRedeemScreen instead — a different
    // page entirely. "End VIP now" lives on VipDemoPage, reached via the
    // "VIP API playground" tile (2026-09-24: found via a real-device run —
    // this test was on the wrong page the whole time, not a timing issue).
    final tile = find.text('VIP API playground');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list VIP / redeem tile');

    await tester.tap(tile);
    await tester.pumpAndSettle(const Duration(seconds: 1));

    final endButton = find.text('End VIP now');
    expect(endButton, findsOneWidget,
        reason: 'the button must be visible whenever VIP is active — if '
            'this fails, the button was removed/renamed or VIP is not '
            'active as asserted above');

    await tester.tap(endButton);
    // Not pumpAndSettle: the recurring ad-retry timer this button kicks off
    // never lets the tree "settle" on a real device with no fill, which is
    // exactly what this test wants to observe — a few fixed pumps instead.
    for (var i = 0; i < 6; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(tester.takeException(), isNull,
        reason: 'ending VIP and kicking the fast-refill reload must not '
            'throw');
    expect(vip.isActive, isFalse,
        reason: '"End VIP now" must actually revoke the real VIP grant');
  });
}
