import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _config({required bool smartPreload}) => AdConfig(
  provider: AdProvider.admob,
  admob: const AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  autoRequestUmpConsent: false,
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  smartPreloadEnabled: smartPreload,
);

Future<void> _until(bool Function() test, {int seconds = 45}) async {
  final end = DateTime.now().add(Duration(seconds: seconds));
  while (!test() && DateTime.now().isBefore(end)) {
    await Future<void>.delayed(const Duration(milliseconds: 200));
  }
}

Future<AdProviderAdapter> _boot(
  WidgetTester tester, {
  required bool smartPreload,
}) async {
  final manager = AdManager();
  await tester.pumpWidget(const MaterialApp(home: Text('home')));
  await tester.runAsync(() async {
    await manager.requestUmpConsent();
    await manager.initialize(
      config: _config(smartPreload: smartPreload),
      onComplete: (_, _) {},
    );
    manager.markSplashInactive();
    await _until(() => manager.adapter!.appOpenSlot.isReady);
  });
  expect(manager.canRequestAds, isTrue, reason: 'consent gate must be open');
  final adapter = manager.adapter!;
  expect(
    adapter.appOpenSlot.isReady,
    isTrue,
    reason: 'App Open still preloads',
  );
  return adapter;
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
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets('secondary preload waits, then loads after markUserEngaged()', (
    tester,
  ) async {
    final adapter = await _boot(tester, smartPreload: true);

    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 5)),
    );
    expect(adapter.interstitialSlot.isIdle, isTrue);
    expect(adapter.rewardedSlot.isIdle, isTrue);
    expect(adapter.rewardedInterstitialSlot.isIdle, isTrue);
    debugPrint(
      'T264_DEVICE deferred: inter/rewarded/RI idle after App Open ready',
    );

    AdManager().markUserEngaged();
    await tester.runAsync(
      () => _until(
        () => adapter.interstitialSlot.isReady && adapter.rewardedSlot.isReady,
      ),
    );

    expect(adapter.interstitialSlot.isReady, isTrue);
    expect(adapter.rewardedSlot.isReady, isTrue);
    debugPrint('T264_DEVICE released: interstitial + rewarded ready');
  });

  testWidgets('host-initiated loadInterstitial is never gated', (tester) async {
    final adapter = await _boot(tester, smartPreload: true);
    expect(adapter.interstitialSlot.isIdle, isTrue);

    await tester.runAsync(() async {
      await AdManager().loadInterstitial();
      await _until(() => adapter.interstitialSlot.isReady);
    });

    expect(adapter.interstitialSlot.isReady, isTrue);
    expect(
      adapter.rewardedSlot.isIdle,
      isTrue,
      reason: 'only the asked format',
    );
    debugPrint(
      'T264_DEVICE host load: interstitial ready, rewarded still idle',
    );
  });

  testWidgets('AdScreen opened before engagement does not preload, then does', (
    tester,
  ) async {
    final adapter = await _boot(tester, smartPreload: true);
    final navKey = GlobalKey<NavigatorState>();
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navKey,
        navigatorObservers: [AdScreenRouteLogger()],
        home: const _ProbeScreen(),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(seconds: 3)),
    );
    expect(adapter.interstitialSlot.isIdle, isTrue);
    debugPrint('T264_DEVICE adscreen: interstitial idle after AdScreen opened');

    AdManager().markUserEngaged();
    await tester.runAsync(() => _until(() => adapter.interstitialSlot.isReady));
    expect(adapter.interstitialSlot.isReady, isTrue);
    debugPrint('T264_DEVICE adscreen: interstitial ready after engagement');
  });

  testWidgets('smartPreloadEnabled:false preloads without engagement', (
    tester,
  ) async {
    final adapter = await _boot(tester, smartPreload: false);

    await tester.runAsync(
      () => _until(
        () => adapter.interstitialSlot.isReady && adapter.rewardedSlot.isReady,
      ),
    );

    expect(adapter.interstitialSlot.isReady, isTrue);
    expect(adapter.rewardedSlot.isReady, isTrue);
    debugPrint('T264_DEVICE opt-out: preloaded immediately');
  });
}
