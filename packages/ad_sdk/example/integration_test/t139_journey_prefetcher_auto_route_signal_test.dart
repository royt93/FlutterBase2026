// T139 on-device integration test — JourneyPrefetcher's opt-in
// autoRouteSignalType fires a real notifySignal() from a real route push
// through a real AdManager() session, on a real device.
//
// Run with:
//   flutter test integration_test/t139_journey_prefetcher_auto_route_signal_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

AdConfig _config() => const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'pushing a named route on a real device auto-fires notifySignal and '
      'triggers a real preload, through a real AdManager() session',
      (tester) async {
    await AdManager().initialize(config: _config(), onComplete: (_, __) {});
    await tester.pump(const Duration(milliseconds: 300));
    expect(AdManager().isInitialised, isTrue);

    final prefetcher =
        JourneyPrefetcher(autoRouteSignalType: AdSlotType.interstitial);
    addTearDown(prefetcher.dispose);
    await prefetcher.ready;

    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [prefetcher.routeObserver!],
      onGenerateRoute: (_) => MaterialPageRoute(
        settings: const RouteSettings(),
        builder: (_) => const Scaffold(body: Text('home')),
      ),
    ));

    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    navigator.push(MaterialPageRoute(
      settings: const RouteSettings(name: 'level_complete'),
      builder: (_) => const Scaffold(body: Text('next')),
    ));
    await tester.pumpAndSettle();

    expect(
      prefetcher.averageTimeToShow('level_complete', AdSlotType.interstitial),
      isNull,
      reason: 'sanity: no matching AdShowEvent has fired yet, only the '
          'preload signal — average stays null until a show lands',
    );

    AdManager().debugEmit(const AdShowEvent(
      providerTag: '[RealDeviceFake]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await tester.pump();

    expect(
      prefetcher.averageTimeToShow('level_complete', AdSlotType.interstitial),
      isNotNull,
      reason: 'the route push must have really called notifySignal('
          '"level_complete", AdSlotType.interstitial) — proven by a '
          'matching AdShowEvent now completing a real rolling-average '
          'sample, on a real device, through a real AdManager() session',
    );
  });
}
