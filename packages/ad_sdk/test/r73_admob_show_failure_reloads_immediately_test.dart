// Round-73 audit — an AdMob show failure armed the load backoff (15 s base)
// on the slot, so the refill that AdManager issues straight after the failed
// show was refused and the slot stayed empty until the 5-minute retry timer.
// AppLovin reloads immediately; AdMob must too. A real LOAD failure must still
// back off.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:flutter_test/flutter_test.dart';

import 'admob_behavioral_test.dart' show FakeGmaBridge;

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'b',
    interstitialId: 'i',
    appOpenId: 'ao',
    rewardedId: 'r',
    rewardedInterstitialId: 'ri',
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdMobAdapter a;
  late FakeGmaBridge bridge;
  setUp(() async {
    bridge = FakeGmaBridge();
    a = AdMobAdapter(bridge: bridge);
    expect(await a.initialize(_config), isTrue);
  });
  tearDown(() => a.dispose());

  group('unit: slot state after a failed show', () {
    test('interstitial: beginLoad is accepted right after a show failure',
        () {
      a.debugSimulateInterstitialShowAndDismiss((_) {}, dismissed: false);
      expect(a.interstitialSlot.isCooldown, isTrue, reason: 'sanity');
      expect(a.interstitialSlot.beginLoad(), isTrue,
          reason: 'THE finding — blocked by its own just-stamped backoff');
    });

    test('rewarded: beginLoad is accepted right after a show failure', () {
      a.debugSimulateRewardedShowAndDismiss((_) {}, dismissed: false);
      expect(a.rewardedSlot.isCooldown, isTrue, reason: 'sanity');
      expect(a.rewardedSlot.beginLoad(), isTrue);
    });

    test('the failure count is kept so later LOAD failures still back off',
        () {
      a.debugSimulateInterstitialShowAndDismiss((_) {}, dismissed: false);
      expect(a.interstitialSlot.consecutiveFailures, 1);
      expect(a.interstitialSlot.beginLoad(), isTrue);
      a.interstitialSlot.markFailed();
      expect(a.interstitialSlot.beginLoad(), isFalse,
          reason: 'a genuine load failure must still be throttled');
    });

    test('a dismissed ad (no failure) is unaffected', () {
      a.debugSimulateInterstitialShowAndDismiss((_) {});
      expect(a.interstitialSlot.isCooldown, isFalse);
      expect(a.interstitialSlot.consecutiveFailures, 0);
    });
  });

  group('manager path: the post-show refill actually starts a load', () {
    test('interstitial load after a failed show reaches the bridge', () async {
      a.debugSimulateInterstitialShowAndDismiss((_) {}, dismissed: false);
      final before = bridge.loads['interstitial']!.length;

      await a.loadInterstitial();

      expect(bridge.loads['interstitial']!.length, before + 1);
    });

    test('rewarded load after a failed show reaches the bridge', () async {
      a.debugSimulateRewardedShowAndDismiss((_) {}, dismissed: false);
      final before = bridge.loads['rewarded']!.length;

      await a.loadRewarded();

      expect(bridge.loads['rewarded']!.length, before + 1);
    });
  });
}
