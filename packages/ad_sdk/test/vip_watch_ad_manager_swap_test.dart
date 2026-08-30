// Round-25 QC round 20 — the reward must land on the manager that is LIVE when
// the ad finishes, not the one captured before it started.
//
// `_onWatchAdForVip` reads `AdManager().vip` up front and then awaits a rewarded
// ad, which is on screen for 15-30 seconds. If the host switches provider or
// re-initialises the SDK in that window, the captured manager is discarded:
// `_save()` correctly drops its writes, so the user who genuinely watched an ad
// got confetti, a "success" message, and no VIP.
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter/material.dart';
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

/// Rewarded slot starts READY so the show path needs no on-demand load, and the
/// reward is delivered only when the test says so — that gap is the window the
/// host tears the SDK down in.
class _Fake implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded)..markReady();
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  @override
  String get tag => 'fake';

  void Function(RewardResult result)? pendingReward;

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    rewardedSlot.beginShow();
    pendingReward = onDone;
  }

  /// Delivers the reward the way a real SDK does once the user has watched it
  /// through: dismiss first, then the reward callback.
  void finishAdEarning() {
    rewardedSlot.markDismissed();
    pendingReward!(const RewardResult(earned: true, shown: true));
  }

  /// The manager reloads the slot after a dismiss; keep it a no-op so the test
  /// does not have to model a second load.
  @override
  Future<void> loadRewarded() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late VipManager captured;
  late VipManager live;
  late _Fake fake;
  late _FakeVipEntriesStore store;

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    AdPreferences.resetForTest();
    VipManager.resetSaveQueueForTest();
    prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    // Both managers share the store, exactly as a destroy + re-init does.
    store = _FakeVipEntriesStore(prefs);
    captured = VipManager(prefs, vipEntriesStore: store);
    await captured.load();
    live = VipManager(prefs, vipEntriesStore: store);
    await live.load();

    fake = _Fake();
    AdManager().debugSetAdapter(fake);
    AdManager().debugVipManager = captured;
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    captured.dispose();
    live.dispose();
  });

  void useTallSurface(WidgetTester tester) {
    tester.view.physicalSize = const Size(1080, 4200);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
  }

  testWidgets('an SDK re-init while the rewarded ad plays still pays the reward',
      (tester) async {
    useTallSurface(tester);
    await tester.pumpWidget(MaterialApp(
        home: VipRedeemScreen(
            publicKeyBase64: 'unused-here',
            rewardWatchAdDuration: const Duration(hours: 6))));
    await tester.pump(const Duration(milliseconds: 50));

    // The BUTTON, not the section title ('Watch ad → free VIP') — tapping the
    // title does nothing and the ad never shows.
    await tester.tap(find.text('WATCH AD'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(fake.pendingReward, isNotNull,
        reason: 'the rewarded ad must actually be showing before we swap');

    // The host tears the SDK down mid-ad and re-initialises — a provider switch,
    // or consent being withdrawn and re-granted.
    captured.dispose();
    AdManager().debugVipManager = live;

    // Only now does the user finish the ad and earn.
    fake.finishAdEarning();
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(live.isActive, isTrue,
        reason: 'the user watched a real ad — the reward must land on the '
            'manager that is live when it finishes');

    // And it must be PERSISTED, not just held in RAM: a grant through a
    // discarded manager is dropped by `_save()`, which is exactly the harm here.
    expect(store.raw, isNotNull,
        reason: 'the grant must reach the shared store, so the next launch '
            'still sees the VIP window the user earned');
    // Disposed inside the test, not in tearDown: an active VIP window arms an
    // expiry timer, and `flutter_test` fails the test on a pending timer before
    // tearDown gets a turn.
    live.dispose();
    captured.dispose();
  });

  testWidgets('CONTROL — with no re-init the reward still lands normally',
      (tester) async {
    // Without this, the test above would pass just as happily if the fix had
    // sent the grant to some other manager than the live one, or if the whole
    // watch-ad flow had stopped granting at all.
    useTallSurface(tester);
    await tester.pumpWidget(MaterialApp(
        home: VipRedeemScreen(
            publicKeyBase64: 'unused-here',
            rewardWatchAdDuration: const Duration(hours: 6))));
    await tester.pump(const Duration(milliseconds: 50));

    await tester.tap(find.text('WATCH AD'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    fake.finishAdEarning();
    await tester.pump();
    await tester
        .runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 300));

    expect(captured.isActive, isTrue);
    expect(store.raw, isNotNull);
    captured.dispose();
    live.dispose();
  });
}
