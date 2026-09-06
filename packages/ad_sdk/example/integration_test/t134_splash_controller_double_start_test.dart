// T134 on-device integration test — calling AdReadinessSplashController
// .start() twice on the SAME instance (a caller bug, not a legitimate flow)
// must be rejected outright: no double splash-count increment, no
// hard-cap-timer restart, no second onReady firing.
//
// Run with:
//   flutter test integration_test/t134_splash_controller_double_start_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _config = AdConfig(
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
      'a second start() call on the same controller instance is rejected '
      '— no double splash-count, no hard-cap reset, no double onReady',
      (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ),
    ));

    final controller = AdReadinessSplashController(
      config: _config,
      hardCapDuration: const Duration(milliseconds: 300),
    );
    addTearDown(controller.dispose);

    var readyCount = 0;
    // ignore: use_build_context_synchronously
    controller.start(ctx, onReady: () => readyCount++);
    final countAfterFirstStart = AdManager().countInitSplashScreen;

    // ignore: use_build_context_synchronously
    controller.start(ctx, onReady: () => readyCount++);

    expect(AdManager().countInitSplashScreen, countAfterFirstStart,
        reason: 'a real device run must reject the second start() call '
            'before it re-increments splash count');

    await tester.pump(const Duration(milliseconds: 500));

    expect(readyCount, 1,
        reason: 'onReady must fire exactly once from the FIRST call\'s '
            'hard cap — a real device run proves the second call\'s '
            'ignored hard-cap timer never got a chance to also fire');
  });
}
