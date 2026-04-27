// Unit tests for FirstInstallGuard — the anti-uninstall-bypass guard.
//
// Anti-bypass is iOS-only by design — Android relies on the host app's
// Auto Backup configuration restoring `SharedPreferences` on Play Store
// reinstall, which short-circuits the outer
// `prefs.isFirstInstallGraceApplied()` flag before the guard ever runs.
//
// The guard depends on platform APIs (Keychain via flutter_secure_storage,
// Platform.isIOS/isAndroid, kDebugMode) that aren't reachable from the test
// environment, so the guard constructor exposes optional `*Override`
// parameters purely for these tests. Production callers use
// `FirstInstallGuard()` with no args.
//
// What's covered:
//   • Debug bypass (both methods short-circuit).
//   • iOS Keychain flag presence/absence/tampered/read-error.
//   • Android always allows grace (anti-bypass disabled by design).
//   • markGranted no-op on Android, write on iOS, idempotency, error swallow.
//   • Cross-platform fall-through (e.g. macOS host) returns false.
//   • clearForTest wipes the flag.

import 'package:applovin_admob_sdk/src/vip/_first_install_guard.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

class _MockSecureStorage extends Mock implements FlutterSecureStorage {}

void main() {
  // ────────────────────────────────────────────────────────────────────────
  // Helper: build a guard with sensible test defaults. Each test overrides
  // only what it needs.
  // ────────────────────────────────────────────────────────────────────────
  FirstInstallGuard buildGuard({
    FlutterSecureStorage? secureStorage,
    bool isDebug = false,
    bool isIos = false,
    bool isAndroid = false,
  }) {
    return FirstInstallGuard(
      secureStorage: secureStorage ?? _MockSecureStorage(),
      debugOverride: isDebug,
      platformIsIos: () => isIos,
      platformIsAndroid: () => isAndroid,
    );
  }

  // ────────────────────────────────────────────────────────────────────────
  // hasAlreadyGranted — debug bypass
  // ────────────────────────────────────────────────────────────────────────
  group('hasAlreadyGranted — debug bypass', () {
    test('returns false in debug mode (iOS path skipped)', () async {
      final storage = _MockSecureStorage();
      // Even if Keychain says "granted", debug bypass wins.
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'true');

      final guard = buildGuard(
        secureStorage: storage,
        isDebug: true,
        isIos: true,
      );

      expect(await guard.hasAlreadyGranted(), isFalse);
      verifyNever(() => storage.read(key: any(named: 'key')));
    });

    test('returns false in debug mode (Android path skipped)', () async {
      final guard = buildGuard(isDebug: true, isAndroid: true);
      expect(await guard.hasAlreadyGranted(), isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // hasAlreadyGranted — iOS Keychain
  // ────────────────────────────────────────────────────────────────────────
  group('hasAlreadyGranted — iOS Keychain flag', () {
    test('returns true when Keychain has the flag', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'true');

      final guard = buildGuard(secureStorage: storage, isIos: true);

      expect(await guard.hasAlreadyGranted(), isTrue);
    });

    test('returns false when Keychain is empty', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => null);

      final guard = buildGuard(secureStorage: storage, isIos: true);

      expect(await guard.hasAlreadyGranted(), isFalse);
    });

    test('returns false when Keychain has a different value', () async {
      final storage = _MockSecureStorage();
      // Tampered / corrupted value — anything other than 'true' fails open.
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'tampered');

      final guard = buildGuard(secureStorage: storage, isIos: true);

      expect(await guard.hasAlreadyGranted(), isFalse);
    });

    test('returns false when Keychain read throws (fail-open)', () async {
      final storage = _MockSecureStorage();
      when(() => storage.read(key: any(named: 'key')))
          .thenThrow(StateError('keychain locked'));

      final guard = buildGuard(secureStorage: storage, isIos: true);

      expect(await guard.hasAlreadyGranted(), isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // hasAlreadyGranted — Android (anti-bypass disabled by design)
  // ────────────────────────────────────────────────────────────────────────
  group('hasAlreadyGranted — Android', () {
    test(
        'always returns false (anti-bypass disabled — '
        'host app relies on Auto Backup)', () async {
      final storage = _MockSecureStorage();
      // Even if Keychain on Android somehow had the flag, Android path
      // returns false unconditionally.
      when(() => storage.read(key: any(named: 'key')))
          .thenAnswer((_) async => 'true');

      final guard = buildGuard(secureStorage: storage, isAndroid: true);

      expect(await guard.hasAlreadyGranted(), isFalse);
      // Android path doesn't touch storage — no read should happen.
      verifyNever(() => storage.read(key: any(named: 'key')));
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // hasAlreadyGranted — non-mobile fall-through
  // ────────────────────────────────────────────────────────────────────────
  group('hasAlreadyGranted — non-mobile platform', () {
    test('returns false when neither isIos nor isAndroid is true', () async {
      // e.g. tests running on macOS / Linux / Windows host.
      final guard = buildGuard();
      expect(await guard.hasAlreadyGranted(), isFalse);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // markGranted — write semantics
  // ────────────────────────────────────────────────────────────────────────
  group('markGranted', () {
    test('no-op in debug mode (no Keychain write)', () async {
      final storage = _MockSecureStorage();
      final guard =
          buildGuard(secureStorage: storage, isDebug: true, isIos: true);

      await guard.markGranted();

      verifyNever(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ));
    });

    test('no-op on Android (only iOS persists locally)', () async {
      final storage = _MockSecureStorage();
      final guard = buildGuard(secureStorage: storage, isAndroid: true);

      await guard.markGranted();

      verifyNever(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          ));
    });

    test('writes flag to Keychain on iOS', () async {
      final storage = _MockSecureStorage();
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenAnswer((_) async {});

      final guard = buildGuard(secureStorage: storage, isIos: true);

      await guard.markGranted();

      verify(() => storage.write(
            key: 'ad_sdk_first_install_granted_v1',
            value: 'true',
          )).called(1);
    });

    test('swallows exceptions on Keychain write failure (fail-open)',
        () async {
      final storage = _MockSecureStorage();
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenThrow(StateError('keychain unavailable'));

      final guard = buildGuard(secureStorage: storage, isIos: true);

      // Must not propagate — the grant flow should never break because
      // the anti-bypass marker couldn't be persisted.
      await expectLater(guard.markGranted(), completes);
    });

    test('idempotent — calling twice writes both times without error',
        () async {
      // The flag itself is a constant 'true' so two writes produce the
      // same end state. We just verify no error is thrown on a second call.
      final storage = _MockSecureStorage();
      when(() => storage.write(
            key: any(named: 'key'),
            value: any(named: 'value'),
          )).thenAnswer((_) async {});

      final guard = buildGuard(secureStorage: storage, isIos: true);

      await guard.markGranted();
      await guard.markGranted();

      verify(() => storage.write(
            key: 'ad_sdk_first_install_granted_v1',
            value: 'true',
          )).called(2);
    });
  });

  // ────────────────────────────────────────────────────────────────────────
  // clearForTest
  // ────────────────────────────────────────────────────────────────────────
  group('clearForTest', () {
    test('deletes the persisted flag', () async {
      final storage = _MockSecureStorage();
      when(() => storage.delete(key: any(named: 'key')))
          .thenAnswer((_) async {});

      final guard = buildGuard(secureStorage: storage);

      await guard.clearForTest();

      verify(() => storage.delete(key: 'ad_sdk_first_install_granted_v1'))
          .called(1);
    });

    test('swallows delete errors (best-effort cleanup)', () async {
      final storage = _MockSecureStorage();
      when(() => storage.delete(key: any(named: 'key')))
          .thenThrow(StateError('cannot delete'));

      final guard = buildGuard(secureStorage: storage);

      await expectLater(guard.clearForTest(), completes);
    });
  });
}
