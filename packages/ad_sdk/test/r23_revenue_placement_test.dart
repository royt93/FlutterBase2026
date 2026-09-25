// Round-23 QC (reviewer C, MINOR) — a revenue (paid) event must name the
// placement the ad was actually shown from.
//
// Both adapters wire their paid-event listener when the ad is *loaded*, and a
// placement only exists when it is *shown*. So every `AdRevenueEvent` the SDK
// ever emitted carried `AdPlacement.unspecified` — and the App Open one was
// worse than that, hardcoded to `AdPlacement.splash` even for a resume
// impression. A host wiring `AdManager().events` into its analytics to answer
// "which screen actually earns money" got one undifferentiated bucket, which
// is the entire point of the placement API.
//
// The fix records the placement at the show call and stamps it on the way
// through `_emit`. Inline formats (banner/MREC/native) are deliberately left
// alone: they have no show call to take a placement from.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Emits a revenue event from inside the show call — which is where a real
/// mediation SDK reports it, on impression — tagged the only way an adapter
/// can tag it: with no idea where it is being shown.
class _PayingAdapter implements AdProviderAdapter {
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
  String get tag => '[fake-paying]';

  /// What the adapter itself knows at paid-event time. `splash` for App Open
  /// mirrors `AdMobAdapter._wirePaidEvent(ad, AdSlotType.appOpen,
  /// AdPlacement.splash)` verbatim.
  void _pay(AdSlotType type, AdPlacement asTaggedByAdapter) {
    eventSink?.call(AdRevenueEvent(
      providerTag: tag,
      type: type,
      placement: asTaggedByAdapter,
      valueMicros: 12000,
      currencyCode: 'USD',
    ));
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    appOpenSlot.beginShow();
    _pay(AdSlotType.appOpen, AdPlacement.splash);
    appOpenSlot.markDismissed();
    onDismiss(true);
  }

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    interstitialSlot.beginShow();
    _pay(AdSlotType.interstitial, AdPlacement.unspecified);
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
    _pay(AdSlotType.rewarded, AdPlacement.unspecified);
    rewardedSlot.markDismissed();
    onDone(const RewardResult(
        earned: true, shown: true, label: 'coins', amount: 1));
  }

  @override
  Future<void> showRewardedInterstitial(
      {required void Function(RewardResult result) onDone}) async {
    rewardedInterstitialSlot.beginShow();
    _pay(AdSlotType.rewardedInterstitial, AdPlacement.unspecified);
    rewardedInterstitialSlot.markDismissed();
    onDone(const RewardResult(
        earned: true, shown: true, label: 'coins', amount: 1));
  }

  /// Banner revenue arrives from a surface that is never "shown" by a call —
  /// it just sits on the screen earning. Used by the CONTROL below.
  void payBanner() => _pay(AdSlotType.banner, AdPlacement.unspecified);

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

  late _PayingAdapter adapter;
  late List<AdRevenueEvent> revenue;

  setUp(() async {
    await AdManager().destroy();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    AdManager().debugVipManager = _FakeVip();
    AdManager().markSplashInactive();
    AdScreenRouteLogger.resetState();

    adapter = _PayingAdapter();
    AdManager().debugSetAdapter(adapter);
    adapter.eventSink = AdManager().debugEmit;

    revenue = [];
    final sub = AdManager()
        .events
        .where((e) => e is AdRevenueEvent)
        .cast<AdRevenueEvent>()
        .listen(revenue.add);
    addTearDown(sub.cancel);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    AdManager().markSplashActive();
    AdScreenRouteLogger.resetState();
  });

  /// The stream is async — the show call returns before the listener has run.
  Future<void> settle() => Future<void>.delayed(Duration.zero);

  test('CONTROL — banner revenue keeps the placement the adapter gave it',
      () async {
    // Nothing shows a banner, so there is no show-time placement to borrow.
    // Stamping one here would be inventing data.
    await AdManager()
        .showInterstitial(onDoneFlow: (_) {}, placement: AdPlacement.levelComplete);
    adapter.payBanner();
    await settle();

    final banner = revenue.where((e) => e.type == AdSlotType.banner).single;
    expect(banner.placement, AdPlacement.unspecified);
  });

  test('interstitial revenue is attributed to the show-time placement',
      () async {
    await AdManager()
        .showInterstitial(onDoneFlow: (_) {}, placement: AdPlacement.levelComplete);
    await settle();

    expect(revenue.single.placement, AdPlacement.levelComplete,
        reason: 'THE finding: every revenue event used to say "unspecified", '
            'so a host could not tell which screen earns');
    expect(revenue.single.valueMicros, 12000,
        reason: 'the rest of the event must pass through untouched');
    expect(revenue.single.currencyCode, 'USD');
  });

  test('rewarded revenue too', () async {
    await AdManager().showRewardedAd(
        onEarnedReward: (_) {}, placement: AdPlacement.shop);
    await settle();

    expect(revenue.single.placement, AdPlacement.shop);
  });

  test('rewarded interstitial revenue too', () async {
    await AdManager().showRewardedInterstitialAd(
        onDone: (_, _) {}, placement: AdPlacement.levelComplete);
    await settle();

    expect(revenue.single.placement, AdPlacement.levelComplete);
  });

  test('App Open revenue stops claiming to be the splash on a resume show',
      () async {
    await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (_) {},
        placement: AdPlacement.home);
    await settle();

    expect(revenue.single.placement, AdPlacement.home,
        reason: 'the adapter hardcodes `splash`; the show-time placement is '
            'the authoritative one and must win');
  });

  test('each format is attributed independently', () async {
    await AdManager()
        .showInterstitial(onDoneFlow: (_) {}, placement: AdPlacement.levelComplete);
    // The 30 s fullscreen throttle would refuse the second show outright, and
    // this test is about attribution, not pacing.
    AdSafetyConfig.resetForReinit();
    await AdManager().showRewardedAd(
        onEarnedReward: (_) {}, placement: AdPlacement.shop);
    await settle();

    expect(
        revenue
            .firstWhere((e) => e.type == AdSlotType.interstitial)
            .placement,
        AdPlacement.levelComplete);
    expect(revenue.firstWhere((e) => e.type == AdSlotType.rewarded).placement,
        AdPlacement.shop,
        reason: 'one shared field would have overwritten the other');
  });
}
