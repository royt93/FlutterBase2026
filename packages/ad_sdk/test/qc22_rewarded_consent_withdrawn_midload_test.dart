// Round-25 QC round 22 (`codex`, BLOCKER) — a rewarded ad must not be shown
// when consent was withdrawn WHILE its on-demand load was in flight.
//
// The VIP "watch an ad to extend your VIP" flow is the one path that loads a
// rewarded ad on demand instead of showing a preloaded one, and that load is
// allowed to take `onDemandLoadTimeout` (15s by default). `showRewardedAd`
// checked the consent gate at the top of the method — before that await — and
// afterwards re-read only the fullscreen mutex, so a withdrawal that landed
// inside the window (the user backgrounds the app, answers the CMP again, and
// the resume re-check applies it) was ignored and the ad was presented anyway.
//
// The same window can also swap the adapter out from under the call, which is
// the second control below.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? raw;
  @override
  Future<String?> getRaw() async => raw;
  @override
  Future<void> setRaw(String json) async => raw = json;
}

/// Rewarded slot starts IDLE, so the show path has to go through the on-demand
/// load — the window this round is about. The load never finishes on its own;
/// the test decides when, and what the world looks like by then.
class _Fake implements AdProviderAdapter {
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
  @override
  String get tag => 'fake';

  int showRewardedCalls = 0;

  @override
  Future<void> loadRewarded() async {
    // Only the first call opens the window; the manager's post-dismiss reload
    // must not reopen it.
    if (rewardedSlot.value == AdSlotState.idle) rewardedSlot.beginLoad();
  }

  /// The fill the user has been waiting for finally lands.
  void completeLoad() => rewardedSlot.markReady();

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(earned: true, shown: true));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late VipManager vip;
  late _Fake fake;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdPreferences.resetForTest();
    VipManager.resetSaveQueueForTest();
    prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    vip = VipManager(prefs, vipEntriesStore: _FakeVipEntriesStore(prefs));
    await vip.load();
    await vip.addVip(key: 'TEST', duration: const Duration(days: 1));
    fake = _Fake();
    AdManager().debugSetAdapter(fake);
    AdManager().debugVipManager = vip;
    AdManager().debugCanRequestAds = true;
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    AdManager().debugCanRequestAds = true;
    vip.dispose();
  });

  /// Starts the VIP watch-ad flow and returns a getter for the result the SDK
  /// hands back to the caller, plus the pending call itself.
  ({Future<void> call, bool? Function() reward}) startWatchAd() {
    bool? reward;
    final call = AdManager().showRewardedAd(
      onEarnedReward: (earned) => reward = earned,
      bypassVipGuard: true,
    );
    return (call: call, reward: () => reward);
  }

  test('consent withdrawn during the on-demand load blocks the show',
      () async {
    final flow = startWatchAd();
    await Future<void>.delayed(Duration.zero);
    expect(fake.rewardedSlot.value, AdSlotState.loading,
        reason: 'sanity: the flow really is waiting on an on-demand load');

    // The user answered the CMP again while this was in flight.
    AdManager().debugCanRequestAds = false;
    fake.completeLoad();
    await flow.call;

    expect(fake.showRewardedCalls, 0,
        reason: 'an impression served after the user withdrew consent is the '
            'one outcome this SDK exists to prevent');
    expect(flow.reward(), isFalse,
        reason: 'the caller must be told the reward was not earned, not left '
            'hanging');
  });

  test('the SDK being torn down during the on-demand load blocks the show',
      () async {
    final flow = startWatchAd();
    await Future<void>.delayed(Duration.zero);

    // destroy() + re-initialise swaps the adapter; `ad` in the call above is
    // the old one, whose native channel is gone.
    final replacement = _Fake();
    AdManager().debugSetAdapter(replacement);
    fake.completeLoad();
    await flow.call;

    expect(fake.showRewardedCalls, 0,
        reason: 'showing on the replaced adapter drives a disposed native '
            'channel');
    expect(replacement.showRewardedCalls, 0,
        reason: 'and it must not be re-pointed at the new adapter either — '
            'that ad was requested under the old session');
    expect(flow.reward(), isFalse);
  });

  // CONTROL — the fix must not turn the whole flow off. A VIP who watches the
  // ad through, with consent intact, still gets the ad and the reward.
  test('CONTROL — consent intact: the ad shows and the reward is paid',
      () async {
    final flow = startWatchAd();
    await Future<void>.delayed(Duration.zero);
    fake.completeLoad();
    await flow.call;

    expect(fake.showRewardedCalls, 1);
    expect(flow.reward(), isTrue);
  });
}
