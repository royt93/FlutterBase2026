// T185 — AdShowEvent picks up whatever requestId is currently stamped on
// the format's AdSlot at show time (see AdSlot.requestId's doc comment and
// each of AdManager's 4 show* methods' new `requestId: ad.xSlot.requestId`
// line). Reuses r23_revenue_placement_test.dart's fake-adapter-through-
// real-AdManager pattern — the adapter itself never emits AdShowEvent
// (AdManager does), so this is the only way to exercise the real read site.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAdapter implements AdProviderAdapter {
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
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;
  @override
  String get tag => '[fake]';

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    appOpenSlot.beginShow();
    appOpenSlot.markDismissed();
    onDismiss(true);
  }

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    interstitialSlot.beginShow();
    interstitialSlot.markDismissed();
    onDone(true);
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(
        earned: true, shown: true, label: 'coins', amount: 1));
  }

  @override
  Future<void> showRewardedInterstitial(
      {required void Function(RewardResult result) onDone}) async {
    rewardedInterstitialSlot.beginShow();
    rewardedInterstitialSlot.markDismissed();
    onDone(const RewardResult(
        earned: true, shown: true, label: 'coins', amount: 1));
  }

  @override
  Future<void> loadInterstitial() async {}
  @override
  Future<void> loadRewarded() async {}
  @override
  Future<void> loadRewardedInterstitial() async {}
  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeVip implements VipManager {
  @override
  bool get isActive => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdapter adapter;
  late List<AdShowEvent> shows;

  setUp(() async {
    await AdManager().destroy();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    AdManager().debugVipManager = _FakeVip();
    AdManager().markSplashInactive();
    AdScreenRouteLogger.resetState();

    adapter = _FakeAdapter();
    AdManager().debugSetAdapter(adapter);
    adapter.eventSink = AdManager().debugEmit;

    shows = [];
    final sub = AdManager()
        .events
        .where((e) => e is AdShowEvent)
        .cast<AdShowEvent>()
        .listen(shows.add);
    addTearDown(sub.cancel);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().markSplashActive();
    AdScreenRouteLogger.resetState();
  });

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('interstitial: AdShowEvent carries whatever requestId is stamped on '
      'interstitialSlot at show time', () async {
    adapter.interstitialSlot.requestId = 'req-inter-1';

    await AdManager().showInterstitial(onDoneFlow: (_) {});
    await settle();

    expect(shows.single.requestId, 'req-inter-1');
  });

  test('rewarded: AdShowEvent carries whatever requestId is stamped on '
      'rewardedSlot at show time', () async {
    adapter.rewardedSlot.requestId = 'req-rewarded-1';

    await AdManager().showRewardedAd(onEarnedReward: (_) {});
    await settle();

    expect(shows.single.requestId, 'req-rewarded-1');
  });

  test('rewarded interstitial: AdShowEvent carries whatever requestId is '
      'stamped on rewardedInterstitialSlot at show time', () async {
    adapter.rewardedInterstitialSlot.requestId = 'req-ri-1';

    await AdManager().showRewardedInterstitialAd(onDone: (_, _) {});
    await settle();

    expect(shows.single.requestId, 'req-ri-1');
  });

  test('app open: AdShowEvent carries whatever requestId is stamped on '
      'appOpenSlot at show time', () async {
    adapter.appOpenSlot.requestId = 'req-appopen-1';

    await AdManager().showAppOpenAd(
        bypassSafety: true, onAdDismiss: (_) {});
    await settle();

    expect(shows.single.requestId, 'req-appopen-1');
  });

  test('omitting requestId (adapter never stamped one) leaves it null on '
      'AdShowEvent — exact pre-T185 behavior, unchanged', () async {
    // interstitialSlot.requestId is null by default — never set here.
    await AdManager().showInterstitial(onDoneFlow: (_) {});
    await settle();

    expect(shows.single.requestId, isNull);
  });
}
