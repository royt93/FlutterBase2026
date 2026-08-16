// Unit tests for VipEntriesStore — the encrypted-at-rest (flutter_secure_
// storage) replacement for the old plaintext-SharedPreferences VIP entries
// blob, including its one-time migration from the legacy checksum-prefixed
// AdPreferences value.
//
// Mirrors redeemed_key_ledger_test.dart's structure: mocktail for the secure
// storage seam, a real (mock-SharedPreferences-backed) AdPreferences for the
// legacy side since that part is cheap and already the established pattern.

import 'dart:convert';

import 'package:applovin_admob_sdk/src/utils/ad_preferences.dart';
import 'package:applovin_admob_sdk/src/vip/_vip_entries_store.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

const _secureKey = 'ad_sdk_vip_entries_v1';
const _legacyKey = 'ad_sdk_vip_entries';

// Mirrors AdPreferences's private FNV-1a checksum exactly (there is no public
// setter left to produce a checksum-prefixed legacy value — the real one was
// removed along with getVipEntriesRaw/setVipEntriesRaw in this migration).
int _fnv1a(String s) {
  const prime = 0x01000193;
  var hash = 0x811c9dc5;
  for (final byte in utf8.encode(s)) {
    hash = ((hash ^ byte) * prime) & 0xFFFFFFFF;
  }
  return hash;
}

String _checksumPrefixed(String value) {
  final checksum = _fnv1a('$value|ad_sdk_vip_integrity_v1').toRadixString(16);
  return '$checksum|$value';
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AdPreferences prefs;

  setUp(() async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({});
    prefs = await AdPreferences.getInstance();
  });

  test('setRaw then getRaw round-trips, writing bare JSON with no checksum',
      () async {
    final storage = _MockSecureStorage();
    String? persisted;
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => persisted);
    when(() =>
            storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((invocation) async {
      persisted = invocation.namedArguments[#value] as String;
    });
    final store = VipEntriesStore(prefs, secureStorage: storage);

    await store.setRaw('[{"key":"A"}]');

    expect(await store.getRaw(), '[{"key":"A"}]');
    verify(() => storage.write(key: _secureKey, value: '[{"key":"A"}]'))
        .called(1);
  });

  test(
      'empty secure storage + migration already run returns null, never '
      'consults the legacy key', () async {
    await prefs.markVipEntriesSecureMigrated();
    final storage = _MockSecureStorage();
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => null);
    final store = VipEntriesStore(prefs, secureStorage: storage);

    expect(await store.getRaw(), isNull);
    verifyNever(() =>
        storage.write(key: any(named: 'key'), value: any(named: 'value')));
  });

  test(
      'checksum-valid legacy value migrates into secure storage and clears '
      'the legacy key', () async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({
      _legacyKey: _checksumPrefixed('[{"key":"LEGACY"}]'),
    });
    prefs = await AdPreferences.getInstance();
    final storage = _MockSecureStorage();
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => null);
    when(() =>
            storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((_) async {});
    final store = VipEntriesStore(prefs, secureStorage: storage);

    expect(await store.getRaw(), '[{"key":"LEGACY"}]');
    verify(() => storage.write(key: _secureKey, value: '[{"key":"LEGACY"}]'))
        .called(1);
    expect(prefs.getLegacyVipEntriesRawChecksumValidated(), isNull,
        reason: 'legacy value must be cleared once safely migrated');
  });

  test(
      'tampered legacy checksum returns null, sets the migration flag, but '
      'leaves the (unusable) legacy value alone', () async {
    // Same checksum as the valid "A" payload, but a swapped-in payload — the
    // checksum no longer matches, simulating direct SharedPreferences editing.
    final valid = _checksumPrefixed('[{"key":"A"}]');
    final checksum = valid.substring(0, valid.indexOf('|'));
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({
      _legacyKey: '$checksum|[{"key":"TAMPERED"}]',
    });
    prefs = await AdPreferences.getInstance();

    final storage = _MockSecureStorage();
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => null);
    final store = VipEntriesStore(prefs, secureStorage: storage);

    expect(await store.getRaw(), isNull);
    expect(prefs.isVipEntriesSecureMigrated(), isTrue,
        reason: 'must not re-attempt the migration on every launch');
    verifyNever(() =>
        storage.write(key: any(named: 'key'), value: any(named: 'value')));
    final rawPrefs = await SharedPreferences.getInstance();
    expect(rawPrefs.getString(_legacyKey), isNotNull,
        reason: 'nothing valid was migrated, so the legacy key is untouched');
  });

  test(
      'legacy bare JSON (pre-checksum era) is trusted once and migrated, '
      'same as a checksum-valid value', () async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({
      'ad_sdk_vip_entries': '[{"key":"OLD"}]',
    });
    prefs = await AdPreferences.getInstance();
    final storage = _MockSecureStorage();
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => null);
    when(() =>
            storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((_) async {});
    final store = VipEntriesStore(prefs, secureStorage: storage);

    expect(await store.getRaw(), '[{"key":"OLD"}]');
    verify(() => storage.write(key: _secureKey, value: '[{"key":"OLD"}]'))
        .called(1);
    expect(prefs.getLegacyVipEntriesRawChecksumValidated(), isNull,
        reason: 'legacy value must be cleared once safely migrated');
  });

  test('secure storage read() throwing fails open to null', () async {
    final storage = _MockSecureStorage();
    when(() => storage.read(key: any(named: 'key')))
        .thenThrow(StateError('keystore unavailable'));
    final store = VipEntriesStore(prefs, secureStorage: storage);

    expect(await store.getRaw(), isNull);
  });

  test('secure storage write() throwing during setRaw does not propagate',
      () async {
    final storage = _MockSecureStorage();
    when(() =>
            storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenThrow(StateError('keystore unavailable'));
    final store = VipEntriesStore(prefs, secureStorage: storage);

    await expectLater(store.setRaw('[{"key":"A"}]'), completes);
  });

  // T59 — a failed secure write must not be recorded as "migration done", or
  // the data is lost forever: the very next read short-circuits to "no VIP"
  // instead of retrying, even though nothing was ever actually persisted.
  test(
      'setRaw: secure write failure does NOT mark migrated, so a later '
      'successful retry can still persist the grant', () async {
    final storage = _MockSecureStorage();
    var shouldFail = true;
    String? persisted;
    when(() => storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenAnswer((invocation) async {
      if (shouldFail) throw StateError('keystore unavailable');
      persisted = invocation.namedArguments[#value] as String;
    });
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => persisted);
    final store = VipEntriesStore(prefs, secureStorage: storage);

    // Keystore broken on the device right now — the VIP grant that just
    // happened in memory (VipManager) can't be persisted this time.
    await store.setRaw('[{"key":"NEW_GRANT"}]');
    expect(prefs.isVipEntriesSecureMigrated(), isFalse,
        reason: 'the write never landed anywhere — marking migrated here '
            'would make the next getRaw() return null forever, even after '
            'Keystore recovers');

    // Keystore recovers (e.g. after a reboot) and the SDK retries the write
    // on the next VIP-relevant call.
    shouldFail = false;
    await store.setRaw('[{"key":"NEW_GRANT"}]');
    expect(await store.getRaw(), '[{"key":"NEW_GRANT"}]',
        reason: 'once the write actually succeeds, the grant must be '
            'readable back');
  });

  test(
      'getRaw migration: secure write failure does NOT mark migrated, '
      'leaving the legacy value in place for the next attempt', () async {
    AdPreferences.resetForTest();
    SharedPreferences.setMockInitialValues({
      _legacyKey: _checksumPrefixed('[{"key":"LEGACY"}]'),
    });
    prefs = await AdPreferences.getInstance();
    final storage = _MockSecureStorage();
    when(() => storage.read(key: any(named: 'key')))
        .thenAnswer((_) async => null);
    when(() =>
            storage.write(key: any(named: 'key'), value: any(named: 'value')))
        .thenThrow(StateError('keystore unavailable'));
    final store = VipEntriesStore(prefs, secureStorage: storage);

    expect(await store.getRaw(), '[{"key":"LEGACY"}]',
        reason: 'the in-memory value returned by THIS call is still correct');
    expect(prefs.isVipEntriesSecureMigrated(), isFalse,
        reason: 'the migration write failed — marking it done here strands '
            'the still-present legacy value unreachable on every future read');
    expect(prefs.getLegacyVipEntriesRawChecksumValidated(), isNotNull,
        reason: 'legacy value must survive a failed migration attempt');
  });

  // T71 — some devices (cheap/custom ROMs) have a permanently broken
  // Keystore: `_writeSecure` fails every time, not just transiently. Before
  // this fix, T59 correctly stopped that from being recorded as "migrated",
  // but there was still nowhere else to persist the grant at all — it only
  // ever lived in memory for the current app run.
  group('fallback storage (T71)', () {
    test(
        'setRaw: secure write fails repeatedly → grant still readable via '
        'fallback storage on a later getRaw()', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      when(() => storage.write(
              key: any(named: 'key'), value: any(named: 'value')))
          .thenThrow(StateError('keystore permanently unavailable'));
      final store = VipEntriesStore(prefs, secureStorage: storage);

      await store.setRaw('[{"key":"FALLBACK_GRANT"}]');

      // A fresh store instance (simulating the next app launch) must still
      // recover the grant, purely from AdPreferences fallback — secure
      // storage never had it and never will on this device.
      final relaunched = VipEntriesStore(prefs, secureStorage: storage);
      expect(await relaunched.getRaw(), '[{"key":"FALLBACK_GRANT"}]');
    });

    test(
        'fallback data is not marked as a completed secure migration '
        '(T59 invariant preserved)', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      when(() => storage.write(
              key: any(named: 'key'), value: any(named: 'value')))
          .thenThrow(StateError('keystore unavailable'));
      final store = VipEntriesStore(prefs, secureStorage: storage);

      await store.setRaw('[{"key":"A"}]');

      expect(prefs.isVipEntriesSecureMigrated(), isFalse,
          reason: 'must stay retriable — a fallback write is not a real '
              'secure-storage migration');
    });

    test(
        'once Keystore recovers, a successful secure write clears the '
        'stale fallback copy', () async {
      final storage = _MockSecureStorage();
      var shouldFail = true;
      String? persisted;
      when(() => storage.write(
              key: any(named: 'key'), value: any(named: 'value')))
          .thenAnswer((invocation) async {
        if (shouldFail) throw StateError('keystore unavailable');
        persisted = invocation.namedArguments[#value] as String;
      });
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => persisted);
      final store = VipEntriesStore(prefs, secureStorage: storage);

      await store.setRaw('[{"key":"OLD"}]'); // Keystore broken → fallback
      expect(prefs.getVipEntriesFallbackRaw(), isNotNull);

      shouldFail = false;
      await store.setRaw('[{"key":"NEW"}]'); // Keystore recovers

      expect(prefs.getVipEntriesFallbackRaw(), isNull,
          reason: 'a successful secure write must drop the now-stale '
              'fallback copy');
      expect(await store.getRaw(), '[{"key":"NEW"}]');
    });
  });
}
