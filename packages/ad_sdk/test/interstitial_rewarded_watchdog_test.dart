// Unit-test coverage for the Interstitial/Rewarded show/dismiss state
// machine via the `debugSimulate*ShowAndDismiss` test seams, which drive
// `AdSlot.beginShow()` WITHOUT a `onShowNeverConfirmed` watchdog (see each
// seam's own doc comment) — deliberately, to isolate the plain
// `beginShow() → [native callback] → markDismissed()/markShowFailed()`
// transition from watchdog timing. The state machine under test here is:
//
//   beginShow() → [native callback] → markDismissed() / markShowFailed()
//
// with a one-shot done-callback (`_interstitialDone` / `_rewardedDone`) that
// must never leave the slot stuck in `AdSlotState.showing` (a "zombie"
// state) — the same bug class that was fixed for App Open.
//
// Audit round 42 correction — this file used to claim, incorrectly, that
// there is "NO watchdog/timer for these two slots" at all in production and
// that a late-callback race here "cannot occur in the real code path." That
// was wrong: `AppLovinAdapter.showInterstitial`/`showRewarded` DO call
// `AdSlot.beginShow(onShowNeverConfirmed: ...)` (Round-7 audit fix — see
// `AdSlot.beginShow`'s doc comment), arming the same 10s
// `AdSlot.showConfirmTimeout` watchdog App Open's own mechanism is built
// around. The confusion was between two DIFFERENT claims: (a) there is no
// App-Open-style LOAD watchdog for these two formats (still true, and still
// a deliberate choice — see `debugSimulateInterstitialShowAndDismiss`'s own
// "R10-E" doc comment, about load hangs, not show confirmation) versus (b)
// there is no SHOW-confirmation watchdog at all (false). A real late-
// callback race through that show-confirmation watchdog is exactly what let
// a stale cycle's ambiguous-creativeId reward event misattribute to a newer
// cycle's caller — see `applovin_adapter_test.dart`'s
// "audit round 42: stale-callback quarantine" group for the coverage this
// file's old comment incorrectly said could not exist.

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
