// Audit fix (post-T207) — the old device test only called destroy() twice
// on an already-uninitialized manager; it never exercised initialize(),
// load, show, or the background/resume lifecycle callback at all, so the
// "device smoke" claim in the completion doc was far narrower than the task
// (initialize→load→show→background→destroy→reinitialize) actually asks for.
//
// Mirrors the real end-to-end chain added in
// packages/ad_sdk/test/t207_lifecycle_contract_test.dart, run for real on
// a physical device: real initialize() (routed through a FakeAdProviderAdapter
// via debugAdapterFactory, since a real AppLovin/AdMob key isn't committed to
// this repo — see CLAUDE.md), real load/show, the real
// didChangeAppLifecycleState() pause/resume callback, real destroy(), and a
// real reinitialize proving the SDK comes back up clean.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'test',
    interstitialId: 'test',
    rewardedId: 'test',
    appOpenId: 'test',
  ),
  autoRequestUmpConsent: false,
  firstInstallVipGrace: FirstInstallVipGrace.disabled,
  safety: AdSafetyParams(dryRun: true, minSessionDurationBeforeAd: 0),
);

/// codex round-2 fix — counts real onAppPaused()/onAppResumed()
/// invocations so the background/resume dispatch is proven to actually
/// reach the adapter, not just "the manager didn't throw". Same class as
/// packages/ad_sdk/test/t207_lifecycle_contract_test.dart's (duplicated —
/// this file can't import across the package/example boundary).
class _LifecycleCountingAdapter extends FakeAdProviderAdapter {
  int pausedCalls = 0;
  int resumedCalls = 0;

  // codex round-3 fix — AdManager only calls onAppResumed() AFTER
  // _resumeAdWorkAfterConsent's consent re-check settles, which is allowed
  // up to 5s (debugResumeConsentRecheckTimeout/_resumeConsentRecheckTimeout).
  // A fixed 100ms pump was flaky on a real device under real (if unlikely)
  // latency — wait on this signal instead, bounded, rather than a guessed
  // delay.
  final Completer<void> resumed = Completer<void>();

  @override
  void onAppPaused() {
    pausedCalls++;
    super.onAppPaused();
  }

  @override
  void onAppResumed() {
    resumedCalls++;
    if (!resumed.isCompleted) resumed.complete();
    super.onAppResumed();
  }
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
      'T207 device smoke: initialize → load → show → background → '
      'foreground → destroy → reinitialize, end to end', (tester) async {
    final manager = AdManager();
    await manager.destroy();
    // A fresh instance per call — same as the real default factory. Reusing
    // one instance across a destroy()+reinitialize would hand the second
    // initialize() an adapter whose slot notifiers the first destroy()
    // already disposed.
    AdManager.debugAdapterFactory = (_) => _LifecycleCountingAdapter();
    addTearDown(() => AdManager.debugAdapterFactory = null);

    await manager.initialize(config: _config, onComplete: (_, __) {});
    expect(manager.isInitialised, isTrue);
    final firstAdapter = manager.adapter;
    expect(firstAdapter, isNotNull);

    await manager.loadInterstitial();
    expect(firstAdapter!.interstitialSlot.isReady, isTrue);

    var shown = false;
    await manager.showInterstitial(onDoneFlow: (v) => shown = v);
    expect(shown, isTrue);

    // Dispatched through the REAL test binding (codex round-1 fix), not by
    // calling manager.didChangeAppLifecycleState(...) directly — that would
    // still pass even if initialize() never actually registered AdManager
    // via WidgetsBinding.instance.addObserver(this) on the real binding.
    final countingAdapter = firstAdapter as _LifecycleCountingAdapter;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    // codex round-3 fix — onAppResumed() only fires after
    // _resumeAdWorkAfterConsent's consent re-check settles (allowed up to
    // 5s), so wait on the real signal with margin instead of a fixed pump
    // that could legitimately be too short on a slower device.
    await countingAdapter.resumed.future
        .timeout(const Duration(seconds: 10));
    // codex round-2 fix — an observable side effect, not just "didn't throw".
    expect(countingAdapter.pausedCalls, 1);
    expect(countingAdapter.resumedCalls, 1);

    await manager.destroy();
    expect(manager.isInitialised, isFalse);
    expect(manager.adapter, isNull);

    await manager.initialize(config: _config, onComplete: (_, __) {});
    expect(manager.isInitialised, isTrue);
    final secondAdapter = manager.adapter;
    expect(secondAdapter, isNot(same(firstAdapter)));

    await manager.loadInterstitial();
    expect(secondAdapter!.interstitialSlot.isReady, isTrue);

    await manager.destroy();
  });
}
