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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

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
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(earned: true, shown: true, label: 'coins', amount: 1));
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
    await tester
        .pump(const Duration(milliseconds: 300)); // finish exit transition

    expect(earned, isFalse);
    expect(fake.showRewardedCalls, 0);
    expect(find.byType(CircularProgressIndicator), findsNothing,
        reason: 'dialog dismissed on timeout');

    await unwire(tester);
  });

  testWidgets(
      'cold VIP: another fullscreen ad starts showing DURING the on-demand '
      'load → re-checked after load succeeds → bails out instead of '
      'stacking on top of it', (tester) async {
    await wire(tester);

    bool? earned;
    // Slot is IDLE (cold VIP — never preloaded). Kick off the bypass show.
    AdManager().showRewardedAd(
      bypassVipGuard: true,
      onEarnedReward: (e) => earned = e,
    );
    await tester.pump(); // enter on-demand load + present dialog
    await tester.pump(const Duration(milliseconds: 50));
    expect(fake.rewardedSlot.isLoading, isTrue);

    // While the load is still pending, another fullscreen surface (e.g. an
    // app-open ad on resume) grabs the screen. beginShow() is only valid from
    // `ready`, so warm the slot up first.
    fake.interstitialSlot.beginReload();
    fake.interstitialSlot.markReady();
    fake.interstitialSlot.beginShow();

    // Now let the on-demand load resolve successfully.
    fake.rewardedSlot.markReady();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));

    expect(earned, isFalse,
        reason: 're-check after load must catch the newly-busy mutex');
    expect(fake.showRewardedCalls, 0,
        reason: 'must not stack on the interstitial that started showing '
            'during the load wait');

    fake.interstitialSlot.markDismissed();
    await unwire(tester);
  });

  testWidgets(
      'cold VIP: AdLoadingDialog.show() throwing (torn-down navigator) '
      'resets _rewardedInFlight instead of sticking it stuck true forever',
      (tester) async {
    // Regression test: before the fix, AdLoadingDialog.show(ctx) was called
    // unguarded after `_rewardedInFlight = true`. If show() throws — e.g.
    // Navigator.of(context, rootNavigator: true) finds no ancestor Navigator
    // because the navigatorKey's context isn't wired into one — the flag
    // never reset, permanently blocking every future showRewardedAd() call
    // for the rest of the session.
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();

    fake = _Fake();
    AdManager().debugSetAdapter(fake);
    AdManager().debugVipManager = _VipActive();

    // Wire a navigatorKey whose context has NO Navigator ancestor, so
    // `Navigator.of(context, rootNavigator: true)` inside
    // AdLoadingDialog.show() throws a FlutterError.
    final badKey = GlobalKey<NavigatorState>();
    AdManager().setNavigatorKey(badKey);
    await tester.pumpWidget(SizedBox(key: badKey));

    bool? earned;
    // Slot is IDLE — reaches the VIP bypass on-demand-load branch, which
    // calls AdLoadingDialog.show(ctx) before waiting on the load.
    await AdManager().showRewardedAd(
      bypassVipGuard: true,
      onEarnedReward: (e) => earned = e,
    );

    expect(earned, isFalse,
        reason: 'show() throwing must fail this call, not crash or hang');
    expect(fake.loadRewardedCalls, 0,
        reason: 'must bail out before ever starting the on-demand load');

    // AdLoadingDialog.show() sets its own `_isShowing` static true BEFORE
    // the throwing showDialog() call. That flag feeds _fullscreenBusyReason,
    // which gates every fullscreen ad surface (app open, interstitial,
    // rewarded) — so the catch block must call resetState(), not just clear
    // _rewardedInFlight, or this one failure deadlocks ALL of them, not only
    // rewarded.
    expect(AdLoadingDialog.isShowing, isFalse,
        reason: 'catch block must call AdLoadingDialog.resetState(), not '
            'just clear _rewardedInFlight, or every fullscreen ad surface '
            'stays deadlocked for the rest of the session');

    // The critical regression assertion: _rewardedInFlight must have been
    // reset, so a SUBSEQUENT call (even with a working navigator this time)
    // is not permanently blocked by the stuck flag.
    await unwire(tester);
    await wire(tester);
    bool? secondEarned;
    AdManager().showRewardedAd(
      bypassVipGuard: true,
      onEarnedReward: (e) => secondEarned = e,
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byType(CircularProgressIndicator), findsOneWidget,
        reason: '_rewardedInFlight must not still be stuck true — this '
            'call must be able to reach the on-demand load path again');

    fake.rewardedSlot.markReady();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    expect(secondEarned, isTrue);

    await unwire(tester);
  });
}
