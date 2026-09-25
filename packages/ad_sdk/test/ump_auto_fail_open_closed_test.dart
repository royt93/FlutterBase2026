// Unit tests for Issue 1 — initialize()'s autoRequestUmpConsent branch must
// fail OPEN only for MissingPluginException (UMP channel not registered —
// i.e. UMP simply isn't wired for this host) and fail CLOSED for any other
// exception (a real consent-fetch failure, with the channel actually wired).
//
// AdManager().debugForceAutoUmpError lets a test force the exact exception
// the runZonedGuarded catch handler sees, without needing a real UMP channel
// failure — see ad_manager.dart's `_onCanRequestAdsChanged`-adjacent comment
// block above `if (e is MissingPluginException)` for the compliance
// rationale (fail-closed unless UMP is provably not wired).
//
// Provider is AppLovin, not AdMob: AdMobAdapter.initialize() reaches into
// google_mobile_ads' AdInstanceManager, which needs far more native-side
// state than a method channel returning null can fake, so it always fails in
// a plain `flutter test` run (see consent_persistence_on_init_test.dart's
// header comment for the same constraint). AppLovinAdapter.initialize() just
// awaits AppLovinMAX.initialize(sdkKey), satisfied by the channel returning
// an (empty, all-nullable) config map.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _alChannel = MethodChannel('applovin_max');
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
      autoRequestUmpConsent: true,
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, (call) async {
      if (call.method == 'initialize') return <String, dynamic>{};
      return null;
    });
    // applyConsentToProviders() unconditionally touches MobileAds.instance
    // regardless of the active provider — an unmocked _gmaChannel would
    // throw a stray, unrelated MissingPluginException here too.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, (call) async => null);
  });

  tearDownAll(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_alChannel, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_gmaChannel, null);
  });

  tearDown(() async {
    AdManager().debugForceAutoUmpError = null;
    AdManager.debugSimulateReleaseModeForUmpGate = false;
    await AdManager().destroy();
  });

  test('MissingPluginException fails OPEN in a debug build — gate reopens',
      () async {
    SharedPreferences.setMockInitialValues({});
    AdManager().debugForceAutoUmpError =
        MissingPluginException('forced for test');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().canRequestAds, isTrue,
        reason: 'UMP not wired (simulated via MissingPluginException) must '
            'fail OPEN so ads are not permanently blocked for a host that '
            'never wires the UMP channel');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });

  test('a non-MissingPluginException fails CLOSED — gate stays shut',
      () async {
    SharedPreferences.setMockInitialValues({});
    AdManager().debugForceAutoUmpError = Exception('forced network failure');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().canRequestAds, isFalse,
        reason: 'a genuine consent-fetch failure (channel IS wired) must '
            'keep the gate closed — failing open here would ship ads with '
            'no verified consent decision');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });
  // Round-7 audit, MAJOR — the fail-open above is a DEBUG convenience only.
  // `google_mobile_ads` is a hard dependency of this package and Flutter
  // registers its channels automatically (AppLovin provider included), so in a
  // shipped app a missing UMP channel means the native integration is broken,
  // not that UMP is out of play. Reopening the gate there serves ads with no
  // verified consent decision — the exact GDPR exposure the fail-closed branch
  // exists to prevent.
  test('the same MissingPluginException fails CLOSED in a release build',
      () async {
    SharedPreferences.setMockInitialValues({});
    AdManager.debugSimulateReleaseModeForUmpGate = true;
    AdManager().debugForceAutoUmpError =
        MissingPluginException('forced for test');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().canRequestAds, isFalse,
        reason: 'a release build cannot treat a missing UMP channel as '
            '"consent not required" — no consent decision was verified');
    expect(AdManager().debugUmpAttemptFailed, isTrue);
  });

  test('the predicate itself only ever reopens for a missing plugin', () {
    expect(
        AdManager.umpFailureMayReopenGate(MissingPluginException('x')), isTrue);
    expect(AdManager.umpFailureMayReopenGate(Exception('network')), isFalse);
    AdManager.debugSimulateReleaseModeForUmpGate = true;
    expect(
        AdManager.umpFailureMayReopenGate(MissingPluginException('x')), isFalse,
        reason: 'release build: not even a missing plugin reopens the gate');
  });

  // Round-72 audit fix (MAJOR, gemini external) — debugForceAutoUmpError
  // itself (distinct from the umpFailureMayReopenGate predicate above) was
  // never gated by AdManager.debugSimulateReleaseModeForTestSeams: any code
  // in the same isolate as a shipped release app could force the auto-UMP
  // path to throw, breaking consent flows in production. Uses
  // debugSimulateReleaseModeForTestSeams (the seam-wide guard), not
  // debugSimulateReleaseModeForUmpGate used by the tests above — a
  // different flag for a different guard.
  //
  // Can't assert "the flow succeeded" directly — this suite has no mocked
  // UMP channel, so the real auto-UMP call always throws
  // MissingPluginException regardless. Instead this proves the forced
  // *generic* Exception (which the 'fails CLOSED' test above shows keeps
  // the gate shut) has zero effect once seam-blocked: the real channel's
  // own MissingPluginException takes over and fails OPEN instead, per the
  // 'fails OPEN' test above — a real, observable behavioral difference.
  test('debugForceAutoUmpError is ignored while (seam) release mode is '
      'simulated — real channel failure fails OPEN instead', () async {
    SharedPreferences.setMockInitialValues({});
    AdManager.debugSimulateReleaseModeForTestSeams = true;
    addTearDown(() => AdManager.debugSimulateReleaseModeForTestSeams = false);
    AdManager().debugForceAutoUmpError = Exception('forced network failure');

    await AdManager().initialize(
      config: _appLovinConfig(),
      onComplete: (_, _) {},
    );
    await Future<void>.delayed(Duration.zero);

    expect(AdManager().canRequestAds, isTrue,
        reason: 'the forced (fails-CLOSED) generic Exception must not apply '
            'in a (simulated) release build — the real channel\'s own '
            'MissingPluginException should have run instead and failed OPEN');
  });
}
