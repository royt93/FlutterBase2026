// On-device integration test for round-37 audit — GPP US-privacy sections.
//
// Why on-device: `IabStorage` reads GPP section strings out of the PLATFORM's
// own preference store (the Android default `<packageName>_preferences` file,
// unprefixed keys on iOS) — the same plumbing `us_privacy_propagation_test.dart`
// proved was silently broken once before (MJ2/m10). A mocked store proves the
// bit-parsing logic; only a device proves a CMP's real write actually reaches
// this SDK's reader. Full bit-layout coverage for all 21 GPP sections (US
// National + California + 19 other states) lives in
// `test/ad_manager_core_test.dart` (40 fixtures from the official
// `@iabgpp/cmpapi` reference encoder) — this file only samples one section per
// distinct code path (US National, California, one "shared decoder" state) to
// prove the platform round-trip, not the parsing math again.
//
// Run with:
//   flutter test integration_test/round37_gpp_privacy_test.dart -d <device-or-sim-id>

import 'dart:io';

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/core/iab_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Opens the very store a CMP writes to — the same one [IabStorage] reads.
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

  const usNationalKey = 'IABGPP_7_String';
  const californiaKey = 'IABGPP_8_String';
  const virginiaKey = 'IABGPP_9_String'; // representative of the 19-state
  // shared decoder (SaleOptOut immediately followed by
  // TargetedAdvertisingOptOut, no SharingOptOut field).

  // Independent review (round 37 verification, MINOR) — a real device's
  // preference store persists across app runs. A leftover real-CMP write,
  // or a stray section this fixture set doesn't cover (sections 10-27, or
  // the legacy `IABUSPrivacy_String` key `usPrivacyOptedOut` checks BEFORE
  // any GPP section — see its priority chain), can override what a given
  // test thinks it just wrote, or make the CONTROL's "must stay null"
  // expectation fail for a reason that has nothing to do with this SDK's
  // logic. Clear the full 7-27 range plus the legacy key before AND after
  // every test, not just the 3 sections these fixtures target.
  final allSectionKeys = [
    'IABUSPrivacy_String',
    for (var section = 7; section <= 27; section++) 'IABGPP_${section}_String',
  ];
  setUp(() => _clearAll(allSectionKeys));
  tearDown(() => _clearAll(allSectionKeys));

  testWidgets(
      'GPP US National: TargetedAdvertisingOptOut=Opted-Out alone is read '
      'off the real platform store', (tester) async {
    // Fixture: `node -e "const {UsNatCoreSegment}=require('@iabgpp/cmpapi');
    //   const s=new UsNatCoreSegment();
    //   s.setFieldValue('TargetedAdvertisingOptOut',1);
    //   console.log(s.encode());"`
    await _writeGpp(usNationalKey, 'CAABAAAAAABA');
    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'the fixture really landed in the real platform preference '
            'store this device reads from, and TargetedAdvertisingOptOut '
            'alone (Sale/Sharing left Not-Applicable) must be enough');
  });

  testWidgets(
      'GPP California: SaleOptOut=Opted-Out is read off the real platform '
      'store (no US National section present)', (tester) async {
    // Fixture: `node -e "const {UsCaCoreSegment}=require('@iabgpp/cmpapi');
    //   const s=new UsCaCoreSegment(); s.setFieldValue('SaleOptOut',1);
    //   console.log(s.encode());"`
    await _writeGpp(californiaKey, 'BAQAAABA');
    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'California must be consulted when US National is absent, '
            'through the real platform store');
  });

  testWidgets(
      'GPP Virginia (representative of the 19 shared-decoder states): '
      'SaleOptOut=Opted-Out is read off the real platform store', (tester) async {
    // Fixture: `node -e "const {UsVaCoreSegment}=require('@iabgpp/cmpapi');
    //   const s=new UsVaCoreSegment(); s.setFieldValue('SaleOptOut',1);
    //   console.log(s.encode());"`
    await _writeGpp(virginiaKey, 'BAQAABA');
    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'a state section reachable only through the shared 19-state '
            'decoder must round-trip through the real platform store too');
  });

  // Round 56 audit fix — real CMPs default to including the optional GPC
  // sub-segment, making the real platform-stored string
  // `CoreSegment.GpcSegment`, not the single-segment fixtures above. Proves
  // the fix (splitting on `.` before bit-decoding) holds through the real
  // platform preference store, not just the mocked unit test.
  testWidgets(
      'GPP US National: a real two-segment string (CoreSegment.GpcSegment) '
      'still decodes the opt-out signal off the real platform store',
      (tester) async {
    // Fixture: `node -e "const {UsNat}=require('@iabgpp/cmpapi');
    //   const u=new UsNat();
    //   u.setFieldValue('Version',1);
    //   u.setFieldValue('SharingNotice',1);
    //   u.setFieldValue('SaleOptOutNotice',1);
    //   u.setFieldValue('SharingOptOutNotice',1);
    //   u.setFieldValue('TargetedAdvertisingOptOutNotice',1);
    //   u.setFieldValue('SensitiveDataProcessingOptOutNotice',0);
    //   u.setFieldValue('SensitiveDataLimitUseNotice',0);
    //   u.setFieldValue('SaleOptOut',2);
    //   u.setFieldValue('SharingOptOut',2);
    //   u.setFieldValue('TargetedAdvertisingOptOut',1);
    //   u.setFieldValue('SensitiveDataProcessing',new Array(12).fill(0));
    //   u.setFieldValue('KnownChildSensitiveDataConsents',[0,0]);
    //   u.setFieldValue('PersonalDataConsents',0);
    //   u.setFieldValue('MspaCoveredTransaction',1);
    //   u.setFieldValue('MspaOptOutOptionMode',1);
    //   u.setFieldValue('MspaServiceProviderMode',0);
    //   u.setFieldValue('Gpc',true);
    //   console.log(u.encode());"` → 'BVQpAAAAAUA.YA'
    await _writeGpp(usNationalKey, 'BVQpAAAAAUA.YA');
    expect(await AdManager().usPrivacyOptedOut, isTrue,
        reason: 'a real two-segment GPP string on the real platform store '
            'must not be silently discarded as "no signal" — this is the '
            'common case from a standards-compliant CMP, not an edge case');
  });

  // CONTROL — the failure mode of an over-eager fix here is a revenue loss
  // for every US user in that state, so the negative direction is pinned on
  // the device too.
  testWidgets(
      'CONTROL — GPP California both opt-outs Not-Applicable stays null on '
      'the real platform store', (tester) async {
    // Fixture: `new UsCaCoreSegment().encode()` with no fields set.
    await _writeGpp(californiaKey, 'BAAAAABA');
    expect(await AdManager().usPrivacyOptedOut, isNull,
        reason: 'an all-Not-Applicable California section must not be read '
            'as an opt-out on a real device any more than in the mocked '
            'unit tests');
  });
}
