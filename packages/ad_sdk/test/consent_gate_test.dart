// T01 — consent gate: no ad request while UMP canRequestAds is false.
//
// Google policy: never request an ad when ConsentInformation.canRequestAds() is
// false. AdManager mirrors this in `canRequestAds`; every load*() must skip when
// it is false. Driven via the debugCanRequestAds seam (real UMP needs native).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

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
  int showInterstitialCalls = 0;

  @override
  String get tag => 'counting';
  @override
  Future<void> showInterstitial({
    required void Function(bool shown) onDone,
  }) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;
  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async =>
      loadAppOpenCalls++;
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
    AdManager().debugConfig = _config;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true; // default open
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
  });

  group('canRequestAds gate', () {
    test('default getter is true (non-UMP hosts unaffected)', () {
      expect(AdManager().canRequestAds, isTrue);
    });

    test('gate CLOSED → all loads skip (adapter not called)', () async {
      AdManager().debugCanRequestAds = false;
      await AdManager().loadInterstitial();
      await AdManager().loadRewardedAd();
      await AdManager().loadAppOpenAd();
      expect(adapter.loadInterstitialCalls, 0);
      expect(adapter.loadRewardedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
    });

    test('gate OPEN → loads reach the adapter', () async {
      AdManager().debugCanRequestAds = true;
      await AdManager().loadInterstitial();
      await AdManager().loadRewardedAd();
      await AdManager().loadAppOpenAd();
      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.loadRewardedCalls, 1);
      expect(adapter.loadAppOpenCalls, 1);
    });

    test('loadAppOpenAd fires onAdLoaded(false) when gate closed', () async {
      AdManager().debugCanRequestAds = false;
      bool? loaded;
      await AdManager().loadAppOpenAd(onAdLoaded: (v) => loaded = v);
      expect(loaded, isFalse);
    });

    test('VIP takes precedence over an open gate', () async {
      AdManager().debugVipManager = _FakeVip(true);
      AdManager().debugCanRequestAds = true;
      await AdManager().loadInterstitial();
      expect(adapter.loadInterstitialCalls, 0);
    });

    test('not initialised → no load regardless of gate', () async {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      await AdManager().loadInterstitial();
      expect(adapter.loadInterstitialCalls, 0);
    });
  });

  group('show gate (T03 — no impression before consent)', () {
    test('gate CLOSED → showInterstitial fires onDoneFlow(false), no show',
        () async {
      AdManager().debugCanRequestAds = false;
      bool? shown;
      await AdManager().showInterstitial(onDoneFlow: (s) => shown = s);
      expect(shown, isFalse);
      expect(adapter.showInterstitialCalls, 0);
    });

    test('gate OPEN → showInterstitial reaches the adapter', () async {
      AdManager().debugCanRequestAds = true;
      await AdManager().showInterstitial(onDoneFlow: (_) {});
      expect(adapter.showInterstitialCalls, 1);
    });
  });

  group('widget: consent action unblocks ad loading', () {
    testWidgets('load triggered from UI respects the gate', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => Column(
                children: [
                  ElevatedButton(
                    onPressed: () => AdManager().loadInterstitial(),
                    child: const Text('Load'),
                  ),
                ],
              ),
            ),
          ),
        ),
      );

      // Gate closed → tap does nothing.
      AdManager().debugCanRequestAds = false;
      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(adapter.loadInterstitialCalls, 0);

      // Consent granted (gate open) → tap loads.
      AdManager().debugCanRequestAds = true;
      await tester.tap(find.text('Load'));
      await tester.pump();
      expect(adapter.loadInterstitialCalls, 1);
    });
  });
}
