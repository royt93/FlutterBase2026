import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

import '../utils/safe_logger.dart';

/// Durable, cross-reinstall backstop for signed-VIP-key one-time-use.
///
/// [VipManager.redeemSignedKey]'s primary ledger is `AdPreferences`
/// (`SharedPreferences`), which is wiped on uninstall — a user could
/// uninstall + reinstall to redeem the same signed key repeatedly. This
/// ledger mirrors the `FirstInstallGuard` pattern (see
/// `_first_install_guard.dart`): iOS gets a Keychain-backed set of redeemed
/// key ids that survives reinstall; Android intentionally has no durable
/// backstop here for the same reason `FirstInstallGuard` doesn't — no local
/// primitive survives uninstall without pulling in a install-referrer plugin
/// for a narrow benefit. `AdPreferences` remains the check on Android.
///
/// Never throws to callers; any internal error degrades to "not redeemed"
/// (fail open) so a storage hiccup never locks a legitimate key out.
class RedeemedKeyLedger {
  RedeemedKeyLedger({
    FlutterSecureStorage? secureStorage,
    bool Function()? platformIsIos,
  })  : _secure = secureStorage ??
            const FlutterSecureStorage(
              iOptions: IOSOptions(
                accessibility: KeychainAccessibility.first_unlock,
              ),
              aOptions: AndroidOptions(),
            ),
        _platformIsIos = platformIsIos ?? _defaultIsIos;

  static bool _defaultIsIos() => Platform.isIOS;

  static const String _tag = 'RedeemedKeyLedger';
  static const String _storageKey = 'ad_sdk_redeemed_vip_kids_v1';

  final FlutterSecureStorage _secure;
  final bool Function() _platformIsIos;

  /// True if [kid] was already redeemed on this device, per the durable
  /// (iOS Keychain) ledger. Always `false` on non-iOS — those platforms rely
  /// solely on `AdPreferences`.
  Future<bool> isRedeemed(String kid) async {
    if (!_platformIsIos()) return false;
    try {
      final raw = await _secure.read(key: _storageKey);
      if (raw == null) return false;
      final ids = (jsonDecode(raw) as List).cast<String>();
      return ids.contains(kid);
    } catch (e) {
      SafeLogger.w(_tag, 'isRedeemed threw: $e — defaulting to not-redeemed');
      return false;
    }
  }

  /// Persist [kid] into the durable ledger. No-op on non-iOS. Errors are
  /// swallowed — a failed durability write must never block the grant that
  /// already happened via `AdPreferences`.
  Future<void> markRedeemed(String kid) async {
    if (!_platformIsIos()) return;
    try {
      final raw = await _secure.read(key: _storageKey);
      final ids = raw == null
          ? <String>{}
          : (jsonDecode(raw) as List).cast<String>().toSet();
      ids.add(kid);
      await _secure.write(key: _storageKey, value: jsonEncode(ids.toList()));
    } catch (e) {
      SafeLogger.w(_tag, 'markRedeemed threw: $e');
    }
  }

  /// Test hook — wipes the persisted ledger. Production callers never call
  /// this.
  @visibleForTesting
  Future<void> clearForTest() async {
    try {
      await _secure.delete(key: _storageKey);
    } catch (_) {/* ignore */}
  }
}
