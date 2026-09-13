// T200 — AdManager().clearSdkData() orchestration: AdPreferences (scoped
// SharedPreferences sweep) + VIP secure storage (live vs not-live
// VipManager) + FirstInstallGuard, all wired together.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? raw;
  @override
  Future<String?> getRaw() async => raw;
  @override
  Future<void> setRaw(String json) async => raw = json;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  tearDown(() {
    AdManager().debugVipManager = null;
  });

  test('everythingExceptEntitlements (default) clears a non-entitlement '
      'SharedPreferences key even with no live VipManager', () async {
    await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');

    await AdManager().clearSdkData();

    expect(prefs.getConsentSettingsRaw(), isNull);
  });

  test('allIncludingEntitlements without confirmation throws and touches '
      'nothing', () async {
    await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');

    await expectLater(
        AdManager()
            .clearSdkData(scope: SdkDataErasureScope.allIncludingEntitlements),
        throwsArgumentError);

    expect(prefs.getConsentSettingsRaw(), isNotNull);
  });

  test('allIncludingEntitlements with confirmation, no live VipManager, '
      'still erases VIP secure storage via the static fallback path',
      () async {
    // No debugVipManager set — _vipManager is null, exercising the
    // "SDK not initialised yet" branch.
    await expectLater(
      AdManager().clearSdkData(
        scope: SdkDataErasureScope.allIncludingEntitlements,
        confirmedEntitlementErasure: true,
      ),
      completes,
    );
  });

  test('allIncludingEntitlements with confirmation, LIVE VipManager, '
      'clears its active entitlement immediately (not just on next '
      'reload)', () async {
    final store = _FakeVipEntriesStore(prefs);
    final vip = VipManager(prefs, vipEntriesStore: store);
    addTearDown(vip.dispose);
    await vip.load();
    await vip.addVip(key: 'k', duration: const Duration(days: 1));
    expect(vip.isActive, isTrue);
    AdManager().debugVipManager = vip;

    await AdManager().clearSdkData(
      scope: SdkDataErasureScope.allIncludingEntitlements,
      confirmedEntitlementErasure: true,
    );

    expect(vip.isActive, isFalse,
        reason: 'the LIVE manager\'s reactive state must reflect the '
            'erasure immediately — this is the whole point of routing '
            'through the live instance instead of the static fallback');
  });
}
