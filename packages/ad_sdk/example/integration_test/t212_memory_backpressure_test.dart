// T212 on-device integration test — a 10k real-event burst plus 50 real
// AdManager().initialize()-then-destroy() reinit cycles, exercised
// directly against the real AdManager singleton. Platform channels
// (applovin_max/google_mobile_ads/flutter_secure_storage) are REAL here —
// no mocking needed, unlike the SDK's own unit-test copy of this logic
// (see packages/ad_sdk/test/support/ad_stress_harness.dart).
//
// Run with:
//   flutter test integration_test/t212_memory_backpressure_test.dart \
//     -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart'
    show AdEventSink;
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
  autoRequestUmpConsent: false,
);

/// Same reasoning as the SDK's own `test/support/ad_stress_harness.dart`
/// copy: a real adapter's `dispose()` disposing its own fullscreen slots
/// would mask whether `AdManager` itself detached its listener first, so
/// this one deliberately never disposes them.
class _LeakDetectableAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  @override
  String get tag => '[stress]';

  @override
  AdEventSink? eventSink;

  @override
  bool Function() canReload = () => true;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  Future<void> dispose() async {}

  @override
  void applyConsent(AdConsent consent) {}

  @override
  dynamic noSuchMethod(Invocation invocation) =>
      super.noSuchMethod(invocation);
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T212 device smoke: 10k real events fully delivered + 50 real '
      'initialize()-then-destroy() reinit cycles leak no listener, on a '
      'real device', (tester) async {
    var delivered = 0;
    final sub = AdManager().events.listen((_) => delivered++);
    const eventCount = 10000;
    for (var i = 0; i < eventCount; i++) {
      AdManager().debugEmit(AdLoadEvent(
        providerTag: '[stress]',
        type: AdSlotType.values[i % AdSlotType.values.length],
        placement: AdPlacement.unspecified,
        success: i.isEven,
      ));
    }
    for (var i = 0; i < eventCount + 50 && delivered < eventCount; i++) {
      await tester.pump();
    }
    await sub.cancel();
    expect(delivered, eventCount,
        reason: 'T212 — nothing may be silently dropped from a real burst '
            'on a real device process');

    var leaked = 0;
    const reinitializations = 50;
    for (var i = 0; i < reinitializations; i++) {
      final adapter = _LeakDetectableAdapter();
      AdManager.debugAdapterFactory = (_) => adapter;
      var completed = false;
      await AdManager().initialize(
        config: _config,
        onComplete: (_, __) => completed = true,
      );
      expect(completed, isTrue);
      await AdManager().destroy();
      if (adapter.appOpenSlot.debugHasStateListeners ||
          adapter.interstitialSlot.debugHasStateListeners ||
          adapter.rewardedSlot.debugHasStateListeners ||
          adapter.rewardedInterstitialSlot.debugHasStateListeners) {
        leaked++;
      }
    }
    AdManager.debugAdapterFactory = null;
    expect(leaked, 0,
        reason: 'T212 — every real initialize()-then-destroy() cycle must '
            'genuinely detach the old adapter\'s fullscreen slot '
            'listeners, on a real device process');
    expect(tester.takeException(), isNull);
  });
}
