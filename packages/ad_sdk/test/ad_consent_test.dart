import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
// Internal import: applyConsentToProviders is not part of the public API
// surface (only the AdConsent data class is exported) — this is the
// established pattern used by other tests in this suite to reach
// unexported internals directly. Same declaration as the public export
// above, so AdConsent is not ambiguous between the two imports.
import 'package:applovin_admob_sdk/src/core/ad_consent.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
// AdMessageCodec isn't exported from the public API — same workaround as
// gma_bridge_test.dart, needed to decode the real MobileAds#
// updateRequestConfiguration call args (RequestConfiguration uses this
// custom codec, not the default StandardMethodCodec).
import 'package:google_mobile_ads/src/ad_instance_manager.dart'
    show AdMessageCodec;

void main() {
  group('AdConsent', () {
    test('default constructor is conservative (all false)', () {
      const c = AdConsent();
      expect(c.hasUserConsent, isFalse);
      expect(c.isAgeRestrictedUser, isFalse);
      expect(c.doNotSell, isFalse);
    });

    test('conservative preset matches default', () {
      expect(AdConsent.conservative.hasUserConsent, isFalse);
      expect(AdConsent.conservative.isAgeRestrictedUser, isFalse);
      expect(AdConsent.conservative.doNotSell, isFalse);
    });

    test('fullyAccepted preset has consent=true', () {
      expect(AdConsent.fullyAccepted.hasUserConsent, isTrue);
      expect(AdConsent.fullyAccepted.isAgeRestrictedUser, isFalse);
      expect(AdConsent.fullyAccepted.doNotSell, isFalse);
    });

    test('custom values are preserved', () {
      const c = AdConsent(
        hasUserConsent: true,
        isAgeRestrictedUser: true,
        doNotSell: true,
      );
      expect(c.hasUserConsent, isTrue);
      expect(c.isAgeRestrictedUser, isTrue);
      expect(c.doNotSell, isTrue);
    });
  });

  group('applyConsentToProviders (T04 — COPPA documented-limitation warning)',
      () {
    TestWidgetsFlutterBinding.ensureInitialized();

    // applyConsentToProviders fires native calls on these channels (AppLovin's
    // are not awaited, so a MissingPluginException would surface as an
    // unhandled async error and fail the test). No-op them, same pattern as
    // npa_consent_wiring_test.dart.
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

    late List<({AdLogLevel level, String tag, String message})> logs;

    setUp(() {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
      logs = [];
      // AdConfig.onLog is only wired into SafeLogger by the real
      // AdManager.initialize() flow, so configure it directly here.
      SafeLogger.configure(
        onLog: (level, tag, message) =>
            logs.add((level: level, tag: tag, message: message)),
      );
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
      SafeLogger.resetForTest();
    });

    test('isAgeRestrictedUser=true logs the AppLovin COPPA-gap warning',
        () async {
      await applyConsentToProviders(const AdConsent(isAgeRestrictedUser: true));

      final warning = logs.where((l) =>
          l.tag == 'AdConsent' && l.message.contains('setIsAgeRestrictedUser'));
      expect(warning, isNotEmpty,
          reason: 'AppLovin MAX 4.x has no COPPA API — the gap must be '
              'surfaced loudly, not silently swallowed');
    });

    test('isAgeRestrictedUser=false does NOT log the COPPA-gap warning',
        () async {
      await applyConsentToProviders(
          const AdConsent(isAgeRestrictedUser: false));

      final warning = logs.where((l) =>
          l.tag == 'AdConsent' && l.message.contains('setIsAgeRestrictedUser'));
      expect(warning, isEmpty,
          reason: 'the warning is conditional on the age-restricted flag, '
              'not unconditional noise on every consent apply');
    });
  });

  group(
      'applyConsentToProviders — BLOCKER round-32: must not record consent '
      'as applied when the provider write actually failed', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    final gmaChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads',
      StandardMethodCodec(AdMessageCodec()),
    );

    tearDown(() {
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
      resetLastConsentAppliedToProviders();
    });

    test(
        'AdMob updateRequestConfiguration throws → lastConsentAppliedToProviders '
        'stays at the previous value instead of being overwritten with the '
        'consent that failed to apply', () async {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);

      // Previous session had already committed conservative consent — this
      // must survive a failed later apply, not be silently overwritten.
      messenger.setMockMethodCallHandler(
          gmaChannel, (call) async => null); // let the baseline apply land
      await applyConsentToProviders(AdConsent.conservative);
      expect(lastConsentAppliedToProviders, AdConsent.conservative);

      // Now the provider write starts failing (e.g. transient channel/native
      // error while the user is withdrawing consent).
      messenger.setMockMethodCallHandler(
          gmaChannel, (call) async => throw PlatformException(code: 'boom'));
      await applyConsentToProviders(AdConsent.fullyAccepted);

      expect(lastConsentAppliedToProviders, AdConsent.conservative,
          reason: 'AdMob never actually received the new consent — the SDK '
              'must not claim it did, or downstream reconcile logic will '
              'skip retrying a write that never landed');
    });
  });

  group(
      'applyConsentToProviders — T164: only the CONFIGURED provider(s) must '
      'apply, not always both', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    final gmaChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads',
      StandardMethodCodec(AdMessageCodec()),
    );

    tearDown(() {
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
      resetLastConsentAppliedToProviders();
    });

    // `MobileAds.instance` is a `static final` field — `_init()` (its own
    // internal, ALSO-unawaited channel call, unrelated to
    // updateRequestConfiguration) only ever fires on the very first access
    // across the whole test process. A gmaChannel handler that throws for
    // EVERY method call — the pattern the round-32 tests above get away
    // with only because something earlier already forced that one-time
    // init through successfully — fails it too whenever a T164 test is the
    // unlucky first to touch `MobileAds.instance`, surfacing as an
    // unrelated unhandled exception. Scoped to the one method actually
    // under test instead.
    void gmaThrowsOnlyForUpdateRequestConfiguration() {
      messenger.setMockMethodCallHandler(gmaChannel, (call) async {
        if (call.method == 'MobileAds#updateRequestConfiguration') {
          throw PlatformException(code: 'boom');
        }
        return null;
      });
    }

    // Note: there is no meaningful equivalent "AdMob-only app, AppLovin's
    // call fails" test. `AppLovinMAX.setHasUserConsent`/`setDoNotSell` are
    // `void`, fire-and-forget calls (verified against the real
    // `applovin_max` package source) — the code under test never awaits
    // them, so any channel failure surfaces as an unrelated, LATER unhandled
    // Future rejection rather than something the local try/catch can ever
    // observe. `appLovinApplied` is therefore always `true` in practice,
    // regardless of provider config — this half of the fix (excluding
    // AppLovin's result when it is not the configured provider) has no
    // reachable failure mode to exercise here. The test below covers the
    // half that IS reachable and meaningful: AdMob's own call IS awaited,
    // so its failure is what an AppLovin-only app must be exempt from.
    test(
        'AppLovin-only app (AdConfig.provider: appLovin): AdMob\'s call '
        'failing does not block recording consent as applied', () async {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      gmaThrowsOnlyForUpdateRequestConfiguration();

      await applyConsentToProviders(AdConsent.fullyAccepted,
          config: const AdConfig(
              provider: AdProvider.appLovin,
              appLovin: AppLovinConfig(
                sdkKey: 'sdk',
                bannerId: 'b',
                interstitialId: 'i',
                appOpenId: 'a',
                rewardedId: 'r',
              )));

      expect(lastConsentAppliedToProviders, AdConsent.fullyAccepted);
    });

    test(
        'AdMob-only app: AdMob\'s OWN call failing still blocks it — this '
        'is not a blanket "always succeed", only the unconfigured side is '
        'exempt', () async {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      gmaThrowsOnlyForUpdateRequestConfiguration();

      await applyConsentToProviders(AdConsent.fullyAccepted,
          config: const AdConfig(
              provider: AdProvider.admob,
              admob: AdMobConfig(
                bannerId: 'b',
                interstitialId: 'i',
                appOpenId: 'a',
              )));

      expect(lastConsentAppliedToProviders, isNull,
          reason: 'T164 — the CONFIGURED provider failing must still block '
              'recording consent as applied, exactly as round-32 intended');
    });

    test(
        'dual-provider case unaffected: both configured providers must '
        'still BOTH apply (config == null keeps the original require-both '
        'default, matching the round-32 test above which never passes a '
        'config)', () async {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      gmaThrowsOnlyForUpdateRequestConfiguration();

      await applyConsentToProviders(AdConsent.fullyAccepted);

      expect(lastConsentAppliedToProviders, isNull,
          reason: 'no config context at all — must not silently exempt '
              'either provider from the original round-32 guarantee');
    });

    test(
        'AdMob-only app, ordinary success on both sides: commits exactly '
        'as before (sanity — the fix must not regress the normal case)',
        () async {
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);

      await applyConsentToProviders(AdConsent.fullyAccepted,
          config: const AdConfig(
              provider: AdProvider.admob,
              admob: AdMobConfig(
                bannerId: 'b',
                interstitialId: 'i',
                appOpenId: 'a',
              )));

      expect(lastConsentAppliedToProviders, AdConsent.fullyAccepted);
    });
  });

  group(
      'applyConsentToProviders testDeviceIds re-apply '
      '(consent re-apply test gap, 2026-08-22 audit)', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    // Must match the production channel's codec (AdMessageCodec) — it's the
    // only way to decode RequestConfiguration's testDeviceIds argument, see
    // gma_bridge_test.dart.
    final gmaChannel = MethodChannel(
      'plugins.flutter.io/google_mobile_ads',
      StandardMethodCodec(AdMessageCodec()),
    );

    final calls = <MethodCall>[];

    setUp(() {
      calls.clear();
      messenger.setMockMethodCallHandler(alChannel, (call) async => null);
      messenger.setMockMethodCallHandler(gmaChannel, (call) async {
        calls.add(call);
        return null;
      });
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
    });

    const config = AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
        bannerId: 'b',
        interstitialId: 'i',
        appOpenId: 'ao',
        testDeviceIds: ['host-device-1'],
      ),
    );

    test(
        'mid-session re-apply (e.g. a later setConsent call) still forwards '
        'the QA fleet hashes alongside the host device id, not just on the '
        'first call', () async {
      // First call — mirrors the initial consent apply at SDK init.
      await applyConsentToProviders(AdConsent.conservative, config: config);
      // Second call with a DIFFERENT consent value — mirrors a mid-session
      // setConsent() (e.g. host's own consent UI, or a UMP re-prompt answer).
      await applyConsentToProviders(AdConsent.fullyAccepted, config: config);

      expect(calls.length, 2);
      for (final call in calls) {
        final ids = List<String>.from(call.arguments['testDeviceIds'] as List);
        expect(ids, contains('host-device-1'),
            reason: 'must not drop the host-configured test device on '
                're-apply');
        for (final hash in kQaTestDeviceHashes) {
          expect(ids, contains(hash),
              reason: 'must not drop the always-on QA fleet hashes on '
                  're-apply');
        }
      }
    });
  });

  group('T120: simulateConsentOutcome', () {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const alChannel = MethodChannel('applovin_max');
    const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

    late List<MethodCall> alCalls;

    setUp(() {
      alCalls = [];
      messenger.setMockMethodCallHandler(alChannel, (call) async {
        alCalls.add(call);
        return null;
      });
      messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
    });

    tearDown(() {
      messenger.setMockMethodCallHandler(alChannel, null);
      messenger.setMockMethodCallHandler(gmaChannel, null);
    });

    test('pure — matches the documented AdMob/AppLovin mapping for every '
        'GDPR/CCPA/COPPA/config combination, with zero platform calls made',
        () async {
      // Every combination this axis can take: hasUserConsent (GDPR),
      // doNotSell (CCPA), isAgeRestrictedUser (COPPA), and the host's own
      // umpTagForUnderAgeOfConsent config flag.
      for (final hasUserConsent in [false, true]) {
        for (final doNotSell in [false, true]) {
          for (final isAgeRestrictedUser in [false, true]) {
            for (final tagUnderAge in [false, true]) {
              final consent = AdConsent(
                hasUserConsent: hasUserConsent,
                doNotSell: doNotSell,
                isAgeRestrictedUser: isAgeRestrictedUser,
              );
              final config = AdConfig(
                provider: AdProvider.admob,
                admob: const AdMobConfig(
                    bannerId: 'b',
                    interstitialId: 'i',
                    appOpenId: 'ao',
                    rewardedId: 'r'),
                umpTagForUnderAgeOfConsent: tagUnderAge,
              );

              final result = simulateConsentOutcome(consent, config: config);
              expect(result.appLovinHasUserConsent, hasUserConsent);
              expect(result.appLovinDoNotSell, doNotSell);
              expect(result.appLovinCoppaForwarded, isFalse,
                  reason: 'AppLovin MAX 4.x has no API to receive this '
                      'signal at all, regardless of input');
              expect(result.admobTagForChildDirectedTreatment,
                  isAgeRestrictedUser ? 'yes' : 'no');
              expect(result.admobTagForUnderAgeOfConsent,
                  tagUnderAge ? 'yes' : 'unspecified');
            }
          }
        }
      }
      expect(alCalls, isEmpty,
          reason: 'a SIMULATION must never touch a real platform channel — '
              'that is the entire point of this API');
    });

    test('shares its decision with the real apply path (single source of '
        'truth) — AppLovin receives exactly what the simulation predicted',
        () async {
      const consent = AdConsent(hasUserConsent: false, doNotSell: true);
      final simulated = simulateConsentOutcome(consent);

      await applyConsentToProviders(consent);

      expect(alCalls.map((c) => c.method),
          ['setHasUserConsent', 'setDoNotSell']);
      expect((alCalls[0].arguments as Map)['value'],
          simulated.appLovinHasUserConsent);
      expect((alCalls[1].arguments as Map)['value'],
          simulated.appLovinDoNotSell);
    });
  });
}
