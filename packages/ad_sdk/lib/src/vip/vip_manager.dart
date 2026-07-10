import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';

import '../config/ad_config.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import '_redeemed_key_ledger.dart';
import 'signed_vip_key.dart';
import 'vip_dialog.dart';
import 'vip_dialog_strings.dart';
import 'vip_entry.dart';

/// VIP management — Phase 4 feature.
///
/// Stores [VipEntry] list in SharedPreferences. A device is "VIP" if any
/// entry's `expiresAt` is in the future. While VIP is active, [AdManager]
/// short-circuits **every** ad type (banner, app-open, interstitial, rewarded).
///
/// API:
/// - [redeemVip] — full UI flow with Cupertino dialog (loading → success/failed).
/// - [addVip] — headless variant for scripted tests / restore-purchase flows.
/// - [revokeVip] — remove a specific key.
/// - [revokeAll] — wipe everything.
/// - [isActive] / [expiresAt] / [activeStream] — reactive state for the host app.
///
/// Conflict policy (Q14A — latest expiry wins): adding a key that already
/// exists keeps the entry whose `expiresAt` is the **latest** of the two.
class VipManager {
  VipManager(
    this._prefs, {
    this.maxStackDuration,
    this.graceNudgeThreshold = const Duration(hours: 24),
    RedeemedKeyLedger? redeemedKeyLedger,
  }) : _redeemedKeyLedger = redeemedKeyLedger ?? RedeemedKeyLedger();

  static const String _tag = 'VipManager';

  final AdPreferences _prefs;

  /// Durable (iOS Keychain) backstop for redeemed signed-key ids — survives
  /// reinstall, unlike `_prefs`'s SharedPreferences-backed ledger. See
  /// `_redeemed_key_ledger.dart`.
  final RedeemedKeyLedger _redeemedKeyLedger;

  /// Optional cap on the total window produced by [addVip] stacking — sourced
  /// from `AdConfig.maxVipStackDuration`. `null` = uncapped. See [addVip].
  final Duration? maxStackDuration;

  /// How long before an active entry's [expiresAt] the grace-period nudge
  /// becomes due. Defaults to 24h; overridable (mainly for tests).
  final Duration graceNudgeThreshold;

  final List<VipEntry> _entries = [];
  final ValueNotifier<bool> _activeNotifier = ValueNotifier<bool>(false);
  final StreamController<bool> _activeStream =
      StreamController<bool>.broadcast();

  /// True once the active VIP window's remaining time has crossed
  /// [graceNudgeThreshold] and hasn't been acknowledged yet for the current
  /// [expiresAt]. See [acknowledgeGraceNudge].
  final ValueNotifier<bool> _graceNudgeDueNotifier = ValueNotifier<bool>(false);

  /// Serialises every prefs write — concurrent `addVip` / `revokeVip` calls
  /// would otherwise race. Each save reads `_entries` at the moment its
  /// queued task runs (capturing the latest state), and waits for the
  /// previous save to finish.
  Future<void> _saveQueue = Future.value();

  /// Concurrency guard for [redeemVip] — a double-tap would otherwise stack
  /// two verifying dialogs and confuse the navigator pop sequence.
  bool _redeemInFlight = false;

  /// Key ids currently mid-redeem in [redeemSignedKey]. The check + insert is
  /// synchronous (no await between), so in Dart's single-threaded model a
  /// concurrent double-tap of the same key is rejected before it can grant
  /// twice — the SDK enforces one-time-use, not just the host UI.
  final Set<String> _signedKidsInFlight = <String>{};

  /// One-shot timer fired at the earliest [VipEntry.expiresAt] across active
  /// entries. When it fires we purge the expired entry, refresh the active
  /// notifier (which flips `true → false` if no entries remain active), and
  /// re-arm for the next-soonest expiry.
  ///
  /// Without this timer the active state would only refresh on
  /// [load]/[addVip]/[revokeVip]/[revokeAll] — meaning a user holding the
  /// app open past the first-install grace expiry would stay falsely VIP
  /// until next launch. The timer fixes that mid-session UX surprise.
  Timer? _expiryTimer;

  /// True if at least one entry is currently active.
  bool get isActive => _activeNotifier.value;

  /// Listenable variant — subscribe via `ValueListenableBuilder`.
  ValueListenable<bool> get activeListenable => _activeNotifier;

  /// Stream emitting on every active-state change.
  Stream<bool> get activeStream => _activeStream.stream;

  /// Latest expiry across all active entries, or null if none active.
  DateTime? get expiresAt {
    DateTime? latest;
    for (final e in _entries) {
      if (!e.isActive) continue;
      if (latest == null || e.expiresAt.isAfter(latest)) latest = e.expiresAt;
    }
    return latest;
  }

  /// Read-only snapshot of all entries (for UI listing).
  List<VipEntry> get entries => List.unmodifiable(_entries);

  /// Listenable — true once the active VIP window's remaining time has
  /// crossed [graceNudgeThreshold] and hasn't been acknowledged yet for the
  /// current [expiresAt]. Host UI should show a one-time nudge pointing at
  /// the redeem/watch-ad-to-extend flow, then call [acknowledgeGraceNudge].
  ValueListenable<bool> get graceNudgeDueListenable => _graceNudgeDueNotifier;

  /// Marks the current [expiresAt] as acknowledged so the nudge stops being
  /// due — until a later stack/redeem produces a new (different) expiry.
  void acknowledgeGraceNudge() {
    final exp = expiresAt;
    if (exp != null) {
      unawaited(_prefs.setVipGraceNudgeAckExpiryMs(exp.millisecondsSinceEpoch));
    }
    _graceNudgeDueNotifier.value = false;
  }

  void _refreshGraceNudge() {
    final exp = expiresAt;
    final now = DateTime.now();
    final due = isActive &&
        exp != null &&
        exp.isAfter(now) &&
        exp.difference(now) <= graceNudgeThreshold &&
        _prefs.getVipGraceNudgeAckExpiryMs() != exp.millisecondsSinceEpoch;
    if (_graceNudgeDueNotifier.value != due) {
      _graceNudgeDueNotifier.value = due;
      SafeLogger.d(_tag, 'grace nudge due: $due');
    }
  }

  /// Normalise the user-supplied VIP key — trim + uppercase. Avoids
  /// accidental whitespace mismatches.
  static String normaliseKey(String raw) => raw.trim().toUpperCase();

  // ───────────────────────────────────────────────────────────────────────────
  //  LOAD + MIGRATE
  // ───────────────────────────────────────────────────────────────────────────

  /// Load entries from prefs.
  ///
  /// If 1.x GAID list is present and 2.x migration has not yet run, convert
  /// the GAIDs that match the [currentDeviceGaid] to entries with year-2099
  /// expiry (Q15A — auto-migrate, treat as effectively permanent).
  ///
  /// **Critical**: 1.x semantic was per-device (each device's prefs held the
  /// list of *VIP-eligible* GAIDs, and the device was VIP only when its own
  /// GAID matched one of them). Naively migrating every GAID would mark
  /// *every* device VIP — that's why we filter against [currentDeviceGaid].
  Future<void> load({String currentDeviceGaid = ''}) async {
    _entries
      ..clear()
      ..addAll(VipEntry.decodeList(_prefs.getVipEntriesRaw()));

    if (!_prefs.isVipMigrated()) {
      final legacyGaids = _prefs.getGAIDList();
      if (legacyGaids.isNotEmpty && currentDeviceGaid.isNotEmpty) {
        final myGaid = normaliseKey(currentDeviceGaid);
        final farFuture = DateTime(2099, 12, 31);
        final now = DateTime.now();
        var migrated = 0;
        for (final gaid in legacyGaids) {
          if (gaid.trim().isEmpty) continue;
          if (normaliseKey(gaid) != myGaid) continue;
          _entries.add(VipEntry(
            key: 'LEGACY_${normaliseKey(gaid)}',
            expiresAt: farFuture,
            grantedAt: now,
          ));
          migrated++;
        }
        if (migrated > 0) {
          SafeLogger.d(_tag,
              'migrated $migrated legacy GAID(s) for this device → entries');
          await _save();
        }
      }
      await _prefs.markVipMigrated();
    }
    _purgeExpired();
    _refreshActive();
    _scheduleNextExpiry();
    SafeLogger.d(_tag, 'load() entries=${_entries.length} active=$isActive');
  }

  Future<void> _save() {
    final task = _saveQueue.then((_) async {
      await _prefs.setVipEntriesRaw(VipEntry.encodeList(_entries));
    });
    // Catch errors so the queue keeps working even if one save fails.
    _saveQueue = task.catchError((Object e) {
      SafeLogger.w(_tag, '_save threw: $e');
    });
    return task;
  }

  void _purgeExpired() {
    final before = _entries.length;
    _entries.removeWhere((e) => !e.isActive);
    if (_entries.length != before) {
      SafeLogger.d(_tag, 'purgeExpired: removed ${before - _entries.length}');
      unawaited(_save());
    }
  }

  void _refreshActive() {
    final wasActive = _activeNotifier.value;
    final nowActive = _entries.any((e) => e.isActive);
    if (wasActive != nowActive) {
      _activeNotifier.value = nowActive;
      if (!_activeStream.isClosed) _activeStream.add(nowActive);
      SafeLogger.d(_tag, 'active state changed: $wasActive → $nowActive');
    }
    // Independent of whether active-state itself flipped — remaining time
    // alone can cross the grace-nudge threshold while still active.
    _refreshGraceNudge();
  }

  /// Re-arm [_expiryTimer] for whichever comes first: the soonest active
  /// entry's `expiresAt`, or the moment the grace-nudge threshold will next
  /// be crossed. Both share one timer/handler — [_handleExpiry] recomputes
  /// everything on fire regardless of which reason woke it. Cancels any
  /// existing timer first; if neither is pending, the timer stays cancelled.
  void _scheduleNextExpiry() {
    _expiryTimer?.cancel();
    _expiryTimer = null;

    DateTime? earliest;
    for (final e in _entries) {
      if (!e.isActive) continue;
      if (earliest == null || e.expiresAt.isBefore(earliest)) {
        earliest = e.expiresAt;
      }
    }

    final exp = expiresAt;
    if (exp != null) {
      final nudgeFireAt = exp.subtract(graceNudgeThreshold);
      if (nudgeFireAt.isAfter(DateTime.now()) &&
          (earliest == null || nudgeFireAt.isBefore(earliest))) {
        earliest = nudgeFireAt;
      }
    }
    if (earliest == null) return;

    final delay = earliest.difference(DateTime.now());
    if (delay <= Duration.zero) {
      // Already expired (clock skew or scheduling lag) — handle on next
      // microtask so we don't reentrantly call _purgeExpired.
      Future.microtask(_handleExpiry);
      return;
    }
    SafeLogger.d(_tag, () => '⏲️ next VIP timer event in ${delay.inSeconds}s');
    _expiryTimer = Timer(delay, _handleExpiry);
  }

  void _handleExpiry() {
    _expiryTimer = null;
    SafeLogger.d(_tag, '⏰ VIP entry expired — purging + refreshing');
    _purgeExpired();
    _refreshActive();
    // Re-arm for the next-soonest entry (if any).
    _scheduleNextExpiry();
  }

  // ───────────────────────────────────────────────────────────────────────────
  //  REDEEM / ADD / REVOKE
  // ───────────────────────────────────────────────────────────────────────────

  /// Headless add. Skips the dialog UI and any validator. Use for
  /// restore-purchase or scripted tests. Returns the saved entry.
  ///
  /// Conflict / accumulation handling:
  /// - [stack] == false (default, **Q14A — latest expiry wins**): when an entry
  ///   with the same [key] exists, the new `now + duration` replaces it only if
  ///   it expires later; otherwise the existing (longer) entry is kept untouched.
  /// - [stack] == true (**global accumulate / cộng dồn toàn cục**): [duration]
  ///   is added on top of the **latest expiry across ALL active entries** (any
  ///   source — redeem key or watch-ad), so every grant extends one growing VIP
  ///   window. E.g. with ~6 active days, redeeming a 30-day code yields ~36 days.
  ///   The just-granted [key]'s entry becomes the new latest (created if new,
  ///   updated if it already existed) and its `grantedAt` resets to now. The
  ///   result is clamped to `now + [maxStackDuration]` when that cap is set.
  ///
  /// [duration] must be strictly positive — a zero or negative duration would
  /// silently create a dead entry (`stack: false`, expires at/before grant)
  /// or invert the stacking base (`stack: true`, pulling the window
  /// backwards). Debug builds `assert` on this; release builds reject the
  /// call by returning the current entry for [key] unchanged (or a
  /// same-instant dead stub if none exists yet) without mutating state or
  /// persisting — matching this method's existing "no-op returns the
  /// untouched entry" convention for the latest-expiry-wins branch above.
  Future<VipEntry> addVip({
    required String key,
    required Duration duration,
    bool stack = false,
  }) async {
    final norm = normaliseKey(key);
    final now = DateTime.now();
    assert(duration > Duration.zero,
        'VipManager.addVip: duration must be > 0 (got $duration) for key=$norm');
    if (duration <= Duration.zero) {
      SafeLogger.w(_tag,
          'addVip: rejected non-positive duration ($duration) for key=$norm — no-op');
      final existingEntry = _entries.firstWhere((e) => e.key == norm,
          orElse: () => VipEntry(key: norm, expiresAt: now, grantedAt: now));
      return existingEntry;
    }
    // Eagerly drop already-expired entries before adding — keeps persistence
    // from accumulating stale rows between the periodic expiry-timer purges.
    _purgeExpired();
    final existing = _entries.indexWhere((e) => e.key == norm);

    if (stack) {
      // Global stacking: extend from the latest expiry across ALL active
      // entries (not just this key) so grants from every source add up.
      var base = now;
      for (final e in _entries) {
        if (e.isActive && e.expiresAt.isAfter(base)) base = e.expiresAt;
      }
      var newExpiry = base.add(duration);
      // Clamp to the optional total-window cap.
      final cap = maxStackDuration;
      if (cap != null) {
        final capExpiry = now.add(cap);
        if (newExpiry.isAfter(capExpiry)) {
          newExpiry = capExpiry;
          SafeLogger.d(_tag, 'addVip: stack clamped to cap ($cap) for $norm');
        }
      }
      final stacked = VipEntry(
        key: norm,
        expiresAt: newExpiry,
        grantedAt: now,
      );
      if (existing >= 0) {
        _entries[existing] = stacked;
      } else {
        _entries.add(stacked);
      }
      SafeLogger.d(_tag,
          'addVip: stacked ${stacked.key} (+${duration.inMinutes}m) → ${stacked.expiresAt}');
      await _save();
      _refreshActive();
      _scheduleNextExpiry();
      return stacked;
    }

    final newEntry = VipEntry(
      key: norm,
      expiresAt: now.add(duration),
      grantedAt: now,
    );
    if (existing >= 0) {
      // Q14A — latest expiry wins.
      final old = _entries[existing];
      if (newEntry.expiresAt.isAfter(old.expiresAt)) {
        _entries[existing] = newEntry;
        SafeLogger.d(_tag, 'addVip: replaced ${old.key} (later expiry wins)');
      } else {
        SafeLogger.d(_tag, 'addVip: kept existing ${old.key} (still later)');
        return old;
      }
    } else {
      _entries.add(newEntry);
      SafeLogger.d(
          _tag, 'addVip: added ${newEntry.key} until ${newEntry.expiresAt}');
    }
    await _save();
    _refreshActive();
    _scheduleNextExpiry();
    return newEntry;
  }

  /// Full UI flow:
  /// 1. Show "Verifying" Cupertino dialog.
  /// 2. Run `validator(key)` — if `null` in [AdConfig.vipKeyValidator], every
  ///    key is accepted (demo mode).
  /// 3. On success → save entry → show success dialog.
  /// 4. On failure / network error → show failed dialog.
  ///
  /// [duration] is forwarded to [addVip] as-is, so the same `duration > 0`
  /// guard applies (see [addVip]) — a non-positive duration is rejected
  /// there rather than silently redeeming a dead entry.
  ///
  /// Returns `true` only if the entry was saved and made active.
  ///
  /// [stack] forwards to [addVip]: when `true`, redeeming a key that is already
  /// active **adds** [duration] on top of the current window instead of the
  /// default latest-expiry-wins replacement. The success dialog reports the
  /// resulting (stacked) expiry.
  Future<bool> redeemVip(
    BuildContext context, {
    required String key,
    required Duration duration,
    required Future<bool> Function(String key)? validator,
    required VipDialogStrings strings,
    bool stack = false,
  }) async {
    if (_redeemInFlight) {
      SafeLogger.w(_tag, 'redeemVip ⏭️ already in flight — ignoring duplicate');
      return false;
    }
    _redeemInFlight = true;
    try {
      final norm = normaliseKey(key);
      if (norm.isEmpty) {
        await _showFailed(context, strings, strings.failedMessage);
        return false;
      }

      // Capture the root NavigatorState BEFORE the await — context.mounted may
      // flip false during the validator wait, but the NavigatorState itself
      // outlives any single screen and is safe to call.
      final navigator = Navigator.of(context, rootNavigator: true);

      // Fire-and-forget the verifying dialog: its future completes when the
      // dialog is popped. We pop it ourselves below; awaiting that future
      // afterwards isn't necessary and would hang if the pop ever fails.
      unawaited(showVipVerifyingDialog(context, strings));

      bool ok = false;
      String? errorMsg;
      try {
        ok = await _runValidator(norm, validator);
      } catch (e) {
        SafeLogger.w(_tag, 'redeemVip validator threw: $e');
        errorMsg = strings.networkErrorMessage;
      }

      try {
        navigator.pop();
      } catch (e) {
        SafeLogger.w(_tag, 'redeemVip pop threw: $e');
      }

      if (!ok) {
        if (context.mounted) {
          await _showFailed(
              context, strings, errorMsg ?? strings.failedMessage);
        }
        return false;
      }

      final entry = await addVip(key: norm, duration: duration, stack: stack);
      if (context.mounted) {
        await showVipSuccessDialog(context, strings, entry);
      }
      return true;
    } finally {
      _redeemInFlight = false;
    }
  }

  /// Redeem an **offline signed** VIP key (T18). The key is verified with the
  /// embedded Ed25519 [publicKeyBase64] — no network, no shared secret, and a
  /// decompiler cannot forge new keys. The VIP window is read from the key
  /// itself. Enforces **per-device one-time-use**: the same key id cannot be
  /// redeemed twice on this device.
  ///
  /// Returns a [SignedVipRedeemResult] describing success / invalid / already
  /// used. On success the grant [stack]s onto the current window by default.
  Future<SignedVipRedeemResult> redeemSignedKey(
    String code, {
    required String publicKeyBase64,
    bool stack = true,
  }) async {
    SignedVipKey parsed;
    try {
      parsed = await verifySignedVipKey(code, publicKeyBase64: publicKeyBase64);
    } on VipKeyException catch (e) {
      SafeLogger.w(_tag, 'redeemSignedKey invalid: ${e.message}');
      return SignedVipRedeemResult.invalid(e.message);
    } catch (e) {
      SafeLogger.w(_tag, 'redeemSignedKey error: $e');
      return SignedVipRedeemResult.invalid('$e');
    }

    // Atomic one-time-use claim: check persisted + in-flight, then claim the
    // kid synchronously (no await in between) so a concurrent double-redeem of
    // the same key can't slip through and grant twice.
    if (_prefs.isVipKeyIdRedeemed(parsed.keyId) ||
        _signedKidsInFlight.contains(parsed.keyId)) {
      SafeLogger.d(_tag, 'redeemSignedKey: kid ${parsed.keyId} already used');
      return const SignedVipRedeemResult.alreadyUsed();
    }
    _signedKidsInFlight.add(parsed.keyId);

    try {
      // Durable cross-reinstall check (iOS Keychain; no-op elsewhere) — the
      // in-flight Set above already claimed the kid synchronously so a
      // same-process double-tap can't slip through; this catches a kid
      // that was redeemed, then the app data/`_prefs` ledger was wiped by
      // an uninstall + reinstall.
      if (await _redeemedKeyLedger.isRedeemed(parsed.keyId)) {
        SafeLogger.d(_tag,
            'redeemSignedKey: kid ${parsed.keyId} already used (durable ledger)');
        return const SignedVipRedeemResult.alreadyUsed();
      }

      final entry = await addVip(
        key: 'SIGNED_${parsed.keyId}',
        duration: parsed.duration,
        stack: stack,
      );
      await _prefs.addRedeemedVipKeyId(parsed.keyId);
      await _redeemedKeyLedger.markRedeemed(parsed.keyId);
      SafeLogger.d(
          _tag,
          () =>
              '🔑 redeemSignedKey ok kid=${parsed.keyId} +${parsed.duration}');
      return SignedVipRedeemResult.success(entry);
    } finally {
      _signedKidsInFlight.remove(parsed.keyId);
    }
  }

  Future<bool> _runValidator(
    String key,
    Future<bool> Function(String key)? validator,
  ) async {
    if (validator == null) {
      // No validator wired — demo mode.
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return true;
    }
    return validator(key);
  }

  Future<void> _showFailed(
    BuildContext context,
    VipDialogStrings strings,
    String message,
  ) =>
      showVipFailedDialog(context, strings, message);

  /// Remove a specific entry.
  Future<void> revokeVip(String key) async {
    final norm = normaliseKey(key);
    final n = _entries.length;
    _entries.removeWhere((e) => e.key == norm);
    if (_entries.length != n) {
      SafeLogger.d(_tag, 'revokeVip: removed $norm');
      await _save();
      _refreshActive();
      _scheduleNextExpiry();
    }
  }

  /// Wipe all entries.
  Future<void> revokeAll() async {
    _entries.clear();
    SafeLogger.d(_tag, 'revokeAll: cleared');
    await _save();
    _refreshActive();
    _scheduleNextExpiry();
  }

  /// Cleanup. After this the manager can no longer fire stream events.
  void dispose() {
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _activeNotifier.dispose();
    _graceNudgeDueNotifier.dispose();
    _activeStream.close();
  }
}
