// T08 — connectivity auto-refill.
//
// When the device goes offline→online the SDK must refill ad slots and nudge
// banners immediately (debounced), instead of waiting up to 5 min for the poll
// timer. Driven through the debugConnectivityChanged seam so the native
// connection_notifier plugin is not required in tests.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:connection_notifier/connection_notifier.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Adapter with real (idle) slots + load counters, so _retryRefillAds is
/// observable. Everything else routes through noSuchMethod.
class _CountingAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

  int loadInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int loadRewardedInterstitialCalls = 0;
  int loadAppOpenCalls = 0;
  int preloadBannerCalls = 0;
  int preloadMrecCalls = 0;

  @override
  String get tag => 'counting';

  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;
  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;
  @override
  Future<void> loadRewardedInterstitial() async =>
      loadRewardedInterstitialCalls++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async =>
      loadAppOpenCalls++;
  @override
  Future<void> preloadBanner(Object key) async => preloadBannerCalls++;
  @override
  Future<void> preloadMrec(Object key) async => preloadMrecCalls++;
  @override
  void applyConsent(AdConsent consent) {}
  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;
  @override
  bool get isActive => _active;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
);

Future<void> _flush() => Future<void>.delayed(const Duration(milliseconds: 5));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    adapter = _CountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config; // isInitialised → true
    AdManager().debugVipManager = null;
    AdManager().debugReconnectDebounce = Duration.zero;
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
  });

  group('offline → online refill', () {
    test('reconnect refills idle slots and bumps initRevision', () async {
      final rev0 = AdManager().initRevision.value;
      AdManager().debugConnectivityChanged(false); // go offline (baseline)
      AdManager().debugConnectivityChanged(true); // reconnect
      await _flush();

      expect(adapter.loadInterstitialCalls, greaterThan(0));
      expect(adapter.loadRewardedCalls, greaterThan(0));
      expect(adapter.loadAppOpenCalls, greaterThan(0));
      expect(adapter.preloadBannerCalls, greaterThan(0));
      // T67 — reconnect must also nudge MREC's AppLovin bridge-level preload
      // cache (mirrors banner just above), not just interstitial/rewarded/
      // appOpen slots.
      expect(adapter.preloadMrecCalls, greaterThan(0));
      expect(AdManager().initRevision.value, rev0 + 1,
          reason: 'banners re-init on initRevision bump');
    });

    test('no transition (online → online) does nothing', () async {
      AdManager().debugConnectivityChanged(true); // was true → no-op
      final rev0 = AdManager().initRevision.value;
      AdManager().debugConnectivityChanged(true);
      await _flush();
      expect(adapter.loadInterstitialCalls, 0);
      expect(AdManager().initRevision.value, rev0);
    });

    test('going offline (online → offline) does not refill', () async {
      AdManager().debugConnectivityChanged(false);
      await _flush();
      expect(adapter.loadInterstitialCalls, 0);
    });

    test('flapping collapses into a single refill (debounced)', () async {
      AdManager().debugReconnectDebounce = const Duration(milliseconds: 40);
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      await Future<void>.delayed(const Duration(milliseconds: 80));
      // Two false→true edges, but the debounce timer is reset each time, so a
      // single refill runs.
      expect(adapter.loadInterstitialCalls, 1);
    });

    test('VIP active → reconnect does NOT refill', () async {
      AdManager().debugVipManager = _FakeVip(true);
      final rev0 = AdManager().initRevision.value;
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      await _flush();
      expect(adapter.loadInterstitialCalls, 0);
      expect(AdManager().initRevision.value, rev0);
    });

    test('not initialised → reconnect is a no-op', () async {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null; // isInitialised → false
      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      await _flush();
      expect(adapter.loadInterstitialCalls, 0);
    });
  });

  group('_retryRefillAds offline guard (R10-C)', () {
    test('does nothing while offline', () {
      AdManager().debugConnectivityChanged(false);

      AdManager().debugRetryRefillAds();

      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.preloadBannerCalls, 0);
    });

    test('still refills while online', () {
      AdManager().debugConnectivityChanged(true);

      AdManager().debugRetryRefillAds();

      expect(adapter.loadInterstitialCalls, greaterThan(0));
      expect(adapter.loadRewardedCalls, greaterThan(0));
      // 2026-08-16 audit: rewardedInterstitial (T89) was missing entirely
      // from this backstop — if its first load ever failed and it was
      // never shown, nothing would ever refill it again.
      expect(adapter.loadRewardedInterstitialCalls, greaterThan(0));
    });
  });

  // T10 — isConnected falls back to the last-known state (not a blind
  // optimistic `true`) when the native detector is unavailable/throws, which
  // is exactly what happens in this plugin-less test environment.
  group('isConnected fallback (T10)', () {
    test('reflects last-known state seen via the connectivity watch', () async {
      AdManager().debugConnectivityChanged(true);
      expect(AdManager().isConnected, isTrue);

      AdManager().debugConnectivityChanged(false);
      expect(AdManager().isConnected, isFalse);

      AdManager().debugConnectivityChanged(true);
      expect(AdManager().isConnected, isTrue);
    });
  });

  // Pre-ready init race: ad preloads fired from initialize()/VIP-change
  // callbacks can read isConnected before ConnectionNotifierTools.initialize()
  // (in _startConnectivityWatch) resolves. The guard must short-circuit to
  // last-known state and must NOT fall through to the exception-catch path —
  // proven here by asserting no warning is logged, which distinguishes the
  // guard from the (pre-existing) try/catch fallback that returns the same
  // value but only after a caught exception.
  group('isConnected pre-ready guard', () {
    tearDown(() {
      AdManager().debugConnectivityReady = false;
      SafeLogger.resetForTest();
    });

    test(
        'short-circuits to last-known without logging a read-failure '
        'warning', () {
      final warnings = <String>[];
      SafeLogger.configure(
        level: AdLogLevel.verbose,
        onLog: (level, tag, message) {
          if (level == AdLogLevel.warning) warnings.add(message);
        },
      );

      AdManager().debugConnectivityChanged(true); // seed _lastConnected
      AdManager().debugConnectivityReady = false;
      expect(AdManager().isConnected, isTrue);

      AdManager().debugConnectivityChanged(false);
      expect(AdManager().isConnected, isFalse);

      expect(warnings, isEmpty,
          reason: 'guard must return last-known before ConnectionNotifier '
              'is ready, not fall through to the catch-and-warn fallback');
    });

    test(
        'once ready, a broken/unavailable detector falls through to the '
        'catch path and DOES log a read-failure warning', () {
      final warnings = <String>[];
      SafeLogger.configure(
        level: AdLogLevel.verbose,
        onLog: (level, tag, message) {
          if (level == AdLogLevel.warning) warnings.add(message);
        },
      );

      AdManager().debugConnectivityChanged(true); // seed _lastConnected
      AdManager().debugConnectivityReady = true; // simulate init having run
      // No real ConnectionNotifierTools plugin in this test environment, so
      // the getter's try block throws and lands in the pre-existing catch —
      // the mirror-image case of the guard test above.
      expect(AdManager().isConnected, isTrue,
          reason: 'catch fallback also returns last-known');
      expect(warnings, isNotEmpty,
          reason: 'once ready, a genuinely broken detector must still warn — '
              'only the pre-ready window is silent');
    });

    test(
        'the ready flag survives destroy()/re-init, so a later read never '
        'regresses to the silent pre-ready path', () async {
      AdManager().debugConnectivityReady = true;
      await AdManager().destroy();

      final messages = <String>[];
      SafeLogger.configure(
        level: AdLogLevel.verbose,
        onLog: (level, tag, message) => messages.add(message),
      );
      AdManager().isConnected; // return value unused — only the log matters

      expect(messages.any((m) => m.contains('before ready')), isFalse,
          reason: '_connectivityReady is process/plugin-level state, not '
              "tied to this AdManager instance's lifecycle — destroy() must "
              'not reset it, or every re-init would re-open the race window');
    });
  });

  // R10-D — ConnectionNotifierTools.initialize() is a real third-party native
  // plugin call, not an internal abstraction. Nothing bounded it before, so a
  // stuck plugin (or platform channel) hung the SDK's connectivity watch
  // forever. debugConnectivityInit lets us simulate that hang deterministically
  // and prove the new 20s timeout unwedges it.
  group('_startConnectivityWatch timeout (R10-D)', () {
    tearDown(() {
      AdManager().debugConnectivityInit = ConnectionNotifierTools.initialize;
      AdManager().debugConnectivityReady = false;
      SafeLogger.resetForTest();
    });

    test(
        'degrades gracefully when the native init call never completes, '
        'instead of hanging forever', () {
      final warnings = <String>[];
      SafeLogger.configure(
        level: AdLogLevel.verbose,
        onLog: (level, tag, message) {
          if (level == AdLogLevel.warning) warnings.add(message);
        },
      );
      AdManager().debugConnectivityInit = () => Completer<void>().future;

      fakeAsync((async) {
        AdManager().debugStartConnectivityWatch();
        async.elapse(const Duration(seconds: 20));

        expect(AdManager().debugConnectivityReady, isFalse,
            reason: '_startConnectivityWatch must give up after 20s instead '
                'of hanging forever on a stuck native plugin call');
        expect(
            warnings.any((w) => w.contains('connectivity watch unavailable')),
            isTrue,
            reason: 'the existing catch(e) branch must log the timeout the '
                'same way it logs any other init failure');
      });
    });
  });

  // 2026-08-16 audit: _startConnectivityWatch is called `unawaited` from
  // initialize(), which can itself finish well before this up-to-20s await
  // resolves — so two overlapping initialize() calls could each start their
  // own overlapping _startConnectivityWatch() invocation. Whichever resolved
  // LAST used to silently overwrite _connectivitySub, leaking the other's
  // subscription forever.
  group('_startConnectivityWatch overlapping-call race (2026-08-16 audit)',
      () {
    tearDown(() {
      AdManager().debugConnectivityInit = ConnectionNotifierTools.initialize;
      AdManager().debugConnectivityReady = false;
    });

    test(
        'an older call resolving AFTER a newer one already started must not '
        'touch ready state at all (it bails before ever reaching it)',
        () {
      var calls = 0;
      // Future.delayed (not a manually-completed Completer) so its Timer is
      // driven the same fakeAsync-instrumented way as the real 20s timeout
      // below it — call A (older, dispatched first) resolves LAST.
      AdManager().debugConnectivityInit = () {
        calls++;
        return calls == 1
            ? Future<void>.delayed(const Duration(seconds: 10))
            : Future<void>.delayed(const Duration(seconds: 2));
      };

      fakeAsync((async) {
        AdManager().debugStartConnectivityWatch(); // call A: gen 1
        AdManager().debugStartConnectivityWatch(); // call B: gen 2

        // call B (newer, 2s delay) resolves first and proceeds normally.
        async.elapse(const Duration(seconds: 3));
        expect(AdManager().debugConnectivityReady, isTrue,
            reason: 'the winning (latest) call must work normally');

        // call A (older, 10s delay) resolves last — must detect it is no
        // longer the latest generation and bail out without touching
        // anything B already set.
        async.elapse(const Duration(seconds: 8));
        expect(AdManager().debugConnectivityReady, isTrue,
            reason: 'a stale call resolving after the winner must never '
                'undo what the winner already set');
      });
    });

    test(
        'a pending call resolving after _stopConnectivityWatch() was called '
        'must not resurrect ready state either', () {
      AdManager().debugConnectivityInit =
          () => Future<void>.delayed(const Duration(seconds: 5));

      fakeAsync((async) {
        AdManager().debugStartConnectivityWatch();
        async.elapse(const Duration(seconds: 1));

        AdManager().debugStopConnectivityWatch();
        async.elapse(const Duration(seconds: 5)); // the delayed init resolves

        expect(AdManager().debugConnectivityReady, isFalse,
            reason: 'a start call already stopped must not resurrect ready '
                'state or a subscription once its stale await finally '
                'resolves');
        expect(AdManager().debugHasConnectivitySubscription, isFalse);
      });
    });
  });

  group('widget: banner reacts to reconnect via initRevision', () {
    testWidgets('a widget listening to initRevision rebuilds on reconnect',
        (tester) async {
      var builds = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: ValueListenableBuilder<int>(
            valueListenable: AdManager().initRevision,
            builder: (_, __, ___) {
              builds++;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      final buildsAfterMount = builds;

      AdManager().debugConnectivityChanged(false);
      AdManager().debugConnectivityChanged(true);
      await tester.pump(const Duration(milliseconds: 10)); // let debounce fire
      await tester.pump(); // rebuild from notifier

      expect(builds, greaterThan(buildsAfterMount),
          reason: 'reconnect bumps initRevision → banner rebuilds/reloads');
    });
  });
}
