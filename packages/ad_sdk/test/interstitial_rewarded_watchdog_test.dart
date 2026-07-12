// Unit-test coverage for the Interstitial/Rewarded show/dismiss state
// machine — the automated equivalent of `applovin_watchdog_test.dart` for
// App Open, adjusted for reality: unlike App Open, AppLovin/GMA's fullscreen
// interstitial and rewarded callbacks are treated as reliable, so there is
// NO watchdog/timer for these two slots (see `_wireInterstitialListener`,
// `_wireRewardedListener` in applovin_adapter.dart and the plain
// `ad.show(GmaShowCallbacks(...))` path in admob_adapter.dart — read in full
// before touching this file). The state machine under test here is just:
//
//   beginShow() → [native callback] → markDismissed() / markShowFailed()
//
// with a one-shot done-callback (`_interstitialDone` / `_rewardedDone`) that
// must never leave the slot stuck in `AdSlotState.showing` (a "zombie"
// state) — the same bug class that was fixed for App Open. Since there is no
// timer to race against a late callback, the regression this file guards is
// simpler: two back-to-back show/dismiss cycles must both complete cleanly
// and leave the slot idle/cooldown, never stuck in `showing`.
//
// No synthetic "late-callback race" test is included: without a watchdog
// timer competing with the native callback, there is no second writer that
// could race the slot transition — inventing one would test a scenario that
// cannot occur in the real code path.

import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('AppLovin interstitial', () {
    test('show → dismiss leaves slot idle, never stuck in showing', () {
      final adapter = AppLovinAdapter();
      bool? shown;
      adapter.debugSimulateInterstitialShowAndDismiss((s) => shown = s);

      expect(shown, isTrue);
      expect(adapter.interstitialSlot.value, AdSlotState.idle);
    });

    test('show → display-fail leaves slot in cooldown, never stuck showing',
        () {
      final adapter = AppLovinAdapter();
      bool? shown;
      adapter.debugSimulateInterstitialShowAndDismiss((s) => shown = s,
          dismissed: false);

      expect(shown, isFalse);
      expect(adapter.interstitialSlot.value, AdSlotState.cooldown);
    });

    test('two back-to-back show/dismiss cycles never leave a zombie showing',
        () {
      final adapter = AppLovinAdapter();
      var calls = 0;
      adapter.debugSimulateInterstitialShowAndDismiss((_) => calls++);
      expect(adapter.interstitialSlot.value, AdSlotState.idle);

      // A real second cycle requires the slot back in `ready` first — the
      // debug hook drives that itself via beginLoad()/markReady().
      adapter.debugSimulateInterstitialShowAndDismiss((_) => calls++);

      expect(calls, 2);
      expect(adapter.interstitialSlot.value, AdSlotState.idle);
    });
  });

  group('AppLovin rewarded', () {
    test('show → dismiss leaves slot idle, never stuck in showing', () {
      final adapter = AppLovinAdapter();
      RewardResult? result;
      adapter.debugSimulateRewardedShowAndDismiss((r) => result = r);

      expect(result, RewardResult.skipped);
      expect(adapter.rewardedSlot.value, AdSlotState.idle);
    });

    test('show → display-fail leaves slot in cooldown, never stuck showing',
        () {
      final adapter = AppLovinAdapter();
      RewardResult? result;
      adapter.debugSimulateRewardedShowAndDismiss((r) => result = r,
          dismissed: false);

      expect(result, RewardResult.skipped);
      expect(adapter.rewardedSlot.value, AdSlotState.cooldown);
    });

    test('two back-to-back show/dismiss cycles never leave a zombie showing',
        () {
      final adapter = AppLovinAdapter();
      var calls = 0;
      adapter.debugSimulateRewardedShowAndDismiss((_) => calls++);
      adapter.debugSimulateRewardedShowAndDismiss((_) => calls++);

      expect(calls, 2);
      expect(adapter.rewardedSlot.value, AdSlotState.idle);
    });
  });

  group('AdMob interstitial', () {
    test('show → dismiss leaves slot idle, never stuck in showing', () {
      final adapter = AdMobAdapter();
      bool? shown;
      adapter.debugSimulateInterstitialShowAndDismiss((s) => shown = s);

      expect(shown, isTrue);
      expect(adapter.interstitialSlot.value, AdSlotState.idle);
    });

    test('show → display-fail leaves slot in cooldown, never stuck showing',
        () {
      final adapter = AdMobAdapter();
      bool? shown;
      adapter.debugSimulateInterstitialShowAndDismiss((s) => shown = s,
          dismissed: false);

      expect(shown, isFalse);
      expect(adapter.interstitialSlot.value, AdSlotState.cooldown);
    });

    test('two back-to-back show/dismiss cycles never leave a zombie showing',
        () {
      final adapter = AdMobAdapter();
      var calls = 0;
      adapter.debugSimulateInterstitialShowAndDismiss((_) => calls++);
      adapter.debugSimulateInterstitialShowAndDismiss((_) => calls++);

      expect(calls, 2);
      expect(adapter.interstitialSlot.value, AdSlotState.idle);
    });
  });

  group('AdMob rewarded', () {
    test('show → dismiss leaves slot idle, never stuck in showing', () {
      final adapter = AdMobAdapter();
      RewardResult? result;
      adapter.debugSimulateRewardedShowAndDismiss((r) => result = r);

      expect(result, RewardResult.skipped);
      expect(adapter.rewardedSlot.value, AdSlotState.idle);
    });

    test('show → display-fail leaves slot in cooldown, never stuck showing',
        () {
      final adapter = AdMobAdapter();
      RewardResult? result;
      adapter.debugSimulateRewardedShowAndDismiss((r) => result = r,
          dismissed: false);

      expect(result, RewardResult.skipped);
      expect(adapter.rewardedSlot.value, AdSlotState.cooldown);
    });

    test('two back-to-back show/dismiss cycles never leave a zombie showing',
        () {
      final adapter = AdMobAdapter();
      var calls = 0;
      adapter.debugSimulateRewardedShowAndDismiss((_) => calls++);
      adapter.debugSimulateRewardedShowAndDismiss((_) => calls++);

      expect(calls, 2);
      expect(adapter.rewardedSlot.value, AdSlotState.idle);
    });
  });
}
