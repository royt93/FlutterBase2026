import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import 'ccpa_opt_out_strings.dart';
import 'consent_settings.dart';

/// Round-31 audit — a ready-made widget for CCPA/CPRA's "Do Not Sell or
/// Share My Personal Information" opt-out (Cal. Civ. Code §1798.135).
///
/// [AdConsent.doNotSell]/[ConsentSettings.doNotSell] already flow correctly
/// through [ConsentManager] to both ad providers and to persistence — this
/// widget is the missing piece that lets an end user actually flip that
/// choice, instead of it only ever being a developer-set constant. Drop it
/// into a Settings/Privacy screen — CCPA/CPRA is a separate axis from the
/// GDPR personalized-ads consent your CMP (e.g. Google UMP) collects, so it
/// is intentionally its own toggle rather than folded into that flow.
///
/// ```dart
/// // Anywhere after AdManager().initialize() has completed:
/// const CcpaOptOutToggle()
/// ```
///
/// Requires [AdManager().initialize] to have already completed — the
/// [ConsentManager] this reads from doesn't exist before then. Shown
/// disabled (with the same copy) if that hasn't happened yet, rather than
/// silently doing nothing when tapped — and (T166) automatically re-enables
/// itself once init finishes, if this widget is mounted before that point
/// (e.g. shown during the first few seconds of a cold start) rather than
/// staying disabled until the host leaves and re-enters the screen.
class CcpaOptOutToggle extends StatefulWidget {
  const CcpaOptOutToggle({
    super.key,
    this.strings = const CcpaOptOutStrings(),
  });

  final CcpaOptOutStrings strings;

  @override
  State<CcpaOptOutToggle> createState() => _CcpaOptOutToggleState();
}

class _CcpaOptOutToggleState extends State<CcpaOptOutToggle> {
  ValueListenable<ConsentSettings>? _listenable;

  @override
  void initState() {
    super.initState();
    _attachListenable();
    // T166 — `AdManager().initRevision` bumps once `initialize()` has
    // fully completed, including `_consentManager` becoming non-null (see
    // ad_manager.dart, right after the adapter/config are set) — the same
    // general-purpose "SDK init state changed" signal `BannerAdWidget`
    // already listens to for its own analogous "was null at mount, may
    // become available later" problem. Without this, mounting this widget
    // during the first few seconds of a cold start (before
    // AdManager().initialize() resolves) left `_listenable` permanently
    // null: nothing else here ever re-checked it, so the toggle stayed
    // greyed out for the rest of this mount even once init genuinely
    // finished moments later — the user had to leave and re-enter the
    // screen to see it light up.
    AdManager().initRevision.addListener(_onInitRevisionChanged);
  }

  void _attachListenable() {
    _listenable?.removeListener(_onChanged);
    _listenable = AdManager().consentManager?.listenable;
    _listenable?.addListener(_onChanged);
  }

  void _onInitRevisionChanged() {
    if (!mounted) return;
    // Only do anything the FIRST time consentManager actually becomes
    // available — once attached, _onChanged (from the real listenable)
    // is the only thing that should trigger further rebuilds; a LATER
    // destroy()/re-init cycle deliberately isn't chased here as it would
    // need this widget to also handle consentManager going back to null
    // mid-session, a state other consent-adjacent surfaces in this package
    // don't attempt either.
    if (_listenable != null) return;
    _attachListenable();
    if (_listenable != null) setState(() {});
  }

  @override
  void dispose() {
    AdManager().initRevision.removeListener(_onInitRevisionChanged);
    _listenable?.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final ready = _listenable != null;
    final value = ready ? AdManager().doNotSell : false;
    return SwitchListTile(
      title: Text(widget.strings.title),
      subtitle: Text(widget.strings.subtitle),
      value: value,
      onChanged: ready
          ? (v) {
              // Optimistic UI: setDoNotSell() persists asynchronously, but
              // ConsentManager.set()'s listenable notifies synchronously
              // (see AdManager's own listener comment), so the rebuild this
              // triggers already reflects the real new value by the time it
              // runs — no separate local state needed.
              AdManager().setDoNotSell(v);
            }
          : null,
    );
  }
}
