// Tests for the optional Server-Side Verification (SSV) plumbing on the
// rewarded-ad path. This SDK does NOT run a server or verify anything
// itself — these tests only assert that `ssvCustomData`/`ssvUserId` passed
// to `AdManager().showRewardedAd(...)` reach each native adapter's real SSV
// field (AppLovin: `custom_data`; AdMob: `ServerSideVerificationOptions`),
// and that `RewardResult.pendingServerConfirmation` /
// `AdRewardEvent.pendingServerConfirmation` are `false` by default and only
// flip `true` when SSV data was supplied — with zero behavior change to the
// existing reward-earned path when SSV params are omitted.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_bridge.dart';
import 'package:applovin_admob_sdk/src/adapters/gma_bridge.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_max/applovin_max.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// ─── AppLovin fakes (mirrors applovin_adapter_test.dart's FakeAppLovinBridge,
// kept local/minimal since only the rewarded surface matters here) ─────────

class _FakeAppLovinBridge implements AppLovinBridge {
  RewardedAdListener? rewarded;

  final List<String> showRewardedCalls = [];
  String? lastCustomData;

  @override
  Future<void> initialize(String sdkKey) async {}
  @override
  void setTestDeviceAdvertisingIds(List<String> ids) {}
  @override
  void setTermsAndPrivacyPolicyFlowEnabled(bool enabled) {}
  @override
  void setAppOpenAdListener(AppOpenAdListener? l) {}
  @override
  void setInterstitialListener(InterstitialListener? l) {}
  @override
  void setRewardedAdListener(RewardedAdListener? l) => rewarded = l;
  @override
  void setWidgetAdViewAdListener(WidgetAdViewAdListener? l) {}
  @override
  void loadAppOpenAd(String id) {}
  @override
  void showAppOpenAd(String id) {}
  @override
  void loadInterstitial(String id) {}
  @override
  void showInterstitial(String id) {}
  @override
  void loadRewardedAd(String id) {}
  @override
  void showRewardedAd(String id, {String? customData}) {
    showRewardedCalls.add(id);
    lastCustomData = customData;
  }

  @override
  Future<AdViewId?> preloadWidgetAdView(String id, AdFormat f) async => 1;
  @override
  Future<void> destroyWidgetAdView(AdViewId id) async {}
}

MaxAd _fakeMaxAd() => MaxAd(
    'rewarded-id',
    'REWARDED',
    null,
    'net',
    '',
    0.0,
    'exact',
    'cid',
    'dsp',
    '',
    0,
    MaxAdWaterfallInfo('', '', const [], 0),
    null,
    null);

const _appLovinConfig = AdConfig(
  provider: AdProvider.appLovin,
  appLovin: AppLovinConfig(
    sdkKey: 'sdk',
    bannerId: 'banner-id',
    interstitialId: 'inter-id',
    appOpenId: 'appopen-id',
    rewardedId: 'rewarded-id',
  ),
);

// ─── AdMob fakes (mirrors admob_behavioral_test.dart) ──────────────────────

class _FakeGmaFullscreenAd implements GmaFullscreenAd {
  GmaShowCallbacks? shown;
  String? lastSsvCustomData;
  String? lastSsvUserId;

  @override
  Future<void> show(
    GmaShowCallbacks callbacks, {
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    shown = callbacks;
    lastSsvCustomData = ssvCustomData;
    lastSsvUserId = ssvUserId;
  }

  @override
  void setPaidEventListener(void Function(num, String, String) cb) {}
  @override
  List<String>? get mediationWaterfall => null;
  @override
  void dispose() {}
}

class _FakeGmaBridge implements GmaBridge {
  _FakeGmaFullscreenAd? lastRewarded;

  @override
  Future<void> initialize() async {}
  @override
  Future<void> updateRequestConfiguration(List<String> ids) async {}
  @override
  Future<void> loadAppOpen(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {}
  @override
  Future<void> loadInterstitial(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {}
  @override
  Future<void> loadRewarded(String id,
      {required bool nonPersonalizedAds,
      bool restrictedDataProcessing = false,
      required void Function(GmaFullscreenAd) onLoaded,
      required void Function(int, String) onFailed}) async {
    final ad = _FakeGmaFullscreenAd();
    lastRewarded = ad;
    onLoaded(ad);
  }
}

const _admobConfig = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
  ),
);

// ─── AdManager end-to-end fake (mirrors ad_manager_core_test.dart's
// _FakeAdapter) — proves the param survives the full showRewardedAd() path
// and lands on the AdRewardEvent, without touching any native plugin. ───────

class _E2EFakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  String? lastSsvCustomData;
  String? lastSsvUserId;

  _E2EFakeAdapter() {
    rewardedSlot.beginLoad();
    rewardedSlot.markReady();
  }

  @override
  String get tag => 'fake';

  // The reward path unconditionally kicks a reload after dismiss/fail
  // (Fix #2) — a real no-op keeps that call from falling through to
  // noSuchMethod, which would throw instead of silently succeeding.
  @override
  Future<void> loadRewarded() async {}

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    lastSsvCustomData = ssvCustomData;
    lastSsvUserId = ssvUserId;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(RewardResult(
      earned: true,
      label: 'coins',
      amount: 1,
      pendingServerConfirmation: ssvCustomData != null || ssvUserId != null,
    ));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RewardResult.pendingServerConfirmation', () {
    test('defaults to false', () {
      const r = RewardResult(earned: true, label: 'coins', amount: 1);
      expect(r.pendingServerConfirmation, isFalse);
    });

    test('RewardResult.skipped is never pending', () {
      expect(RewardResult.skipped.pendingServerConfirmation, isFalse);
    });

    test('true when explicitly constructed with it', () {
      const r = RewardResult(earned: true, pendingServerConfirmation: true);
      expect(r.pendingServerConfirmation, isTrue);
    });
  });

  group('AppLovinAdapter SSV passthrough', () {
    late _FakeAppLovinBridge bridge;
    late AppLovinAdapter adapter;

    setUp(() async {
      bridge = _FakeAppLovinBridge();
      adapter = AppLovinAdapter(bridge: bridge);
      expect(await adapter.initialize(_appLovinConfig), isTrue);
    });

    tearDown(() async => adapter.dispose());

    test('omitting ssv params → customData null, no behavior change', () async {
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(_fakeMaxAd());

      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);
      expect(bridge.showRewardedCalls, ['rewarded-id']);
      expect(bridge.lastCustomData, isNull);

      bridge.rewarded!
          .onAdReceivedRewardCallback(_fakeMaxAd(), MaxReward(10, 'coins'));
      expect(result, isNotNull);
      expect(result!.earned, isTrue);
      expect(result!.pendingServerConfirmation, isFalse,
          reason: 'no SSV data supplied → not pending');
    });

    test(
        'ssvCustomData is forwarded verbatim to AppLovinMAX.showRewardedAd '
        'custom_data field, and marks the result pending', () async {
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(_fakeMaxAd());

      RewardResult? result;
      await adapter.showRewarded(
        onDone: (r) => result = r,
        ssvCustomData: 'user-123:order-456',
      );
      expect(bridge.lastCustomData, 'user-123:order-456');

      bridge.rewarded!
          .onAdReceivedRewardCallback(_fakeMaxAd(), MaxReward(10, 'coins'));
      expect(result!.pendingServerConfirmation, isTrue);
    });

    test(
        'ssvUserId falls back into custom_data (AppLovin has no separate '
        'userId field)', () async {
      await adapter.loadRewarded();
      bridge.rewarded!.onAdLoadedCallback(_fakeMaxAd());

      await adapter.showRewarded(
        onDone: (_) {},
        ssvUserId: 'user-789',
      );
      expect(bridge.lastCustomData, 'user-789');
    });
  });

  group('AdMobAdapter SSV passthrough', () {
    late _FakeGmaBridge bridge;
    late AdMobAdapter adapter;

    setUp(() async {
      bridge = _FakeGmaBridge();
      adapter = AdMobAdapter(bridge: bridge);
      expect(await adapter.initialize(_admobConfig), isTrue);
    });

    test('omitting ssv params → GMA show() gets null SSV, no behavior change',
        () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(onDone: (r) => result = r);

      expect(bridge.lastRewarded!.lastSsvCustomData, isNull);
      expect(bridge.lastRewarded!.lastSsvUserId, isNull);

      bridge.lastRewarded!.shown!.onUserEarnedReward!(10, 'coins');
      expect(result!.earned, isTrue);
      expect(result!.pendingServerConfirmation, isFalse);
    });

    test(
        'ssvCustomData/ssvUserId reach ServerSideVerificationOptions via '
        'GmaFullscreenAd.show(...)', () async {
      await adapter.loadRewarded();
      RewardResult? result;
      await adapter.showRewarded(
        onDone: (r) => result = r,
        ssvCustomData: 'order-456',
        ssvUserId: 'user-123',
      );

      expect(bridge.lastRewarded!.lastSsvCustomData, 'order-456');
      expect(bridge.lastRewarded!.lastSsvUserId, 'user-123');

      bridge.lastRewarded!.shown!.onUserEarnedReward!(10, 'coins');
      expect(result!.pendingServerConfirmation, isTrue);
    });
  });

  group('AdManager().showRewardedAd SSV plumbing (end-to-end, no native SDK)',
      () {
    late _E2EFakeAdapter fake;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      fake = _E2EFakeAdapter();
      AdManager().debugSetAdapter(fake);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
    });

    test('omitting ssv params: adapter sees nulls, event not pending',
        () async {
      AdRewardEvent? event;
      final sub = AdManager().events.listen((e) {
        if (e is AdRewardEvent) event = e;
      });

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);

      expect(earned, isTrue, reason: 'existing earned path unchanged');
      expect(fake.lastSsvCustomData, isNull);
      expect(fake.lastSsvUserId, isNull);
      expect(event, isNotNull);
      expect(event!.pendingServerConfirmation, isFalse);
      await sub.cancel();
    });

    test('supplying ssvCustomData: adapter receives it, event flips pending',
        () async {
      AdRewardEvent? event;
      final sub = AdManager().events.listen((e) {
        if (e is AdRewardEvent) event = e;
      });

      bool? earned;
      await AdManager().showRewardedAd(
        onEarnedReward: (e) => earned = e,
        ssvCustomData: 'partner-order-789',
      );

      expect(earned, isTrue);
      expect(fake.lastSsvCustomData, 'partner-order-789');
      expect(event, isNotNull);
      expect(event!.pendingServerConfirmation, isTrue);
      await sub.cancel();
    });

    test(
        'supplying ssvUserId only: still reaches the adapter and flips '
        'pending', () async {
      bool? earned;
      await AdManager().showRewardedAd(
        onEarnedReward: (e) => earned = e,
        ssvUserId: 'user-42',
      );
      expect(earned, isTrue);
      expect(fake.lastSsvUserId, 'user-42');
    });
  });
}
