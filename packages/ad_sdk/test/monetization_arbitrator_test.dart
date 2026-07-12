// Behavioral tests for the opt-in Smart Monetization Arbitrator, driven
// through the same @visibleForTesting seams as ad_manager_core_test.dart
// (debugSetAdapter / debugEmit) so the two choke points (showInterstitial /
// showRewardedAd) are exercised without native plugins.
//
// Covered:
//   1. Default (arbitrator == null) is a byte-for-byte no-op — the exact
//      same show-ad scenarios as the pre-existing ad_manager tests, with
//      identical outcomes.
//   2. Trailing eCPM computed correctly from a sequence of synthetic
//      AdRevenueEvents fed via debugEmit.
//   3. Registered arbitrator whose decision crosses to nudgeVip: native show
//      is skipped, ArbitratorNudgeEvent fires on events, and the completion
//      callback signals "not shown" exactly like other early-exit gates.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

/// Same minimal fake adapter shape as ad_manager_core_test.dart — real slots
/// so slot reads work, call counters for the load/show paths.
class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int showInterstitialCalls = 0;
  int showRewardedCalls = 0;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadInterstitial() async {}

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> loadRewarded() async {
    rewardedSlot.beginReload();
    rewardedSlot.markReady();
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(const RewardResult(earned: true, label: 'coins', amount: 1));
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdRevenueEvent _rev(int micros) => AdRevenueEvent(
      providerTag: 'fake',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      valueMicros: micros,
      currencyCode: 'USD',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  late _FakeAdapter adapter;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    // Permissive safety so the fullscreen gate never blocks the show path
    // under test — isolates the arbitrator veto as the only variable.
    await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
    AdSafetyConfig.resetForReinit();
    adapter = _FakeAdapter();
    AdManager().debugSetAdapter(adapter);
  });

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugVipManager = null;
    AdManager().disableArbitrator();
  });

  group('default (no arbitrator registered) — zero behavior change', () {
    test('arbitrator getter is null by default', () {
      expect(AdManager().arbitrator, isNull);
    });

    test('showInterstitial shows exactly as before', () async {
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue);
      expect(adapter.showInterstitialCalls, 1);
    });

    test('showRewardedAd shows exactly as before', () async {
      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(earned, isTrue);
      expect(adapter.showRewardedCalls, 1);
    });

    test('feeding revenue events with no arbitrator registered changes nothing',
        () async {
      AdManager().debugEmit(_rev(100000)); // would be well below any threshold
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue,
          reason: 'no arbitrator → events are never consulted');
      expect(adapter.showInterstitialCalls, 1);
    });
  });

  group('trailing eCPM computation (via debugEmit)', () {
    test('estimatedEcpmMicros is 0 with no revenue events', () {
      final arb = MonetizationArbitrator();
      expect(arb.estimatedEcpmMicros, 0);
      arb.dispose();
    });

    test('averages a sequence of AdRevenueEvents', () async {
      final arb = MonetizationArbitrator();
      AdManager().debugEmit(_rev(1000000)); // $1.00
      AdManager().debugEmit(_rev(3000000)); // $3.00
      // Broadcast-stream delivery is async (microtask) — flush.
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 2000000); // avg $2.00
      arb.dispose();
    });

    test('rolling window truncates to the last N samples', () async {
      final arb = MonetizationArbitrator(rollingWindowSize: 2);
      AdManager().debugEmit(_rev(10000000)); // dropped once window fills
      AdManager().debugEmit(_rev(2000000));
      AdManager().debugEmit(_rev(2000000));
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicros, 2000000, reason: 'oldest sample evicted');
      arb.dispose();
    });
  });

  group('registered arbitrator crossing to nudgeVip', () {
    test(
        'showInterstitial: native show skipped, ArbitratorNudgeEvent fires, '
        'onDoneFlow(false)', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000)); // $0.10 — well below threshold
      await Future<void>.delayed(Duration.zero);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);

      expect(flow, isFalse, reason: 'vetoed — signals "not shown"');
      expect(adapter.showInterstitialCalls, 0,
          reason: 'native show call must be skipped');
      expect(events.whereType<ArbitratorNudgeEvent>(), hasLength(1));
      expect(
          events.whereType<ArbitratorNudgeEvent>().single.estimatedEcpmMicros,
          100000);

      await sub.cancel();
    });

    test(
        'showRewardedAd: native show skipped, ArbitratorNudgeEvent fires, '
        'onEarnedReward(false)', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);

      expect(earned, isFalse);
      expect(adapter.showRewardedCalls, 0);
      expect(events.whereType<ArbitratorNudgeEvent>(), hasLength(1));

      await sub.cancel();
    });

    test('high trailing eCPM (above threshold) → ad shows normally', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(10000000)); // $10 — above threshold
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue);
      expect(adapter.showInterstitialCalls, 1);
    });

    test(
        'registered VIP-likelihood estimator: high likelihood + low eCPM → '
        'nudgeVip', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      arb.registerVipLikelihoodEstimator(() => 0.9);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isFalse);
      expect(adapter.showInterstitialCalls, 0);
    });

    test(
        'registered VIP-likelihood estimator: low likelihood → ad shows '
        'despite low eCPM', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      arb.registerVipLikelihoodEstimator(() => 0.1);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000));
      await Future<void>.delayed(Duration.zero);

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isTrue);
      expect(adapter.showInterstitialCalls, 1);
    });

    test(
        'showRewardedAd VIP-bypass path (bypassVipGuard) is never vetoed by '
        'the arbitrator — watch-ad-to-extend-VIP always proceeds', () async {
      AdManager().debugVipManager = _FakeVipTrue();
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      AdManager().debugEmit(_rev(100000)); // low eCPM, would normally nudge
      await Future<void>.delayed(Duration.zero);

      bool? earned;
      await AdManager().showRewardedAd(
          bypassVipGuard: true, onEarnedReward: (e) => earned = e);
      expect(earned, isTrue);
      expect(adapter.showRewardedCalls, 1,
          reason: 'VIP watch-ad-to-extend flow must never be vetoed');
    });
  });
}

class _FakeVipTrue implements VipManager {
  @override
  bool get isActive => true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
