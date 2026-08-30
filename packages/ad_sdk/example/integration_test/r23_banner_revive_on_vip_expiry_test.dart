// On-device integration test for round-23 MINOR V6 — inline ad surfaces must
// come back the moment VIP expires.
//
// The finding: gaining VIP hid banners immediately, but losing it did not bring
// them back until something else happened to rebuild the widget. A user whose
// paid window ended saw a permanently blank banner slot for the rest of the
// session, and the app earned nothing from it.
//
// `_onVipActiveChanged` now bumps `initRevision`, which is the signal
// `BannerAdWidget` already listens to. The unit/widget tests
// (`packages/ad_sdk/test/r23_vip_expiry_banner_revive_test.dart`) prove the
// bump and prove the widget reloads on it, but they do both against fakes. This
// file drives the real Banner demo page, with the real adapter mounted and the
// real VIP store, and asserts the transition happens end to end without the
// widget tree throwing.
//
// Ad *fill* is never guaranteed (least of all on an emulator), so this
// deliberately does NOT assert that a creative appeared — only that the SDK
// asks for one again. Asserting on fill would make the test a network check.
//
// Run with:
//   flutter test integration_test/r23_banner_revive_on_vip_expiry_test.dart -d <device-id>

import 'package:ad_sdk_example/main.dart' as app;
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

Future<void> _waitForInit(WidgetTester tester) async {
  for (var i = 0; i < 180; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    if (AdManager().isInitialised && AdManager().vip != null) return;
  }
  fail('SDK must finish initialising on device');
}

Future<void> _pumpFor(WidgetTester tester, int steps) async {
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 300));
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('losing VIP asks the real banner page to load again',
      (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);

    final vip = AdManager().vip!;
    await vip.revokeAll();
    await _pumpFor(tester, 5);

    // Grant VIP BEFORE the banner page is ever mounted. This is the shape that
    // makes the assertion below mean something: the banner has never loaded, so
    // a load event after the expiry can only have been caused by the fix. If
    // the page were opened first and then suppressed, the already-loaded banner
    // would simply be un-hidden, no new request would be made, and "no load
    // event" would prove nothing either way.
    await vip.addVip(
        key: 'R23-REVIVE-DEVICE', duration: const Duration(days: 1));
    await _pumpFor(tester, 10);
    expect(AdManager().isVIPMember(), isTrue,
        reason: 'sanity — the grant must actually take on the real store');

    final bannerLoads = <AdLoadEvent>[];
    final sub = AdManager().events.listen((e) {
      if (e is AdLoadEvent && e.type == AdSlotType.banner) bannerLoads.add(e);
    });
    addTearDown(sub.cancel);

    // Splash replaces itself with Home on the ROOT navigator — wait for a Home
    // landmark before navigating, pushing too early races that replace.
    final tile = find.text('Banner ad');
    var foundTile = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) {
        foundTile = true;
        break;
      }
    }
    expect(foundTile, isTrue, reason: 'HomePage must list the Banner ad tile');

    await tester.tap(tile);
    await _pumpFor(tester, 20);
    expect(find.text('Banner demo'), findsOneWidget);

    // CONTROL — the page is mounted under an active VIP, so nothing has been
    // requested. This is also what makes the assertion after the expiry a real
    // one rather than an accident of timing.
    expect(bannerLoads, isEmpty,
        reason: 'a VIP must not have an ad requested for them at all — '
            'suppression that still costs a request is not suppression');

    // The window ends. This is the transition that used to leave the slot
    // blank for the rest of the session.
    //
    // Round-24 QC (reviewer A): asserting the revision bump alone stops one
    // layer short of the outcome. What the user is owed is a banner request
    // actually reaching the adapter, so listen for the real load event the
    // real AdMob adapter emits — success or failure, either proves the SDK
    // asked. (Asserting on *fill* would make this a network check that fails
    // for reasons unrelated to the fix.)
    final beforeExpiry = AdManager().initRevision.value;
    await vip.revokeAll();
    await _pumpFor(tester, 15);

    expect(AdManager().isVIPMember(), isFalse);
    expect(AdManager().initRevision.value, greaterThan(beforeExpiry),
        reason: 'THE finding — nothing else tells the banner its suppression '
            'is over, so without this bump the slot stays blank and the app '
            'earns nothing from it for the rest of the session');

    // The page must still be alive and un-thrown after the transition — a
    // reload triggered on a disposed slot would surface here.
    expect(find.text('Banner demo'), findsOneWidget);
    expect(tester.takeException(), isNull);

    // Give the real load a window to come back one way or the other.
    for (var i = 0; i < 40 && bannerLoads.isEmpty; i++) {
      await tester.pump(const Duration(milliseconds: 500));
    }

    expect(bannerLoads, isNotEmpty,
        reason: 'the revision bump is only worth something if a banner '
            'request actually reaches the adapter — this is the assertion '
            'that says the user gets an ad slot back, not just a notifier '
            'tick');

    expect(tester.takeException(), isNull,
        reason: 'and it must still be clean once the reload has had time to '
            'come back (or fail) on the real network');
  }, timeout: const Timeout(Duration(minutes: 6)));
}
