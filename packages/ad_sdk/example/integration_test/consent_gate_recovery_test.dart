// On-device integration test for round-13 QC round 12 (MAJOR) — the ad gate
// must never be left shut by an apply that never landed.
//
// Round 11 shuts the gate for any consent result queued behind a running
// apply, because a queued result cannot be known to be a grant: a
// purposes-only withdrawal reports `canRequestAds=true`. That close is a
// guess, so somebody has to lift it — and the apply that was supposed to can
// end without writing anything (the host makes its own `setConsent` decision
// in the meantime) or die on the way (its write throws). Nothing else in the
// SDK reopens the gate: `setConsent` deliberately does not own it. The result
// was every ad surface in the app dark for the rest of the session.
//
// Why on-device: the recovery consults the real UMP channel for whether ads
// are allowed at all before it reopens anything, and reads the platform's own
// TCF keys to check that what is applied still matches the device. Both are
// plumbing a mocked test cannot prove.
//
// Round 14 adds the refill half of the same contract (see the third test).
//
// Unit coverage of the same contract: test/tcf_personalisation_consent_test.dart
// ("a pessimistic close is lifted when the apply that owed it was superseded"
// / "... that owed it failed"). Widget coverage of the consequence:
// test/consent_gate_banner_widget_test.dart.
//
// Run with:
//   flutter test integration_test/consent_gate_recovery_test.dart -d <device>

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _admobConfig() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

Future<bool> _gateOpenWithin(WidgetTester tester, Duration limit) async {
  final steps = limit.inMilliseconds ~/ 250;
  for (var i = 0; i < steps; i++) {
    await tester.pump(const Duration(milliseconds: 250));
    if (AdManager().canRequestAds) return true;
  }
  return AdManager().canRequestAds;
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    AdManager.debugConsentWriteBarrier = null;
    await AdManager().destroy();
  });

  testWidgets('a queued apply superseded by the host still leaves the ad gate '
      'open', (tester) async {
    await AdManager()
        .initialize(config: _admobConfig(), onComplete: (_, __) {});
    await AdManager().requestUmpConsent();

    // One apply parks at its write — a slow provider call is all it takes.
    final stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));

    // A second result queues behind it, which shuts the gate (round 11).
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));

    // The host now makes its own decision. It supersedes both applies, so
    // neither of them is ever going to reopen what round 11 shut.
    AdManager.debugConsentWriteBarrier = null;
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    stuck.complete();
    await first;
    await queued;

    expect(await _gateOpenWithin(tester, const Duration(seconds: 10)), isTrue,
        reason: 'UMP allows ads on this device and what is applied matches it '
            '— a gate left shut here means no banner, no interstitial and no '
            'app-open ad for the rest of the session');
  });

  // Round-14 QC, MINOR, on device — reopening the gate is only half of it: the
  // ordinary apply refills the held fullscreen slots too, and the recovery did
  // not. A user whose gate was reopened this way had no app-open, interstitial
  // or rewarded ad loaded behind it until the next route change or the
  // five-minute scan, which on a single-screen session is never.
  //
  // On device because the refill goes through the real AdMob adapter: the slot
  // state a mocked adapter reports is our own bookkeeping, not the plugin's.
  testWidgets('a recovered gate has its fullscreen slots refilled behind it',
      (tester) async {
    await AdManager()
        .initialize(config: _admobConfig(), onComplete: (_, __) {});
    await AdManager().requestUmpConsent();
    // A VIP loads no ads at all — by design — and this fleet's devices carry
    // VIP entries from the other suites. Same setup the ad-loading integration
    // tests use.
    await AdManager().vip!.revokeAll();
    await tester.pump(const Duration(milliseconds: 500));

    final stuck = Completer<void>();
    AdManager.debugConsentWriteBarrier = stuck.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));

    AdManager.debugConsentWriteBarrier = null;
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    stuck.complete();
    await first;
    await queued;
    expect(await _gateOpenWithin(tester, const Duration(seconds: 10)), isTrue,
        reason: 'sanity: the recovery reopened the gate');

    var refilled = false;
    for (var i = 0; i < 40; i++) {
      await tester.pump(const Duration(milliseconds: 250));
      final slot = AdManager().adapter?.interstitialSlot;
      if (slot != null && !slot.isIdle) {
        refilled = true;
        break;
      }
    }
    expect(refilled, isTrue,
        reason: 'an open gate with every slot still empty is the same blank '
            'screen to the user as a shut one');
  });

  testWidgets('an apply whose write fails does not take the queued intent '
      'down with it', (tester) async {
    await AdManager()
        .initialize(config: _admobConfig(), onComplete: (_, __) {});
    await AdManager().requestUmpConsent();

    final failing = Completer<void>();
    AdManager.debugConsentWriteBarrier = failing.future;
    final first = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));
    final queued = AdManager().showPrivacyOptions();
    await tester.pump(const Duration(milliseconds: 200));

    AdManager.debugConsentWriteBarrier = null;
    failing.completeError(StateError('storage is gone'));
    await expectLater(first, throwsA(isA<StateError>()),
        reason: 'the caller is still told its own apply failed');
    await queued;

    expect(await _gateOpenWithin(tester, const Duration(seconds: 10)), isTrue,
        reason: 'the queued intent must still get its turn — one failing '
            'write must not cost the session its ads');
  });
}
