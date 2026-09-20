// T200 on-device integration test — AdManager().clearSdkData() against
// REAL SharedPreferences and REAL flutter_secure_storage (Android
// Keystore) on an actual device: a host app's own key survives every
// scope, an SDK key is gone after the default scope, and VIP entitlement
// secure storage is untouched unless the dangerous scope is explicitly
// confirmed.
//
// Run with:
//   flutter test integration_test/t200_clear_sdk_data_test.dart -d <device-or-sim-id>

import 'package:applovin_admob_sdk/applovin_admob_sdk.dart';
import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  const vipSecureKey = 'ad_sdk_vip_entries_v1';

  testWidgets(
      'host key survives every scope; a real SDK key is gone after the '
      'default scope; VIP secure storage untouched unless confirmed',
      (tester) async {
    final rawPrefs = await SharedPreferences.getInstance();
    await rawPrefs.setString('host_apps_own_key', 'do not touch me');

    final prefs = await AdPreferences.getInstance();
    await prefs.setConsentSettingsRaw('{"hasUserConsent":true}');

    const secure = FlutterSecureStorage();
    await secure.write(key: vipSecureKey, value: '[]');

    // Default scope: clears the non-entitlement SDK key, leaves the host
    // key AND the VIP secure-storage entry alone.
    await AdManager().clearSdkData();

    expect(rawPrefs.getString('host_apps_own_key'), 'do not touch me',
        reason: 'a host app key must never be touched, unlike '
            'clearAllData()');
    expect(prefs.getConsentSettingsRaw(), isNull,
        reason: 'a real SDK SharedPreferences key must actually be gone');
    expect(await secure.read(key: vipSecureKey), '[]',
        reason: 'VIP entitlement secure storage must survive the '
            'default scope untouched');

    // The dangerous scope, confirmed: now the VIP secure-storage entry
    // is really gone too, and the host key is STILL untouched.
    await AdManager().clearSdkData(
      scope: SdkDataErasureScope.allIncludingEntitlements,
      confirmedEntitlementErasure: true,
    );

    expect(await secure.read(key: vipSecureKey), isNull,
        reason: 'a confirmed allIncludingEntitlements call must erase '
            'the real Keychain/Keystore-backed VIP entry');
    expect(rawPrefs.getString('host_apps_own_key'), 'do not touch me',
        reason: 'the host key must still be untouched even at the '
            'dangerous scope');

    await secure.delete(key: vipSecureKey);
    await rawPrefs.remove('host_apps_own_key');
  });

  // Round 54 audit fix (MINOR) — same call, this time proving a LIVE
  // ProviderFailoverAdvisor's in-memory streak/circuit state is reset too,
  // against REAL SharedPreferences on-device — not just that the
  // underlying persisted keys are gone.
  testWidgets(
      'clearSdkData() resets a live, tripped ProviderFailoverAdvisor too, '
      'on a real device', (tester) async {
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
    await tester.pump();
    expect(advisor.shouldFailoverNextSession, isTrue,
        reason: 'sanity: tripped before erasure, on a real device');

    await AdManager().clearSdkData();
    await tester.pump();

    expect(advisor.shouldFailoverNextSession, isFalse,
        reason: 'a real erasure call must reset the live instance, not '
            'just the SharedPreferences keys underneath it');

    AdManager().disableProviderFailoverAdvisor();
  });
}
