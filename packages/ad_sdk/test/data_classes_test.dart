// Unit tests for the small public value objects: ConsentSettings,
// FirstInstallVipGrace, UmpConsentResult, and the AdConfig provider/config
// invariant. These are pure and partner-facing.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ConsentSettings', () {
    test('defaults are the conservative (no consent) state', () {
      const s = ConsentSettings();
      expect(s.hasUserConsent, isFalse);
      expect(s.isAgeRestrictedUser, isFalse);
      expect(s.doNotSell, isFalse);
      expect(s.hasBeenAsked, isFalse);
    });

    test('copyWith overrides only the given fields', () {
      const s = ConsentSettings();
      final s2 = s.copyWith(hasUserConsent: true, hasBeenAsked: true);
      expect(s2.hasUserConsent, isTrue);
      expect(s2.hasBeenAsked, isTrue);
      expect(s2.doNotSell, isFalse, reason: 'untouched field preserved');
    });

    test('toAdConsent projects the GDPR/COPPA/CCPA flags', () {
      const s = ConsentSettings(
        hasUserConsent: true,
        isAgeRestrictedUser: true,
        doNotSell: true,
      );
      final c = s.toAdConsent();
      expect(c.hasUserConsent, isTrue);
      expect(c.isAgeRestrictedUser, isTrue);
      expect(c.doNotSell, isTrue);
    });

    test('country defaults to null and survives copyWith/toJson/fromJson', () {
      const s = ConsentSettings();
      expect(s.country, isNull);

      final withCountry = s.copyWith(country: 'DE');
      expect(withCountry.country, 'DE');

      final json = withCountry.toJson();
      expect(json['country'], 'DE');
      expect(ConsentSettings.fromJson(json).country, 'DE');

      final noCountryJson = s.toJson();
      expect(noCountryJson['country'], isNull);
      expect(ConsentSettings.fromJson(noCountryJson).country, isNull);
    });
  });

  group('FirstInstallVipGrace', () {
    test('disabled is not enabled', () {
      expect(FirstInstallVipGrace.disabled.isEnabled, isFalse);
      expect(FirstInstallVipGrace.disabled.duration, isNull);
    });

    test('a positive duration is enabled', () {
      expect(FirstInstallVipGrace.day.isEnabled, isTrue);
      expect(FirstInstallVipGrace.day.duration, const Duration(days: 1));
      expect(FirstInstallVipGrace.debugShort.duration,
          const Duration(seconds: 30));
    });

    test('zero / null duration is not enabled', () {
      expect(const FirstInstallVipGrace(Duration.zero).isEnabled, isFalse);
      expect(const FirstInstallVipGrace(null).isEnabled, isFalse);
    });

    test('toString includes the duration', () {
      expect(FirstInstallVipGrace.disabled.toString(),
          'FirstInstallVipGrace(null)');
    });
  });

  group('UmpConsentResult', () {
    test('obtained status sets isObtained', () {
      const r = UmpConsentResult(
        canRequestAds: true,
        status: ConsentStatus.obtained,
      );
      expect(r.isObtained, isTrue);
      expect(r.isRequired, isFalse);
      expect(r.isNotRequired, isFalse);
      expect(r.canRequestAds, isTrue);
      expect(r.formShown, isFalse, reason: 'default');
    });

    test('required status sets isRequired', () {
      const r = UmpConsentResult(
        canRequestAds: false,
        status: ConsentStatus.required,
      );
      expect(r.isRequired, isTrue);
      expect(r.isObtained, isFalse);
    });

    test('notRequired status sets isNotRequired', () {
      const r = UmpConsentResult(
        canRequestAds: true,
        status: ConsentStatus.notRequired,
        formShown: false,
      );
      expect(r.isNotRequired, isTrue);
    });
  });

  group('AdConfig provider/config invariant', () {
    test('appLovin provider with a non-null AppLovinConfig is valid', () {
      expect(
        () => const AdConfig(
          provider: AdProvider.appLovin,
          appLovin: AppLovinConfig(
            sdkKey: 'k',
            bannerId: 'b',
            interstitialId: 'i',
            appOpenId: 'a',
            rewardedId: 'r',
          ),
        ),
        returnsNormally,
      );
    });

    test('appLovin provider WITHOUT an AppLovinConfig fails the assert', () {
      expect(
        () => AdConfig(provider: AdProvider.appLovin),
        throwsA(isA<AssertionError>()),
      );
    });

    test('admob provider WITHOUT an AdMobConfig fails the assert', () {
      expect(
        () => AdConfig(provider: AdProvider.admob),
        throwsA(isA<AssertionError>()),
      );
    });
  });
}
