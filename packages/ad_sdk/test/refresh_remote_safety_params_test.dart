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
}
