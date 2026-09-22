// T111 regression: AdManager.refreshRemoteSafetyParams() lets a host
// re-fetch RemoteAdSafetyProvider overrides without a full
// destroy()+initialize() cycle (mirrors VipManager.refreshRevocationList's
// fail-open contract).
//
// Deliberately drives this through the debugSetAdapter/debugConfig test
// seams rather than a real AdManager().initialize() — refreshRemoteSafetyParams
// itself only touches _remoteSafetyProvider/_config/AdSafetyConfig, never the
// adapter, so a real AdMobAdapter.initialize() is unnecessary weight here.
// It also sidesteps a real `google_mobile_ads` plugin quirk this ticket ran
// into while writing the test: `MobileAds._instance` fires an un-awaited
// `channel.invokeMethod('_init')` the first time anything in the isolate
// touches `MobileAds.instance`, and in a small isolated file (unlike
// ad_manager_core_test.dart, where dozens of earlier tests already touched
// it) that first touch reliably raced `AdInstanceManager.initialize()`'s own
// setup and crashed with a null-check — unrelated to this ticket's logic.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeRemoteSafetyProvider implements RemoteAdSafetyProvider {
  _FakeRemoteSafetyProvider(this._overrides);
  final Map<String, dynamic> _overrides;
  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async =>
      _overrides;
}

class _ThrowingRemoteSafetyProvider implements RemoteAdSafetyProvider {
  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    throw StateError('simulated network failure');
  }
}

/// T132 — a provider whose fetch pauses at [fetchStarted] until [releaseWith]
/// completes, so a test can deterministically land a `destroy()`+
/// `initialize()` cycle (simulated via `debugBumpInitGen()`) exactly inside
/// the await window `refreshRemoteSafetyParams()` is waiting on.
class _DelayedRemoteSafetyProvider implements RemoteAdSafetyProvider {
  _DelayedRemoteSafetyProvider(
      {required this.fetchStarted, required this.releaseWith});
  final Completer<void> fetchStarted;
  final Future<Map<String, dynamic>?> releaseWith;

  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async {
    fetchStarted.complete();
    return releaseWith;
  }
}

/// Only the four fullscreen slots matter — debugSetAdapter() wires busy-state
/// listeners onto every one of them (AdManager._attachFullscreenBusySlotListeners).
/// Everything else on [AdProviderAdapter] is routed through `noSuchMethod`
/// since refreshRemoteSafetyParams() never calls into the adapter itself.
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

  @override
  Future<void> dispose() async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
    bannerId: 'ca-app-pub-3940256099942544/6300978111',
    interstitialId: 'ca-app-pub-3940256099942544/1033173712',
    appOpenId: 'ca-app-pub-3940256099942544/9257395921',
    rewardedId: 'ca-app-pub-3940256099942544/5224354917',
  ),
  safety: AdSafetyParams(dryRun: true),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  /// Drives AdManager into a state refreshRemoteSafetyParams() can act on
  /// (_config + _remoteSafetyProvider set, adapter present, AdSafetyConfig
  /// cold-started against a real — mocked — AdPreferences so
  /// dailyCapReached()'s persisted-count read has something to compare
  /// against) without touching the real ad adapter.
  Future<void> wireUp(RemoteAdSafetyProvider provider) async {
    // T137 — AdPreferences caches its instance across the whole file run;
    // without this reset, `setMockInitialValues({})` below replaces the
    // MOCK STORE's backing data, but the already-initialized AdPreferences
    // singleton (obtained by an earlier test in this file) keeps its OLD
    // in-memory reads for anything not re-fetched (e.g. the persisted
    // remote-safety revision), leaking that state across otherwise
    // independent tests.
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await AdSafetyConfig.init(prefs, params: _config.safety, isRelease: false);
    AdManager().debugSetAdapter(_SlotOnlyAdapter());
    AdManager().debugConfig = _config;
    AdManager().debugRemoteSafetyProvider = provider;
  }

  tearDown(() {
    AdManager().debugSetAdapter(null);
    AdManager().debugConfig = null;
    AdManager().debugRemoteSafetyProvider = null;
    AdManager().debugLastAppliedRemoteSafetyRevision = null;
    AdSafetyConfig.updateParams(const AdSafetyParams());
  });

  test(
      'refreshRemoteSafetyParams() applies NEW overrides live, without a '
      'full destroy()+initialize() cycle', () async {
    await wireUp(_FakeRemoteSafetyProvider({'maxFullscreenAdsPerDay': 999}));
    await AdManager().refreshRemoteSafetyParams();
    AdSafetyConfig.recordFullscreenAdShown();
    expect(AdSafetyConfig.dailyCapReached(), isFalse,
        reason: 'sanity: the loose 999/day override must not already be '
            'capped after 1 show');

    // Swap in a stricter provider WITHOUT re-initialising — proves the
    // refresh path genuinely re-fetches rather than re-applying whatever
    // was set before.
    AdManager().debugRemoteSafetyProvider =
        _FakeRemoteSafetyProvider({'maxFullscreenAdsPerDay': 1});
    await AdManager().refreshRemoteSafetyParams();

    expect(AdSafetyConfig.dailyCapReached(), isTrue,
        reason: 'the new 1/day override must take effect live — the '
            'already-shown ad from before the refresh now exceeds it');
    expect(AdManager().isInitialised, isTrue,
        reason: 'refreshRemoteSafetyParams must not tear down or re-create '
            'the adapter — that is exactly the "full cycle" cost this '
            'ticket removes');
  });

  test(
      'a throwing provider on refresh leaves the currently-applied params '
      'untouched (fail-open)', () async {
    await wireUp(_FakeRemoteSafetyProvider({'maxFullscreenAdsPerDay': 1}));
    await AdManager().refreshRemoteSafetyParams();
    AdSafetyConfig.recordFullscreenAdShown();
    expect(AdSafetyConfig.dailyCapReached(), isTrue,
        reason: 'sanity: the 1/day override must already be live');

    AdManager().debugRemoteSafetyProvider = _ThrowingRemoteSafetyProvider();
    await AdManager().refreshRemoteSafetyParams();

    expect(AdSafetyConfig.dailyCapReached(), isTrue,
        reason: 'a throwing refresh must fail open — the cap applied '
            'before must survive, not silently reset to local defaults');
  });

  test('no-op when no remoteSafetyProvider has ever been set', () async {
    // Must not throw even though nothing was ever wired up.
    await AdManager().refreshRemoteSafetyParams();
  });

  // Round-31 audit (MAJOR) — initialize() wraps applyRemoteSafetyOverrides()
  // in a try/catch; this method did not. A malformed numeric field (e.g.
  // `Infinity`, which `posInt()` used to crash on via `double.toInt()`)
  // would escape this method uncaught instead of falling back to "keep
  // current params" like the class doc promises and every other malformed
  // field already does. Exercises both this method's try/catch AND
  // posInt()'s own Infinity fix together — proves no crash escapes either
  // way.
  test(
      'a malformed numeric override (Infinity) on refresh does not throw',
      () async {
    await wireUp(_FakeRemoteSafetyProvider(
        {'maxFullscreenAdsPerDay': double.infinity}));
    // Before the fix, `posInt()` threw `UnsupportedError` on `Infinity`
    // from inside the try-less second half of this method — an uncaught
    // exception escaping an async method surfaces as the returned Future
    // completing with an error, which `completes` (as opposed to
    // `completion`/a bare await) specifically fails on.
    await expectLater(AdManager().refreshRemoteSafetyParams(), completes);
  });

  // Round-30 audit (MAJOR) — refreshRemoteSafetyParams() used to merge
  // remote overrides onto the raw config.safety, silently reverting every
  // field a safetyRampSchedule stage had adjusted (but the remote payload
  // doesn't mention) back to day-0 config on every refresh.
  test(
      'refresh preserves the safetyRampSchedule stage for fields the '
      'remote override does not touch', () async {
    final rampedConfig = AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'ca-app-pub-3940256099942544/6300978111',
        interstitialId: 'ca-app-pub-3940256099942544/1033173712',
        appOpenId: 'ca-app-pub-3940256099942544/9257395921',
        rewardedId: 'ca-app-pub-3940256099942544/5224354917',
      ),
      // Day-0 default is loose (999/day); the ramp should have long since
      // moved this device to the strict 1/day stage by the time it's 10
      // days old.
      safety: AdSafetyParams(dryRun: true, maxFullscreenAdsPerDay: 999),
      safetyRampSchedule: {
        Duration.zero: AdSafetyParams(dryRun: true, maxFullscreenAdsPerDay: 999),
        Duration(days: 7):
            AdSafetyParams(dryRun: true, maxFullscreenAdsPerDay: 1),
      },
    );

    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await prefs.setFirstInstallAtMsIfMissing(
        DateTime.now().subtract(const Duration(days: 10)).millisecondsSinceEpoch);
    // Simulates the state a real initialize() call would have correctly left
    // behind: this device is 10 days old, so the ramp's day-7 stage (1/day)
    // is already in effect — that part of the pipeline isn't the bug.
    await AdSafetyConfig.init(prefs,
        params: const AdSafetyParams(dryRun: true, maxFullscreenAdsPerDay: 1),
        isRelease: false);
    AdManager().debugSetAdapter(_SlotOnlyAdapter());
    AdManager().debugConfig = rampedConfig;
    // Override a field the ramp doesn't touch — `maxFullscreenAdsPerDay`
    // must still come from the day-10 ramp stage (1), not the raw
    // config.safety default (999) this bug used to fall back to.
    AdManager().debugRemoteSafetyProvider =
        _FakeRemoteSafetyProvider({'maxClicksPerMinute': 5});

    await AdManager().refreshRemoteSafetyParams();

    AdSafetyConfig.recordFullscreenAdShown();
    expect(AdSafetyConfig.dailyCapReached(), isTrue,
        reason: 'the ramp stage (1/day for a 10-day-old device) must '
            'survive a refresh whose override never mentions '
            'maxFullscreenAdsPerDay — falling back to the raw config\'s '
            '999/day would silently undo the ramp');
  });

  // T132 regression — a slow fetch that is still in flight when a
  // destroy()+initialize() cycle completes must discard its now-stale
  // result instead of stomping the new session's live AdSafetyConfig with a
  // baseline computed from the OLD session's config.
  test(
      'a refresh superseded mid-fetch (new session initialized while '
      'fetching) discards its stale override instead of applying it',
      () async {
    await wireUp(_FakeRemoteSafetyProvider({}));

    final fetchStarted = Completer<void>();
    final releaseFetch = Completer<Map<String, dynamic>?>();
    AdManager().debugRemoteSafetyProvider = _DelayedRemoteSafetyProvider(
      fetchStarted: fetchStarted,
      releaseWith: releaseFetch.future,
    );

    final refreshFuture = AdManager().refreshRemoteSafetyParams();
    await fetchStarted.future;

    // Simulate destroy()+initialize() completing a NEW session while the
    // fetch above is still in flight — the only observable state change a
    // real cycle leaves behind that this method's guard can see.
    AdManager().debugBumpInitGen();

    // Now let the stale fetch resolve, with an override that would be very
    // obviously wrong if it landed (drops the cap to 1/day).
    releaseFetch.complete({'maxFullscreenAdsPerDay': 1});
    await refreshFuture;

    expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 5,
        reason: 'the fetch belonged to a session that no longer exists by '
            'the time it resolved — its override must be discarded, not '
            'merged onto the live AdSafetyConfig the NEW session is using');
  });

  // Round-72 audit fix (MAJOR, gemini external) — debugBumpInitGen() is a
  // plain method, not a setter, so it cannot be gated the way
  // debugSetAdapter/debugConfig etc. are; the guard lives inside the method
  // body instead. Proven here through the exact same stale-fetch scenario
  // above, inverted: with the seam blocked the bump must be a true no-op, so
  // the "new session" guard never trips and the stale fetch's override lands
  // unmodified — the same bug the test above exists to catch, reintroduced
  // deliberately to prove the seam-block itself, not the guard it wraps.
  test(
      'debugBumpInitGen is ignored while release mode is simulated — a '
      'stale fetch is no longer detected', () async {
    await wireUp(_FakeRemoteSafetyProvider({}));

    final fetchStarted = Completer<void>();
    final releaseFetch = Completer<Map<String, dynamic>?>();
    AdManager().debugRemoteSafetyProvider = _DelayedRemoteSafetyProvider(
      fetchStarted: fetchStarted,
      releaseWith: releaseFetch.future,
    );

    final refreshFuture = AdManager().refreshRemoteSafetyParams();
    await fetchStarted.future;

    AdManager.debugSimulateReleaseModeForTestSeams = true;
    addTearDown(() => AdManager.debugSimulateReleaseModeForTestSeams = false);
    AdManager().debugBumpInitGen(); // must be a no-op while blocked

    releaseFetch.complete({'maxFullscreenAdsPerDay': 1});
    await refreshFuture;

    expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 1,
        reason: 'debugBumpInitGen must not apply in a (simulated) release '
            'build — proven by the generation guard NOT tripping, so the '
            'stale override lands same as it would with no bump call at '
            'all (the exact regression the un-blocked seam exists to '
            'catch, seen here through the seam-block\'s own absence)');
  });

  // ─────────────────────────────────────────────────
  // T137 — revision-guard (rollback protection)
  // ─────────────────────────────────────────────────
  group('revision guard (T137)', () {
    test('no revision key — always applies, unchanged from pre-T137 behavior',
        () async {
      await wireUp(
          _FakeRemoteSafetyProvider({'maxFullscreenAdsPerDay': 1}));

      await AdManager().refreshRemoteSafetyParams();

      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 1);
    });

    test('a revision higher than nothing-applied-yet is accepted and '
        'persisted', () async {
      await wireUp(_FakeRemoteSafetyProvider(
          {'maxFullscreenAdsPerDay': 1, 'revision': 5}));

      await AdManager().refreshRemoteSafetyParams();

      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 1);
      final prefs = await AdPreferences.getInstance();
      expect(prefs.getRemoteSafetyRevision(), 5);
    });

    test('a revision strictly lower than the last applied one is rejected — '
        'the whole payload is discarded, not just the revision field',
        () async {
      await wireUp(_FakeRemoteSafetyProvider(
          {'maxFullscreenAdsPerDay': 1, 'revision': 10}));
      await AdManager().refreshRemoteSafetyParams();
      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 1,
          reason: 'sanity: revision 10 applied first');

      AdManager().debugRemoteSafetyProvider = _FakeRemoteSafetyProvider(
          {'maxFullscreenAdsPerDay': 999, 'revision': 3});
      await AdManager().refreshRemoteSafetyParams();

      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 1,
          reason: 'revision 3 is older than the already-applied 10 — the '
              'whole payload (including maxFullscreenAdsPerDay: 999) must '
              'be discarded');
      final prefs = await AdPreferences.getInstance();
      expect(prefs.getRemoteSafetyRevision(), 10,
          reason: 'the rejected payload must not overwrite the persisted '
              'revision either');
    });

    test('a revision equal to the last applied one is still accepted '
        '(only STRICTLY older is rejected)', () async {
      await wireUp(_FakeRemoteSafetyProvider(
          {'maxFullscreenAdsPerDay': 1, 'revision': 7}));
      await AdManager().refreshRemoteSafetyParams();

      AdManager().debugRemoteSafetyProvider = _FakeRemoteSafetyProvider(
          {'maxFullscreenAdsPerDay': 2, 'revision': 7});
      await AdManager().refreshRemoteSafetyParams();

      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 2);
    });

    // Round-2 independent adversarial review (BLOCKING) — the guard used
    // to be `async`, checking the persisted revision then `await`-ing a
    // write before the caller separately `await`-ed its own apply. Two
    // overlapping refreshes could both pass the check before either
    // write landed, and whichever one's async tail finished LAST won —
    // regardless of which revision was actually newer. This test pins the
    // exact scenario the review described: an OLDER revision's fetch
    // resolving AFTER a NEWER one already applied must not roll it back.
    test(
        'overlapping refreshes: an older revision whose fetch resolves '
        'LAST does not roll back a newer one that already applied',
        () async {
      await wireUp(_FakeRemoteSafetyProvider({}));

      final oldFetchStarted = Completer<void>();
      final oldRelease = Completer<Map<String, dynamic>?>();
      AdManager().debugRemoteSafetyProvider = _DelayedRemoteSafetyProvider(
          fetchStarted: oldFetchStarted, releaseWith: oldRelease.future);
      // Captures this (soon-to-be-stale) provider synchronously, before
      // the newer refresh below ever runs — the real shape of "a periodic
      // tick's fetch is still in flight when a manual/newer one lands".
      final oldRefresh = AdManager().refreshRemoteSafetyParams();
      await oldFetchStarted.future;

      // The "newer" refresh — a different provider captured synchronously
      // by ITS OWN call, resolves immediately (no Completer to wait on).
      AdManager().debugRemoteSafetyProvider = _FakeRemoteSafetyProvider(
          {'maxFullscreenAdsPerDay': 2, 'revision': 10});
      await AdManager().refreshRemoteSafetyParams();
      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 2,
          reason: 'sanity: the newer refresh (revision 10) applied first');

      // Now let the OLDER (revision 3) fetch resolve — its own guard check
      // must see revision 10 already applied (in-memory, synchronously)
      // and reject itself, even though its fetch happens to finish AFTER
      // the newer one's.
      oldRelease.complete({'maxFullscreenAdsPerDay': 999, 'revision': 3});
      await oldRefresh;

      expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 2,
          reason: 'the older (revision 3) refresh resolving AFTER the '
              'newer (revision 10) one must not roll back the live '
              'AdSafetyConfig');
    });

    // Round-2 independent adversarial review (MINOR) — the ticket
    // explicitly asks for malformed-value tests on every new field, same
    // spirit as `posInt`/`unitDouble`'s own tests elsewhere in this file.
    test('a malformed (non-int) revision is treated as absent — legacy '
        'always-apply behavior, does not touch the persisted revision',
        () async {
      for (final malformed in <Object?>[
        'not-a-number',
        3.5,
        true,
        null,
      ]) {
        await wireUp(_FakeRemoteSafetyProvider(
            {'maxFullscreenAdsPerDay': 1, 'revision': malformed}));

        await AdManager().refreshRemoteSafetyParams();

        expect(AdSafetyConfig.getStatusSnapshot().maxFullscreenAdsPerDay, 1,
            reason: 'malformed revision $malformed must still always-apply');
        final prefs = await AdPreferences.getInstance();
        expect(prefs.getRemoteSafetyRevision(), isNull,
            reason: 'a malformed revision must never be persisted as if '
                'it were a real one');
      }
    });
  });
}
