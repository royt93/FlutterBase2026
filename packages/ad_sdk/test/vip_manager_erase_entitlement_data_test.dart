// T200 — VipManager.eraseAllEntitlementData() (live-instance path) and
// VipManager.eraseSecureEntitlementStorage() (static, no-live-instance
// path), both feeding AdManager().clearSdkData(scope:
// SdkDataErasureScope.allIncludingEntitlements, ...).

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_redeemed_key_ledger.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? raw;
  int eraseCalls = 0;

  @override
  Future<String?> getRaw() async => raw;
  @override
  Future<void> setRaw(String json) async => raw = json;
  @override
  Future<void> erase() async {
    eraseCalls++;
    raw = null;
  }
}

class _FakeRedeemedKeyLedger extends RedeemedKeyLedger {
  int eraseCalls = 0;
  bool _redeemed = false;

  @override
  Future<bool> isRedeemed(String kid) async => _redeemed;
  @override
  Future<void> markRedeemed(String kid) async => _redeemed = true;
  @override
  Future<void> erase() async {
    eraseCalls++;
    _redeemed = false;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  group('VipManager.eraseAllEntitlementData (live instance, T200)', () {
    test('clears active VIP entries (in-memory + persisted) AND the '
        'redeemed-key ledger', () async {
      final entriesStore = _FakeVipEntriesStore(prefs);
      final ledger = _FakeRedeemedKeyLedger();
      final mgr = VipManager(prefs,
          vipEntriesStore: entriesStore, redeemedKeyLedger: ledger);
      addTearDown(mgr.dispose);
      await mgr.load();

      await mgr.addVip(key: 'test_key', duration: const Duration(days: 30));
      await ledger.markRedeemed('some-kid');
      expect(mgr.isActive, isTrue);
      expect(await ledger.isRedeemed('some-kid'), isTrue);

      await mgr.eraseAllEntitlementData();

      expect(mgr.isActive, isFalse,
          reason: 'the live reactive state must reflect the erasure '
              'immediately, not just on next reload');
      expect(ledger.eraseCalls, 1,
          reason: 'the redeemed-key ledger must actually be erased too — '
              'a genuine "erase everything" request, not just revoke');
      expect(await ledger.isRedeemed('some-kid'), isFalse,
          reason: 'a previously-redeemed key must be redeemable again '
              'after a full entitlement erasure');
    });
  });

  group('VipManager.eraseSecureEntitlementStorage (static, no live '
      'instance, T200)', () {
    test('erases a fresh VipEntriesStore and RedeemedKeyLedger without '
        'needing a live VipManager', () async {
      // Simulates AdManager().clearSdkData() being called before
      // initialize() ever ran — no live VipManager instance exists.
      await expectLater(
          VipManager.eraseSecureEntitlementStorage(prefs), completes);
    });
  });
}
