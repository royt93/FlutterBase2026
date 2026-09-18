// Round-44 audit fix — finding 3. `applyConsentToProviders` used to call
// `AppLovinMAX.setHasUserConsent(bool)` unconditionally, always feeding it
// the SAME purpose-only boolean this SDK computes for AdMob's per-request
// `npa` flag (`AdConsent.hasUserConsent`, built from
// `IabStorage.tcfAllowsPersonalisedAds()` — deliberately vendor-blind, a
// choice documented and reasonable specifically for parsing Google's own
// vendor id out of the range-encoded TC string). That same boolean has no
// equivalent vendor-consent basis for AppLovin: a user who consented to
// purposes 1/3/4 but never consented to (or denied) the AppLovin vendor was
// still reported to MAX as consenting.
//
// Root cause turned out to be architectural, not just a missing vendor
// check: AppLovin's own MAX integration docs say the SDK auto-reads a real
// IAB TCF string from platform storage the moment a certified CMP (UMP)
// writes one, and the explicit `setHasUserConsent` call is documented as
// the path for apps that do NOT use a CMP at all
// (https://support.applovin.com/en/max/ios/overview/terms-and-privacy-policy-flow
// — "If you do not use a CMP ... you must continue to set AppLovin's SDK's
// binary consent flags"). The fix: skip the explicit call whenever a real
// TC string is already on the device (MAX evaluates its own — correct —
// vendor consent from it); keep calling it when there is no CMP session at
// all, exactly as AppLovin's own docs describe.
//
// `setDoNotSell` is CCPA/US-Privacy, an unrelated axis with no IAB TCF
// vendor-consent concept — it must stay unconditional, unaffected by this
// gate.

import 'package:applovin_admob_sdk/src/core/ad_consent.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences_platform_interface/in_memory_shared_preferences_async.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const alChannel = MethodChannel('applovin_max');
  const gmaChannel = MethodChannel('plugins.flutter.io/google_mobile_ads');

  late List<String> alCalls;

  setUp(() {
    IabStorage.debugResetForTest();
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.empty();
    alCalls = [];
    messenger.setMockMethodCallHandler(alChannel, (call) async {
      alCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(gmaChannel, (call) async => null);
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(alChannel, null);
    messenger.setMockMethodCallHandler(gmaChannel, null);
  });

  test(
      'a real TCF string on device (UMP already ran) → setHasUserConsent is '
      'NOT called, MAX reads it itself (THE finding)', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(
            {'IABTCF_TCString': 'CPxxRealConsentString'});

    await applyConsentToProviders(AdConsent.fullyAccepted);

    expect(alCalls, isNot(contains('setHasUserConsent')),
        reason: 'THE finding — AppLovin\'s own docs say MAX auto-reads a '
            'real TC string; an explicit call here was feeding it a '
            'purpose-only boolean with no vendor-consent basis for '
            'AppLovin');
  });

  test('no TCF string on device (no CMP at all) → setHasUserConsent IS '
      'still called, matching AppLovin\'s documented no-CMP path',
      () async {
    // Empty store — no TCF session has ever run on this device.
    await applyConsentToProviders(AdConsent.fullyAccepted);

    expect(alCalls, contains('setHasUserConsent'),
        reason: 'an app with no CMP at all must still be able to set the '
            'binary consent flag AppLovin\'s docs describe for that case '
            '— this path must not regress');
  });

  test('an empty TC string reads as absent — setHasUserConsent is still '
      'called (matches tcfConsentString\'s own "empty = no session" rule)',
      () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData({'IABTCF_TCString': ''});

    await applyConsentToProviders(AdConsent.fullyAccepted);

    expect(alCalls, contains('setHasUserConsent'));
  });

  test('setDoNotSell is called regardless of TC-string presence (CCPA is a '
      'different axis, no vendor-consent concept)', () async {
    SharedPreferencesAsyncPlatform.instance =
        InMemorySharedPreferencesAsync.withData(
            {'IABTCF_TCString': 'CPxxRealConsentString'});

    await applyConsentToProviders(const AdConsent(doNotSell: true));

    expect(alCalls, contains('setDoNotSell'),
        reason: 'CONTROL — CCPA opt-out must never be gated on GDPR/TCF '
            'string presence');
  });
}
