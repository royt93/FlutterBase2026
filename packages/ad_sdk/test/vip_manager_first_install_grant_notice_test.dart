// First-install VIP grant notice: fires once when AdManager grants the
// first-install grace window (see AdManager.initialize()), until the host
// acknowledges it. Unlike the grace-period expiry nudge, this is a one-shot
// in-session signal — not persisted, since the underlying grant call is
// already guarded by AdPreferences.isFirstInstallGraceApplied().

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// In-memory fake so VIP tests don't hit the real (unavailable-in-test)
/// flutter_secure_storage platform channel.
class _FakeVipEntriesStore extends VipEntriesStore {
  _FakeVipEntriesStore(super.prefs);
  String? _raw;
  @override
  Future<String?> getRaw() async => _raw;
  @override
  Future<void> setRaw(String json) async => _raw = json;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;
  late VipManager mgr;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    mgr = VipManager(prefs, vipEntriesStore: _FakeVipEntriesStore(prefs));
    await mgr.load();
    addTearDown(mgr.dispose);
  });

  test('not due before any grant', () {
    expect(mgr.firstInstallGrantDueListenable.value, isFalse);
    expect(mgr.lastFirstInstallGrantDuration, isNull);
  });

  test('notifyFirstInstallGrant() flips the notifier and records duration', () {
    mgr.notifyFirstInstallGrant(const Duration(hours: 24));

    expect(mgr.firstInstallGrantDueListenable.value, isTrue);
    expect(mgr.lastFirstInstallGrantDuration, const Duration(hours: 24));
  });

  test('acknowledgeFirstInstallGrant() clears the notifier', () {
    mgr.notifyFirstInstallGrant(const Duration(hours: 24));
    expect(mgr.firstInstallGrantDueListenable.value, isTrue);

    mgr.acknowledgeFirstInstallGrant();

    expect(mgr.firstInstallGrantDueListenable.value, isFalse);
    // Duration stays readable after ack — only the "due" flag is cleared.
    expect(mgr.lastFirstInstallGrantDuration, const Duration(hours: 24));
  });

  test('a second grant re-fires the notice even without ack in between', () {
    mgr.notifyFirstInstallGrant(const Duration(seconds: 30));
    mgr.acknowledgeFirstInstallGrant();
    expect(mgr.firstInstallGrantDueListenable.value, isFalse);

    mgr.notifyFirstInstallGrant(const Duration(hours: 24));

    expect(mgr.firstInstallGrantDueListenable.value, isTrue);
    expect(mgr.lastFirstInstallGrantDuration, const Duration(hours: 24));
  });
}
