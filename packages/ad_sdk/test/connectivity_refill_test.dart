// T08 — connectivity auto-refill.
//
// When the device goes offline→online the SDK must refill ad slots and nudge
// banners immediately (debounced), instead of waiting up to 5 min for the poll
// timer. Driven through the debugConnectivityChanged seam so the native
// connection_notifier plugin is not required in tests.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
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
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int loadInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int loadAppOpenCalls = 0;
  int preloadBannerCalls = 0;

  @override
  String get tag => 'counting';

  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;
  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async =>
      loadAppOpenCalls++;
  @override
  Future<void> preloadBanner() async => preloadBannerCalls++;
  @override
  void applyConsent(AdConsent consent) {}

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
