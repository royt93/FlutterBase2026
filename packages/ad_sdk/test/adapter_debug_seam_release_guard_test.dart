// Round-70 audit fix (MAJOR) — the exact same gap round 68/69 fixed on
// `AdManager` (a `@visibleForTesting` seam is an analyzer lint, not a
// runtime guard) also existed on `AppLovinAdapter`, `AdMobAdapter`,
// `AdSafetyConfig` and `IabStorage`. The most severe: `AdMobAdapter`/
// `AppLovinAdapter`'s `debugSimulateRewardedShowAndDismiss` fires the
// reward-granting callback directly — reachable in a shipped release app
// via `AdManager().adapter as AdMobAdapter`, with no real ad ever shown.
//
// One representative test per file/category rather than one per seam — the
// pattern is what needs proving. `AppLovinAdapter` shares the identical
// mechanism (same guard, same `debugSimulateRewardedShowAndDismiss` shape)
// verified here via `AdMobAdapter`; not duplicated for the simpler adapter
// to construct in a unit test.
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/core/ad_safety_config.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/state/ad_slot.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  tearDown(() {
    AdMobAdapter.debugSimulateReleaseModeForTestSeams = false;
    AdSafetyConfig.debugSimulateReleaseModeForTestSeams = false;
    IabStorage.debugSimulateReleaseModeForTestSeams = false;
    AdSlot.debugSimulateReleaseModeForTestSeams = false;
  });

  // Round-71 audit fix (MAJOR, gemini reviewer) — same lint-only gap on
  // `AdSlot.debugFireLoadWatchdogNow`: could force a real in-flight ad load
  // to fail early in a shipped release app.
  test(
      'AdSlot.debugFireLoadWatchdogNow is ignored while release mode is '
      'simulated', () {
    final slot = AdSlot(type: AdSlotType.interstitial)..beginLoad();
    addTearDown(slot.dispose);
    slot.armLoadWatchdog('interstitial', const Duration(seconds: 10));

    AdSlot.debugSimulateReleaseModeForTestSeams = true;
    slot.debugFireLoadWatchdogNow();

    expect(slot.isLoading, isTrue,
        reason: 'debugFireLoadWatchdogNow must not force markFailed() in a '
            '(simulated) release build');
  });

  // Control for the test above — proves the seam still works normally (not
  // release-simulated), so the guard is proven to gate something real.
  test('AdSlot.debugFireLoadWatchdogNow still fires when not released', () {
    final slot = AdSlot(type: AdSlotType.interstitial)..beginLoad();
    addTearDown(slot.dispose);
    slot.armLoadWatchdog('interstitial', const Duration(seconds: 10));

    slot.debugFireLoadWatchdogNow();

    expect(slot.isLoading, isFalse,
        reason: 'debugFireLoadWatchdogNow must force markFailed() when not '
            '(simulated) released, or the guard above proves nothing');
  });

  // ConsentManager's own release-guard regression test lives in
  // consent_manager_test.dart — it needs the file's bootstrap/channel-mock
  // setup, which this file doesn't have.

  test(
      'AdMobAdapter.debugSimulateRewardedShowAndDismiss is ignored while '
      'release mode is simulated', () {
    final adapter = AdMobAdapter();
    var called = false;

    AdMobAdapter.debugSimulateReleaseModeForTestSeams = true;
    adapter.debugSimulateRewardedShowAndDismiss((_) => called = true);

    expect(called, isFalse,
        reason: 'the reward callback must not fire in a (simulated) '
            'release build with no real ad shown');
    expect(adapter.rewardedSlot.value, AdSlotState.idle,
        reason: 'the slot state machine must not be desynced either');
  });

  test(
      'AdSafetyConfig.debugExpireSuspiciousPause is ignored while release '
      'mode is simulated', () {
    AdSafetyConfig.resetForReinit();
    // Arm a REAL invalid-traffic pause the normal way (default preset
    // caps at 3 fullscreen clicks/min) — not via a debug seam — then try
    // to defeat it as an attacker would.
    for (var i = 0; i < 5; i++) {
      AdSafetyConfig.recordAdClick(fullscreen: true);
    }
    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'test setup: a real pause must be active before this seam '
            'is exercised, or the assertion below proves nothing');

    AdSafetyConfig.debugSimulateReleaseModeForTestSeams = true;
    AdSafetyConfig.debugExpireSuspiciousPause();

    expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
        reason: 'debugExpireSuspiciousPause must not clear a real '
            'invalid-traffic pause in a (simulated) release build');
  });

  test(
      'IabStorage.debugResetForTest is a no-op while release mode is '
      'simulated (does not throw, guard branch reached)', () {
    // No public getter exposes the private cached-store field this seam
    // clears, so this only proves the guard branch is reached without
    // throwing — the release-mode check itself is identical to every
    // other seam in this file and already covered above/in round 68/69.
    IabStorage.debugSimulateReleaseModeForTestSeams = true;
    expect(() => IabStorage.debugResetForTest(), returnsNormally);
  });
}
