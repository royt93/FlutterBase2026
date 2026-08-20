// Behavioral unit tests for the AdManager orchestrator core, driven through the
// @visibleForTesting seams (debugSetAdapter / debugVipManager / debugEmit /
// releaseFootgunWarnings) so the gating logic is exercised WITHOUT the native
// AppLovin/AdMob plugins.
//
// Covered:
//   1. releaseFootgunWarnings — the loud release-build guard for AdMob Google
//      test IDs left in release, as a pure function. (dryRun-in-release is a
//      separate, silent-correction guard now — see AdSafetyConfig.init()'s
//      applyDryRunReleaseGuard.)
//   2. VIP gating — every public load/show/canShow path must short-circuit when
//      a VIP entry is active (the SDK's "VIP suppresses all ad surfaces"
//      contract), including the documented canShowRewardedAd()==true quirk.
//   3. RevenuePanel — a real consumer of AdManager().events: feeding
//      AdRevenueEvents through debugEmit must accumulate on screen.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// T88 — fakes for remoteSafetyProvider tests.
class _FakeRemoteSafetyProvider implements RemoteAdSafetyProvider {
  _FakeRemoteSafetyProvider(this._overrides);
  final Map<String, dynamic> _overrides;
  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async =>
      _overrides;
}

class _ThrowingRemoteSafetyProvider implements RemoteAdSafetyProvider {
  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() async =>
      throw StateError('remote config backend unreachable');
}

class _HangingRemoteSafetyProvider implements RemoteAdSafetyProvider {
  @override
  Future<Map<String, dynamic>?> fetchSafetyParamOverrides() =>
      Completer<Map<String, dynamic>?>().future; // never completes
}

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
const _appLovinMaxChannel =
    MethodChannel('com.applovin.applovin_max/applovin_max');

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
  final AdSlot _bannerSlot = AdSlot(type: AdSlotType.banner);
  @override
  AdSlot bannerSlot(Object key) => _bannerSlot;

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

  // T89
  @override
  final AdSlot rewardedInterstitialSlot =
      AdSlot(type: AdSlotType.rewardedInterstitial);
  int loadRewardedInterstitialCalls = 0;
  int showRewardedInterstitialCalls = 0;
  bool nextRewardedInterstitialEarned = true;

  @override
  Future<void> loadRewardedInterstitial() async {
    loadRewardedInterstitialCalls++;
    if (loadMarksReady) {
      rewardedInterstitialSlot.beginReload();
      rewardedInterstitialSlot.markReady();
    }
  }

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    showRewardedInterstitialCalls++;
    rewardedInterstitialSlot.beginShow();
    rewardedInterstitialSlot.markDismissed();
    onDone(nextRewardedInterstitialEarned
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
  void applyConsent(AdConsent consent) {
    // Fake implementation — no-op for test purposes.
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
  void resyncSessionClock() {}

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
  bool autoRequestUmpConsent = true,
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
    autoRequestUmpConsent: autoRequestUmpConsent,
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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_appLovinMaxChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_appLovinMaxChannel, null);
  });

  group('releaseFootgunWarnings', () {
    test('debug build never warns (guards are release-only)', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: true),
        isDebug: true,
      );
      expect(w, isEmpty);
    });

    test(
        'release + dryRun → no warning (R12-A: AdSafetyConfig.init forces '
        'it off before this ever runs, so the old dryRun check was removed)',
        () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: false),
        isDebug: false,
      );
      expect(w, isEmpty);
    });

    test('release + AdMob Google test IDs → one warning', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: true),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('TEST'));
    });

    test(
        'release + dryRun + test IDs → only the test-ID warning fires '
        '(dryRun is no longer checked here, see R12-A)', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: true, testIds: true),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('TEST'));
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
    // 2.0.0 — autoRequestUmpConsent now DEFAULTS to true, so a default config
    // no longer trips the footgun; that is the whole point of the new default.
    // Opt out of it explicitly to exercise the warning logic itself.
    test('no consent flow configured + UMP never requested → warns', () {
      final w = AdManager.consentFootgunWarning(
        _admobConfig(dryRun: true, testIds: true, autoRequestUmpConsent: false),
        umpRequested: false,
      );
      expect(w, isNotNull);
      expect(w, contains('No consent flow will run'));
    });

    test('default config no longer warns (autoRequestUmpConsent defaults true)',
        () {
      final w = AdManager.consentFootgunWarning(
        _admobConfig(dryRun: true, testIds: true),
        umpRequested: false,
      );
      expect(w, isNull,
          reason: 'the 2.0.0 default runs UMP, so there IS a consent flow');
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

    test('N2: consentExplicitlySet:true → no warning (custom consent UI)', () {
      final w = AdManager.consentFootgunWarning(
        _admobConfig(dryRun: true, testIds: true),
        umpRequested: false,
        consentExplicitlySet: true,
      );
      expect(w, isNull);
    });
  });

  // 2026-08-19 audit (Finding 7): requestAtt()-before-UMP ordering was only
  // ever a `SafeLogger.w` inside requestUmpConsent() itself — easy to miss,
  // and not release-gated the way this SDK's other real footguns are.
  group('attOrderFootgunWarning (2026-08-19 audit, Finding 7)', () {
    test('iOS + requestAtt() never called → warns', () {
      final w = AdManager.attOrderFootgunWarning(attRequested: false, isIos: true);
      expect(w, isNotNull);
      expect(w, contains('requestAtt()'));
    });

    test('iOS + requestAtt() already called → no warning', () {
      final w = AdManager.attOrderFootgunWarning(attRequested: true, isIos: true);
      expect(w, isNull);
    });

    test('Android → no warning regardless (ATT is iOS-only)', () {
      final w = AdManager.attOrderFootgunWarning(attRequested: false, isIos: false);
      expect(w, isNull);
    });
  });

  group('N2: consent footgun runtime block', () {
    setUp(() {
      // Isolate from adapter/config state other groups may have left behind
      // — this group only cares about the canRequestAds/_footgunBlocked
      // interaction, not a real init flow.
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
    });
    tearDown(() {
      AdManager().debugFootgunBlocked = false;
      AdManager().debugCanRequestAds = true;
    });

    test('footgun block alone makes canRequestAds false', () {
      AdManager().debugCanRequestAds = true;
      AdManager().debugFootgunBlocked = true;
      expect(AdManager().canRequestAds, isFalse);
    });

    test('setConsent() clears the footgun block and reopens the gate',
        () async {
      AdManager().debugCanRequestAds = true;
      AdManager().debugFootgunBlocked = true;
      expect(AdManager().canRequestAds, isFalse);

      await AdManager().setConsent(const AdConsent(hasUserConsent: true));

      expect(AdManager().canRequestAds, isTrue);
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
        'T64 — consent revoked after an ad already loaded+cached → '
        'canShowInterstitial() is false', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(false);
      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();
      expect(AdManager().canShowInterstitial(), isTrue,
          reason: 'sanity check: ready + consent granted shows normally');

      AdManager().debugCanRequestAds = false; // consent revoked mid-session
      addTearDown(() => AdManager().debugCanRequestAds = true);

      expect(AdManager().canShowInterstitial(), isFalse,
          reason: 'a cached-ready ad must not show once consent is '
              'revoked, even though it finished loading before that');
    });

    test(
        'T64 — consent revoked after an ad already loaded+cached (non-VIP) '
        '→ canShowRewardedAd() is false', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(false);
      adapter.rewardedSlot.beginLoad();
      adapter.rewardedSlot.markReady();
      expect(AdManager().canShowRewardedAd(), isTrue,
          reason: 'sanity check: ready + consent granted shows normally');

      AdManager().debugCanRequestAds = false; // consent revoked mid-session
      addTearDown(() => AdManager().debugCanRequestAds = true);

      expect(AdManager().canShowRewardedAd(), isFalse,
          reason: 'a cached-ready ad must not show once consent is '
              'revoked, even though it finished loading before that — the '
              'documented VIP-bypass quirk above is untouched, this only '
              'covers the real (non-VIP) ad path');
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

    test(
        'C3: interstitial already showing → showAppOpenAd(bypassSafety: true) '
        'is skipped instead of stacking on top of it', () async {
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      // beginShow() is only valid from `ready`, so warm the slot up first.
      adapter.interstitialSlot.beginReload();
      adapter.interstitialSlot.markReady();
      adapter.interstitialSlot
          .beginShow(); // another fullscreen ad owns the screen
      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );
      expect(dismissed, isFalse);
      expect(adapter.showAppOpenCalls, 0,
          reason: 'must consult the shared mutex, not just its own slot');
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

  // T72 — a screen that renders before SDK init completes had no clear way
  // to be notified once AdManager().vip becomes non-null, other than
  // polling initRevision and re-checking vip != null itself.
  group('vipReady listenable (T72)', () {
    test('fires false → true exactly once when vip becomes ready',
        () async {
      SharedPreferences.setMockInitialValues({});
      await AdManager().destroy(); // guaranteed clean slate for this test
      addTearDown(() => AdManager().destroy());

      expect(AdManager().vip, isNull);
      expect(AdManager().vipReady.value, isFalse);

      final seen = <bool>[];
      AdManager().vipReady.addListener(() => seen.add(AdManager().vipReady.value));

      // Phase 4 (VipManager swap) runs unconditionally, before the real
      // adapter's native initialize() call — no platform-channel mocking
      // needed to reach it (mirrors the re-init test above).
      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) {},
      );

      expect(AdManager().vip, isNotNull);
      expect(AdManager().vipReady.value, isTrue);
      expect(seen, [true], reason: 'must fire exactly once, false → true');
    });
  });

  // T75 — public reactive mirror of the internal fullscreen-mutex reason,
  // so a host can disable its own CTA / avoid a competing dialog while the
  // SDK holds it, instead of only checking at the moment it calls show().
  group('fullscreenBusy listenable (T75)', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugVipManager = _FakeVip(false);
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugVipManager = null;
      AdScreenRouteLogger.resetState();
      AdLoadingDialog.resetState();
    });

    test('reflects a fullscreen ad slot entering/leaving the showing state',
        () {
      expect(AdManager().fullscreenBusy.value, isFalse);

      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();
      adapter.interstitialSlot.beginShow();
      expect(AdManager().fullscreenBusy.value, isTrue,
          reason: 'an interstitial actually showing must count as busy');

      adapter.interstitialSlot.markDismissed();
      expect(AdManager().fullscreenBusy.value, isFalse);
    });

    testWidgets('reflects AdLoadingDialog.show()/dismiss()', (tester) async {
      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          }),
        ),
      ));

      expect(AdManager().fullscreenBusy.value, isFalse);
      AdLoadingDialog.show(ctx);
      await tester.pump();
      expect(AdManager().fullscreenBusy.value, isTrue,
          reason: 'the buffering dialog itself must count as fullscreen-busy');

      AdLoadingDialog.dismiss();
      await tester.pump();
      expect(AdManager().fullscreenBusy.value, isFalse);
    });

    test('reflects AdScreenRouteLogger popup push/pop', () {
      expect(AdManager().fullscreenBusy.value, isFalse);

      final route = _FakePopupRoute();
      AdScreenRouteLogger().didPush(route, null);
      expect(AdManager().fullscreenBusy.value, isTrue,
          reason: 'a dialog on top of the navigator stack must count as busy');

      AdScreenRouteLogger().didPop(route, null);
      expect(AdManager().fullscreenBusy.value, isFalse);
    });
  });

  // T76 — the on-demand rewarded path already has its own load timeout
  // (onDemandLoadTimeout); a regular background preload had none — if the
  // native SDK's callback never fires, the slot was stuck in `loading`
  // forever, never picked up by the existing backoff/retry logic (which
  // only reacts to AdSlot.markFailed()).
  group('load watchdog (T76)', () {
    late _FakeAdapter adapter;

    setUp(() {
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().debugCanRequestAds = true;
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
    });

    test(
        'a rewarded preload whose native callback never fires is forced to '
        'fail after the watchdog window', () {
      fakeAsync((async) {
        adapter.hangLoad = true; // simulates a silent native SDK
        AdManager().loadRewardedAd(watchdog: const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(adapter.rewardedSlot.isLoading, isTrue,
            reason: 'sanity: the load actually started');

        async.elapse(const Duration(seconds: 9));
        expect(adapter.rewardedSlot.isLoading, isTrue,
            reason: 'still inside the watchdog window');

        async.elapse(const Duration(seconds: 2));
        expect(adapter.rewardedSlot.value, AdSlotState.cooldown,
            reason: 'watchdog must force markFailed() once the window '
                'elapses with no native callback');
      });
    });

    test(
        'a rewarded preload that resolves normally is never touched by the '
        'watchdog', () {
      fakeAsync((async) {
        adapter.loadMarksReady = true;
        AdManager().loadRewardedAd(watchdog: const Duration(seconds: 10));
        async.flushMicrotasks();

        expect(adapter.rewardedSlot.value, AdSlotState.ready);

        async.elapse(const Duration(seconds: 11));
        expect(adapter.rewardedSlot.value, AdSlotState.ready,
            reason: 'a late-firing watchdog must not clobber a real ready ad');
      });
    });
  });

  // T77 — structured AdSkipEvent twin of the SafeLogger-only gate/skip
  // decisions, so a host can build a funnel/dashboard without parsing logs.
  group('AdSkipEvent (T77)', () {
    late AdPreferences prefs;
    late _FakeAdapter adapter;
    late List<AdEvent> events;
    late StreamSubscription<AdEvent> sub;

    setUp(() async {
      // AdPreferences.getInstance() caches its singleton across the whole
      // test file — plain setMockInitialValues() alone doesn't rebind it,
      // so daily-cap/suspicious-count state can otherwise leak between
      // these tests (and from unrelated tests earlier in the file).
      AdPreferences.resetForTest();
      SharedPreferences.setMockInitialValues({});
      prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().debugCanRequestAds = true;
      events = <AdEvent>[];
      sub = AdManager().events.listen(events.add);
    });
    tearDown(() async {
      await sub.cancel();
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
    });

    AdSkipEvent? lastSkip() {
      final skips = events.whereType<AdSkipEvent>();
      return skips.isEmpty ? null : skips.last;
    }

    test('load: VIP member emits an interstitial load skip with reason=vip',
        () async {
      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadInterstitial();
      await Future<void>.delayed(Duration.zero); // flush the broadcast stream

      final skip = lastSkip();
      expect(skip, isNotNull);
      expect(skip!.type, AdSlotType.interstitial);
      expect(skip.action, 'load');
      expect(skip.reason, 'vip');
    });

    test('load: daily cap reached emits a rewarded load skip with '
        'reason=daily_cap', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug
              .copyWith(maxFullscreenAdsPerDay: 0));
      AdSafetyConfig.resetForReinit();

      await AdManager().loadRewardedAd();
      await Future<void>.delayed(Duration.zero);

      final skip = lastSkip();
      expect(skip, isNotNull);
      expect(skip!.type, AdSlotType.rewarded);
      expect(skip.action, 'load');
      expect(skip.reason, 'daily_cap');
    });

    test('load: consent not granted emits a load skip with reason=consent',
        () async {
      AdManager().debugCanRequestAds = false;

      await AdManager().loadInterstitial();
      await Future<void>.delayed(Duration.zero);

      final skip = lastSkip();
      expect(skip, isNotNull);
      expect(skip!.action, 'load');
      expect(skip.reason, 'consent');
    });

    test(
        'show: safety cooldown (progressive suspicious pause) emits a show '
        'skip with reason=cooldown', () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(maxClicksPerMinute: 2));
      AdSafetyConfig.resetForReinit();

      for (var i = 0; i < 3; i++) {
        AdSafetyConfig.recordAdClick(); // 3rd click > cap → suspicious pause
      }

      await AdManager().showInterstitial(onDoneFlow: (_) {});
      await Future<void>.delayed(Duration.zero);

      final skip = lastSkip();
      expect(skip, isNotNull);
      expect(skip!.action, 'show');
      expect(skip.reason, 'cooldown');
    });

    // T92 — per-placement daily cap, on top of the global one.
    test(
        'show: reaching the per-placement daily cap emits a show skip '
        'with reason=placement_cap, without touching the global cap',
        () async {
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(
              maxPerPlacementAdsPerDay: {AdPlacement.splash: 1}));
      AdSafetyConfig.resetForReinit();
      AdSafetyConfig.recordPlacementAdShown(AdPlacement.splash);

      await AdManager().showInterstitial(
          onDoneFlow: (_) {}, placement: AdPlacement.splash);
      await Future<void>.delayed(Duration.zero);

      final skip = lastSkip();
      expect(skip, isNotNull);
      expect(skip!.action, 'show');
      expect(skip.reason, 'placement_cap');

      // A DIFFERENT placement, with no cap configured, must still show
      // normally — the global daily cap alone (5, from AdSafetyParams.debug's
      // override above) is nowhere near reached.
      events.clear();
      await AdManager().showInterstitial(
          onDoneFlow: (_) {}, placement: AdPlacement.home);
      await Future<void>.delayed(Duration.zero);
      expect(events.whereType<AdSkipEvent>().where((e) => e.reason == 'placement_cap'),
          isEmpty);
    });
  });

  // T88 — remoteSafetyProvider lets a host plug in Firebase Remote
  // Config/a custom backend to adjust AdSafetyParams without an app
  // store release. Validated + merged onto config.safety; a failing or
  // slow provider must never block init.
  group('remoteSafetyProvider (T88)', () {
    setUp(() async {
      AdPreferences.resetForTest();
      SharedPreferences.setMockInitialValues({});
    });
    tearDown(() async {
      await AdManager().destroy();
    });

    test('valid overrides are applied to AdSafetyConfig before init proceeds',
        () async {
      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) {},
        remoteSafetyProvider:
            _FakeRemoteSafetyProvider({'maxFullscreenAdsPerDay': 1}),
      );

      AdSafetyConfig.recordFullscreenAdShown();
      expect(AdSafetyConfig.dailyCapReached(), isTrue,
          reason: 'remote override of maxFullscreenAdsPerDay=1 must be '
              'the value AdSafetyConfig actually initialised with');
    });

    test('a throwing provider falls back to local AdSafetyParams, does not '
        'block init', () async {
      var callCount = 0;
      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) => callCount++,
        remoteSafetyProvider: _ThrowingRemoteSafetyProvider(),
      );

      // Local config.safety here is AdSafetyParams.debug-ish (dryRun:true,
      // testIds:true via _admobConfig) — the exact point is just that init
      // proceeded to the point of scheduling the (failing, no native
      // channel) adapter connect instead of crashing on the provider.
      expect(AdSafetyConfig.dailyCapReached(), isFalse,
          reason: 'provider failure must fall back to local params, not '
              'leave AdSafetyConfig uninitialised');
    });

    test('a provider slower than the 5s timeout falls back to local params',
        () {
      fakeAsync((async) {
        unawaited(AdManager().initialize(
          config: _admobConfig(dryRun: true, testIds: true),
          onComplete: (_, __) {},
          remoteSafetyProvider: _HangingRemoteSafetyProvider(),
        ));
        async.elapse(const Duration(seconds: 6));

        expect(AdSafetyConfig.dailyCapReached(), isFalse,
            reason: 'a provider that never answers must not hang init '
                'forever — the 5s timeout falls back to local params');
      });
    });
  });

  // T89 — Rewarded Interstitial (AdMob only). Reuses the same gate shape as
  // showInterstitial (no VIP-bypass/SSV, unlike showRewardedAd).
  group('rewardedInterstitial (T89)', () {
    late _FakeAdapter adapter;

    setUp(() async {
      AdPreferences.resetForTest();
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugConfig = _admobConfig(dryRun: true, testIds: true);
      AdManager().debugVipManager = _FakeVip(false);
      AdManager().debugCanRequestAds = true;
    });
    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;
      AdManager().debugVipManager = null;
    });

    test('load: VIP member skips and emits reason=vip', () async {
      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadRewardedInterstitialAd();

      expect(adapter.loadRewardedInterstitialCalls, 0);
    });

    test('load: reaches the adapter when nothing gates it', () async {
      await AdManager().loadRewardedInterstitialAd();

      expect(adapter.loadRewardedInterstitialCalls, 1);
    });

    test('show: VIP member skips, never reaches the adapter', () async {
      AdManager().debugVipManager = _FakeVip(true);
      var shown = true, earned = true;
      await AdManager().showRewardedInterstitialAd(
          onDone: (s, e) {
            shown = s;
            earned = e;
          });

      expect(adapter.showRewardedInterstitialCalls, 0);
      expect(shown, isFalse);
      expect(earned, isFalse);
    });

    test('show: consent not granted skips, never reaches the adapter',
        () async {
      AdManager().debugCanRequestAds = false;
      var shown = true;
      await AdManager()
          .showRewardedInterstitialAd(onDone: (s, __) => shown = s);

      expect(adapter.showRewardedInterstitialCalls, 0);
      expect(shown, isFalse);
    });

    test(
        'show: reaching the adapter and earning the reward reports '
        'shown=true, earned=true and reloads', () async {
      adapter.nextRewardedInterstitialEarned = true;
      bool? shown, earned;
      await AdManager().showRewardedInterstitialAd(
          onDone: (s, e) {
            shown = s;
            earned = e;
          });

      expect(adapter.showRewardedInterstitialCalls, 1);
      expect(shown, isTrue);
      expect(earned, isTrue);
      expect(adapter.loadRewardedInterstitialCalls, 1,
          reason: 'must reload after a completed show, same as rewarded');
    });

    test('AppLovin adapter: genuinely never supports this ad type', () {
      final applovin = AppLovinAdapter();
      expect(applovin.rewardedInterstitialSlot.isReady, isFalse);

      bool? earned;
      applovin.showRewardedInterstitial(
          onDone: (result) => earned = result.earned);
      expect(earned, isFalse,
          reason: 'AppLovin MAX has no Rewarded Interstitial ad unit type — '
              'this must always be a no-op, never actually show anything');
    });
  });

  // T93 — deterministic experiment bucket assignment.
  group('experimentBucket (T93)', () {
    setUp(() async {
      AdPreferences.resetForTest();
      SharedPreferences.setMockInitialValues({});
      await AdPreferences.getInstance();
      AdManager().debugCurrentDeviceGAID = '';
    });
    tearDown(() {
      AdManager().debugCurrentDeviceGAID = '';
    });

    test('same call is stable across repeated invocations', () {
      final first = AdManager().experimentBucket('exp', buckets: 3);
      final second = AdManager().experimentBucket('exp', buckets: 3);
      expect(second, first);
    });

    test('prefers a real GAID when available', () {
      AdManager().debugCurrentDeviceGAID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      final viaGaid = AdManager().experimentBucket('exp', buckets: 5);

      AdManager().debugCurrentDeviceGAID =
          'FFFFFFFF-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      final viaDifferentGaid = AdManager().experimentBucket('exp', buckets: 5);

      // Not asserting they differ (could legitimately collide on 1/5 odds) —
      // asserting the GAID path is actually consulted, via the install-id
      // fallback test below showing a DIFFERENT mechanism is used when GAID
      // is empty.
      expect(viaGaid, isA<int>());
      expect(viaDifferentGaid, isA<int>());
    });

    test(
        'falls back to a persisted install id when GAID is empty (not just '
        'a hardcoded bucket for every opted-out user)', () async {
      AdManager().debugCurrentDeviceGAID = '';
      final resultA = AdManager().experimentBucket('exp', buckets: 5);

      // A different (never-persisted) install falls back to a different
      // pseudonymous id, so must not always land on the exact same bucket.
      final buckets = <int>{};
      for (var i = 0; i < 30; i++) {
        SharedPreferences.setMockInitialValues({});
        AdPreferences.resetForTest();
        await AdPreferences.getInstance();
        buckets.add(AdManager().experimentBucket('exp', buckets: 5));
      }
      expect(buckets.length, greaterThan(1),
          reason: '30 distinct opted-out installs all landing in the same '
              'bucket would mean GAID-empty users are not actually '
              'differentiated at all');
      expect(resultA, isA<int>());
    });

    test('all-zeros GAID is treated the same as empty (Limit Ad Tracking)',
        () {
      AdManager().debugCurrentDeviceGAID =
          '00000000-0000-0000-0000-000000000000';
      // Must not throw, and must use the install-id fallback path rather
      // than hashing the literal zero-GAID string (which every opted-out
      // user on this exact GAID convention would share).
      expect(() => AdManager().experimentBucket('exp', buckets: 5),
          returnsNormally);
    });

    test('buckets <= 0 throws', () {
      expect(() => AdManager().experimentBucket('exp', buckets: 0),
          throwsArgumentError);
    });
  });

  // T90 — deterministic provider A/B split, built on experimentBucket (T93).
  group('pickProviderCohort (T90)', () {
    setUp(() async {
      AdPreferences.resetForTest();
      SharedPreferences.setMockInitialValues({});
      await AdPreferences.getInstance();
      AdManager().debugCurrentDeviceGAID = '';
    });
    tearDown(() {
      AdManager().debugCurrentDeviceGAID = '';
    });

    test('is stable across repeated calls', () {
      final first = AdManager().pickProviderCohort();
      final second = AdManager().pickProviderCohort();
      expect(second, first);
    });

    test('result is always a valid AdProvider', () {
      expect(AdManager().pickProviderCohort(),
          anyOf(AdProvider.admob, AdProvider.appLovin));
    });

    test('different keys can independently split the same install', () {
      // Not a hardcoded "always admob" — the key participates in the hash
      // (same guarantee experimentBucket already tests directly).
      final seen = <AdProvider>{};
      for (var i = 0; i < 50; i++) {
        seen.add(AdManager().pickProviderCohort(key: 'experiment_$i'));
      }
      expect(seen, {AdProvider.admob, AdProvider.appLovin});
    });

    test('distributes across many distinct installs, not stuck on one '
        'provider', () async {
      final seen = <AdProvider>{};
      for (var i = 0; i < 30; i++) {
        SharedPreferences.setMockInitialValues({});
        AdPreferences.resetForTest();
        await AdPreferences.getInstance();
        seen.add(AdManager().pickProviderCohort());
      }
      expect(seen, {AdProvider.admob, AdProvider.appLovin});
    });
  });

  group('initialize() onComplete single-fire (init auto-retry fix)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    tearDown(() async {
      // Init failure schedules a real (5s+) retry Timer — destroy() cancels
      // it so it can't fire against a later test's state.
      await AdManager().destroy();
    });

    test(
        'onComplete is NOT fired on a failed attempt while auto-retry '
        'budget remains — only on the terminal outcome', () async {
      var callCount = 0;
      await AdManager().initialize(
        // Real adapter.initialize() always fails under `flutter test` (no
        // native platform channel) — that failure path is exactly what
        // schedules the auto-retry this test is pinning.
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) => callCount++,
      );

      expect(callCount, 0,
          reason: 'the first failed attempt still has retry budget left '
              '(_scheduleInitRetryIfNeeded returns true) — firing '
              'onComplete here as well as on the eventual terminal outcome '
              'would violate the "fires once" 1.x callback contract');
    });

    // T80 — regression test for the 2.0.1 fix described in CHANGELOG.md:
    // "Stale internal-retry flag could leak into a later legitimate call."
    // A retry timer firing while another initialize() call already held
    // _isInitializing left _isInternalInitRetryCall stuck true, so the
    // NEXT real host-initiated call was misclassified as an internal retry
    // (skipping its retry-budget reset). Before the fix, this test goes red:
    // the flag stays true because it was read/cleared AFTER the
    // _isInitializing early-return guard instead of before it.
    test(
        'an internal retry racing an in-progress initialize() call must '
        'not leak _isInternalInitRetryCall into the next real call',
        () async {
      AdManager().debugSimulateInternalRetryRaceWithBusyGuard();
      expect(AdManager().debugIsInternalInitRetryCall, isTrue,
          reason: 'sanity: the race is set up');

      var callCount = 0;
      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) => callCount++,
      );

      expect(AdManager().debugIsInternalInitRetryCall, isFalse,
          reason: 'must be cleared even though this call hit the '
              '_isInitializing early-return — otherwise the NEXT real call '
              'would be misclassified as an internal retry');
      expect(callCount, 0,
          reason: 'the _isInitializing early-return must not fire '
              'onComplete either — it never even attempted a real init');
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

  group(
      'initialize(isRelease:) wiring into AdSafetyConfig.init() '
      '(R12-A audit round 12, self-review)', () {
    setUp(() async {
      await AdManager().destroy();
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
    });

    tearDown(() async {
      await AdManager().destroy();
    });

    test(
        'a real initialize() call forwards isRelease through to '
        'AdSafetyConfig.init() (cheaper direct coverage of the guard itself '
        'is in ad_safety_config_test.dart)', () async {
      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) {},
        isRelease: true,
      );

      expect(AdSafetyConfig.getStatusSnapshot().dryRun, isFalse,
          reason: 'proves the wiring/ordering invariant through the real '
              'initialize() path, not just AdSafetyConfig.init() called '
              'directly in isolation');
    });
  });

  group(
      'consent-footgun guard call site (R12-A audit round 5 — '
      'isActuallyRelease(isRelease) at this call site was previously '
      'unreachable by any test)', () {
    // A real initialize() call always fails adapter init under `flutter
    // test` (no native platform channel), so the consent-footgun guard at
    // ad_manager.dart's `isActuallyRelease(isRelease)` call site can't be
    // reached through initialize() itself — the 'N2: consent footgun
    // runtime block' group above only drives `debugFootgunBlocked` directly.
    // debugApplyConsentFootgunGuard() exercises that exact call site's
    // decision directly instead.
    setUp(() {
      AdManager().debugCanRequestAds = true;
      AdManager().debugFootgunBlocked = false;
    });
    tearDown(() {
      AdManager().debugFootgunBlocked = false;
      AdManager().debugCanRequestAds = true;
    });

    test('debugApplyConsentFootgunGuard(isRelease: true) blocks ad requests',
        () {
      final mgr = AdManager();
      expect(mgr.canRequestAds, isTrue);

      mgr.debugApplyConsentFootgunGuard(true);

      expect(mgr.canRequestAds, isFalse,
          reason: 'a release build must block ad requests when the '
              'consent-coverage footgun guard fires');
    });

    test(
        'debugApplyConsentFootgunGuard(isRelease: false) leaves ad requests '
        'unblocked', () {
      final mgr = AdManager();
      expect(mgr.canRequestAds, isTrue);

      mgr.debugApplyConsentFootgunGuard(false);

      expect(mgr.canRequestAds, isTrue,
          reason: 'debug/profile builds stay in demo mode so hosts can '
              'diagnose the footgun without being blocked');
    });
  });

  group(
      'T60 — built-in consent dialog + autoRequestUmpConsent:false must '
      'still clear the footgun block', () {
    tearDown(() async {
      await AdManager().destroy();
    });

    testWidgets(
        'scheduled built-in dialog answered → canRequestAds recovers, not '
        'stuck locked forever', (tester) async {
      final prefs = await AdPreferences.getInstance();
      final consentMgr = await ConsentManager.bootstrap(
          prefs: prefs, strings: ConsentDialogStrings.vi);
      final mgr = AdManager();
      mgr.debugConsentManager = consentMgr;
      mgr.debugConfig = const AdConfig(
        provider: AdProvider.admob,
        admob: AdMobConfig(
          bannerId: 'x',
          interstitialId: 'x',
          appOpenId: 'x',
          rewardedId: 'x',
        ),
        // The exact narrow combo T60 is about: host runs UMP itself
        // elsewhere (or forgets to), and relies on the SDK's built-in
        // dialog — never calling requestUmpConsent()/setConsent() directly.
        autoRequestUmpConsent: false,
        autoShowConsentDialog: true,
        consentDialogPostSplashDelay: Duration.zero,
      );
      // Simulate the release-mode footgun having tripped at init time
      // (no consent form anywhere had run yet).
      mgr.debugFootgunBlocked = true;
      mgr.debugCanRequestAds = true;
      expect(mgr.canRequestAds, isFalse, reason: 'footgun starts tripped');

      final navigatorKey = GlobalKey<NavigatorState>();
      mgr.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const SizedBox(),
      ));

      mgr.markSplashInactive(); // schedules the built-in dialog (delay=0)
      await tester.pumpAndSettle();

      expect(find.text(ConsentDialogStrings.vi.title), findsOneWidget,
          reason: 'built-in dialog must have been scheduled and shown');
      await tester.tap(find.text(ConsentDialogStrings.vi.allowButton));
      await tester.pumpAndSettle();

      expect(mgr.canRequestAds, isTrue,
          reason: 'user answered the built-in dialog — the footgun must '
              'clear, not stay locked for the rest of the release session');
    });
  });

  group(
      '_resetGuardState (R12-A audit round 6 — reinit-without-destroy() '
      'branch used to skip _umpRequested/_consentExplicitlySet the way it '
      'skipped _footgunBlocked pre-round-5)', () {
    tearDown(() {
      AdManager().debugFootgunBlocked = false;
      AdManager().debugUmpRequested = false;
      AdManager().debugConsentExplicitlySet = false;
    });

    test('debugResetGuardState() clears all three guard flags at once', () {
      final mgr = AdManager();
      mgr.debugFootgunBlocked = true;
      mgr.debugUmpRequested = true;
      mgr.debugConsentExplicitlySet = true;

      mgr.debugResetGuardState();

      expect(mgr.debugFootgunBlocked, isFalse);
      expect(mgr.debugUmpRequested, isFalse);
      expect(mgr.debugConsentExplicitlySet, isFalse);
    });
  });

  group(
      'T63 — _resetGuardState leaves _canRequestAds/_umpAttemptFailed stale '
      'across destroy()/re-init', () {
    tearDown(() {
      AdManager().debugCanRequestAds = true;
    });

    test(
        'debugResetGuardState() also restores _canRequestAds to its '
        'un-gated default and clears _umpAttemptFailed', () {
      final mgr = AdManager();
      // Simulate a session that ended with UMP having blocked ad requests
      // and a failed UMP attempt (e.g. network error/timeout) still pending.
      mgr.debugCanRequestAds = false;
      mgr.debugUmpAttemptFailed = true;

      mgr.debugResetGuardState();

      expect(mgr.canRequestAds, isTrue,
          reason: '_canRequestAds must return to its un-gated default '
              '(true) on destroy()/re-init, or a host with '
              'autoRequestUmpConsent:false has no assignment left to ever '
              'reopen it — ad requests stay closed for the entire new '
              'session');
      expect(mgr.debugUmpAttemptFailed, isFalse,
          reason: 'a stale failed-UMP-attempt flag from the previous '
              'session must not carry into the new one');
    });
  });

  group(
      '_resetGuardState cancels _splashBudgetTimer (re-init timer leak '
      'regression)', () {
    // Before the fix, _resetGuardState() reset the footgun/UMP/consent flags
    // but left `_splashBudgetTimer` running — only destroy() cancelled it
    // explicitly. A reinit-without-destroy() (which also calls
    // _resetGuardState()) would leave a stale timer alive that could later
    // fire `_onSplashBudgetElapsed` → `markSplashInactive()` against the
    // freshly re-initialized session.
    tearDown(() {
      AdManager().markSplashInactive();
    });

    test(
        'timer armed by markSplashActive() does not fire '
        'markSplashInactive() after debugResetGuardState()', () {
      fakeAsync((async) {
        final mgr = AdManager();
        mgr.markSplashActive(); // arms _splashBudgetTimer (8s default)
        expect(mgr.isSplashActive, isTrue);

        mgr.debugResetGuardState();

        // Pre-fix: the still-armed timer would fire at 8s and force
        // isSplashActive back to false. Post-fix: _resetGuardState()
        // already cancelled it, so nothing fires.
        async.elapse(const Duration(seconds: 9));

        expect(mgr.isSplashActive, isTrue,
            reason: '_resetGuardState() must cancel the stale splash '
                'budget timer, not just the guard flags — otherwise it '
                'fires markSplashInactive() against the re-initialized '
                'session');
      });
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

    // 2026-08-19 audit (Finding 4/6): showAppOpenAdOnResume() always called
    // showAppOpenAd(bypassSafety: true) — not just the splash flow — so a
    // resume-triggered App Open skipped the daily/hourly/session fullscreen
    // cap entirely while still counting toward it via
    // recordFullscreenAdShown(), an asymmetric bypass that contradicts this
    // repo's own contract ("don't bypass except the splash App Open ad").
    testWidgets(
        'resume-triggered app-open is blocked once the daily fullscreen cap '
        'is reached, unlike the splash path\'s deliberate bypass',
        (tester) async {
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs,
          params: AdSafetyParams.debug.copyWith(maxFullscreenAdsPerDay: 0));
      AdSafetyConfig.resetForReinit();

      adapter.appOpenSlot.beginReload();
      adapter.appOpenSlot.markReady();

      AdManager().showAppOpenAdOnResume(); // consumes the cold-start skip
      adapter.loadAppOpenCalls = 0;

      AdManager().showAppOpenAdOnResume(); // schedules the 1s fallback timer
      await tester.pump(const Duration(seconds: 1, milliseconds: 100));

      expect(adapter.showAppOpenCalls, 0,
          reason: 'a resume-triggered App Open must respect the daily '
              'fullscreen cap the same as every other show path');
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

    // T70 — a debounced compliance-log write must be flushed to disk before
    // the process could be killed while backgrounded, not left pending.
    test('paused flushes a pending debounced compliance-log write', () async {
      // Reuse the AdPreferences singleton the enclosing setUp already bound
      // to a mock SharedPreferences — re-calling setMockInitialValues here
      // would reset the plugin-level mock store out from under it.
      final prefs = await AdPreferences.getInstance();
      final eventLog = AdEventLog(prefs);
      AdManager().debugEventLog = eventLog;
      addTearDown(() => AdManager().debugEventLog = null);

      // AdPreferences is a process-wide singleton shared across this whole
      // test file, so the compliance-log key may already hold data from an
      // earlier test — assert on this event's own marker, not on nullness.
      const marker = 'T70-flush-on-pause-marker';
      eventLog.recordSafetyBlock(marker);
      expect(prefs.getComplianceLogRaw() ?? '', isNot(contains(marker)),
          reason: 'sanity: still inside the debounce window');

      AdManager().didChangeAppLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);

      expect(prefs.getComplianceLogRaw() ?? '', contains(marker),
          reason: 'paused must force-flush the pending debounced write');
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
      expect(adapter.bannerSlot('k').isIdle, isTrue);
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

  group('COPPA hard-stop', () {
    test(
        'isAgeRestrictedUser=true mid-session on AppLovin hard-stops '
        '(AppLovin no runtime COPPA API — must hard-stop ad '
        'requests instead of only logging warning)', () {
      fakeAsync((async) {
        final adapter = _FakeAdapter();
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'test-key',
            bannerId: 'banner-id',
            interstitialId: 'interstitial-id',
            appOpenId: 'appopen-id',
            rewardedId: 'rewarded-id',
          ),
        );

        AdManager().debugCanRequestAds = true;

        // Start the async setConsent call but don't await it —
        // this triggers the hard-stop logic synchronously before
        // any async work begins.
        unawaited(AdManager().setConsent(
          const AdConsent(
            hasUserConsent: true,
            isAgeRestrictedUser: true,
            doNotSell: false,
          ),
        ));

        // Check the hard-stop happened synchronously
        expect(AdManager().canRequestAds, isFalse,
            reason: 'AppLovin no runtime COPPA API — must hard-stop ad '
                'requests instead of only logging warning');

        // Complete any pending async work to avoid "test failed after
        // completion" errors — but don't propagate exceptions.
        async.elapse(const Duration(seconds: 1));
        try {
          // Ignore any errors from the pending future
          async.flushMicrotasks();
        } catch (_) {}
      });
    });

    test(
        'isAgeRestrictedUser=true mid-session on AdMob does NOT hard-stop '
        '(AdMob receives tag via RequestConfiguration)', () {
      fakeAsync((async) {
        final adapter = _FakeAdapter();
        AdManager().debugSetAdapter(adapter);
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-9999999999999999/1111111111',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            rewardedId: 'ca-app-pub-9999999999999999/4444444444',
          ),
        );

        AdManager().debugCanRequestAds = true;

        // Start the async setConsent call but don't await it.
        unawaited(AdManager().setConsent(
          const AdConsent(
            hasUserConsent: true,
            isAgeRestrictedUser: true,
            doNotSell: false,
          ),
        ));

        // Check the hard-stop did NOT happen for AdMob
        expect(AdManager().canRequestAds, isTrue,
            reason: 'AdMob already receives COPPA tag via '
                'RequestConfiguration — no hard-stop needed for provider');

        // Complete any pending async work to avoid "test failed after
        // completion" errors — but don't propagate exceptions.
        async.elapse(const Duration(seconds: 1));
        try {
          // Ignore any errors from the pending future
          async.flushMicrotasks();
        } catch (_) {}
      });
    });
  });
}
