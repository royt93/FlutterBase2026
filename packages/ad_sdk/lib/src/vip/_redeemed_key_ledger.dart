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
/// key ids that survives reinstall; Android has no *class-local* backstop
/// here, but `AdPreferences`'s redeemed-key list (the check this class
/// defers to on Android) lives in the same `SharedPreferences` →
/// `FlutterSharedPreferences.xml` file that `FirstInstallGuard`'s doc
/// comment describes a host app backing up via Android Auto Backup — a host
/// that wires that manifest config (see README's "Disable first-install
/// grace" section) gets this ledger's protection transitively, for free.
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

  /// Round-27 audit (3 independent reviewers, same finding) — [markRedeemed]
  /// used to read-modify-write the Keychain with no serialization: two
  /// concurrent redemptions could both read the same snapshot, and whichever
  /// write landed second would silently drop the other's `kid`. Same
  /// idea as `AdEventLog._persistChain` — every write chains onto the
  /// previous one instead of racing it.
  ///
  /// Round-31 audit fix (MAJOR) — **static on purpose**, mirroring
  /// `VipManager._saveQueue`'s round-10 fix for the identical reason: this
  /// was per-instance, but every instance writes the SAME secure-storage
  /// key. `AdManager.destroy()` + `initialize()` builds a brand new
  /// `VipManager` (never passing `redeemedKeyLedger:`), which builds a
  /// brand new `RedeemedKeyLedger` with its own empty queue — so the OLD
  /// ledger's `markRedeemed()` write, still parked inside
  /// `_secure.write(...)` from a redemption that started right before
  /// teardown, was not serialized against the new ledger's own write at
  /// all. Whichever landed last silently dropped the other's `kid` from
  /// the persisted set — reopening the exact one-time-use hole this ledger
  /// exists to close, on a redeem racing a reinit. `_writesInFlight`
  /// exists for the same zone-lifetime reason `VipManager` documents on
  /// its own counter: a finished tail future from an earlier (e.g. test)
  /// zone can never deliver a `.then` from a later one.
  static Future<void> _writeChain = Future<void>.value();
  static int _writesInFlight = 0;

  /// Round-72 audit follow-up (3rd independent review) — same idiom as
  /// `AdManager.debugSimulateReleaseModeForTestSeams`; this file had no
  /// release-mode infrastructure at all before this fix.
  @visibleForTesting
  static bool debugSimulateReleaseModeForTestSeams = false;

  /// Drops the process-wide write ordering. Tests only — guarded: without
  /// it, calling this in a release build reopens the exact
  /// dropped-redemption race documented above.
  @visibleForTesting
  static void resetWriteChainForTest() {
    if (kReleaseMode || debugSimulateReleaseModeForTestSeams) {
      SafeLogger.e(_tag,
          'resetWriteChainForTest ignored in a release build — test-only seam (round-72 audit)');
      return;
    }
    _writeChain = Future<void>.value();
    _writesInFlight = 0;
  }

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
  Future<void> markRedeemed(String kid) {
    if (!_platformIsIos()) return Future<void>.value();
    // Chain onto the previous write so two near-simultaneous redemptions —
    // including one issued by a different `RedeemedKeyLedger` instance,
    // see `_writeChain`'s doc comment — never read the same pre-write
    // snapshot. The second one always reads what the first one just wrote.
    final predecessor =
        _writesInFlight > 0 ? _writeChain : Future<void>.value();
    _writesInFlight++;
    final next = predecessor.then((_) async {
      try {
        await _markRedeemed(kid);
      } finally {
        _writesInFlight--;
      }
    });
    _writeChain = next;
    return next;
  }

  Future<void> _markRedeemed(String kid) async {
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

  /// Wipes the persisted ledger. T200 — was test-only (`clearForTest`,
  /// "production callers never call this"); now also the real
  /// production entry point `VipManager.eraseSecureEntitlementStorage()`
  /// uses for a confirmed VIP-entitlement data-erasure request. The
  /// operation itself was already exactly this simple; only its
  /// intended callers changed.
  Future<void> erase() async {
    try {
      await _secure.delete(key: _storageKey);
    } catch (_) {/* ignore */}
  }
}
