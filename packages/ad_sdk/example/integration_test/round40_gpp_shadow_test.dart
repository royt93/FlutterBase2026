// On-device integration test for round-40 audit MAJOR (R40-A) —
// `IabStorage.usPrivacyOptedOut()` used to return the first *non-null* GPP
// signal in a fixed priority order, even when that signal was `false`,
// letting an earlier tier's stale/default "did not opt out" shadow a real
// opt-out sitting in a later tier. Fixed to let `true` win over `false`
// regardless of tier order.
//
// Unit coverage of the same fix (all fixtures, mocked store):
//   test/ad_manager_core_test.dart, "R40-A" tests
//
// Why on-device: `round37_gpp_privacy_test.dart`'s header already explains
// why the platform round-trip needs its own proof separate from the
// parsing math — this file reuses that same rationale for the cross-tier
// combination specifically.
//
// Run with:
//   flutter test integration_test/round40_gpp_shadow_test.dart -d <device-or-sim-id>

import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<SharedPreferencesAsync> _iabStore() async {
  if (Platform.isAndroid) {
    final pkg = (await PackageInfo.fromPlatform()).packageName;
    return SharedPreferencesAsync(
        options: IabStorage.androidOptionsFor('${pkg}_preferences'));
  }
  return SharedPreferencesAsync();
}

Future<void> _writeGpp(String key, String value) async {
  final store = await _iabStore();
  await store.setString(key, value);
  IabStorage.debugResetForTest();
}

Future<void> _clearAll(List<String> keys) async {
  final store = await _iabStore();
  for (final key in keys) {
    await store.remove(key);
  }
  IabStorage.debugResetForTest();
}

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  final allSectionKeys = [
    'IABUSPrivacy_String',
    for (var section = 7; section <= 27; section++) 'IABGPP_${section}_String',
  ];
  setUp(() => _clearAll(allSectionKeys));
  tearDown(() => _clearAll(allSectionKeys));

  testWidgets(
      'R40-A: a real California opt-out is not shadowed by GPP USNAT\'s '
      'explicit Did-Not-Opt-Out, on the real platform store', (tester) async {
    await _writeGpp('IABGPP_7_String', 'CAACAAAAAABA'); // USNAT: false
    await _writeGpp('IABGPP_8_String', 'BAQAAABA'); // California: true
    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'both fixtures really landed in the real platform '
            'preference store this device reads from, and California\'s '
            'real opt-out must survive USNAT\'s explicit "did not opt out"');
  });

  testWidgets(
      'R40-A: a real Colorado opt-out is not shadowed by Virginia\'s '
      'explicit Did-Not-Opt-Out, on the real platform store', (tester) async {
    await _writeGpp('IABGPP_9_String', 'BAoAABA'); // Virginia: false
    await _writeGpp('IABGPP_10_String', 'BAQAAEA'); // Colorado: true
    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'the within-states aggregation must also let a real '
            'opt-out survive another state\'s explicit "did not opt out", '
            'on the real platform store');
  });
}
