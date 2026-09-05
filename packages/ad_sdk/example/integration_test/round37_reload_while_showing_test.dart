// On-device integration test for round-37 audit BLOCKER — a reload call must
// not dispose a real, currently-showing ad just because its cache looks
// stale.
//
// Why on-device: `test/admob_behavioral_test.dart`'s "round-37 audit
// (BLOCKER)" group already proves this against a FAKE native bridge. This
// file drives the exact same race against a REAL, currently-displaying
// native AdMob interstitial — the fake bridge can't prove the real
// `GmaFullscreenAd`/native listener survives a reload call while genuinely
// on screen, only that the Dart-side bookkeeping does.
//
// The exact 1-hour cache-expiry window is simulated by reaching into the
// real, already-loaded ad's own bookkeeping field (`AdSlot.lastLoadedAt`,
// the same public-within-package field the unit test manipulates) rather
// than waiting a real hour or touching the device's system clock.
//
// IMPORTANT — same as `interstitial_ad_test.dart`: a HUMAN must manually
// tap the interstitial's close/X button when it appears, since no
// automated on-device UI-automation tool can reach content the native SDK
// renders outside the Flutter widget tree. The generous polling below
// accounts for that.
//
// Run with:
//   flutter test integration_test/round37_reload_while_showing_test.dart -d <device-or-sim-id>

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

Future<void> _revokeVipGraceAndClearConsentDialog(WidgetTester tester) async {
  await AdManager().vip!.revokeAll();
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 300));
    final allow = find.text('Allow personalized ads');
    if (allow.evaluate().isNotEmpty) {
      await tester.tap(allow);
      await tester.pump(const Duration(milliseconds: 300));
      break;
    }
  }
}

Future<bool> _waitForInterstitialLoaded(WidgetTester tester) async {
  for (var i = 0; i < 40; i++) {
    await tester.pump(const Duration(milliseconds: 500));
    final slot = AdManager().adapter?.interstitialSlot;
    if (slot == null) continue;
    if (slot.isReady) return true;
    if (slot.isCooldown) return false;
  }
  return false;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'a real, currently-showing interstitial survives a reload call even '
      'when its cache looks stale (round-37 BLOCKER)', (tester) async {
    app.main();
    await tester.pump();
    await _waitForInit(tester);
    await _revokeVipGraceAndClearConsentDialog(tester);

    final tile = find.text('Interstitial ad');
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (tile.evaluate().isNotEmpty) break;
    }
    await tester.tap(tile);
    await tester.pump(const Duration(milliseconds: 300));

    final loaded = await _waitForInterstitialLoaded(tester);
    expect(loaded, isTrue,
        reason: 'a real interstitial must finish loading before this test '
            'can show it');

    final showButton = find.widgetWithText(
        FilledButton, 'Show interstitial (placement: levelComplete)');
    await tester.tap(showButton);

    final slotOrNull = AdManager().adapter?.interstitialSlot;
    expect(slotOrNull, isNotNull);
    final slot = slotOrNull!;
    // The tap first goes through AdLoadingDialog.showAdBuffer's ~1s buffer
    // window before the real showInterstitial() call even happens, so poll
    // rather than assume a fixed pump is long enough.
    var becameShowing = false;
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 300));
      if (slot.isShowing) {
        becameShowing = true;
        break;
      }
    }
    expect(becameShowing, isTrue,
        reason: 'sanity: the real interstitial must actually be on screen '
            'now — a human should see it on the device');

    // Simulate the >1h cache-expiry race WITHOUT touching the device's real
    // clock: stamp the real, currently-displaying ad's own load-time
    // bookkeeping as if it had loaded 2 hours ago.
    slot.lastLoadedAt = DateTime.now().subtract(const Duration(hours: 2));

    // A background refill call lands while the real ad is still showing —
    // exactly the race the round-37 fix guards against. Pre-fix, this
    // disposed the real, on-screen ad and nulled its native listener.
    await AdManager().loadInterstitial();
    await tester.pump(const Duration(milliseconds: 300));

    expect(slot.isShowing, isTrue,
        reason: 'the real ad on screen must not have been disposed just '
            'because its cache looked stale — if this is false, its '
            'dismiss callback (and the "Show interstitial" button forever '
            'after) is already gone');

    // A human taps the close/X button on the native ad now.
    for (var i = 0; i < 400; i++) {
      await tester.pump(const Duration(milliseconds: 500));
      if (!slot.isShowing) break;
    }

    expect(slot.isShowing, isFalse,
        reason: 'the real dismiss must still resolve normally — if the '
            'round-37 fix regressed the reload-guard, the earlier reload '
            'call may have wedged the slot in showing forever, and no '
            'human tap could ever clear it');
    expect(tester.takeException(), isNull);
  });
}
