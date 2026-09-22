// T42 — regression test for consent being silently "forgotten" on every app
// launch.
//
// Real host order (see SplashScreen): requestUmpConsent() (→ setConsent())
// runs BEFORE initialize(). At that point AdManager._consentManager is still
// null, so the old setConsent() only touched an in-memory field and returned
// early — then initialize()'s ConsentManager.bootstrap() unconditionally
// reloaded the STALE, previously-persisted value and overwrote it. This test
// reproduces that exact sequence against the real initialize() path (not the
// debugSetAdapter/debugConfig seams) so the fix is proven end-to-end.
//
// Provider is AppLovin, not AdMob: AdMobAdapter.initialize() reaches into
// google_mobile_ads' AdInstanceManager, which needs far more native-side
// state than a method channel returning null can fake, so it always fails in
// a plain `flutter test` run (see the "re-init guard" group in
// ad_manager_core_test.dart, which only asserts on pre-adapter-init side
// effects for that reason). AppLovinAdapter.initialize() just awaits
// AppLovinMAX.initialize(sdkKey), which is satisfied by the channel
// returning an (empty, all-nullable) config map — a real init success is
// reachable, which is required to exercise the fix (it runs AFTER adapter
// init succeeds).

import 'dart:async';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_mobile_ads/src/ump/user_messaging_codec.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');

// Same codec requirement as ump_consent_test.dart — the plain default codec
// can't decode ConsentRequestParameters, corrupting the call before our
// handler sees it.
final _umpChannel = MethodChannel(
  'plugins.flutter.io/google_mobile_ads/ump',
  StandardMethodCodec(UserMessagingCodec()),
);

// applyConsentToProviders() (ad_consent.dart) unconditionally touches
// MobileAds.instance regardless of the active provider — pre-existing
// behavior, out of scope for T42. MobileAds.instance's first access fires an
// un-awaited '_init' platform call; if this channel isn't mocked, that call
// throws MissingPluginException as an unhandled async error (outside the
// try/catch in ad_consent.dart, which only wraps updateRequestConfiguration)
// and fails this test even though every explicit expect() below passes.
const _gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

AdConfig _appLovinConfig() => const AdConfig(
      provider: AdProvider.appLovin,
      appLovin: AppLovinConfig(
        sdkKey: 'test-sdk-key',
        bannerId: 'banner-id',
        interstitialId: 'interstitial-id',
        appOpenId: 'appopen-id',
        rewardedId: 'rewarded-id',
      ),
      safety: AdSafetyParams(dryRun: true),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          return Future.value(null);
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          return Future.value(0); // unknown
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
        default:
          return Future.value(null);
      }
    });
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_umpChannel, null);
  });

  setUp(() async {
    await AdManager().destroy();
    AdPreferences.resetForTest();
    ConsentManager.resetForTest();
  });

  tearDown(() async {
    await AdManager().destroy();
  });

  // R10-A — requestUmpConsent()'s own doc comment says standard usage is to
  // call it BEFORE initialize(). autoRequestUmpConsent:true used to run the
  // UMP flow AFTER adapter.initialize() had already fired the first
  // AppLovin/AdMob native init call, so that native init went out before EEA
  // consent was known.
  //
  // Round-71 audit fix (MAJOR, codex + gemini reviewers, both independent) —
  // an earlier version of this test only proved the UMP *call* fires first;
  // it never held the flow open, so it couldn't tell an awaited flow from a
  // fire-and-forget one that merely starts first by coincidence of
  // scheduling. `getConsentStatus` — the step that decides whether a form is
  // even needed — is parked here, and adapter.initialize() is asserted to
  // NOT have fired while consent is still undetermined, before being
  // released to prove init still proceeds normally afterward.
  // `requestUmpConsent()` already carries its own 240s hard cap (see
  // ad_manager.dart's M6 fix), so awaiting it in production cannot hang
  // forever the way the original fire-and-forget design once feared.
  //
  // Asserts on `AdManager().isInitialised` rather than a raw
  // `al:initialize` channel call — package:applovin_max memoizes its
  // initialize() call behind a static `_hasInitializeInvoked` flag with no
  // test reset hook, so once any earlier test in this *process* (not just
  // this file — flutter test can share a worker isolate across files) has
  // called AppLovinMAX.initialize(), later calls short-circuit without
  // touching the method channel at all, even though they still resolve
  // successfully. `isInitialised` reflects this SDK's own per-session state
  // (`_config != null && _adapter != null`), which resets every `destroy()`
  // regardless of the native plugin's one-time memoization — immune to test
  // run order.
  test('autoRequestUmpConsent:true — adapter.initialize() waits for the UMP '
      'flow to actually resolve', () async {
    SharedPreferences.setMockInitialValues({});
    final callOrder = <String>[];
    final consentStatusGate = Completer<int>();

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    messenger.setMockMethodCallHandler(_umpChannel, (call) {
      switch (call.method) {
        case 'ConsentInformation#requestConsentInfoUpdate':
          callOrder.add('ump:${call.method}');
          return Future.value(null);
        case 'ConsentInformation#canRequestAds':
          return Future.value(true);
        case 'ConsentInformation#getConsentStatus':
          // Held open deliberately — native SDK init must not fire while
          // this is still pending.
          return consentStatusGate.future;
        case 'ConsentInformation#isConsentFormAvailable':
          return Future.value(false);
        default:
          return Future.value(null);
      }
    });
    addTearDown(() {
      if (!consentStatusGate.isCompleted) consentStatusGate.complete(0);
      messenger.setMockMethodCallHandler(_alChannel, (call) async {
        if (call.method == 'initialize') return <String, dynamic>{};
        return null;
      });
      messenger.setMockMethodCallHandler(_umpChannel, (call) {
        switch (call.method) {
          case 'ConsentInformation#requestConsentInfoUpdate':
            return Future.value(null);
          case 'ConsentInformation#canRequestAds':
            return Future.value(true);
          case 'ConsentInformation#getConsentStatus':
            return Future.value(0);
          case 'ConsentInformation#isConsentFormAvailable':
            return Future.value(false);
          default:
            return Future.value(null);
        }
      });
    });

    final pending = AdManager().initialize(
      config: const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'test-sdk-key',
          bannerId: 'banner-id',
          interstitialId: 'interstitial-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
        ),
        safety: AdSafetyParams(dryRun: true),
        autoRequestUmpConsent: true,
      ),
      onComplete: (_, __) {},
    );

    // A fixed `pumpEventQueue(times: N)` only flushes microtasks — under
    // real parallel CPU load from other test workers, that can occasionally
    // not be enough wall-clock-independent turns to reach the mocked
    // `getConsentStatus` gate, making this flaky depending on what else the
    // suite happens to schedule alongside it. Poll for the actual condition
    // instead (same pattern as `r23_coppa_midinit_flip_test.dart`'s
    // `_pumpUntil`), which is robust regardless of scheduling variance.
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (callOrder.isEmpty && DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }

    expect(
        callOrder, contains('ump:ConsentInformation#requestConsentInfoUpdate'));
    expect(AdManager().isInitialised, isFalse,
        reason: 'the SDK must not consider itself initialised while UMP '
            'consent status is still being determined — the native SDK '
            'must not start before EEA/UK consent is known');

    consentStatusGate.complete(0); // unknown status, no form required
    await pending;

    expect(AdManager().isInitialised, isTrue,
        reason: 'UMP consent flow must resolve before the AppLovin/AdMob '
            'adapter fires its first native init call, so that init already '
            'reflects the user\'s EEA consent choice');
  });

  test(
      'setConsent() called BEFORE initialize() survives the bootstrap '
      '(not overwritten by stale persisted data)', () async {
    // Simulate a previous session that had already rejected consent —
    // exactly the stale data initialize()'s bootstrap would otherwise reload.
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await prefs.setConsentSettingsRaw(
      ConsentSettings.encode(ConsentSettings.rejected),
    );

    // Real host order: requestUmpConsent() → setConsent() runs first, while
    // _consentManager is still null.
    await AdManager().setConsent(AdConsent.fullyAccepted);

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );

    expect(AdManager().isInitialised, isTrue,
        reason: 'adapter init must have actually succeeded for this test to '
            'prove anything about the post-init consent logic');
    expect(AdManager().consent.hasUserConsent, isTrue,
        reason: 'the fresh UMP result must win over the stale bootstrap');
    expect(AdManager().consentManager!.current.hasUserConsent, isTrue);
    expect(AdManager().consentManager!.current.hasBeenAsked, isTrue);

    // And it must actually be persisted, not just held in memory.
    final persisted = ConsentSettings.decode(prefs.getConsentSettingsRaw());
    expect(persisted.hasUserConsent, isTrue,
        reason: 'setConsent() must write through even before initialize()');
  });

  test(
      'initialize() with no pending setConsent() still loads persisted '
      'consent normally (no regression)', () async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await AdPreferences.getInstance();
    await prefs.setConsentSettingsRaw(
      ConsentSettings.encode(ConsentSettings.accepted),
    );

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, __) {},
    );

    expect(AdManager().isInitialised, isTrue);
    expect(AdManager().consent.hasUserConsent, isTrue);
    expect(AdManager().consentManager!.current.hasUserConsent, isTrue);
  });

  // Audit finding: initialize()'s autoRequestUmpConsent branch called
  // requestUmpConsent() without forwarding AdConfig.umpDebugGeography /
  // AdConfig.umpTestIdentifiers, silently dropping EEA-debug-test config.
  test(
      'autoRequestUmpConsent forwards umpDebugGeography/umpTestIdentifiers '
      'into the internal requestUmpConsent() call', () async {
    SharedPreferences.setMockInitialValues({});

    await AdManager().initialize(
      config: const AdConfig(
        provider: AdProvider.appLovin,
        appLovin: AppLovinConfig(
          sdkKey: 'test-sdk-key',
          bannerId: 'banner-id',
          interstitialId: 'interstitial-id',
          appOpenId: 'appopen-id',
          rewardedId: 'rewarded-id',
        ),
        safety: AdSafetyParams(dryRun: true),
        autoRequestUmpConsent: true,
        umpDebugGeography: DebugGeography.debugGeographyEea,
        umpTestIdentifiers: ['TEST-ID'],
      ),
      onComplete: (_, __) {},
    );

    expect(AdManager().isInitialised, isTrue);
    expect(AdManager().debugLastAutoUmpParams, isNotNull);
    expect(AdManager().debugLastAutoUmpParams!['debugGeography'],
        DebugGeography.debugGeographyEea);
    expect(AdManager().debugLastAutoUmpParams!['testIdentifiers'], ['TEST-ID']);
  });
}
