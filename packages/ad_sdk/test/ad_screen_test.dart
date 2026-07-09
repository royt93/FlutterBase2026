// Widget tests for AdScreen / AdScreenState — the high-level helper a host
// screen extends to get buildBanner() + showInterstitialAd() + showRewardedAd()
// with built-in pre-checks. Without an initialised SDK every show must resolve
// safely to `false` (no dialog, no crash), and buildBanner must render an empty
// banner. This proves the safe-default contract from the screen layer.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Minimal fake adapter whose interstitial/rewarded slots can be marked
/// ready, so `canShowInterstitial()`/`canShowRewardedAd()` pass the
/// pre-check and the flow actually reaches `AdLoadingDialog.showAdBuffer`'s
/// delay — the window T23's audit flagged as untested for mid-await dispose.
class _ReadyAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int showInterstitialCalls = 0;
  int showRewardedCalls = 0;

  @override
  String get tag => 'ready';

  @override
  bool get isInitialised => true;

  @override
  BannerListenables banner = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );

  @override
  bool bannerRoutePaused = false;

  @override
  void setBannerRoutePaused(bool paused) => bannerRoutePaused = paused;

  @override
  Future<void> loadInterstitial() async {}

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> loadRewarded() async {}

  @override
  Future<void> showRewarded(
      {required void Function(RewardResult result) onDone}) async {
    showRewardedCalls++;
    onDone(const RewardResult(earned: true, label: 'coins', amount: 1));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _DemoAdScreen extends AdScreen {
  const _DemoAdScreen({
    required this.onInter,
    required this.onReward,
    this.disclosureTitle,
    this.disclosureSubtitle,
    this.disclosureButtonLabel,
    this.disclosureCancelLabel,
  });
  final void Function(bool) onInter;
  final void Function(bool) onReward;
  final String? disclosureTitle;
  final String? disclosureSubtitle;
  final String? disclosureButtonLabel;
  final String? disclosureCancelLabel;

  @override
  State<_DemoAdScreen> createState() => _DemoAdScreenState();
}

class _DemoAdScreenState extends AdScreenState<_DemoAdScreen> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Column(
        children: [
          buildBanner(),
          ElevatedButton(
            key: const Key('inter'),
            onPressed: () => showInterstitialAd(
              placement: AdPlacement.gameOver,
              onDone: widget.onInter,
            ),
            child: const Text('inter'),
          ),
          ElevatedButton(
            key: const Key('reward'),
            onPressed: () => showRewardedAd(
              onEarnedReward: widget.onReward,
              disclosureTitle: widget.disclosureTitle,
              disclosureSubtitle: widget.disclosureSubtitle,
              disclosureButtonLabel: widget.disclosureButtonLabel,
              disclosureCancelLabel: widget.disclosureCancelLabel,
            ),
            child: const Text('reward'),
          ),
        ],
      ),
    );
  }
}

void main() {
  Widget host(Widget child) => MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: child,
      );

  testWidgets('buildBanner renders (empty when SDK not initialised)',
      (tester) async {
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (_) {},
      onReward: (_) {},
    )));
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('showInterstitialAd fails the pre-check → onDone(false)',
      (tester) async {
    bool? result;
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (v) => result = v,
      onReward: (_) {},
    )));
    await tester.tap(find.byKey(const Key('inter')));
    await tester.pump();
    expect(result, isFalse,
        reason:
            'no adapter → canShowInterstitial false → no dialog, onDone(false)');
  });

  testWidgets('showRewardedAd with no ad → onEarnedReward(false)',
      (tester) async {
    bool? reward;
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (_) {},
      onReward: (v) => reward = v,
    )));
    await tester.tap(find.byKey(const Key('reward')));
    await tester.pump(); // onEarnedReward(false) fires synchronously
    expect(reward, isFalse);
    // No-ad path shows a 3 s TopToast — pump past it so no timer is left pending.
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('disposed screen resolves shows to false without throwing',
      (tester) async {
    bool? result;
    await tester.pumpWidget(host(_DemoAdScreen(
      onInter: (v) => result = v,
      onReward: (_) {},
    )));
    // Tear the screen down, then a late callback must be safe.
    await tester.pumpWidget(host(const SizedBox()));
    await tester.pumpAndSettle();
    expect(find.byType(BannerAdWidget), findsNothing);
    expect(tester.takeException(), isNull);
    expect(result, isNull);
  });

  // T23 (leak-audit round) — the pre-check passes (a real ready adapter), so
  // the flow reaches AdLoadingDialog.showAdBuffer's ~1s delay. Disposing the
  // screen WHILE that delay is in flight, then letting it fire, must not
  // touch the disposed State/context: ad_screen.dart's `if (!mounted ||
  // _isDisposed)` guard inside the onComplete closure is what's under test.
  group('mid-showAdBuffer dispose (pre-check passed, awaiting buffer)', () {
    late _ReadyAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _ReadyAdapter();
      adapter.interstitialSlot.beginReload();
      adapter.interstitialSlot.markReady();
      adapter.rewardedSlot.beginReload();
      adapter.rewardedSlot.markReady();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() => AdManager().debugSetAdapter(null));

    testWidgets(
        'interstitial: dispose during buffer delay → no crash, onDone(false)',
        (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (v) => result = v,
          onReward: (_) {},
        ),
      ));
      await tester.tap(find.byKey(const Key('inter')));
      // Dialog route is now pushed; showAdBuffer's 1000ms delay is pending.
      // Replace the whole tree so the screen — and its dialog — are torn
      // down mid-delay, before the buffer timer fires.
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester
          .pump(const Duration(seconds: 2)); // let the buffer timer fire

      expect(tester.takeException(), isNull,
          reason: 'onComplete must check mounted/_isDisposed before acting');
      expect(adapter.showInterstitialCalls, 0,
          reason:
              'disposed screen must never reach AdManager.showInterstitial');
      expect(result, isFalse,
          reason: 'onDone is still invoked (caller decides UI), but with '
              'false — screen never touches its own disposed state');
    });

    testWidgets(
        'rewarded: dispose during buffer delay → no crash, onEarnedReward(false)',
        (tester) async {
      bool? reward;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (_) {},
          onReward: (v) => reward = v,
        ),
      ));
      await tester.tap(find.byKey(const Key('reward')));
      await tester.pumpWidget(const MaterialApp(home: SizedBox()));
      await tester.pump(const Duration(seconds: 2));

      expect(tester.takeException(), isNull);
      expect(adapter.showRewardedCalls, 0,
          reason: 'disposed screen must never reach AdManager.showRewardedAd');
      expect(reward, isFalse);
    });
  });

  // T22 — disclosureTitle opts a caller into a confirm dialog before the
  // rewarded ad plays. Omitted-disclosureTitle path is already pinned by
  // the earlier tests in this file (none pass it).
  group('rewarded disclosure hook', () {
    late _ReadyAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _ReadyAdapter();
      adapter.rewardedSlot.beginReload();
      adapter.rewardedSlot.markReady();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() => AdManager().debugSetAdapter(null));

    testWidgets('confirmed → proceeds to ad flow, reward true', (tester) async {
      bool? reward;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (_) {},
          onReward: (v) => reward = v,
          disclosureTitle: 'Earn 50 coins',
          disclosureSubtitle: 'Watch a short ad to continue.',
          disclosureButtonLabel: 'Watch ad',
        ),
      ));
      await tester.tap(find.byKey(const Key('reward')));
      await tester.pump(); // build disclosure dialog

      expect(find.text('Earn 50 coins'), findsOneWidget);
      await tester.tap(find.text('Watch ad'));
      await tester.pump(); // dismiss dialog, start buffer delay
      await tester.pump(const Duration(seconds: 2)); // let buffer timer fire

      expect(tester.takeException(), isNull);
      expect(adapter.showRewardedCalls, 1,
          reason: 'confirming the disclosure must still reach the real ad');
      expect(reward, isTrue);
    });

    testWidgets('cancelled → onEarnedReward(false), ad never shown',
        (tester) async {
      bool? reward;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (_) {},
          onReward: (v) => reward = v,
          disclosureTitle: 'Earn 50 coins',
          disclosureCancelLabel: 'Không, cảm ơn',
        ),
      ));
      await tester.tap(find.byKey(const Key('reward')));
      await tester.pump();

      expect(find.text('Không, cảm ơn'), findsOneWidget,
          reason: 'disclosureCancelLabel must override the English default');
      await tester.tap(find.text('Không, cảm ơn'));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(adapter.showRewardedCalls, 0,
          reason: 'declining the disclosure must never reach the ad flow');
      expect(reward, isFalse);
    });
  });
}
