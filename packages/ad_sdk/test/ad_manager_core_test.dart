// Behavioral unit tests for the AdManager orchestrator core, driven through the
// @visibleForTesting seams (debugSetAdapter / debugVipManager / debugEmit /
// releaseFootgunWarnings) so the gating logic is exercised WITHOUT the native
// AppLovin/AdMob plugins.
//
// Covered:
//   1. releaseFootgunWarnings — the loud release-build guards (dryRun, AdMob
//      Google test IDs in release) as a pure function.
//   2. VIP gating — every public load/show/canShow path must short-circuit when
//      a VIP entry is active (the SDK's "VIP suppresses all ad surfaces"
//      contract), including the documented canShowRewardedAd()==true quirk.
//   3. RevenuePanel — a real consumer of AdManager().events: feeding
//      AdRevenueEvents through debugEmit must accumulate on screen.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so VIP tests don't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

/// `MobileAds._instance` is a lazily-initialized static field that fires an
/// un-awaited `channel.invokeMethod('_init')` the first time anything in this
/// isolate touches `MobileAds.instance`. Without a mock handler that call
/// throws an uncaught async MissingPluginException that attaches to whatever
/// test happens to be running at that moment — not necessarily the one whose
/// code path triggered it. The re-init guard tests below legitimately reach
/// real `AdMobAdapter.initialize()` on the second `AdManager().initialize()`
/// call, so this mock must be installed before any test runs.
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

/// Tracks whether [dispose] ran, to prove a stale VipManager is torn down
/// (not just detached) on AdManager re-init — see the "re-init disposes the
/// previous VipManager" test.
class _DisposeTrackingVipManager extends VipManager {
  _DisposeTrackingVipManager(super.prefs, {super.vipEntriesStore});

  bool disposed = false;

  @override
  void dispose() {
    disposed = true;
    super.dispose();
  }
}

/// Minimal fake adapter: real slots (so the non-VIP slot reads work) and call
/// counters for the load/show paths. Everything else is routed through
/// noSuchMethod — these tests never touch the rest of the surface.
class _FakeAdapter implements AdProviderAdapter {
  @override
  final AdSlot appOpenSlot = AdSlot(type: AdSlotType.appOpen);
  @override
  final AdSlot interstitialSlot = AdSlot(type: AdSlotType.interstitial);
  @override
  final AdSlot rewardedSlot = AdSlot(type: AdSlotType.rewarded);
  @override
  final AdSlot bannerSlot = AdSlot(type: AdSlotType.banner);

  int loadInterstitialCalls = 0;
  int showInterstitialCalls = 0;
  int loadRewardedCalls = 0;
  int showRewardedCalls = 0;

  /// When true, [loadRewarded] simulates a successful async load by flipping
  /// the slot to `ready`. Drives the VIP-bypass on-demand load path.
  /// Default false = load never makes the slot ready.
  bool loadMarksReady = false;

  /// When true, [loadRewarded] begins loading (slot → `loading`) but never
  /// resolves — simulates a slow load so the on-demand wait stays in flight.
  bool hangLoad = false;

  /// What [showRewarded] reports back via `onDone`.
  bool nextRewardEarned = true;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    onDone(true);
  }

  @override
  Future<void> loadRewarded() async {
    loadRewardedCalls++;
    if (hangLoad) {
      rewardedSlot.beginReload(); // → loading, never resolves
      return;
    }
    if (loadMarksReady) {
      rewardedSlot.beginReload();
      rewardedSlot.markReady();
    }
  }

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(nextRewardEarned
        ? const RewardResult(earned: true, label: 'coins', amount: 1)
        : RewardResult.skipped);
  }

  int loadAppOpenCalls = 0;
  int showAppOpenCalls = 0;

  /// When true, [loadAppOpen] simulates a successful load (slot → ready).
  bool appOpenLoadMarksReady = false;

  @override
  Future<void> loadAppOpen({void Function(bool loaded)? onAdLoaded}) async {
    loadAppOpenCalls++;
    if (appOpenLoadMarksReady) {
      appOpenSlot.beginReload();
      appOpenSlot.markReady();
    }
    onAdLoaded?.call(appOpenLoadMarksReady);
  }

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    showAppOpenCalls++;
    appOpenSlot.beginShow();
    appOpenSlot.markDismissed();
    onDismiss(true);
  }

  @override
  Future<void> dispose() async {}

  int onAppPausedCalls = 0;
  int onAppResumedCalls = 0;

  /// When true, [onAppPaused]/[onAppResumed] throw — proves
  /// didChangeAppLifecycleState's try/catch swallows adapter exceptions.
  bool throwOnLifecycle = false;

  @override
  void onAppPaused() {
    onAppPausedCalls++;
    if (throwOnLifecycle) throw StateError('fake onAppPaused failure');
  }

  @override
  void onAppResumed() {
    onAppResumedCalls++;
    if (throwOnLifecycle) throw StateError('fake onAppResumed failure');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Fake VipManager whose `isActive` is fixed — the only member AdManager reads
/// for gating (`_isVipMember => _vipManager?.isActive ?? false`).
class _FakeVip implements VipManager {
  _FakeVip(this._active);
  final bool _active;

  @override
  bool get isActive => _active;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Minimal [PopupRoute] to drive [AdScreenRouteLogger.isDialogOnTop] without a
/// real dialog widget tree — mirrors the private helper in
/// ad_route_observer_test.dart.
class _FakePopupRoute extends PopupRoute<void> {
  @override
  Color? get barrierColor => null;

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => null;

  @override
  Widget buildPage(BuildContext context, Animation<double> animation,
          Animation<double> secondaryAnimation) =>
      const SizedBox.shrink();

  @override
  Duration get transitionDuration => Duration.zero;
}

AdConfig _admobConfig({
  required bool dryRun,
  required bool testIds,
  AppOpenTrigger appOpenTrigger = AppOpenTrigger.both,
  FirstInstallVipGrace firstInstallVipGrace = FirstInstallVipGrace.auto,
}) {
  const realPrefix = 'ca-app-pub-9999999999999999';
  const testPrefix = 'ca-app-pub-3940256099942544';
  final p = testIds ? testPrefix : realPrefix;
  return AdConfig(
    provider: AdProvider.admob,
    admob: AdMobConfig(
      bannerId: '$p/1111111111',
      interstitialId: '$p/2222222222',
      appOpenId: '$p/3333333333',
      rewardedId: '$p/4444444444',
    ),
    safety: AdSafetyParams(dryRun: dryRun),
    appOpenTrigger: appOpenTrigger,
    firstInstallVipGrace: firstInstallVipGrace,
  );
}

AdConfig _consentConfig({
  bool autoRequestUmpConsent = false,
  bool disableAppLovinCmpFlow = true,
}) {
  return AdConfig(
    provider: AdProvider.admob,
    admob: const AdMobConfig(
      bannerId: 'ca-app-pub-9999999999999999/1111111111',
      interstitialId: 'ca-app-pub-9999999999999999/2222222222',
      appOpenId: 'ca-app-pub-9999999999999999/3333333333',
      rewardedId: 'ca-app-pub-9999999999999999/4444444444',
    ),
    autoRequestUmpConsent: autoRequestUmpConsent,
    disableAppLovinCmpFlow: disableAppLovinCmpFlow,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  group('releaseFootgunWarnings', () {
    test('debug build never warns (guards are release-only)', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: true),
        isDebug: true,
      );
      expect(w, isEmpty);
    });

    test('release + dryRun → one warning about the safety bypass', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: false),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('dryRun'));
    });

    test('release + AdMob Google test IDs → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: true),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('TEST'));
    });

    test('release + dryRun + test IDs → both warnings fire', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: true),
        isDebug: false,
      );
      expect(w, hasLength(2));
    });

    test('release + production AdMob IDs + dryRun off → clean', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: false),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    test('AppLovin provider is exempt from the AdMob test-ID guard', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            // Even if an ID happens to contain the Google prefix, the AdMob
            // guard must not fire for an AppLovin provider.
            bannerId: 'ca-app-pub-3940256099942544/x',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    // ── T16: empty / malformed ad-unit-id footguns ──────────────────────────
    test('release + empty AdMob rewardedId → one warning naming "rewarded"',
        () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-9999999999999999/1111111111',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            // rewardedId defaults to '' — the T16 footgun this guards.
          ),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('rewarded'));
      expect(w.single, contains('empty'));
    });

    test('release + empty required AdMob id (banner) → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: '',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            rewardedId: 'ca-app-pub-9999999999999999/4444444444',
          ),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('banner'));
      expect(w.single, contains('empty'));
    });
  });

  group('consentFootgunWarning (F4)', () {
    test('default config + UMP never requested → warns', () {
      final w = AdManager.consentFootgunWarning(
        _admobConfig(dryRun: true, testIds: true),
        umpRequested: false,
      );
      expect(w, isNotNull);
      expect(w, contains('No consent flow will run'));
    });

    test('UMP already requested → no warning', () {
      final w = AdManager.consentFootgunWarning(
        _admobConfig(dryRun: true, testIds: true),
        umpRequested: true,
      );
      expect(w, isNull);
    });

    test('autoRequestUmpConsent:true → no warning', () {
      final w = AdManager.consentFootgunWarning(
        _consentConfig(autoRequestUmpConsent: true),
        umpRequested: false,
      );
      expect(w, isNull);
    });

    test('disableAppLovinCmpFlow:false → no warning', () {
      final w = AdManager.consentFootgunWarning(
        _consentConfig(disableAppLovinCmpFlow: false),
        umpRequested: false,
      );
      expect(w, isNull);
    });

    test('release + AppLovin-shaped id on AdMob provider → format warning', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'appLovinLookingId123',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            rewardedId: 'ca-app-pub-9999999999999999/4444444444',
          ),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('banner'));
      expect(w.single, contains('format'));
    });

    test('release + well-formed production AdMob ids → no id warnings', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: false),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    test('release + empty AppLovin id → one warning (no format check)', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: '',
            rewardedId: 'r',
          ),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('appOpen'));
      expect(w.single, contains('empty'));
    });

    test('release + non-ca-app-pub AppLovin ids → exempt from format check',
        () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    test(
        'release + AdMob-shaped id on AppLovin provider → format warning '
        '(reverse T16 footgun)', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            bannerId: 'ca-app-pub-9999999999999999/1111111111',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('banner'));
      expect(w.single, contains('AdMob'));
    });

    // ── T17: firstInstallVipGrace disabled footgun ──────────────────────────
    test('release + firstInstallVipGrace.disabled → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        AdConfig(
          provider: AdProvider.appLovin,
          appLovin: const AppLovinConfig(
            sdkKey: 'k',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          firstInstallVipGrace: FirstInstallVipGrace.disabled,
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('firstInstallVipGrace'));
    });

    test('release + firstInstallVipGrace enabled (default) → no grace warning',
        () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          firstInstallVipGrace: FirstInstallVipGrace.day,
        ),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    // ── Idea #8: config validation / preflight checks ───────────────────────
    test('release + umpDebugGeography set → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-9999999999999999/1111111111',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            rewardedId: 'ca-app-pub-9999999999999999/4444444444',
          ),
          umpDebugGeography: DebugGeography.debugGeographyEea,
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('umpDebugGeography'));
    });

    test('release + AppLovin empty sdkKey → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: '',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('sdkKey'));
    });

    test(
        'release + AdMob provider with empty AppLovin sdkKey (unrelated '
        'field) → the AppLovin sdkKey guard does not fire', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: false),
        isDebug: false,
      );
      expect(w, isEmpty);
    });
  });

  group('VIP gating (via injected adapter + VipManager)', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugVipManager = null;
    });

    test('VIP active → loadInterstitial is skipped (adapter not called)',
        () async {
      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadInterstitial();
      expect(adapter.loadInterstitialCalls, 0);
    });

    test('VIP active → loadRewardedAd is skipped', () async {
      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadRewardedAd();
      expect(adapter.loadRewardedCalls, 0);
    });

    test('VIP active → showInterstitial resolves false, never shows', () async {
      AdManager().debugVipManager = _FakeVip(true);
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isFalse);
      expect(adapter.showInterstitialCalls, 0);
    });

    test('VIP active → canShowInterstitial() is false', () {
      AdManager().debugVipManager = _FakeVip(true);
      expect(AdManager().canShowInterstitial(), isFalse);
    });

    test(
        'VIP active → canShowRewardedAd() is TRUE '
        '(documented quirk: gate the button, decide reward via vipAutoGrant)',
        () {
      AdManager().debugVipManager = _FakeVip(true);
      expect(AdManager().canShowRewardedAd(), isTrue);
    });

    test('no VIP + idle slot → canShowInterstitial() is false', () {
      AdManager().debugVipManager = _FakeVip(false);
      // Slot is idle (never loaded) → not ready → false regardless of the
      // safety layer's session-timing state.
      expect(adapter.interstitialSlot.isReady, isFalse);
      expect(AdManager().canShowInterstitial(), isFalse);
    });

    test(
        'VIP active → showAppOpenAd is skipped even with bypassSafety '
        '(never stacks on top of the no-ads state)', () async {
      AdManager().debugVipManager = _FakeVip(true);
      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );
      expect(dismissed, isFalse);
    });
  });

  group('AppOpenTrigger gating', () {
    late _FakeAdapter adapter;

    setUp(() async {
      await AdManager().destroy();
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().markSplashInactive();
      AdScreenRouteLogger.resetState();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
      AdManager().markSplashActive();
      AdScreenRouteLogger.resetState();
    });

    test('resumeOnly → showAppOpenAd(bypassSafety: true) is blocked', () async {
      AdManager().debugConfig = _admobConfig(
        dryRun: true,
        testIds: true,
        appOpenTrigger: AppOpenTrigger.resumeOnly,
      );
      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );
      expect(dismissed, isFalse);
      expect(adapter.showAppOpenCalls, 0);
    });

    test('splashOnly → showAppOpenAdOnResume() is a no-op', () {
      AdManager().debugConfig = _admobConfig(
        dryRun: true,
        testIds: true,
        appOpenTrigger: AppOpenTrigger.splashOnly,
      );
      adapter.appOpenSlot.beginReload();
      adapter.appOpenSlot.markReady();
      AdManager().showAppOpenAdOnResume();
      expect(adapter.showAppOpenCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
    });

    test(
        'both (default) → showAppOpenAd(bypassSafety: true) is NOT blocked '
        'by the trigger gate', () async {
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );
      expect(dismissed, isTrue);
      expect(adapter.showAppOpenCalls, 1);
    });

    test(
        'both (default) → showAppOpenAdOnResume() is NOT blocked by the '
        'trigger gate (still gated by cold-start, as before)', () {
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      adapter.appOpenSlot.beginReload();
      adapter.appOpenSlot.markReady();
      AdManager().showAppOpenAdOnResume();
      expect(adapter.showAppOpenCalls, 0,
          reason: 'cold start one-shot skip, unrelated to the trigger gate');
      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1));
    });

    test(
        'splashOnly + splash inactive → loadAppOpenAd() is a no-op '
        '(High finding fix: load-gate, not just show-gate)', () async {
      AdManager().debugConfig = _admobConfig(
        dryRun: true,
        testIds: true,
        appOpenTrigger: AppOpenTrigger.splashOnly,
      );
      // setUp already calls markSplashInactive().
      await AdManager().loadAppOpenAd();
      expect(adapter.loadAppOpenCalls, 0);
    });

    test('splashOnly + splash active → loadAppOpenAd() still loads', () async {
      AdManager().debugConfig = _admobConfig(
        dryRun: true,
        testIds: true,
        appOpenTrigger: AppOpenTrigger.splashOnly,
      );
      AdManager().markSplashActive();
      await AdManager().loadAppOpenAd();
      expect(adapter.loadAppOpenCalls, 1);
    });

    test(
        'resumeOnly + splash inactive → loadAppOpenAd() still loads '
        '(same slot serves resume, no waste)', () async {
      AdManager().debugConfig = _admobConfig(
        dryRun: true,
        testIds: true,
        appOpenTrigger: AppOpenTrigger.resumeOnly,
      );
      await AdManager().loadAppOpenAd();
      expect(adapter.loadAppOpenCalls, 1);
    });

    test('both + splash inactive → loadAppOpenAd() still loads', () async {
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      await AdManager().loadAppOpenAd();
      expect(adapter.loadAppOpenCalls, 1);
    });
  });

  group('rewarded VIP-bypass (watch-ad to EXTEND VIP)', () {
    late _FakeAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      // Permissive safety + clean timing so the fullscreen gate never blocks
      // the show path under test.
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugVipManager = null;
    });

    test(
        'default (no bypass): VIP active → no real ad even if a slot is ready, '
        'onEarnedReward(false)', () async {
      AdManager().debugVipManager = _FakeVip(true);
      adapter.loadMarksReady = true;
      bool? earned;
      await AdManager().showRewardedAd(onEarnedReward: (e) => earned = e);
      expect(earned, isFalse, reason: 'vipAutoGrant defaults to false');
      expect(adapter.showRewardedCalls, 0);
    });

    test('default + vipAutoGrant: VIP active → earned(true) without showing',
        () async {
      AdManager().debugVipManager = _FakeVip(true);
      bool? earned;
      await AdManager().showRewardedAd(
          vipAutoGrant: true, onEarnedReward: (e) => earned = e);
      expect(earned, isTrue);
      expect(adapter.showRewardedCalls, 0);
    });

    test(
        'bypassVipGuard: VIP active → on-demand load + REAL ad shown, '
        'earned=true', () async {
      AdManager().debugVipManager = _FakeVip(true);
      adapter.loadMarksReady = true;
      adapter.nextRewardEarned = true;
      bool? earned;
      await AdManager().showRewardedAd(
          bypassVipGuard: true, onEarnedReward: (e) => earned = e);
      expect(adapter.loadRewardedCalls, greaterThanOrEqualTo(1),
          reason: 'slot was not preloaded for a VIP → must load on demand');
      expect(adapter.showRewardedCalls, 1, reason: 'a real ad must be shown');
      expect(earned, isTrue);
    });

    test('bypassVipGuard but on-demand load fails → no show, earned=false',
        () async {
      AdManager().debugVipManager = _FakeVip(true);
      adapter.loadMarksReady = false; // load never makes the slot ready
      bool? earned;
      await AdManager().showRewardedAd(
          bypassVipGuard: true, onEarnedReward: (e) => earned = e);
      expect(adapter.showRewardedCalls, 0);
      expect(earned, isFalse);
    });

    test('bypassVipGuard with a non-VIP user still shows normally', () async {
      AdManager().debugVipManager = _FakeVip(false);
      adapter.loadMarksReady = true;
      bool? earned;
      await AdManager().showRewardedAd(
          bypassVipGuard: true, onEarnedReward: (e) => earned = e);
      expect(adapter.showRewardedCalls, 1);
      expect(earned, isTrue);
    });

    test(
        'a second call while the first is mid on-demand-load is rejected '
        '(re-entrancy guard, slot not yet showing)', () async {
      AdManager().debugVipManager = _FakeVip(true);
      adapter.hangLoad = true; // first call's load never resolves
      bool? r1, r2;
      // First call enters the on-demand wait and stays in flight.
      final f1 = AdManager().showRewardedAd(
        bypassVipGuard: true,
        onDemandLoadTimeout: const Duration(milliseconds: 300),
        onEarnedReward: (e) => r1 = e,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      // Second call while the first is still loading (slot is `loading`, NOT
      // `showing`) — only the in-flight guard can reject it.
      await AdManager().showRewardedAd(
        bypassVipGuard: true,
        onEarnedReward: (e) => r2 = e,
      );
      expect(r2, isFalse, reason: 'blocked by _rewardedInFlight guard');
      expect(adapter.showRewardedCalls, 0, reason: 'neither reached show');
      await f1; // first times out → false, releasing the guard
      expect(r1, isFalse);
    });
  });

  group(
      'initialize() re-init guard (Fix #5: stale retry timer/connectivity '
      'watch leak)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
      // Force isInitialised=true (config != null && adapter != null) via the
      // existing injection seams — the real adapter.initialize() path (native
      // plugins) isn't reachable in a plain `flutter test` run, but the guard
      // this fix touches runs BEFORE that call, so this is enough to exercise it.
      AdManager().debugSetAdapter(_FakeAdapter());
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().vip?.dispose();
      AdManager().debugVipManager = null;
    });

    test(
        're-entering initialize() while already initialised bumps the '
        'retry generation (stops the stale timer + connectivity watch)',
        () async {
      expect(AdManager().isInitialised, isTrue);
      final genBefore = AdManager().debugRetryGen;

      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) {},
      );

      // The re-init guard (`if (isInitialised) { ...; _stopAdRetryTimer(); }`)
      // must have run — _stopAdRetryTimer() unconditionally increments
      // _retryGen, so a strictly-greater value proves the stale timer chain
      // (and, in the same guard, the stale connectivity subscription) was
      // torn down before the fresh adapter/init proceeded.
      expect(AdManager().debugRetryGen, greaterThan(genBefore));
    });

    test(
        're-entering initialize() disposes the previous VipManager '
        '(audit 1.1: stale _expiryTimer/notifier leak)', () async {
      // Phase 4 (VipManager swap) runs unconditionally, before the real
      // adapter's native initialize() call — so this doesn't need any
      // platform-channel mocking to reach.
      final prefs = await AdPreferences.getInstance();
      final oldVip = _DisposeTrackingVipManager(prefs,
          vipEntriesStore: _FakeVipEntriesStore(prefs));
      await oldVip.load(currentDeviceGaid: '');
      AdManager().debugVipManager = oldVip;

      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) {},
      );

      expect(oldVip.disposed, isTrue,
          reason: 'without dispose(), the old VipManager\'s _expiryTimer '
              'keeps re-arming itself via a closure holding the instance '
              'alive forever');
      expect(AdManager().vip, isNot(same(oldVip)),
          reason: 'a fresh VipManager must replace the disposed one');
    });
  });

  group('T48: first-install VIP grace fires through the real init flow', () {
    setUp(() async {
      await AdManager().destroy();
      SharedPreferences.setMockInitialValues({});
      // AdPreferences caches its SharedPreferences instance in a static
      // singleton — without this, an earlier test's
      // markFirstInstallGraceApplied() leaks in and this test's grant
      // silently no-ops.
      AdPreferences.resetForTest();
    });

    tearDown(() async {
      await AdManager().destroy();
    });

    test(
        'fresh install + AdManager().initialize() auto-activates VIP for '
        'the configured 1-day grace window', () async {
      // kDebugMode is true under `flutter test`, so FirstInstallGuard
      // short-circuits to "allow grace" without touching Keychain/secure
      // storage — see FirstInstallGuard.hasAlreadyGranted().
      await AdManager().initialize(
        config: _admobConfig(
          dryRun: true,
          testIds: true,
          firstInstallVipGrace: FirstInstallVipGrace.day,
        ),
        onComplete: (_, __) {},
      );

      final vip = AdManager().vip;
      expect(vip, isNotNull);
      expect(vip!.isActive, isTrue,
          reason: 'first-install grace must auto-activate VIP through the '
              'real initialize() flow, not just via addVip() called '
              'directly in isolation');
      expect(vip.activeListenable.value, isTrue);
      final remainingHours = vip.expiresAt!.difference(DateTime.now()).inHours;
      expect(remainingHours, inInclusiveRange(23, 24));
    });
  });

  group('null adapter (uninitialised) is safe', () {
    setUp(() => AdManager().debugSetAdapter(null));

    test('canShowInterstitial / canShowRewardedAd both false', () {
      expect(AdManager().canShowInterstitial(), isFalse);
      expect(AdManager().canShowRewardedAd(), isFalse);
    });

    test('showInterstitial resolves false without an adapter', () async {
      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);
      expect(flow, isFalse);
    });
  });

  group('showAppOpenAdOnResume() guard chain', () {
    late _FakeAdapter adapter;

    setUp(() async {
      // A previous group's real showRewarded/showInterstitial completion may
      // have left `_lastFullscreenDismissAt` recent, which would trip the
      // resume-debounce gate before this group's own guards get a chance to
      // run — destroy() is the only way to zero it (no debug seam for it).
      await AdManager().destroy();
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit(); // fresh _isColdStart=true per test
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().markSplashInactive();
      AdScreenRouteLogger.resetState();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
      AdManager().markSplashActive();
      AdScreenRouteLogger.resetState();
    });

    test('adapter null → no-op, never throws', () {
      AdManager().debugSetAdapter(null);
      expect(AdManager().showAppOpenAdOnResume, returnsNormally);
    });

    test('splash active → skipped, no reload triggered', () {
      AdManager().markSplashActive();
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.showAppOpenCalls, 0);
    });

    test('VIP member → skipped, no reload triggered', () {
      AdManager().debugVipManager = _FakeVip(true);
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.showAppOpenCalls, 0);
    });

    test('interstitial currently showing → skipped, no reload triggered', () {
      adapter.interstitialSlot.beginReload();
      adapter.interstitialSlot.markReady();
      adapter.interstitialSlot.beginShow();
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.showAppOpenCalls, 0);
    });

    test('dialog/popup on top → skipped, no reload triggered', () {
      final logger = AdScreenRouteLogger();
      logger.didPush(_FakePopupRoute(), null);
      expect(AdScreenRouteLogger.isDialogOnTop, isTrue);
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.showAppOpenCalls, 0);
    });

    test('cold start (first resume ever) → skipped but triggers a reload', () {
      adapter.appOpenSlot.beginReload();
      adapter.appOpenSlot.markReady();
      AdManager().showAppOpenAdOnResume();
      expect(adapter.showAppOpenCalls, 0,
          reason: 'cold start is a one-shot skip, never shows on the first '
              'resume');
      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1));
    });

    test('slot not ready → skipped but triggers a reload', () {
      // Consume the one-shot cold-start skip first so this test reaches the
      // slot-readiness gate instead.
      AdManager().showAppOpenAdOnResume();
      adapter.loadAppOpenCalls = 0;

      expect(adapter.appOpenSlot.isReady, isFalse,
          reason: 'never loaded — still idle');
      AdManager().showAppOpenAdOnResume();
      expect(adapter.showAppOpenCalls, 0);
      expect(adapter.loadAppOpenCalls, 1);
    });

    testWidgets(
        'happy path (no navigatorKey context) → fallback timer shows a real '
        'App Open ad', (tester) async {
      adapter.appOpenSlot.beginReload();
      adapter.appOpenSlot.markReady();

      AdManager().showAppOpenAdOnResume(); // consumes the cold-start skip
      AdManager().showAppOpenAdOnResume(); // schedules the 1s fallback timer
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));

      expect(adapter.showAppOpenCalls, 1);
    });
  });

  group('didChangeAppLifecycleState()', () {
    late _FakeAdapter adapter;

    setUp(() async {
      await AdManager().destroy();
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().markSplashInactive();
      AdScreenRouteLogger.resetState();
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
      AdManager().markSplashActive();
      AdScreenRouteLogger.resetState();
    });

    test('not initialised → logs only, never throws', () {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      expect(
          () =>
              AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed),
          returnsNormally);
    });

    test('paused → calls adapter.onAppPaused()', () {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.paused);
      expect(adapter.onAppPausedCalls, 1);
      expect(adapter.onAppResumedCalls, 0);
    });

    test(
        'resumed → calls adapter.onAppResumed() and reaches '
        'showAppOpenAdOnResume()', () {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      expect(adapter.onAppResumedCalls, 1);
      // Cold-start one-shot skip still triggers a reload — same proof used
      // by the showAppOpenAdOnResume() guard-chain group above — showing the
      // dispatcher really reached showAppOpenAdOnResume(), not just onResume.
      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1));
    });

    test('detached → early-return, never touches the adapter', () {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.detached);
      expect(adapter.onAppPausedCalls, 0);
      expect(adapter.onAppResumedCalls, 0);
      expect(adapter.loadAppOpenCalls, 0);
    });

    test('adapter throwing on paused/resumed is swallowed, never propagates',
        () {
      adapter.throwOnLifecycle = true;
      expect(
          () =>
              AdManager().didChangeAppLifecycleState(AppLifecycleState.paused),
          returnsNormally);
      expect(
          () =>
              AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed),
          returnsNormally);
      expect(adapter.onAppPausedCalls, 1);
      expect(adapter.onAppResumedCalls, 1);
    });
  });

  group('didHaveMemoryPressure()', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
    });

    tearDown(() => AdManager().debugSetAdapter(null));

    test('null adapter → no-op, never throws', () {
      AdManager().debugSetAdapter(null);
      expect(AdManager().didHaveMemoryPressure, returnsNormally);
    });

    test('single call is a no-op besides logging — slots untouched', () {
      expect(AdManager().didHaveMemoryPressure, returnsNormally);
      expect(adapter.appOpenSlot.isIdle, isTrue);
      expect(adapter.interstitialSlot.isIdle, isTrue);
      expect(adapter.rewardedSlot.isIdle, isTrue);
      expect(adapter.bannerSlot.isIdle, isTrue);
    });

    test('two calls back-to-back (inside the 60s throttle) never throw', () {
      AdManager().didHaveMemoryPressure();
      expect(AdManager().didHaveMemoryPressure, returnsNormally);
    });
  });

  group('retry timer (_startAdRetryTimer / _scheduleNextRetry)', () {
    late _FakeAdapter adapter;

    setUp(() async {
      await AdManager().destroy();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
    });

    tearDown(() {
      AdManager().debugStopAdRetryTimer();
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });

    test('fires a refill scan every 5 minutes while active', () {
      fakeAsync((async) {
        AdManager().debugStartAdRetryTimer();
        expect(adapter.loadInterstitialCalls, 0);

        async.elapse(const Duration(minutes: 5));
        expect(adapter.loadInterstitialCalls, 1,
            reason: 'first 5-minute tick should trigger a refill scan');
        expect(adapter.loadRewardedCalls, 1);
        expect(adapter.loadAppOpenCalls, 1);

        async.elapse(const Duration(minutes: 5));
        expect(adapter.loadInterstitialCalls, 2,
            reason: 'timer must reschedule itself for the next tick');
      });
    });

    test('debugStopAdRetryTimer() bumps the generation and stops ticks', () {
      fakeAsync((async) {
        AdManager().debugStartAdRetryTimer();
        async.elapse(const Duration(minutes: 5));
        expect(adapter.loadInterstitialCalls, 1);

        final genBefore = AdManager().debugRetryGen;
        AdManager().debugStopAdRetryTimer();
        expect(AdManager().debugRetryGen, greaterThan(genBefore));

        async.elapse(const Duration(minutes: 15));
        expect(adapter.loadInterstitialCalls, 1,
            reason: 'no further ticks once the timer generation has moved on');
      });
    });
  });

  group('destroy() event stream lifecycle (T31)', () {
    AdRevenueEvent rev(int micros) => AdRevenueEvent(
          providerTag: 'fake',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          valueMicros: micros,
          currencyCode: 'USD',
        );

    test(
        'destroy() closes events stream; subsequent debugEmit() after '
        'destroy() does not throw', () async {
      final events = <AdEvent>[];
      bool done = false;
      final sub =
          AdManager().events.listen(events.add, onDone: () => done = true);
      AdManager().debugEmit(rev(100));
      await Future<void>.value();
      await AdManager().destroy();
      expect(done, isTrue,
          reason: 'destroy() must close the old broadcast controller, '
              'firing onDone for existing subscribers');
      await sub.cancel();
      expect(() => AdManager().debugEmit(rev(200)), returnsNormally,
          reason: 'destroy() must recreate _eventStream so a later '
              'initialize() cycle can emit again without throwing on a '
              'closed StreamController');
    });
  });

  group('isOfflineListenable (T33)', () {
    tearDown(() => AdManager().debugConnectivityChanged(true));

    test(
        'flips true when connectivity drops false, back to false on '
        'reconnect', () {
      final mgr = AdManager();
      expect(mgr.isOfflineListenable.value, isFalse);
      mgr.debugConnectivityChanged(false);
      expect(mgr.isOfflineListenable.value, isTrue);
      mgr.debugConnectivityChanged(true);
      expect(mgr.isOfflineListenable.value, isFalse);
    });
  });

  group('RevenuePanel consumes AdManager().events (debugEmit)', () {
    AdRevenueEvent rev(int micros) => AdRevenueEvent(
          providerTag: 'fake',
          type: AdSlotType.interstitial,
          placement: AdPlacement.unspecified,
          valueMicros: micros,
          currencyCode: 'USD',
        );

    testWidgets('emitted revenue accumulates and renders', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(compact: true, showDecimals: false),
        ),
      ));
      await tester.pump();
      expect(find.text('Rev: \$0.00  /  0 imp'), findsOneWidget);

      AdManager().debugEmit(rev(1500000)); // $1.50
      AdManager().debugEmit(rev(500000)); //  $0.50
      // Broadcast-stream delivery is async (microtask) → flush, then rebuild.
      await tester.pump();
      await tester.pump();

      expect(find.text('Rev: \$2.00  /  2 imp'), findsOneWidget,
          reason: 'two events accumulate value + impression count');
    });

    testWidgets('non-revenue events do not move the counter', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(compact: true, showDecimals: false),
        ),
      ));
      await tester.pump();

      AdManager().debugEmit(AdShowEvent(
        providerTag: 'fake',
        type: AdSlotType.interstitial,
        placement: AdPlacement.unspecified,
        success: true,
      ));
      await tester.pump();

      expect(find.text('Rev: \$0.00  /  0 imp'), findsOneWidget);
    });

    testWidgets('compact:false renders the full Card with decimals',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(),
        ),
      ));
      await tester.pump();
      expect(find.byType(Card), findsOneWidget);
      expect(find.text('Session Revenue'), findsOneWidget);
      expect(find.text('\$0.0000'), findsOneWidget);
      expect(find.text('0 impressions'), findsOneWidget);

      AdManager().debugEmit(rev(1500000)); // $1.50
      await tester.pump();
      await tester.pump();

      expect(find.text('\$1.5000'), findsOneWidget);
      expect(find.text('1 impressions'), findsOneWidget);
    });

    testWidgets(
        'disposing the widget cancels the subscription — later debugEmit '
        'never throws', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(compact: true, showDecimals: false),
        ),
      ));
      await tester.pump();
      AdManager().debugEmit(rev(1000000));
      await tester.pump();
      await tester.pump();
      expect(find.text('Rev: \$1.00  /  1 imp'), findsOneWidget);

      // Unmount the panel — dispose() must cancel _sub and dispose both
      // ValueNotifiers without leaking a listener callback into a torn-down
      // State.
      await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));
      await tester.pump();

      expect(() => AdManager().debugEmit(rev(2000000)), returnsNormally);
      await tester.pump();
    });

    testWidgets(
        'F9: debugModeOverride:true still renders (matches default '
        'kDebugMode behavior under flutter test)', (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(
              compact: true, showDecimals: false, debugModeOverride: true),
        ),
      ));
      await tester.pump();
      expect(find.text('Rev: \$0.00  /  0 imp'), findsOneWidget);
    });

    testWidgets(
        'F9: debugModeOverride:false renders nothing and never subscribes',
        (tester) async {
      await tester.pumpWidget(const MaterialApp(
        home: Scaffold(
          body: RevenuePanel(
              compact: true, showDecimals: false, debugModeOverride: false),
        ),
      ));
      await tester.pump();

      expect(find.byType(RevenuePanel), findsOneWidget);
      expect(find.textContaining('Rev:'), findsNothing);
      expect(find.byType(Card), findsNothing);

      // Not subscribed → emitting revenue must not make text appear later.
      AdManager().debugEmit(rev(1500000));
      await tester.pump();
      await tester.pump();
      expect(find.textContaining('Rev:'), findsNothing);
    });
  });

  group('tcfConsentString', () {
    test('reads the IABTCF_TCString Google UMP writes to native storage',
        () async {
      SharedPreferences.setMockInitialValues(
          {'IABTCF_TCString': 'CPxxTestConsentString'});
      expect(await AdManager().tcfConsentString, 'CPxxTestConsentString');
    });

    test('null when no TCF session has ever run', () async {
      SharedPreferences.setMockInitialValues({});
      expect(await AdManager().tcfConsentString, isNull);
    });
  });
}
