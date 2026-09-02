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
///   • **Android — no guard-class-level check; relies on OS Auto Backup
///     of the grace flag instead.** This class (`FirstInstallGuard`) has no
///     Android-side check of its own — there's no local-only signal
///     (Keychain/EncryptedSharedPreferences wipe with the app on uninstall,
///     ANDROID_ID needs companion storage) it could check here. Instead, the
///     app declares Android Auto Backup (`android:allowBackup="true"` +
///     `fullBackupContent`/`dataExtractionRules`, see
///     `full_backup_content.xml` / `data_extraction_rules.xml`) covering
///     `FlutterSharedPreferences.xml`, the file holding
///     `AdPreferences.isFirstInstallGraceApplied()`'s flag — that flag IS
///     the marker, and the grant gate (`AdManager.initialize()`) already
///     checks it directly (`!prefs.isFirstInstallGraceApplied()`) before
///     this guard is even consulted. On a reinstall to the same
///     device+Google-account with backup/sync enabled, Android restores
///     that file automatically before the app's first run, so the flag is
///     already `true` and no fresh grace is granted — a best-effort,
///     non-attacker-proof mitigation (see limitations below). Play Install
///     Referrer alone was rejected as an alternative: it cannot distinguish
///     a fresh install from a reinstall, and a dedicated plugin
///     (`play_install_referrer`) would add startup overhead and a crash
///     surface for no better guarantee than the Auto Backup path above.
///
/// **Bypass-result matrix:**
///
/// | Attempt                                      | iOS                        | Android                    |
/// |----------------------------------------------|----------------------------|----------------------------|
/// | Uninstall + reinstall (same device+account, backup enabled) | block (Keychain flag) | mitigated (Auto Backup restores the grace flag) |
/// | Uninstall + reinstall (different account, or backup/sync disabled) | block (Keychain flag) | bypass (no signal survives) |
/// | Single-app-per-vendor + IDFV reset           | block (we don't use IDFV)  | n/a                        |
/// | "Erase All Content and Settings"             | bypass (Keychain wiped)    | bypass                     |
/// | Genuine first launch on a NEW physical device, restored from an iCloud/iTunes/Finder backup of an old device that already got the grace | false-positive BLOCK (Keychain flag survives `.first_unlock` restore by design) | n/a |
///
/// Round-31 audit — the false-positive row above is a real product
/// trade-off, not a bug: `KeychainAccessibility.first_unlock` (not
/// `.first_unlock_this_device_only`) is what makes the "reinstall on the
/// SAME device" row above actually block, but Apple's device-restore
/// mechanics apply that same non-device-locked accessibility to a restore
/// onto a DIFFERENT device too. Tightening to `.first_unlock_this_device_only`
/// would close this row but reopen "reinstall, same device" as a bypass —
/// there is no single accessibility value that blocks one and not the
/// other. Left as a known, accepted limitation for the product owner to
/// judge, not "fixed" here.
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
      SafeLogger.d(
          _tag, '⏭️ Android — anti-bypass disabled by design, allow grace');
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
      SafeLogger.w(
          _tag, '_checkIosKeychainFlag threw: $e — defaulting to allow grace');
      return false;
    }
  }
}
