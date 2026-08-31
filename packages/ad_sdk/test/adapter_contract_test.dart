// T116 — reusable contract-test suite run against BOTH AdMobAdapter and
// AppLovinAdapter through their existing per-provider fakes
// (FakeGmaBridge / FakeAppLovinBridge), asserting the SAME
// provider-agnostic invariants that AdProviderAdapter promises callers of
// AdManager. Historically, a guard/callback/dispose gap in one adapter but
// not the other only surfaced via an independent audit round (see T104/T105)
// rather than a test catching it directly — this file is the safety net so
// the next such gap fails a test instead. Test-only: no production code
// changed by this ticket.
//
// Scenario matrix (ticket-mandated): consent epoch, late callbacks after
// dispose, N independent widget-keyed instances, watchdog, revenue, dispose,
// show mutex.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;
import 'applovin_adapter_test.dart' show FakeAppLovinBridge;

MaxAd _fakeMaxAd({double revenue = 0.0}) => MaxAd(
    'unit',
    'INTER',
    null,
    'net',
    '',
    revenue,
    'exact',
    'cid',
    'dsp',
    '',
    0,
    MaxAdWaterfallInfo('', '', const [], 0),
    null,
    null);

/// Provider-specific glue the shared scenario matrix below drives through —
/// each method maps one adapter-agnostic action onto that provider's own
/// fake wiring. The assertions live in the shared suite, not here.
abstract class _Driver {
  String get name;
  Future<AdProviderAdapter> build();
  Future<void> loadInterstitialToReady(AdProviderAdapter a);
  int interstitialShowCallCount();
  void fireLateInterstitialDismiss();
  void fireInterstitialRevenue();
  void armAppOpenWatchdogAndShow(AdProviderAdapter a, void Function(bool) onDismiss);
}

class _AdMobDriver implements _Driver {
  late FakeGmaBridge bridge;

  @override
  String get name => 'AdMob';

  @override
  Future<AdProviderAdapter> build() async {
    bridge = FakeGmaBridge();
    final a = AdMobAdapter(bridge: bridge);
    expect(await a.initialize(const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
          bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
    )), isTrue);
    return a;
  }

  @override
  Future<void> loadInterstitialToReady(AdProviderAdapter a) async {
    await (a as AdMobAdapter).loadInterstitial();
    // FakeGmaBridge resolves onLoaded synchronously.
    expect(a.interstitialSlot.isReady, isTrue);
  }

  @override
  int interstitialShowCallCount() => bridge.lastInter!.showCount;

  @override
  void fireLateInterstitialDismiss() => bridge.lastInter!.shown!.onDismissed!();

  @override
  void fireInterstitialRevenue() =>
      bridge.lastInter!.paidCallback?.call(1000000, 'USD', 'exact');

  @override
  void armAppOpenWatchdogAndShow(
          AdProviderAdapter a, void Function(bool) onDismiss) =>
      (a as AdMobAdapter)
          .debugSimulateAppOpenShowAndArmWatchdog(onDismiss, const Duration(seconds: 90));
}

class _AppLovinDriver implements _Driver {
  late FakeAppLovinBridge bridge;
  InterstitialListener? _capturedListener;

  @override
  String get name => 'AppLovin';

  @override
  Future<AdProviderAdapter> build() async {
    bridge = FakeAppLovinBridge();
    // paused: forces the hard-cap branch of the App Open watchdog rather
    // than the platform/lifecycle-dependent fast path — matches AdMob's
    // driver, which has no lifecycle branching at all.
    final a =
        AppLovinAdapter(bridge: bridge, lifecycleStateResolver: () => AppLifecycleState.paused);
    expect(await a.initialize(const AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(
          sdkKey: 'sdk',
          bannerId: 'banner-id',
          interstitialId: 'inter-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id'),
    )), isTrue);
    return a;
  }

  @override
  Future<void> loadInterstitialToReady(AdProviderAdapter a) async {
    await (a as AppLovinAdapter).loadInterstitial();
    _capturedListener = bridge.inter;
    bridge.inter!.onAdLoadedCallback(_fakeMaxAd());
    expect(a.interstitialSlot.isReady, isTrue);
  }

  @override
  int interstitialShowCallCount() => bridge.showInterCalls.length;

  @override
  void fireLateInterstitialDismiss() =>
      _capturedListener!.onAdHiddenCallback(_fakeMaxAd());

  @override
  void fireInterstitialRevenue() =>
      bridge.inter!.onAdRevenuePaidCallback?.call(_fakeMaxAd(revenue: 1.5));

  @override
  void armAppOpenWatchdogAndShow(
          AdProviderAdapter a, void Function(bool) onDismiss) =>
      (a as AppLovinAdapter).debugStartAppOpenWatchdog(onDismiss);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  void runContractSuite(_Driver Function() makeDriver) {
    late _Driver driver;
    late AdProviderAdapter adapter;

    group(makeDriver().name, () {
      setUp(() async {
        driver = makeDriver();
        adapter = await driver.build();
      });

      tearDown(() async {
        if (!adapter.interstitialSlot.debugStateDisposed) await adapter.dispose();
      });

      test('consent epoch: discardCachedFullscreenAds bumps AdSlot.consentEpoch '
          'and resets a ready interstitial back to idle', () async {
        await driver.loadInterstitialToReady(adapter);
        final before = AdSlot.consentEpoch;

        await adapter.discardCachedFullscreenAds();

        expect(AdSlot.consentEpoch, greaterThan(before),
            reason: 'consent narrowing must be a process-wide generation bump, '
                'not a per-slot flag — see AdSlot.consentEpoch doc comment');
        expect(adapter.interstitialSlot.isIdle, isTrue,
            reason: 'a cached-but-unshown ad must not survive consent withdrawal');
      });

      test('show mutex: a second showInterstitial() while already showing is '
          'rejected without a second native show() call', () async {
        await driver.loadInterstitialToReady(adapter);

        bool? first;
        await adapter.showInterstitial(onDone: (s) => first = s);
        expect(driver.interstitialShowCallCount(), 1);

        bool? second;
        await adapter.showInterstitial(onDone: (s) => second = s);

        expect(second, isFalse,
            reason: 'blocked by AdSlot.beginShow only valid from ready');
        expect(driver.interstitialShowCallCount(), 1,
            reason: 'the live ad must never be shown twice');
        expect(first, isNull,
            reason: 'the first call\'s onDone must not fire until dismiss');
      });

      test('dispose: leaves the interstitial slot disposed', () async {
        await driver.loadInterstitialToReady(adapter);

        await adapter.dispose();

        expect(adapter.interstitialSlot.debugStateDisposed, isTrue);
      });

      test('late callback after dispose: a native callback that lands after '
          'dispose() does not throw and is silently dropped', () async {
        await driver.loadInterstitialToReady(adapter);
        await adapter.showInterstitial(onDone: (_) {});

        await adapter.dispose();

        expect(driver.fireLateInterstitialDismiss, returnsNormally,
            reason: 'a callback in flight when dispose() started must never '
                'crash the app — see AdSlot._disposed guard doc comment');
      });

      test('revenue: a paid event on interstitial is forwarded as an '
          'AdRevenueEvent through eventSink', () async {
        final events = <AdEvent>[];
        adapter.eventSink = events.add;
        await driver.loadInterstitialToReady(adapter);

        driver.fireInterstitialRevenue();

        expect(events.whereType<AdRevenueEvent>(), isNotEmpty,
            reason: '${driver.name}: revenue must reach the host through the '
                'same AdRevenueEvent shape as the other provider');
      });

      test('watchdog: App Open force-dismisses false if native never '
          'confirms dismissal', () {
        fakeAsync((async) {
          bool? dismissed;
          driver.armAppOpenWatchdogAndShow(adapter, (d) => dismissed = d);
          expect(adapter.appOpenSlot.isShowing, isTrue);

          // AppLovin's hard cap is 18 attempts × 5s, and the boundary check
          // runs on the *pre-increment* attempt count, so the 19th tick (not
          // the 18th) is the one that actually force-dismisses — 100s covers
          // that with margin for both providers.
          async.elapse(const Duration(seconds: 100));

          expect(dismissed, isFalse,
              reason: '${driver.name}: a lost native dismiss callback must '
                  'eventually force the slot out of showing, not hang forever');
          expect(adapter.appOpenSlot.isShowing, isFalse);
        });
      });

      test('N instances: bannerSlot(key) hands out an independent AdSlot per '
          'widget key, not one shared/clobbered slot', () {
        final a = adapter.bannerSlot('key-a');
        final b = adapter.bannerSlot('key-b');

        expect(identical(a, b), isFalse);

        a.beginLoad();
        expect(a.isLoading, isTrue);
        expect(b.isIdle, isTrue,
            reason: 'loading one widget\'s banner must not affect a sibling '
                'instance keyed differently');
      });
    });
  }

  runContractSuite(_AdMobDriver.new);
  runContractSuite(_AppLovinDriver.new);
}
