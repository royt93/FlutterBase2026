import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

/// Audit fix (post-T211) — the original tests only asserted the slot's
/// end state (`isReady`/`isCooldown`) after concurrent calls. That end
/// state is IDENTICAL whether `AdManager`'s `_coalesceAdLoad` actually
/// joined the calls into one native request or just let both through:
/// `FakeAdProviderAdapter`'s own `AdSlot.beginLoad()` guard already makes
/// a second concurrent call to the SAME slot a no-op (`isLoading` true),
/// so the tests passed regardless of whether the manager-level
/// coalescing map (`_inFlightAdLoads`) did anything at all. This counts
/// real invocations of the adapter's load methods to prove coalescing —
/// not just the slot's own guard — is what limits the native call count.
class _CountingAdapter extends FakeAdProviderAdapter {
  _CountingAdapter({super.shouldSucceed, super.loadDelay});
  int interstitialLoadCalls = 0;
  int rewardedLoadCalls = 0;

  @override
  Future<void> loadInterstitial() {
    interstitialLoadCalls++;
    return super.loadInterstitial();
  }

  @override
  Future<void> loadRewarded() {
    rewardedLoadCalls++;
    return super.loadRewarded();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _CountingAdapter adapter;

  setUp(() {
    adapter = _CountingAdapter();
    final manager = AdManager();
    manager.debugResetGuardState();
    manager.debugSetAdapter(adapter);
    manager.debugCanRequestAds = true;
  });

  tearDown(() {
    AdManager().debugResetGuardState();
    AdManager().debugSetAdapter(null);
  });

  test('concurrent interstitial loads issue exactly one native request',
      () async {
    await Future.wait(
        [AdManager().loadInterstitial(), AdManager().loadInterstitial()]);
    expect(adapter.interstitialLoadCalls, 1);
    expect(adapter.interstitialSlot.isReady, isTrue);
  });

  test(
      'three-way concurrent interstitial loads still issue exactly one '
      'native request', () async {
    await Future.wait([
      AdManager().loadInterstitial(),
      AdManager().loadInterstitial(),
      AdManager().loadInterstitial(),
    ]);
    expect(adapter.interstitialLoadCalls, 1);
  });

  test('failed request is removed from coalescing map and a retry issues a '
      'second real native request', () async {
    adapter = _CountingAdapter(shouldSucceed: false);
    AdManager().debugSetAdapter(adapter);
    await AdManager().loadRewardedAd();
    expect(adapter.rewardedLoadCalls, 1);
    expect(adapter.rewardedSlot.isCooldown, isTrue);

    await AdManager().loadRewardedAd();
    expect(adapter.rewardedLoadCalls, 2,
        reason: 'a retry after failure must not join a stale coalesced '
            'future — it needs a fresh native request');
  });

  test(
      'a coalesced load in flight is invalidated by destroy()/reinit — a '
      'load started right after reset issues a fresh native request '
      'instead of joining the still-pending stale one', () async {
    adapter = _CountingAdapter(loadDelay: const Duration(milliseconds: 50));
    AdManager().debugSetAdapter(adapter);
    final stale = AdManager().loadInterstitial();
    // codex round-1 fix — start the second load WHILE the first is still
    // pending (not after awaiting it), otherwise the first future's own
    // normal whenComplete cleanup already removes the map entry by the
    // time the second load runs, and this test would pass even if
    // debugResetGuardState() stopped invalidating anything at all.
    AdManager().debugResetGuardState();
    final fresh = AdManager().loadInterstitial();
    await Future.wait([stale, fresh]);
    expect(adapter.interstitialLoadCalls, 2,
        reason: 'after debugResetGuardState() invalidates the in-flight '
            'coalesced future (same path destroy()/reinit use), a load '
            'call issued while the stale one is still pending must start '
            'a fresh native request rather than silently joining it');
  });
}
