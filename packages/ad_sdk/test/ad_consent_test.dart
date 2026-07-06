import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
// Internal import: applyConsentToProviders is not part of the public API
// surface (only the AdConsent data class is exported) — this is the
// established pattern used by other tests in this suite to reach
// unexported internals directly. Same declaration as the public export
// above, so AdConsent is not ambiguous between the two imports.
import 'package:applovin_admob_sdk/src/core/ad_consent.dart';
import 'package:flutter/services.dart';
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
}
