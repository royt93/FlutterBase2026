import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HapticFeedback;

import 'consent_dialog_strings.dart';
import 'consent_settings.dart';

/// Result of [showConsentDialog]: either a settings update, or null if the
/// user dismissed without choosing.
typedef ConsentDialogResult = ConsentSettings?;

const _kDialogRadius = 24.0;
const _kAccent = Color(0xFF6366F1); // indigo-500
const _kRejectFg = Color(0xFF64748B); // slate-500

/// Show the binary consent dialog (Allow / Reject).
///
/// A custom Material [Dialog] (not a stock CupertinoAlertDialog) — gives us
/// space for a hero icon, hierarchical typography, soft shadows, and accent
/// colours without forcing the host app to style anything.
///
/// **Why binary only?** [ConsentSettings.isAgeRestrictedUser] (COPPA) is an
/// app-level property — set by the developer if the app targets children,
/// not chosen per-user — configured in code via [ConsentManager.set], not
/// exposed as a toggle here. Real-world apps (Spotify, Twitter, etc.) all
/// use a single binary "Allow personalized ads?" prompt for the GDPR/
/// generic-consent case this dialog covers.
///
/// Round-31 audit fix — [ConsentSettings.doNotSell] (CCPA/CPRA, Cal. Civ.
/// Code §1798.135) does NOT belong in the "app-level, developer-set" bucket
/// this comment used to lump it into: CCPA specifically requires "Do Not
/// Sell/Share" to be an end-user-executable choice, not a hardcoded
/// constant. This binary dialog still doesn't need to grow a CCPA toggle —
/// see `CcpaOptOutToggle` for a dedicated, opt-in widget a California-
/// facing host can show separately (e.g. in a Settings/Privacy screen).
///
/// Returns the updated [ConsentSettings] (`hasBeenAsked = true`) or `null`
/// if dismissed without choice (only possible when [barrierDismissible]).
Future<ConsentDialogResult> showConsentDialog(
  BuildContext context, {
  required ConsentDialogStrings strings,
  required ConsentSettings current,
  bool barrierDismissible = false,
  void Function(String url)? onPrivacyPolicyTap,
}) {
  return showGeneralDialog<ConsentSettings>(
    context: context,
    barrierDismissible: barrierDismissible,
    barrierLabel: strings.title,
    barrierColor: Colors.black.withValues(alpha: 0.55),
    transitionDuration: const Duration(milliseconds: 280),
    transitionBuilder: (_, anim, __, child) {
      final curve = CurvedAnimation(parent: anim, curve: Curves.easeOutCubic);
      return Opacity(
        opacity: curve.value,
        child: Transform.scale(
          scale: 0.92 + (curve.value * 0.08),
          child: child,
        ),
      );
    },
    // Round-29 audit (MINOR) — `barrierDismissible` only gates tapping
    // outside the dialog; it never blocked the Android system back
    // button/gesture, which called `Navigator.maybePop()` and popped this
    // route anyway, defeating the "force an explicit choice" intent
    // `barrierDismissible: false` (the default) communicates. `PopScope`
    // covers both escape routes with the one flag.
    pageBuilder: (ctx, _, __) => PopScope(
      canPop: barrierDismissible,
      child: _ConsentBinaryDialog(
        strings: strings,
        current: current,
        onPrivacyPolicyTap: onPrivacyPolicyTap,
      ),
    ),
  );
}

class _ConsentBinaryDialog extends StatelessWidget {
  const _ConsentBinaryDialog({
    required this.strings,
    required this.current,
    required this.onPrivacyPolicyTap,
  });

  final ConsentDialogStrings strings;
  final ConsentSettings current;
  final void Function(String url)? onPrivacyPolicyTap;

  @override
  Widget build(BuildContext context) {
    final policyUrl = strings.privacyPolicyUrl;
    return Center(
      child: Material(
        color: Colors.transparent,
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 24),
          constraints: const BoxConstraints(maxWidth: 380),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(_kDialogRadius),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.18),
                blurRadius: 32,
                offset: const Offset(0, 12),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 28),
              // Hero icon: shield in a soft gradient circle.
              Container(
                width: 72,
                height: 72,
                decoration: const BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: LinearGradient(
                    colors: [_kAccent, Color(0xFF8B5CF6)], // indigo → violet
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Color(0x336366F1),
                      blurRadius: 20,
                      offset: Offset(0, 8),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.privacy_tip_rounded,
                  color: Colors.white,
                  size: 36,
                ),
              ),
              const SizedBox(height: 20),
              // Title.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  strings.title,
                  textAlign: TextAlign.center,
                  style: const TextStyle(
                    fontSize: 19,
                    fontWeight: FontWeight.w700,
                    height: 1.25,
                  ),
                ),
              ),
              const SizedBox(height: 12),
              // Body.
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 28),
                child: Text(
                  strings.message,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.45,
                    color: Theme.of(context)
                        .colorScheme
                        .onSurface
                        .withValues(alpha: 0.72),
                  ),
                ),
              ),
              if (strings.adPartnersLabel != null) ...[
                const SizedBox(height: 8),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  child: Text(
                    strings.adPartnersLabel!,
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 11.5,
                      color: Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                    ),
                  ),
                ),
              ],
              if (policyUrl != null) ...[
                const SizedBox(height: 12),
                // ponytail: Semantics(button:true) wrapper — bare InkWell
                // exposes no distinct tappable a11y node (same gap found +
                // fixed in vip_redeem_screen.dart's ACTIVATE button).
                Semantics(
                  button: true,
                  label: strings.privacyPolicyLabel,
                  child: InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => onPrivacyPolicyTap?.call(policyUrl),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: 12, vertical: 6),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.open_in_new_rounded,
                              size: 14, color: _kAccent),
                          const SizedBox(width: 6),
                          Text(
                            strings.privacyPolicyLabel,
                            style: const TextStyle(
                              color: _kAccent,
                              fontWeight: FontWeight.w600,
                              fontSize: 13,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
              const SizedBox(height: 24),
              // Buttons.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  children: [
                    // Round-29 audit (MINOR) — Reject used to get `flex: 1`
                    // against Allow's `flex: 2` (half the width), on top of
                    // its own ghost/outline style vs Allow's filled gradient
                    // + shadow. Not a real EEA-compliance violation (this
                    // dialog isn't the UMP form Google's EEA/UK consent flow
                    // actually uses — see the class doc above), but equal
                    // width removes any ambiguity for a defensive minimum.
                    Expanded(
                      child: _RejectButton(
                        label: strings.rejectButton,
                        onTap: () {
                          HapticFeedback.lightImpact();
                          Navigator.of(context, rootNavigator: true).pop(
                            current.copyWith(
                              hasUserConsent: false,
                              hasBeenAsked: true,
                              askedAt: DateTime.now(),
                            ),
                          );
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _AllowButton(
                        label: strings.allowButton,
                        onTap: () {
                          HapticFeedback.mediumImpact();
                          Navigator.of(context, rootNavigator: true).pop(
                            current.copyWith(
                              hasUserConsent: true,
                              hasBeenAsked: true,
                              askedAt: DateTime.now(),
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AllowButton extends StatelessWidget {
  const _AllowButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      // ponytail: Semantics(button:true) — bare InkWell exposes no distinct
      // tappable a11y node (same gap found + fixed in vip_redeem_screen.dart's
      // ACTIVATE button); this is the primary GDPR-consent action.
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Ink(
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              gradient: const LinearGradient(
                colors: [_kAccent, Color(0xFF8B5CF6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              boxShadow: const [
                BoxShadow(
                  color: Color(0x556366F1),
                  blurRadius: 14,
                  offset: Offset(0, 6),
                ),
              ],
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w700,
                    fontSize: 15,
                    letterSpacing: 0.2,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _RejectButton extends StatelessWidget {
  const _RejectButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      // ponytail: same Semantics(button:true) fix as _AllowButton above.
      child: Semantics(
        button: true,
        label: label,
        child: InkWell(
          borderRadius: BorderRadius.circular(14),
          onTap: onTap,
          child: Container(
            height: 50,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: _kRejectFg.withValues(alpha: 0.25),
                width: 1.2,
              ),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Center(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                  label,
                  maxLines: 1,
                  style: const TextStyle(
                    color: _kRejectFg,
                    fontWeight: FontWeight.w600,
                    fontSize: 14,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
