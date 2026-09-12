import 'dart:async' show Completer, unawaited;
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

  /// Round-30 audit (MAJOR) — `getInstance()` used to check `_instance`
  /// only BEFORE its `await`, never re-checking after: two concurrent
  /// callers racing before `_instance` was first set both passed the null
  /// check and each built their own separate `AdPreferences` object (their
  /// underlying `SharedPreferences` stayed consistent — that class's own
  /// `getInstance()` really does dedupe — but per-instance mutable state
  /// like `_fillRateBaselineChain`'s write-serialization queue did not, so
  /// two "singletons" could silently drop each other's writes exactly like
  /// the race `_fillRateBaselineChain` was added to prevent). Mirrors the
  /// same completer-based guard `SharedPreferences.getInstance()` itself
  /// already uses.
  static Completer<AdPreferences>? _initCompleter;

  static Future<AdPreferences> getInstance() async {
    final existing = _instance;
    if (existing != null) return existing;
    final inFlight = _initCompleter;
    if (inFlight != null) return inFlight.future;
    final completer = Completer<AdPreferences>();
    _initCompleter = completer;
    try {
      final instance = AdPreferences._();
      instance._prefs = await SharedPreferences.getInstance();
      _instance = instance;
      completer.complete(instance);
      return instance;
    } catch (e, st) {
      _initCompleter = null;
      completer.completeError(e, st);
      rethrow;
    }
  }

  static AdPreferences? get instanceOrNull => _instance;

  /// Reset the cached singleton (used by test setUp so each test gets a
  /// fresh instance bound to a fresh `SharedPreferences.setMockInitialValues`).
  @visibleForTesting
  static void resetForTest() {
    _instance = null;
    _initCompleter = null;
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

  /// Round-31 audit fix — every other rolling window in `AdSafetyConfig`
  /// (hourly cap, throttle, resume-spam) uses `millisecondsSinceEpoch`, which
  /// is absolute and immune to the device clock's timezone setting. This
  /// "which calendar day is it" boundary used local time
  /// (`DateTime.now().toIso8601String()`), which is NOT absolute: a user
  /// changing their device's timezone (Settings → Date & Time → Time Zone —
  /// no need to touch "Automatic date & time", and no clock rollback like
  /// the MJ9 case) instantly changes what "today" means, resetting this
  /// counter to 0 on demand, repeatedly, on the same real calendar day.
  /// UTC has no such user-facing knob.
  static String _todayUtc({DateTime? now}) =>
      (now ?? DateTime.now()).toUtc().toIso8601String().substring(0, 10);

  static const String _keyDailyAdCount = 'ad_sdk_daily_count';
  static const String _keyDailyDate = 'ad_sdk_daily_date';
  static const String _keySuspiciousCount = 'ad_sdk_suspicious_count';

  // Round-37 audit MAJOR — `_todayUtc()` alone is a raw wall-clock reading,
  // so winding the system clock back one day made `today != saved` fire in
  // the *other* direction from what round-31's UTC fix closed, resetting
  // the daily/per-placement counters below to 0 on demand and defeating the
  // safety cap that protects the AdMob account from invalid-traffic flags.
  // Mirrors `VipManager`'s clock-rollback guard
  // (`getVipMaxObservedClockMs`/`setVipMaxObservedClockMs`): a high-water
  // mark of the latest UTC day ever observed, so a day that looks earlier
  // than one already recorded is never trusted. ISO-8601 `YYYY-MM-DD`
  // strings compare lexicographically the same as chronologically, so plain
  // `String.compareTo` is sufficient.
  static const String _keyDailyDateHighWaterMark =
      'ad_sdk_daily_date_high_water_mark';

  String _todayUtcClamped({DateTime? now}) {
    final real = _todayUtc(now: now);
    final observed = _prefs?.getString(_keyDailyDateHighWaterMark);
    if (observed == null || real.compareTo(observed) > 0) {
      _prefs?.setString(_keyDailyDateHighWaterMark, real);
      return real;
    }
    return observed;
  }

  int getDailyAdCount({DateTime? now}) {
    final today = _todayUtcClamped(now: now);
    final saved = _prefs?.getString(_keyDailyDate) ?? '';
    if (saved != today) {
      _prefs?.setString(_keyDailyDate, today);
      _prefs?.setInt(_keyDailyAdCount, 0);
      return 0;
    }
    return _prefs?.getInt(_keyDailyAdCount) ?? 0;
  }

  // Round-31 audit — a chain-based write-serializer (mirroring
  // `_fillRateBaselineChain`) was tried here and reverted: `_prefs` is the
  // LEGACY `SharedPreferences`, whose `setInt`/`setString` mutate its
  // in-memory `_preferenceCache` SYNCHRONOUSLY at call time (see
  // shared_preferences_legacy.dart's `_setValue` — it isn't even `async`),
  // before the returned Future's platform-channel write ever resolves.
  // `getDailyAdCount()` reads that same synchronous cache, not the
  // platform side, so two `unawaited()` calls fired back-to-back with no
  // `await` between them cannot actually interleave — Dart's single-
  // threaded model runs the first call's synchronous read+cache-write
  // prefix to completion before the second call's body starts. Reproducing
  // the "lost update" required an artificial delay hook injected BETWEEN
  // the read and the write, a gap that does not exist in the real code
  // path. `_fillRateBaselineHistory`'s version of this bug (T101) is real
  // because it targets different storage; this one was a false positive
  // from pattern-matching that fix without checking the backend differs.
  // A chain also has a real cost: `.then()` never resolves synchronously,
  // even on an already-completed `Future.value()` — deferring the
  // synchronous cache mutation by a microtask broke every caller (in
  // `AdSafetyConfig`, and its tests) that reads `getDailyAdCount()`
  // synchronously right after recording a show, which is the norm here.
  Future<void> incrementDailyAdCount({DateTime? now}) async {
    final today = _todayUtcClamped(now: now);
    final current = getDailyAdCount(now: now);
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

  Map<String, int> getPlacementDailyCounts({DateTime? now}) {
    final today = _todayUtcClamped(now: now);
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

  // Round-31 audit — see the reverted write-serializer comment on
  // [incrementDailyAdCount] above; the same reasoning applies here.
  Future<void> incrementPlacementDailyCount(String placementId,
      {DateTime? now}) async {
    final today = _todayUtcClamped(now: now);
    final counts = getPlacementDailyCounts(now: now); // handles rollover
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
  //
  // Round-31 audit — on Android, this plain `SharedPreferences` list is the
  // ONLY backstop against replaying a key (`_redeemed_key_ledger.dart`'s
  // iOS Keychain ledger has no Android counterpart, by its own doc). Same
  // root/physical-extraction privilege tier as the clock high-water mark
  // above, and deliberately not "fixed" with a checksum for the same M6
  // reason documented there: an unkeyed checksum salted from the published
  // source is not real protection against the attacker who'd need it.
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
  //
  // Round-31 audit — this key is plain `SharedPreferences` (unencrypted on
  // Android; readable via root or `adb backup` on a debuggable build),
  // unlike VIP entries themselves (`flutter_secure_storage`/Keychain-
  // Keystore). Deleting just this key, then rolling the clock back into an
  // already-expired entry's `grantedAt`..`expiresAt` window, revives it —
  // a real gap, but one that needs root/physical-extraction access, same
  // privilege tier as every other "edit our own app's storage" attack this
  // no-backend design already accepts (see `_redeemed_key_ledger.dart`'s
  // own "Android has no class-local backstop" note). Deliberately NOT
  // "fixed" with a local checksum: this codebase's own M6 finding
  // (`_vip_entries_store.dart`) already established that an unkeyed
  // checksum with a salt baked into the published pub.dev source is
  // reproducible by exactly the attacker it would need to stop, so it
  // would be a false sense of security rather than a real one. Moving this
  // into secure storage would be the honest fix, but `_effectiveNow()`
  // reads this synchronously on every call across several hot paths in
  // `VipManager` — secure storage is async, so that migration is a real
  // refactor of its own, not a one-line change, and is deliberately not
  // bundled into an audit round.
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

  // T155 — bypass audit trail (T128), persisted the same way as the
  // compliance event log above so it survives a cold start, not just the
  // process that recorded it.

  static const String _keyBypassAuditTrail = 'ad_sdk_bypass_audit_trail_v1';

  String? getBypassAuditTrailRaw() => _prefs?.getString(_keyBypassAuditTrail);

  Future<void> setBypassAuditTrailRaw(String json) async {
    await _prefs?.setString(_keyBypassAuditTrail, json);
  }

  // T137 — last `revision` a remote safety-params payload actually applied
  // successfully. Lets `AdManager` reject a stale/rolled-back payload (an
  // older revision than this) without needing to track it in memory only —
  // persisted so a stale payload can't slip back in across app restarts.
  static const String _keyRemoteSafetyRevision =
      'ad_sdk_remote_safety_revision';

  int? getRemoteSafetyRevision() =>
      _prefs?.getInt(_keyRemoteSafetyRevision);

  Future<void> setRemoteSafetyRevision(int revision) async {
    await _prefs?.setInt(_keyRemoteSafetyRevision, revision);
  }

  // T136 — last time `pickSessionProvider()` actually committed a
  // session-alternate exploration (epoch ms), so the rate limit
  // (`minIntervalBetweenExplorations`) survives across app restarts, not
  // just within one process. Set only once VIP status is known to be
  // false for that session — see `AdManager._reconcileProviderExploration
  // Slot`'s doc comment for why the write is deferred rather than
  // immediate.
  static const String _keyLastProviderExplorationAtMs =
      'ad_sdk_last_provider_exploration_at_ms';

  int? getLastProviderExplorationAtMs() =>
      _prefs?.getInt(_keyLastProviderExplorationAtMs);

  Future<void> setLastProviderExplorationAtMs(int epochMs) async {
    await _prefs?.setInt(_keyLastProviderExplorationAtMs, epochMs);
  }

  // T136 (round 2, BLOCKER #3 in independent review) — WaterfallTuner's
  // rolling per-(provider,format,placement) samples, serialized as raw
  // JSON so they survive a destroy()+initialize() cycle (a real app
  // process restart included) — without this, a session-alternate
  // exploration's data was thrown away the moment that session ended,
  // making cross-session accumulation impossible regardless of how many
  // sessions explored.
  static const String _keyWaterfallTunerState = 'ad_sdk_waterfall_tuner_state';

  String? getWaterfallTunerStateRaw() =>
      _prefs?.getString(_keyWaterfallTunerState);

  Future<void> setWaterfallTunerStateRaw(String json) async {
    await _prefs?.setString(_keyWaterfallTunerState, json);
  }

  // T163 — SelfHealingObserver's "already fired this exact recommendation"
  // dedupe, now keyed to WHEN each key last fired rather than a permanent
  // set membership (see that class's own doc comment on _alreadyObserved
  // for why: a plain Set never forgot a key, so once a (format, placement)
  // pair had been recommended BOTH directions — e.g. "switch to AppLovin"
  // then later "switch to Google" — a real, later need to recommend
  // "switch to AppLovin" again (the exact same key as before) stayed
  // silent forever, even though the underlying data genuinely changed
  // back). A new pref key on purpose: the old `List<String>` format (no
  // timestamps) has no way to represent "when", so migrating it would
  // mean guessing — left as unread legacy data instead, which just means
  // a key that WAS permanently blocked pre-fix becomes immediately
  // eligible again post-upgrade (the direction of error that actually
  // matters here: a spurious re-notification is a minor annoyance, a
  // silent-forever tuner is the whole bug being fixed).
  static const String _keySelfHealingObservedAt =
      'ad_sdk_self_healing_observed_at';

  /// Key → epoch-millis it was last recommended at.
  Map<String, int> getSelfHealingObservedAt() {
    final raw = _prefs?.getString(_keySelfHealingObservedAt);
    if (raw == null || raw.isEmpty) return const {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(k, v as int));
    } catch (_) {
      return const {};
    }
  }

  Future<void> setSelfHealingObservedAt(Map<String, int> observedAt) async {
    await _prefs?.setString(_keySelfHealingObservedAt, jsonEncode(observedAt));
  }

  // T143 — ProviderFailoverAdvisor's consecutive-load-failure streak for
  // the current provider, plus which provider tag that streak belongs to
  // (so a real provider switch since the last event doesn't let a stale
  // streak from the OLD provider carry over onto the new one). Persisted
  // for the same reason as WaterfallTuner's state above: the whole point
  // is deciding the provider for the host's NEXT `initialize()` call, so
  // the streak must survive the app restart between "this session failed
  // repeatedly" and "the host reads that before starting the next one".
  static const String _keyProviderFailoverConsecutiveFailures =
      'ad_sdk_provider_failover_consecutive_failures';
  static const String _keyProviderFailoverLastProviderTag =
      'ad_sdk_provider_failover_last_provider_tag';

  int getProviderFailoverConsecutiveFailures() =>
      _prefs?.getInt(_keyProviderFailoverConsecutiveFailures) ?? 0;

  Future<void> setProviderFailoverConsecutiveFailures(int count) async {
    await _prefs?.setInt(_keyProviderFailoverConsecutiveFailures, count);
  }

  String? getProviderFailoverLastProviderTag() =>
      _prefs?.getString(_keyProviderFailoverLastProviderTag);

  Future<void> setProviderFailoverLastProviderTag(String? tag) async {
    if (tag == null) {
      await _prefs?.remove(_keyProviderFailoverLastProviderTag);
    } else {
      await _prefs?.setString(_keyProviderFailoverLastProviderTag, tag);
    }
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

  /// Round-27 backlog B1 — exposed so `AdManager.experimentBucket` can mint
  /// an id in the same format for its pre-bootstrap fallback (see
  /// [seedExperimentInstallIdIfAbsent]).
  static String generateRandomId() => _generateRandomId();

  /// Round-27 backlog B1 — a caller that generated an id BEFORE this
  /// singleton was bootstrapped (there is no synchronous path to
  /// `SharedPreferences` on first read) hands it over here once bootstrap
  /// completes, so this device's id is stable from its very first call
  /// onward instead of a second random id winning the race on first real
  /// read. No-op if something already persisted a real id first.
  void seedExperimentInstallIdIfAbsent(String id) {
    if (_experimentInstallIdCache != null) return;
    final persisted = _prefs?.getString(_keyExperimentInstallId);
    if (persisted != null && persisted.isNotEmpty) return;
    _experimentInstallIdCache = id;
    unawaited(_prefs?.setString(_keyExperimentInstallId, id));
  }

  // ─── Fill-rate/eCPM 7-day baseline (T97) ─────────────────────────────────
  // One JSON blob keyed by ISO date ('YYYY-MM-DD') then AdSlotType.name,
  // each holding {attempts, successes, revenueMicros, revenueCount}. Pruned
  // to the last [_fillRateBaselineDays] on every read — same "one blob,
  // rolled over lazily on access" shape as the per-placement counts above,
  // just keyed by day instead of by placement.

  static const String _keyFillRateBaselineHistory =
      'ad_sdk_fill_rate_baseline_history_v1';
  static const int _fillRateBaselineDays = 7;

  /// `{date: {slotTypeName: {attempts, successes, revenueMicros,
  /// revenueCount}}}`, already pruned to the last [_fillRateBaselineDays]
  /// calendar days. Corrupt storage degrades to an empty history (no
  /// baseline to compare against, never a fabricated one).
  Map<String, Map<String, Map<String, int>>> getFillRateBaselineHistory() {
    final raw = _prefs?.getString(_keyFillRateBaselineHistory);
    if (raw == null) return {};
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final cutoff =
          DateTime.now().subtract(const Duration(days: _fillRateBaselineDays));
      final result = <String, Map<String, Map<String, int>>>{};
      decoded.forEach((date, perType) {
        final parsed = DateTime.tryParse(date);
        if (parsed == null || parsed.isBefore(cutoff)) return;
        final typeMap = <String, Map<String, int>>{};
        (perType as Map<String, dynamic>).forEach((type, counts) {
          typeMap[type] = (counts as Map<String, dynamic>)
              .map((k, v) => MapEntry(k, v as int));
        });
        result[date] = typeMap;
      });
      return result;
    } catch (e) {
      SafeLogger.w(_tag, 'discarding corrupt fill-rate baseline history: $e');
      return {};
    }
  }

  /// T101 — test-only hook: when set, awaited right before the write inside
  /// [recordFillRateBaselineSample], to reproduce the real-device timing gap
  /// (genuine async platform-channel I/O) that the in-memory
  /// `SharedPreferences` mock is too fast to ever exhibit on its own.
  @visibleForTesting
  static Duration? debugFillRateWriteDelay;

  /// T101 — chains every [recordFillRateBaselineSample] write so the next
  /// call's read-modify-write only starts after the previous one's write has
  /// landed. Without this, two samples fired close together (e.g. a load
  /// event immediately followed by a revenue event) both read the SAME
  /// on-disk snapshot, and whichever write completes last silently discards
  /// the other's delta — same idiom as `AdEventLog._persistChain`.
  Future<void> _fillRateBaselineChain = Future.value();

  /// Adds today's [attempts]/[successes]/[revenueMicros]/[revenueCount] deltas
  /// (each defaulting to 0 — callers pass only what changed) onto today's
  /// bucket for [slotTypeName], creating it if absent.
  Future<void> recordFillRateBaselineSample({
    required String slotTypeName,
    int attempts = 0,
    int successes = 0,
    int revenueMicros = 0,
    int revenueCount = 0,
  }) {
    final result = _fillRateBaselineChain.then((_) =>
        _recordFillRateBaselineSampleNow(
          slotTypeName: slotTypeName,
          attempts: attempts,
          successes: successes,
          revenueMicros: revenueMicros,
          revenueCount: revenueCount,
        ));
    _fillRateBaselineChain = result.catchError((e) {
      SafeLogger.w(_tag, 'fill-rate baseline write failed: $e');
    });
    return result;
  }

  Future<void> _recordFillRateBaselineSampleNow({
    required String slotTypeName,
    required int attempts,
    required int successes,
    required int revenueMicros,
    required int revenueCount,
  }) async {
    final today = DateTime.now().toIso8601String().substring(0, 10);
    final history = getFillRateBaselineHistory(); // already pruned
    final todayMap = Map<String, Map<String, int>>.from(history[today] ?? {});
    final existing = Map<String, int>.from(todayMap[slotTypeName] ??
        {'attempts': 0, 'successes': 0, 'revenueMicros': 0, 'revenueCount': 0});
    existing['attempts'] = (existing['attempts'] ?? 0) + attempts;
    existing['successes'] = (existing['successes'] ?? 0) + successes;
    existing['revenueMicros'] = (existing['revenueMicros'] ?? 0) + revenueMicros;
    existing['revenueCount'] = (existing['revenueCount'] ?? 0) + revenueCount;
    todayMap[slotTypeName] = existing;
    history[today] = todayMap;
    final delay = debugFillRateWriteDelay;
    if (delay != null) await Future<void>.delayed(delay);
    await _prefs?.setString(_keyFillRateBaselineHistory, jsonEncode(history));
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

  // Round-7 audit, MAJOR — the Ed25519 public key the cached CRL above last
  // verified against, remembered so `VipManager.load()` can re-verify and
  // apply that CACHED CRL at startup without the host having to hand the key
  // over again. Storing it costs nothing: it is a PUBLIC key, it already ships
  // inside the app binary, and a CRL can only ever narrow an entitlement — an
  // attacker who swapped this value would just be choosing not to be revoked,
  // which deleting the cache already achieves.

  static const String _keyVipRevocationKey = 'ad_sdk_vip_revocation_pubkey_v1';

  String? getVipRevocationPublicKey() =>
      _prefs?.getString(_keyVipRevocationKey);

  Future<void> setVipRevocationPublicKey(String publicKeyBase64) async {
    await _prefs?.setString(_keyVipRevocationKey, publicKeyBase64);
  }

  // Round-25 QC round 22 (`codex`, MAJOR) — the raw CRL and the public key it
  // was verified against are ONE fact, and storing them as two keys made them
  // separable: a process death between the two writes, or two managers
  // interleaving their writes, left a CRL paired with the wrong key. Nothing
  // ever noticed — the next launch simply failed to verify the cached CRL and
  // fell open with an EMPTY revoked set, so a refunded or resold key was
  // redeemable again until some later refresh happened to succeed. One value,
  // one write: a torn write can only lose the update, never mismatch it.
  static const String _keyVipRevocationPair = 'ad_sdk_vip_revocation_v2';

  /// The cached CRL together with the key it verified under, or null when
  /// nothing usable is stored.
  ///
  /// Falls back to the pre-v2 pair of keys so an app upgrading in place keeps
  /// its cache; that pair can be mismatched, which is exactly what the read
  /// below cannot detect and the caller's signature check will.
  ({String raw, String publicKey})? getVipRevocationCache() {
    final packed = _prefs?.getString(_keyVipRevocationPair);
    if (packed != null) {
      try {
        final map = jsonDecode(packed);
        if (map is Map) {
          final raw = map['raw'];
          final key = map['key'];
          if (raw is String && key is String && raw.isNotEmpty && key.isNotEmpty) {
            return (raw: raw, publicKey: key);
          }
        }
      } catch (e) {
        SafeLogger.w('AdPreferences', 'VIP revocation cache unreadable: $e');
      }
      // A present-but-unusable v2 value is a final answer: falling back to the
      // legacy keys here would resurrect exactly the stale pair v2 replaced.
      return null;
    }
    final raw = _prefs?.getString(_keyVipRevocationCache);
    final key = _prefs?.getString(_keyVipRevocationKey);
    if (raw == null || key == null) return null;
    return (raw: raw, publicKey: key);
  }

  Future<void> setVipRevocationCache({
    required String raw,
    required String publicKey,
  }) async {
    await _prefs?.setString(_keyVipRevocationPair,
        jsonEncode(<String, String>{'raw': raw, 'key': publicKey}));
  }
}
