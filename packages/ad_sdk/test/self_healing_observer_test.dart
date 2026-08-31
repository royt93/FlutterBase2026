// T127 — SelfHealingObserver unit tests, driven via AdManager().debugEmit
// (no real network/adapter needed). Confirms the OBSERVE-ONLY contract: an
// AdSelfHealingObserveEvent appears on the stream when the trailing data
// recommends a switch, and — critically — nothing about the active
// adapter/slot state ever changes because of it.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SelfHealingObserver observer;
  late FakeAdProviderAdapter adapter;

  setUp(() {
    adapter = FakeAdProviderAdapter();
    AdManager().debugSetAdapter(adapter);
    observer = SelfHealingObserver();
  });

  tearDown(() {
    observer.dispose();
    AdManager().debugSetAdapter(null);
  });

  void emitLoad(String provider, {required bool success}) {
    AdManager().debugEmit(AdLoadEvent(
      providerTag: provider,
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      success: success,
    ));
  }

  void emitRevenue(String provider, int valueMicros) {
    AdManager().debugEmit(AdRevenueEvent(
      providerTag: provider,
      type: AdSlotType.interstitial,
      placement: AdPlacement.home,
      valueMicros: valueMicros,
      currencyCode: 'USD',
    ));
  }

  test('no adapter set → never observes anything, even with lopsided data',
      () async {
    AdManager().debugSetAdapter(null);
    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    for (var i = 0; i < 10; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<AdSelfHealingObserveEvent>(), isEmpty);
  });

  test(
      'emits AdSelfHealingObserveEvent once the OTHER provider clearly '
      'out-fills and out-earns the current one', () async {
    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    // Current provider ('[Fake]', per the injected adapter's tag) fails a
    // lot and earns little; '[AdMob]' fills reliably and earns well.
    for (var i = 0; i < 6; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await Future<void>.delayed(Duration.zero);

    final observed = events.whereType<AdSelfHealingObserveEvent>().toList();
    expect(observed, hasLength(1),
        reason: 'exactly one observation for this (type, placement) pair');
    expect(observed.single.providerTag, '[Fake]');
    expect(observed.single.wouldSwitchToProvider, '[AdMob]');
    expect(observed.single.recommendedScore,
        greaterThan(observed.single.currentScore));

    // OBSERVE-ONLY contract: nothing about the active adapter changed.
    expect(AdManager().adapter, same(adapter));
    expect(AdManager().adapter?.tag, '[Fake]');
  });

  test('does not re-emit the same (type, placement, recommendation) twice',
      () async {
    final events = <AdEvent>[];
    final sub = AdManager().events.listen(events.add);
    addTearDown(sub.cancel);

    for (var i = 0; i < 12; i++) {
      emitLoad('[Fake]', success: false);
      emitLoad('[AdMob]', success: true);
      emitRevenue('[AdMob]', 5000000);
    }
    await Future<void>.delayed(Duration.zero);

    expect(events.whereType<AdSelfHealingObserveEvent>(), hasLength(1),
        reason: 'a recommendation that keeps holding must not spam the '
            'event stream on every subsequent event');
  });
}
