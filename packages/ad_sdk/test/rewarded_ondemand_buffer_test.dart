import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
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
  final AdSlot rewardedInterstitialSlot = AdSlot(
    type: AdSlotType.rewardedInterstitial,
  );
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

  int loadRewardedCalls = 0;
  int showRewardedCalls = 0;
  bool completeLoadImmediately = true;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadRewarded() async {
    loadRewardedCalls++;
    if (loadRewardedCalls > 1) return;
    rewardedSlot.beginReload();
    if (completeLoadImmediately) rewardedSlot.markReady();
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    if (!rewardedSlot.isReady) {
      onDone(const RewardResult(earned: false, shown: false));
      return;
    }
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(
      const RewardResult(earned: true, shown: true, label: 'coins', amount: 10),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _NonVipManager implements VipManager {
  @override
  bool get isActive => false;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _FakeAdapter fake;
  late GlobalKey<NavigatorState> navKey;

  Future<void> wire(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    AdManager().debugConfig = AdConfig(
      provider: AdProvider.admob,
      admob: const AdMobConfig(bannerId: '', interstitialId: '', appOpenId: ''),
    );

    navKey = GlobalKey<NavigatorState>();
    fake = _FakeAdapter();
    AdManager().debugSetAdapter(fake);
    AdManager().debugVipManager = _NonVipManager();
    AdManager().setNavigatorKey(navKey);

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        home: const Scaffold(body: SizedBox.shrink()),
      ),
    );
  }

  Future<void> unwire(WidgetTester tester) async {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pump();
  }

  testWidgets(
    'non-VIP: slot idle and onDemandBuffer:false skips show immediately without dialog',
    (tester) async {
      await wire(tester);
      bool? earned;

      // Slot is cooldown so the default flow cannot load it on demand.
      fake.rewardedSlot.markFailed();
      AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(fake.loadRewardedCalls, 1);
      expect(fake.showRewardedCalls, 1);
      expect(earned, isFalse);

      await unwire(tester);
    },
  );

  testWidgets(
    'non-VIP: slot already ready and onDemandBuffer:true shows immediately without dialog',
    (tester) async {
      await wire(tester);
      bool? earned;

      fake.rewardedSlot.beginReload();
      fake.rewardedSlot.markReady();

      AdManager().showRewardedAd(
        onDemandBuffer: true,
        onEarnedReward: (e) => earned = e,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(fake.showRewardedCalls, 1);
      expect(earned, isTrue);

      await unwire(tester);
    },
  );

  testWidgets(
    'non-VIP: slot idle and onDemandBuffer:true presents dialog, loads on demand, shows ad',
    (tester) async {
      await wire(tester);
      bool? earned;

      fake.completeLoadImmediately = false;
      AdManager().showRewardedAd(
        onDemandBuffer: true,
        onEarnedReward: (e) => earned = e,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));

      // Dialog is active while loading.
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      expect(fake.rewardedSlot.isLoading, isTrue);
      expect(fake.showRewardedCalls, 0);

      // Async load finishes successfully.
      fake.rewardedSlot.markReady();
      await tester.pump();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 250));

      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(fake.showRewardedCalls, 1);
      expect(earned, isTrue);

      await unwire(tester);
    },
  );

  testWidgets(
    'non-VIP: onDemandBuffer:true times out -> dismisses dialog and returns earned=false',
    (tester) async {
      await wire(tester);
      bool? earned;
      fake.completeLoadImmediately = false;

      final future = AdManager().showRewardedAd(
        onDemandBuffer: true,
        onDemandLoadTimeout: const Duration(milliseconds: 300),
        onEarnedReward: (e) => earned = e,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 50));
      expect(find.byType(CircularProgressIndicator), findsOneWidget);

      await tester.pump(const Duration(milliseconds: 350));
      await future;
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      expect(earned, isFalse);
      expect(fake.showRewardedCalls, 0);
      expect(find.byType(CircularProgressIndicator), findsNothing);

      await unwire(tester);
    },
  );
}
