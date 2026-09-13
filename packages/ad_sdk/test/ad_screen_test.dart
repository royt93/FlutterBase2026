// Widget tests for AdScreen / AdScreenState — the high-level helper a host
// screen extends to get buildBanner() + showInterstitialAd() + showRewardedAd()
// with built-in pre-checks. Without an initialised SDK every show must resolve
// safely to `false` (no dialog, no crash), and buildBanner must render an empty
// banner. This proves the safe-default contract from the screen layer.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/foundation.dart';
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
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;
  @override
  Iterable<AdSlot> get bannerSlots => [_bannerSlot];
  // T181 — a real BannerAdWidget mount (as _DemoAdScreen's own buildBanner()
  // does) reaches this once its cooldown clears; previously missing here,
  // it fell through to noSuchMethod and threw.
  @override
  Future<void> loadBannerIfNeeded(Object key, double widthPx) async {}

  int showInterstitialCalls = 0;
  int showRewardedCalls = 0;
  String? lastSsvUserId;
  String? lastSsvCustomData;

  @override
  String get tag => 'ready';

  @override
  bool get isInitialised => true;

  final BannerListenables _banner = BannerListenables(
    isLoaded: ValueNotifier<bool>(false),
    hasError: ValueNotifier<bool>(false),
    adSize: ValueNotifier<Size?>(null),
    autoRefreshEnabled: ValueNotifier<bool>(true),
    visible: ValueNotifier<bool>(true),
  );
  @override
  BannerListenables banner(Object key) => _banner;

  bool _bannerRoutePaused = false;
  @override
  bool bannerRoutePaused(Object key) => _bannerRoutePaused;

  @override
  void setBannerRoutePaused(Object key, bool paused) =>
      _bannerRoutePaused = paused;

  @override
  void disposeBannerInstance(Object key) {}

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
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    lastSsvUserId = ssvUserId;
    lastSsvCustomData = ssvCustomData;
    onDone(const RewardResult(earned: true, shown: true, label: 'coins', amount: 1));
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
    this.ssvUserId,
    this.ssvCustomData,
    this.bypassVipGuard = false,
    this.callSiteTag = 'unspecified',
  });
  final void Function(bool) onInter;
  final void Function(bool) onReward;
  final String? disclosureTitle;
  final String? disclosureSubtitle;
  final String? disclosureButtonLabel;
  final String? disclosureCancelLabel;
  final String? ssvUserId;
  final String? ssvCustomData;
  final bool bypassVipGuard;
  final String callSiteTag;

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
              ssvUserId: widget.ssvUserId,
              ssvCustomData: widget.ssvCustomData,
              bypassVipGuard: widget.bypassVipGuard,
              callSiteTag: widget.callSiteTag,
            ),
            child: const Text('reward'),
          ),
        ],
      ),
    );
  }
}

class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;

  @override
  bool get isActive => _active;

  // BannerAdWidget (rendered by buildBanner() inside _DemoAdScreen) reads
  // this directly — without it, the property falls through to
  // noSuchMethod's default (throws), crashing that widget's build.
  @override
  ValueListenable<bool> get activeListenable => ValueNotifier<bool>(_active);

  @override
  void resyncSessionClock() {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
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

  testWidgets(
      'T107 follow-up: buildBanner/buildMrec/buildNative forward placement '
      'to the underlying widget — the documented AdScreen integration path '
      "must be able to set it, not just the widgets' own constructors",
      (tester) async {
    await tester.pumpWidget(host(Scaffold(
      body: Builder(builder: (context) {
        // ignore: invalid_use_of_protected_member
        final state = _DemoAdScreenState();
        return Column(children: [
          state.buildBanner(placement: AdPlacement.gameOver),
          state.buildMrec(placement: AdPlacement.gameOver),
          state.buildNative(placement: AdPlacement.gameOver),
        ]);
      }),
    )));
    await tester.pumpAndSettle();
    expect(
        (tester.widget(find.byType(BannerAdWidget)) as BannerAdWidget)
            .placement,
        AdPlacement.gameOver);
    expect(
        (tester.widget(find.byType(MrecAdWidget)) as MrecAdWidget).placement,
        AdPlacement.gameOver);
    expect(
        (tester.widget(find.byType(NativeAdWidget)) as NativeAdWidget)
            .placement,
        AdPlacement.gameOver);
  });

  testWidgets(
      'T153: buildBanner/buildMrec/buildNative forward active to the '
      'underlying widget — the IndexedStack use case active exists for was '
      'unreachable through this documented helper before this fix',
      (tester) async {
    await tester.pumpWidget(host(Scaffold(
      body: Builder(builder: (context) {
        // ignore: invalid_use_of_protected_member
        final state = _DemoAdScreenState();
        return Column(children: [
          state.buildBanner(active: false),
          state.buildMrec(active: false),
          state.buildNative(active: false),
        ]);
      }),
    )));
    await tester.pumpAndSettle();
    expect(
        (tester.widget(find.byType(BannerAdWidget)) as BannerAdWidget).active,
        isFalse);
    expect(
        (tester.widget(find.byType(MrecAdWidget)) as MrecAdWidget).active,
        isFalse);
    expect(
        (tester.widget(find.byType(NativeAdWidget)) as NativeAdWidget).active,
        isFalse);
  });

  testWidgets(
      'T153: omitting active from buildBanner/buildMrec/buildNative keeps '
      'each widget\'s own pre-T153 default — not breaking for existing '
      'callers that never pass it', (tester) async {
    await tester.pumpWidget(host(Scaffold(
      body: Builder(builder: (context) {
        // ignore: invalid_use_of_protected_member
        final state = _DemoAdScreenState();
        return Column(children: [
          state.buildBanner(),
          state.buildMrec(),
          state.buildNative(),
        ]);
      }),
    )));
    await tester.pumpAndSettle();
    expect(
        (tester.widget(find.byType(BannerAdWidget)) as BannerAdWidget).active,
        isNull,
        reason: 'null defers to BannerAdWidget\'s own automatic signal, '
            'same as constructing it directly with no active param');
    expect(
        (tester.widget(find.byType(MrecAdWidget)) as MrecAdWidget).active,
        isNull);
    expect(
        (tester.widget(find.byType(NativeAdWidget)) as NativeAdWidget).active,
        isTrue,
        reason: 'NativeAdWidget has no automatic signal (T154) — its own '
            'default is true, not null');
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

  // T39 audit gap — AdScreenState.showRewardedAd()'s ssvUserId/ssvCustomData
  // params were added with no test proving they actually reach the adapter
  // (only manually verified by reading the diff). Pins the forwarding so a
  // future param-name swap/typo fails here instead of going unnoticed.
  group('rewarded SSV param forwarding', () {
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

    testWidgets('ssvUserId/ssvCustomData reach AdManager.showRewardedAd',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (_) {},
          onReward: (_) {},
          ssvUserId: 'user-123',
          ssvCustomData: 'custom-abc',
        ),
      ));
      await tester.tap(find.byKey(const Key('reward')));
      await tester.pump(); // start buffer delay
      await tester.pump(const Duration(seconds: 2)); // let buffer timer fire

      expect(tester.takeException(), isNull);
      expect(adapter.showRewardedCalls, 1);
      expect(adapter.lastSsvUserId, 'user-123');
      expect(adapter.lastSsvCustomData, 'custom-abc');
    });
  });

  // T156 — AdScreenState.showRewardedAd() had no way to reach
  // AdManager().showRewardedAd(bypassVipGuard: true) — a VIP member's own
  // short-circuit inside the helper always won first, regardless of the
  // param, since the param didn't even exist on the helper yet.
  group('rewarded bypassVipGuard forwarding (T156)', () {
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
      AdManager().debugVipManager = _FakeVip(true);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugVipManager = null;
    });

    testWidgets(
        'VIP active + bypassVipGuard:true still reaches the real ad — the '
        'exact voluntary watch-to-extend flow this param exists for',
        (tester) async {
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (_) {},
          onReward: (_) {},
          bypassVipGuard: true,
          callSiteTag: 'vip_extend_screen',
        ),
      ));
      await tester.tap(find.byKey(const Key('reward')));
      await tester.pump(); // start buffer delay
      await tester.pump(const Duration(seconds: 2)); // let buffer timer fire

      expect(tester.takeException(), isNull);
      expect(adapter.showRewardedCalls, 1,
          reason: 'T156 — bypassVipGuard:true must reach the real ad even '
              'while VIP is active, matching AdManager().showRewardedAd\'s '
              'own contract');
    });

    testWidgets(
        'VIP active + bypassVipGuard:false (the default) still suppresses '
        'the ad, not breaking existing callers', (tester) async {
      var reward = true;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (_) {},
          onReward: (r) => reward = r,
        ),
      ));
      await tester.tap(find.byKey(const Key('reward')));
      await tester.pump();

      expect(tester.takeException(), isNull);
      expect(adapter.showRewardedCalls, 0,
          reason:
              'omitting bypassVipGuard must keep the pre-T156 VIP-suppresses '
              'behavior unchanged');
      expect(reward, isFalse);
    });
  });

  // T181 (codex round-2 fix) — showInterstitialAd's own pre-check
  // (AdManager().canShowInterstitial()) used to never receive the
  // placement it was about to show for, so a registry override looser
  // than the app-wide throttle blocked the pre-check here even though the
  // real showInterstitial() call below it (which DOES take placement)
  // would have gone on to succeed.
  group('minIntervalOverrideMs reaches the AdScreenState pre-check (T181)',
      () {
    late _ReadyAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(minTimeBetweenFullscreenAds: 999999999));
      AdSafetyConfig.resetForReinit();
      adapter = _ReadyAdapter();
      adapter.interstitialSlot.beginReload();
      adapter.interstitialSlot.markReady();
      AdManager().debugSetAdapter(adapter);
      // _DemoAdScreen's interstitial button always passes
      // placement: AdPlacement.gameOver.
      AdManager().debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
            bannerId: 'b', interstitialId: 'i', appOpenId: 'a', rewardedId: 'r'),
        placements: PlacementRegistry({
          'game_over': PlacementSpec(
            format: AdSlotType.interstitial,
            minIntervalOverrideMs: 0,
          ),
        }),
      );
      AdSafetyConfig.recordFullscreenAdShown();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    testWidgets(
        'a registered gameOver override lets the pre-check pass and reach '
        'the real show call, even though the app-wide throttle alone is '
        'set to an effectively infinite wait', (tester) async {
      bool? result;
      await tester.pumpWidget(MaterialApp(
        navigatorObservers: [adRouteObserver],
        home: _DemoAdScreen(
          onInter: (v) => result = v,
          onReward: (_) {},
        ),
      ));
      await tester.tap(find.byKey(const Key('inter')));
      // Just past showAdBuffer's 1000ms delay — not a longer pump, which
      // lets the demo screen's own banner widget's retry timer fire a
      // real loadBannerIfNeeded() call this file's fake adapter doesn't
      // implement (unrelated to what this test is about).
      await tester.pump(const Duration(milliseconds: 1100));

      expect(tester.takeException(), isNull);
      expect(adapter.showInterstitialCalls, 1,
          reason: 'the pre-check must have honored the gameOver override '
              'and let this reach AdManager.showInterstitial()');
      expect(result, isTrue);
    });
  });
}
