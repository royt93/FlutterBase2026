// Tests for T94's AdReadinessSplashController — the officialized version of
// the splash-screen orchestration boilerplate the README documents by hand.
//
// Full end-to-end (real SDK init succeeding, a real App Open ad loading and
// showing) needs native plugins unavailable under `flutter test` — these
// tests instead pin the parts reachable without them: the hard-cap timer,
// the re-entrant-splash short-circuit, and dispose() cleanup.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
);

void main() {
  setUp(() async {
    await AdManager().destroy();
  });
  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets('hard cap fires onReady if nothing else resolves in time',
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
      hardCapDuration: const Duration(milliseconds: 100),
    );
    addTearDown(controller.dispose);

    var readyCount = 0;
    controller.start(ctx, onReady: () => readyCount++);

    await tester.pump(const Duration(milliseconds: 50));
    expect(readyCount, 0, reason: 'still inside the hard-cap window');

    await tester.pump(const Duration(milliseconds: 100));
    expect(readyCount, 1,
        reason: 'the hard cap must force onReady once it elapses');

    // Must never fire a second time even if something else resolves later.
    await tester.pump(const Duration(milliseconds: 500));
    expect(readyCount, 1);
  });

  testWidgets(
      'reopening while a previous splash instance is still on the stack '
      'short-circuits straight to onReady', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ),
    ));

    AdManager().markSplashActive();
    AdManager().incrementSplashCount(); // simulates a splash already active

    final controller = AdReadinessSplashController(
      config: _config,
      hardCapDuration: const Duration(seconds: 30), // must not be needed
    );
    addTearDown(controller.dispose);

    var ready = false;
    controller.start(ctx, onReady: () => ready = true);
    await tester.pump(); // the postFrameCallback short-circuit

    expect(ready, isTrue,
        reason: 'countInitSplashScreen > 1 must short-circuit immediately, '
            'not wait out the hard cap');
  });

  testWidgets('dispose() before the hard cap fires prevents onReady from '
      'ever firing', (tester) async {
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
      hardCapDuration: const Duration(milliseconds: 100),
    );

    var readyCount = 0;
    controller.start(ctx, onReady: () => readyCount++);
    controller.dispose();

    await tester.pump(const Duration(milliseconds: 200));
    expect(readyCount, 0,
        reason: 'a disposed controller must not fire onReady later — the '
            'hard-cap Timer must actually be cancelled, not just forgotten');
  });
}
