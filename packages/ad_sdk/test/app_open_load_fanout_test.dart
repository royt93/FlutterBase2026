import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdManager().debugResetGuardState();
    AdManager().debugSetAdapter(null);
  });

  test('concurrent app-open callers each receive one callback', () async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    var first = 0;
    var second = 0;
    await Future.wait([
      manager.loadAppOpenAd(onAdLoaded: (_) => first++),
      manager.loadAppOpenAd(onAdLoaded: (_) => second++),
    ]);
    expect(adapter.appOpenSlot.isReady, isTrue);
    expect(first, 1);
    expect(second, 1);
  });

  test('a throwing callback does not prevent other callbacks', () async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
    var delivered = 0;
    await Future.wait([
      manager.loadAppOpenAd(onAdLoaded: (_) => throw StateError('host')),
      manager.loadAppOpenAd(onAdLoaded: (_) => delivered++),
    ]);
    expect(delivered, 1);
  });

  test(
      'post-T218 audit fix (CONFIRMED race) — a callback that reentrantly '
      'starts ANOTHER app-open load (a common "retry on failure" pattern) '
      'still gets its own callback invoked, not silently swallowed',
      () async {
    final adapter = FakeAdProviderAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;

    var firstDelivered = false;
    var secondDelivered = false;
    await manager.loadAppOpenAd(onAdLoaded: (_) {
      firstDelivered = true;
      // Reentrant call, synchronously from inside the first load's own
      // callback — this is exactly the timing window the old code got
      // wrong: `_inFlightAdLoads` still held the (already fully resolved)
      // first load's marker at this exact point, so this call used to
      // silently join it instead of starting a fresh load.
      unawaited(manager.loadAppOpenAd(onAdLoaded: (_) {
        secondDelivered = true;
      }));
    });
    // The reentrant call's own load needs a further pump/turn to resolve
    // (it started a brand new coalesce cycle after the outer await above
    // already returned).
    for (var i = 0; i < 10 && !secondDelivered; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    expect(firstDelivered, isTrue);
    expect(secondDelivered, isTrue,
        reason: 'T218 — the reentrant call\'s own callback must actually '
            'fire, not join a phantom already-resolved future that will '
            'never dispatch to it');
  });
}
