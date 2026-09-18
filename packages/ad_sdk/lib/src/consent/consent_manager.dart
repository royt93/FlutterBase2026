import 'dart:async';

import 'package:flutter/foundation.dart';

import '../compliance/consent_provenance_journal.dart';
import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import 'consent_fallback.dart';
import 'consent_settings.dart';

/// Standalone consent helper — owns persistence and the provider-apply
/// pipeline. Available independently of [AdManager.initialize] so a host
/// app can:
///   - Read current settings (e.g., to display "Personalized: Yes/No").
///   - Programmatically set settings (e.g., "Reject all" button).
///   - Re-apply current settings to providers after a config change.
///
/// Lifecycle: created during [AdManager.initialize] and stays alive for the
/// process. Access via [AdManager.consentManager] OR [ConsentManager.instance]
/// once initialized.
class ConsentManager {
  ConsentManager._({
    required AdPreferences prefs,
    ConsentProvenanceJournal? provenanceJournal,
  })  : _prefs = prefs,
        _journal = provenanceJournal;

  static const String _tag = 'ConsentManager';

  static ConsentManager? _instance;

  /// Process-wide singleton (after [bootstrap]). Throws if called before
  /// [AdManager.initialize] / [bootstrap].
  static ConsentManager get instance {
    final i = _instance;
    if (i == null) {
      throw StateError('ConsentManager not bootstrapped — '
          'call AdManager.initialize first or ConsentManager.bootstrap directly');
    }
    return i;
  }

  /// Whether [bootstrap] has run.
  static bool get isReady => _instance != null;

  /// Initialise and load persisted settings. Idempotent: a second call
  /// updates the strings and re-loads from disk but does not re-run init
  /// side-effects — in particular, [prefs] is silently ignored on a second
  /// call (the singleton keeps the one from its first `bootstrap()`), which
  /// used to be a confusing, undocumented-in-behavior contract. Now warns
  /// when that actually discards a different instance than the one already
  /// in use, so passing a fresh `AdPreferences` the second time around
  /// doesn't fail silently.
  /// [provenanceJournal] (T202) is optional — when set, every [set] /
  /// [reset] call appends a [ConsentProvenanceEntry] to it. Omitting it is a
  /// no-op: no behavior change for a caller that doesn't need this. Unlike
  /// [prefs] (frozen after the first call), a non-null [provenanceJournal]
  /// is adopted on EVERY `bootstrap()` call. Audit finding B: freezing
  /// it like [prefs] left `AdManager` (which loads a fresh
  /// `ConsentProvenanceJournal` from disk on every `initialize()`) and this
  /// singleton (which survives `destroy()`, per its own doc comment above)
  /// pointing at two DIFFERENT journal instances after a destroy()+
  /// reinitialize() cycle — real writes landed on the old, orphaned one
  /// while `AdManager().consentProvenanceJournal` returned the new,
  /// silently-stale one. Both instances read/write the same persisted
  /// SharedPreferences key regardless of identity, so always adopting the
  /// latest one loses no data — it just keeps the two objects in sync.
  static Future<ConsentManager> bootstrap({
    required AdPreferences prefs,
    ConsentProvenanceJournal? provenanceJournal,
  }) async {
    final existing = _instance;
    if (existing != null && !identical(existing._prefs, prefs)) {
      SafeLogger.w(
          _tag,
          'bootstrap() called again with a different AdPreferences instance '
          '— ignored; the singleton keeps using the one from its first '
          'bootstrap() call. Pass the same AdPreferences every time.');
    }
    final m = existing ??
        ConsentManager._(
          prefs: prefs,
          provenanceJournal: provenanceJournal,
        );
    if (provenanceJournal != null) {
      m._journal = provenanceJournal;
    }
    await m._load();
    _instance = m;
    return m;
  }

  /// For tests: clear the singleton.
  ///
  /// Round-39 audit re-review (NITPICK, independent Gemini pass) — also
  /// clears [debugPersistDelay]/[debugApplyBarrier]: a test that sets either
  /// and aborts before its own tearDown runs would otherwise leak an
  /// artificial delay/barrier into every subsequent test in the same
  /// process.
  @visibleForTesting
  static void resetForTest() {
    _instance?._settingsListenable.dispose();
    _instance?._fallbackListenable.dispose();
    _instance = null;
    debugPersistDelay = null;
    debugApplyBarrier = null;
  }

  final AdPreferences _prefs;
  ConsentProvenanceJournal? _journal;

  /// Round-39 audit fix (MAJOR) — serializes every [_persist] call after
  /// whatever previous one is still in flight, same intent as
  /// `AdEventLog._persistChain`, so two overlapping `set()`/`reset()` calls'
  /// real platform-channel writes can never be in flight at once and finish
  /// out of order. Without this, an older call's slower write could land on
  /// disk AFTER a newer call's faster one, invisibly reverting the user's
  /// real, most-recent consent choice until they change it again.
  ///
  /// Deliberately `null` (not a resolved `Future.value()`) when nothing is in
  /// flight, so the common, non-overlapping case calls [_persist] with no
  /// preceding `await` at all: a widget test that calls `set()`/`reset()` as
  /// its very first statement, before ever pumping a frame, depends on this
  /// — inserting even one extra already-resolved `await` ahead of the real
  /// platform-channel call left it permanently unresolved with nothing left
  /// to ever pump it (caught by `ccpa_opt_out_toggle_test.dart`'s "reflects
  /// an already-true doNotSell on first build").
  Completer<void>? _persistLock;

  Future<void> _schedulePersist() async {
    final prior = _persistLock;
    final mine = Completer<void>();
    _persistLock = mine;
    if (prior != null) await prior.future;
    try {
      await _persist();
    } finally {
      mine.complete();
      if (identical(_persistLock, mine)) _persistLock = null;
    }
  }

  ConsentSettings _current = ConsentSettings.unset;
  ConsentFallbackState? _fallback;

  // Round-38 audit follow-up (on-device integration test caught this — no
  // unit test ever exercised it, since all of them bypass `ConsentManager`
  // entirely via `AdManager.debugSetAdapter`/`debugConfig`) — `_setInternal`
  // below persists THEN applies, with a real async gap (`_persist()`) in
  // between. `AdManager.setConsent()` was fixed to guard its OWN direct
  // `applyConsentToProviders` call with an epoch, but that call is a
  // redundant SECOND apply — `_setInternal` here is the FIRST, and every
  // caller of `set()`/`reset()` (not just AdManager) goes
  // through it. It had no ordering protection of its own at all, so an
  // older, already-superseded call whose `_persist()` await resolves after a
  // newer overlapping call still silently re-applied its stale value here —
  // the actual real-world reproduction of the race the AdManager-level guard
  // only partially closed. Fixed at the root, self-contained, so it protects
  // every caller uniformly rather than each one individually.
  int _applyEpoch = 0;

  /// Test-only barrier awaited right before [_applyToProviders], after the
  /// epoch check — lets a test hold an older call's real provider-apply open
  /// while a newer overlapping call races ahead and completes its own first.
  @visibleForTesting
  static Future<void>? debugApplyBarrier;

  /// Reactive listenable — rebuilds widgets when settings change.
  ValueListenable<ConsentSettings> get listenable => _settingsListenable;
  final ValueNotifier<ConsentSettings> _settingsListenable =
      ValueNotifier<ConsentSettings>(ConsentSettings.unset);

  /// Current cached settings.
  ///
  /// [ConsentSettings.country] is never populated by this class — the SDK has
  /// no way to determine a user's real country from UMP (only an EEA/non-EEA
  /// classification, plus a debug-only override). A host app that wants
  /// consent-country analytics must supply it itself, e.g.:
  /// `set(current.copyWith(country: 'DE'))`.
  ConsentSettings get current => _current;

  /// Provenance of the last conservative offline/error decision, if any.
  ConsentFallbackState? get fallback => _fallback;

  /// Reactive mirror of [fallback] — audit fix (post-T210): [recordFallback]
  /// and [clearFallback] used to update `_fallback` with no notification at
  /// all, so a host UI built to show "why are ads conservative right now"
  /// (the whole reason this state is public) could never react to it
  /// changing — only a full rebuild triggered by something else would ever
  /// pick up a new value. [listenable] is the wrong vehicle for this: it is
  /// typed [ConsentSettings], a different shape, and is not touched by
  /// fallback changes either.
  ValueListenable<ConsentFallbackState?> get fallbackListenable =>
      _fallbackListenable;
  final ValueNotifier<ConsentFallbackState?> _fallbackListenable =
      ValueNotifier<ConsentFallbackState?>(null);

  /// Convenience — same as `current.hasBeenAsked`.
  bool get hasBeenAsked => _current.hasBeenAsked;

  /// Project to the runtime [AdConsent] used by `applyConsentToProviders`.
  AdConsent get adConsent => _current.toAdConsent();

  Future<void> _load() async {
    _current = ConsentSettings.decode(_prefs.getConsentSettingsRaw());
    final rawFallback = _prefs.getConsentFallbackRaw();
    var fallback = rawFallback == null
        ? null
        : () {
            try {
              return ConsentFallbackState.decode(rawFallback);
            } catch (_) {
              return null;
            }
          }();
    // Audit fix (post-T210) — `staleRevision` was declared as a reason but
    // nothing in production ever produced it: a fallback recorded under an
    // old policy revision was silently treated as still current forever.
    // Reclassify it here (keeping the original policyRevision/recordedAt
    // provenance, only the reason changes) so a host reading [fallback]
    // after a policy bump sees `staleRevision`, not a stale `timeout`/
    // `platformError` from an epoch that no longer applies.
    //
    // codex round-2 fix — [recordFallback] is a PUBLIC API documented for
    // "UMP/ATT" and any other caller-supplied reason, so [policyRevision] is
    // not always this SDK's own UMP namespace. Comparing every persisted
    // value against [kUmpPolicyRevision] would permanently misclassify a
    // host's own ATT/custom-policy fallback (e.g. `'att-v1'`) as
    // `staleRevision` on every single bootstrap, forever, just for not
    // being the UMP constant. Scope this migration to records that are
    // actually in the UMP revision namespace (`kUmpPolicyRevision`'s own
    // `'ump-vN'` convention) — the only namespace this SDK itself writes to
    // today — and leave anything else alone.
    if (fallback != null &&
        fallback.policyRevision.startsWith('ump-') &&
        fallback.policyRevision != kUmpPolicyRevision &&
        fallback.reason != ConsentFallbackReason.staleRevision) {
      fallback = ConsentFallbackState(
        policyRevision: fallback.policyRevision,
        reason: ConsentFallbackReason.staleRevision,
        recordedAt: fallback.recordedAt,
      );
      await _prefs.setConsentFallbackRaw(fallback.encode());
    }
    _fallback = fallback;
    _fallbackListenable.value = fallback;
    _settingsListenable.value = _current;
    SafeLogger.d(_tag, () => 'load → $_current');
  }

  /// Test-only hook: when set, awaited right before the real platform write
  /// inside [_persist] (after the value to write has already been captured),
  /// to reproduce the real-device timing gap a mock `SharedPreferences` is
  /// too fast to ever exhibit on its own. Same pattern as
  /// `AdEventLog.debugPersistDelay`.
  @visibleForTesting
  static Duration? debugPersistDelay;

  /// T202 — no-op when no journal was wired via `bootstrap()`.
  Future<void> _recordProvenance({
    required String source,
    required String policyRevision,
  }) async {
    final journal = _journal;
    if (journal == null) return;
    await journal.append(
      source: source,
      policyRevision: policyRevision,
      hasUserConsent: _current.hasUserConsent,
      isAgeRestrictedUser: _current.isAgeRestrictedUser,
      doNotSell: _current.doNotSell,
      regionSignal: _current.country,
    );
  }

  Future<void> _persist() async {
    final encoded = ConsentSettings.encode(_current);
    final delay = debugPersistDelay;
    if (delay != null) await Future<void>.delayed(delay);
    await _prefs.setConsentSettingsRaw(encoded);
  }

  Future<void> _applyToProviders(AdConfig? config) async {
    await applyConsentToProviders(_current.toAdConsent(), config: config);
  }

  // ─── Public API ───────────────────────────────────────────────────────────

  /// Programmatic setter — no UI. Use for "Accept all" / "Reject all"
  /// shortcuts or restoring persisted state from server.
  ///
  /// [source] / [policyRevision] (T202) are only used when a
  /// [ConsentProvenanceJournal] was wired via `bootstrap()` — free-text
  /// [source] (`'ump'`, `'host'`, `'manual'`, or a caller's own vocabulary,
  /// same convention as `IncidentEntry.label`), defaulting to `'host'`
  /// since this setter is normally called by the app's own UI/logic, not
  /// forwarding a raw UMP result.
  Future<void> set(
    ConsentSettings settings, {
    AdConfig? config,
    String source = 'host',
    String policyRevision = kUmpPolicyRevision,
  }) async {
    await _setInternal(settings,
        config: config, source: source, policyRevision: policyRevision);
  }

  /// Records a versioned, conservative fallback when UMP/ATT cannot resolve.
  Future<void> recordFallback({
    required ConsentFallbackReason reason,
    required String policyRevision,
  }) async {
    _fallback = ConsentFallbackState.create(
      reason: reason,
      policyRevision: policyRevision,
    );
    _fallbackListenable.value = _fallback;
    await _prefs.setConsentFallbackRaw(_fallback!.encode());
  }

  /// Clears fallback provenance after a fresh successful consent resolution.
  Future<void> clearFallback() async {
    _fallback = null;
    _fallbackListenable.value = null;
    await _prefs.clearConsentFallback();
  }

  /// Re-apply the current cached settings to providers. Useful after a
  /// config hot-swap that changed `testDeviceIds` (which gets wiped from
  /// AdMob's RequestConfiguration on every update).
  Future<void> applyToProviders({AdConfig? config}) async {
    final epoch = ++_applyEpoch;
    SafeLogger.d(_tag, () => 'applyToProviders ($_current)');
    final barrier = debugApplyBarrier;
    if (barrier != null) await barrier;
    if (epoch == _applyEpoch) {
      await _applyToProviders(config);
    }
  }

  /// Wipe the user's per-install consent answer (`hasUserConsent`,
  /// `hasBeenAsked`, `askedAt`, `country`) so the host's own consent flow
  /// (e.g. a certified CMP) re-prompts on its next qualifying trigger, and
  /// immediately re-applies the result to both providers.
  ///
  /// Round-29 audit (MAJOR) — this used to reset to [ConsentSettings.unset],
  /// which also zeroes `isAgeRestrictedUser` (COPPA) and `doNotSell` (CCPA).
  /// Those two are documented (`consent_settings.dart`) as app-level
  /// constants, not per-user answers — a child-directed host calling
  /// `reset()` believing it only re-asks the personalization question was
  /// silently flipping its own COPPA flag off and pushing that live to
  /// AdMob. This now preserves both across the reset.
  ///
  /// Always applies the result to providers — the doc comment used to claim
  /// otherwise (call [applyToProviders] separately), but the code never
  /// matched that: it called `_applyToProviders` unconditionally regardless.
  Future<void> reset({
    AdConfig? config,
    String source = 'host',
    String policyRevision = kUmpPolicyRevision,
  }) async {
    final epoch = ++_applyEpoch;
    _current = ConsentSettings.unset.copyWith(
      isAgeRestrictedUser: _current.isAgeRestrictedUser,
      doNotSell: _current.doNotSell,
    );
    _settingsListenable.value = _current;
    await _recordProvenance(source: source, policyRevision: policyRevision);
    await _schedulePersist();
    SafeLogger.d(_tag, 'reset → unset (COPPA/CCPA flags preserved)');
    final barrier = debugApplyBarrier;
    if (barrier != null) await barrier;
    if (epoch == _applyEpoch) {
      await _applyToProviders(config);
    } else {
      SafeLogger.d(_tag,
          'reset: superseded by a newer call before its own apply ran — skipping');
    }
  }

  // ─── Internals ────────────────────────────────────────────────────────────

  Future<void> _setInternal(
    ConsentSettings s, {
    AdConfig? config,
    String source = 'host',
    String policyRevision = kUmpPolicyRevision,
  }) async {
    final epoch = ++_applyEpoch;
    _current = s;
    _settingsListenable.value = s;
    await _recordProvenance(source: source, policyRevision: policyRevision);
    await _schedulePersist();
    SafeLogger.d(_tag, () => 'set → $s');
    // An overlapping, newer call may have already bumped `_applyEpoch` and
    // applied its own (correct) value while this call was awaiting persist
    // above — an older call landing here after that must not stomp it back.
    final barrier = debugApplyBarrier;
    if (barrier != null) await barrier;
    if (epoch == _applyEpoch) {
      await _applyToProviders(config);
    } else {
      SafeLogger.d(_tag,
          'set: superseded by a newer call before its own apply ran — skipping');
    }
  }
}
