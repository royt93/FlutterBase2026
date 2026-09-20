// T200 — AdManager().clearSdkData() orchestration: AdPreferences (scoped
// SharedPreferences sweep) + VIP secure storage (live vs not-live
// VipManager), wired together. Deliberately does NOT touch
// FirstInstallGuard's Keychain flag — see round 49's fix in
// ad_manager.dart's clearSdkData for why.

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_first_install_guard.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? raw;
  @override
  Future<String?> getRaw() async => raw;
  @override
  Future<void> setRaw(String json) async => raw = json;
}

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

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
    AdManager.debugFirstInstallGuardFactory = null;
    AdManager().disableProviderFailoverAdvisor();
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

  test(
      'allIncludingEntitlements does NOT erase the iOS FirstInstallGuard '
      'Keychain flag — round 49 regression: that flag exists to survive '
      'exactly this kind of local-data wipe', () async {
    final secureStorage = _MockSecureStorage();
    when(() => secureStorage.write(
          key: any(named: 'key'),
          value: any(named: 'value'),
        )).thenAnswer((_) async {});
    when(() => secureStorage.read(key: any(named: 'key')))
        .thenAnswer((_) async => 'true');
    when(() => secureStorage.delete(key: any(named: 'key')))
        .thenAnswer((_) async {});

    final guard = FirstInstallGuard(
      secureStorage: secureStorage,
      debugOverride: false,
      platformIsIos: () => true,
      platformIsAndroid: () => false,
    );
    AdManager.debugFirstInstallGuardFactory = () => guard;

    expect(await guard.hasAlreadyGranted(), isTrue,
        reason: 'sanity check: guard reports a prior grant before erasure');

    await AdManager().clearSdkData(
      scope: SdkDataErasureScope.allIncludingEntitlements,
      confirmedEntitlementErasure: true,
    );

    verifyNever(() => secureStorage.delete(key: any(named: 'key')));
    expect(await guard.hasAlreadyGranted(), isTrue,
        reason: 'the Keychain anti-farming flag must survive a '
            '"clear my data" request — only a real uninstall should be '
            'able to clear it, per the class doc comment');
  });

  // Round 54 audit fix (MINOR) — a live ProviderFailoverAdvisor's persisted
  // keys aren't entitlement keys, so the generic sweep above already
  // erases them at either scope. Without resetting the live instance's
  // in-memory copy too, its next AdEvent write-chain silently re-persists
  // the just-erased streak/circuit state right back.
  test(
      'clearSdkData() resets a live, tripped ProviderFailoverAdvisor '
      'in-memory too — an erasure request must not be silently undone by '
      'the advisor\'s next persist', () async {
    final advisor = ProviderFailoverAdvisor(consecutiveFailureThreshold: 2);
    AdManager().enableProviderFailoverAdvisor(advisor);
    await advisor.ready;

    AdManager().debugEmit(AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: false,
    ));
    AdManager().debugEmit(AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: false,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(advisor.shouldFailoverNextSession, isTrue,
        reason: 'sanity: circuit tripped before erasure');

    await AdManager().clearSdkData();

    expect(advisor.shouldFailoverNextSession, isFalse,
        reason: 'clearSdkData() must reset the live instance, not just the '
            'persisted keys — otherwise the next real ad-load event '
            'silently re-persists the pre-erasure streak');

    // The instance also must not resurrect the erased data on its own via
    // its next write.
    AdManager().debugEmit(AdLoadEvent(
      providerTag: '[AppLovin]',
      type: AdSlotType.interstitial,
      placement: AdPlacement.unspecified,
      success: true,
    ));
    await Future<void>.delayed(Duration.zero);
    expect(advisor.shouldFailoverNextSession, isFalse);
  });
}
