// Adapter-level tests for AdMobAdapter — the layer that previously had no
// tests and where the recent fixes live. We can't drive the real GMA native
// classes (AppOpenAd.load / ad.show), but the two riskiest fixes expose
// testable seams:
//   • `isAdFresh` — the interstitial/rewarded/app-open expiry decision.
//   • App Open show watchdog — a real Timer whose hard cap is overridable via
//     `debugSimulateAppOpenShowAndArmWatchdog`, so the "no dismiss callback →
//     force dismiss(false)" path can be exercised end-to-end without GMA.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/google_mobile_ads.dart';
// AdMessageCodec isn't exported from the public API — same workaround as
// gma_bridge_test.dart, needed to match the plugin's own channel codec.
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;

import 'admob_behavioral_test.dart' show FakeGmaBridge;

const _lateFailureConfig = AdConfig(
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

  group('AdMobAdapter.isAdFresh (expiry decision)', () {
    final base = DateTime(2026, 6, 14, 12, 0, 0);

    test('never-loaded (null) is not fresh', () {
      expect(AdMobAdapter.isAdFresh(null, 1, now: base), isFalse);
    });

    test('loaded within the window is fresh', () {
      final loadedAt = base.subtract(const Duration(minutes: 30));
      expect(AdMobAdapter.isAdFresh(loadedAt, 1, now: base), isTrue);
    });

    test('loaded beyond the window is stale', () {
      final loadedAt = base.subtract(const Duration(hours: 1, minutes: 1));
      expect(AdMobAdapter.isAdFresh(loadedAt, 1, now: base), isFalse);
    });

    test('4h app-open window respected', () {
      expect(
        AdMobAdapter.isAdFresh(base.subtract(const Duration(hours: 3)), 4,
            now: base),
        isTrue,
      );
      expect(
        AdMobAdapter.isAdFresh(base.subtract(const Duration(hours: 5)), 4,
            now: base),
        isFalse,
      );
    });

    // m16 (audit_claude.md MINOR) — `lastLoadedAt` is a wall-clock stamp, so a
    // backwards clock change puts it in the future: `difference()` goes
    // negative and `< maxHours` stayed true forever, leaving the ad "fresh"
    // for the rest of the session.
    test('m16 — a loadedAt in the future (clock moved back) is NOT fresh', () {
      expect(
        AdMobAdapter.isAdFresh(base.add(const Duration(hours: 2)), 1,
            now: base),
        isFalse,
        reason: 'negative age means the real age is unknowable — reload',
      );
      expect(
        AdMobAdapter.isAdFresh(base.add(const Duration(days: 30)), 4,
            now: base),
        isFalse,
      );
    });
  });

  // m16, behaviourally: the clock-jump case needs no injected `now` — stamping
  // lastLoadedAt in the future is exactly the state a backwards clock change
  // leaves the slot in.
  group('m16 — clock moved backwards does not make a stale ad look fresh', () {
    test('showAppOpen discards a slot whose loadedAt is in the future',
        () async {
      final adapter = AdMobAdapter();
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();
      adapter.appOpenSlot.lastLoadedAt =
          DateTime.now().add(const Duration(hours: 2));

      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);

      expect(dismissed, isFalse, reason: 'must not be shown');
      expect(adapter.appOpenSlot.lastLoadedAt, isNull,
          reason: 'only the stale-discard branch clears lastLoadedAt — with a '
              'negative age the freshness check waved the ad through instead');
    });

    test('showInterstitial discards a slot whose loadedAt is in the future',
        () async {
      final adapter = AdMobAdapter();
      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();
      adapter.interstitialSlot.lastLoadedAt =
          DateTime.now().add(const Duration(hours: 2));

      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);

      expect(shown, isFalse);
      expect(adapter.interstitialSlot.lastLoadedAt, isNull);
    });
  });

  group('AdMobAdapter App Open watchdog', () {
    test('force-dismisses with false after the hard cap when no callback fires',
        () async {
      final adapter = AdMobAdapter();
      bool? dismissed;
      adapter.debugSimulateAppOpenShowAndArmWatchdog(
        (d) => dismissed = d,
        const Duration(milliseconds: 40),
      );
      expect(adapter.debugWatchdogArmed, isTrue);
      expect(adapter.appOpenSlot.isShowing, isTrue);

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(dismissed, isFalse, reason: 'caller must be force-dismissed');
      expect(adapter.appOpenSlot.value, AdSlotState.cooldown,
          reason: 'markShowFailed → cooldown');
      expect(adapter.debugWatchdogArmed, isFalse, reason: 'timer self-cleared');
    });

    // Round-23 audit, MAJOR — the hard cap on an ad we KNOW reached the screen
    // only proves the dismiss callback was lost (a click-out to the store, or
    // an ad left up past 90s). Reporting that as a show FAILURE charged the
    // failure backoff — App Open got progressively rarer for exactly the users
    // who engage with ads — and told AdManager no ad was ever shown, so the
    // impression counted against no cap and the 30s inter-fullscreen throttle
    // stayed unarmed while the ad could still be on screen.
    test('a CONFIRMED display resolves as dismissed(true), not a failure',
        () async {
      final adapter = AdMobAdapter();
      bool? dismissed;
      adapter.debugSimulateAppOpenShowAndArmWatchdog(
        (d) => dismissed = d,
        const Duration(milliseconds: 40),
      );
      adapter.appOpenSlot.markDisplayed(); // GMA confirmed it is on screen

      await Future<void>.delayed(const Duration(milliseconds: 120));

      expect(dismissed, isTrue,
          reason: 'the ad really was displayed — AdManager must count it');
      expect(adapter.appOpenSlot.value, AdSlotState.idle,
          reason: 'markDismissed → idle, no failure backoff charged');
    });

    test('dispose cancels the watchdog — it never fires twice', () async {
      final adapter = AdMobAdapter();
      var calls = 0;
      adapter.debugSimulateAppOpenShowAndArmWatchdog(
        (_) => calls++,
        const Duration(milliseconds: 40),
      );

      // dispose flushes the pending dismiss callback once and cancels the timer.
      await adapter.dispose();
      expect(calls, 1,
          reason: 'dispose flushes the pending callback exactly once');
      expect(adapter.debugWatchdogArmed, isFalse);

      // Past the original cap — the cancelled timer must NOT fire again.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(calls, 1, reason: 'cancelled watchdog must not double-fire');
    });
  });

  // 2026-08-19 audit (Finding 3): the 4h/1h isAdFresh expiry was only ever
  // consulted when *loading* (reuse-if-fresh); showAppOpen/showInterstitial/
  // showRewarded/showRewardedInterstitial never checked it, so an ad that
  // sat `ready` past its expiry (e.g. app backgrounded for hours, then
  // resumed) could still be shown stale — violating Google's App Open
  // "discard and reload after ~4h, never show stale" policy.
  group('AdMobAdapter show*() reject a stale-but-ready slot (2026-08-19 audit)',
      () {
    void markReadyAt(AdSlot slot, DateTime loadedAt) {
      slot.beginLoad();
      slot.markReady();
      slot.lastLoadedAt = loadedAt;
    }

    test('showAppOpen discards a stale ready ad instead of showing it',
        () async {
      final adapter = AdMobAdapter();
      markReadyAt(
          adapter.appOpenSlot, DateTime.now().subtract(const Duration(hours: 5)));

      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);

      expect(dismissed, isFalse, reason: 'a stale ad must never be shown');
      expect(adapter.appOpenSlot.value, AdSlotState.idle,
          reason: 'a stale ready slot must be discarded (idle → immediately '
              'eligible for reload), not left ready as if nothing happened. '
              'm15 — it used to land in cooldown, which is a *failure* state '
              'and blocked the very refill the discard needs');
    });

    test('showAppOpen still shows a genuinely fresh ready ad', () async {
      final adapter = AdMobAdapter();
      markReadyAt(adapter.appOpenSlot,
          DateTime.now().subtract(const Duration(minutes: 5)));

      bool? dismissed;
      await adapter.showAppOpen(onDismiss: (d) => dismissed = d);

      // No real GMA ad object exists in this unit-test environment, so the
      // pre-existing `ad == null` guard still rejects the show — the point
      // of this test is only that it's rejected for THAT reason, not
      // discarded as stale (slot must stay `ready`, not flip to cooldown).
      expect(dismissed, isFalse);
      expect(adapter.appOpenSlot.value, AdSlotState.ready,
          reason: 'a fresh ready slot must not be discarded by the '
              'staleness check');
    });

    test('showInterstitial discards a stale ready ad instead of showing it',
        () async {
      final adapter = AdMobAdapter();
      markReadyAt(adapter.interstitialSlot,
          DateTime.now().subtract(const Duration(hours: 2)));

      bool? shown;
      await adapter.showInterstitial(onDone: (s) => shown = s);

      expect(shown, isFalse);
      expect(adapter.interstitialSlot.value, AdSlotState.idle);
    });

    test('showRewarded discards a stale ready ad instead of showing it',
        () async {
      final adapter = AdMobAdapter();
      markReadyAt(adapter.rewardedSlot,
          DateTime.now().subtract(const Duration(hours: 2)));

      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);

      expect(result, RewardResult.skipped);
      expect(adapter.rewardedSlot.value, AdSlotState.idle);
    });

    test(
        'showRewardedInterstitial discards a stale ready ad instead of '
        'showing it', () async {
      final adapter = AdMobAdapter();
      markReadyAt(adapter.rewardedInterstitialSlot,
          DateTime.now().subtract(const Duration(hours: 2)));

      RewardResult? result;
      await adapter.showRewardedInterstitial(onDone: (r) => result = r);

      expect(result, RewardResult.skipped);
      expect(adapter.rewardedInterstitialSlot.value, AdSlotState.idle);
    });

    // m15 (audit_claude.md MINOR) — the discard above recorded the expiry as a
    // load *failure* (markFailed): consecutiveFailures++ and lastErrorAt=now.
    // AdManager fires the refill from the very onDone/onDismiss callback this
    // discard invokes, so `beginLoad()` then hit a 15s+ backoff window the
    // discard itself had just created and the slot stayed empty until the
    // periodic retry timer.
    test('m15 — a stale discard does not poison the reload backoff', () async {
      final stale = DateTime.now().subtract(const Duration(hours: 5));

      final appOpen = AdMobAdapter();
      markReadyAt(appOpen.appOpenSlot, stale);
      await appOpen.showAppOpen(onDismiss: (_) {});
      expect(appOpen.appOpenSlot.consecutiveFailures, 0,
          reason: 'appOpen: an expiry is not a load failure');
      expect(appOpen.appOpenSlot.lastErrorAt, isNull);
      expect(appOpen.appOpenSlot.beginLoad(), isTrue,
          reason: 'appOpen: the refill right after the discard must be allowed');

      final inter = AdMobAdapter();
      markReadyAt(inter.interstitialSlot, stale);
      await inter.showInterstitial(onDone: (_) {});
      expect(inter.interstitialSlot.consecutiveFailures, 0);
      expect(inter.interstitialSlot.beginLoad(), isTrue,
          reason: 'interstitial: refill after discard must be allowed');

      final rewarded = AdMobAdapter();
      markReadyAt(rewarded.rewardedSlot, stale);
      await rewarded.showRewarded(onDone: (_) {});
      expect(rewarded.rewardedSlot.consecutiveFailures, 0);
      expect(rewarded.rewardedSlot.beginLoad(), isTrue,
          reason: 'rewarded: refill after discard must be allowed');

      final ri = AdMobAdapter();
      markReadyAt(ri.rewardedInterstitialSlot, stale);
      await ri.showRewardedInterstitial(onDone: (_) {});
      expect(ri.rewardedInterstitialSlot.consecutiveFailures, 0);
      expect(ri.rewardedInterstitialSlot.beginLoad(), isTrue,
          reason: 'rewardedInterstitial: refill after discard must be allowed');
    });
  });

  group('AdMobAdapter.dispose() releases ValueNotifiers', () {
    test('slot and banner notifiers are disposed, not just reset', () async {
      final adapter = AdMobAdapter();
      await adapter.dispose();

      expect(() => adapter.appOpenSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.interstitialSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.rewardedSlot.state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.bannerSlot('k').state.addListener(() {}),
          throwsFlutterError);
      expect(
          () => adapter.banner('k').isLoaded.addListener(() {}), throwsFlutterError);
      expect(
          () => adapter.mrecSlot('k').state.addListener(() {}), throwsFlutterError);
      expect(
          () => adapter.mrec('k').isLoaded.addListener(() {}), throwsFlutterError);
      expect(() => adapter.nativeSlot('k').state.addListener(() {}),
          throwsFlutterError);
      expect(() => adapter.native('k').isLoaded.addListener(() {}),
          throwsFlutterError);
    });

    // m24 (audit_claude.md MINOR) — dispose()'s key loop only walked the SLOT
    // maps, but banner(key)/mrec(key)/native(key) create a BannerListenables
    // bundle independently of bannerSlot(key). A key that was only ever asked
    // for its listenables had its five ValueNotifiers left alive for good.
    // The bundles must be resolved BEFORE dispose — afterwards every getter
    // hands back the shared pre-disposed singleton, which hides the leak (that
    // is exactly why the test above passes either way).
    test('m24 — listenables created without a slot are disposed too', () async {
      final adapter = AdMobAdapter();
      final banner = adapter.banner('lonely-banner');
      final mrec = adapter.mrec('lonely-mrec');
      final native = adapter.native('lonely-native');

      await adapter.dispose();

      expect(() => banner.isLoaded.addListener(() {}), throwsFlutterError,
          reason: 'banner listenables with no slot must still be disposed');
      expect(() => mrec.isLoaded.addListener(() {}), throwsFlutterError,
          reason: 'mrec listenables with no slot must still be disposed');
      expect(() => native.isLoaded.addListener(() {}), throwsFlutterError,
          reason: 'native listenables with no slot must still be disposed');
    });
  });

  group('AdMobAdapter banner slot', () {
    // T65 (phase 2) — same guarantee as native (phase 1): two different
    // BannerAdWidget keys must not share AdSlot/BannerListenables state.
    test('two different keys get independent AdSlot/BannerListenables', () {
      final adapter = AdMobAdapter();
      adapter.bannerSlot('a').beginLoad();
      adapter.bannerSlot('a').markReady();
      adapter.banner('a').isLoaded.value = true;

      expect(adapter.bannerSlot('b').value, AdSlotState.idle,
          reason: 'key "b" must start idle, unaffected by key "a" loading');
      expect(adapter.banner('b').isLoaded.value, isFalse,
          reason: 'key "b" must not see key "a" isLoaded=true');
    });

    test('disposeBannerInstance releases that key without affecting others',
        () {
      final adapter = AdMobAdapter();
      adapter.bannerSlot('a').beginLoad();
      adapter.bannerSlot('b').beginLoad();

      adapter.disposeBannerInstance('a');

      expect(adapter.bannerSlots.length, 1,
          reason: 'only key "b" remains tracked after disposing "a"');
      expect(adapter.bannerSlot('b').isLoading, isTrue,
          reason: 'disposing key "a" must not touch key "b"');
    });
  });

  group('AdMobAdapter mrec slot', () {
    // T65 (phase 3) — same guarantee as banner/native: two different keys
    // must not share AdSlot/BannerListenables state.
    test('two different keys get independent AdSlot/BannerListenables', () {
      final adapter = AdMobAdapter();
      adapter.mrecSlot('a').beginLoad();
      adapter.mrecSlot('a').markReady();
      adapter.mrec('a').isLoaded.value = true;

      expect(adapter.mrecSlot('b').value, AdSlotState.idle,
          reason: 'key "b" must start idle, unaffected by key "a" loading');
      expect(adapter.mrec('b').isLoaded.value, isFalse,
          reason: 'key "b" must not see key "a" isLoaded=true');
    });

    test('disposeMrecInstance releases that key without affecting others', () {
      final adapter = AdMobAdapter();
      adapter.mrecSlot('a').beginLoad();
      adapter.mrecSlot('b').beginLoad();

      adapter.disposeMrecInstance('a');

      expect(adapter.mrecSlots.length, 1,
          reason: 'only key "b" remains tracked after disposing "a"');
      expect(adapter.mrecSlot('b').isLoading, isTrue,
          reason: 'disposing key "a" must not touch key "b"');
    });
  });

  group('AdMobAdapter native slot', () {
    test('beginLoad/markReady/markFailed drive nativeSlot state', () {
      final adapter = AdMobAdapter();
      expect(adapter.nativeSlot('k').beginLoad(), isTrue);
      expect(adapter.nativeSlot('k').isLoading, isTrue);

      adapter.nativeSlot('k').markReady();
      expect(adapter.nativeSlot('k').value, AdSlotState.ready);

      adapter.nativeSlot('k').reset();
      expect(adapter.nativeSlot('k').beginLoad(), isTrue);
      adapter.nativeSlot('k').markFailed();
      expect(adapter.nativeSlot('k').value, AdSlotState.cooldown);
    });

    // T65 (phase 1) — the whole point of the keyed refactor: two different
    // keys must NOT share state.
    test('two different keys get independent AdSlot/BannerListenables', () {
      final adapter = AdMobAdapter();
      adapter.nativeSlot('a').beginLoad();
      adapter.nativeSlot('a').markReady();
      adapter.native('a').isLoaded.value = true;

      expect(adapter.nativeSlot('b').value, AdSlotState.idle,
          reason: 'key "b" must start idle, unaffected by key "a" loading');
      expect(adapter.native('b').isLoaded.value, isFalse,
          reason: 'key "b" must not see key "a" isLoaded=true');
    });
  });

  // Regression for the "visible stuck false" bug: onAppPaused() blanks
  // `visible` for every key with a live listener; onAppResumed()'s
  // error-reload branch never set it back (only its "ad already alive"
  // branch did) — a resume-triggered reload that succeeded stayed hidden
  // behind an empty placeholder. Fix: onAdLoaded sets `visible.value = true`
  // itself. Drives the REAL BannerAdListener created by loadMrecIfNeeded
  // (via debugMrecListenerFor) — not a re-implemented copy — so reverting the
  // production fix fails this test.
  group('AdMobAdapter mrec visible (T-visible regression, 2026-08-22 audit)',
      () {
    const config = AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'b',
        interstitialId: 'i',
        appOpenId: 'ao',
        mrecId: 'm',
      ),
    );
    final channel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads',
      StandardMethodCodec(AdMessageCodec()),
    );
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

    setUp(() {
      // BannerAd.load() fires a real (unawaited) platform call — MREC has no
      // adaptive-size lookup, so this is the only channel traffic to stub.
      messenger.setMockMethodCallHandler(channel, (call) async => null);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(channel, null);
    });

    test('onAdLoaded sets visible=true after a resume-triggered reload',
        () async {
      final adapter = AdMobAdapter(bridge: FakeGmaBridge());
      expect(await adapter.initialize(config), isTrue);
      addTearDown(adapter.dispose);

      // Simulate the state a paused-then-errored MREC is left in.
      adapter.mrec('k').visible.value = false;

      await adapter.loadMrecIfNeeded('k', 0);
      final listener = adapter.debugMrecListenerFor('k');
      expect(listener, isNotNull,
          reason: 'loadMrecIfNeeded must have created the real BannerAd');

      final dummyAd = BannerAd(
        adUnitId: 'm',
        size: AdSize.mediumRectangle,
        request: const AdRequest(),
        listener: const BannerAdListener(),
      );
      listener!.onAdLoaded!(dummyAd);

      expect(adapter.mrec('k').visible.value, isTrue,
          reason: 'a successful load must make the MREC visible again');
    });
  });

  // Round-27 audit (3 independent reviewers, same finding) — onLoaded checks
  // _discardIfDisposed before mutating slot state / emitting; onFailed had
  // no equivalent for any of the 4 fullscreen types. A failure delivered for
  // a request still in flight when dispose() ran would still mutate the slot
  // and emit through eventSink on an adapter nobody owns any more.
  group('AdMobAdapter — late onFailed after dispose() is discarded', () {
    late FakeGmaBridge bridge;
    late AdMobAdapter adapter;
    late List<AdEvent> events;

    setUp(() async {
      bridge = FakeGmaBridge()
        ..failNextLoad = true
        ..deferNextFailure = true;
      adapter = AdMobAdapter(bridge: bridge);
      expect(await adapter.initialize(_lateFailureConfig), isTrue);
      events = <AdEvent>[];
      adapter.eventSink = events.add;
    });

    test('appOpen', () async {
      await adapter.loadAppOpen();
      final pending = bridge.pendingAppOpenOnFailed;
      expect(pending, isNotNull);

      await adapter.dispose();
      events.clear(); // dispose() itself may emit; only care about after
      expect(() => pending!(3, 'no fill'), returnsNormally);
      expect(events, isEmpty,
          reason: 'a late onFailed after dispose() must not emit');
    });

    test('interstitial', () async {
      await adapter.loadInterstitial();
      final pending = bridge.pendingInterOnFailed;
      expect(pending, isNotNull);

      await adapter.dispose();
      events.clear();
      expect(() => pending!(3, 'no fill'), returnsNormally);
      expect(events, isEmpty,
          reason: 'a late onFailed after dispose() must not emit');
    });

    test('rewarded', () async {
      await adapter.loadRewarded();
      final pending = bridge.pendingRewardedOnFailed;
      expect(pending, isNotNull);

      await adapter.dispose();
      events.clear();
      expect(() => pending!(3, 'no fill'), returnsNormally);
      expect(events, isEmpty,
          reason: 'a late onFailed after dispose() must not emit');
    });

    test('rewardedInterstitial', () async {
      await adapter.loadRewardedInterstitial();
      final pending = bridge.pendingRewardedInterstitialOnFailed;
      expect(pending, isNotNull);

      await adapter.dispose();
      events.clear();
      expect(() => pending!(3, 'no fill'), returnsNormally);
      expect(events, isEmpty,
          reason: 'a late onFailed after dispose() must not emit');
    });
  });
}
