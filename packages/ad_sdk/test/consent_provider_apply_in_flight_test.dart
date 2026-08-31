// Round-26 audit regression (claude, finding #5 — fix attempt 3): a
// tightening setConsent() call (GDPR withdrawal, a fresh CCPA opt-out) used
// to call applyConsentToProviders() with the gate wide open. That function
// applies to AppLovin synchronously but AWAITS AdMob's
// updateRequestConfiguration — during that gap a concurrent load could fire
// under AdMob's OLD, more permissive global RequestConfiguration.
//
// Fix: AdManager._consentProviderApplyInFlight, a narrow flag set only for a
// tightening setConsent() call, bracketing just that one await — distinct
// from (and not interacting with) the round-11 `_pessimisticGateClose`
// mechanism, which solves a different problem (a queued apply's unknown
// outcome) and is not touched by this fix.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Just enough of [AdProviderAdapter] for `setConsent()` to see the SDK as
/// initialised — `applyConsent` is the only member it actually calls.
class _MinimalAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  @override
  void applyConsent(AdConsent consent) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  Completer<void>? updateRequestConfigGate;

  setUp(() {
    updateRequestConfigGate = null;
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async {
      if (call.method == 'MobileAds#updateRequestConfiguration') {
        final gate = updateRequestConfigGate;
        if (gate != null) await gate.future;
      }
      return null;
    });
    AdManager().debugConfig = _admobConfig;
    AdManager().debugSetAdapter(_MinimalAdapter());
  });

  tearDown(() async {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'a tightening setConsent() blocks canRequestAds only while the '
      'provider apply is actually in flight', () async {
    // Establish a granted baseline first, so the next call is a genuine
    // tightening (true → false), matching the field's own gating condition.
    await AdManager().setConsent(const AdConsent(hasUserConsent: true));
    expect(AdManager().canRequestAds, isTrue, reason: 'sanity: baseline open');

    updateRequestConfigGate = Completer<void>();
    final future =
        AdManager().setConsent(const AdConsent(hasUserConsent: false));

    // Give the synchronous AppLovin leg and the start of the AdMob await a
    // turn to run, landing inside the gate.
    await Future<void>.delayed(Duration.zero);
    expect(AdManager().canRequestAds, isFalse,
        reason: 'a concurrent load here would go out under AdMob\'s OLD '
            'RequestConfiguration — must be blocked while the write is '
            'still in flight');

    updateRequestConfigGate!.complete();
    await future;

    expect(AdManager().canRequestAds, isTrue,
        reason: 'the flag must self-clear once the apply has actually '
            'landed — withdrawing personalisation does not withdraw ads');
  });

  test(
      'a loosening setConsent() (granting consent) never blocks '
      'canRequestAds, even mid-apply', () async {
    // Guards against over-scoping the fix to every setConsent() call instead
    // of just the tightening direction — round-26 fix attempt 3, step 1
    // broke exactly this shape of case (a COPPA-grant test reading
    // canRequestAds synchronously mid-apply).
    updateRequestConfigGate = Completer<void>();
    final future =
        AdManager().setConsent(const AdConsent(hasUserConsent: true));

    await Future<void>.delayed(Duration.zero);
    expect(AdManager().canRequestAds, isTrue,
        reason: 'granting consent has no stale-config window worth '
            'guarding — must not be blocked');

    updateRequestConfigGate!.complete();
    await future;
  });
}
