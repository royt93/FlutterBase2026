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
  static const String _probeKey = 'ad_sdk_secure_probe_v1';

  /// True when the last [getRaw] served the plaintext fallback on a device
  /// whose secure storage is working — a state no legitimate write path
  /// produces. The caller must not treat such entries as fully trusted; see M6
  /// in [getRaw].
  ///
  /// Deliberately a flag rather than a thrown error or a filtered value: the
  /// entry may well be genuine (Keystore broken at grant time, healed since),
  /// and this class does not parse entries — the decision of what to do with a
  /// suspicious grant belongs to `VipManager`, next to the equivalent M5 clamp.
  bool lastReadWasUntrustedFallback = false;

  /// Round-trips a throwaway key to tell "secure storage is empty" apart from
  /// "secure storage does not work here". [_readSecure] returns null for both.
  @visibleForTesting
  Future<bool> secureStorageWorks() => _secureStorageWorks();

  Future<bool> _secureStorageWorks() async {
    try {
      await _secure.write(key: _probeKey, value: '1');
      final v = await _secure.read(key: _probeKey);
      await _secure.delete(key: _probeKey);
      return v == '1';
    } catch (_) {
      return false;
    }
  }

  /// Read the current VIP entries JSON, migrating once from the legacy
  /// checksum-prefixed `SharedPreferences` value if secure storage is empty
  /// and migration hasn't happened yet.
  Future<String?> getRaw() async {
    final secure = await _readSecure();
    if (secure != null) return secure;

    // T71 — some devices have a permanently broken Keystore: `setRaw()`
    // falls back to AdPreferences (checksum-prefixed) whenever the secure
    // write fails. Check it before the one-time legacy-migration logic
    // below, since a device whose Keystore never works will also never
    // complete that migration (`_writeSecure` fails there identically).
    final fallback = _legacyPrefs.getVipEntriesFallbackRaw();
    if (fallback != null) {
      // M6 (round-6 audit) — this plaintext fallback is protected only by an
      // unkeyed FNV-1a checksum whose salt is a literal in this package, so it
      // is reproducible from the published pub.dev source. With root, an
      // emulator, or a permissive backup/restore path, a forged
      // "VIP until 2099" entry planted here was accepted outright.
      //
      // What makes that detectable: `setRaw()` only ever writes here when the
      // SECURE write failed. So a fallback entry on a device whose secure
      // storage works has no legitimate way to exist — probe it and treat the
      // value as untrusted when the probe succeeds. An attacker now has to
      // actually break their own Keystore rather than append a line.
      //
      // Untrusted does not mean discarded: a device whose Keystore was broken
      // when the grant was made and later healed (an OS update) would leave a
      // GENUINE entry in exactly this state, and the one-time-use ledger means
      // that customer cannot simply redeem their code again. So the value is
      // still returned and the caller clamps it — see
      // [lastReadWasUntrustedFallback].
      // A failed entries read tells us nothing about the fallback's
      // provenance, so a healthy probe after one is not evidence.
      lastReadWasUntrustedFallback =
          !_lastSecureReadErrored && await _secureStorageWorks();
      if (lastReadWasUntrustedFallback) {
        SafeLogger.w(
            _tag,
            'fallback VIP entries present while secure storage is HEALTHY — '
            'treating as untrusted (M6)');
      }
      return fallback;
    }
    lastReadWasUntrustedFallback = false;

    if (_legacyPrefs.isVipEntriesSecureMigrated()) {
      // Migration already ran — secure storage being empty here is a
      // legitimate "no VIP" state, never fall back to the legacy key again.
      return null;
    }

    final legacy = _legacyPrefs.getLegacyVipEntriesRawChecksumValidated();
    if (legacy == null) {
      // Nothing to migrate — safe to mark done regardless of secure storage.
      await _legacyPrefs.markVipEntriesSecureMigrated();
    } else {
      final wrote = await _writeSecure(legacy);
      // T59: only mark the migration done — and only clear the legacy
      // copy — once the secure write actually landed. A failed write must
      // leave both the flag and the legacy value alone, or the still-present
      // legacy data becomes permanently unreachable (this method returns
      // null on every future call once the flag is set, never re-checking
      // legacy) even though it was never actually migrated anywhere.
      if (wrote) {
        await _legacyPrefs.markVipEntriesSecureMigrated();
        await _legacyPrefs.clearLegacyVipEntriesRaw();
      } else {
        // T71 — Keystore broken on this device: preserve the data via
        // fallback storage too, so it's still readable even though secure
        // storage never got it (and never will, on this device).
        await _legacyPrefs.setVipEntriesFallbackRaw(legacy);
      }
    }
    return legacy;
  }

  /// Persist [json] to secure storage (no checksum — the OS already
  /// encrypts this at rest, an unkeyed hash on top adds nothing).
  Future<void> setRaw(String json) async {
    final wrote = await _writeSecure(json);
    // T59: only mark migrated when the write actually landed. Marking it
    // unconditionally made a failed write indistinguishable from "no VIP
    // data" forever after — getRaw() short-circuits to null once this flag
    // is set, so a Keystore hiccup would permanently lose a grant that was
    // never actually persisted anywhere. Leaving it unset lets the next
    // setRaw()/getRaw() call retry once storage recovers.
    //
    // Idempotent: a fresh install whose first VIP action is a write (not a
    // read) shouldn't later pay the legacy-fallback check on its first load().
    if (wrote) {
      await _legacyPrefs.markVipEntriesSecureMigrated();
      // T71 — Keystore just recovered (or always worked): drop any stale
      // fallback copy so a future getRaw() doesn't prefer outdated data.
      await _legacyPrefs.clearVipEntriesFallbackRaw();
    } else {
      // T71 — Keystore broken: fall back to AdPreferences (checksum-
      // prefixed) so a legitimate VIP grant isn't lost entirely.
      await _legacyPrefs.setVipEntriesFallbackRaw(json);
    }
  }

  /// Set when the last [_readSecure] FAILED, as opposed to finding nothing.
  ///
  /// Round-6 QC — both cases used to return null, so a transient read blip was
  /// indistinguishable from an empty store: the probe right afterwards
  /// succeeded, the fallback looked planted, and a genuine grant was clamped.
  /// A failed read is evidence of nothing, so it must not feed that inference.
  bool _lastSecureReadErrored = false;

  Future<String?> _readSecure() async {
    _lastSecureReadErrored = false;
    try {
      return await _secure.read(key: _secureKey);
    } catch (e) {
      SafeLogger.w(_tag, 'getRaw threw: $e — defaulting to no VIP data');
      _lastSecureReadErrored = true;
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
