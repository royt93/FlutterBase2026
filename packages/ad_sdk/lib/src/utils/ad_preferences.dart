import 'dart:async' show unawaited;
import 'dart:convert' show jsonDecode, jsonEncode, utf8;
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'safe_logger.dart';

/// Thin wrapper around `SharedPreferences` for SDK-owned persistence.
///
/// Stores:
/// - VIP GAID list (1.x legacy, kept for migration)
/// - First-init flag (one-time VIP import)
/// - Daily ad count + day stamp (anti-fraud cap)
/// - Suspicious-violation count (progressive cooldown)
/// - VIP entries (2.x — JSON list of [VipEntry])
class AdPreferences {
  AdPreferences._();

  static AdPreferences? _instance;
  SharedPreferences? _prefs;

  static Future<AdPreferences> getInstance() async {
    var instance = _instance;
    if (instance == null) {
      instance = AdPreferences._();
      instance._prefs = await SharedPreferences.getInstance();
      _instance = instance;
    }
    return instance;
  }

  static AdPreferences? get instanceOrNull => _instance;

  /// Reset the cached singleton (used by test setUp so each test gets a
  /// fresh instance bound to a fresh `SharedPreferences.setMockInitialValues`).
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
  }

  // ─── Legacy VIP GAID list ─────────────────────────────────────────────────

  static const String _keyListGAID = 'ad_sdk_keyListGAID';
  static const String _keyAddVIPFirstInit = 'ad_sdk_keyAddVIPFirstInitSuccess';

  List<String> getGAIDList() => _prefs?.getStringList(_keyListGAID) ?? [];

  Future<void> saveGAIDList(List<String> list) async {
    await _prefs?.setStringList(_keyListGAID, list.toSet().toList());
  }

  bool isAddVIPMemberFirstInitSuccess() =>
      _prefs?.getBool(_keyAddVIPFirstInit) ?? false;

  Future<void> addVIPMemberFirstInitSuccess() async {
    await _prefs?.setBool(_keyAddVIPFirstInit, true);
  }

  // ─── Daily ad count (anti-fraud) ──────────────────────────────────────────

  static const String _keyDailyAdCount = 'ad_sdk_daily_count';
  static const String _keyDailyDate = 'ad_sdk_daily_date';
  static const String _keySuspiciousCount = 'ad_sdk_suspicious_count';

  int getDailyAdCount() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final saved = _prefs?.getString(_keyDailyDate) ?? '';
    if (saved != today) {
      _prefs?.setString(_keyDailyDate, today);
      _prefs?.setInt(_keyDailyAdCount, 0);
      return 0;
    }
    return _prefs?.getInt(_keyDailyAdCount) ?? 0;
  }

  Future<void> incrementDailyAdCount() async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final current = getDailyAdCount();
    await _prefs?.setInt(_keyDailyAdCount, current + 1);
    await _prefs?.setString(_keyDailyDate, today);
  }

  // ─── Per-placement daily ad count (T92) ────────────────────────────────────
  // Same day-rollover shape as the global counter above, but keyed by
  // AdPlacement.id in a single JSON blob (placements are host-defined, open-
  // ended strings — a dynamic-key-per-placement scheme would need its own
  // "list of known keys" bookkeeping for no real benefit over one blob).

  static const String _keyPlacementDailyCounts = 'ad_sdk_placement_daily_counts';
  static const String _keyPlacementDailyDate = 'ad_sdk_placement_daily_date';

  Map<String, int> getPlacementDailyCounts() {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final saved = _prefs?.getString(_keyPlacementDailyDate) ?? '';
    if (saved != today) {
      _prefs?.setString(_keyPlacementDailyDate, today);
      _prefs?.setString(_keyPlacementDailyCounts, '{}');
      return {};
    }
    final raw = _prefs?.getString(_keyPlacementDailyCounts);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as int));
    } catch (e) {
      SafeLogger.w(_tag, 'discarding corrupt placement daily counts: $e');
      return {};
    }
  }

  Future<void> incrementPlacementDailyCount(String placementId) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final counts = getPlacementDailyCounts(); // handles rollover
    counts[placementId] = (counts[placementId] ?? 0) + 1;
    await _prefs?.setString(_keyPlacementDailyCounts, jsonEncode(counts));
    await _prefs?.setString(_keyPlacementDailyDate, today);
  }

  int getSuspiciousCount() => _prefs?.getInt(_keySuspiciousCount) ?? 0;

  Future<void> setSuspiciousCount(int value) async {
    await _prefs?.setInt(_keySuspiciousCount, value);
  }

  // ─── First-install VIP grace ──────────────────────────────────────────────

  static const String _keyFirstInstallApplied =
      'ad_sdk_first_install_grace_applied';
  static const String _keyFirstInstallAt = 'ad_sdk_first_install_at_ms';

  bool isFirstInstallGraceApplied() =>
      _prefs?.getBool(_keyFirstInstallApplied) ?? false;

  Future<void> markFirstInstallGraceApplied() async {
    await _prefs?.setBool(_keyFirstInstallApplied, true);
  }

  /// Epoch-ms of the first SDK init on this install. Set on first init,
  /// preserved across hot-restart but lost on app data clear / reinstall.
  int? getFirstInstallAtMs() => _prefs?.getInt(_keyFirstInstallAt);

  Future<void> setFirstInstallAtMsIfMissing(int epochMs) async {
    if (_prefs?.getInt(_keyFirstInstallAt) != null) return;
    await _prefs?.setInt(_keyFirstInstallAt, epochMs);
  }

  // ─── Consent settings (JSON) ──────────────────────────────────────────────

  static const String _keyConsentSettings = 'ad_sdk_consent_settings_v1';

  String? getConsentSettingsRaw() => _prefs?.getString(_keyConsentSettings);

  Future<void> setConsentSettingsRaw(String json) async {
    await _prefs?.setString(_keyConsentSettings, json);
  }

  // ─── 2.x VIP entries — legacy checksum-prefixed SharedPreferences value ───
  // Superseded by `VipEntriesStore` (flutter_secure_storage). Kept here only
  // as the one-time migration source for installs that predate the secure
  // storage move — see `getLegacyVipEntriesRawChecksumValidated` below.

  static const String _keyVipEntries = 'ad_sdk_vip_entries';
  static const String _keyVipMigrated = 'ad_sdk_vip_migrated_v2';
  // Separate from `_keyVipMigrated` (1.x GAID → 2.x entries migration,
  // unrelated). Tracks whether the one-time raw-JSON-without-checksum
  // trust-and-backfill below has already happened, so a raw JSON array
  // reappearing afterwards (e.g. a rooted/jailbroken write straight to
  // SharedPreferences) is rejected instead of trusted again.
  static const String _keyVipEntriesChecksumMigrated =
      'ad_sdk_vip_entries_checksum_migrated_v1';
  // Tracks whether the legacy SharedPreferences value above has been
  // migrated into `VipEntriesStore`'s secure storage. Distinct from
  // `_keyVipEntriesChecksumMigrated` (a different, older migration).
  static const String _keyVipEntriesSecureMigrated =
      'ad_sdk_vip_entries_secure_migrated_v1';
  static const String _tag = 'AdPreferences';

  // FNV-1a — deterministic across Dart/Flutter versions (unlike
  // `String.hashCode`, which isn't spec-guaranteed stable). This is a
  // tamper-*deterrent* against casual SharedPreferences editing, not a
  // cryptographic guarantee against a rooted/jailbroken attacker. Only
  // relevant to the legacy value below — new writes go to secure storage
  // (OS-encrypted at rest) without a checksum.
  static int _fnv1a(String s) {
    const prime = 0x01000193;
    var hash = 0x811c9dc5;
    for (final byte in utf8.encode(s)) {
      hash = ((hash ^ byte) * prime) & 0xFFFFFFFF;
    }
    return hash;
  }

  static String _vipEntriesChecksum(String value) =>
      _fnv1a('$value|ad_sdk_vip_integrity_v1').toRadixString(16);

  /// One-time read of the legacy checksum-prefixed value, for
  /// `VipEntriesStore`'s migration path only. Same trust-once-bare-JSON /
  /// checksum-validation behavior as before the secure-storage move.
  String? getLegacyVipEntriesRawChecksumValidated() {
    final payload = _prefs?.getString(_keyVipEntries);
    if (payload == null) return null;
    if (payload.startsWith('[')) {
      if (_prefs?.getBool(_keyVipEntriesChecksumMigrated) ?? false) {
        SafeLogger.w(_tag,
            'VIP entries checksum mismatch — raw JSON after migration, ignoring as tampered');
        return null;
      }
      unawaited(_prefs?.setBool(_keyVipEntriesChecksumMigrated, true));
      return payload;
    }
    final sep = payload.indexOf('|');
    if (sep == -1) return null;
    final raw = payload.substring(sep + 1);
    if (payload.substring(0, sep) != _vipEntriesChecksum(raw)) {
      SafeLogger.w(
          _tag, 'VIP entries checksum mismatch — ignoring as tampered');
      return null;
    }
    return raw;
  }

  /// Remove the legacy SharedPreferences value once its content has been
  /// safely copied into secure storage.
  Future<void> clearLegacyVipEntriesRaw() async {
    await _prefs?.remove(_keyVipEntries);
  }

  bool isVipEntriesSecureMigrated() =>
      _prefs?.getBool(_keyVipEntriesSecureMigrated) ?? false;

  Future<void> markVipEntriesSecureMigrated() async {
    await _prefs?.setBool(_keyVipEntriesSecureMigrated, true);
  }

  // T71 — some Android devices (cheap/custom ROMs with a broken Keystore)
  // can't read/write flutter_secure_storage at all. Distinct key from the
  // legacy one above (that one is a one-time migration source with its own
  // "trust bare JSON once" semantics); this is an ongoing fallback landing
  // spot `VipEntriesStore` writes to whenever its secure write fails, so a
  // legitimate VIP grant isn't lost entirely on such a device. Same
  // checksum scheme as the legacy value — a light tamper deterrent, not
  // encryption (this device's Keystore is already known broken).
  static const String _keyVipEntriesFallback = 'ad_sdk_vip_entries_fallback_v1';

  Future<void> setVipEntriesFallbackRaw(String json) async {
    final checksum = _vipEntriesChecksum(json);
    await _prefs?.setString(_keyVipEntriesFallback, '$checksum|$json');
  }

  String? getVipEntriesFallbackRaw() {
    final payload = _prefs?.getString(_keyVipEntriesFallback);
    if (payload == null) return null;
    final sep = payload.indexOf('|');
    if (sep == -1) return null;
    final raw = payload.substring(sep + 1);
    if (payload.substring(0, sep) != _vipEntriesChecksum(raw)) {
      SafeLogger.w(
          _tag, 'VIP entries fallback checksum mismatch — ignoring as tampered');
      return null;
    }
    return raw;
  }

  Future<void> clearVipEntriesFallbackRaw() async {
    await _prefs?.remove(_keyVipEntriesFallback);
  }

  bool isVipMigrated() => _prefs?.getBool(_keyVipMigrated) ?? false;

  Future<void> markVipMigrated() async {
    await _prefs?.setBool(_keyVipMigrated, true);
  }

  // ─── Redeemed signed-key IDs (T18 — per-device one-time-use) ───────────────
  // We can't enforce GLOBAL one-time-use offline, but we can stop the SAME
  // signed key from being redeemed repeatedly on the SAME device.

  static const String _keyRedeemedVipKids = 'ad_sdk_redeemed_vip_kids';

  List<String> getRedeemedVipKeyIds() =>
      _prefs?.getStringList(_keyRedeemedVipKids) ?? const [];

  bool isVipKeyIdRedeemed(String kid) => getRedeemedVipKeyIds().contains(kid);

  Future<void> addRedeemedVipKeyId(String kid) async {
    final set = getRedeemedVipKeyIds().toSet()..add(kid);
    await _prefs?.setStringList(_keyRedeemedVipKids, set.toList());
  }

  // ─── VIP grace-period expiry nudge (one-time-per-expiry ack) ──────────────
  // Stores the `expiresAt` (millisSinceEpoch) already acknowledged, so a
  // later stack/redeem that produces a NEW expiry naturally makes the nudge
  // due again — no separate reset logic needed.

  static const String _keyVipGraceNudgeAckExpiryMs =
      'ad_sdk_vip_grace_nudge_ack_expiry_ms';

  int? getVipGraceNudgeAckExpiryMs() =>
      _prefs?.getInt(_keyVipGraceNudgeAckExpiryMs);

  Future<void> setVipGraceNudgeAckExpiryMs(int expiryMs) async {
    await _prefs?.setInt(_keyVipGraceNudgeAckExpiryMs, expiryMs);
  }

  // ─── VIP clock-rollback guard — high-water mark of the latest wall-clock
  // time ever observed by [VipManager]. `DateTime.now()` reading *before*
  // this stored value means the system clock was rolled back — clamping
  // "now" to this mark stops a rolled-back clock from reviving a VIP/trial
  // entry that already expired in real time (closes the window between
  // `grantedAt` and `expiresAt`, which the `grantedAt`-anchor check alone
  // does not cover).

  static const String _keyVipMaxObservedClockMs = 'ad_sdk_vip_max_observed_clock_ms';

  int? getVipMaxObservedClockMs() =>
      _prefs?.getInt(_keyVipMaxObservedClockMs);

  Future<void> setVipMaxObservedClockMs(int millisSinceEpoch) async {
    await _prefs?.setInt(_keyVipMaxObservedClockMs, millisSinceEpoch);
  }

  // ─── Compliance event log (T23, JSON-encoded ring buffer) ─────────────────

  static const String _keyComplianceLog = 'ad_sdk_compliance_event_log_v1';

  String? getComplianceLogRaw() => _prefs?.getString(_keyComplianceLog);

  Future<void> setComplianceLogRaw(String json) async {
    await _prefs?.setString(_keyComplianceLog, json);
  }

  Future<void> clearAllData() async => _prefs?.clear();

  // T93 — a stable pseudonymous per-install id for AdManager.experimentBucket
  // to hash, independent of GAID (which is empty/all-zeros for a user who
  // opted out of ad tracking — using GAID alone there would collide every
  // opted-out user into the exact same A/B bucket).
  static const String _keyExperimentInstallId = 'ad_sdk_experiment_install_id';
  String? _experimentInstallIdCache;

  /// Side effect: persists a freshly-generated id to disk on first call
  /// (fire-and-forget, same pattern as `VipManager.expiresAt`) — same
  /// getter-with-a-write-side-effect trade-off, documented here for the
  /// same reason: cheap for normal use, avoid polling this at high frequency.
  String getOrCreateExperimentInstallId() {
    final cached = _experimentInstallIdCache;
    if (cached != null) return cached;
    final persisted = _prefs?.getString(_keyExperimentInstallId);
    if (persisted != null && persisted.isNotEmpty) {
      _experimentInstallIdCache = persisted;
      return persisted;
    }
    final fresh = _generateRandomId();
    _experimentInstallIdCache = fresh;
    unawaited(_prefs?.setString(_keyExperimentInstallId, fresh));
    return fresh;
  }

  static String _generateRandomId() {
    final rand = math.Random.secure();
    final bytes = List<int>.generate(16, (_) => rand.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  // ─── VIP key revocation list (CRL) cache — T95 ───────────────────────────
  // Caches the RAW signed CRL code (not the parsed plaintext) so it gets
  // re-verified against the Ed25519 public key on every read — never trust
  // unsigned cached data, even data this same SDK wrote itself.

  static const String _keyVipRevocationCache = 'ad_sdk_vip_revocation_cache_v1';

  String? getVipRevocationCacheRaw() => _prefs?.getString(_keyVipRevocationCache);

  Future<void> setVipRevocationCacheRaw(String code) async {
    await _prefs?.setString(_keyVipRevocationCache, code);
  }
}
