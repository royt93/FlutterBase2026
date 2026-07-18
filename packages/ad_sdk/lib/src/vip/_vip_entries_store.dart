import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';

/// Encrypted-at-rest storage for the VIP entries blob (`VipEntry` list),
/// backed by `flutter_secure_storage` (Keychain on iOS, Keystore-backed
/// `EncryptedSharedPreferences` on Android) instead of plaintext
/// `SharedPreferences`.
///
/// Unlike [RedeemedKeyLedger]/`FirstInstallGuard` (iOS-only — those exist for
/// *reinstall-survival*, which Android has no primitive for), this class runs
/// on both platforms: the goal here is at-rest confidentiality of the active
/// entitlement, which Android's Keystore-backed storage does provide.
///
/// Never throws to callers; any internal error degrades to "no VIP data"
/// (fail open on read) so a storage hiccup never fabricates entitlement, and
/// swallows write errors (logged) so a storage hiccup never blocks a grant
/// that already happened in memory.
class VipEntriesStore {
  VipEntriesStore(
    this._legacyPrefs, {
    FlutterSecureStorage? secureStorage,
  }) : _secure = secureStorage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              aOptions: AndroidOptions(),
            );

  final AdPreferences _legacyPrefs;
  final FlutterSecureStorage _secure;

  static const String _tag = 'VipEntriesStore';
  static const String _secureKey = 'ad_sdk_vip_entries_v1';

  /// Read the current VIP entries JSON, migrating once from the legacy
  /// checksum-prefixed `SharedPreferences` value if secure storage is empty
  /// and migration hasn't happened yet.
  Future<String?> getRaw() async {
    final secure = await _readSecure();
    if (secure != null) return secure;

    if (_legacyPrefs.isVipEntriesSecureMigrated()) {
      // Migration already ran — secure storage being empty here is a
      // legitimate "no VIP" state, never fall back to the legacy key again.
      return null;
    }

    final legacy = _legacyPrefs.getLegacyVipEntriesRawChecksumValidated();
    await _legacyPrefs.markVipEntriesSecureMigrated();

    if (legacy != null) {
      final wrote = await _writeSecure(legacy);
      // Only clear the legacy copy once the secure write actually landed —
      // a failed write must leave it as the safety net for the next read.
      if (wrote) await _legacyPrefs.clearLegacyVipEntriesRaw();
    }
    return legacy;
  }

  /// Persist [json] to secure storage (no checksum — the OS already
  /// encrypts this at rest, an unkeyed hash on top adds nothing).
  Future<void> setRaw(String json) async {
    await _writeSecure(json);
    // Idempotent: a fresh install whose first VIP action is a write (not a
    // read) shouldn't later pay the legacy-fallback check on its first load().
    await _legacyPrefs.markVipEntriesSecureMigrated();
  }

  Future<String?> _readSecure() async {
    try {
      return await _secure.read(key: _secureKey);
    } catch (e) {
      SafeLogger.w(_tag, 'getRaw threw: $e — defaulting to no VIP data');
      return null;
    }
  }

  Future<bool> _writeSecure(String json) async {
    try {
      await _secure.write(key: _secureKey, value: json);
      return true;
    } catch (e) {
      SafeLogger.w(_tag, 'setRaw threw: $e');
      return false;
    }
  }

  /// Test hook — wipes secure storage so `getRaw` reports empty again.
  @visibleForTesting
  Future<void> clearForTest() async {
    try {
      await _secure.delete(key: _secureKey);
    } catch (_) {/* ignore */}
  }
}
