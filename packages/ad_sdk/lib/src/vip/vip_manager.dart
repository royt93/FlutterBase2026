import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/foundation.dart';
import 'package:package_info_plus/package_info_plus.dart';

import '../config/ad_config.dart';
import '../utils/ad_preferences.dart';
import '../utils/release_mode.dart';
import '../utils/safe_logger.dart';
import '_redeemed_key_ledger.dart';
import '_vip_entries_store.dart';
import 'signed_vip_key.dart';
import 'vip_dialog.dart';
import 'vip_dialog_strings.dart';
import 'vip_entry.dart';
import 'vip_revocation_provider.dart';

/// VIP management — Phase 4 feature.
///
/// Stores [VipEntry] list via [VipEntriesStore] (flutter_secure_storage). A
/// device is "VIP" if any
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
  // `isRelease` isn't `@visibleForTesting` here for the same barrel-export
  // reason covered in `AdSafetyConfig.applyDryRunReleaseGuard`'s doc comment —
  // safety comes from `isActuallyRelease`, not the annotation. `AdManager`
  // (production code) legitimately forwards its own `isRelease` param here.
  VipManager(
    this._prefs, {
    this.maxStackDuration,
    this.graceNudgeThreshold = const Duration(hours: 24),
    RedeemedKeyLedger? redeemedKeyLedger,
    VipEntriesStore? vipEntriesStore,
    bool isRelease = kReleaseMode,
    bool Function()? isConnectedCheck,
  })  : _redeemedKeyLedger = redeemedKeyLedger ?? RedeemedKeyLedger(),
        _vipEntriesStore = vipEntriesStore ?? VipEntriesStore(_prefs),
        _isRelease = isRelease,
        // Default fail-open (`true`) — a caller that doesn't wire real
        // connectivity (raw unit tests, hosts not yet on this SDK version)
        // keeps today's behaviour. `AdManager` wires its own safe
        // `isConnected` getter here in production, see [redeemSignedKey].
        _isConnectedCheck = isConnectedCheck ?? (() => true),
        _sessionAnchorRealMs = DateTime.now().millisecondsSinceEpoch,
        _sessionClockStopwatch = Stopwatch()..start();

  static const String _tag = 'VipManager';

  final AdPreferences _prefs;

  /// Reports whether the device currently has network connectivity. Gates
  /// [redeemSignedKey] — even though signature verification itself is fully
  /// offline (Ed25519, no server call), requiring a network check at the
  /// point of redemption was an explicit product decision to discourage
  /// sharing one signed key across many devices with no connectivity signal
  /// at all. Wired to `AdManager`'s own connectivity getter in production.
  final bool Function() _isConnectedCheck;

  /// Wall-clock reading taken at construction (and re-taken on every
  /// foreground resume by [resyncSessionClock]), paired with a monotonic
  /// stopwatch (re)started alongside it. Together they let [_effectiveNow]
  /// tell "device clock actually progressed" apart from "the wall clock
  /// jumped" *within the current foreground session* — see [_effectiveNow]'s
  /// doc comment for why that matters, and [resyncSessionClock] for why this
  /// resets on resume rather than staying pinned to construction time.
  int _sessionAnchorRealMs;
  Stopwatch _sessionClockStopwatch;

  /// Durable (iOS Keychain) backstop for redeemed signed-key ids — survives
  /// reinstall, unlike `_prefs`'s SharedPreferences-backed ledger. See
  /// `_redeemed_key_ledger.dart`.
  final RedeemedKeyLedger _redeemedKeyLedger;

  /// Encrypted-at-rest storage (Keychain/Keystore) for the VIP entries list.
  /// See `_vip_entries_store.dart`.
  final VipEntriesStore _vipEntriesStore;

  /// Test-only override so [_runValidator]'s release-build guard can be
  /// exercised under `flutter test` without a real release build.
  final bool _isRelease;

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

  /// True right after [AdManager] grants a first-install VIP grace window,
  /// until the host acknowledges it. See [notifyFirstInstallGrant] and
  /// [acknowledgeFirstInstallGrant].
  final ValueNotifier<bool> _firstInstallGrantDueNotifier =
      ValueNotifier<bool>(false);

  /// Duration of the most recent first-install grant, for the host's notice
  /// copy (e.g. "You got 24h ad-free!"). Null until [notifyFirstInstallGrant]
  /// is called.
  Duration? _lastFirstInstallGrantDuration;

  /// Serialises every prefs write — concurrent `addVip` / `revokeVip` calls
  /// would otherwise race. Each save reads `_entries` at the moment its
  /// queued task runs (capturing the latest state), and waits for the
  /// previous save to finish.
  ///
  /// Round-10 QC, MAJOR — **static on purpose.** The queue used to be
  /// per-instance, but the thing it protects is not: every manager writes the
  /// same secure-storage key. On `AdManager.destroy()` + `initialize()` the old
  /// manager could have a write already parked inside `setRaw()`; the
  /// replacement had its own empty queue, so it read, revoked, and wrote — and
  /// then the old write landed on top and resurrected the entitlement the live
  /// manager had just revoked. One process-wide queue makes the last writer
  /// actually last.
  static Future<void> _saveQueue = Future<void>.value();

  /// Drops the process-wide save ordering. Tests only — a test that parks a
  /// write and never releases it would otherwise wedge every later test.
  @visibleForTesting
  static void resetSaveQueueForTest() {
    _saveQueue = Future<void>.value();
  }

  /// This instance's own most recent save. [_load] waits on THIS, never on the
  /// process-wide [_saveQueue]: the global queue can hold a write parked by a
  /// manager this one never met (in tests, a manager from a previous test), and
  /// waiting on that would make every load pay the drain timeout for a write it
  /// has no stake in. What a load actually needs is that ITS OWN pending grants
  /// have landed before it trusts the disk.
  Future<void> _ownSaveTail = Future<void>.value();

  /// How long [load] waits for pending writes to land before giving up on
  /// them. Bounded because a wedged platform channel would otherwise hang
  /// `AdManager.initialize()` forever — see the drain in [_load].
  static const Duration kSaveDrainTimeout = Duration(seconds: 5);

  /// Concurrency guard for [redeemVip] — a double-tap would otherwise stack
  /// two verifying dialogs and confuse the navigator pop sequence.
  bool _redeemInFlight = false;

  /// `kid`s currently revoked, per the last verified CRL (T95) — either
  /// loaded from [_prefs]'s cache or freshly fetched by
  /// [refreshRevocationList]. Empty until either happens.
  Set<String> _revokedKeyIds = <String>{};

  /// `issuedAt` of the CRL currently backing [_revokedKeyIds], so
  /// [refreshRevocationList] can reject a replayed OLDER signed CRL.
  DateTime? _revocationIssuedAt;

  /// Guards the one-time load of any cached CRL from disk — see
  /// [_ensureCachedRevocationLoaded].
  bool _revocationCacheLoaded = false;

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

  /// Round-7 audit, MAJOR — retry schedule for a [load] whose secure-storage
  /// read FAILED (as opposed to reading fine and finding no VIP).
  ///
  /// Without it a single Keychain/Keystore error at startup cost a paying
  /// customer their entitlement for the whole session: `getRaw()` returned
  /// null, `load()` decoded an empty list, and nothing ever asked again. The
  /// common real cause is not a random blip but a locked device — Keychain
  /// data stored `first_unlock` is genuinely unreadable until the user unlocks
  /// once, which no in-line retry can wait out, so the retries are spread over
  /// the first minute of the session instead.
  static const List<Duration> _secureReadRetryDelays = <Duration>[
    Duration(seconds: 2),
    Duration(seconds: 10),
    Duration(seconds: 45),
  ];
  Timer? _readRetryTimer;
  int _readRetryIndex = 0;
  String _lastLoadGaid = '';

  /// Round-7 final QC (both reviewers, independently) — `dispose()` cancels a
  /// PENDING retry, but not a `load()` whose timer already fired and is now
  /// awaiting storage. That load used to come back and mutate entries, push the
  /// notifier, add to an already-closed stream and arm fresh timers, on a
  /// manager the host had thrown away — a leak with a heartbeat on any host
  /// that re-inits (`AdManager.destroy()` then `initialize()`).
  bool _disposed = false;

  /// Serialises [load] by invocation order. Two loads used to run concurrently
  /// (the host's own call plus a retry, or a re-init) and settle in completion
  /// order, each clearing `_entries` under the other's feet.
  Future<void> _loadQueue = Future<void>.value();

  /// True if at least one entry is currently active.
  bool get isActive => _activeNotifier.value;

  /// Listenable variant — subscribe via `ValueListenableBuilder`.
  ValueListenable<bool> get activeListenable => _activeNotifier;

  /// Stream emitting on every active-state change.
  Stream<bool> get activeStream => _activeStream.stream;

  /// Latest expiry across all active entries, or null if none active.
  ///
  /// **Side effect:** each read calls [_effectiveNow], which persists the
  /// current wall-clock time to disk as the new anti-clock-rollback
  /// high-water mark (unless the clock actually rolled back, in which case
  /// nothing is written). This is intentional and cheap for normal UI reads,
  /// but avoid polling this getter at high frequency (e.g. every frame/tick)
  /// — each read schedules a `SharedPreferences` write.
  DateTime? get expiresAt {
    final now = _effectiveNow();
    DateTime? latest;
    for (final e in _entries) {
      if (!e.isActiveAt(now)) continue;
      if (latest == null || e.expiresAt.isAfter(latest)) latest = e.expiresAt;
    }
    return latest;
  }

  /// Returns `DateTime.now()` clamped against the highest wall-clock time
  /// ever observed by this manager (persisted in [_prefs]). If the device
  /// clock has been rolled backwards since the last time we looked — the
  /// classic trial/VIP abuse move: let a grant expire in real time, then set
  /// the clock back into the granted window — this returns the high-water
  /// mark instead of the (lower) real clock, so [VipEntry.isActiveAt] still
  /// sees the entry as expired. Otherwise records and returns the real time.
  ///
  /// This is a client-side, fully-offline mitigation: it cannot detect a
  /// clock rolled back *before* the app was ever run on this device (no
  /// prior high-water mark exists yet), only reactivation attempts made
  /// after the app has already observed the later time once.
  ///
  /// Naively committing every forward-moving [DateTime.now] reading to the
  /// mark has a self-inflicted failure mode: if the wall clock jumps far
  /// forward (fat-fingered in Settings, a DST/NTP glitch, a QA test) and is
  /// then corrected back to the true time, the mark is now stuck in that
  /// bogus future — freezing every VIP entry's remaining time (or expiring
  /// it outright) until the *real* clock organically catches up, which can
  /// be a very long wait. To avoid committing a spurious jump, a forward
  /// reading is only trusted as-is when it's consistent with the monotonic
  /// [_sessionClockStopwatch] elapsed since this manager was constructed —
  /// i.e. wall-clock time and real elapsed time agree that this much time
  /// has actually passed. When they disagree (an in-session clock edit),
  /// the monotonic-anchored estimate is used instead, so the edit is never
  /// written to the high-water mark and self-corrects the moment the clock
  /// is fixed. This only covers edits made *while the app is foregrounded
  /// and this manager's clock anchor hasn't been resynced* — see
  /// [resyncSessionClock] for why a background/resume cycle deliberately
  /// resets this anchor rather than accumulating drift across it. A jump
  /// made, then the app killed and relaunched (or backgrounded and
  /// resumed), then corrected, anchors a fresh (bogus) session and isn't
  /// caught; that residual gap needs a native monotonic-uptime source to
  /// close and isn't attempted here.
  // KNOWN LIMITATION, DELIBERATELY NOT CLOSED (MJ9, decided 2026-08-22).
  // A clock set forward BEFORE this app's first ever launch is indistinguishable
  // from the truth: there is no prior high-water mark to contradict it, and with
  // the product's "VIP works fully offline, no server" constraint there is no
  // second time source to ask. The mark then stays parked in that bogus future
  // and an entry granted against it effectively never expires.
  //
  // Do not "fix" this by switching to a monotonic duration budget: `Stopwatch`
  // is the only monotonic clock in pure Dart and it dies with the process, so
  // the budget would stop draining across an app kill — turning every VIP
  // permanent, which is worse. Closing it properly needs a native uptime source
  // (see this method's doc comment), which would make this pure-Dart package a
  // plugin with native code.
  //
  // The worthwhile follow-up is NOT anti-cheat: it is capping how far ahead of
  // real time the mark is allowed to sit, which fixes the PAYING-customer case
  // in the doc comment above (an honest NTP/DST glitch while the app is closed
  // freezes or voids their remaining VIP). Rationale, rejected alternatives and
  // the trade-off are recorded in doc/audit/audit_claude.md § MJ9.
  DateTime _effectiveNow() {
    final real = DateTime.now();
    final expectedMs =
        _sessionAnchorRealMs + _sessionClockStopwatch.elapsedMilliseconds;
    const sessionDriftSlack = Duration(minutes: 10);
    final trusted = (real.millisecondsSinceEpoch - expectedMs).abs() <=
            sessionDriftSlack.inMilliseconds
        ? real
        : DateTime.fromMillisecondsSinceEpoch(expectedMs);

    final observedMs = _prefs.getVipMaxObservedClockMs();
    if (observedMs != null && observedMs > trusted.millisecondsSinceEpoch) {
      return DateTime.fromMillisecondsSinceEpoch(observedMs);
    }
    unawaited(_prefs.setVipMaxObservedClockMs(trusted.millisecondsSinceEpoch));
    return trusted;
  }

  /// Re-anchors [_effectiveNow]'s drift check to "now" — call on every
  /// foreground resume (wired from [AdManager.didChangeAppLifecycleState]).
  ///
  /// [Stopwatch] measures OS uptime (`CLOCK_MONOTONIC` on Android,
  /// `mach_absolute_time` on iOS), which **stops advancing while the device
  /// is asleep/suspended** — unlike [DateTime.now], which keeps advancing
  /// through sleep same as any wall clock. Without this resync, a phone
  /// merely being locked for longer than the drift slack makes
  /// [_effectiveNow] mistake that ordinary sleep gap for a wall-clock jump,
  /// discard the (correct) real time, and freeze the high-water mark at a
  /// stale value — silently extending VIP time on every lock/unlock cycle.
  /// Resetting the anchor on resume drops drift detection back to only
  /// covering edits made while the app is actively foregrounded, which is
  /// the scenario B3 was written for (see [_effectiveNow]'s doc comment).
  void resyncSessionClock() {
    _sessionAnchorRealMs = DateTime.now().millisecondsSinceEpoch;
    _sessionClockStopwatch = Stopwatch()..start();
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

  /// Listenable — true right after a first-install VIP grace window was
  /// granted (see `AdManager.initialize()`), until the host acknowledges it
  /// via [acknowledgeFirstInstallGrant]. Mirrors [graceNudgeDueListenable].
  ValueListenable<bool> get firstInstallGrantDueListenable =>
      _firstInstallGrantDueNotifier;

  /// Duration of the most recent first-install grant, or null if none
  /// happened this session. Read this from the [firstInstallGrantDueListenable]
  /// listener to build the notice copy.
  Duration? get lastFirstInstallGrantDuration => _lastFirstInstallGrantDuration;

  /// Called by [AdManager] right after granting the first-install VIP
  /// window. Not persisted like [acknowledgeGraceNudge] — this is a one-shot
  /// in-session signal, and the grant itself is already guarded by
  /// `AdPreferences.isFirstInstallGraceApplied()` so it naturally fires once
  /// per (legitimate) install.
  void notifyFirstInstallGrant(Duration duration) {
    _lastFirstInstallGrantDuration = duration;
    _firstInstallGrantDueNotifier.value = true;
  }

  /// Marks the current first-install grant notice as shown.
  void acknowledgeFirstInstallGrant() {
    _firstInstallGrantDueNotifier.value = false;
  }

  void _refreshGraceNudge() {
    final exp = expiresAt;
    final now = _effectiveNow();
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
  Future<void> load({String currentDeviceGaid = ''}) {
    final task = _loadQueue.then((_) => _load(currentDeviceGaid));
    // Keeps the queue usable after a failed load, exactly like `_save()`.
    _loadQueue = task.catchError((Object e) {
      SafeLogger.w(_tag, 'load threw: $e');
    });
    return task;
  }

  Future<void> _load(String currentDeviceGaid) async {
    if (_disposed) return;
    _lastLoadGaid = currentDeviceGaid;

    // Round-8 QC, MAJOR — the read is the one await nothing can cancel. By the
    // time a slow Keychain answers, two things may have changed:
    //
    //  * the host disposed this manager (below), or
    //  * a grant landed in memory (`_mutationEpoch` moved) — a redeem one
    //    second into the retry wait, say. `_refreshActive` cancels a retry that
    //    is still WAITING, but a retry whose timer already fired is a load in
    //    flight, and this method's first act is to clear `_entries`: it would
    //    wipe a live grant whose own `_save()` had not landed yet, exactly the
    //    bug the cancel was supposed to prevent.
    //
    // Whoever wrote last wins, and the in-memory state is by definition newer
    // than a read that started before it. So abandon the read, not the grant.
    // Round-9 QC, MAJOR — the epoch alone does not cover a QUEUED load. Load A
    // rejects its stale read correctly, but load B then starts, snapshots the
    // ALREADY-bumped epoch, and can still read storage before the grant's save
    // has landed: it accepts that read, clears the grant, and the next save
    // serialises the cleared list — the entitlement is gone from disk too.
    //
    // `_loadQueue` and `_saveQueue` are independent, so draining the save queue
    // first is what makes the read authoritative. Safe to await: `_save()`
    // hands the queue an already-caught future, so this cannot throw, and
    // nothing on the save side ever waits on a load.
    //
    // Snapshotted BEFORE the drain, not after: a grant landing *during* the
    // wait is exactly the case the epoch exists for, and a snapshot taken
    // afterwards would miss it.
    final epochBefore = _mutationEpoch;
    var drained = true;
    try {
      await _ownSaveTail.timeout(kSaveDrainTimeout);
    } catch (_) {
      // Bounded on purpose (round-10 QC, MAJOR): a platform write future that
      // never settles would otherwise hang every later load — and
      // `AdManager.initialize()` awaits one, so it would hang SDK startup.
      drained = false;
    }
    if (_disposed) return;
    if (!drained) {
      SafeLogger.w(
          _tag,
          'pending VIP writes did not land within '
          '${kSaveDrainTimeout.inSeconds}s — keeping the in-memory state and '
          'retrying rather than trusting a possibly stale read');
      _scheduleReadRetryIfNeeded(force: true);
      return;
    }
    final raw = await _vipEntriesStore.getRaw();
    if (_disposed) return;
    if (_mutationEpoch != epochBefore) {
      SafeLogger.w(
          _tag,
          'discarding a storage read that raced a live entitlement change — '
          'keeping the newer in-memory state');
      return;
    }
    _entries
      ..clear()
      ..addAll(VipEntry.decodeList(raw));

    // M6 — the entries came from the plaintext fallback on a device whose
    // secure storage works, which no legitimate write path produces (setRaw
    // only falls back when the secure write fails). The fallback's integrity
    // is an unkeyed checksum with a salt published in this package's source,
    // so a forged entry is cheap with root.
    //
    // Clamped rather than dropped, same reasoning as M5: a device whose
    // Keystore was broken at grant time and healed later leaves a GENUINE
    // entry in exactly this state, and the one-time-use ledger means that
    // customer cannot redeem their code again. So a real customer keeps a day
    // (and support has a window) while a forged "VIP until 2099" is worth a
    // day instead of forever.
    if (_vipEntriesStore.lastReadWasUntrustedFallback && _entries.isNotEmpty) {
      var clamped = 0;
      for (var i = 0; i < _entries.length; i++) {
        final e = _entries[i];
        // Round-7 audit, MAJOR — the cutoff is anchored to the entry's OWN
        // `grantedAt`, not to `now`. It used to be `now + window`, which meant
        // the 24h was measured from whenever the app happened to launch: if
        // the `_save()` below failed (the very case its catch below exists
        // for), the next launch re-read the same untouched plaintext line and
        // measured a fresh 24h from that launch. A rolling window, renewed
        // forever — exactly the hole the round-6 persist fix was meant to
        // close, still open through the failure branch. Anchoring to
        // `grantedAt` makes the clamp idempotent: the same forged line yields
        // the same absolute cutoff on every launch whether or not the write
        // ever lands, so the grant really is worth one day rather than
        // forever. A genuine grant from a device whose Keystore was broken at
        // redemption time gets its day from the redemption, which is what
        // "the customer keeps a day" was always supposed to mean.
        final cutoff = e.grantedAt.add(untrustedFallbackWindow);
        if (!e.expiresAt.isAfter(cutoff)) continue;
        _entries[i] =
            VipEntry(key: e.key, expiresAt: cutoff, grantedAt: e.grantedAt);
        clamped++;
      }
      if (clamped > 0) {
        SafeLogger.w(
            _tag,
            () => 'M6: clamped $clamped untrusted fallback grant(s) to '
                '${untrustedFallbackWindow.inHours}h');
        // Round-6 final QC — without this the clamp lived only in memory, so
        // every launch re-read the untouched forged line and granted a FRESH
        // 24h: a rolling window, renewed forever, and M6 blocked nothing. Both
        // reviewers found this independently. Persisting also moves the list
        // into secure storage when that works, so the next launch reads the
        // clamped value rather than the plaintext line at all.
        //
        // Guarded: `_save()` deliberately returns the un-caught task, so an
        // await here would throw straight out of `load()` — before
        // `_refreshActive()` — and a paying VIP whose disk write happened to
        // fail would be treated as non-VIP for the whole session. A storage
        // problem must not become an entitlement problem. The clamped entries
        // are valid in memory; failing to write them down is a reason to retry
        // later, not to revoke access now.
        try {
          await _save();
        } catch (e) {
          SafeLogger.w(
              _tag, 'M6: clamp persist failed ($e) — keeping RAM state');
        }
      }
    }

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
      // Round-10 QC, MINOR — never mark the one-shot 1.x migration done when
      // the write above may have been dropped (disposed mid-load): the flag
      // makes the next launch skip migration entirely, so the legacy
      // entitlement would be lost for good.
      if (_disposed) return;
      await _prefs.markVipMigrated();
    }
    // Round-7 audit, MAJOR — apply the cached CRL on EVERY startup, not only
    // on the paths that go through `refreshRevocationList`/`redeemSignedKey`.
    // Before this, a revoked grant that was already on disk full-length (the
    // process died between caching the CRL and clamping the grants, or the
    // clamp's own save failed) stayed full-length across every later launch
    // unless the host happened to refresh the CRL again — and a host that
    // refreshes daily, or a device that is offline, does not. The clamp is
    // idempotent, so running it here is free when there is nothing to do.
    final cachedCrlKey = _prefs.getVipRevocationPublicKey();
    if (cachedCrlKey != null) {
      // Guarded for the same reason the M6 clamp above is: `_clampRevokedEntries`
      // awaits an un-caught `_save()`, and a storage error must not throw out of
      // `load()` before `_refreshActive()` and cost a paying customer the
      // session. The clamp is valid in memory either way.
      try {
        await _ensureCachedRevocationLoaded(cachedCrlKey);
        await _clampRevokedEntries();
      } catch (e) {
        SafeLogger.w(_tag, 'startup CRL clamp failed ($e) — keeping RAM state');
      }
    }

    _purgeExpired();
    _refreshActive();
    _scheduleNextExpiry();
    _scheduleReadRetryIfNeeded();
    SafeLogger.d(_tag, 'load() entries=${_entries.length} active=$isActive');
  }

  /// Re-runs [load] shortly after a load that could not READ secure storage.
  ///
  /// Only when the read actually errored AND nothing was recovered from any
  /// other source: an empty list from a healthy store is a final answer, and a
  /// grant found via the fallback has already been through the M6 clamp above.
  /// Re-entering [load] rather than just re-reading is deliberate — every
  /// trust decision about what comes off disk lives there, and a second copy
  /// of it would be a second thing to keep correct.
  void _scheduleReadRetryIfNeeded({bool force = false}) {
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    if (_disposed) return;
    // `force` is the drain-timeout path in [_load]: there the read never even
    // ran, so `lastSecureReadErrored` says nothing, but the load still has to
    // be re-attempted or the session runs on whatever was in memory.
    if (!force &&
        (!_vipEntriesStore.lastSecureReadErrored || _entries.isNotEmpty)) {
      _readRetryIndex = 0;
      return;
    }
    if (_readRetryIndex >= _secureReadRetryDelays.length) {
      SafeLogger.w(
          _tag,
          'secure storage still unreadable after '
          '${_secureReadRetryDelays.length} retries — giving up for this '
          'session; a real VIP will be restored on the next launch');
      return;
    }
    final delay = _secureReadRetryDelays[_readRetryIndex++];
    SafeLogger.w(
        _tag,
        'secure storage read FAILED and no entries were recovered — '
        'retrying in ${delay.inSeconds}s rather than treating it as "no VIP"');
    _readRetryTimer = Timer(delay, () {
      _readRetryTimer = null;
      if (_disposed) return;
      // Round-8 QC, MINOR — `load()` deliberately returns the UN-caught task
      // (the queue keeps its own caught copy), so unawaiting it raw turns a
      // storage error on a retry into an unhandled async error, which in a
      // release build reaches the host's Flutter error handler as a crash
      // report for something this class already handles.
      unawaited(load(currentDeviceGaid: _lastLoadGaid).catchError((Object e) {
        SafeLogger.w(_tag, 'retry load failed: $e');
      }));
    });
  }

  /// Bumped by every write to [_entries] that does not come from [_load].
  ///
  /// Round-8 QC — see the epoch check in [_load]: this is what lets a load tell
  /// "nothing happened while I waited" from "a grant landed, my read is stale".
  int _mutationEpoch = 0;

  Future<void> _save() {
    // Round-9 QC, MAJOR — one guard in the shared write path rather than after
    // every await in `_load`. A manager the host has thrown away must never
    // write storage: on a destroy + re-init the replacement manager owns that
    // same key, so a late write from the discarded one resurrects entries the
    // live manager has already revoked or clamped. RAM mutations on a discarded
    // object are harmless (nothing reads them, `_refreshActive` is guarded);
    // persistence is not.
    if (_disposed) {
      SafeLogger.w(_tag, 'save on a disposed manager — dropped');
      return Future<void>.value();
    }
    _mutationEpoch++;
    // Bounded wait on the queue, not a bare `then`: a platform write that never
    // answers (a wedged Keystore) would otherwise freeze every later save for
    // the life of the process. Ordering still holds in the normal case; past
    // the timeout we prefer a possibly-reordered write to no writes at all.
    final previous = _saveQueue;
    final task = () async {
      try {
        await previous.timeout(kSaveDrainTimeout);
      } catch (_) {
        SafeLogger.w(_tag, 'a queued VIP write did not settle within '
            '${kSaveDrainTimeout.inSeconds}s — writing anyway');
      }
      // Re-checked at EXECUTION time, not just at call time: this task may have
      // waited behind other writes long enough for the host to tear the SDK
      // down, and by then the store belongs to the replacement manager.
      if (_disposed) {
        SafeLogger.w(_tag, 'save reached the queue after dispose — dropped');
        return;
      }
      await _vipEntriesStore.setRaw(VipEntry.encodeList(_entries));
    }();
    // Catch errors so the queue keeps working even if one save fails.
    _saveQueue = task.catchError((Object e) {
      SafeLogger.w(_tag, '_save threw: $e');
    });
    // A separately-caught view of THIS task — not `_saveQueue`, which is the
    // process-wide chain and would drag in writes from managers this instance
    // has nothing to do with.
    _ownSaveTail = task.catchError((Object _) {});
    return task;
  }

  void _purgeExpired() {
    final now = _effectiveNow();
    final before = _entries.length;
    _entries.removeWhere((e) => !e.isActiveAt(now));
    if (_entries.length != before) {
      SafeLogger.d(_tag, 'purgeExpired: removed ${before - _entries.length}');
      unawaited(_save());
    }
  }

  void _refreshActive() {
    // The single funnel for "entitlement state changed", so the two lifecycle
    // guards live here rather than at each of its seven call sites.
    if (_disposed) return;
    if (_entries.isNotEmpty && _readRetryTimer != null) {
      // A grant arrived while a retry was pending (a redeem one second into the
      // 2 s wait). Re-reading now would be pointless at best, and could drop
      // the fresh grant from memory if its own save has not landed yet.
      _readRetryTimer!.cancel();
      _readRetryTimer = null;
      _readRetryIndex = 0;
    }
    final wasActive = _activeNotifier.value;
    final now = _effectiveNow();
    final nowActive = _entries.any((e) => e.isActiveAt(now));
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
    if (_disposed) return;

    final now = _effectiveNow();
    DateTime? earliest;
    for (final e in _entries) {
      if (!e.isActiveAt(now)) continue;
      if (earliest == null || e.expiresAt.isBefore(earliest)) {
        earliest = e.expiresAt;
      }
    }

    final exp = expiresAt;
    if (exp != null) {
      final nudgeFireAt = exp.subtract(graceNudgeThreshold);
      if (nudgeFireAt.isAfter(now) &&
          (earliest == null || nudgeFireAt.isBefore(earliest))) {
        earliest = nudgeFireAt;
      }
    }
    if (earliest == null) return;

    final delay = earliest.difference(now);
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
  ///   `now + duration` is clamped to `now + [maxStackDuration]` when that cap
  ///   is set, same as the `stack: true` branch below (T49 — a single key
  ///   whose encoded duration alone exceeds the cap must not bypass it just
  ///   because it wasn't stacked).
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
    // T-clock — must go through _effectiveNow(), not a raw DateTime.now():
    // otherwise turning the device clock forward, redeeming any VIP grant,
    // then turning it back grants an effectively permanent VIP (expiresAt
    // gets baked from the tampered clock and is never recomputed).
    final now = _effectiveNow();
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
        if (e.isActiveAt(now) && e.expiresAt.isAfter(base)) base = e.expiresAt;
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

    var singleExpiry = now.add(duration);
    final singleCap = maxStackDuration;
    if (singleCap != null) {
      final capExpiry = now.add(singleCap);
      if (singleExpiry.isAfter(capExpiry)) {
        singleExpiry = capExpiry;
        SafeLogger.d(
            _tag, 'addVip: single-entry clamped to cap ($singleCap) for $norm');
      }
    }
    final newEntry = VipEntry(
      key: norm,
      expiresAt: singleExpiry,
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
  ///    key is accepted in debug/profile builds (demo mode); release builds
  ///    refuse instead, so a forgotten validator can't ship as free-VIP-for-
  ///    anyone.
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
  /// Requires connectivity to even attempt redemption (checked via
  /// [_isConnectedCheck], not a network call the key verification itself
  /// needs) — a deliberate product gate against redeeming with the device
  /// offline, not a technical requirement of the Ed25519 check.
  ///
  /// Returns a [SignedVipRedeemResult] describing success / invalid / already
  /// used. On success the grant [stack]s onto the current window by default.
  Future<SignedVipRedeemResult> redeemSignedKey(
    String code, {
    required String publicKeyBase64,
    bool stack = true,
  }) async {
    // Round-9 follow-up — refuse outright on a disposed manager, BEFORE the
    // one-time-use ledger is touched. `_save()` now drops writes from a
    // discarded manager (which is right: it must not clobber the store its
    // replacement owns), but redemption burns the key at
    // `addRedeemedVipKeyId`/`markRedeemed` AFTER granting, so a dropped save
    // here left the customer with a key that can never be redeemed again and no
    // VIP window to show for it. Reported as `invalid` rather than a new enum
    // value: `VipRedeemStatus` is exported, so adding a case is breaking for
    // any consuming app that switches on it exhaustively.
    if (_disposed) {
      SafeLogger.w(_tag, 'redeemSignedKey on a disposed manager — refused');
      return const SignedVipRedeemResult.invalid(
          'SDK was torn down — redeem again after it re-initialises');
    }
    // ⚠️ DELIBERATE PRODUCT GATE — do NOT "fix" this.
    //
    // Three independent audit agents have now flagged this twice as a bug
    // ("Ed25519 verification is offline, so why require network?"). The
    // signature check IS fully offline; requiring connectivity to *redeem* is
    // a product decision by the owner of this SDK, not an oversight. Removing
    // it changes agreed product behaviour. If a future audit disagrees, take
    // it to the product owner rather than to this line.
    if (!_isConnectedCheck()) {
      SafeLogger.d(_tag, 'redeemSignedKey: rejected — device is offline');
      return const SignedVipRedeemResult.invalid(
          'no network connection — connect to the internet to redeem a VIP code');
    }

    SignedVipKey parsed;
    try {
      // C6 — read the running app's bundle id so an AVP2 key bound to another
      // app is rejected. Read here rather than taken as a parameter: a host
      // that passed the wrong value, or omitted it, would silently disable the
      // binding and never know. A failure to read degrades to "no bundle
      // check" rather than blocking a legitimate redemption.
      // Only AVP2 carries an app binding, so only AVP2 needs the platform
      // call. Skipping it for AVP1 keeps the old path free of an extra async
      // hop — which is not just a micro-optimisation: adding that hop
      // unconditionally made three existing widget tests fail, because their
      // pump sequence no longer landed after the redeem completed. Paying a
      // platform round trip for a check that cannot apply was wrong anyway.
      String? bundleId;
      if (code.trim().startsWith('AVP2.')) {
        try {
          bundleId = (await PackageInfo.fromPlatform()).packageName;
        } catch (e) {
          SafeLogger.w(_tag,
              'could not read bundle id ($e) — skipping the AVP2 app binding');
        }
      }
      parsed = await verifySignedVipKey(
        code,
        publicKeyBase64: publicKeyBase64,
        currentBundleId: bundleId,
        // M2 fix (audit_claude.md, 2026-08-20) — without this, expiry used
        // the raw device clock, bypassing _effectiveNow()'s anti-rollback
        // clamp: winding the clock back could redeem an already-expired key.
        now: _effectiveNow(),
      );
    } on VipKeyException catch (e) {
      SafeLogger.w(_tag, 'redeemSignedKey invalid: ${e.message}');
      return SignedVipRedeemResult.invalid(e.message);
    } catch (e) {
      SafeLogger.w(_tag, 'redeemSignedKey error: $e');
      return SignedVipRedeemResult.invalid('$e');
    }

    // T95 — CRL check. Uses the SAME publicKeyBase64 already passed in for
    // key verification above (the private key mints both keys and CRLs), so
    // no extra config is needed from the host.
    await _ensureCachedRevocationLoaded(publicKeyBase64);
    if (_revokedKeyIds.contains(parsed.keyId)) {
      SafeLogger.d(_tag, 'redeemSignedKey: kid ${parsed.keyId} is revoked');
      return const SignedVipRedeemResult.invalid('key revoked');
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

  /// Loads any cached signed CRL from disk (offline-first) exactly once per
  /// manager instance, re-verifying it against [publicKeyBase64] before
  /// trusting it. A verify failure (corrupt storage, tampered value) degrades
  /// to an empty revoked set rather than blocking redemption — fail-open.
  Future<void> _ensureCachedRevocationLoaded(String publicKeyBase64) async {
    if (_revocationCacheLoaded) return;
    _revocationCacheLoaded = true;
    final raw = _prefs.getVipRevocationCacheRaw();
    if (raw == null) return;
    try {
      final parsed =
          await verifySignedCrl(raw, publicKeyBase64: publicKeyBase64);
      _revokedKeyIds = parsed.revokedKeyIds;
      _revocationIssuedAt = parsed.issuedAt;
    } catch (e) {
      SafeLogger.w(_tag, 'cached CRL failed to verify, ignoring: $e');
    }
  }

  /// T95 — flagship: fetches a fresh signed VIP-key revocation list (CRL) via
  /// [revocationProvider], verifies it against [publicKeyBase64] (same
  /// Ed25519 key(s) — comma-separated rotation list — [redeemSignedKey]
  /// already uses), and if it verifies AND is newer than whatever is
  /// currently cached, persists it and applies it to future
  /// [redeemSignedKey] calls.
  ///
  /// Call this periodically from the host app (once/day is plenty — see
  /// [VipRevocationProvider]'s doc comment for a `Timer.periodic` example).
  ///
  /// **Fails open on every error** — fetch throws, fetch returns null, bad
  /// signature, stale/older `issuedAt` — leaving the previously cached (or
  /// empty) revocation list untouched. A network hiccup or missing CRL
  /// infrastructure must never block a legitimate redemption; this only ever
  /// narrows what's accepted, on top of an already-offline-first base.
  Future<void> refreshRevocationList({
    required String publicKeyBase64,
    required VipRevocationProvider revocationProvider,
  }) async {
    await _ensureCachedRevocationLoaded(publicKeyBase64);

    String? raw;
    try {
      raw = await revocationProvider.fetchSignedCrl();
    } catch (e) {
      SafeLogger.w(_tag, 'refreshRevocationList: fetch threw: $e');
      return;
    }
    if (raw == null) return;

    VipRevocationList parsed;
    try {
      parsed = await verifySignedCrl(raw, publicKeyBase64: publicKeyBase64);
    } catch (e) {
      SafeLogger.w(
          _tag, 'refreshRevocationList: fetched CRL failed to verify: $e');
      return;
    }

    final cachedIssuedAt = _revocationIssuedAt;
    if (cachedIssuedAt != null && !parsed.issuedAt.isAfter(cachedIssuedAt)) {
      SafeLogger.d(_tag,
          'refreshRevocationList: fetched CRL is not newer than cached — ignoring');
      // Round-6 QC — returning here used to skip the clamp entirely, which is
      // what made a crash between "CRL persisted" and "grants clamped"
      // permanent: on every later launch the same-age CRL landed in this
      // branch. The clamp is idempotent, so run it before giving up.
      await _clampRevokedEntries();
      return;
    }

    _revokedKeyIds = parsed.revokedKeyIds;
    _revocationIssuedAt = parsed.issuedAt;
    // Clamp BEFORE persisting: a process death between these two awaits then
    // leaves the CRL un-cached with grants already clamped, which self-heals on
    // the next fetch. The other order left the CRL cached and the grants
    // full-length, and nothing ever revisited them.
    await _clampRevokedEntries();
    await _prefs.setVipRevocationCacheRaw(raw);
    // Round-7 audit, MAJOR — remembered so `load()` can apply this same CRL on
    // every later launch, including the launches where the host never calls
    // back in here (offline, or a host that refreshes once a day).
    await _prefs.setVipRevocationPublicKey(publicKeyBase64);
    SafeLogger.d(
        _tag,
        () =>
            'refreshRevocationList: applied ${parsed.revokedKeyIds.length} revoked kid(s)');
  }

  /// How much time a grant keeps after the key that issued it is revoked.
  static const Duration revokedGraceWindow = Duration(hours: 24);

  /// How much a grant read from the plaintext fallback is worth when the
  /// device's secure storage is working — see M6 in [load].
  static const Duration untrustedFallbackWindow = Duration(hours: 24);

  /// M5 (round-6 audit) — before this, [_revokedKeyIds] was consulted at
  /// exactly one place: redemption. Applying a newer CRL swapped the set and
  /// cached it, and did nothing else. A key that leaked *after* being redeemed
  /// on N devices therefore kept its full window on all N of them; revocation
  /// only ever stopped the (N+1)-th redemption.
  ///
  /// Clamp rather than delete, deliberately. A mis-issued CRL cannot be undone
  /// from the customer's side — the cached-CRL rule only accepts a newer
  /// `issuedAt`, so you can publish a correction, but a deleted entry is gone.
  /// Clamping makes a mis-issue cost a paying customer one day, with a window
  /// for support to re-issue, while a leaked key stops earning within a day.
  ///
  /// Known limitation, worth stating rather than hiding: entries are keyed
  /// `SIGNED_<kid>` through [normaliseKey], which upper-cases, so kids that
  /// differ only in case share one entry key and revoking either would clamp
  /// the other. Mint kids in a single case. Closing it properly means carrying
  /// the exact kid on [VipEntry] as an additive field.
  ///
  /// Also note stacking: with `stack: true` a later legitimate key's entry has
  /// already absorbed the revoked window into its own `expiresAt`, so clamping
  /// the revoked entry does not claw that part back.
  Future<void> _clampRevokedEntries() async {
    if (_revokedKeyIds.isEmpty || _entries.isEmpty) return;

    final revokedEntryKeys =
        _revokedKeyIds.map((kid) => normaliseKey('SIGNED_$kid')).toSet();
    final cutoff = _effectiveNow().add(revokedGraceWindow);

    var clamped = 0;
    for (var i = 0; i < _entries.length; i++) {
      final e = _entries[i];
      if (!revokedEntryKeys.contains(e.key)) continue;
      if (!e.expiresAt.isAfter(cutoff)) continue; // already shorter than grace
      _entries[i] = VipEntry(
        key: e.key,
        expiresAt: cutoff,
        grantedAt: e.grantedAt,
      );
      clamped++;
    }

    if (clamped == 0) return;
    SafeLogger.w(
        _tag,
        () => 'refreshRevocationList: clamped $clamped revoked grant(s) to '
            '${revokedGraceWindow.inHours}h');
    await _save();
    _refreshActive();
    _scheduleNextExpiry();
  }

  Future<bool> _runValidator(
    String key,
    Future<bool> Function(String key)? validator,
  ) async {
    if (validator == null) {
      if (isActuallyRelease(_isRelease)) {
        // A plain assert() would be stripped from release builds — the
        // exact build where a forgotten validator matters most (free VIP
        // for any string). Refuse instead, so demo mode only ever applies
        // to debug/profile builds used while wiring the integration.
        SafeLogger.e(
            _tag,
            'redeemVip: no vipKeyValidator configured in a release build — '
            'refusing all keys. Set AdConfig.vipKeyValidator, or use '
            'redeemSignedKey() instead, before shipping.');
        return false;
      }
      // No validator wired — demo mode (debug/profile only).
      await Future<void>.delayed(const Duration(milliseconds: 400));
      return true;
    }
    return validator(key);
  }

  /// Test seam for [_runValidator] — the no-validator/`isRelease` guard
  /// above is otherwise only reachable through [redeemVip]'s full dialog
  /// flow, which requires a widget pump under `flutter test`.
  @visibleForTesting
  Future<bool> debugRunValidator(
    String key,
    Future<bool> Function(String key)? validator,
  ) =>
      _runValidator(key, validator);

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

  /// Test hook — wipes the durable (iOS Keychain) redeemed-signed-key-id
  /// ledger, so `redeemSignedKey` accepts a previously-used `kid` again.
  /// Deliberately separate from [revokeAll]: that only clears active VIP
  /// entries, not the anti-reuse ledger (which must survive revoke/reinstall
  /// in production). Production callers never call this.
  @visibleForTesting
  Future<void> clearRedeemedKeyLedgerForTest() =>
      // ignore: invalid_use_of_visible_for_testing_member
      _redeemedKeyLedger.clearForTest();

  /// Cleanup. After this the manager can no longer fire stream events.
  ///
  /// Deliberately does NOT dispose [_activeNotifier]/[_graceNudgeDueNotifier]:
  /// external widgets (e.g. wifi_stressor_screen's grace-nudge listener) hold
  /// references to these across an `AdManager` re-init and call
  /// `removeListener` against whichever instance they last attached to.
  /// `ChangeNotifier.removeListener` is documented as safe to call after
  /// dispose in the current Flutter SDK, so this isn't closing a live crash —
  /// it's removing the dependency on that specific SDK guarantee, since
  /// they're plain objects that GC reclaims once this VipManager is
  /// unreferenced; no need to dispose them explicitly.
  void dispose() {
    _disposed = true;
    _expiryTimer?.cancel();
    _expiryTimer = null;
    _readRetryTimer?.cancel();
    _readRetryTimer = null;
    _activeStream.close();
  }
}
