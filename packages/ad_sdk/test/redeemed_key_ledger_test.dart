// Unit tests for RedeemedKeyLedger — the durable (iOS Keychain) backstop
// against signed-VIP-key replay via uninstall + reinstall.
//
// Mirrors first_install_guard_test.dart's structure: the ledger depends on
// platform APIs unreachable from the test environment, so its constructor
// exposes `*Override` params purely for tests.

import 'package:applovin_admob_sdk/src/vip/_redeemed_key_ledger.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  RedeemedKeyLedger buildLedger({
    FlutterSecureStorage? secureStorage,
    bool isIos = false,
  }) {
    return RedeemedKeyLedger(
      secureStorage: secureStorage ?? _MockSecureStorage(),
      platformIsIos: () => isIos,
    );
  }

  group('isRedeemed — non-iOS', () {
    test('always false, never touches storage', () async {
      final storage = _MockSecureStorage();
      final ledger = buildLedger(secureStorage: storage, isIos: false);

      expect(await ledger.isRedeemed('kid1'), isFalse);
      verifyNever(() => storage.read(key: any(named: 'key')));
    });
  });

  group('isRedeemed — iOS', () {
    test('false when Keychain empty', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      expect(await ledger.isRedeemed('kid1'), isFalse);
    });

    test('true when kid present in persisted list', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => '["kid1","kid2"]');
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      expect(await ledger.isRedeemed('kid2'), isTrue);
      expect(await ledger.isRedeemed('kid3'), isFalse);
    });

    test('false when Keychain read throws (fail-open)', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenThrow(StateError('keychain locked'));
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      expect(await ledger.isRedeemed('kid1'), isFalse);
    });

    test('false when persisted value is corrupt JSON (fail-open)', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'not-json{{{');
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      expect(await ledger.isRedeemed('kid1'), isFalse);
    });
  });

  group('markRedeemed — non-iOS', () {
    test('no-op, never writes', () async {
      final storage = _MockSecureStorage();
      final ledger = buildLedger(secureStorage: storage, isIos: false);

      await ledger.markRedeemed('kid1');

      verifyNever(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ));
    });
  });

  group('markRedeemed — iOS', () {
    test('persists a new kid into an empty ledger', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenAnswer((_) async {});
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      await ledger.markRedeemed('kid1');

      verify(() => storage.write(
            key: 'ad_sdk_redeemed_vip_kids_v1',
            value: '["kid1"]',
          )).called(1);
    });

    test('appends onto an existing ledger without dropping prior kids',
        () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => '["kid1"]');
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenAnswer((_) async {});
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      await ledger.markRedeemed('kid2');

      verify(() => storage.write(
            key: 'ad_sdk_redeemed_vip_kids_v1',
            value: any(
                named: 'value',
                that: predicate<String>(
                    (v) => v.contains('kid1') && v.contains('kid2'))),
          )).called(1);
    });

    test('swallows write errors (fail-open)', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenThrow(StateError('keychain unavailable'));
      final ledger = buildLedger(secureStorage: storage, isIos: true);

      await expectLater(ledger.markRedeemed('kid1'), completes);
    });
  });

  group('reinstall-evasion — durable marker survives a simulated reinstall',
      () {
    test(
        'kid marked redeemed on iOS is still reported redeemed by a fresh '
        'ledger instance pointed at the same Keychain backend', () async {
      final storage = _MockSecureStorage();
      String? persisted;
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => persisted);
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenAnswer((invocation) async {
        persisted = invocation.namedArguments[#value] as String;
      });

      final firstInstall = buildLedger(secureStorage: storage, isIos: true);
      await firstInstall.markRedeemed('replayed-kid');

      // "Reinstall": a brand-new ledger instance, but the Keychain-backed
      // storage (unlike SharedPreferences) survives — same mock backend.
      final afterReinstall = buildLedger(secureStorage: storage, isIos: true);
      expect(await afterReinstall.isRedeemed('replayed-kid'), isTrue);
    });
  });

  group('clearForTest', () {
    test('deletes the persisted ledger', () async {
      final storage = _MockSecureStorage();
      when(() => storage.delete(key: any(named: 'key')))
          .thenAnswer((_) async {});
      final ledger = buildLedger(secureStorage: storage);

      await ledger.clearForTest();

      verify(() => storage.delete(key: 'ad_sdk_redeemed_vip_kids_v1'))
          .called(1);
    });
  });
}
