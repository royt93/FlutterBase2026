// Behavioural tests for AdMobAdapter via the injectable GmaBridge. A
// FakeGmaBridge hands back fake fullscreen ads that capture the show callbacks,
// so the reward earned-vs-dismissed logic, the dismiss(true)/fail(false)
// resolution and the load-failure path are all exercised without the native
// google_mobile_ads plugin — giving AdMob the same behavioural coverage as
// AppLovin (a partner may run either provider).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/gma_bridge.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart'
    show TagForChildDirectedTreatment, TagForUnderAgeOfConsent;
import 'dart:async';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_test/flutter_test.dart';

class FakeGmaFullscreenAd implements GmaFullscreenAd {
  GmaShowCallbacks? shown;
  int showCount = 0;
  int disposeCount = 0;

  /// MJ25 + M5 (second independent review) — the fake had no way to make
  /// `show()` throw, so the four `show* THREW` catch branches were untestable
  /// and shipped unverified. The throw is reachable in production:
  /// `gma_bridge` awaits `setServerSideOptions()` before showing, and a
  /// platform call can fail.
  bool throwOnShow = false;

  /// MJ24 — a `show()` that never completes. Before the fix the watchdog was
  /// armed AFTER `await ad.show(...)`, so this exact case — the hang the
  /// watchdog exists for — left it never armed at all.
  bool hangOnShow = false;

  // Captured SSV params from the most recent show() call.
  String? lastSsvCustomData;
  String? lastSsvUserId;

  @override
  Future<void> show(
    GmaShowCallbacks callbacks, {
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    if (throwOnShow) throw PlatformException(code: 'show-failed');
    if (hangOnShow) {
      shown = callbacks;
      showCount++;
      // Never completes, and never invokes a callback.
      await Completer<void>().future;
      return;
    }
    shown = callbacks;
    showCount++;
    lastSsvCustomData = ssvCustomData;
    lastSsvUserId = ssvUserId;
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {}

  @override
  List<String>? get mediationWaterfall => null;

  @override
  void dispose() => disposeCount++;
}

class FakeGmaBridge implements GmaBridge {
  bool failNextLoad = false;

  // Captured from the most recent updateRequestConfiguration() call.
  List<String>? capturedTestDeviceIds;

  FakeGmaFullscreenAd? lastAppOpen;
  FakeGmaFullscreenAd? lastInter;
  FakeGmaFullscreenAd? lastRewarded;
  FakeGmaFullscreenAd? lastRewardedInterstitial;

  // Captured non-personalized (npa) flag from the most recent load per slot.
  bool? npaAppOpen;
  bool? npaInter;
  bool? npaRewarded;

  // Captured restricted-data-processing (CCPA RDP) flag from the most recent
  // load per slot.
  bool? rdpAppOpen;
  bool? rdpInter;
  bool? rdpRewarded;

  // m8 — RequestConfiguration replaces rather than merges, so these must
  // travel with every updateRequestConfiguration call or the tags get wiped.
  int? capturedCoppaTag;
  int? capturedTfuaTag;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updateRequestConfiguration(
    List<String> ids, {
    int? tagForChildDirectedTreatment,
    int? tagForUnderAgeOfConsent,
  }) async {
    capturedTestDeviceIds = ids;
    capturedCoppaTag = tagForChildDirectedTreatment;
    capturedTfuaTag = tagForUnderAgeOfConsent;
  }

  @override
  Future<void> loadAppOpen(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaAppOpen = nonPersonalizedAds;
    rdpAppOpen = restrictedDataProcessing;
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastAppOpen = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadInterstitial(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaInter = nonPersonalizedAds;
    rdpInter = restrictedDataProcessing;
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastInter = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadRewarded(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    npaRewarded = nonPersonalizedAds;
    rdpRewarded = restrictedDataProcessing;
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastRewarded = ad;
    onLoaded(ad);
  }

  @override
  Future<void> loadRewardedInterstitial(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    if (failNextLoad) return onFailed(3, 'no fill');
    final ad = FakeGmaFullscreenAd();
    lastRewardedInterstitial = ad;
    onLoaded(ad);
  }
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeGmaBridge bridge;
  late AdMobAdapter adapter;

  setUp(() async {
    bridge = FakeGmaBridge();
    adapter = AdMobAdapter(bridge: bridge);
    expect(await adapter.initialize(_config), isTrue);
  });

  group('QA test-device hashes (always merged into RequestConfiguration)',
      () {
    test('no custom testDeviceIds configured → the 7 known QA hashes still '
        'go to AdMob', () {
      expect(bridge.capturedTestDeviceIds, isNotNull);
      for (final hash in kQaTestDeviceHashes) {
        expect(bridge.capturedTestDeviceIds, contains(hash));
      }
    });

    test('a host app\'s own custom testDeviceIds are merged with, not '
        'replaced by, the QA hashes', () async {
      final customBridge = FakeGmaBridge();
      final customAdapter = AdMobAdapter(bridge: customBridge);
      const customConfig = AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'ao',
          rewardedId: 'r',
          testDeviceIds: ['host-apps-own-test-device'],
        ),
      );

      expect(await customAdapter.initialize(customConfig), isTrue);

      expect(customBridge.capturedTestDeviceIds,
          contains('host-apps-own-test-device'),
          reason: 'the merge must not drop what the host app configured');
      for (final hash in kQaTestDeviceHashes) {
        expect(customBridge.capturedTestDeviceIds, contains(hash),
            reason: 'the merge must not drop the always-on QA fleet either');
      }
    });
  });

  // m8 (round 5) + M5 (independent review) — the fake captured these tags so
  // this could be asserted; nothing read them until now. RequestConfiguration
  // REPLACES rather than merges, so passing only test-device ids wiped whatever
  // COPPA/TFUA state had just been set.
  group('m8: RequestConfiguration carries the COPPA/TFUA tags', () {
    test('child-directed init sends tagForChildDirectedTreatment=yes',
        () async {
      final b = FakeGmaBridge();
      final a = AdMobAdapter(bridge: b);
      expect(
        await a.initialize(_config,
            consent: const AdConsent(isAgeRestrictedUser: true)),
        isTrue,
      );
      expect(b.capturedCoppaTag, TagForChildDirectedTreatment.yes);
      addTearDown(() => a.dispose());
    });

    test('umpTagForUnderAgeOfConsent:true sends TFUA=yes', () async {
      final b = FakeGmaBridge();
      final a = AdMobAdapter(bridge: b);
      expect(
        await a.initialize(const AdConfig(
          provider: AdProvider.admob,
          umpTagForUnderAgeOfConsent: true,
          admob: AdMobConfig(
              bannerId: 'b', interstitialId: 'i', appOpenId: 'ao',
              rewardedId: 'r'),
        )),
        isTrue,
      );
      expect(b.capturedTfuaTag, TagForUnderAgeOfConsent.yes);
      addTearDown(() => a.dispose());
    });

    test('no declaration → TFUA stays unspecified, never a bare "no"',
        () async {
      expect(bridge.capturedTfuaTag, TagForUnderAgeOfConsent.unspecified,
          reason: 'claiming a user is NOT under the age of consent is a '
              'statement we have no basis for');
    });
  });

  group('Interstitial dismiss resolution', () {
    test('dismiss → onDone(true) and the ad is disposed', () async {
      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isReady, isTrue);

      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      bridge.lastInter!.shown!.onDismissed!();

      expect(shown, isTrue);
      expect(bridge.lastInter!.disposeCount, 1);
    });

    test('fail-to-show → onDone(false)', () async {
      await adapter.loadInterstitial();
      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);
      bridge.lastInter!.shown!.onFailedToShow!('boom');
      expect(shown, isFalse);
    });
  });

  // T11 — single-use guard: a fullscreen ad can never be shown twice, and the
  // slot state machine (isReady + atomic beginShow + null-on-dismiss) blocks a
  // second show from ever touching a shown/disposed ad object.
  group('single-use / double-show guard', () {
    test('second showInterstitial while showing is rejected (shown once)',
        () async {
      await adapter.loadInterstitial();
      final ad = bridge.lastInter!;

      bool? first;
      await adapter.showInterstitial(onDone: (s) => first = s);
      expect(ad.showCount, 1);

      // Second call BEFORE dismiss — slot is `showing`, must be rejected and
      // must NOT invoke show() again or dispose the live ad.
      bool? second;
      await adapter.showInterstitial(onDone: (s) => second = s);
      expect(second, isFalse, reason: 'blocked by slot state');
      expect(ad.showCount, 1, reason: 'never shown twice');
      expect(ad.disposeCount, 0, reason: 'live ad not disposed mid-show');

      // Dismiss resolves the first call and disposes exactly once.
      ad.shown!.onDismissed!();
      expect(first, isTrue);
      expect(ad.disposeCount, 1);
    });

    test(
        'showInterstitial after dismiss is not-ready (no reuse of disposed ad)',
        () async {
      await adapter.loadInterstitial();
      final ad = bridge.lastInter!;
      await adapter.showInterstitial(onDone: (_) {});
      ad.shown!.onDismissed!(); // ad nulled + disposed, slot idle

      bool? again;
      await adapter.showInterstitial(onDone: (s) => again = s);
      expect(again, isFalse, reason: 'no ad loaded → not ready');
      expect(ad.showCount, 1, reason: 'disposed ad never shown again');
      expect(ad.disposeCount, 1, reason: 'no double dispose');
    });
  });

  group('Rewarded earned vs dismissed', () {
    test('earning then dismiss → earned=true exactly once', () async {
      await adapter.loadRewarded();
      var calls = 0;
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) {
        calls++;
        result = r;
      });

      bridge.lastRewarded!.shown!.onUserEarnedReward!(10, 'coins');
      bridge.lastRewarded!.shown!.onDismissed!(); // dismiss after earning

      expect(result, isNotNull);
      expect(result!.earned, isTrue);
      expect(result!.amount, 10);
      expect(calls, 1,
          reason: 'reward must fire once (earned wins over dismiss)');
    });

    // Found by on-device smoke test on 2026-08-25 (OPPO CPH1989, real AdMob
    // test ads): cycle 1 of rewarded_ad_test.dart passed and cycle 2 failed
    // with "rewarded ad must reload and finish loading before Cycle 2 show".
    // AdMob delivers `onUserEarnedReward` BEFORE `onAdDismissed`, and
    // AdManager's reload hangs off the reward callback — so it ran against the
    // still-cached ad and no-op'd, and the slot stayed empty for the whole
    // session. The AppLovin adapter never had this because it reloads inside
    // its own `onAdHiddenCallback`.
    test('earn-then-dismiss refills the slot for the next show', () async {
      await adapter.loadRewarded();
      final first = bridge.lastRewarded!;
      await adapter.showRewarded(onDone: (_) {});

      first.shown!.onUserEarnedReward!(10, 'coins');
      first.shown!.onDismissed!();
      await Future<void>.delayed(Duration.zero);

      expect(bridge.lastRewarded, isNot(same(first)),
          reason: 'the dismiss must request a fresh rewarded ad');
      expect(adapter.rewardedSlot.isReady, isTrue,
          reason: 'the refilled slot must be showable again');
    });

    test('a dismiss with the AdManager gate closed does NOT reload', () async {
      await adapter.loadRewarded();
      final first = bridge.lastRewarded!;
      await adapter.showRewarded(onDone: (_) {});
      // VIP / daily cap / consent-not-granted / offline all come through here.
      adapter.canReload = () => false;

      first.shown!.onUserEarnedReward!(10, 'coins');
      first.shown!.onDismissed!();
      await Future<void>.delayed(Duration.zero);

      expect(bridge.lastRewarded, same(first),
          reason: 'a closed gate must never be bypassed by the refill');
    });
    test('dismiss WITHOUT earning → skipped (no reward)', () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);

      bridge.lastRewarded!.shown!.onDismissed!(); // no reward fired

      expect(result, isNotNull);
      expect(result!.earned, isFalse);
    });

    // Round-23 audit, MAJOR — `shown` is the impression signal AdManager
    // charges the daily/hourly/placement caps on. It used to be hardcoded
    // `true` (the default), which made it worthless in both directions.
    test('a displayed-then-closed rewarded reports shown=true, earned=false',
        () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);

      bridge.lastRewarded!.shown!.onShowed!(); // the ad reached the screen
      bridge.lastRewarded!.shown!.onDismissed!(); // closed before the reward

      expect(result!.earned, isFalse);
      expect(result!.shown, isTrue,
          reason: 'the user saw an ad — it must consume cap budget');
    });

    test('a rewarded that never reached the screen reports shown=false',
        () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);

      // No onShowed: GMA failed to present it at all.
      bridge.lastRewarded!.shown!.onFailedToShow!('no fill on show');

      expect(result!.shown, isFalse);
    });
  });

  // T89 — Rewarded Interstitial (AdMob only). Mirrors the plain Rewarded
  // group above; the adapter implementation is a close copy of
  // loadRewarded/showRewarded, so the same earn/dismiss/fail behaviors must
  // hold for this ad type too.
  group('Rewarded Interstitial (T89)', () {
    test('load success → slot ready, bridge received the fake ad', () async {
      await adapter.loadRewardedInterstitial();

      expect(adapter.rewardedInterstitialSlot.isReady, isTrue);
      expect(bridge.lastRewardedInterstitial, isNotNull);
    });

    test('load failure → slot goes to cooldown, not stuck loading', () async {
      bridge.failNextLoad = true;
      await adapter.loadRewardedInterstitial();

      expect(adapter.rewardedInterstitialSlot.isLoading, isFalse);
      expect(adapter.rewardedInterstitialSlot.isReady, isFalse);
    });

    test('earning then dismiss → earned=true exactly once', () async {
      await adapter.loadRewardedInterstitial();
      var calls = 0;
      RewardResult? result;
      await adapter.showRewardedInterstitial(onDone: (r) {
        calls++;
        result = r;
      });

      bridge.lastRewardedInterstitial!.shown!.onUserEarnedReward!(5, 'gems');
      bridge.lastRewardedInterstitial!.shown!.onDismissed!();

      expect(result, isNotNull);
      expect(result!.earned, isTrue);
      expect(result!.amount, 5);
      expect(result!.label, 'gems');
      expect(calls, 1);
    });

    test('dismiss WITHOUT earning → skipped (no reward)', () async {
      await adapter.loadRewardedInterstitial();
      RewardResult? result;
      await adapter.showRewardedInterstitial(onDone: (r) => result = r);

      bridge.lastRewardedInterstitial!.shown!.onDismissed!();

      expect(result, isNotNull);
      expect(result!.earned, isFalse);
    });

    test('show without a loaded ad → skipped immediately, no throw',
        () async {
      RewardResult? result;
      await adapter.showRewardedInterstitial(onDone: (r) => result = r);

      expect(result, isNotNull);
      expect(result!.earned, isFalse);
    });
  });

  group('App Open dismiss resolution', () {
    test('dismiss → onDismiss(true) and ad disposed', () async {
      await adapter.loadAppOpen();
      expect(adapter.appOpenSlot.isReady, isTrue);

      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      bridge.lastAppOpen!.shown!.onDismissed!();

      expect(dismissed, isTrue);
      expect(bridge.lastAppOpen!.disposeCount, 1);
      addTearDown(() => adapter.dispose());
    });
  });

  // MJ15 (round 5 audit) + M5 (independent review). Drives the REAL
  // GmaShowCallbacks the adapter registered — an earlier version of this test
  // called a debug seam that re-implemented the two lines under test, so
  // deleting the fix from the real callbacks left it green.
  group('App Open late callback (MJ15)', () {
    test('a late duplicate callback must not clear a reloaded ad', () async {
      await adapter.loadAppOpen();
      final first = bridge.lastAppOpen!;

      await adapter.showAppOpen(onDismiss: (_) {});
      // Resolve this show normally: `_appOpenDismiss` is now null, which is the
      // state the hard-cap watchdog also leaves behind.
      first.shown!.onDismissed!();
      expect(first.disposeCount, 1);

      // AdManager reloads — a different ad object takes the field.
      await adapter.loadAppOpen();
      final second = bridge.lastAppOpen!;
      expect(identical(first, second), isFalse,
          reason: 'the fake bridge must hand out a fresh ad per load');
      expect(adapter.appOpenSlot.isReady, isTrue);

      // Now the FIRST ad's native callback fires again, late.
      first.shown!.onDismissed!();

      expect(adapter.appOpenSlot.isReady, isTrue,
          reason: 'the reloaded ad must still be showable');
      expect(second.disposeCount, 0,
          reason: 'the replacement must not be disposed by a stale callback');

      // The decisive check: the ad the adapter would actually show. Before the
      // fix `_appOpenAd` was nulled here while the slot stayed ready, so
      // showAppOpen() returned false against a null ad forever.
      bool? shownOk;
      await adapter.showAppOpen(onDismiss: (d) => shownOk = d);
      expect(second.showCount, 1,
          reason: 'THE regression: a stale callback cleared _appOpenAd, so this '
              'show found nothing and bailed');
      second.shown!.onDismissed!();
      expect(shownOk, isTrue);
      addTearDown(() => adapter.dispose());
    });
  });

  // MJ25 + M5 (second independent review). All four `show*` catch branches used
  // to drop the ad object without disposing it, leaking the native ad. The
  // local `ad` is the last reference at that point, so "forget" and "leak" are
  // the same thing.
  // MJ24 (round 5) + M5 (second independent review). `_armAppOpenWatchdog` used
  // to be called AFTER `await ad.show(...)`. If the platform call itself never
  // resolved — precisely the hang the watchdog exists to survive — it was never
  // armed, and on the resume path there is no other recovery timer, so
  // `_appOpenDismiss` stayed pending forever and App Open was dead for the
  // session.
  group('MJ24: the App Open watchdog is armed before show() can hang', () {
    test('a show() that never returns still leaves the watchdog armed',
        () async {
      await adapter.loadAppOpen();
      bridge.lastAppOpen!.hangOnShow = true;

      // Deliberately NOT awaited: the point is that show() never completes.
      unawaited(adapter.showAppOpen(onDismiss: (_) {}));
      await Future<void>.delayed(Duration.zero);

      expect(bridge.lastAppOpen!.showCount, 1,
          reason: 'the show call must have been made and then hung');
      expect(adapter.debugWatchdogArmed, isTrue,
          reason: 'armed BEFORE the await, so a hung platform call still has a '
              'way out. Armed after, this is the one case that gets none.');
      addTearDown(() => adapter.dispose());
    });
  });

  // M-4 (independent review) — `_armAppOpenWatchdog`'s hard-cap timer used to
  // read `_appOpenAd` fresh when it fired and compare that field to itself
  // (`_clearAppOpenIfSame(_appOpenAd)`), which is trivially always true, i.e.
  // no guard at all. No load/show path today can actually swap `_appOpenAd`
  // out from under a still-armed watchdog (see the method's own doc comment
  // for why), so `debugReplaceAppOpenAdUnsafe` pokes the field directly to
  // construct the scenario the identity check exists to guard — a regression
  // backstop against a future change that reintroduces that possibility.
  group('M-4: the hard-cap watchdog must not touch a swapped-in ad', () {
    test('fires against the ad it was armed for, not whatever _appOpenAd is '
        'when it goes off', () {
      fakeAsync((async) {
        adapter.loadAppOpen();
        async.flushMicrotasks();
        final original = bridge.lastAppOpen!;
        original.hangOnShow = true;

        bool? dismissed;
        unawaited(adapter.showAppOpen(onDismiss: (d) => dismissed = d));
        async.flushMicrotasks();
        expect(adapter.debugWatchdogArmed, isTrue);

        // Something else takes the field while this show's watchdog is still
        // the pending one — unreachable via any real path today, but exactly
        // what the identity check must survive if that ever changes.
        final swappedIn = FakeGmaFullscreenAd();
        adapter.debugReplaceAppOpenAdUnsafe(swappedIn);

        async.elapse(const Duration(seconds: 91));

        expect(dismissed, isFalse, reason: 'the hard cap must still fire');
        expect(swappedIn.disposeCount, 0,
            reason: 'M-4: the watchdog must never dispose an ad it was not '
                'armed for, no matter what _appOpenAd holds when it fires');
        expect(original.disposeCount, 1,
            reason: 'the ad actually abandoned must still be released');
      });
    });
  });

  group('MJ25: a show() that throws still disposes the ad', () {
    test('interstitial', () async {
      await adapter.loadInterstitial();
      final ad = bridge.lastInter!..throwOnShow = true;
      bool? done;
      await adapter.showInterstitial(onDone: (d) => done = d);
      expect(done, isFalse, reason: 'caller must be resolved, not left hanging');
      expect(ad.disposeCount, 1, reason: 'the native ad would otherwise leak');
      expect(adapter.interstitialSlot.isShowing, isFalse);
    });

    test('rewarded', () async {
      await adapter.loadRewarded();
      final ad = bridge.lastRewarded!..throwOnShow = true;
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);
      expect(result, RewardResult.skipped);
      expect(ad.disposeCount, 1);
    });

    test('app open', () async {
      await adapter.loadAppOpen();
      final ad = bridge.lastAppOpen!..throwOnShow = true;
      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);
      expect(dismissed, isFalse);
      expect(ad.disposeCount, 1);
      addTearDown(() => adapter.dispose());
    });

    test('rewarded interstitial', () async {
      await adapter.loadRewardedInterstitial();
      final ad = bridge.lastRewardedInterstitial!..throwOnShow = true;
      RewardResult? result;
      await adapter.showRewardedInterstitial(onDone: (r) => result = r);
      expect(result, RewardResult.skipped);
      expect(ad.disposeCount, 1);
    });
  });

  group('Load failure', () {
    test('a failed load drops the slot into cooldown', () async {
      bridge.failNextLoad = true;
      await adapter.loadInterstitial();
      expect(adapter.interstitialSlot.isReady, isFalse);
      expect(adapter.interstitialSlot.value, AdSlotState.cooldown);
    });
  });

  // T02 — every AdMob AdRequest must carry the non-personalized (npa) flag
  // derived from consent. Conservative default = non-personalized.
  group('Non-personalized (npa) consent propagation', () {
    test('conservative default: npa=true before any consent applied', () async {
      expect(adapter.debugNonPersonalizedAds, isTrue,
          reason: 'adapter must default to non-personalized');
      await adapter.loadInterstitial();
      expect(bridge.npaInter, isTrue);
    });

    test('consent granted → npa=false on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      expect(adapter.debugNonPersonalizedAds, isFalse);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.npaInter, isFalse);
      expect(bridge.npaRewarded, isFalse);
      expect(bridge.npaAppOpen, isFalse);
    });

    test('consent declined → npa=true on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: false));
      expect(adapter.debugNonPersonalizedAds, isTrue);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.npaInter, isTrue);
      expect(bridge.npaRewarded, isTrue);
      expect(bridge.npaAppOpen, isTrue);
    });

    test('accept then revoke → later loads flip back to npa=true', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      await adapter.loadInterstitial();
      expect(bridge.npaInter, isFalse);

      adapter.applyConsent(const AdConsent(hasUserConsent: false));
      await adapter.loadRewarded();
      expect(bridge.npaRewarded, isTrue);
    });

    test('age-restricted/doNotSell alone do not enable personalization',
        () async {
      // Only hasUserConsent controls npa; other flags are orthogonal.
      adapter.applyConsent(
          const AdConsent(isAgeRestrictedUser: true, doNotSell: true));
      expect(adapter.debugNonPersonalizedAds, isTrue);
    });

    test('dispose resets to conservative (npa=true)', () async {
      adapter.applyConsent(const AdConsent(hasUserConsent: true));
      expect(adapter.debugNonPersonalizedAds, isFalse);
      await adapter.dispose();
      expect(adapter.debugNonPersonalizedAds, isTrue,
          reason: 're-init before consent must stay non-personalized');
    });
  });

  // T05 — CCPA `doNotSell` must map to AdMob restricted-data-processing (RDP),
  // forwarded per-request via GmaBridge, and must stay independent of the
  // GDPR (npa) and COPPA (age-restricted) flags.
  group('Restricted-data-processing (RDP/CCPA) consent propagation', () {
    test('conservative default: rdp=false before any consent applied',
        () async {
      expect(adapter.debugRestrictedDataProcessing, isFalse,
          reason: 'adapter must default to unrestricted');
      await adapter.loadInterstitial();
      expect(bridge.rdpInter, isFalse);
    });

    test('doNotSell=true → rdp=true on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      expect(adapter.debugRestrictedDataProcessing, isTrue);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.rdpInter, isTrue);
      expect(bridge.rdpRewarded, isTrue);
      expect(bridge.rdpAppOpen, isTrue);
    });

    test('doNotSell=false → rdp=false on all fullscreen loads', () async {
      adapter.applyConsent(const AdConsent(doNotSell: false));
      expect(adapter.debugRestrictedDataProcessing, isFalse);

      await adapter.loadInterstitial();
      await adapter.loadRewarded();
      await adapter.loadAppOpen();
      addTearDown(() => adapter.dispose());

      expect(bridge.rdpInter, isFalse);
      expect(bridge.rdpRewarded, isFalse);
      expect(bridge.rdpAppOpen, isFalse);
    });

    test('opt-out then opt-in → later loads flip back to rdp=false', () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      await adapter.loadInterstitial();
      expect(bridge.rdpInter, isTrue);

      adapter.applyConsent(const AdConsent(doNotSell: false));
      await adapter.loadRewarded();
      expect(bridge.rdpRewarded, isFalse);
    });

    test('hasUserConsent/isAgeRestrictedUser alone do not trigger RDP',
        () async {
      // Only doNotSell controls rdp; other flags are orthogonal.
      adapter.applyConsent(
          const AdConsent(hasUserConsent: true, isAgeRestrictedUser: true));
      expect(adapter.debugRestrictedDataProcessing, isFalse);
    });

    test('doNotSell alone does not enable personalization (npa unaffected)',
        () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      expect(adapter.debugRestrictedDataProcessing, isTrue);
      expect(adapter.debugNonPersonalizedAds, isTrue,
          reason: 'doNotSell must not flip npa');
    });

    test('dispose resets to conservative (rdp=false)', () async {
      adapter.applyConsent(const AdConsent(doNotSell: true));
      expect(adapter.debugRestrictedDataProcessing, isTrue);
      await adapter.dispose();
      expect(adapter.debugRestrictedDataProcessing, isFalse,
          reason: 're-init before consent must stay unrestricted');
    });
  });
}
