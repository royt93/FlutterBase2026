// Round-23 QC (reviewer C, MINOR) — a device on the host's own VIP GAID
// whitelist must not lose VIP after 90 days.
//
// `AdConfig.vipDeviceGaids` is how a host marks its internal/QA handsets as
// permanently ad-free. `_applyConfigVipGaidWhitelist` granted them a 50-year
// entry — except `VipManager` clamps every entry to
// `AdConfig.maxVipStackDuration` (~90 days), so what the device actually got
// was 90 days. And the routine was one-shot, gated on a
// `isAddVIPMemberFirstInitSuccess()` flag it set immediately afterwards, so
// when those 90 days ran out nothing ever granted again. The only way back was
// reinstalling the app.
//
// The fix re-grants once the window has actually run out. Nothing else changes:
// the device is still on the host's own whitelist, which is all the grant ever
// asserted in the first place.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

const _myGaid = 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee';

const _config = AdConfig(
  provider: AdProvider.admob,
  admob: AdMobConfig(
      bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
  // Deliberately upper-cased: the matcher is case-insensitive, and a host
  // pasting a GAID out of a console gets whichever case the console used.
  vipDeviceGaids: ['AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE'],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late VipManager vip;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    AdPreferences.resetForTest();
    prefs = await AdPreferences.getInstance();
    vip = VipManager(prefs, vipEntriesStore: _FakeVipEntriesStore(prefs));
    await vip.load();
    await vip.revokeAll();
    addTearDown(vip.dispose);
  });

  Future<void> apply({String gaid = _myGaid, AdConfig config = _config}) =>
      AdManager().debugApplyConfigVipGaidWhitelist(config, vip, prefs,
          deviceGaid: gaid);

  test('first init grants the whitelisted device and marks the flag', () async {
    await apply();

    expect(vip.isActive, isTrue);
    expect(prefs.isAddVIPMemberFirstInitSuccess(), isTrue);
  });

  test('CONTROL — a second init while still VIP grants nothing extra',
      () async {
    await apply();
    final entries = vip.entries.length;

    await apply();

    expect(vip.entries.length, entries,
        reason: 'the one-shot flag exists to stop re-granting on every single '
            'launch, and that part is still wanted');
  });

  test('once the clamped window has run out, the next init grants again',
      () async {
    await apply();
    expect(prefs.isAddVIPMemberFirstInitSuccess(), isTrue, reason: 'sanity');

    // What ~90 days later looks like: the clamped entry is over, the flag from
    // the first init is still set.
    await vip.revokeAll();
    expect(vip.isActive, isFalse, reason: 'sanity');

    await apply();

    expect(vip.isActive, isTrue,
        reason: 'THE finding: the flag made the 90-day clamp permanent, and '
            'the only way back for an internal device was a reinstall');
  });

  test('CONTROL — a device that is not on the list still gets nothing',
      () async {
    await apply(gaid: '11111111-2222-3333-4444-555555555555');

    expect(vip.isActive, isFalse);
    expect(prefs.isAddVIPMemberFirstInitSuccess(), isTrue,
        reason: 'the flag records "the list has been processed on this '
            'install", not "someone was granted"');
  });

  test('CONTROL — an empty whitelist is a no-op, flag included', () async {
    await apply(
        config: const AdConfig(
      provider: AdProvider.admob,
      admob: AdMobConfig(
          bannerId: 'b', interstitialId: 'i', appOpenId: 'ao', rewardedId: 'r'),
    ));

    expect(vip.isActive, isFalse);
    expect(prefs.isAddVIPMemberFirstInitSuccess(), isFalse);
  });

  // Round-37 QC (reviewer B, MAJOR) — `destroy()` mid-`await` disposes this
  // same `vip`; `addVip`'s own `_save()` already drops the write, but nothing
  // stopped the one-shot flag from being marked over a grant that never
  // landed — permanently hiding the whitelisted device from ever being
  // re-granted, since the flag is what gates the re-grant this file's own
  // fix exists for.
  test('a grant dropped by a disposed manager does not burn the flag',
      () async {
    vip.dispose();

    await apply();

    expect(prefs.isAddVIPMemberFirstInitSuccess(), isFalse,
        reason: 'THE finding — marking this flag over a dropped grant would '
            'permanently hide the whitelisted device from ever being '
            're-granted');
  });
}
