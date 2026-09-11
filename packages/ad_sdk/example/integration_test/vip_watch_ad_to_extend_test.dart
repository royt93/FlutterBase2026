// T156 — VipDemoPage's "Watch ad -> +3 days VIP (stack)" button actually
// reaches a real rewarded ad on a real device while VIP is active, proving
// showRewardedAd(bypassVipGuard: true) — routed through the documented
// AdScreenState helper, not AdManager().showRewardedAd() directly — really
// bypasses the VIP suppression. Before this task's fix, the helper had no
// bypassVipGuard param at all, so the VIP short-circuit inside it always
// won first and this button's own onPressed call could never have reached
// a real ad regardless of what AdManager supported underneath.
//
// Run with:
//   flutter test integration_test/vip_watch_ad_to_extend_test.dart -d <device-or-sim-id>

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
      'Watch ad -> +3 days VIP (stack) reaches a real rewarded ad while VIP '
      'is already active', (tester) async {
    tester.view.physicalSize = const Size(1080, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip;
    expect(vip, isNotNull, reason: 'SDK must expose a VipManager once init');
    await vip!.addVip(key: 'T156_DEMO', duration: const Duration(hours: 1));
    expect(vip.isActive, isTrue, reason: 'sanity: the grant must be active');

    final tile = find.text('VIP / redeem');
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
    // Not pumpAndSettle: VipDemoPage's own countdown/VIP-status display
    // rebuilds on a live timer and never lets the tree "settle" — fixed
    // pumps instead, same reasoning as vip_fast_refill_demo_test.dart.
    // Generous count: the route-push animation must fully finish before a
    // Scrollable exists to search for below.
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 300));
    }

    final button = find.text('Watch ad → +3 days VIP (stack)');
    var foundScrollable = false;
    for (var i = 0; i < 10; i++) {
      if (find.byType(Scrollable).evaluate().isNotEmpty) {
        foundScrollable = true;
        break;
      }
      await tester.pump(const Duration(milliseconds: 300));
    }
    expect(foundScrollable, isTrue,
        reason: 'VipDemoPage must have mounted its body by now');
    await tester.scrollUntilVisible(button, 300,
        scrollable: find.byType(Scrollable).first);
    for (var i = 0; i < 4; i++) {
      await tester.pump(const Duration(milliseconds: 250));
    }

    final bypassEntriesBefore = AdManager()
        .bypassAuditTrail
        .entries
        .where((e) => e.callSiteTag == 'vip_extend_screen')
        .length;

    await tester.tap(button);
    // Not pumpAndSettle: a real on-demand rewarded load/show can pump
    // frames for a while — a few fixed pumps instead, mirroring
    // vip_fast_refill_demo_test.dart's own reasoning for the same button
    // family on this page.
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(tester.takeException(), isNull,
        reason: 'T156 — bypassVipGuard:true through the documented '
            'showRewardedAd() helper must not throw while VIP is active');
    // codex re-review (P2) — takeException() alone would still pass even if
    // the VIP short-circuit were accidentally restored, since a suppressed
    // ad reports failure through onEarnedReward(false), not a thrown
    // exception. bypassAuditTrail.record(kind: 'bypassVipGuard', ...) only
    // fires from INSIDE AdManager().showRewardedAd()'s own bypassVipGuard
    // branch (see T155) — a new entry here proves the tap genuinely
    // reached that real code path, not just that nothing crashed.
    final bypassEntriesAfter = AdManager()
        .bypassAuditTrail
        .entries
        .where((e) => e.callSiteTag == 'vip_extend_screen')
        .length;
    expect(bypassEntriesAfter, greaterThan(bypassEntriesBefore),
        reason: 'T156 — the tap must actually reach '
            'AdManager().showRewardedAd(bypassVipGuard: true), not silently '
            'stop at AdScreenState\'s own VIP short-circuit');
  });
}
