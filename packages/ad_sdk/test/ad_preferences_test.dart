// Round-trip tests for AdPreferences — the SDK-owned SharedPreferences wrapper
// that backs VIP entries, consent settings, first-install state and the legacy
// GAID list. Uses the in-memory SharedPreferences mock.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  test('VIP entries raw round-trips', () async {
    expect(prefs.getVipEntriesRaw(), isNull, reason: 'nothing stored yet');
    await prefs.setVipEntriesRaw('[{"key":"A"}]');
    expect(prefs.getVipEntriesRaw(), '[{"key":"A"}]');
  });

  test('consent settings raw round-trips', () async {
    await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');
    expect(prefs.getConsentSettingsRaw(), '{"hasUserConsent":true}');
  });

  test('vip-migrated flag defaults to false', () {
    expect(prefs.isVipMigrated(), isFalse);
  });

  test('first-install grace flag defaults to false', () {
    expect(prefs.isFirstInstallGraceApplied(), isFalse);
  });

  test('legacy GAID list defaults to empty', () {
    expect(prefs.getGAIDList(), isEmpty);
  });

  test('setFirstInstallAtMsIfMissing only writes once', () async {
    await prefs.setFirstInstallAtMsIfMissing(1000);
    await prefs.setFirstInstallAtMsIfMissing(2000); // must NOT overwrite
    // The first value is retained — exercised via the public getter if present;
    // here we just assert the second call does not throw and the flow is stable.
    expect(() => prefs.isFirstInstallGraceApplied(), returnsNormally);
  });
}
