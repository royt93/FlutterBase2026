import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/safe_logger.dart';

/// Anti-uninstall-bypass guard for the first-install VIP grace.
///
/// Without this guard, the grace flag (`AdPreferences._keyFirstInstallApplied`)
/// lives only in `SharedPreferences`, which is wiped on uninstall. A user
/// could uninstall + reinstall in a loop to keep getting the 24-hour grace —
/// effectively gaming the "ad-free first install" feature.
///
/// **Per-platform behaviour:**
///
///   • **iOS — Keychain "already-granted" flag** (`flutter_secure_storage`)
///     stored with `kSecAttrAccessibleAfterFirstUnlock`. Keychain items
///     persist across uninstall on iOS by default, so a reinstall on the
///     same device finds the flag and the guard skips re-granting.
///
///     We deliberately do NOT use `identifierForVendor` (IDFV) as part of
///     the persisted token — Apple resets IDFV when the user deletes all
///     of a vendor's apps and reinstalls, which would let a standalone-app
///     reinstall silently bypass the guard.
///
///   • **Android — anti-bypass intentionally disabled.** The host app
///     accepts that uninstall + reinstall on Android grants a fresh 24 h
///     grace window. Android has no reliable local-only signal that
///     survives uninstall (Keychain/EncryptedSharedPreferences wipe with
///     the app, ANDROID_ID needs companion storage), and Play Install
///     Referrer alone cannot distinguish a fresh install from a reinstall.
///     Rather than pull in a plugin (`play_install_referrer`) that adds
///     startup overhead and a small crash surface for zero anti-bypass
///     benefit, we simply allow grace on every Android first-init.
///
/// **Bypass-result matrix:**
///
/// | Attempt                                      | iOS                        | Android                    |
/// |----------------------------------------------|----------------------------|----------------------------|
/// | Uninstall + reinstall (same device)          | block (Keychain flag)      | bypass (intentional, fail-open) |
/// | Single-app-per-vendor + IDFV reset           | block (we don't use IDFV)  | n/a                        |
/// | "Erase All Content and Settings"             | bypass (Keychain wiped)    | bypass                     |
///
/// **Debug builds**: the guard auto-bypasses in `kDebugMode` so QA can
/// iterate on `flutter run` without being locked out of the grace UX.
/// To validate iOS anti-bypass, build a signed release variant and test
/// on TestFlight or via Xcode device install.
///
/// The guard never throws to callers; any internal error degrades to
/// "allow grace" (false negative on bypass) so legitimate first-time users
/// are never falsely denied.
class FirstInstallGuard {
  /// All `*Override` parameters exist solely for unit tests — production
  /// callers should use `FirstInstallGuard()` with no args, which wires
  /// the real storage / platform via the package-private defaults below.
  FirstInstallGuard({
    FlutterSecureStorage? secureStorage,
    bool? debugOverride,
    bool Function()? platformIsIos,
    bool Function()? platformIsAndroid,
  })  : _secure = secureStorage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              // flutter_secure_storage 10.x deprecated `encryptedSharedPreferences`
              // (Jetpack Security retired); data auto-migrates to custom ciphers.
              aOptions: AndroidOptions(),
            ),
        _isDebug = debugOverride ?? kDebugMode,
        _platformIsIos = platformIsIos ?? _defaultIsIos,
        _platformIsAndroid = platformIsAndroid ?? _defaultIsAndroid;

  static bool _defaultIsIos() => Platform.isIOS;
  static bool _defaultIsAndroid() => Platform.isAndroid;

  static const String _tag = 'FirstInstallGuard';

  /// Keychain key for the iOS "already granted" flag. Versioned so a
  /// future SDK can rotate the namespace by bumping `:vN` if needed
  /// (which would treat every device as a fresh first-install again —
  /// only do that if the storage scheme itself is broken).
  static const String _grantedFlagKey = 'ad_sdk_first_install_granted_v1';
  static const String _grantedFlagValue = 'true';

  final FlutterSecureStorage _secure;
  final bool _isDebug;
  final bool Function() _platformIsIos;
  final bool Function() _platformIsAndroid;

  /// True if grace has previously been granted on this device, i.e. the
  /// caller should **skip** granting it again.
  ///
  /// Returns `false` on any error so legitimate first-time users still get
  /// their grace (we'd rather miss a bypass than punish a real user).
  ///
  /// **Debug builds always return `false`** so QA can iterate on
  /// `flutter run` without being locked out of the grace UX.
  ///
  /// **Android always returns `false`** — anti-bypass is iOS-only by
  /// design.
  Future<bool> hasAlreadyGranted() async {
    if (_isDebug) {
      SafeLogger.d(_tag,
          '⏭️ debug build — anti-bypass guard bypassed (test on release builds)');
      return false;
    }

    if (_platformIsIos()) {
      return _checkIosKeychainFlag();
    }
    if (_platformIsAndroid()) {
      // Anti-bypass intentionally disabled on Android. The host app
      // accepts uninstall + reinstall as a way to receive a fresh 24 h
      // grace window. See class doc comment for rationale.
      SafeLogger.d(_tag,
          '⏭️ Android — anti-bypass disabled by design, allow grace');
      return false;
    }
    // Other platforms (web, desktop) — anti-bypass is mobile-only.
    return false;
  }

  /// Persist the "already granted" flag so future inits (after a
  /// reinstall on iOS) can detect the bypass.
  ///
  /// Idempotent: calling twice is a no-op.
  /// Errors are swallowed (logged as warnings) — we never want a storage
  /// failure to break the grace grant flow.
  ///
  /// **No-op on Android.** Anti-bypass is iOS-only by design (see
  /// [hasAlreadyGranted]).
  ///
  /// **Debug builds skip the write entirely**, mirroring the
  /// [hasAlreadyGranted] bypass. Otherwise a debug session's flag would
  /// persist into a subsequent release install on the same device
  /// (Keychain on iOS), denying grace to QA the first time they switch
  /// from `flutter run` debug to a signed release build.
  ///
  /// **Call-order requirement**: `AdManager` must call this BEFORE
  /// `prefs.markFirstInstallGraceApplied()` (and after `vip.addVip()`).
  /// The Keychain write is the load-bearing anti-bypass primitive — if a
  /// force-kill happens between the two writes, leaving Keychain set but
  /// prefs flag unset is the safe state (next init re-runs the guard,
  /// finds the Keychain flag, and correctly skips re-granting).
  ///
  /// The reverse order would leave a window where prefs flag is set but
  /// the Keychain flag is not — uninstall + reinstall during that
  /// microsecond would bypass the guard.
  Future<void> markGranted() async {
    if (_isDebug) {
      SafeLogger.d(_tag,
          '⏭️ debug build — Keychain flag write skipped (avoid polluting release)');
      return;
    }
    if (!_platformIsIos()) {
      // Android / other platforms — no useful local-only persistence
      // beyond the host app's own SharedPreferences flag.
      return;
    }
    try {
      await _secure.write(key: _grantedFlagKey, value: _grantedFlagValue);
      SafeLogger.d(_tag, '✅ Keychain anti-bypass flag persisted');
    } catch (e) {
      SafeLogger.w(_tag, 'markGranted threw: $e');
    }
  }

  /// Test hook — wipes the persisted flag so `hasAlreadyGranted` reports
  /// `false` again. Production callers should never invoke this.
  @visibleForTesting
  Future<void> clearForTest() async {
    try {
      await _secure.delete(key: _grantedFlagKey);
    } catch (_) {/* ignore */}
  }

  Future<bool> _checkIosKeychainFlag() async {
    try {
      final flag = await _secure.read(key: _grantedFlagKey);
      if (flag == _grantedFlagValue) {
        SafeLogger.d(_tag,
            '🛡️ Keychain flag present — prior install detected on this device');
        return true;
      }
      return false;
    } catch (e) {
      SafeLogger.w(_tag,
          '_checkIosKeychainFlag threw: $e — defaulting to allow grace');
      return false;
    }
  }
}
