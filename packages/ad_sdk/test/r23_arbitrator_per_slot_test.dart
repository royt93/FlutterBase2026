// Round-23 QC (reviewer A, MAJOR) — the arbitrator must price the format it
// was asked about, using that format's own currency.
//
// The bug: every AdRevenueEvent went into one pool. A content feed emitting a
// hundred cheap banner impressions dragged the trailing average below the
// *rewarded* threshold, and the next rewarded opportunity — worth many times
// a banner — was vetoed in favour of a VIP nudge. Real lost revenue, and the
// ArbitratorNudgeEvent reported an eCPM belonging to a different format. The
// same shape applied to currency: a non-USD account was compared against a
// threshold documented in dollars.
//
// Every test here fails if `decide()` goes back to reading the global pool.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

  int showRewardedCalls = 0;
  int showInterstitialCalls = 0;

  @override
  String get tag => 'fake';

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
  Future<void> loadInterstitial() async {}

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

AdRevenueEvent _rev(
  int micros, {
  required AdSlotType type,
  String currencyCode = 'USD',
}) =>
    AdRevenueEvent(
      providerTag: 'fake',
      type: type,
      placement: AdPlacement.unspecified,
      valueMicros: micros,
      currencyCode: currencyCode,
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

  group('a format is priced from its own history', () {
    test(
        'a feed full of cheap banner revenue does not veto a rewarded show',
        () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // 20 banner impressions at $0.0001 each — the exact shape of a scrolling
      // content feed. Under the old single-pool arithmetic this pinned the
      // trailing eCPM at $0.10 and vetoed everything that followed.
      for (var i = 0; i < 20; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.banner));
      }
      await Future<void>.delayed(Duration.zero);

      expect(arb.estimatedEcpmMicros, 100000,
          reason: 'the diagnostic pool still sees the banner revenue');
      expect(arb.estimatedEcpmMicrosFor(AdSlotType.rewarded), 0,
          reason: 'the rewarded slot has produced no revenue of its own yet');

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);

      expect(adapter.showRewardedCalls, 1,
          reason: 'banner revenue must not price a rewarded opportunity');
      expect(earned, isTrue);
      expect(events.whereType<ArbitratorNudgeEvent>(), isEmpty);
      await sub.cancel();
    });

    test('no samples for a slot means "no evidence", never "cheap"', () {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      // Nothing fed at all. A threshold rule with no data must fail toward
      // showing the ad — suppressing revenue on zero evidence is the one
      // outcome an opt-in monetization helper must never produce.
      expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.showAd);
      expect(arb.estimatedEcpmMicrosFor(AdSlotType.rewarded), 0);
      arb.dispose();
    });

    // ── Round-24 QC (reviewer B, MAJOR) ────────────────────────────────────
    //
    // Splitting the pool per format made each bucket fill hundreds of times
    // more slowly, so a rewarded bucket sits at n=1 for a long stretch of a
    // session. Pricing off that let one cheap backfill veto the format for the
    // rest of the session — and the loop self-latched, because a vetoed show
    // emits no revenue event and the bucket could never grow past the bad
    // sample. A straight revenue regression introduced by the round-23 fix.

    test('one cheap fill cannot veto the whole session', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);

      // The realistic session: a feed full of banner money, and exactly ONE
      // rewarded fill that happened to be a $0.10 house ad.
      for (var i = 0; i < 20; i++) {
        AdManager().debugEmit(_rev(10000, type: AdSlotType.banner));
      }
      AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
      await Future<void>.delayed(Duration.zero);

      expect(arb.estimatedEcpmMicrosFor(AdSlotType.rewarded), 0,
          reason: 'one sample is not evidence — and 0 means "no evidence", '
              'which decide() already reads as show');
      expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.showAd,
          reason: 'THE finding — vetoing here loses every rewarded impression '
              'for the rest of the session off one unrepresentative fill');

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(adapter.showRewardedCalls, 1);
      expect(earned, isTrue);
      arb.dispose();
    });

    test('a thin bucket cannot self-latch: the veto never starts, so the '
        'evidence can still arrive', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);

      // Four cheap fills — still under the bar. If these vetoed, no fifth
      // sample could ever arrive, because a vetoed show pays nothing.
      for (var i = 0; i < 4; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
        await Future<void>.delayed(Duration.zero);
        expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.showAd,
            reason: 'sample ${i + 1} must not close the door on sample '
                '${i + 2}');
      }

      // The fifth arrives, and now the arbitrator has something to say.
      AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
      await Future<void>.delayed(Duration.zero);
      expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.nudgeVip,
          reason: 'once there IS evidence the veto must still work — the fix '
              'delays the judgement, it does not remove it');
      arb.dispose();
    });

    // Round-25 QC (reviewer A, MINOR) — the warm-up must never exceed what the
    // host agreed to keep. `rollingWindowSize` is public and a host may set it
    // to 1–4; the bucket is truncated to that size, so a flat requirement of
    // five would have switched their arbitrator off permanently and silently.

    test('a host with a rolling window smaller than the warm-up still gets a '
        'working arbitrator', () async {
      for (final window in [1, 4]) {
        final arb = MonetizationArbitrator(
            ecpmThresholdMicros: 5000000, rollingWindowSize: window);
        AdManager().enableArbitrator(arb);

        // Ten cheap fills — far more than the window keeps, and still fewer
        // than the default warm-up would demand.
        for (var i = 0; i < 10; i++) {
          AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
        }
        await Future<void>.delayed(Duration.zero);

        expect(arb.estimatedEcpmMicrosFor(AdSlotType.rewarded), 100000,
            reason: 'window $window — a host who keeps $window sample(s) must '
                'be priced off $window sample(s), not left unpriced forever');
        expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.nudgeVip,
            reason: 'window $window — the policy the host configured must '
                'actually run');
        arb.dispose();
      }
    });

    test('a rolling window of zero is survived, not crashed on', () async {
      // Round-26 QC (both reviewers) — the first clamp only went downward, so
      // a window of 0 gave a warm-up of 0: an empty bucket "qualified" and the
      // average divided by zero. A public constructor knob must not be able to
      // crash the SDK.
      final arb = MonetizationArbitrator(
          ecpmThresholdMicros: 5000000, rollingWindowSize: 0);
      AdManager().enableArbitrator(arb);

      for (var i = 0; i < 10; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
      }
      await Future<void>.delayed(Duration.zero);

      expect(arb.estimatedEcpmMicrosFor(AdSlotType.rewarded), 0,
          reason: 'a host who keeps no history has no evidence — and that is '
              'an answer, not an exception');
      expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.showAd,
          reason: 'and no evidence must fail toward showing the ad');
      expect(arb.estimatedEcpmMicros, 0);
      arb.dispose();
    });

    test(
        'CONTROL — genuinely cheap rewarded revenue still vetoes a rewarded '
        'show', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(100, type: AdSlotType.rewarded));
      }
      await Future<void>.delayed(Duration.zero);

      final events = <AdEvent>[];
      final sub = AdManager().events.listen(events.add);

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);

      expect(adapter.showRewardedCalls, 0,
          reason: 'the fix narrows WHICH samples count, it does not disable '
              'the veto');
      expect(earned, isFalse);
      final nudge = events.whereType<ArbitratorNudgeEvent>().single;
      expect(nudge.estimatedEcpmMicros, 100000,
          reason: 'the reported figure is the one the veto was made on');
      await sub.cancel();
    });

    test(
        'a rich rewarded history is not dragged under the threshold by cheap '
        'banners', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // $10 eCPM rewarded — comfortably above the $5 threshold. Five samples,
      // because a bucket thinner than that is deliberately not priced at all
      // (see `_minSamplesToPrice`).
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(10000, type: AdSlotType.rewarded));
      }
      // ...drowned in 40 banner impressions worth a thousandth of that.
      for (var i = 0; i < 40; i++) {
        AdManager().debugEmit(_rev(10, type: AdSlotType.banner));
      }
      await Future<void>.delayed(Duration.zero);

      expect(arb.estimatedEcpmMicrosFor(AdSlotType.rewarded), 10000000);
      expect(arb.decide(AdSlotType.rewarded), ArbitratorDecision.showAd);

      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(adapter.showRewardedCalls, 1);
      expect(earned, isTrue);
    });
  });

  group('a format is priced in its own currency', () {
    test('a stray event in another currency is not averaged in', () async {
      final arb = MonetizationArbitrator(ecpmThresholdMicros: 5000000);
      AdManager().enableArbitrator(arb);
      // A publisher paid in VND: 200_000 micros/impression is a perfectly
      // ordinary number there, and comparing it against a threshold written
      // in dollars is meaningless. What must NOT happen is the two being
      // added together into a single average.
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(_rev(9000, type: AdSlotType.interstitial));
      }
      for (var i = 0; i < 5; i++) {
        AdManager().debugEmit(
            _rev(1, type: AdSlotType.interstitial, currencyCode: 'VND'));
      }
      await Future<void>.delayed(Duration.zero);

      // The newest currency wins the bucket for that slot; the USD samples are
      // kept separately rather than blended with it.
      expect(arb.estimatedEcpmMicrosFor(AdSlotType.interstitial), 1000,
          reason: 'the VND bucket alone, not the two currencies averaged');

      // And switching back re-selects the USD history untouched.
      AdManager().debugEmit(_rev(9000, type: AdSlotType.interstitial));
      await Future<void>.delayed(Duration.zero);
      expect(arb.estimatedEcpmMicrosFor(AdSlotType.interstitial), 9000000,
          reason: 'the six USD samples, none of them polluted by the VND one');
    });
  });
}
