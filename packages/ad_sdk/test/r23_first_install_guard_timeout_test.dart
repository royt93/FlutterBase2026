// Round-23 QC (reviewer C, MINOR) — a Keychain read that times out must not
// cost a genuine new user their trial day.
//
// The first-install grace window is granted once per install, and an
// anti-uninstall-bypass guard (`FirstInstallGuard`, iOS Keychain) is asked
// first whether this device has had it already. That read is bounded at 5 s
// because a Keychain read can genuinely block — most typically before the
// first unlock after a reboot, which is exactly when a freshly installed app
// tends to be opened for the first time.
//
// On timeout the code answers `true` ("assume already granted"), which is the
// right conservative call for *this* launch. What was wrong was what came
// next: it then wrote the per-install "grace applied" flag, so the timeout
// became permanent. The user never got the trial, and with no backend there is
// nothing to hand it back with.
//
// A timeout means "could not read", not "already granted". Skip this launch,
// leave the flag alone, decide properly on the next one.

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/ad_provider_adapter.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_first_install_guard.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _OkAdapter implements AdProviderAdapter {
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
  String get tag => 'FakeAdapter';
  @override
  AdEventSink? eventSink;
  @override
  bool Function() canReload = () => true;

  @override
  Future<bool> initialize(
    AdConfig config, {
    String deviceGaid = '',
    bool isAgeRestrictedUser = false,
    AdConsent? consent,
  }) async =>
      true;

  @override
  Future<void> loadAppOpen({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> loadInterstitial({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> loadRewarded({void Function(bool)? onAdLoaded}) async {}
  @override
  Future<void> preloadBanner(Object key) async {}
  @override
  Future<void> preloadMrec(Object key) async {}
  @override
  Future<void> applyConsent(AdConsent consent) async {}
  @override
  Future<void> dispose() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Stands in for the real Keychain read. [answer] is what
/// `hasAlreadyGranted()` resolves to; a `null` answer never resolves at all,
/// which is the blocked-Keychain case the 5 s bound exists for.
class _ScriptedGuard extends FirstInstallGuard {
  _ScriptedGuard(this.answer);
  final bool? answer;
  int markGrantedCalls = 0;

  @override
  Future<bool> hasAlreadyGranted() {
    final a = answer;
    if (a == null) return Completer<bool>().future; // never completes
    return Future<bool>.value(a);
  }

  @override
  Future<void> markGranted() async => markGrantedCalls++;
}

/// Same shape as `_ScriptedGuard(null)` but the caller decides WHEN it
/// resolves, instead of it never resolving at all — needed to land
/// `destroy()` precisely inside the await and then let it answer afterward.
class _ControllableGuard extends FirstInstallGuard {
  _ControllableGuard(this._gate);
  final Completer<bool> _gate;
  final Completer<void> entered = Completer<void>();
  int markGrantedCalls = 0;

  @override
  Future<bool> hasAlreadyGranted() {
    if (!entered.isCompleted) entered.complete();
    return _gate.future;
  }

  @override
  Future<void> markGranted() async => markGrantedCalls++;
}

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
      bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
  safety: AdSafetyParams(dryRun: true),
  firstInstallVipGrace: FirstInstallVipGrace.day,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    // `AdPreferences` caches the SharedPreferences instance, so without this
    // every test after the first reads the previous test's grant.
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
    AdManager.debugAdapterFactory = (_) => _OkAdapter();
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
  });

  tearDown(() async {
    AdManager.debugAdapterFactory = null;
    AdManager.debugFirstInstallGuardFactory = null;
    await AdManager().destroy();
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  Future<void> initOnce() => AdManager().initialize(
        config: _config,
        onComplete: (_, __) {},
      );

  test(
      'CONTROL — a guard that answers "no" grants the trial and marks the '
      'install', () async {
    final guard = _ScriptedGuard(false);
    AdManager.debugFirstInstallGuardFactory = () => guard;

    await initOnce();

    expect(AdManager().vip?.isActive, isTrue,
        reason: 'sanity — this is the happy path the grace exists for');
    expect(prefs.isFirstInstallGraceApplied(), isTrue);
    expect(guard.markGrantedCalls, 1);
  });

  test(
      'CONTROL — a guard that answers "yes" still burns the flag (a real '
      'reinstall)', () async {
    AdManager.debugFirstInstallGuardFactory = () => _ScriptedGuard(true);

    await initOnce();

    expect(AdManager().vip?.isActive, isFalse);
    expect(prefs.isFirstInstallGraceApplied(), isTrue,
        reason: 'a definite "already granted" is a real answer — not asking '
            'again on every launch is the point of the flag');
  });

  test('a guard that never answers does not burn the trial', () async {
    AdManager.debugFirstInstallGuardFactory = () => _ScriptedGuard(null);

    await initOnce();

    expect(AdManager().vip?.isActive, isFalse,
        reason: 'skipping THIS launch is still the conservative call — the '
            'device might genuinely be a reinstall');
    expect(prefs.isFirstInstallGraceApplied(), isFalse,
        reason: 'THE finding: a timeout is "could not read", not "already '
            'granted". Burning the flag lost the trial day permanently, and '
            'there is no backend to hand it back.');
  }, timeout: const Timeout(Duration(seconds: 60)));

  // ── Round-37 QC (reviewer B, MAJOR) ─────────────────────────────────────
  //
  // The Keychain read is a real, multi-second production await with no
  // supersede guard around it. `destroy()` landing while it is still in
  // flight disposes the `VipManager` this same `initialize()` call had just
  // installed; `addVip`'s own `_save()` (round 18) then drops the grant — but
  // nothing stopped the two one-shot flags from being burned anyway,
  // permanently destroying the trial for a genuine first-time user.

  test(
      'destroy() landing mid-Keychain-read does not burn the flags over a '
      'dropped grant', () async {
    final gate = Completer<bool>();
    final guard = _ControllableGuard(gate);
    AdManager.debugFirstInstallGuardFactory = () => guard;

    final init = AdManager().initialize(config: _config, onComplete: (_, __) {});
    await guard.entered.future; // the Keychain read is genuinely in flight

    await AdManager().destroy();
    gate.complete(false); // the read finally answers: a genuine fresh install
    await init;

    expect(prefs.isFirstInstallGraceApplied(), isFalse,
        reason: 'THE finding — the grant this flag claims to record was '
            'dropped by the disposed manager; marking it anyway loses the '
            'trial with no way to hand it back');
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('and the NEXT launch, on the same install, still grants it', () async {
    final gate = Completer<bool>();
    final guard = _ControllableGuard(gate);
    AdManager.debugFirstInstallGuardFactory = () => guard;
    final init = AdManager().initialize(config: _config, onComplete: (_, __) {});
    await guard.entered.future;
    await AdManager().destroy();
    gate.complete(false);
    await init;

    AdManager.debugFirstInstallGuardFactory = () => _ScriptedGuard(false);
    await initOnce();

    expect(AdManager().vip?.isActive, isTrue,
        reason: 'not burning the flag on the dropped grant is only worth '
            'something if the very next launch can still succeed');
    expect(prefs.isFirstInstallGraceApplied(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  test('and the next launch, when the Keychain answers, grants it', () async {
    AdManager.debugFirstInstallGuardFactory = () => _ScriptedGuard(null);
    await initOnce();
    expect(AdManager().vip?.isActive, isFalse);
    await AdManager().destroy();

    // Same install, same prefs — only the Keychain has woken up.
    AdManager.debugFirstInstallGuardFactory = () => _ScriptedGuard(false);
    await initOnce();

    expect(AdManager().vip?.isActive, isTrue,
        reason: 'the whole reason for not burning the flag');
    expect(prefs.isFirstInstallGraceApplied(), isTrue);
  }, timeout: const Timeout(Duration(seconds: 60)));

  // Round-72 audit fix (MAJOR, gemini external) — `debugFirstInstallGuardFactory`
  // is a plain static field, so it cannot be gated at assignment the way a
  // setter can; the guard lives at the READ site instead (see the
  // `_testSeamsBlocked ? null : ...` in ad_manager.dart's grace-check block).
  // A factory left un-guarded here is the exact anti-uninstall bypass the
  // guard exists to prevent: any code in the same isolate as a shipped
  // release app could swap in a guard that always answers "not granted yet",
  // handing out unlimited fresh 24h trials on every launch.
  //
  // Uses its own AppLovin config rather than `initOnce()`/`_config` (AdMob):
  // `debugSimulateReleaseModeForTestSeams` blocks EVERY seam at once,
  // including `debugAdapterFactory` (this file's `_OkAdapter` stand-in), so
  // the REAL adapter runs underneath. The real `AdMobAdapter` needs a fuller
  // native mock than this file's generic channel handlers provide and fails
  // outright in a plain `flutter test`; the real `AppLovinAdapter` only
  // awaits `AppLovinMAX.initialize(sdkKey)`, which the existing generic
  // `alChannel` handler (returning null) already satisfies — same reasoning
  // as `ump_auto_fail_open_closed_test.dart`'s header comment.
  test(
      'debugFirstInstallGuardFactory is ignored while release mode is '
      'simulated', () async {
    const appLovinConfig = AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(
        sdkKey: 'test-sdk-key',
        bannerId: 'banner-id',
        interstitialId: 'interstitial-id',
        appOpenId: 'appopen-id',
        rewardedId: 'rewarded-id',
      ),
      safety: AdSafetyParams(dryRun: true),
      firstInstallVipGrace: FirstInstallVipGrace.day,
    );

    // Claims "already granted" — if the override took effect, grace would
    // be SKIPPED. `kDebugMode` is true under `flutter test`, so the real
    // (un-overridden) `FirstInstallGuard()` answers `false` instead (its
    // own debug-build bypass), and grace is granted as normal.
    final guard = _ScriptedGuard(true);
    AdManager.debugFirstInstallGuardFactory = () => guard;
    AdManager.debugSimulateReleaseModeForTestSeams = true;
    addTearDown(() => AdManager.debugSimulateReleaseModeForTestSeams = false);

    // debugSimulateReleaseModeForTestSeams also blocks debugAdapterFactory
    // (see comment above), so the REAL AppLovinAdapter runs underneath —
    // its AppLovinMAX.initialize() needs the 'initialize' method call
    // specifically answered with a map, unlike this file's other tests
    // (which stay on the debugAdapterFactory-stubbed adapter and never
    // reach it).
    messenger.setMockMethodCallHandler(alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });

    await AdManager()
        .initialize(config: appLovinConfig, onComplete: (_, __) {});

    expect(AdManager().vip?.isActive, isTrue,
        reason: 'debugFirstInstallGuardFactory must not apply in a '
            '(simulated) release build — the real FirstInstallGuard must '
            'decide instead of a scripted override');
    expect(prefs.isFirstInstallGraceApplied(), isTrue);
    expect(guard.markGrantedCalls, 0,
        reason: 'the scripted guard must never be touched at all while the '
            'seam is blocked — proves the override was ignored outright, '
            'not merely out-voted');
  });
}
