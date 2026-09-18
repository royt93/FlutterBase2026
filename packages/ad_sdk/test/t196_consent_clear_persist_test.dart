// T196 — ConsentSettings.copyWith's new clearAskedAt/clearCountry flags,
// exercised through the REAL persistence path (ConsentManager.set() →
// SharedPreferences → decode on a simulated "next app launch"), not just
// the bare data-class round-trip already covered in data_classes_test.dart.
// A cleared field must actually come back null on reload, not silently
// reappear because some layer in between re-derived it from the old value.

import 'package:applovin_admob_sdk/src/consent/consent_manager.dart';
import 'package:applovin_admob_sdk/src/consent/consent_settings.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
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

  test('clearing country/askedAt, persisting, then reloading (a fresh '
      'ConsentManager from the same prefs, simulating the next app '
      'launch) reads back null — not the old value quietly surviving '
      'the round trip', () async {
    final m = await ConsentManager.bootstrap(prefs: prefs);

    await m.set(ConsentSettings(
      hasUserConsent: true,
      hasBeenAsked: true,
      askedAt: DateTime.utc(2026, 1, 1),
      country: 'DE',
    ));
    // Sanity: it actually landed with both fields set before clearing.
    final beforeClear = ConsentSettings.decode(prefs.getConsentSettingsRaw());
    expect(beforeClear.askedAt, isNotNull);
    expect(beforeClear.country, 'DE');

    await m.set(m.current.copyWith(clearAskedAt: true, clearCountry: true));

    // Simulate the next app launch: a brand-new ConsentManager reading the
    // same underlying persisted state from scratch.
    ConsentManager.resetForTest();
    final reloaded = await ConsentManager.bootstrap(prefs: prefs);

    expect(reloaded.current.askedAt, isNull,
        reason: 'askedAt must not silently reappear on reload after '
            'being explicitly cleared and persisted');
    expect(reloaded.current.country, isNull,
        reason: 'country must not silently reappear on reload after '
            'being explicitly cleared and persisted');
    // Unrelated fields must have survived the clear + persist + reload
    // round trip untouched.
    expect(reloaded.current.hasUserConsent, isTrue);
    expect(reloaded.current.hasBeenAsked, isTrue);
  });
}
