import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
    'loaded App Open respects sensitive screen across host-driven lifecycle',
    (tester) async {
      final manager = AdManager();
      final navigatorKey = GlobalKey<NavigatorState>();
      manager.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
          home: const Scaffold(body: Text('home')),
        ),
      );
      await tester.runAsync(() async {
        await manager.requestUmpConsent();
        await manager.initialize(
          config: const AdConfig(
            provider: AdProvider.admob,
            admob: AdMobConfig(
              bannerId: 'ca-app-pub-3940256099942544/6300978111',
              interstitialId: 'ca-app-pub-3940256099942544/1033173712',
              appOpenId: 'ca-app-pub-3940256099942544/9257395921',
              rewardedId: 'ca-app-pub-3940256099942544/5224354917',
            ),
            autoRequestUmpConsent: false,
            firstInstallVipGrace: FirstInstallVipGrace.disabled,
          ),
          onComplete: (_, _) {},
        );
        manager.markSplashInactive();
        await manager.loadAppOpenAd();
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!manager.adapter!.appOpenSlot.isReady &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
      });
      expect(manager.isInitialised, isTrue);
      expect(manager.canRequestAds, isTrue);
      final adapter = manager.adapter!;
      expect(adapter.appOpenSlot.isReady, isTrue);

      final shows = <AdShowEvent>[];
      final subscription = manager.events.listen((event) {
        if (event is AdShowEvent && event.type == AdSlotType.appOpen) {
          shows.add(event);
        }
      });
      addTearDown(subscription.cancel);
      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
          home: const AdSensitiveScreen(child: Scaffold(body: Text('payment'))),
        ),
      );
      await tester.runAsync(() async {
        final skip = manager.events
            .firstWhere(
              (event) =>
                  event is AdSkipEvent &&
                  event.type == AdSlotType.appOpen &&
                  event.reason == 'sensitive_screen',
            )
            .timeout(const Duration(seconds: 45));
        debugPrint('T262_HOST sensitive_ready');
        await skip;
      });
      expect(AdSensitiveScreen.isActive, isTrue);
      expect(adapter.appOpenSlot.isReady, isTrue);
      expect(shows, isEmpty);
      expect(find.text('payment'), findsOneWidget);
      debugPrint('T262_HOST sensitive_block_confirmed');

      await tester.pumpWidget(
        MaterialApp(
          navigatorKey: navigatorKey,
          navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
          home: const Scaffold(body: Text('home')),
        ),
      );
      expect(AdSensitiveScreen.isActive, isFalse);
      await tester.runAsync(() async {
        debugPrint('T262_HOST normal_ready');
        final deadline = DateTime.now().add(const Duration(seconds: 45));
        while (!adapter.appOpenSlot.isShowing &&
            DateTime.now().isBefore(deadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(adapter.appOpenSlot.isShowing, isTrue);
        debugPrint('T262_HOST showing');
        final dismissDeadline = DateTime.now().add(const Duration(seconds: 45));
        while (shows.isEmpty && DateTime.now().isBefore(dismissDeadline)) {
          await Future<void>.delayed(const Duration(milliseconds: 100));
        }
        expect(shows.any((event) => event.success), isTrue);
      });
    },
    // Requires host ADB Home/relaunch and native test-ad dismissal.
    skip: !const bool.fromEnvironment('T262_HOST_LIFECYCLE'),
  );
}
