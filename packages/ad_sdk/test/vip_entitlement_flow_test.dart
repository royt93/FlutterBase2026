// Integration-style test for the VIP entitlement subsystem.
//
// Unlike the pure-unit tests (vip_entry_test), this wires REAL collaborators
// together — VipManager + AdPreferences + SharedPreferences persistence + the
// reactive `activeListenable`/`activeStream` — and exercises the end-to-end
// entitlement lifecycle the host app depends on:
//
//   redeem → active (reactive notify) → persist → reload from "disk" →
//   conflict (latest-expiry-wins) → expire/purge on load → revoke.
//
// It runs under `flutter test` (no device needed) because every dependency is
// real except the SharedPreferences backing store, which is mocked in-memory.

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/vip_entry.dart';
import 'package:applovin_admob_sdk/src/vip/vip_manager.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
    // Shared singleton store → wipe persisted entries for a clean slate.
    await VipManager(prefs).revokeAll();
  });

  test('redeem activates entitlement and fires the reactive notifier',
      () async {
    final mgr = VipManager(prefs);
    await mgr.load();
    expect(mgr.isActive, isFalse);

    final transitions = <bool>[];
    mgr.activeListenable.addListener(() => transitions.add(mgr.isActive));

    await mgr.addVip(key: 'KEY_30D', duration: const Duration(days: 30));

    expect(mgr.isActive, isTrue);
    expect(transitions, [true], reason: 'notifier fires exactly once false→true');
    addTearDown(() => mgr.dispose());
  });

  test('entitlement survives a reload from persistence', () async {
    final writer = VipManager(prefs);
    await writer.load();
    await writer.addVip(key: 'KEY_PERSIST', duration: const Duration(hours: 1));
    expect(writer.isActive, isTrue);

    // Fresh manager reading the SAME backing store = app relaunch.
    final reader = VipManager(prefs);
    await reader.load();
    expect(reader.isActive, isTrue,
        reason: 'persisted entry must restore active state across instances');
  });

  test('latest-expiry-wins when the same key is redeemed twice', () async {
    final mgr = VipManager(prefs);
    await mgr.load();

    await mgr.addVip(key: 'DUP', duration: const Duration(hours: 1));
    await mgr.addVip(key: 'DUP', duration: const Duration(hours: 5)); // later
    await mgr.addVip(key: 'DUP', duration: const Duration(minutes: 10)); // earlier

    // Reload to inspect what actually persisted.
    final reader = VipManager(prefs);
    await reader.load();
    final expiry = reader.expiresAt;
    expect(expiry, isNotNull);
    final remaining = expiry!.difference(DateTime.now());
    expect(remaining.inMinutes, greaterThan(60),
        reason: 'the 5h grant must win over both the 1h and 10m grants');
    expect(remaining.inMinutes, lessThan(5 * 60 + 1));
  });

  test('expired entries are purged on load and do not grant access', () async {
    // Inject a stale entry straight into the backing store (past expiry).
    final expired = VipEntry(
      key: 'STALE',
      expiresAt: DateTime.now().subtract(const Duration(days: 1)),
      grantedAt: DateTime.now().subtract(const Duration(days: 31)),
    );
    final fresh = VipEntry(
      key: 'LIVE',
      expiresAt: DateTime.now().add(const Duration(days: 1)),
      grantedAt: DateTime.now(),
    );
    await prefs.setVipEntriesRaw(VipEntry.encodeList([expired, fresh]));

    final mgr = VipManager(prefs);
    await mgr.load();

    // Still active because of LIVE, but STALE must be gone after purge.
    expect(mgr.isActive, isTrue);
    final reader = VipManager(prefs);
    await reader.load();
    expect(reader.isActive, isTrue);
    // Revoking LIVE should leave nothing active (STALE was already purged).
    await reader.revokeVip('LIVE');
    expect(reader.isActive, isFalse);
  });

  test('revokeAll clears entitlement and notifies', () async {
    final mgr = VipManager(prefs);
    await mgr.load();
    await mgr.addVip(key: 'KEY_A', duration: const Duration(days: 1));
    expect(mgr.isActive, isTrue);

    await mgr.revokeAll();
    expect(mgr.isActive, isFalse);

    final reader = VipManager(prefs);
    await reader.load();
    expect(reader.isActive, isFalse, reason: 'revokeAll must persist the wipe');
  });
}
