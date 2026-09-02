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
/// into a Settings/Privacy screen; it is intentionally NOT part of
/// [showConsentDialog]'s binary GDPR prompt (see that dialog's own doc
/// comment for why).
///
/// ```dart
/// // Anywhere after AdManager().initialize() has completed:
/// const CcpaOptOutToggle()
/// ```
///
/// Requires [AdManager().initialize] to have already completed — the
/// [ConsentManager] this reads from doesn't exist before then. Shown
/// disabled (with the same copy) if that hasn't happened yet, rather than
/// silently doing nothing when tapped.
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
    _listenable = AdManager().consentManager?.listenable;
    _listenable?.addListener(_onChanged);
  }

  @override
  void dispose() {
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
