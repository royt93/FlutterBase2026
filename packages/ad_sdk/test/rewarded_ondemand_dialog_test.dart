// Widget tests for the VIP-bypass *cold start* rewarded path — the case the
// real-device AppLovin log never hit (there the slot stayed warm via the
// adapter's dismiss-reload). Here we force the slot IDLE while VIP and drive a
// rewarded show through `bypassVipGuard`, asserting:
//
//   1. a blocking AdLoadingDialog appears WHILE the on-demand load is in flight,
//   2. when the load completes ASYNCHRONOUSLY the dialog dismisses and the real
//      ad is shown (earned forwarded),
//   3. if the load never completes the call times out → earned=false, no show,
//      and the dialog is dismissed.
//
// A real navigatorKey + MaterialApp are wired so AdLoadingDialog.show/dismiss
// run for real (they need a Navigator + MaterialLocalizations).

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Fake adapter whose rewarded load goes to `loading` and is completed by the
/// test (markReady / markFailed) — simulating a real async network load.
class _Fake implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int loadRewardedCalls = 0;
  int showRewardedCalls = 0;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadRewarded() async {
    loadRewardedCalls++;
    rewardedSlot.beginReload(); // → loading; test completes it later
  }

  @override
  Future<void> showRewarded(
      {required void Function(RewardResult result) onDone}) async {
    showRewardedCalls++;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(earned: true, label: 'coins', amount: 1));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _VipActive implements VipManager {
  @override
  bool get isActive => true;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Fake fake;
  late GlobalKey<NavigatorState> navKey;

  Future<void> wire(WidgetTester tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    navKey = GlobalKey<NavigatorState>();
    fake = _Fake();
    AdManager().debugSetAdapter(fake);
    AdManager().debugVipManager = _VipActive();
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
      'cold VIP: idle slot → loading dialog during on-demand load → async '
      'ready → real ad shown', (tester) async {
    await wire(tester);

    bool? earned;
    // Slot is IDLE (cold VIP — never preloaded). Kick off the bypass show.
    AdManager().showRewardedAd(
      bypassVipGuard: true,
      onEarnedReward: (e) => earned = e,
    );
    await tester.pump(); // enter on-demand load + present dialog
    await tester.pump(const Duration(milliseconds: 50));

    // Dialog is up; the ad has NOT been shown yet — we're waiting on the load.
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: 'loading dialog must cover the on-demand wait');
    expect(fake.rewardedSlot.isLoading, isTrue);
    expect(fake.showRewardedCalls, 0);

    // Simulate the async load completing successfully.
    fake.rewardedSlot.markReady();
    await tester.pump(); // listener resolves → dismiss dialog → show ad
    await tester.pump(const Duration(milliseconds: 250));

    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'dialog dismissed once the load resolved');
    expect(fake.showRewardedCalls, 1, reason: 'real ad shown after load');
    expect(earned, isTrue);

    await unwire(tester);
  });

  testWidgets(
      'cold VIP: on-demand load never completes → timeout → earned=false, '
      'no show, dialog dismissed', (tester) async {
    await wire(tester);

    bool? earned;
    final future = AdManager().showRewardedAd(
      bypassVipGuard: true,
      onDemandLoadTimeout: const Duration(milliseconds: 300),
      onEarnedReward: (e) => earned = e,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);

    // Let the on-demand timeout elapse (no markReady).
    await tester.pump(const Duration(milliseconds: 350));
    await future;
    await tester.pump(); // process the dismiss pop
    await tester.pump(const Duration(milliseconds: 300)); // finish exit transition

    expect(earned, isFalse);
    expect(fake.showRewardedCalls, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'dialog dismissed on timeout');

    await unwire(tester);
  });
}
