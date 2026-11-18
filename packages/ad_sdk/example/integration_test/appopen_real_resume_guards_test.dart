import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

class _ResumeCounter extends WidgetsBindingObserver {
  int resumes = 0;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) resumes++;
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('real resume blocks App Open for dialog and VIP, then shows',
      (tester) async {
    final manager = AdManager();
    final navigatorKey = GlobalKey<NavigatorState>();
    final lifecycle = _ResumeCounter();
    final events = <AdShowEvent>[];
    final subscription = manager.events.listen((event) {
      if (event is AdShowEvent && event.type == AdSlotType.appOpen) {
        events.add(event);
      }
    });
    WidgetsBinding.instance.addObserver(lifecycle);
    addTearDown(() async {
      WidgetsBinding.instance.removeObserver(lifecycle);
      await subscription.cancel();
      await manager.destroy();
    });
    manager.setNavigatorKey(navigatorKey);
    await tester.pumpWidget(MaterialApp(
      navigatorKey: navigatorKey,
      navigatorObservers: [adRouteObserver, AdScreenRouteLogger()],
      home: const Scaffold(body: Text('resume guard probe')),
    ));

    Future<void> waitFor(bool Function() predicate, String reason) async {
      final deadline = DateTime.now().add(const Duration(seconds: 60));
      while (!predicate() && DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      }
      expect(predicate(), isTrue, reason: reason);
    }

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
      await waitFor(() => manager.adapter!.appOpenSlot.isReady,
          'a filled test ad is required before testing guards');
    });
    expect(manager.canRequestAds, isTrue);

    await tester.runAsync(() async {
      final before = lifecycle.resumes;
      debugPrint('RESUME_GUARD cold_start_ready');
      await waitFor(() => lifecycle.resumes > before, 'cold-start resume');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(events, isEmpty, reason: 'cold-start guard must skip first resume');
      expect(manager.adapter!.appOpenSlot.isReady, isTrue);
      expect(manager.vip!.isActive, isFalse);
      debugPrint('RESUME_GUARD cold_start_consumed');
    });

    final dialog = showDialog<void>(
      context: navigatorKey.currentContext!,
      builder: (_) => const AlertDialog(title: Text('resume guard dialog')),
    );
    await tester.pumpAndSettle();
    expect(AdScreenRouteLogger.isDialogOnTop, isTrue);
    await tester.runAsync(() async {
      final before = lifecycle.resumes;
      debugPrint('RESUME_GUARD dialog_ready');
      await waitFor(() => lifecycle.resumes > before, 'real dialog resume');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(AdScreenRouteLogger.isDialogOnTop, isTrue);
      expect(manager.adapter!.appOpenSlot.isReady, isTrue);
      expect(events, isEmpty);
      debugPrint('RESUME_GUARD dialog_block_confirmed');
    });
    navigatorKey.currentState!.pop();
    await tester.pumpAndSettle();
    await dialog;

    await tester.runAsync(() async {
      await manager.vip!.addVip(
          key: 'RESUME_GUARD_PROBE', duration: const Duration(minutes: 5));
      expect(manager.vip!.isActive, isTrue);
      final before = lifecycle.resumes;
      debugPrint('RESUME_GUARD vip_ready');
      await waitFor(() => lifecycle.resumes > before, 'real VIP resume');
      await Future<void>.delayed(const Duration(seconds: 2));
      expect(manager.vip!.isActive, isTrue);
      expect(manager.adapter!.appOpenSlot.isShowing, isFalse);
      expect(events, isEmpty);
      debugPrint('RESUME_GUARD vip_block_confirmed');
      await manager.vip!.revokeAll();
      await manager.loadAppOpenAd();
      await waitFor(() => manager.adapter!.appOpenSlot.isReady,
          'a filled control ad is required after VIP removal');
      // Cold-start was consumed above; one more host resume shows the ad.
      debugPrint('RESUME_GUARD control_ready');
      await waitFor(
          () => manager.adapter!.appOpenSlot.displayConfirmed,
          'normal resume must confirm native display');
      debugPrint('RESUME_GUARD showing');
      await waitFor(() => events.any((e) => e.success),
          'host must dismiss the native test ad');
      expect(events.where((e) => e.success), hasLength(1));
      expect(manager.adapter!.appOpenSlot.isShowing, isFalse);
    });
    expect(tester.takeException(), isNull);
  },
      // Host Home/relaunch once at each *_ready marker.
      skip: !const bool.fromEnvironment('HOST_RESUME_GUARDS'));
}
