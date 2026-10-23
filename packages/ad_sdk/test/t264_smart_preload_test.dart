// T264 — Engagement-gated secondary preload. App Open/Banner preload stay
// immediate; Interstitial/Rewarded/RewardedInterstitial auto-preload waits
// for 15s continuous foreground, 2 navigation events, or markUserEngaged().
// Host-initiated loadX() calls are never gated.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _CountingAdapter implements AdProviderAdapter {
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

  int loadInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int loadRewardedInterstitialCalls = 0;
  int get secondaryCalls =>
      loadInterstitialCalls + loadRewardedCalls + loadRewardedInterstitialCalls;

  @override
  String get tag => 'counting';
  @override
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async => true;

  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;
  @override
  Future<void> loadRewarded() async => loadRewardedCalls++;
  @override
  Future<void> loadRewardedInterstitial() async =>
      loadRewardedInterstitialCalls++;
  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> applyConsent(AdConsent consent) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdConfig _config({bool smartPreload = true}) => AdConfig(
  provider: AdProvider.admob,
  admob: const AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  safety: const AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  smartPreloadEnabled: smartPreload,
);

class _Popup extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;
  @override
  bool get barrierDismissible => true;
  @override
  String? get barrierLabel => null;
  @override
  Duration get transitionDuration => Duration.zero;
  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) => const SizedBox();
}

class _ProbeScreen extends AdScreen {
  const _ProbeScreen();
  @override
  State<_ProbeScreen> createState() => _ProbeScreenState();
}

class _ProbeScreenState extends AdScreenState<_ProbeScreen> {
  @override
  Widget build(BuildContext context) => const Scaffold(body: Text('probe'));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');
  late _CountingAdapter adapter;

  Future<void> boot({bool smartPreload = true}) async {
    AdManager.debugAdapterFactory = (_) => adapter = _CountingAdapter();
    await AdManager().initialize(
      config: _config(smartPreload: smartPreload),
      onComplete: (_, _) {},
    );
    // initialize()'s own consent gate overwrites canRequestAds while it
    // settles — re-assert AFTER it, same idiom as fast_refill_*_test.dart.
    AdManager().debugCanRequestAds = true;
    // _startConnectivityWatch() resolves asynchronously and flips the ready
    // flag on, after which the real (offline-in-tests) detector answers —
    // let it settle first, then force the optimistic last-known path.
    await Future<void>.delayed(const Duration(milliseconds: 50));
    AdManager().debugConnectivityReady = false;
    AdManager().debugConnectivityChanged(true);
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;
  }

  void settleAppOpen() {
    adapter.appOpenSlot.beginLoad();
    adapter.appOpenSlot.markReady();
  }

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    AdScreenRouteLogger.resetState();
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    await AdManager().destroy();
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugVipManager = null;
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test('smartPreloadEnabled defaults to true', () {
    expect(
      const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'b',
          interstitialId: 'i',
          appOpenId: 'a',
          rewardedId: 'r',
        ),
      ).smartPreloadEnabled,
      isTrue,
    );
  });

  test(
    'App Open settling does not preload secondary formats before engagement',
    () async {
      await boot();
      settleAppOpen();
      await Future<void>.delayed(Duration.zero);

      expect(adapter.secondaryCalls, 0);
    },
  );

  test(
    'markUserEngaged() releases the deferred preload exactly once',
    () async {
      await boot();
      settleAppOpen();

      AdManager().markUserEngaged();
      AdManager().markUserEngaged();
      await Future<void>.delayed(Duration.zero);

      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.loadRewardedCalls, 1);
      expect(adapter.loadRewardedInterstitialCalls, 1);
    },
  );

  test(
    'markUserEngaged() before App Open settles preloads on settle',
    () async {
      await boot();
      AdManager().markUserEngaged();
      expect(adapter.secondaryCalls, 0, reason: 'App Open has not settled yet');

      settleAppOpen();
      await Future<void>.delayed(Duration.zero);

      expect(adapter.secondaryCalls, 3);
    },
  );

  test('two navigation events engage the user; one does not', () async {
    await boot();
    settleAppOpen();
    final logger = AdScreenRouteLogger();
    final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());

    logger.didPush(route, null);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.secondaryCalls, 0, reason: 'one navigation is not enough');

    logger.didPush(route, null);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.secondaryCalls, 3);
  });

  testWidgets('real Navigator pushes engage the user after two routes', (
    tester,
  ) async {
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [AdScreenRouteLogger()],
        home: const Scaffold(body: Text('home')),
      ),
    );
    await tester.runAsync(() async {
      await boot();
      settleAppOpen();
    });
    expect(adapter.secondaryCalls, 0);

    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('second')),
    );
    await tester.pumpAndSettle();
    expect(adapter.secondaryCalls, 0, reason: 'one real push is not enough');

    navKey.currentState!.push(
      MaterialPageRoute<void>(builder: (_) => const Text('third')),
    );
    await tester.pumpAndSettle();

    expect(adapter.loadInterstitialCalls, 1);
    expect(adapter.loadRewardedCalls, 1);
    expect(adapter.loadRewardedInterstitialCalls, 1);
  });

  testWidgets(
    'the SDK loading dialog and host dialogs do not count as navigation',
    (tester) async {
      final navKey = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navKey,
          navigatorObservers: [AdScreenRouteLogger()],
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.runAsync(() async {
        await boot();
        settleAppOpen();
      });

      AdLoadingDialog.show(navKey.currentContext!);
      await tester.pump();
      AdLoadingDialog.dismiss();
      await tester.pump();
      showDialog<void>(
        context: navKey.currentContext!,
        builder: (_) => const AlertDialog(title: Text('host dialog')),
      );
      await tester.pumpAndSettle();
      navKey.currentState!.pop();
      await tester.pumpAndSettle();

      expect(
        adapter.secondaryCalls,
        0,
        reason: 'popup routes are not user navigation',
      );

      navKey.currentState!.push(
        MaterialPageRoute<void>(builder: (_) => const Text('single page')),
      );
      await tester.pumpAndSettle();

      expect(
        adapter.secondaryCalls,
        0,
        reason: 'dialog cycle + 1 page = only 1 page nav; requires 2',
      );
    },
  );

  test('navigation events before initialize() do not count', () async {
    final logger = AdScreenRouteLogger();
    final route = MaterialPageRoute<void>(builder: (_) => const SizedBox());
    logger.didPush(route, null);
    logger.didPush(route, null);
    final popup = _Popup();
    logger.didPush(popup, route);
    logger.didPop(popup, route);

    await boot();
    settleAppOpen();
    logger.didPush(route, null);
    await Future<void>.delayed(Duration.zero);
    expect(
      adapter.secondaryCalls,
      0,
      reason: '2 pre-init + 1 post-init: only 1 counts',
    );

    logger.didPush(route, null);
    await Future<void>.delayed(Duration.zero);
    expect(adapter.secondaryCalls, 3, reason: '2 post-init events engage');
  });

  test(
    '15s of continuous foreground engages; 14s does not',
    () async {
      await boot();
      settleAppOpen();

      await Future<void>.delayed(const Duration(seconds: 14));
      expect(adapter.secondaryCalls, 0, reason: '14s foreground');

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(adapter.secondaryCalls, 3, reason: '15.5s foreground');
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'pausing resets the foreground timer',
    () async {
      await boot();
      settleAppOpen();

      await Future<void>.delayed(const Duration(seconds: 10));
      AdManager().didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(const Duration(seconds: 6));
      expect(
        adapter.secondaryCalls,
        0,
        reason: 'background time must not count',
      );

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(seconds: 14));
      expect(adapter.secondaryCalls, 0, reason: '14s since resume');

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(adapter.secondaryCalls, 3, reason: '15.5s since resume');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'Android paused -> hidden -> inactive -> resumed restarts 15s timer',
    () async {
      await boot();
      settleAppOpen();
      await Future<void>.delayed(const Duration(seconds: 10));

      for (final state in [
        AppLifecycleState.paused,
        AppLifecycleState.hidden,
        AppLifecycleState.inactive,
        AppLifecycleState.resumed,
      ]) {
        AdManager().didChangeAppLifecycleState(state);
      }

      await Future<void>.delayed(const Duration(seconds: 14));
      expect(adapter.secondaryCalls, 0, reason: '14s since actual resume');
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(adapter.secondaryCalls, 3, reason: '15.5s since actual resume');
    },
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'hidden without paused stops the timer until resumed',
    () async {
      await boot();
      settleAppOpen();
      AdManager().didChangeAppLifecycleState(AppLifecycleState.hidden);
      await Future<void>.delayed(const Duration(seconds: 16));
      expect(adapter.secondaryCalls, 0, reason: 'hidden time must not count');
      AdManager().didChangeAppLifecycleState(AppLifecycleState.inactive);
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 15500));
      expect(adapter.secondaryCalls, 3);
    },
    timeout: const Timeout(Duration(seconds: 50)),
  );

  test(
    'init finishing while hidden does not count hidden time',
    () async {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.hidden);
      await boot();
      settleAppOpen();

      await Future<void>.delayed(const Duration(seconds: 16));
      expect(adapter.secondaryCalls, 0, reason: 'still hidden');

      AdManager().didChangeAppLifecycleState(AppLifecycleState.inactive);
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(milliseconds: 15500));
      expect(adapter.secondaryCalls, 3, reason: '15.5s since resume');
    },
    timeout: const Timeout(Duration(seconds: 50)),
  );

  test(
    'inactive -> resumed (no pause) does not restart the 15s clock',

    () async {
      await boot();
      settleAppOpen();

      await Future<void>.delayed(const Duration(seconds: 9));
      AdManager().didChangeAppLifecycleState(AppLifecycleState.inactive);
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(seconds: 7));

      expect(adapter.secondaryCalls, 3, reason: '16s since init, no pause');
    },
    timeout: const Timeout(Duration(seconds: 40)),
  );

  test(
    'init finishing while backgrounded does not count background time',
    () async {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.paused);
      await boot();
      settleAppOpen();

      await Future<void>.delayed(const Duration(seconds: 16));
      expect(adapter.secondaryCalls, 0, reason: 'still backgrounded');

      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(const Duration(seconds: 14));
      expect(adapter.secondaryCalls, 0, reason: '14s since resume');

      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(adapter.secondaryCalls, 3, reason: '15.5s since resume');
    },
    timeout: const Timeout(Duration(seconds: 60)),
  );

  test(
    'retry refill backstop does not load secondary before engagement',
    () async {
      await boot();

      AdManager().debugRetryRefillAds();
      await Future<void>.delayed(Duration.zero);

      expect(adapter.secondaryCalls, 0);
    },
  );

  test('retry refill loads secondary after engagement', () async {
    await boot();
    AdManager().markUserEngaged();
    await Future<void>.delayed(Duration.zero);
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;

    AdManager().debugRetryRefillAds();
    await Future<void>.delayed(Duration.zero);

    expect(adapter.loadInterstitialCalls, 1);
    expect(adapter.loadRewardedCalls, 1);
    expect(adapter.loadRewardedInterstitialCalls, 1);
  });

  test('VIP ending does not preload secondary before engagement', () async {
    await boot();
    final vip = AdManager().vip!;
    await vip.revokeAll();
    await vip.addVip(key: 'PAID', duration: const Duration(hours: 1));
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;

    await vip.revokeAll();

    expect(adapter.secondaryCalls, 0);
  });

  test(
    'host-initiated loadInterstitial/loadRewardedAd are never gated',
    () async {
      await boot();
      final skips = <String>[];
      final sub = AdManager().events.listen((e) {
        if (e is AdSkipEvent) skips.add('${e.type.name}:${e.reason}');
      });

      await AdManager().loadInterstitial();
      await AdManager().loadRewardedAd();
      await AdManager().loadRewardedInterstitialAd();
      await Future<void>.delayed(Duration.zero);
      // ignore: avoid_print
      print(
        'T264_PROBE skips=$skips canRequest=${AdManager().canRequestAds} '
        'connected=${AdManager().isConnected}',
      );
      await sub.cancel();
      expect(adapter.loadInterstitialCalls, 1);
      expect(adapter.loadRewardedCalls, 1);
      expect(adapter.loadRewardedInterstitialCalls, 1);
    },
  );

  testWidgets('AdScreen.initState defers its interstitial preload', (
    tester,
  ) async {
    await tester.runAsync(() => boot());
    await tester.pumpWidget(const MaterialApp(home: _ProbeScreen()));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(adapter.loadInterstitialCalls, 0, reason: 'deferred, not dropped');

    AdManager().markUserEngaged();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(adapter.loadInterstitialCalls, 1, reason: 'released on engagement');
  });

  testWidgets('AdScreen.initState preloads at once after engagement', (
    tester,
  ) async {
    await tester.runAsync(() => boot());
    AdManager().markUserEngaged();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    adapter.loadInterstitialCalls = 0;

    await tester.pumpWidget(const MaterialApp(home: _ProbeScreen()));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(adapter.loadInterstitialCalls, 1);
  });

  testWidgets('AdScreen.initState preloads at once when smart preload is off', (
    tester,
  ) async {
    await tester.runAsync(() => boot(smartPreload: false));

    await tester.pumpWidget(const MaterialApp(home: _ProbeScreen()));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));

    expect(adapter.loadInterstitialCalls, 1);
  });

  test(
    'JourneyPrefetcher defers fullscreen signals but not App Open',
    () async {
      await boot();
      final prefetcher = JourneyPrefetcher(persist: false);
      addTearDown(prefetcher.dispose);

      prefetcher.notifySignal('level_start', AdSlotType.interstitial);
      prefetcher.notifySignal('level_start', AdSlotType.rewarded);
      prefetcher.notifySignal('level_start', AdSlotType.rewardedInterstitial);
      await Future<void>.delayed(Duration.zero);
      expect(adapter.secondaryCalls, 0, reason: 'deferred until engaged');

      AdManager().markUserEngaged();
      await Future<void>.delayed(Duration.zero);
      expect(adapter.secondaryCalls, 3, reason: 'released once, all 3 formats');
    },
  );

  test('JourneyPrefetcher loads at once after engagement', () async {
    await boot();
    AdManager().markUserEngaged();
    await Future<void>.delayed(Duration.zero);
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;
    final prefetcher = JourneyPrefetcher(persist: false);
    addTearDown(prefetcher.dispose);

    prefetcher.notifySignal('level_start', AdSlotType.interstitial);
    await Future<void>.delayed(Duration.zero);

    expect(adapter.loadInterstitialCalls, 1);
    expect(adapter.loadRewardedCalls, 0, reason: 'only the signalled format');
  });

  test('smartPreloadEnabled:false preloads immediately as before', () async {
    await boot(smartPreload: false);
    settleAppOpen();
    await Future<void>.delayed(Duration.zero);

    expect(adapter.loadInterstitialCalls, 1);
    expect(adapter.loadRewardedCalls, 1);
    expect(adapter.loadRewardedInterstitialCalls, 1);
  });

  test('destroy() clears engagement on its own', () async {
    await boot();
    AdManager().markUserEngaged();
    await AdManager().destroy();

    // Same adapter object + settle after destroy: a leaked _userEngaged flag
    // would let this load; a leaked pending flag would too.
    AdManager().debugSetAdapter(adapter);
    AdManager().debugConfig = _config();
    adapter.loadInterstitialCalls = 0;
    adapter.loadRewardedCalls = 0;
    adapter.loadRewardedInterstitialCalls = 0;
    AdManager().debugRetryRefillAds();
    await Future<void>.delayed(Duration.zero);

    expect(adapter.secondaryCalls, 0);
  });

  test(
    're-initialize() without destroy() does not inherit engagement',
    () async {
      await boot();
      AdManager().markUserEngaged();

      await boot();
      settleAppOpen();
      await Future<void>.delayed(Duration.zero);

      expect(adapter.secondaryCalls, 0);
    },
  );

  test('destroy() + re-initialize() does not inherit engagement', () async {
    await boot();
    AdManager().markUserEngaged();
    await AdManager().destroy();

    await boot();
    settleAppOpen();
    await Future<void>.delayed(Duration.zero);

    expect(adapter.secondaryCalls, 0);
  });
}
