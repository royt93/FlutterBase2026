import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _admobConfig() => const AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  autoRequestUmpConsent: false,
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
);

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
    'resume suppresses App Open only while sensitive screen is mounted',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: Text('home')));

      var initialized = false;
      await AdManager().initialize(
        config: _admobConfig(),
        onComplete: (_, _) => initialized = true,
      );
      expect(initialized, isTrue);
      AdManager().markSplashInactive();

      final skips = <AdSkipEvent>[];
      final subscription = AdManager().events.listen((event) {
        if (event is AdSkipEvent && event.type == AdSlotType.appOpen) {
          skips.add(event);
        }
      });
      addTearDown(subscription.cancel);

      await tester.pumpWidget(
        const MaterialApp(
          home: AdSensitiveScreen(child: Scaffold(body: Text('payment'))),
        ),
      );
      await tester.runAsync(() async {
        final sensitiveSkip = AdManager().events.firstWhere(
          (event) =>
              event is AdSkipEvent &&
              event.type == AdSlotType.appOpen &&
              event.reason == 'sensitive_screen',
        );
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await sensitiveSkip.timeout(const Duration(seconds: 10));
      });
      await tester.pump();

      expect(AdSensitiveScreen.isActive, isTrue);
      expect(skips.any((event) => event.reason == 'sensitive_screen'), isTrue);
      expect(find.text('payment'), findsOneWidget);

      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: Text('home'))),
      );
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump();

      expect(AdSensitiveScreen.isActive, isFalse);
      expect(
        skips.where((event) => event.reason == 'sensitive_screen'),
        hasLength(1),
      );
      expect(find.text('home'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
