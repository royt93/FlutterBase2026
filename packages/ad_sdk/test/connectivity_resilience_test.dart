// Deeper connectivity resilience test, complementing connectivity_refill_test
// (T08 basics). Drives the same debugConnectivityChanged/debugReconnectDebounce
// seams (no native connection_notifier plugin needed in tests) but exercises:
//   - rapid flapping (5-10 cycles faster than the debounce window)
//   - a long offline period followed by reconnect
//   - that safety-cap counters (AdPreferences daily/suspicious) are untouched
//     by connectivity churn alone — only actual ad show/impression paths
//     increment those, never the reconnect-refill scan.
//   - that repeated genuine online transitions each cause exactly one refill.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Same counting adapter shape as connectivity_refill_test: slots stay idle
/// forever (load* never flips slot state), so every refill scan that runs
/// re-triggers a load call — making "how many refills actually happened"
/// directly observable as a call count.
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

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/1111111111',
    interstitialId: 'ca-app-pub-3940256099942544/2222222222',
    appOpenId: 'ca-app-pub-3940256099942544/3333333333',
    rewardedId: 'ca-app-pub-3940256099942544/4444444444',
  ),
);

Future<void> _flush([Duration d = const Duration(milliseconds: 5)]) =>
    Future<void>.delayed(d);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _CountingAdapter adapter;
  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    adapter = _CountingAdapter();
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config; // isInitialised → true
    AdManager().debugVipManager = null;
    // Realistic debounce (matches production default) unless a test
    // overrides it explicitly.
    AdManager().debugReconnectDebounce = const Duration(milliseconds: 800);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
  });

  group('rapid flapping (faster than the 800ms debounce)', () {
    test(
        '8 disconnect/reconnect cycles in quick succession collapse into '
        'a single refill', () async {
      final rev0 = AdManager().initRevision.value;
      final dailyBefore = prefs.getDailyAdCount();
      final suspiciousBefore = prefs.getSuspiciousCount();

      // Baseline: go offline once so the loop below starts on a known state.
      AdManager().debugConnectivityChanged(false);

      // 8 rapid false→true→false... cycles, no awaiting between them — much
      // faster than the 800ms debounce, so every restart cancels the
      // previous timer per the Timer.cancel() in _onConnectivityChanged.
      for (var i = 0; i < 8; i++) {
        AdManager().debugConnectivityChanged(true);
        AdManager().debugConnectivityChanged(false);
      }
      // End on a genuine final reconnect.
      AdManager().debugConnectivityChanged(true);

      // Nothing should have fired yet — still inside the debounce window.
      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);

      await _flush(const Duration(milliseconds: 850));

      // Exactly one refill fires for the whole flapping burst.
      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.loadRewardedCalls, 1);
      expect(adapter.loadAppOpenCalls, 1);
      expect(adapter.preloadBannerCalls, 1);
      expect(AdManager().initRevision.value, rev0 + 1);

      // Safety-cap counters are untouched by connectivity churn alone — only
      // actual show/impression paths increment these, never the reconnect
      // refill scan (which only calls adapter load*, never a show).
      expect(prefs.getDailyAdCount(), dailyBefore);
      expect(prefs.getSuspiciousCount(), suspiciousBefore);
    });

    test('10 rapid toggles ending offline do not refill at all', () async {
      AdManager().debugConnectivityChanged(true); // seed: online baseline
      for (var i = 0; i < 10; i++) {
        AdManager().debugConnectivityChanged(false);
        AdManager().debugConnectivityChanged(true);
      }
      AdManager().debugConnectivityChanged(false); // end offline

      await _flush(const Duration(milliseconds: 850));

      // Every reconnect edge during the loop reset the debounce timer; ending
      // offline means the timer that would fire never does.
      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
    });

    test('no exception thrown across a rapid flapping burst', () async {
      var caught = 0;
      await runZonedGuarded(() async {
        AdManager().debugConnectivityChanged(false);
        for (var i = 0; i < 10; i++) {
          AdManager().debugConnectivityChanged(true);
          AdManager().debugConnectivityChanged(false);
        }
        AdManager().debugConnectivityChanged(true);
        await _flush(const Duration(milliseconds: 850));
      }, (e, st) => caught++);
      expect(caught, 0);
    });
  });

  group('long offline period then reconnect', () {
    test(
        'one genuine transition after a long offline gap refills exactly '
        'once', () async {
      final rev0 = AdManager().initRevision.value;
      AdManager().debugConnectivityChanged(true); // seed online
      AdManager().debugConnectivityChanged(false); // drop offline

      // Well beyond the debounce window — simulates a long real outage.
      await _flush(const Duration(seconds: 2));
      expect(adapter.loadInterstitialCalls, 0,
          reason: 'still offline, no refill should ever fire');

      AdManager().debugConnectivityChanged(true); // reconnect
      await _flush(const Duration(milliseconds: 850));

      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.loadRewardedCalls, 1);
      expect(adapter.loadAppOpenCalls, 1);
      expect(adapter.preloadBannerCalls, 1);
      expect(AdManager().initRevision.value, rev0 + 1);
    });

    test(
        'multiple genuine online transitions each refill exactly once, '
        'safety counters stay untouched throughout', () async {
      final dailyBefore = prefs.getDailyAdCount();
      final suspiciousBefore = prefs.getSuspiciousCount();

      for (var cycle = 1; cycle <= 3; cycle++) {
        AdManager().debugConnectivityChanged(false);
        await _flush(const Duration(milliseconds: 850)); // long-ish offline
        AdManager().debugConnectivityChanged(true); // genuine reconnect
        await _flush(const Duration(milliseconds: 850));

        expect(adapter.loadInterstitialCalls, cycle,
            reason: 'cycle $cycle should add exactly one more refill');
        expect(adapter.loadRewardedCalls, cycle);
        expect(adapter.loadAppOpenCalls, cycle);
      }

      expect(prefs.getDailyAdCount(), dailyBefore);
      expect(prefs.getSuspiciousCount(), suspiciousBefore);
    });
  });

  group('VIP + not-initialised edge cases stay safe under churn', () {
    test('VIP active: flapping + long offline never refills, never throws',
        () async {
      AdManager().debugVipManager = _FakeVip(true);
      var caught = 0;
      await runZonedGuarded(() async {
        AdManager().debugConnectivityChanged(false);
        for (var i = 0; i < 6; i++) {
          AdManager().debugConnectivityChanged(true);
          AdManager().debugConnectivityChanged(false);
        }
        await _flush(const Duration(seconds: 1));
        AdManager().debugConnectivityChanged(true);
        await _flush(const Duration(milliseconds: 850));
      }, (e, st) => caught++);

      expect(caught, 0);
      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
    });
  });
}

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;
  @override
  bool get isActive => _active;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
