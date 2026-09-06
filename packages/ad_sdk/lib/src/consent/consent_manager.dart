import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../config/ad_config.dart';
import '../core/ad_consent.dart';
import '../utils/ad_preferences.dart';
import '../utils/safe_logger.dart';
import 'consent_dialog.dart';
import 'consent_dialog_strings.dart';
import 'consent_settings.dart';

/// Standalone consent helper — owns the dialog UI, persistence, and
/// provider-apply pipeline. Available independently of [AdManager.initialize]
/// so a host app can:
///   - Re-show the consent dialog from a "Privacy" settings page.
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
    required ConsentDialogStrings strings,
  })  : _prefs = prefs,
        _strings = strings;

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
  static Future<ConsentManager> bootstrap({
    required AdPreferences prefs,
    required ConsentDialogStrings strings,
  }) async {
    final existing = _instance;
    if (existing != null && !identical(existing._prefs, prefs)) {
      SafeLogger.w(
          _tag,
          'bootstrap() called again with a different AdPreferences instance '
          '— ignored; the singleton keeps using the one from its first '
          'bootstrap() call. Pass the same AdPreferences every time.');
    }
    final m = existing ?? ConsentManager._(prefs: prefs, strings: strings);
    m._strings = strings;
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
    _instance = null;
    debugPersistDelay = null;
    debugApplyBarrier = null;
  }

  final AdPreferences _prefs;
  ConsentDialogStrings _strings;

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

  // Round-38 audit follow-up (on-device integration test caught this — no
  // unit test ever exercised it, since all of them bypass `ConsentManager`
  // entirely via `AdManager.debugSetAdapter`/`debugConfig`) — `_setInternal`
  // below persists THEN applies, with a real async gap (`_persist()`) in
  // between. `AdManager.setConsent()` was fixed to guard its OWN direct
  // `applyConsentToProviders` call with an epoch, but that call is a
  // redundant SECOND apply — `_setInternal` here is the FIRST, and every
  // caller of `set()`/`showDialog()`/`reset()` (not just AdManager) goes
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

  /// Convenience — same as `current.hasBeenAsked`.
  bool get hasBeenAsked => _current.hasBeenAsked;

  /// Project to the runtime [AdConsent] used by `applyConsentToProviders`.
  AdConsent get adConsent => _current.toAdConsent();

  /// Update the strings used by the dialog (e.g., on locale change).
  /// Cheaper than calling [bootstrap] again — does not re-load from prefs.
  void updateStrings(ConsentDialogStrings v) => _strings = v;
  ConsentDialogStrings get strings => _strings;

  Future<void> _load() async {
    _current = ConsentSettings.decode(_prefs.getConsentSettingsRaw());
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

  /// Show the simple binary dialog (Allow / Reject). Persists user's choice
  /// and re-applies to providers. Returns the new settings.
  ///
  /// Returns [current] unchanged if the dialog was dismissed without choice.
  Future<ConsentSettings> showDialog(
    BuildContext context, {
    AdConfig? config,
    bool barrierDismissible = false,
    void Function(String url)? onPrivacyPolicyTap,
  }) async {
    // Round-39 audit (MINOR) — a host wiring neither privacy-policy signal
    // ships this dialog with no way for the user to actually reach the
    // policy it references. Every other release footgun in this package
    // warns loudly (see AdManager.releaseFootgunWarnings); this one had no
    // signal at all, debug or release.
    if (_strings.privacyPolicyUrl == null && onPrivacyPolicyTap == null) {
      SafeLogger.w(_tag,
          '🚨 showDialog: neither ConsentDialogStrings.privacyPolicyUrl nor '
          'onPrivacyPolicyTap is set — this consent dialog has no way for '
          'the user to reach your privacy policy. Set one of them.');
    }
    final result = await showConsentDialog(
      context,
      strings: _strings,
      current: _current,
      barrierDismissible: barrierDismissible,
      onPrivacyPolicyTap: onPrivacyPolicyTap,
    );
    if (result == null) {
      SafeLogger.d(_tag, 'dialog dismissed without choice');
      return _current;
    }
    await _setInternal(result, config: config);
    return _current;
  }

  /// Show only if user has not been asked yet. Used by [AdManager.initialize]
  /// for first-launch auto-show. Idempotent across calls.
  Future<ConsentSettings> showDialogIfNeeded(
    BuildContext context, {
    AdConfig? config,
    bool barrierDismissible = false,
  }) async {
    if (_current.hasBeenAsked) {
      SafeLogger.d(_tag, 'showDialogIfNeeded ⏭️ already asked');
      return _current;
    }
    return showDialog(
      context,
      config: config,
      barrierDismissible: barrierDismissible,
    );
  }

  /// Programmatic setter — no UI. Use for "Accept all" / "Reject all"
  /// shortcuts or restoring persisted state from server.
  Future<void> set(ConsentSettings settings, {AdConfig? config}) async {
    await _setInternal(settings, config: config);
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
  /// `hasBeenAsked`, `askedAt`, `country`) so [showDialogIfNeeded] re-prompts
  /// on the next qualifying trigger, and immediately re-applies the result
  /// to both providers.
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
  Future<void> reset({AdConfig? config}) async {
    final epoch = ++_applyEpoch;
    _current = ConsentSettings.unset.copyWith(
      isAgeRestrictedUser: _current.isAgeRestrictedUser,
      doNotSell: _current.doNotSell,
    );
    _settingsListenable.value = _current;
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

  Future<void> _setInternal(ConsentSettings s, {AdConfig? config}) async {
    final epoch = ++_applyEpoch;
    _current = s;
    _settingsListenable.value = s;
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
