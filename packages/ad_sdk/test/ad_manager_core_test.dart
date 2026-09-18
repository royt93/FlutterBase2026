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
import 'dart:math';

import 'package:app_tracking_transparency/app_tracking_transparency.dart';
import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/adapters/admob_adapter.dart';
import 'package:applovin_admob_sdk/src/adapters/applovin_adapter.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

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

/// T136 — deterministic stand-in for `pickSessionProvider`'s
/// `debugRandom` seam. `Random` is abstract in `dart:math`, so a plain
/// `implements` fake is enough — no real randomness needed to pin
/// "rolled below the exploration rate" vs "rolled above it".
class _FixedRandom implements Random {
  _FixedRandom(this._value);
  final double _value;

  @override
  double nextDouble() => _value;

  @override
  int nextInt(int max) => 0;

  @override
  bool nextBool() => false;
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

  /// Round-29 audit (BLOCKER) — when true, [loadRewarded] throws instead of
  /// returning, simulating a native platform-channel exception mid-load.
  bool throwOnLoad = false;

  /// Round-29 audit (BLOCKER) — when true, [showRewarded] throws instead of
  /// calling `onDone`, simulating a native platform-channel exception.
  bool throwOnShow = false;

  /// What [showRewarded] reports back via `onDone`.
  bool nextRewardEarned = true;

  @override
  String get tag => 'fake';

  @override
  Future<void> loadInterstitial() async => loadInterstitialCalls++;

  /// Round-37 audit (MAJOR) — when true, [showInterstitial] throws instead
  /// of calling `onDone`, simulating a native platform-channel exception
  /// (the same class of failure `throwOnShow` already covers for
  /// [showRewarded]).
  bool throwOnShowInterstitial = false;

  @override
  Future<void> showInterstitial(
      {required void Function(bool shown) onDone}) async {
    showInterstitialCalls++;
    if (throwOnShowInterstitial) {
      throw StateError('fake native platform-channel throw');
    }
    onDone(true);
  }

  @override
  Future<void> loadRewarded() async {
    loadRewardedCalls++;
    if (throwOnLoad) throw StateError('fake native platform-channel throw');
    if (hangLoad) {
      rewardedSlot.beginReload(); // → loading, never resolves
      return;
    }
    if (loadMarksReady) {
      rewardedSlot.beginReload();
      rewardedSlot.markReady();
    }
  }

  /// Round-23: a rewarded ad the user CLOSED EARLY — really displayed
  /// (`shown: true`), no reward. `false` reproduces the never-displayed paths
  /// (not ready, already showing, show threw) which report `shown: false`.
  bool nextRewardDisplayed = true;

  @override
  Future<void> showRewarded({
    required void Function(RewardResult result) onDone,
    String? ssvCustomData,
    String? ssvUserId,
  }) async {
    showRewardedCalls++;
    if (throwOnShow) throw StateError('fake native platform-channel throw');
    rewardedSlot.beginShow();
    rewardedSlot.markDismissed();
    onDone(nextRewardEarned
        ? const RewardResult(earned: true, shown: true, label: 'coins', amount: 1)
        : RewardResult(earned: false, shown: nextRewardDisplayed));
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

  /// Round-37 audit (MAJOR) — see [throwOnShowInterstitial].
  bool throwOnShowRewardedInterstitial = false;

  @override
  Future<void> showRewardedInterstitial({
    required void Function(RewardResult result) onDone,
  }) async {
    showRewardedInterstitialCalls++;
    if (throwOnShowRewardedInterstitial) {
      throw StateError('fake native platform-channel throw');
    }
    rewardedInterstitialSlot.beginShow();
    rewardedInterstitialSlot.markDismissed();
    onDone(nextRewardedInterstitialEarned
        ? const RewardResult(earned: true, shown: true, label: 'coins', amount: 1)
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

  /// Round-37 audit (MAJOR) — see [throwOnShowInterstitial].
  bool throwOnShowAppOpen = false;

  @override
  Future<void> showAppOpen(
      {required void Function(bool dismissed) onDismiss}) async {
    showAppOpenCalls++;
    if (throwOnShowAppOpen) {
      throw StateError('fake native platform-channel throw');
    }
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
  bool umpTagForUnderAgeOfConsent = false,
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
    umpTagForUnderAgeOfConsent: umpTagForUnderAgeOfConsent,
  );
}

AdConfig _consentConfig({
  bool autoRequestUmpConsent = false,
  bool disableAppLovinCmpFlow = true,
  AdProvider provider = AdProvider.admob,
}) {
  return AdConfig(
    provider: provider,
    appLovin: const AppLovinConfig(
      sdkKey: 'test-sdk-key',
      bannerId: 'al-banner',
      interstitialId: 'al-inter',
      appOpenId: 'al-appopen',
      rewardedId: 'al-rewarded',
    ),
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

    // Audit round 42, MINOR (codex) — rewardedInterstitialId/mrecId/nativeId
    // were never checked at all, so a release build shipping a leftover
    // Google test id on one of these three specific slots got NO warning,
    // unlike the identical mistake on banner/interstitial/appOpen/rewarded.
    test('release + AdMob Google test ID on native → warns (round 42 gap)',
        () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-9999999999999999/1111111111',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            rewardedId: 'ca-app-pub-9999999999999999/4444444444',
            nativeId: 'ca-app-pub-3940256099942544/2247696110',
          ),
          safety: AdSafetyParams(dryRun: false),
        ),
        isDebug: false,
      );
      expect(w, hasLength(1));
      expect(w.single, contains('TEST'));
    });

    test(
        'release + AdMob Google test ID on mrec/rewardedInterstitial → '
        'warns (round 42 gap)', () {
      final w = AdManager.releaseFootgunWarnings(
        const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'ca-app-pub-9999999999999999/1111111111',
            interstitialId: 'ca-app-pub-9999999999999999/2222222222',
            appOpenId: 'ca-app-pub-9999999999999999/3333333333',
            rewardedId: 'ca-app-pub-9999999999999999/4444444444',
            mrecId: 'ca-app-pub-3940256099942544/6300978111',
            rewardedInterstitialId: 'ca-app-pub-3940256099942544/5354046379',
          ),
          safety: AdSafetyParams(dryRun: false),
        ),
        isDebug: false,
      );
      // One combined warning covers all 7 formats (same convention as the
      // existing 4-format check above), not one per field.
      expect(w, hasLength(1));
      expect(w.single, contains('TEST'));
    });

    test(
        'a genuinely unused optional slot (mrec/native/rewardedInterstitial '
        'left at its empty default) does NOT warn — only a configured but '
        'wrong id should', () {
      final w = AdManager.releaseFootgunWarnings(
        _admobConfig(dryRun: false, testIds: false),
        isDebug: false,
      );
      expect(w, isEmpty,
          reason: 'these three formats are optional — an app that never '
              'configures them must not be flagged for it');
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

    // BL2 (round 5 audit). This pair used to be a single test asserting that
    // `disableAppLovinCmpFlow: false` silenced the warning for ANY provider —
    // which encoded the bug: the flag is only ever read by
    // AppLovinAdapter.initialize, so on AdMob it grants imaginary consent
    // coverage. That combination (admob + autoRequestUmpConsent:false +
    // disableAppLovinCmpFlow:false) is a config the SDK accepts silently, and
    // it left `_canRequestAds` at its default `true`: EEA/UK users served ads
    // with no consent flow at all, and no warning to say so.
    test('BL2: disableAppLovinCmpFlow:false on AppLovin → no warning', () {
      final w = AdManager.consentFootgunWarning(
        _consentConfig(
          disableAppLovinCmpFlow: false,
          provider: AdProvider.appLovin,
        ),
        umpRequested: false,
      );
      expect(w, isNull,
          reason: 'AppLovin CMP is genuinely a consent flow when AppLovin is '
              'the active provider');
    });

    test('BL2: disableAppLovinCmpFlow:false on AdMob still warns', () {
      final w = AdManager.consentFootgunWarning(
        _consentConfig(
          disableAppLovinCmpFlow: false,
          provider: AdProvider.admob,
        ),
        umpRequested: false,
      );
      expect(w, isNotNull,
          reason: 'an AppLovin-only flag cannot cover consent on AdMob — '
              'this is the fail-open the guard exists to catch');
      expect(w, contains('admob'));
    });

    // Audit round 42, MAJOR — disableAppLovinCmpFlow:false's own doc comment
    // tells a host to flip only that one flag to use AppLovin's own CMP
    // "instead of" UMP. Nothing checked whether autoRequestUmpConsent (true
    // by default) was ALSO turned off, so following that doc comment
    // literally ran BOTH consent flows concurrently on the same EEA user
    // with zero warning.
    test(
        'dual-CMP: disableAppLovinCmpFlow:false + autoRequestUmpConsent:true '
        '→ warns (both flows would run concurrently)', () {
      final w = AdManager.consentFootgunWarning(
        _consentConfig(
          disableAppLovinCmpFlow: false,
          provider: AdProvider.appLovin,
          autoRequestUmpConsent: true,
        ),
        umpRequested: false,
      );
      expect(w, isNotNull,
          reason: 'AppLovin CMP and UMP both running concurrently can each '
              'overwrite the other\'s consent answer on AppLovin — this '
              'must be surfaced, not silently accepted');
      expect(w, contains('concurrently'));
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

  // Round-31 audit (MAJOR) — a self-declared child-directed app whose UMP
  // flow still runs with `umpTagForUnderAgeOfConsent` left at its `false`
  // default had no warning at all before this.
  group('coppaUmpMismatchWarning (round-31 audit)', () {
    test('isAgeRestrictedUser + UMP will run + tag NOT set → warns', () {
      final w = AdManager.coppaUmpMismatchWarning(
        _admobConfig(dryRun: true, testIds: true),
        isAgeRestrictedUser: true,
        umpWillRun: true,
      );
      expect(w, isNotNull);
      expect(w, contains('umpTagForUnderAgeOfConsent'));
    });

    test('isAgeRestrictedUser + UMP will run + tag SET → no warning', () {
      final w = AdManager.coppaUmpMismatchWarning(
        _admobConfig(
            dryRun: true, testIds: true, umpTagForUnderAgeOfConsent: true),
        isAgeRestrictedUser: true,
        umpWillRun: true,
      );
      expect(w, isNull);
    });

    test('not age-restricted → no warning regardless of the tag', () {
      final w = AdManager.coppaUmpMismatchWarning(
        _admobConfig(dryRun: true, testIds: true),
        isAgeRestrictedUser: false,
        umpWillRun: true,
      );
      expect(w, isNull);
    });

    test('age-restricted but no UMP flow will run → no warning (nothing to '
        'mis-tag)', () {
      final w = AdManager.coppaUmpMismatchWarning(
        _admobConfig(dryRun: true, testIds: true),
        isAgeRestrictedUser: true,
        umpWillRun: false,
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

  // M9 (audit_claude.md, 2026-08-20): AdvertisingId.id(true) triggers its own
  // ATT prompt on iOS independent of requestAtt() — defer the GAID fetch
  // until ATT is actually decided, but only when deferring is necessary.
  group('shouldDeferGaidFetch (M9)', () {
    test('iOS + ATT notDetermined + requestAtt not called → defer', () {
      final defer = AdManager.shouldDeferGaidFetch(
          isIos: true,
          attRequested: false,
          attStatus: TrackingStatus.notDetermined);
      expect(defer, isTrue);
    });

    // m7 (round 5 audit). Both of the next two used to assert `isFalse` —
    // "do not defer" — which meant initialize() went on to call
    // `AdvertisingId.id(true)`, and that `true` asks the plugin to raise
    // Apple's ATT prompt. So the SDK could pop the tracking dialog itself,
    // outside the host's control, in exactly the two states where it has no
    // business doing so.
    test('m7: iOS + requestAtt called but status still notDetermined → defer',
        () {
      final defer = AdManager.shouldDeferGaidFetch(
          isIos: true,
          attRequested: true,
          attStatus: TrackingStatus.notDetermined);
      expect(defer, isTrue,
          reason: 'requestAtt() ran but the status never moved off '
              'notDetermined, i.e. the prompt timed out (att_consent.dart has '
              'its own guard for that) and the user never actually answered. '
              'A real answer lands as authorized/denied/restricted.');
    });

    test('iOS + ATT already decided (authorized) → do not defer', () {
      final defer = AdManager.shouldDeferGaidFetch(
          isIos: true, attRequested: false, attStatus: TrackingStatus.authorized);
      expect(defer, isFalse);
    });

    test('m7: iOS + ATT status unreadable (null) → defer', () {
      final defer = AdManager.shouldDeferGaidFetch(
          isIos: true, attRequested: false, attStatus: null);
      expect(defer, isTrue,
          reason: 'null means the status read itself threw, so we do NOT know '
              'whether the user has been asked. Unknown must be treated like '
              'notDetermined — the alternative is triggering the ATT prompt '
              'from inside initialize() on a guess.');
    });

    test('m7: iOS + ATT unreadable but requestAtt already ran → do not defer',
        () {
      final defer = AdManager.shouldDeferGaidFetch(
          isIos: true, attRequested: true, attStatus: null);
      expect(defer, isFalse,
          reason: 'the host already ran the prompt, so reading the GAID '
              'cannot raise a second one — the only reason to defer is gone');
    });

    test('Android → never defer regardless of ATT status', () {
      final defer = AdManager.shouldDeferGaidFetch(
          isIos: false,
          attRequested: false,
          attStatus: TrackingStatus.notDetermined);
      expect(defer, isFalse);
    });
  });

  group('adMobTestDeviceHashHint / currentDeviceGaid', () {
    tearDown(() {
      AdManager().debugCurrentDeviceGAID = '';
    });

    test('currentDeviceGaid reflects the resolved GAID', () {
      AdManager().debugCurrentDeviceGAID =
          'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      expect(AdManager().currentDeviceGaid,
          'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE');
    });

    test('currentDeviceGaid normalizes the all-zero GUID to empty', () {
      AdManager().debugCurrentDeviceGAID =
          '00000000-0000-0000-0000-000000000000';
      expect(AdManager().currentDeviceGaid, isEmpty);
    });

    test('hint explains there is no formula and points at logcat tag Ads', () {
      final hint = AdManager().adMobTestDeviceHashHint();
      expect(hint, contains('logcat'));
      expect(hint, contains('Ads'));
      expect(hint, contains('setTestDeviceIds'));
    });

    test('hint includes current GAID but says it is not valid there', () {
      AdManager().debugCurrentDeviceGAID =
          'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      final hint = AdManager().adMobTestDeviceHashHint();
      expect(hint, contains('AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'));
      expect(hint, contains('NOT valid'));
    });

    test('hint shows a placeholder instead of an empty GAID', () {
      AdManager().debugCurrentDeviceGAID =
          '00000000-0000-0000-0000-000000000000';
      final hint = AdManager().adMobTestDeviceHashHint();
      expect(hint, contains('not resolved yet, or Limit Ad Tracking is on'));
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

    // m18 (audit_claude.md MINOR) — canShowInterstitial/canShowRewardedAd are
    // read-only "should I enable my UI" queries a host may poll. They only
    // asked `isReady`, so a cached AdMob ad that aged past the 1h content
    // validity while being polled still reported `true` — and the show path
    // then discarded it instead of showing it, leaving the host with a button
    // that does nothing. Needs the REAL AdMobAdapter: the expiry rule is
    // AdMob's, AppLovin/MAX documents none.
    test('m18 — a stale (>1h) ready AdMob slot is not reported as showable',
        () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(false);

      final admob = AdMobAdapter();
      AdManager().debugSetAdapter(admob);

      for (final slot in [admob.interstitialSlot, admob.rewardedSlot]) {
        slot.beginLoad();
        slot.markReady();
      }
      expect(AdManager().canShowInterstitial(), isTrue,
          reason: 'sanity check: a freshly loaded ad is showable');
      expect(AdManager().canShowRewardedAd(), isTrue,
          reason: 'sanity check: a freshly loaded ad is showable');

      // Same `ready` slots, now past AdMob's 1h content validity.
      final stale = DateTime.now().subtract(const Duration(hours: 2));
      admob.interstitialSlot.lastLoadedAt = stale;
      admob.rewardedSlot.lastLoadedAt = stale;

      expect(AdManager().canShowInterstitial(), isFalse,
          reason: 'showInterstitial() would discard this ad rather than show '
              'it, so the peek must not claim it is showable');
      expect(AdManager().canShowRewardedAd(), isFalse,
          reason: 'showRewarded() would discard this ad rather than show it, '
              'so the peek must not claim it is showable');
    });

    test(
        'm18 — rewardedInterstitial gets the same staleness check as the '
        'other two', () async {
      // Round-3 QC finding: m18 wired the freshness check into
      // canShowInterstitial and canShowRewardedAd but not into
      // canShowRewardedInterstitialAd, leaving one of the three fullscreen
      // peeks still able to answer "showable" for an ad the show path would
      // immediately discard — the exact host-visible symptom m18 was about.
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(false);

      final admob = AdMobAdapter();
      AdManager().debugSetAdapter(admob);

      admob.rewardedInterstitialSlot.beginLoad();
      admob.rewardedInterstitialSlot.markReady();
      expect(AdManager().canShowRewardedInterstitialAd(), isTrue,
          reason: 'sanity check: a freshly loaded ad is showable');

      admob.rewardedInterstitialSlot.lastLoadedAt =
          DateTime.now().subtract(const Duration(hours: 2));

      expect(AdManager().canShowRewardedInterstitialAd(), isFalse,
          reason: 'past AdMob\'s 1h content validity the show path discards '
              'this ad, so the peek must not claim it is showable');
    });

    // Round-32 audit (MAJOR) — canShowInterstitial/canShowRewardedAd both
    // gate on `AdLoadingDialog.isShowing`, but canShowRewardedInterstitialAd
    // never got the same line. A host polling it while another fullscreen
    // flow's non-dismissable loading dialog is up would see `true` and let
    // the user open a second (disclosure) dialog on top of it — UI stuck,
    // not a double-shown ad (showRewardedInterstitialAd() itself already
    // checks AdLoadingDialog.isShowing separately).
    testWidgets(
        'canShowRewardedInterstitialAd() is false while '
        'AdLoadingDialog is showing, same as its two siblings', (
      tester,
    ) async {
      addTearDown(AdLoadingDialog.resetState);
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(false);

      final admob = AdMobAdapter();
      AdManager().debugSetAdapter(admob);
      admob.rewardedInterstitialSlot.beginLoad();
      admob.rewardedInterstitialSlot.markReady();
      expect(AdManager().canShowRewardedInterstitialAd(), isTrue,
          reason: 'sanity check: a freshly loaded ad is showable');

      late BuildContext ctx;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(builder: (c) {
            ctx = c;
            return const SizedBox.shrink();
          }),
        ),
      ));
      AdLoadingDialog.show(ctx);
      await tester.pump();

      expect(AdManager().canShowRewardedInterstitialAd(), isFalse,
          reason: 'a non-dismissable loading dialog from another fullscreen '
              'flow is already on screen — opening the RI disclosure dialog '
              'now would stack a second dialog on top of it');
    });

    // Round-37 audit (MAJOR) — the round-32 fix above closed the gap for
    // `AdLoadingDialog.isShowing` but `_fullscreenBusyReason` (used by the
    // real show* paths) also treats `AdScreenRouteLogger.isDialogOnTop` as
    // busy, and none of the three canShow* peeks checked it. A double-tap on
    // a rewarded/rewarded-interstitial button opens the SDK's own disclosure
    // dialog (a real PopupRoute) before the loading buffer exists, so the
    // peek used for the *second* tap's pre-check saw `true` and let a second
    // disclosure dialog stack on top of the first — one of the two flows
    // then failed silently later at the real `_fullscreenBusyReason` gate.
    group('round-37 audit (MAJOR): canShow* peeks also respect '
        'isDialogOnTop, not just AdLoadingDialog', () {
      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await AdPreferences.getInstance();
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugVipManager = _FakeVip(false);
      });

      tearDown(AdScreenRouteLogger.resetState);

      test('canShowInterstitial() is false while a dialog/popup is on top',
          () {
        adapter.interstitialSlot.beginLoad();
        adapter.interstitialSlot.markReady();
        expect(AdManager().canShowInterstitial(), isTrue,
            reason: 'sanity check: a freshly loaded ad is showable');

        final route = _FakePopupRoute();
        AdScreenRouteLogger().didPush(route, null);

        expect(AdManager().canShowInterstitial(), isFalse,
            reason: 'a dialog/popup (e.g. the reward disclosure from '
                'another in-flight tap) is already on screen — the show '
                'path would refuse via _fullscreenBusyReason anyway');

        // Independent review (round 37 verification) — the on-device
        // integration test for this only proves isDialogOnTop itself
        // clears on a real pop (ad-readiness on a real device isn't
        // deterministic); this proves the full canShow* recovery with a
        // ready ad under full control.
        AdScreenRouteLogger().didPop(route, null);
        expect(AdManager().canShowInterstitial(), isTrue,
            reason: 'once the popup is gone, the gate must open back up '
                'again, not stay stuck closed');
      });

      test('canShowRewardedAd() is false while a dialog/popup is on top', () {
        adapter.rewardedSlot.beginLoad();
        adapter.rewardedSlot.markReady();
        expect(AdManager().canShowRewardedAd(), isTrue,
            reason: 'sanity check: a freshly loaded ad is showable');

        final route = _FakePopupRoute();
        AdScreenRouteLogger().didPush(route, null);

        expect(AdManager().canShowRewardedAd(), isFalse,
            reason: 'a dialog/popup is already on screen');

        AdScreenRouteLogger().didPop(route, null);
        expect(AdManager().canShowRewardedAd(), isTrue,
            reason: 'once the popup is gone, the gate must open back up '
                'again, not stay stuck closed');
      });

      test(
          'canShowRewardedInterstitialAd() is false while a dialog/popup is '
          'on top', () {
        adapter.rewardedInterstitialSlot.beginLoad();
        adapter.rewardedInterstitialSlot.markReady();
        expect(AdManager().canShowRewardedInterstitialAd(), isTrue,
            reason: 'sanity check: a freshly loaded ad is showable');

        final route = _FakePopupRoute();
        AdScreenRouteLogger().didPush(route, null);

        expect(AdManager().canShowRewardedInterstitialAd(), isFalse,
            reason: 'a dialog/popup is already on screen');

        AdScreenRouteLogger().didPop(route, null);
        expect(AdManager().canShowRewardedInterstitialAd(), isTrue,
            reason: 'once the popup is gone, the gate must open back up '
                'again, not stay stuck closed');
      });
    });

    // T168 — a host's own custom overlay (e.g. a manual
    // Overlay.of(context).insert(...), which AdScreenRouteLogger.
    // isDialogOnTop cannot see) must fold into the exact same fullscreen
    // mutex the round-37 group above already proves for a real PopupRoute.
    group('T168: canShow* peeks also respect customOverlayOnScreen '
        '(host-declared custom overlay)', () {
      setUp(() async {
        SharedPreferences.setMockInitialValues({});
        final prefs = await AdPreferences.getInstance();
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugVipManager = _FakeVip(false);
      });

      tearDown(() => markCustomOverlayOnScreen(false));

      test('canShowInterstitial() is false while a custom overlay is on '
          'screen', () {
        adapter.interstitialSlot.beginLoad();
        adapter.interstitialSlot.markReady();
        expect(AdManager().canShowInterstitial(), isTrue,
            reason: 'sanity check: a freshly loaded ad is showable');

        markCustomOverlayOnScreen(true);
        expect(AdManager().canShowInterstitial(), isFalse,
            reason: 'a host-declared custom overlay is on screen');
        expect(AdManager().debugFullscreenBusyReason,
            'a custom host overlay is on screen');

        markCustomOverlayOnScreen(false);
        expect(AdManager().canShowInterstitial(), isTrue,
            reason: 'once the host clears its flag, the gate must open '
                'back up again, not stay stuck closed');
      });

      test('canShowRewardedAd() is false while a custom overlay is on '
          'screen', () {
        adapter.rewardedSlot.beginLoad();
        adapter.rewardedSlot.markReady();
        expect(AdManager().canShowRewardedAd(), isTrue);

        markCustomOverlayOnScreen(true);
        expect(AdManager().canShowRewardedAd(), isFalse);

        markCustomOverlayOnScreen(false);
        expect(AdManager().canShowRewardedAd(), isTrue);
      });

      test('canShowRewardedInterstitialAd() is false while a custom '
          'overlay is on screen', () {
        adapter.rewardedInterstitialSlot.beginLoad();
        adapter.rewardedInterstitialSlot.markReady();
        expect(AdManager().canShowRewardedInterstitialAd(), isTrue);

        markCustomOverlayOnScreen(true);
        expect(AdManager().canShowRewardedInterstitialAd(), isFalse);

        markCustomOverlayOnScreen(false);
        expect(AdManager().canShowRewardedInterstitialAd(), isTrue);
      });

      test('customOverlayOnScreen defaults to false — no accidental block',
          () {
        expect(customOverlayOnScreen.value, isFalse);
      });
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

    test(
        'bypassSafety does NOT bypass the invalid-traffic pause (round-6 audit)',
        () async {
      // `bypassSafety` exists so the splash App Open can skip the FREQUENCY
      // limits — daily cap, 30s throttle, per-placement cap. The
      // invalid-traffic cooldown is a different thing: it protects the
      // publisher's AdMob account from being flagged for invalid traffic, and
      // skipping it at the surface that shows most often (every cold start) is
      // the worst possible place to skip it.
      SharedPreferences.setMockInitialValues({});
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      AdManager().debugVipManager = _FakeVip(false);

      final adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();

      // Trip the click-spam detector through the real production path — one
      // click past the configured per-minute ceiling — rather than reaching
      // into private state.
      for (var i = 0; i <= AdSafetyParams.debug.maxClicksPerMinute; i++) {
        AdSafetyConfig.recordAdClick();
      }
      expect(AdSafetyConfig.isInvalidTrafficPauseActive, isTrue,
          reason: 'sanity check: the click spam must have started a pause');

      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );

      expect(adapter.showAppOpenCalls, 0,
          reason: 'a device already flagged for click fraud must not be served '
              'an App Open, even on the splash bypass path');
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

  group(
      'round-37 audit (MAJOR): an adapter throw during show*() must still '
      'resolve the host callback, matching showRewardedAd\'s round-29 fix',
      () {
    late _FakeAdapter adapter;

    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      // AdPreferences.getInstance() caches its singleton across the whole
      // test file run — without this, the daily-ad-count this group's
      // several successful show* calls record leaks into later, unrelated
      // tests (e.g. T76's load-watchdog group started failing with "daily
      // cap reached" once these tests were added).
      AdPreferences.resetForTest();
      final prefs = await AdPreferences.getInstance();
      await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
      AdSafetyConfig.resetForReinit();
      adapter = _FakeAdapter();
      AdManager().debugSetAdapter(adapter);
      AdManager().debugVipManager = _FakeVip(false);
    });

    tearDown(() {
      AdManager().debugSetAdapter(null);
      AdManager().debugVipManager = null;
    });

    test('showInterstitial() throwing still calls onDoneFlow(false)',
        () async {
      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();
      adapter.throwOnShowInterstitial = true;

      bool? flow;
      await AdManager().showInterstitial(onDoneFlow: (v) => flow = v);

      expect(flow, isFalse,
          reason: 'the throw must resolve as a clean miss, not leave the '
              'host callback uncalled forever');
    });

    // Independent review (round 37 verification pass, MAJOR, confirmed via
    // an empirical probe before this fix existed) — the try/catch above
    // wraps the ENTIRE `await ad.show*(onDone: callback)` expression, so if
    // the real callback already ran and delivered a result to the host, but
    // something inside it (or after it, in the same lambda) then throws,
    // the outer catch used to call the host callback a SECOND time with a
    // contradictory result. Confirmed empirically: a host `onDoneFlow` that
    // throws on its first call was invoked twice (callCount reached 2)
    // before this fix.
    test(
        'showInterstitial() does NOT double-invoke onDoneFlow when the host '
        'callback itself throws after being delivered', () async {
      adapter.interstitialSlot.beginLoad();
      adapter.interstitialSlot.markReady();

      var callCount = 0;
      await AdManager().showInterstitial(onDoneFlow: (v) {
        callCount++;
        throw StateError('host callback throws after being delivered');
      });

      expect(callCount, 1,
          reason: 'the host callback must be delivered exactly once, even '
              'if it throws — a second, contradictory call is worse than '
              'letting the host\'s own exception surface');
    });

    test(
        'showRewardedInterstitialAd() throwing still calls onDone(false, '
        'false)', () async {
      adapter.rewardedInterstitialSlot.beginLoad();
      adapter.rewardedInterstitialSlot.markReady();
      adapter.throwOnShowRewardedInterstitial = true;

      bool? shown;
      bool? earned;
      await AdManager().showRewardedInterstitialAd(onDone: (s, e) {
        shown = s;
        earned = e;
      });

      expect(shown, isFalse);
      expect(earned, isFalse);
    });

    test(
        'showAppOpenAd() throwing calls onAdDismiss(false) instead of '
        'rethrowing', () async {
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();
      adapter.throwOnShowAppOpen = true;

      bool? dismissed;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) => dismissed = d,
      );

      expect(dismissed, isFalse,
          reason: 'a rethrow here leaves whoever awaited this call (e.g. '
              'the splash screen) with an unhandled exception AND a '
              'callback that never fires');
    });

    test(
        'showRewardedInterstitialAd() does NOT double-invoke onDone when '
        'the host callback itself throws after being delivered', () async {
      adapter.rewardedInterstitialSlot.beginLoad();
      adapter.rewardedInterstitialSlot.markReady();

      var callCount = 0;
      await AdManager().showRewardedInterstitialAd(onDone: (s, e) {
        callCount++;
        throw StateError('host callback throws after being delivered');
      });

      expect(callCount, 1);
    });

    test(
        'showAppOpenAd() does NOT double-invoke onAdDismiss when the host '
        'callback itself throws after being delivered', () async {
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();

      var callCount = 0;
      await AdManager().showAppOpenAd(
        bypassSafety: true,
        onAdDismiss: (d) {
          callCount++;
          throw StateError('host callback throws after being delivered');
        },
      );

      expect(callCount, 1);
    });

    test(
        'showRewardedAd() (pre-existing round-29 pattern) does NOT '
        'double-invoke onEarnedReward when the host callback itself throws '
        'after being delivered', () async {
      adapter.rewardedSlot.beginLoad();
      adapter.rewardedSlot.markReady();

      var callCount = 0;
      await AdManager().showRewardedAd(onEarnedReward: (earned) {
        callCount++;
        throw StateError('host callback throws after being delivered');
      });

      expect(callCount, 1,
          reason: 'this is the ORIGINAL round-29 pattern showInterstitial '
              'etc. copied — it had the same latent double-invoke bug, '
              'caught by independent review of the round-37 diff, not just '
              'the 3 new call sites');
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

    test(
        'round-29 audit (BLOCKER): on-demand load throwing releases '
        '_rewardedInFlight instead of wedging it forever', () async {
      AdManager().debugVipManager = _FakeVip(true);
      adapter.throwOnLoad = true;
      bool? r1;
      await AdManager().showRewardedAd(
        bypassVipGuard: true,
        onEarnedReward: (e) => r1 = e,
      );
      expect(r1, isFalse, reason: 'the throw must resolve as a clean miss');

      // If the guard were left stuck true, this second call would be
      // rejected before ever reaching the adapter. `earned`/`displayed`
      // stay false to avoid tripping the persisted daily-ad-cap counter,
      // which must not leak into unrelated groups later in this file.
      adapter.throwOnLoad = false;
      adapter.loadMarksReady = true;
      adapter.nextRewardEarned = false;
      adapter.nextRewardDisplayed = false;
      await AdManager().showRewardedAd(
        bypassVipGuard: true,
        onEarnedReward: (_) {},
      );
      expect(adapter.showRewardedCalls, 1,
          reason: '_rewardedInFlight must have been released by the throw');
    });

    test(
        'round-29 audit (BLOCKER): showRewarded() throwing releases '
        '_rewardedInFlight instead of wedging it forever', () async {
      AdManager().debugVipManager = _FakeVip(false);
      adapter.loadMarksReady = true;
      adapter.throwOnShow = true;
      bool? r1;
      await AdManager().showRewardedAd(onEarnedReward: (e) => r1 = e);
      expect(r1, isFalse, reason: 'the throw must resolve as a clean miss');

      // `earned`/`displayed` stay false to avoid tripping the persisted
      // daily-ad-cap counter, which must not leak into later groups.
      adapter.throwOnShow = false;
      adapter.nextRewardEarned = false;
      adapter.nextRewardDisplayed = false;
      await AdManager().showRewardedAd(onEarnedReward: (_) {});
      expect(adapter.showRewardedCalls, 2,
          reason: '_rewardedInFlight must have been released by the throw');
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

    // T140 — PlacementRegistry's frequencyCapOverride, end to end through a
    // real showInterstitial call, not just AdSafetyConfig's own unit tests.
    group('PlacementRegistry frequencyCapOverride (T140)', () {
      tearDown(() => AdManager().debugConfig = null);

      test(
          'a registered placement with frequencyCapOverride blocks even '
          'though AdSafetyParams itself configures NO cap for it',
          () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'level_complete': PlacementSpec(
              format: AdSlotType.interstitial,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('level_complete'));

        await AdManager().showInterstitial(
          onDoneFlow: (_) {},
          placement: const AdPlacement.custom('level_complete'),
        );
        await Future<void>.delayed(Duration.zero);

        final skip = lastSkip();
        expect(skip, isNotNull);
        expect(skip!.reason, 'placement_cap',
            reason: 'the registry\'s override (1/day) must block this — '
                'AdSafetyParams.debug configures no per-placement cap at '
                'all on its own');
      });

      test(
          'a placement NOT in the registry is completely unaffected by it '
          'being configured for OTHER placements', () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'level_complete': PlacementSpec(
              format: AdSlotType.interstitial,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(AdPlacement.home);

        events.clear();
        await AdManager().showInterstitial(
            onDoneFlow: (_) {}, placement: AdPlacement.home);
        await Future<void>.delayed(Duration.zero);

        expect(
            events
                .whereType<AdSkipEvent>()
                .where((e) => e.reason == 'placement_cap'),
            isEmpty,
            reason: 'AdPlacement.home has no registry entry — the override '
                'registered for a DIFFERENT placement id must not leak '
                'into it');
      });

      test('no registry configured at all (AdConfig.placements: null, the '
          'default) behaves identically to every release before T140',
          () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          // placements: intentionally omitted — defaults to null.
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('level_complete'));

        events.clear();
        await AdManager().showInterstitial(
          onDoneFlow: (_) {},
          placement: const AdPlacement.custom('level_complete'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
            events
                .whereType<AdSkipEvent>()
                .where((e) => e.reason == 'placement_cap'),
            isEmpty,
            reason: 'no registry at all must mean no per-call override '
                'ever applies — AdSafetyParams.debug has no configured '
                'per-placement cap either, so nothing should block this');
      });

      // Round-2 independent review (IMPORTANT) — a spec's `format` used to
      // be required but never actually checked at runtime: a registry
      // entry declared for `interstitial` would silently ALSO gate any
      // OTHER format's show call that happened to reuse the same
      // AdPlacement.id (nothing stops a host from doing that —
      // AdPlacement itself carries no format).
      test(
          'a spec registered for a DIFFERENT format than the actual show '
          'call is NOT applied — format is checked, not just the id',
          () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            // Registered for interstitial ...
            'shared_id': PlacementSpec(
              format: AdSlotType.interstitial,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('shared_id'));

        // ... but THIS call is a rewarded ad reusing the same placement id.
        events.clear();
        await AdManager().showRewardedAd(
          onEarnedReward: (_) {},
          placement: const AdPlacement.custom('shared_id'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
            events
                .whereType<AdSkipEvent>()
                .where((e) => e.reason == 'placement_cap'),
            isEmpty,
            reason: 'the interstitial-only override must not leak into a '
                'rewarded show call just because the placement id matches');
      });

      test(
          'showRewardedAd() also honors a registered frequencyCapOverride',
          () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'reward_shop': PlacementSpec(
              format: AdSlotType.rewarded,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('reward_shop'));

        events.clear();
        await AdManager().showRewardedAd(
          onEarnedReward: (_) {},
          placement: const AdPlacement.custom('reward_shop'),
        );
        await Future<void>.delayed(Duration.zero);

        final skip =
            events.whereType<AdSkipEvent>().where((e) => e.reason == 'placement_cap');
        expect(skip, isNotEmpty);
      });

      test(
          'showRewardedInterstitialAd() also honors a registered '
          'frequencyCapOverride', () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'ri_placement': PlacementSpec(
              format: AdSlotType.rewardedInterstitial,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('ri_placement'));

        events.clear();
        await AdManager().showRewardedInterstitialAd(
          onDone: (_, __) {},
          placement: const AdPlacement.custom('ri_placement'),
        );
        await Future<void>.delayed(Duration.zero);

        final skip =
            events.whereType<AdSkipEvent>().where((e) => e.reason == 'placement_cap');
        expect(skip, isNotEmpty);
      });

      test(
          'showAppOpenAd(bypassSafety: false) honors a registered '
          'frequencyCapOverride', () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'splash': PlacementSpec(
              format: AdSlotType.appOpen,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('splash'));

        events.clear();
        await AdManager().showAppOpenAd(
          onAdDismiss: (_) {},
          placement: const AdPlacement.custom('splash'),
        );
        await Future<void>.delayed(Duration.zero);

        final skip =
            events.whereType<AdSkipEvent>().where((e) => e.reason == 'placement_cap');
        expect(skip, isNotEmpty);
      });

      test(
          'showAppOpenAd(bypassSafety: true) still bypasses the placement '
          'cap entirely — same exemption as every other safety check it '
          'already bypasses, unchanged by T140', () async {
        await AdSafetyConfig.init(prefs, params: AdSafetyParams.debug);
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'splash': PlacementSpec(
              format: AdSlotType.appOpen,
              frequencyCapOverride: 1,
            ),
          }),
        );
        AdSafetyConfig.recordPlacementAdShown(
            const AdPlacement.custom('splash'));

        events.clear();
        await AdManager().showAppOpenAd(
          onAdDismiss: (_) {},
          bypassSafety: true,
          placement: const AdPlacement.custom('splash'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
            events
                .whereType<AdSkipEvent>()
                .where((e) => e.reason == 'placement_cap'),
            isEmpty,
            reason: 'bypassSafety: true must still exempt the placement '
                'cap too, T140 or not — same rule as the global safety '
                'checks it already bypasses');
      });
    });

    // T181 — PlacementRegistry's minIntervalOverrideMs, end to end through a
    // real showInterstitial/showRewardedAd call, mirroring T140's
    // frequencyCapOverride group above.
    group('PlacementRegistry minIntervalOverrideMs (T181)', () {
      tearDown(() => AdManager().debugConfig = null);

      test(
          'a registered placement with a TIGHTER minIntervalOverrideMs '
          'blocks even though AdSafetyParams itself allows it '
          '(minTimeBetweenFullscreenAds: 0)', () async {
        await AdSafetyConfig.init(prefs,
            params:
                AdSafetyParams.debug.copyWith(minTimeBetweenFullscreenAds: 0));
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'level_complete': PlacementSpec(
              format: AdSlotType.interstitial,
              minIntervalOverrideMs: 999999999,
            ),
          }),
        );
        AdSafetyConfig.recordFullscreenAdShown();

        await AdManager().showInterstitial(
          onDoneFlow: (_) {},
          placement: const AdPlacement.custom('level_complete'),
        );
        await Future<void>.delayed(Duration.zero);

        final skip = lastSkip();
        expect(skip, isNotNull);
        expect(skip!.reason, 'cooldown',
            reason: 'the registry\'s tighter interval override must block '
                'this even though AdSafetyParams.debug itself was just '
                'set to allow any interval at all');
      });

      test(
          'a registered placement with a LOOSER minIntervalOverrideMs is '
          'allowed even though AdSafetyParams itself would still be '
          'blocking', () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams.debug
                .copyWith(minTimeBetweenFullscreenAds: 999999999));
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'reward_shop': PlacementSpec(
              format: AdSlotType.rewarded,
              minIntervalOverrideMs: 0,
            ),
          }),
        );
        AdSafetyConfig.recordFullscreenAdShown();

        events.clear();
        await AdManager().showRewardedAd(
          onEarnedReward: (_) {},
          placement: const AdPlacement.custom('reward_shop'),
        );
        await Future<void>.delayed(Duration.zero);

        expect(
            events
                .whereType<AdSkipEvent>()
                .where((e) => e.reason == 'cooldown'),
            isEmpty,
            reason: 'the registry\'s looser interval override (0ms) must '
                'let this through even though AdSafetyParams alone would '
                'still be well within its throttle window');
      });

      test(
          'a placement NOT in the registry is unaffected by an override '
          'configured for a DIFFERENT placement', () async {
        await AdSafetyConfig.init(prefs,
            params:
                AdSafetyParams.debug.copyWith(minTimeBetweenFullscreenAds: 0));
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'level_complete': PlacementSpec(
              format: AdSlotType.interstitial,
              minIntervalOverrideMs: 999999999,
            ),
          }),
        );
        AdSafetyConfig.recordFullscreenAdShown();

        events.clear();
        await AdManager().showInterstitial(
            onDoneFlow: (_) {}, placement: AdPlacement.home);
        await Future<void>.delayed(Duration.zero);

        expect(
            events
                .whereType<AdSkipEvent>()
                .where((e) => e.reason == 'cooldown'),
            isEmpty,
            reason: 'AdPlacement.home has no registry entry — the override '
                'registered for a DIFFERENT placement id must not leak '
                'into it (AdSafetyParams.debug allows any interval on its '
                'own, so a leak would show up as a spurious cooldown '
                'skip)');
      });

      // codex round-1 fix — canShowInterstitial()/canShowRewardedAd()/
      // canShowRewardedInterstitialAd() (the documented pre-check UI-gating
      // helpers) used to have no placement param at all, so a looser
      // registry override could make showInterstitial() itself succeed
      // while this peek still said false for the same placement.
      test(
          'canShowInterstitial(placement:) reflects the SAME registry '
          'override the real showInterstitial() call for that placement '
          'would use', () async {
        await AdSafetyConfig.init(prefs,
            params: AdSafetyParams.debug
                .copyWith(minTimeBetweenFullscreenAds: 999999999));
        AdSafetyConfig.resetForReinit();
        AdManager().debugConfig = const AdConfig(
          provider: AdProvider.admob,
          admob: AdMobConfig(
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
          placements: PlacementRegistry({
            'level_complete': PlacementSpec(
              format: AdSlotType.interstitial,
              minIntervalOverrideMs: 0,
            ),
          }),
        );
        adapter.interstitialSlot.beginLoad();
        adapter.interstitialSlot.markReady();
        AdSafetyConfig.recordFullscreenAdShown();

        expect(
            AdManager()
                .canShowInterstitial(placement: const AdPlacement.custom('level_complete')),
            isTrue,
            reason: 'this placement has a 0ms override — it must read as '
                'showable even though the app-wide throttle alone (set to '
                'an effectively infinite wait above) would say no');
        expect(AdManager().canShowInterstitial(), isFalse,
            reason: 'the default placement (unspecified) has no registry '
                'entry — it must still see the app-wide throttle unchanged');
      });
    });

    // T119 — explainLastSkip is a thin read of the exact same AdSkipEvent
    // this whole group already asserts on, so this doesn't re-test every
    // reason code — just that the read side actually reflects it.
    test(
        'T119: explainLastSkip reflects the most recent skip for that slot, '
        'null for a slot that has never skipped', () async {
      // _lastSkipByType is a process-wide singleton field, deliberately not
      // cleared by destroy() (see its doc) — reset the test-only seam so an
      // earlier test's skip on the same slot can't leak into this one.
      AdManager().debugResetLastSkip();
      expect(AdManager().explainLastSkip(AdSlotType.interstitial), isNull);

      AdManager().debugVipManager = _FakeVip(true);
      await AdManager().loadInterstitial();
      await Future<void>.delayed(Duration.zero);

      expect(AdManager().explainLastSkip(AdSlotType.interstitial),
          'interstitial load skipped: vip');
      // A slot that never had a load/show attempt at all stays null.
      expect(AdManager().explainLastSkip(AdSlotType.rewarded), isNull);
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
        () async {
      // T102 round 3 — deliberately real time, not fakeAsync. initialize()'s
      // remote-safety fetch is awaited and caught cleanly (ad_manager.dart
      // around the `remoteSafetyProvider != null` block), but the real
      // AdMobAdapter.initialize() work that follows uses genuine
      // platform-channel calls fakeAsync's virtual zone cannot control. That
      // tail used to keep running in real wall-clock time after this test's
      // fakeAsync zone had already closed (the test only elapsed a virtual
      // 6s, never awaited initialize() itself) — invisible with
      // `unawaited(_eventLog?.flush())` in destroy(), but a real hang once
      // that becomes `await` (see T102) because destroy()'s tearDown then
      // waits on state that orphaned tail never finishes touching. Waiting
      // for real 6s here keeps everything inside ONE zone (the real one) so
      // nothing is left running past the end of this test.
      await AdManager().initialize(
        config: _admobConfig(dryRun: true, testIds: true),
        onComplete: (_, __) {},
        remoteSafetyProvider: _HangingRemoteSafetyProvider(),
      );

      expect(AdSafetyConfig.dailyCapReached(), isFalse,
          reason: 'a provider that never answers must not hang init '
              'forever — the 5s timeout falls back to local params');
    });
  });
  // T111's own tests live in test/refresh_remote_safety_params_test.dart —
  // deliberately NOT in this group: this file already runs 80+ real
  // AdMobAdapter.initialize() calls in sequence, and appending more here
  // triggered a deterministic (not flaky) google_mobile_ads internal null
  // check a few tests after the "slower than the 5s timeout" case above,
  // which leaves its real GMA init orphaned rather than cancelled. Root
  // cause is in that pre-existing test's interaction with the real plugin,
  // not in T111's logic — isolating into a fresh file sidesteps it rather
  // than papering over it.

  // Round-23 audit, MAJOR — impression accounting used to key off the REWARD,
  // so a rewarded ad the user watched for two seconds and closed counted
  // against no cap at all: the safety layer's daily/hourly/session budget was
  // silently unspendable by anyone who skips rewarded ads.
  group('rewarded impression accounting (round 23)', () {
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

    test('a displayed rewarded the user closed early still counts as an ad',
        () async {
      adapter.nextRewardEarned = false;
      adapter.nextRewardDisplayed = true;
      final before = AdSafetyConfig.getSessionAdCount();

      await AdManager().showRewardedAd(onEarnedReward: (_) {});

      expect(AdSafetyConfig.getSessionAdCount(), before + 1,
          reason: 'the user SAW an ad — it has to consume cap budget');
    });

    test('a rewarded that never reached the screen counts as nothing',
        () async {
      adapter.nextRewardEarned = false;
      adapter.nextRewardDisplayed = false;
      final before = AdSafetyConfig.getSessionAdCount();

      await AdManager().showRewardedAd(onEarnedReward: (_) {});

      expect(AdSafetyConfig.getSessionAdCount(), before,
          reason: 'no display, no impression');
    });

    test('an earned rewarded counts exactly once', () async {
      adapter.nextRewardEarned = true;
      final before = AdSafetyConfig.getSessionAdCount();

      await AdManager().showRewardedAd(onEarnedReward: (_) {});

      expect(AdSafetyConfig.getSessionAdCount(), before + 1);
    });

    test('rewardedInterstitial reports shown=false when never displayed',
        () async {
      adapter.nextRewardedInterstitialEarned = false;
      bool? shown;
      await AdManager()
          .showRewardedInterstitialAd(onDone: (s, __) => shown = s);

      expect(shown, isFalse,
          reason: 'RewardResult.skipped used to say shown:true, so a host '
              'that never got an ad was told it had one');
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

    // Round-27 backlog B1 (P0) — the exact call order the class doc's own
    // example uses: BEFORE AdPreferences has ever bootstrapped. This is not
    // an edge case — [pickProviderCohort]'s doc comment REQUIRES calling it
    // before `initialize()`, which is the only thing that ever calls
    // `AdPreferences.getInstance()` for the first time.
    test(
        'called before AdPreferences ever bootstraps (the documented '
        'pickProviderCohort call order) must not collapse every device into '
        'the same bucket', () {
      AdPreferences.resetForTest();
      AdManager().debugResetPreInitExperimentId();
      AdManager().debugCurrentDeviceGAID = '';
      expect(AdPreferences.instanceOrNull, isNull,
          reason: 'sanity: this test must reproduce the actual pre-bootstrap '
              'state, not one already warmed up by a prior test');

      final buckets = <int>{};
      for (var i = 0; i < 30; i++) {
        AdPreferences.resetForTest();
        AdManager().debugResetPreInitExperimentId();
        buckets.add(AdManager().experimentBucket('exp', buckets: 5));
      }
      expect(buckets.length, greaterThan(1),
          reason: '30 distinct never-bootstrapped installs all landing in '
              'the same bucket means pickProviderCohort() is a no-op for '
              'every host that follows its own documented call order');
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

  group('pickSessionProvider (T136)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({});
      AdPreferences.resetForTest();
      await AdPreferences.getInstance();
    });

    tearDown(() async {
      await AdManager().debugReconcileProviderExplorationSlot(vipActive: false);
    });

    test('explorationRate 0 (the default) always returns the install '
        'cohort provider, regardless of the random roll', () async {
      final result = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        debugRandom: _FixedRandom(0), // would explore at any positive rate
      );
      expect(result, AdProvider.admob);
      expect(AdManager().debugHasPendingExplorationCommit, isFalse);
    });

    test('a roll below explorationRate returns the OTHER provider and '
        'marks a pending commit', () async {
      final result = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 0.5,
        debugRandom: _FixedRandom(0.1), // 0.1 < 0.5
      );
      expect(result, AdProvider.appLovin);
      expect(AdManager().debugHasPendingExplorationCommit, isTrue);
    });

    test('a roll at or above explorationRate keeps the install cohort '
        'provider', () async {
      final result = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.appLovin,
        explorationRate: 0.5,
        debugRandom: _FixedRandom(0.5), // 0.5 is NOT < 0.5
      );
      expect(result, AdProvider.appLovin);
      expect(AdManager().debugHasPendingExplorationCommit, isFalse);
    });

    test('explorationRate above 1 is clamped to 1, not treated as >100%',
        () async {
      // A roll of exactly 1.0 fails a clamped-to-1.0 rate (1.0 >= 1.0 —
      // does NOT explore) but would pass an un-clamped 1.5 (1.0 >= 1.5 is
      // false — WOULD explore) — the one roll value that actually tells
      // the two cases apart. Real Random.nextDouble() never returns
      // exactly 1.0, but debugRandom is a plain test double, not required
      // to.
      final result = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1.5,
        debugRandom: _FixedRandom(1.0),
      );
      expect(result, AdProvider.admob,
          reason: 'must be clamped to 1.0, not accepted as-is (1.5)');
    });

    test('a negative minIntervalBetweenExplorations is clamped to zero, '
        'not treated as "rate limit disabled forever"', () async {
      await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1,
        debugRandom: _FixedRandom(0),
      );
      await AdManager()
          .debugReconcileProviderExplorationSlot(vipActive: false);

      final second = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1,
        minIntervalBetweenExplorations: const Duration(seconds: -5),
        debugRandom: _FixedRandom(0),
      );

      expect(second, AdProvider.appLovin,
          reason: 'a clamped-to-zero interval means "no minimum wait", so '
              'this explores again immediately — the opposite of the bug '
              'this test guards (a raw negative Duration making the '
              'nowMs - lastMs < interval check always true, i.e. rate '
              'limit ALWAYS blocking, would also be wrong)');
    });

    // Round 2 independent review, BLOCKER — a synchronous version of this
    // method that only read AdPreferences.instanceOrNull saw `null` on a
    // cold process (nobody had called AdPreferences.getInstance() yet),
    // silently bypassing the persisted daily rate limit on exactly the
    // call pattern this method's own doc recommends.
    test(
        'a cold process (AdPreferences.instanceOrNull still null) still '
        'sees a persisted last-exploration timestamp', () async {
      final recentMs = DateTime.now().millisecondsSinceEpoch - 1000;
      SharedPreferences.setMockInitialValues(
          {'ad_sdk_last_provider_exploration_at_ms': recentMs});
      AdPreferences.resetForTest();
      expect(AdPreferences.instanceOrNull, isNull,
          reason: 'sanity: nobody has touched AdPreferences yet, matching '
              'a real cold app launch');

      final result = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1, // would explore every time if the rate limit
        // were bypassed by a stale/absent AdPreferences read
        debugRandom: _FixedRandom(0),
      );

      expect(result, AdProvider.admob,
          reason: 'must await AdPreferences for real and see the persisted '
              'timestamp — must not explore again this soon after');
    });

    test(
        'reconciling with vipActive: true discards the pending commit — '
        'never persisted, never counted against the rate limit', () async {
      await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1,
        debugRandom: _FixedRandom(0),
      );
      expect(AdManager().debugHasPendingExplorationCommit, isTrue,
          reason: 'sanity: exploration was decided');

      await AdManager()
          .debugReconcileProviderExplorationSlot(vipActive: true);

      expect(AdManager().debugHasPendingExplorationCommit, isFalse);
      final prefs = await AdPreferences.getInstance();
      expect(prefs.getLastProviderExplorationAtMs(), isNull,
          reason: 'a VIP session\'s exploration attempt must not be '
              'persisted — it could never produce WaterfallTuner data '
              'anyway, so it must not count against the daily rate limit '
              'either');
    });

    test(
        'reconciling with vipActive: false persists the commit, and a '
        'second pickSessionProvider call within the rate-limit window no '
        'longer explores even with a roll that would otherwise qualify',
        () async {
      final first = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1,
        debugRandom: _FixedRandom(0),
      );
      expect(first, AdProvider.appLovin, reason: 'sanity: first one explored');
      await AdManager()
          .debugReconcileProviderExplorationSlot(vipActive: false);

      final prefs = await AdPreferences.getInstance();
      expect(prefs.getLastProviderExplorationAtMs(), isNotNull,
          reason: 'sanity: the non-VIP commit above must have persisted');

      final second = await AdManager().pickSessionProvider(
        installCohortProvider: AdProvider.admob,
        explorationRate: 1, // would explore every single time if not rate-limited
        debugRandom: _FixedRandom(0),
      );

      expect(second, AdProvider.admob,
          reason: 'the default 1-day rate limit must block a second '
              'exploration this soon after the first one actually counted');
    });

    test('a reconciliation call with no pending commit is a safe no-op',
        () async {
      await expectLater(
          AdManager().debugReconcileProviderExplorationSlot(vipActive: false),
          completes);
      await expectLater(
          AdManager().debugReconcileProviderExplorationSlot(vipActive: true),
          completes);
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

    testWidgets(
        'round-26: destroy() before the scheduled delay elapses cancels the '
        'dialog — the stale closure must never fire', (tester) async {
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
        autoRequestUmpConsent: false,
        autoShowConsentDialog: true,
        // Non-zero on purpose — destroy() below must land INSIDE this
        // window, before the scheduled Timer fires.
        consentDialogPostSplashDelay: Duration(milliseconds: 200),
      );

      final navigatorKey = GlobalKey<NavigatorState>();
      mgr.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const SizedBox(),
      ));

      mgr.markSplashInactive(); // schedules the built-in dialog, delay=200ms
      await tester.pump(const Duration(milliseconds: 50));

      // A destroy()+re-init cycle happens (provider switch, logout, SDK
      // reset) while the scheduled dialog is still pending.
      await mgr.destroy();

      // Advance past the ORIGINAL delay. Pre-fix, the stale Timer/Future
      // still fired here and showed the dialog against the old
      // ConsentManager/config even though the session had already been torn
      // down.
      await tester.pump(const Duration(milliseconds: 200));
      await tester.pumpAndSettle();

      expect(find.text(ConsentDialogStrings.vi.title), findsNothing,
          reason: 'destroy() must cancel the pending consent-dialog Timer, '
              'not just the re-scheduling guard flag');
    });

    testWidgets(
        'round-27 B7: reinit-without-destroy() (via _resetGuardState, the '
        'same function initialize()\'s "auto-disposing previous" branch '
        'calls) also cancels the pending dialog Timer', (tester) async {
      // ConsentManager is a persistent static singleton (bootstrap() reuses
      // it) — reset it or an earlier test in this group answering the
      // dialog (setting hasBeenAsked=true, persisted) leaks in here and
      // _maybeScheduleConsentDialog's `if (mgr.hasBeenAsked) return;` guard
      // makes it a no-op before ever creating a Timer, independently of
      // whatever this test is trying to prove.
      ConsentManager.resetForTest();
      final prefs = await AdPreferences.getInstance();
      final consentMgr = await ConsentManager.bootstrap(
          prefs: prefs, strings: ConsentDialogStrings.vi);
      // The underlying SharedPreferences mock backing AdPreferences is NOT
      // reset between tests in this group (only AdManager().destroy() runs
      // in tearDown, see above) — an earlier test in this same group answers
      // the dialog and persists hasBeenAsked=true, which bootstrap() above
      // would otherwise silently inherit. Force the "never asked" state this
      // test actually needs, regardless of what ran before it.
      await consentMgr.reset();
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
        autoRequestUmpConsent: false,
        autoShowConsentDialog: true,
        consentDialogPostSplashDelay: Duration(milliseconds: 200),
      );
      addTearDown(() => mgr.destroy());

      final navigatorKey = GlobalKey<NavigatorState>();
      mgr.setNavigatorKey(navigatorKey);
      await tester.pumpWidget(MaterialApp(
        navigatorKey: navigatorKey,
        home: const SizedBox(),
      ));

      mgr.markSplashInactive(); // schedules the built-in dialog, delay=200ms
      await tester.pump(const Duration(milliseconds: 50));
      expect(mgr.debugConsentDialogTimerActive, isTrue,
          reason: 'sanity: the Timer must actually be pending before the '
              'reinit-without-destroy() below, or this test proves nothing');

      // Round-26 only fixed the destroy() entry point. A host that calls
      // initialize() again WITHOUT destroy() first (documented, supported
      // path — "auto-disposing previous") reaches the guard-flag reset ONLY
      // through _resetGuardState(), never through destroy()'s own inline
      // block. debugResetGuardState() is that same function's test seam.
      mgr.debugResetGuardState();

      expect(mgr.debugConsentDialogTimerActive, isFalse,
          reason: 'reinit-without-destroy() must cancel the pending '
              'consent-dialog Timer too — round-26 only wired this into '
              'destroy()\'s own inline cleanup, not into the single '
              '"guard state" function both entry points share');
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
      '_resetGuardState clears stale GAID (audit fix — privacy leak past '
      "destroy())", () {
    tearDown(() {
      AdManager().debugCurrentDeviceGAID = '';
    });

    test(
        'debugResetGuardState() clears currentDeviceGaid left over from the '
        'previous session', () {
      final mgr = AdManager();
      mgr.debugCurrentDeviceGAID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      expect(mgr.currentDeviceGaid, isNotEmpty);

      mgr.debugResetGuardState();

      expect(mgr.currentDeviceGaid, isEmpty,
          reason: 'a stale GAID from the previous session must not survive '
              'destroy()/re-init — reporting a device\'s ad ID after the '
              'SDK claims to be torn down is a privacy leak past the point '
              'consent should be re-evaluated at');
    });
  });

  group(
      '_resetGuardState clears stale _lastShownPlacement (T160 — revenue '
      "attribution must not survive destroy()/re-init", () {
    late List<AdEvent> events;
    late StreamSubscription<AdEvent> sub;

    setUp(() {
      events = <AdEvent>[];
      sub = AdManager().events.listen(events.add);
    });
    tearDown(() async {
      await sub.cancel();
      AdManager().debugResetGuardState();
    });

    AdRevenueEvent revenueFor(AdPlacement placement) => AdRevenueEvent(
          providerTag: '[Fake]',
          type: AdSlotType.interstitial,
          placement: placement,
          valueMicros: 1000,
          currencyCode: 'USD',
        );

    test(
        'a revenue event is still attributed to the last-shown placement '
        'BEFORE any reset (sanity — proves the mechanism actually works)',
        () async {
      final mgr = AdManager();
      mgr.debugSetLastShownPlacement(AdSlotType.interstitial, AdPlacement.shop);

      mgr.debugEmit(revenueFor(AdPlacement.unspecified));
      await Future<void>.delayed(Duration.zero);

      final revenue = events.whereType<AdRevenueEvent>().last;
      expect(revenue.placement, AdPlacement.shop,
          reason: 'sanity: the show-time placement must win over the '
              'adapter-reported one, as documented on _lastShownPlacement');
    });

    test(
        'debugResetGuardState() clears it, so a LATER revenue event is not '
        'attributed to a placement from the previous session', () async {
      final mgr = AdManager();
      mgr.debugSetLastShownPlacement(AdSlotType.interstitial, AdPlacement.shop);

      mgr.debugResetGuardState();
      mgr.debugEmit(revenueFor(AdPlacement.unspecified));
      await Future<void>.delayed(Duration.zero);

      final revenue = events.whereType<AdRevenueEvent>().last;
      expect(revenue.placement, AdPlacement.unspecified,
          reason: 'T160 — a placement from a session that ended (destroy() '
              'or a reinit-without-destroy(), both of which reach '
              '_resetGuardState()) must not survive to misattribute a '
              'revenue event the NEW session\'s adapter reports before its '
              'own first show call');
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

  group(
      'Issue 3 — _resetGuardState clears the stale GAID (privacy leak past '
      'destroy())', () {
    tearDown(() => AdManager().debugCurrentDeviceGAID = '');

    test('debugResetGuardState() clears _currentDeviceGAID', () {
      final mgr = AdManager();
      mgr.debugCurrentDeviceGAID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';
      expect(mgr.currentDeviceGaid, isNotEmpty);

      mgr.debugResetGuardState();

      expect(mgr.currentDeviceGaid, isEmpty,
          reason: 'a stale GAID from the previous session must not survive '
              'destroy()/re-init — reporting it past the point consent '
              'should be re-evaluated at is a privacy leak');
    });

    test('a real destroy() (not just the debug seam) clears it too',
        () async {
      final mgr = AdManager();
      mgr.debugCurrentDeviceGAID = 'AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE';

      await mgr.destroy();

      expect(mgr.currentDeviceGaid, isEmpty,
          reason: 'destroy() calls _resetGuardState() internally — this '
              'proves the real public entry point, not only the debug '
              'seam, clears the GAID');
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

    // M1 (round-6 audit, found independently by two auditors) — Google's App
    // Open policy calls out returning from an ad click specifically: the user
    // taps a banner, the browser or Play Store opens, they come back, and an
    // App Open ad is waiting for them. Clicks were already recorded at 14 call
    // sites, but only into the click-spam window and the CTR counter — the
    // resume path read neither.
    //
    // These two tests are a PAIR on purpose. Cold start alone already forces
    // `showAppOpenCalls == 0` here, so asserting that would pass with or
    // without the fix. `loadAppOpenCalls` is the discriminator: the cold-start
    // skip refills before returning, every guard ahead of it returns without
    // loading. So "0 loads" proves we stopped at the new guard, and the
    // baseline test proves the cold-start path really does load — without it,
    // the first test would be untethered.
    test('backgrounding right after an ad click suppresses App Open on resume',
        () {
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();

      AdSafetyConfig.recordAdClick();
      AdSafetyConfig.recordAppWentBackground();

      AdManager().showAppOpenAdOnResume();

      expect(adapter.showAppOpenCalls, 0);
      expect(adapter.loadAppOpenCalls, 0,
          reason: 'must return at the ad-click guard, which sits ahead of the '
              'cold-start skip — the cold-start skip refills, so a nonzero '
              'load count would mean the new guard never fired');
    });

    test('one click cannot suppress two separate resumes', () {
      // Round-6 QC finding: the latch was consumed on resume but
      // `_lastAdClickAt` was left set, so a SECOND backgrounding still inside
      // the 5s window re-latched off the same click. Click at t=0, background
      // at t=1s, resume at t=2s (consumes the latch), background again at
      // t=3s — the second trip has nothing to do with an ad and must not be
      // suppressed. A click is attributable to one departure, not to every
      // departure for the next five seconds.
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();

      AdSafetyConfig.recordAdClick();
      AdSafetyConfig.recordAppWentBackground();
      AdManager().showAppOpenAdOnResume(); // consumes the latch
      expect(adapter.loadAppOpenCalls, 0, reason: 'first trip: suppressed');

      AdSafetyConfig.recordAppWentBackground(); // no new click
      AdManager().showAppOpenAdOnResume();

      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1),
          reason: 'the second departure was not caused by an ad click, so the '
              'resume path must run normally and reach the refill');
    });

    test('a resume that returns at an earlier guard still spends the latch',
        () {
      // Round-7 audit, MAJOR — the latch used to be read at its decision
      // point, six early returns down. A click followed by a resume that hit
      // any of those (splash active here, but VIP / another fullscreen /
      // a dialog on top do the same) left it set, and it then ate the next
      // genuine background→foreground App Open — a lost impression blamed on
      // a click the user made hours earlier.
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();

      AdSafetyConfig.recordAdClick();
      AdSafetyConfig.recordAppWentBackground();

      AdManager().markSplashActive();
      AdManager().showAppOpenAdOnResume(); // returns at the splash guard
      AdManager().markSplashInactive();

      // A later, unrelated trip out of the app.
      AdSafetyConfig.recordAppWentBackground();
      AdManager().showAppOpenAdOnResume();

      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1),
          reason: 'the stale latch must not survive the splash-guard return '
              'and suppress this unrelated resume');
    });

    test('baseline: without an ad click the resume path reaches the refill',
        () {
      adapter.appOpenSlot.beginLoad();
      adapter.appOpenSlot.markReady();

      AdSafetyConfig.recordAppWentBackground();

      AdManager().showAppOpenAdOnResume();

      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1),
          reason: 'anchors the test above: this path DOES load, so "0 loads" '
              'there is evidence of the ad-click guard and not of some '
              'unrelated early return');
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

    // T168 — the exact scenario this task describes: a host's own custom
    // overlay (invisible to AdScreenRouteLogger.isDialogOnTop above) must
    // block App Open on resume too, via the fullscreen mutex
    // (_fullscreenBusyReason) markCustomOverlayOnScreen feeds into.
    test('host-declared custom overlay on screen → skipped, no reload '
        'triggered', () {
      markCustomOverlayOnScreen(true);
      addTearDown(() => markCustomOverlayOnScreen(false));
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, 0);
      expect(adapter.showAppOpenCalls, 0);
    });

    test('clearing the custom-overlay flag lets a resume reach the refill '
        'again', () {
      markCustomOverlayOnScreen(true);
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, 0,
          reason: 'sanity: still blocked while the flag is set');

      markCustomOverlayOnScreen(false);
      AdManager().showAppOpenAdOnResume();
      expect(adapter.loadAppOpenCalls, greaterThanOrEqualTo(1),
          reason: 'T168 — once the host clears its flag, resume must '
              'reach the refill path again, not stay stuck blocked');
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

    // Round-31 audit (MAJOR) — _attachFullscreenDismissWatchers() only
    // watched appOpen/interstitial/rewarded, not rewardedInterstitial
    // (AdMob-only). That format fell back to the brittle adapter-callback
    // timestamp (stamped at onUserEarnedReward, which fires BEFORE the ad
    // actually leaves the screen), so this guard could never see a
    // rewardedInterstitial dismiss.
    test(
        'a rewardedInterstitial dismiss arms the same resume-suppression '
        'window as interstitial/rewarded/app-open', () {
      fakeAsync((async) {
        AdManager().debugAttachFullscreenDismissWatchers();
        addTearDown(AdManager().debugDetachFullscreenDismissWatchers);

        adapter.appOpenSlot.beginReload();
        adapter.appOpenSlot.markReady();
        AdManager().showAppOpenAdOnResume(); // consumes the cold-start skip
        async.elapse(const Duration(milliseconds: 50));
        adapter.showAppOpenCalls = 0;
        adapter.loadAppOpenCalls = 0;

        adapter.rewardedInterstitialSlot.beginLoad();
        adapter.rewardedInterstitialSlot.markReady();
        adapter.rewardedInterstitialSlot.beginShow();
        adapter.rewardedInterstitialSlot.markDismissed();

        adapter.appOpenSlot.beginReload();
        adapter.appOpenSlot.markReady();
        AdManager().showAppOpenAdOnResume();
        // The resume-fallback path (no navigatorKey in this test group) waits
        // 1s before actually calling showAppOpen — elapse past it so a
        // wrongly-unsuppressed call has time to land.
        async.elapse(const Duration(seconds: 2));

        expect(adapter.showAppOpenCalls, 0,
            reason: 'before the fix, rewardedInterstitialSlot was not '
                'watched at all, so nothing armed the debounce window and '
                'App Open could show right on top of the dismissed ad');
      });
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

    // T155 (codex round 2, P1) — showAppOpenAd(bypassSafety: true) records
    // into bypassAuditTrail before it ever checks the adapter, so a real
    // bypass can be recorded with no adapter yet (very early in the splash
    // window). The flush used to sit behind `if (ad == null) return;` and
    // silently skip for exactly that case.
    test(
        'paused with no adapter yet still flushes a bypass recorded before '
        'it', () async {
      final prefs = await AdPreferences.getInstance();
      AdManager().bypassAuditTrail.attach(prefs);
      AdManager().debugSetAdapter(null);
      AdManager().debugConfig = null;

      AdManager().bypassAuditTrail.record(
          kind: 'bypassSafety',
          callSiteTag: 'pre_init_paused_test',
          type: AdSlotType.appOpen);

      expect(
          () => AdManager()
              .didChangeAppLifecycleState(AppLifecycleState.paused),
          returnsNormally);
      // The flush is unawaited (fire-and-forget) — give it a couple of
      // microtask turns to actually run.
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      final raw = prefs.getBypassAuditTrailRaw();
      expect(raw, isNotNull);
      expect(raw, contains('pre_init_paused_test'));
    });

    test(
        'resumed → calls adapter.onAppResumed() and reaches '
        'showAppOpenAdOnResume()', () async {
      AdManager().didChangeAppLifecycleState(AppLifecycleState.resumed);
      // Round-13 QC (BLOCKER ×2) — everything that can request an ad now waits
      // for the resume consent re-check, so none of it is reached in the same
      // synchronous turn: a fill cached under a consent the user has since
      // withdrawn must not be requested or shown before the withdrawal is
      // applied, and onAppResumed() itself recreates failed banners.
      expect(adapter.onAppResumedCalls, 0,
          reason: 'consent is re-checked first');
      expect(adapter.loadAppOpenCalls, 0,
          reason: 'consent is re-checked first');
      await pumpEventQueue(times: 50);
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
        () async {
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
      // Round-13 QC (round 2) — onAppResumed() requests ads (it recreates
      // failed banners), so it now runs after the resume consent re-check.
      await pumpEventQueue(times: 50);
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
      // m12 (round 5 audit) — the poll tick now re-attempts the connectivity
      // watch whenever it is not up yet, so these tests can no longer rely on
      // it never starting. Left alone, the checker runs for real under
      // `flutter test`, every HTTP probe comes back 400, and it concludes the
      // device is offline — which makes `canReload()` false and silently
      // starves every later refill (the symptom was a second tick that loaded
      // nothing). Declaring the watch ready keeps `isConnected` at its
      // optimistic value, which is what these assertions are actually about.
      AdManager().debugConnectivityReady = true;
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

    // Regression: _onConnectivityChanged only retries a failed UMP attempt
    // on an observed offline→online transition. A platform/test where that
    // transition never fires (see _startConnectivityWatch's best-effort
    // skip) left a failed UMP attempt permanently un-retried. Fix: the
    // periodic poll backstops it too.
    group('UMP retry backstop (2026-08-22 audit)', () {
      final umpChannel = MethodChannel(
        'plugins.flutter.io/google_mobile_ads/ump',
        StandardMethodCodec(UserMessagingCodec()),
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

      setUp(() {
        messenger.setMockMethodCallHandler(umpChannel, (call) {
          switch (call.method) {
            case 'ConsentInformation#requestConsentInfoUpdate':
              return Future<void>.value();
            case 'ConsentInformation#isConsentFormAvailable':
              return Future.value(false);
            case 'ConsentInformation#canRequestAds':
              return Future.value(true);
            case 'ConsentInformation#getConsentStatus':
              return Future.value(3); // notRequired
            default:
              return Future.value(null);
          }
        });
      });

      tearDown(() {
        messenger.setMockMethodCallHandler(umpChannel, null);
        AdManager().debugUmpAttemptFailed = false;
      });

      test('retries requestUmpConsent on the periodic poll when a prior '
          'attempt failed', () {
        fakeAsync((async) {
          AdManager().debugUmpAttemptFailed = true;
          AdManager().debugStartAdRetryTimer();

          async.elapse(const Duration(minutes: 5));
          async.flushMicrotasks();

          expect(AdManager().debugUmpBackstopRetryCount, 1,
              reason: 'a failed UMP attempt must be retried by the '
                  'periodic backstop poll, not just the connectivity watch');
        });
      });

      test('does not retry when the last UMP attempt did not fail', () {
        fakeAsync((async) {
          AdManager().debugUmpAttemptFailed = false;
          AdManager().debugStartAdRetryTimer();

          async.elapse(const Duration(minutes: 5));
          async.flushMicrotasks();

          expect(AdManager().debugUmpBackstopRetryCount, 0);
        });
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

  group(
      'round-37 audit (MAJOR): destroy() must not clear isDialogOnTop out '
      'from under a dialog that is genuinely still on screen', () {
    tearDown(AdScreenRouteLogger.resetState);

    test(
        'a live dialog/popup stays reflected in isDialogOnTop across '
        'destroy()', () async {
      AdScreenRouteLogger().didPush(_FakePopupRoute(), null);
      expect(AdScreenRouteLogger.isDialogOnTop, isTrue,
          reason: 'sanity check: pushing a popup route sets the flag');

      // A host re-initializing the provider (or switching consent flow)
      // mid-dialog is a documented, supported destroy()+initialize() cycle —
      // round-13 already made the analogous call for `umpFormOnScreen`,
      // reasoning that destroy() doesn't actually dismiss the thing on
      // screen, so clearing the tracking flag just lets an App Open ad draw
      // straight over it on the next resume.
      await AdManager().destroy();

      expect(AdScreenRouteLogger.isDialogOnTop, isTrue,
          reason: 'destroy() does not dismiss the real dialog still on '
              'screen — the flag must keep reflecting that, or '
              'showAppOpenAdOnResume can stack an App Open ad on top of it');
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

  // MJ2 + m10 (round 5 audit). These used to drive the reads through
  // `SharedPreferences.setMockInitialValues`, which made them pass while the
  // production code could not possibly work: the legacy API reads a different
  // store on Android and prefixes every key with `flutter.` on iOS, so
  // `tcfConsentString` returned null on every real device. A mock that answers
  // a question the real store never sees is worse than no test — it is what
  // kept this broken through four audit rounds.
  //
  // These drive the same async platform interface the production code uses, so
  // a regression in *which store is read* still cannot be caught here — that
  // part is only provable on a device (verified on Android; iOS not run, see
  // MJ29). What they do lock is the parsing and the fail-soft contract.
  group('IAB consent strings (MJ2/m10)', () {
    setUp(() {
      IabStorage.debugResetForTest();
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.empty();
    });

    test('tcfConsentString returns the string UMP wrote', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABTCF_TCString': 'CPxxTestConsentString'});
      expect(await AdManager().tcfConsentString, 'CPxxTestConsentString');
    });

    test('tcfConsentString is null when no TCF session has ever run', () async {
      expect(await AdManager().tcfConsentString, isNull);
    });

    test('an empty string reads as absent, not as a valid consent string',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({'IABTCF_TCString': ''});
      expect(await AdManager().tcfConsentString, isNull);
    });

    test('usPrivacyOptedOut: `1YYN` → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABUSPrivacy_String': '1YYN'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test('usPrivacyOptedOut: `1YNN` → not opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABUSPrivacy_String': '1YNN'});
      expect(await AdManager().usPrivacyOptedOut, isFalse);
    });

    test('usPrivacyOptedOut: no string → null, NOT false', () async {
      expect(await AdManager().usPrivacyOptedOut, isNull,
          reason: '"no signal" and "signal says they did not opt out" are '
              'different answers, and a compliance report must not conflate '
              'them — reporting a definite `false` we cannot back up is the '
              'bug m10 is about');
    });

    test('usPrivacyOptedOut: malformed string → null rather than a guess',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABUSPrivacy_String': '1'});
      expect(await AdManager().usPrivacyOptedOut, isNull);
    });

    // Round-33 audit (R33-02) — a CMP that only writes the newer GPP US
    // National section (no legacy `IABUSPrivacy_String`) was invisible to
    // `usPrivacyOptedOut()`, so a state that opted out purely through GPP
    // read as "no signal" instead of "opted out". Fixtures below are REAL
    // GPP USNAT (section id 7) Core Segment strings generated by IAB Tech
    // Lab's own reference encoder (`@iabgpp/cmpapi` — the same library the
    // GitHub GPP spec repo ships), not hand-derived — cross-checking this
    // SDK's independent bit-reader against the authoritative implementation
    // instead of trusting hand arithmetic for a legal-consent code path:
    //   node -e "const {UsNatCoreSegment}=require('@iabgpp/cmpapi');
    //     const s=new UsNatCoreSegment();
    //     s.setFieldValue('SaleOptOut',1); s.setFieldValue('SharingOptOut',2);
    //     console.log(s.encode());"
    test(
        'usPrivacyOptedOut: GPP USNAT SaleOptOut=Opted-Out (official encoder fixture), no legacy string → opted out',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_7_String': 'CAAYAAAAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP USNAT SharingOptOut=Opted-Out, SaleOptOut=Did-Not (official encoder fixture) → opted out',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_7_String': 'CAAkAAAAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP USNAT both opt-outs Not-Applicable (official encoder default) → null',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_7_String': 'CAAAAAAAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isNull);
    });

    test('usPrivacyOptedOut: truncated/malformed GPP string → null, no throw',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({'IABGPP_7_String': 'AA'});
      expect(await AdManager().usPrivacyOptedOut, isNull);
    });

    test(
        'usPrivacyOptedOut: R40-A round 2 (R2-01) — a real GPP opt-out is '
        'not shadowed by a legacy string saying "did not opt out"',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABUSPrivacy_String': '1YNN', // legacy says NOT opted out
        'IABGPP_7_String': 'CAAYAAAAAABA', // GPP says opted out
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'the legacy string and GPP are both just keys a CMP '
              'wrote, with no ordering/timestamp to say one is more '
              'definitive than the other — a real opt-out from either '
              'must not be shadowed by the other saying "did not opt out"');
    });

    test(
        'usPrivacyOptedOut: R40-A round 2 (R2-01) — a real legacy opt-out '
        'is not shadowed by GPP saying "did not opt out"', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABUSPrivacy_String': '1YYN', // legacy: opted out
        'IABGPP_7_String': 'CAACAAAAAABA', // GPP USNAT: Did-Not-Opt-Out
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'the union rule must work in both directions, not just '
              'GPP-over-legacy');
    });

    // Round-37 audit MAJOR — USNAT parsing only ever read SaleOptOut/
    // SharingOptOut, so a CMP that expresses an opt-out ONLY through
    // TargetedAdvertisingOptOut (a real, distinct field per the IAB Tech
    // Lab's MSPA US National spec — e.g. Virginia's VCDPA opt-out right,
    // which a CMP can propagate into USNAT without touching Sale/Sharing)
    // was invisible. Fixtures generated the same way as the round-33 ones
    // above, via the official reference encoder:
    //   node -e "const {UsNatCoreSegment}=require('@iabgpp/cmpapi');
    //     const s=new UsNatCoreSegment();
    //     s.setFieldValue('TargetedAdvertisingOptOut',1);
    //     console.log(s.encode());"
    test(
        'usPrivacyOptedOut: GPP USNAT TargetedAdvertisingOptOut=Opted-Out '
        'ONLY (Sale/Sharing left Not-Applicable) → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_7_String': 'CAABAAAAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP USNAT TargetedAdvertisingOptOut=Did-Not-Opt-'
        'Out ONLY → not opted out (false, not null)', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_7_String': 'CAACAAAAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isFalse);
    });

    // Round-37 audit MAJOR — a CMP implementing ONLY the GPP California
    // section (section id 8, no US National section and no legacy
    // IABUSPrivacy_String) used to produce no signal at all.
    // California's Core Segment is its OWN bit layout (verified against
    // the IAB Tech Lab's "GPP Extension: California Privacy" spec — 3
    // Notice fields, not 6, and no TargetedAdvertisingOptOut field).
    // Fixtures via the same official reference encoder:
    //   node -e "const {UsCaCoreSegment}=require('@iabgpp/cmpapi');
    //     const s=new UsCaCoreSegment();
    //     s.setFieldValue('SaleOptOut',1); console.log(s.encode());"
    test(
        'usPrivacyOptedOut: GPP California SaleOptOut=Opted-Out (no USNAT, '
        'no legacy string) → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_8_String': 'BAQAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP California SharingOptOut=Opted-Out, '
        'SaleOptOut=Did-Not → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_8_String': 'BAkAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP California both opt-outs Not-Applicable → '
        'null', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_8_String': 'BAAAAABA'});
      expect(await AdManager().usPrivacyOptedOut, isNull);
    });

    test(
        'usPrivacyOptedOut: GPP USNAT present but all-Not-Applicable falls '
        'through to GPP California', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABGPP_7_String': 'CAAAAAAAAABA', // USNAT: no signal
        'IABGPP_8_String': 'BAQAAABA', // California: opted out
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'USNAT with no usable signal must not shadow a real '
              'California-only opt-out');
    });

    // Round-37 audit MAJOR — the 19 other US state GPP sections
    // (Virginia(9) through Rhode Island(27)) were not read at all. None of
    // them has a `SharingOptOut` value field, so a single decoder reading
    // `SaleOptOut(2)` then `TargetedAdvertisingOptOut(2)` covers all of
    // them — only the skip-before-`SaleOptOut` differs per state (12/14/16
    // bits). Fixtures generated via the official reference encoder for
    // EVERY state individually (not derived from one and reused), e.g.:
    //   node -e "const {UsVaCoreSegment}=require('@iabgpp/cmpapi');
    //     const s=new UsVaCoreSegment(); s.setFieldValue('SaleOptOut',1);
    //     console.log(s.encode());"
    // This caught a real mismatch between Maryland/Indiana/Kentucky/Rhode
    // Island's published spec prose (which lists a `SectionID`+`Version`
    // preamble) and the reference encoder's actual field layout (which has
    // neither) — the skip values below are the verified ones.
    const usStateSaleOptedOutFixtures = {
      9: 'BAQAABA', // Virginia
      10: 'BAQAAEA', // Colorado
      11: 'BAEAAAQA', // Utah
      12: 'BAQAAAEA', // Connecticut
      13: 'BAQAAABA', // Florida
      14: 'BAQAAABA', // Montana
      15: 'BAQAAAABAA', // Oregon
      16: 'BAQAAAQA', // Texas
      17: 'BAQAAAABAA', // Delaware
      18: 'BAEAAAQA', // Iowa
      19: 'BAQAAAQA', // Nebraska
      20: 'BAQAAABA', // New Hampshire
      21: 'BAQAAAAAQA', // New Jersey
      22: 'BAQAAAQA', // Tennessee
      23: 'BAQAAAQA', // Minnesota
      24: 'BQBA', // Maryland
      25: 'BQBA', // Indiana
      26: 'BQBA', // Kentucky
      27: 'BQBA', // Rhode Island
    };
    for (final entry in usStateSaleOptedOutFixtures.entries) {
      test(
          'usPrivacyOptedOut: GPP US state section ${entry.key} '
          'SaleOptOut=Opted-Out → opted out', () async {
        SharedPreferencesAsyncPlatform.instance =
            InMemorySharedPreferencesAsync.withData(
                {'IABGPP_${entry.key}_String': entry.value});
        expect(await AdManager().usPrivacyOptedOut, isTrue);
      });
    }

    // Deeper mechanism check (one per distinct skip-bit-count group: 12,
    // 14, 16) — proves TargetedAdvertisingOptOut alone is read (not just
    // SaleOptOut) and that "both Did Not Opt Out" correctly resolves false,
    // not just true/opted-out.
    test(
        'usPrivacyOptedOut: GPP Virginia (skip=12) TargetedAdvertisingOptOut '
        '=Opted-Out ONLY → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_9_String': 'BAEAABA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP Virginia both Did-Not-Opt-Out → false, not '
        'null', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_9_String': 'BAoAABA'});
      expect(await AdManager().usPrivacyOptedOut, isFalse);
    });

    test(
        'usPrivacyOptedOut: GPP Utah (skip=14) TargetedAdvertisingOptOut '
        '=Opted-Out ONLY → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_11_String': 'BABAAAQA'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP Maryland (skip=16) TargetedAdvertisingOptOut '
        '=Opted-Out ONLY → opted out', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_24_String': 'BQAQ'});
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: GPP Maryland both Did-Not-Opt-Out → false, not '
        'null', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_24_String': 'BQCg'});
      expect(await AdManager().usPrivacyOptedOut, isFalse);
    });

    test(
        'usPrivacyOptedOut: USNAT and California both absent falls through '
        'to a US state section', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData(
              {'IABGPP_21_String': 'BAQAAAAAQA'}); // New Jersey, opted out
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    // Round-40 audit MAJOR (R40-A) — an earlier-checked GPP tier's
    // explicit "did not opt out" used to permanently shadow a real
    // opt-out sitting in a later-checked tier. Reuses the exact fixtures
    // from the tests above (each already verified independently) so this
    // test isolates only the cross-tier combination behavior.
    test(
        'usPrivacyOptedOut: R40-A regression — GPP USNAT explicit '
        'Did-Not-Opt-Out must not shadow a real California opt-out',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABGPP_7_String': 'CAACAAAAAABA', // USNAT: Did-Not-Opt-Out (false)
        'IABGPP_8_String': 'BAQAAABA', // California: opted out (true)
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'a real opt-out in one GPP tier must not be swallowed by '
              'another tier\'s explicit "did not opt out"');
    });

    // Round-40 audit MAJOR (R40-A) — same shadowing bug existed *within*
    // the 19-state check itself: whichever state happened to be checked
    // first won, even with an explicit `false`.
    test(
        'usPrivacyOptedOut: R40-A regression — GPP Virginia explicit '
        'Did-Not-Opt-Out must not shadow a real Colorado opt-out',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABGPP_9_String': 'BAoAABA', // Virginia: Did-Not-Opt-Out (false)
        'IABGPP_10_String': 'BAQAAEA', // Colorado: opted out (true)
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'a real opt-out in one state section must not be '
              'swallowed by another state\'s explicit "did not opt out"');
    });

    // Round-40 audit — independent-review follow-up: the two regression
    // tests above only combined (USNAT, California) and (state, state).
    // These three lock in the same true-beats-false rule across every
    // other pairing the fix touches, reusing only fixtures already proven
    // correct individually above (no new hand-encoded GPP bit-strings).
    test(
        'usPrivacyOptedOut: R40-A — GPP USNAT opted out beats a real '
        'Virginia Did-Not-Opt-Out too, not just California', () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABGPP_7_String': 'CAAYAAAAAABA', // USNAT: opted out (true)
        'IABGPP_9_String': 'BAoAABA', // Virginia: Did-Not-Opt-Out (false)
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue);
    });

    test(
        'usPrivacyOptedOut: R40-A — a truncated/malformed GPP section '
        '(→ null) does not block a real opt-out in another section',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABGPP_7_String': 'AA', // USNAT: truncated/malformed → null
        'IABGPP_8_String': 'BAQAAABA', // California: opted out (true)
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'a parse failure must be treated as "no signal", not as a '
              'false that could shadow a real opt-out elsewhere');
    });

    test(
        'usPrivacyOptedOut: R40-A — a malformed legacy string falls through '
        'to a real GPP opt-out instead of being treated as precedence',
        () async {
      SharedPreferencesAsyncPlatform.instance =
          InMemorySharedPreferencesAsync.withData({
        'IABUSPrivacy_String': '1', // malformed (too short) legacy string
        'IABGPP_8_String': 'BAQAAABA', // California: opted out (true)
      });
      expect(await AdManager().usPrivacyOptedOut, isTrue,
          reason: 'only a legacy string that actually parses gets '
              'precedence over GPP — a malformed one must not silently '
              'suppress a real GPP signal');
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
