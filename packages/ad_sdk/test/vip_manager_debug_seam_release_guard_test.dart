// Round-71 audit fix (MAJOR, gemini reviewer) — `VipManager.
// clearRedeemedKeyLedgerForTest` was `@visibleForTesting` only (an
// analyzer lint, not a runtime guard), same gap rounds 68-70 fixed
// elsewhere on `AdManager`/adapters/`AdSafetyConfig`/`IabStorage`. Any code
// in a shipped release app could wipe the Keychain-backed one-time-use
// ledger and redeem an already-spent signed VIP key again on the same
// device — a full bypass of the offline anti-replay guarantee.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_redeemed_key_ledger.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    RedeemedKeyLedger.resetWriteChainForTest();
  });

  test(
      'clearRedeemedKeyLedgerForTest is ignored when isRelease is true',
      () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _MockSecureStorage();
    final ledger = RedeemedKeyLedger(
      secureStorage: storage,
      platformIsIos: () => true,
    );
    final vip = VipManager(prefs, redeemedKeyLedger: ledger, isRelease: true);
    addTearDown(vip.dispose);

    await vip.clearRedeemedKeyLedgerForTest();

    verifyNever(() => storage.delete(key: any(named: 'key')));
  });

  test('clearRedeemedKeyLedgerForTest still erases when not released',
      () async {
    final prefs = await AdPreferences.getInstance();
    final storage = _MockSecureStorage();
    when(() => storage.delete(key: any(named: 'key')))
        .thenAnswer((_) async {});
    final ledger = RedeemedKeyLedger(
      secureStorage: storage,
      platformIsIos: () => true,
    );
    final vip =
        VipManager(prefs, redeemedKeyLedger: ledger, isRelease: false);
    addTearDown(vip.dispose);

    await vip.clearRedeemedKeyLedgerForTest();

    verify(() => storage.delete(key: any(named: 'key'))).called(1);
  });
}
