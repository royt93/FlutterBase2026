// Round-23 QC (reviewer A, MAJOR) — a rewarded interstitial that was DISPLAYED
// consumes an impression, whether or not the user stayed for the reward.
//
// The bug: `showRewardedInterstitialAd` counted the impression inside
// `if (result.earned)`. A user who closes the ad before the reward point still
// caused a real, billed AdMob impression — but it consumed none of the
// session/hourly/daily/placement budget and did not re-arm the 30-second
// fullscreen pacing. Repeating that hands out materially more fullscreen
// inventory than the anti-invalid-traffic caps allow, which is the publisher's
// AdMob account at risk. The ordinary rewarded path has always used
// `result.shown`; this was the last place still gating on the reward.
//
// The same line also reported `AdShowEvent.success: false` for an ad the SDK
// had just displayed, so the SDK's own analytics disagreed with the impression
// it billed.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

/// Returns whatever [result] it is handed, so a test can pick the decisive
/// combination the old code got wrong: `shown: true, earned: false`.
class _FakeAdapter implements AdProviderAdapter {
  _FakeAdapter(this.result);

  final RewardResult result;

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

  int showRewardedInterstitialCalls = 0;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadRewardedInterstitial() async {
    rewardedInterstitialSlot.beginReload();
    rewardedInterstitialSlot.markReady();
  }

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    showRewardedInterstitialCalls++;
    rewardedInterstitialSlot.beginShow();
    rewardedInterstitialSlot.markDismissed();
    onDone(result);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<_FakeAdapter> _install(RewardResult result) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await AdPreferences.getInstance();
  await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
  AdSafetyConfig.resetForReinit();
  final adapter = _FakeAdapter(result);
  AdManager().debugSetAdapter(adapter);
  await adapter.loadRewardedInterstitial();
  return adapter;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
  });

  test(
      'shown but not earned still consumes the session impression budget',
      () async {
    final adapter = await _install(
        const RewardResult(earned: false, shown: true, label: '', amount: 0));
    final before = AdSafetyConfig.getSessionAdCount();

    bool? shown;
    bool? earned;
    await AdManager().showRewardedInterstitialAd(onDone: (s, e) {
      shown = s;
      earned = e;
    });

    expect(adapter.showRewardedInterstitialCalls, 1);
    expect(shown, isTrue);
    expect(earned, isFalse);
    expect(AdSafetyConfig.getSessionAdCount(), before + 1,
        reason: 'the ad was displayed and billed — it has to cost budget');
  });

  test(
      'shown but not earned reports AdShowEvent.success = true',
      () async {
    await _install(
        const RewardResult(earned: false, shown: true, label: '', amount: 0));

    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    await AdManager().showRewardedInterstitialAd(onDone: (_, _) {});
    await Future<void>.delayed(Duration.zero);

    final show = events
        .whereType<AdShowEvent>()
        .where((e) => e.type == AdSlotType.rewardedInterstitial)
        .single;
    expect(show.success, isTrue,
        reason: '`success` on a show event means displayed, not rewarded');
    expect(events.whereType<AdRewardEvent>(), isEmpty,
        reason: 'no reward was earned, so no reward event may be emitted');
    await sub.cancel();
  });

  test('earned still counts exactly one impression and one reward event',
      () async {
    await _install(
        const RewardResult(earned: true, shown: true, label: 'coins', amount: 5));
    final before = AdSafetyConfig.getSessionAdCount();

    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    bool? earned;
    await AdManager()
        .showRewardedInterstitialAd(onDone: (_, e) => earned = e);
    await Future<void>.delayed(Duration.zero);

    expect(earned, isTrue);
    expect(AdSafetyConfig.getSessionAdCount(), before + 1,
        reason: 'not double-counted now that `shown` drives the counter');
    expect(events.whereType<AdRewardEvent>(), hasLength(1));
    await sub.cancel();
  });

  test('CONTROL — never displayed costs no budget at all', () async {
    await _install(
        const RewardResult(earned: false, shown: false, label: '', amount: 0));
    final before = AdSafetyConfig.getSessionAdCount();

    bool? shown;
    await AdManager()
        .showRewardedInterstitialAd(onDone: (s, _) => shown = s);

    expect(shown, isFalse);
    expect(AdSafetyConfig.getSessionAdCount(), before,
        reason: 'the fix must not start charging for ads that never appeared');
  });
}
