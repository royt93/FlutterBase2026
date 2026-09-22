// Coverage was 0% despite ConsentManager being the standalone consent
// singleton every host app talks to — no test file existed for it at all.
// Covers: bootstrap/idempotency, programmatic set/reset, persistence
// round-trip, and the reactive listenable.

import 'dart:async';

import 'package:applovin_admob_sdk/src/config/ad_config.dart';
import 'package:applovin_admob_sdk/src/consent/consent_fallback.dart';
import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/utils/safe_logger.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // applyConsentToProviders (called by every mutator below) fires native
  // calls on these channels — no-op them, same pattern as ad_consent_test.dart.
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  late AdPreferences prefs;

  setUp(() async {
    messenger.setMockMethodCallHandler(alChannel, (call) async => null);
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    ConsentManager.resetForTest();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
    ConsentManager.resetForTest();
  });

  test('instance throws before bootstrap', () {
    expect(() => ConsentManager.instance, throwsStateError);
    expect(ConsentManager.isReady, isFalse);
  });

  test('bootstrap loads unset defaults on a fresh install', () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs);
    expect(ConsentManager.isReady, isTrue);
    expect(m.current, ConsentSettings.unset);
    expect(m.hasBeenAsked, isFalse);
  });

  test('bootstrap is idempotent and re-loads persisted settings', () async {
    await prefs.setConsentSettingsRaw(ConsentSettings.encode(
      ConsentSettings.accepted,
    ));
    final m1 = await ConsentManager.bootstrap(
        prefs: prefs);
    expect(m1.current.hasUserConsent, isTrue);

    final m2 = await ConsentManager.bootstrap(
        prefs: prefs);
    expect(identical(m1, m2), isTrue,
        reason: 'second bootstrap call must reuse the singleton');
  });

  test(
      'bootstrap called again with a DIFFERENT AdPreferences instance warns '
      'instead of silently ignoring it', () async {
    final warnings = <String>[];
    SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => warnings.add('$tag: $message'));
    addTearDown(() => SafeLogger.configure());

    await ConsentManager.bootstrap(prefs: prefs);

    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    final otherPrefs = await AdPreferences.getInstance();
    addTearDown(AdPreferences.resetForTest);
    await ConsentManager.bootstrap(
        prefs: otherPrefs);

    expect(warnings, isNotEmpty,
        reason: 'silently discarding the second call\'s prefs argument is a '
            'confusing API contract — it must at least be visible in logs');
  });

  test(
      'bootstrap called again with the SAME AdPreferences instance does '
      'NOT warn — this is the normal, expected usage pattern', () async {
    final warnings = <String>[];
    SafeLogger.configure(
        level: AdLogLevel.warning,
        onLog: (level, tag, message) => warnings.add('$tag: $message'));
    addTearDown(() => SafeLogger.configure());

    await ConsentManager.bootstrap(prefs: prefs);
    await ConsentManager.bootstrap(prefs: prefs);
    await ConsentManager.bootstrap(prefs: prefs);

    expect(warnings, isEmpty,
        reason: 'AdManager.initialize() re-bootstraps with the same '
            'AdPreferences singleton every time — that must stay silent, '
            'not log a false-positive warning on every ordinary re-init');
  });

  test('set() persists, updates listenable, and re-applies to providers',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs);

    final seen = <ConsentSettings>[];
    m.listenable.addListener(() => seen.add(m.listenable.value));

    await m.set(ConsentSettings.rejected);

    expect(m.current.hasUserConsent, isFalse);
    expect(m.current.hasBeenAsked, isTrue);
    expect(seen, hasLength(1));
    expect(ConsentSettings.decode(prefs.getConsentSettingsRaw()).hasBeenAsked,
        isTrue,
        reason: 'set() must persist through to SharedPreferences');
  });

  test('reset() wipes back to unset and persists it', () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs);
    await m.set(ConsentSettings.accepted);

    await m.reset();

    // Round-29 audit (MAJOR fix): reset() now returns a fresh instance with
    // isAgeRestrictedUser/doNotSell carried over from before the reset
    // (both false here, same as `unset`) rather than the literal `unset`
    // singleton — so this must compare by value (`ConsentSettings` has no
    // `operator ==`), not by identity.
    expect(m.current.toJson(), ConsentSettings.unset.toJson());
    expect(ConsentSettings.decode(prefs.getConsentSettingsRaw()).toJson(),
        ConsentSettings.unset.toJson());
  });

  test(
      'round-29 audit (MAJOR): reset() preserves isAgeRestrictedUser and '
      'doNotSell — those are app-level flags, not per-user consent answers',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs);
    await m.set(ConsentSettings.accepted.copyWith(
      isAgeRestrictedUser: true,
      doNotSell: true,
    ));
    expect(m.current.isAgeRestrictedUser, isTrue);
    expect(m.current.doNotSell, isTrue);

    await m.reset();

    expect(m.current.hasUserConsent, isFalse,
        reason: 'the per-user consent answer must still be wiped');
    expect(m.current.hasBeenAsked, isFalse);
    expect(m.current.isAgeRestrictedUser, isTrue,
        reason: 'a child-directed app must not have its COPPA flag '
            'silently cleared by what looks like a benign consent reset');
    expect(m.current.doNotSell, isTrue,
        reason: 'CCPA opt-out must not be silently cleared by reset()');
    expect(
        ConsentSettings.decode(prefs.getConsentSettingsRaw())
            .isAgeRestrictedUser,
        isTrue,
        reason: 'the preserved flag must also survive persistence');
  });

  test('applyToProviders can be called standalone without changing settings',
      () async {
    final m = await ConsentManager.bootstrap(
        prefs: prefs);
    await m.set(ConsentSettings.accepted);

    await expectLater(m.applyToProviders(), completes);
    expect(m.current.hasUserConsent, isTrue);
  });

  group('T210 audit fix — a fallback recorded under an old policy revision '
      'is reclassified as staleRevision on load', () {
    test('a persisted fallback under an OLD policyRevision is reclassified',
        () async {
      final old = ConsentFallbackState.create(
        policyRevision: 'ump-v0',
        reason: ConsentFallbackReason.timeout,
        now: DateTime.utc(2020, 1, 1),
      );
      await prefs.setConsentFallbackRaw(old.encode());

      final m = await ConsentManager.bootstrap(
          prefs: prefs);

      expect(m.fallback?.reason, ConsentFallbackReason.staleRevision,
          reason: 'ump-v0 no longer matches the SDK\'s current declared '
              'kUmpPolicyRevision — a host reading .fallback must be told '
              'this record predates the current policy, not that it was '
              'still a timeout/platformError');
      expect(m.fallback?.policyRevision, 'ump-v0',
          reason: 'original provenance (which revision it WAS recorded '
              'under) must be preserved, not overwritten');
      expect(m.fallback?.recordedAt, old.recordedAt);

      // The reclassification is itself persisted, so a second bootstrap
      // (e.g. a later app launch) reads it back the same way rather than
      // re-deriving it every time.
      final raw = prefs.getConsentFallbackRaw();
      expect(raw, isNotNull);
      expect(ConsentFallbackState.decode(raw).reason,
          ConsentFallbackReason.staleRevision);
    });

    test('a persisted fallback under the CURRENT policyRevision is left '
        'untouched', () async {
      final current = ConsentFallbackState.create(
        policyRevision: kUmpPolicyRevision,
        reason: ConsentFallbackReason.offline,
      );
      await prefs.setConsentFallbackRaw(current.encode());

      final m = await ConsentManager.bootstrap(
          prefs: prefs);

      expect(m.fallback?.reason, ConsentFallbackReason.offline,
          reason: 'a fallback recorded under the CURRENT policy revision '
              'must keep its real reason, not be reclassified');
    });

    test('no persisted fallback at all stays null', () async {
      final m = await ConsentManager.bootstrap(
          prefs: prefs);
      expect(m.fallback, isNull);
    });

    test(
        'codex round-2 fix — a fallback recorded under a NON-UMP '
        'policyRevision (e.g. a host\'s own ATT fallback) is never '
        'reclassified, even though it differs from kUmpPolicyRevision',
        () async {
      // recordFallback() is public and documented for UMP/ATT/any caller-
      // supplied reason — 'att-v1' is a legitimate value a host could pass,
      // not a stale UMP record. It must not be permanently misclassified as
      // staleRevision just for not matching the UMP constant.
      final attFallback = ConsentFallbackState.create(
        policyRevision: 'att-v1',
        reason: ConsentFallbackReason.platformError,
      );
      await prefs.setConsentFallbackRaw(attFallback.encode());

      final m = await ConsentManager.bootstrap(
          prefs: prefs);

      expect(m.fallback?.reason, ConsentFallbackReason.platformError,
          reason: 'this is not a UMP-namespaced record — the staleRevision '
              'migration must not touch it');
      expect(m.fallback?.policyRevision, 'att-v1');
    });
  });

  group('round-71 audit fix (MAJOR, gemini reviewer)', () {
    // `resetForTest` was `@visibleForTesting` only (an analyzer lint, not a
    // runtime guard), same gap rounds 68-70 fixed on `AdManager`/adapters —
    // any code in a shipped release app could tear down the live consent
    // singleton.
    test('resetForTest is ignored while release mode is simulated',
        () async {
      final m = await ConsentManager.bootstrap(prefs: prefs);

      ConsentManager.debugSimulateReleaseModeForTestSeams = true;
      addTearDown(() =>
          ConsentManager.debugSimulateReleaseModeForTestSeams = false);
      ConsentManager.resetForTest();

      expect(ConsentManager.instance, same(m),
          reason: 'resetForTest must not tear down the live singleton in a '
              '(simulated) release build');
    });
  });

  group('round-72 audit fix (MAJOR, gemini external) — read-site seams', () {
    // `debugPersistDelay`/`debugApplyBarrier` are read at 4 call sites
    // (`_persist`, `applyToProviders`, `reset`, `_setInternal`'s own apply)
    // rather than gated at assignment — same reason as `resetForTest` above,
    // proven here through the one public entry point (`set`) every one of
    // those sites is reachable from.
    test('debugPersistDelay is ignored while release mode is simulated',
        () async {
      final m = await ConsentManager.bootstrap(prefs: prefs);

      ConsentManager.debugPersistDelay = const Duration(milliseconds: 300);
      ConsentManager.debugSimulateReleaseModeForTestSeams = true;
      addTearDown(() {
        ConsentManager.debugSimulateReleaseModeForTestSeams = false;
        ConsentManager.debugPersistDelay = null;
      });

      final sw = Stopwatch()..start();
      await m.set(const ConsentSettings(
          hasUserConsent: true, hasBeenAsked: true));
      sw.stop();

      expect(sw.elapsedMilliseconds, lessThan(150),
          reason: 'debugPersistDelay must not apply in a (simulated) '
              'release build — a debug-only seam must not be able to '
              'throttle production consent persistence');
    });

    test('debugApplyBarrier is ignored while release mode is simulated',
        () async {
      final m = await ConsentManager.bootstrap(prefs: prefs);
      final neverCompletes = Completer<void>();

      ConsentManager.debugApplyBarrier = neverCompletes.future;
      ConsentManager.debugSimulateReleaseModeForTestSeams = true;
      addTearDown(() {
        ConsentManager.debugSimulateReleaseModeForTestSeams = false;
        ConsentManager.debugApplyBarrier = null;
      });

      await m
          .set(const ConsentSettings(
              hasUserConsent: true, hasBeenAsked: true))
          .timeout(const Duration(seconds: 2),
              onTimeout: () => fail(
                  'debugApplyBarrier must not apply in a (simulated) '
                  'release build — it hung waiting on a barrier that '
                  'never completes, exactly what a shipped app must never '
                  'do while applying a real consent decision'));
    });
  });
}
