// Round-26 audit regression (claude, MAJOR — borders BLOCKER): destroy()
// used to tear the adapter down (nulling its native listeners) with no
// regard for a fullscreen ad actively on screen. For AppLovin specifically,
// the native bridge dereferences its listener at dispatch time rather than
// at show-start, so a reward event already in flight when teardown started
// landed on a listener that had just been nulled and was silently dropped —
// a user who finished watching a rewarded ad right as destroy() ran
// (provider switch, logout, SDK reset) was told they earned nothing despite
// watching the whole thing.
//
// This only exercises the shared guard in AdManager._disposeAdapter (see
// _waitForFullscreenShowsToFinish) via a minimal fake adapter — not the real
// AppLovin bridge, which isn't available under `flutter test`.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Only the four fullscreen slots matter here — everything else on
/// [AdProviderAdapter] is routed through `noSuchMethod` since this adapter is
/// never asked to actually load or show anything.
class _SlotOnlyAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);

  bool disposeCalled = false;

  @override
  Future<void> dispose() async => disposeCalled = true;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    AdManager().debugSetAdapter(null);
  });

  test(
      'destroy() waits for a showing rewarded ad to finish before tearing '
      'the adapter down', () async {
    final adapter = _SlotOnlyAdapter();
    adapter.rewardedSlot.state.value = AdSlotState.showing;
    AdManager().debugSetAdapter(adapter);

    var destroyDone = false;
    final destroyFuture = AdManager().destroy().then((_) => destroyDone = true);

    // Give the event loop a few turns — destroy() must still be waiting on
    // the showing rewarded slot, NOT have already nulled the adapter.
    await Future.delayed(const Duration(milliseconds: 50));
    expect(destroyDone, isFalse,
        reason: 'must not tear the adapter down while a rewarded ad is '
            'still showing — that is exactly how the reward event got lost');
    expect(adapter.disposeCalled, isFalse);

    // The "native reward event" finally lands — the real adapter would
    // resolve this via its onReward/onHidden callback, which flips the slot
    // out of `showing`.
    adapter.rewardedSlot.state.value = AdSlotState.idle;

    await destroyFuture.timeout(const Duration(seconds: 2));
    expect(destroyDone, isTrue);
    expect(adapter.disposeCalled, isTrue);
  });

  test(
      'destroy() does not hang forever if a showing slot never resolves '
      '(wedged native SDK)', () async {
    final adapter = _SlotOnlyAdapter();
    adapter.rewardedSlot.state.value = AdSlotState.showing;
    AdManager().debugSetAdapter(adapter);

    // Never flips the slot back — simulates the documented AdMob
    // rewarded-permanently-stuck upstream bug. destroy() must still
    // complete via its bounded drain timeout rather than hang the caller.
    await AdManager().destroy().timeout(const Duration(seconds: 10));
    expect(adapter.disposeCalled, isTrue);
  });
}
