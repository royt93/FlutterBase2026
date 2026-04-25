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
  /// side-effects.
  static Future<ConsentManager> bootstrap({
    required AdPreferences prefs,
    required ConsentDialogStrings strings,
  }) async {
    final m = _instance ?? ConsentManager._(prefs: prefs, strings: strings);
    m._strings = strings;
    await m._load();
    _instance = m;
    return m;
  }

  /// For tests: clear the singleton.
  @visibleForTesting
  static void resetForTest() {
    _instance?._settingsListenable.dispose();
    _instance = null;
  }

  final AdPreferences _prefs;
  ConsentDialogStrings _strings;

  ConsentSettings _current = ConsentSettings.unset;

  /// Reactive listenable — rebuilds widgets when settings change.
  ValueListenable<ConsentSettings> get listenable => _settingsListenable;
  final ValueNotifier<ConsentSettings> _settingsListenable =
      ValueNotifier<ConsentSettings>(ConsentSettings.unset);

  /// Current cached settings.
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

  Future<void> _persist() async {
    await _prefs.setConsentSettingsRaw(ConsentSettings.encode(_current));
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
    SafeLogger.d(_tag, () => 'applyToProviders ($_current)');
    await _applyToProviders(config);
  }

  /// Wipe persisted state. Next [showDialogIfNeeded] will re-prompt.
  /// Does NOT auto-revert provider state — call [applyToProviders] after
  /// if you need conservative defaults applied immediately.
  Future<void> reset({AdConfig? config}) async {
    _current = ConsentSettings.unset;
    _settingsListenable.value = _current;
    await _persist();
    SafeLogger.d(_tag, 'reset → unset');
    await _applyToProviders(config);
  }

  // ─── Internals ────────────────────────────────────────────────────────────

  Future<void> _setInternal(ConsentSettings s, {AdConfig? config}) async {
    _current = s;
    _settingsListenable.value = s;
    await _persist();
    SafeLogger.d(_tag, () => 'set → $s');
    await _applyToProviders(config);
  }
}
