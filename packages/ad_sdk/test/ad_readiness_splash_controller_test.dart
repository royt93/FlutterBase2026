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

/// Minimal fake adapter for the round-26 regression below — only
/// `loadAppOpen` matters, and it deliberately never resolves on its own so
/// the test controls exactly when the native callback "arrives" relative to
/// `dispose()`. Every other member is unused by this path; `noSuchMethod`
/// stands in for the rest of `AdProviderAdapter` so this doesn't have to
/// list two dozen methods it never calls.
class _PendingAppOpenAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  // debugSetAdapter() wires busy-state listeners onto every fullscreen slot
  // (AdManager._attachFullscreenBusySlotListeners) — these three need to be
  // real AdSlot instances too, not routed through noSuchMethod.
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  void Function(bool loaded)? pendingOnLoaded;

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    pendingOnLoaded = onAdLoaded;
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

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

  testWidgets(
      'round-26: a loadAppOpenAd callback arriving AFTER dispose() must not '
      'fire onReady', (tester) async {
    late BuildContext ctx;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (c) {
          ctx = c;
          return const SizedBox.shrink();
        }),
      ),
    ));

    final adapter = _PendingAppOpenAdapter();
    AdManager().debugSetAdapter(adapter);
    addTearDown(() => AdManager().debugSetAdapter(null));

    final controller = AdReadinessSplashController(
      config: _config,
      hardCapDuration: const Duration(seconds: 30), // must not fire first
    );

    var readyCount = 0;
    controller.start(ctx, onReady: () => readyCount++);

    // Drives the controller into _showSplashAppOpen(), which calls
    // AdManager().loadAppOpenAd() — the fake adapter now holds the callback
    // instead of resolving it.
    SimpleEventBus().fire(const BoolEvent(true));
    await tester.pump();
    expect(adapter.pendingOnLoaded, isNotNull,
        reason: 'the fake adapter must be mid-load, not resolved yet — '
            'otherwise this test proves nothing about the race');

    // The app is backgrounded and killed (or the splash route is popped)
    // while that load is still in flight — the host calls dispose().
    controller.dispose();

    // The native callback finally arrives, after dispose().
    adapter.pendingOnLoaded!.call(false);
    await tester.pump();

    expect(readyCount, 0,
        reason: 'a native callback arriving after dispose() must not '
            "fire onReady against an already-disposed splash — this used "
            'to run the host\'s navigation callback on a deactivated '
            'BuildContext ("Looking up a deactivated widget\'s ancestor is '
            'unsafe")');
  });
}
