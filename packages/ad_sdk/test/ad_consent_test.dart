import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:flutter_test/flutter_test.dart';

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
}
