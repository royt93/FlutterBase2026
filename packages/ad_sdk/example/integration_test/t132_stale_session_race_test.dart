// T132 on-device integration test — refreshRemoteSafetyParams() must not let
// a fetch started by session A land on session B's live AdSafetyConfig if a
// real destroy()+initialize() cycle completes while that fetch is still in
// flight. Unit coverage of the same fix lives in
// test/refresh_remote_safety_params_test.dart (fast, deterministic, but
// necessarily drives the race via a debug generation-bump seam rather than a
// real initialize() — see that file's own header for why a real lifecycle
// call in an isolated unit-test file crashes on an unrelated
// google_mobile_ads plugin quirk). This file is the real-lifecycle proof:
// genuine destroy()+initialize() calls, on a real device/simulator, with the
// actual `_initGen` bump that production code produces — not simulated.
//
// Run with:
//   flutter test integration_test/t132_stale_session_race_test.dart -d <device-or-sim-id>

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

/// `initialize()` itself calls `fetchSafetyParamOverrides()` once (T88), so
/// a provider passed straight to `initialize(remoteSafetyProvider: ...)`
/// gets invoked there FIRST, before the test ever calls
/// `refreshRemoteSafetyParams()` explicitly. Round-2 independent review
/// caught exactly this: an earlier version of this test used one delayed
/// provider for both calls, so `initialize()`'s own fetch consumed
/// [fetchStarted] and the explicit refresh's second call threw
/// `StateError: Future already completed` trying to complete it again —
/// caught by `refreshRemoteSafetyParams()`'s own fail-open `catch`, so the
/// test passed without ever reaching the generation-guard code path at all.
///
/// This provider resolves its FIRST call immediately with no override (so
/// `initialize()` proceeds normally, untouched), and only pauses at
/// [fetchStarted] on the SECOND call — the one the test's own explicit
/// `refreshRemoteSafetyParams()` triggers.
class _DelayedOnSecondCallRemoteSafetyProvider
    implements RemoteAdSafetyProvider {
  _DelayedOnSecondCallRemoteSafetyProvider(
      {required this.fetchStarted, required this.releaseWith});
  final Completer<void> fetchStarted;
  final Future<Map<String, dynamic>?> releaseWith;

  int callCount = 0;

  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    callCount++;
    if (callCount == 1) return null;
    fetchStarted.complete();
    return releaseWith;
  }
}

AdConfig _config({required int maxFullscreenAdsPerDay}) => AdConfig(
      provider: AdProvider.admob,
      admob: const AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      safety: AdSafetyParams(
          dryRun: true, maxFullscreenAdsPerDay: maxFullscreenAdsPerDay),
    );

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() async {
    await AdManager().destroy();
  });

  testWidgets(
      'a refresh fetch started by session A discards its override instead '
      'of stomping session B, which really destroy()+initialize()d for '
      'real while that fetch was in flight', (tester) async {
    final fetchStarted = Completer<void>();
    final releaseFetch = Completer<Map<String, dynamic>?>();
    final provider = _DelayedOnSecondCallRemoteSafetyProvider(
      fetchStarted: fetchStarted,
      releaseWith: releaseFetch.future,
    );

    // Session A — real init. `initialize()` itself calls
    // `fetchSafetyParamOverrides()` once (T88) — that's this provider's
    // FIRST call, resolved immediately with no override, so init proceeds
    // normally and `fetchStarted` is untouched.
    await AdManager().initialize(
      config: _config(maxFullscreenAdsPerDay: 999),
      remoteSafetyProvider: provider,
      onComplete: (_, _) {},
    );
    await tester.pump(const Duration(milliseconds: 300));
    expect(provider.callCount, 1,
        reason: 'sanity: initialize() must have made exactly its own one '
            'call before the explicit refresh below makes its second');

    // The test's own explicit refresh — this is the provider's SECOND call,
    // the one that actually pauses at fetchStarted.
    final refreshFuture = AdManager().refreshRemoteSafetyParams();
    await fetchStarted.future;
    await tester.pump();
    expect(provider.callCount, 2,
        reason: 'sanity: the explicit refresh above must be in flight on '
            'its own (second) fetch call, not still on initialize()\'s');

    // Real destroy()+initialize() into session B, completing for real
    // (genuine `_initGen` bump from production code) WHILE the fetch above
    // is still suspended — the exact interleaving T132 is about.
    await AdManager().destroy();
    await AdManager().initialize(
      config: _config(maxFullscreenAdsPerDay: 5),
      onComplete: (_, _) {},
    );
    await tester.pump(const Duration(milliseconds: 300));

    // Now let session A's stale fetch resolve, with an override that would
    // be very obviously wrong if it landed on session B.
    releaseFetch.complete({'maxFullscreenAdsPerDay': 1});
    await refreshFuture;
    await tester.pump(const Duration(milliseconds: 300));

    expect(tester.takeException(), isNull);
    expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 5,
        reason: 'session A\'s stale fetch resolved after session B (a real '
            'destroy()+initialize() cycle) was already live — its override '
            'must be discarded, not merged onto session B\'s AdSafetyConfig');
  });
}
