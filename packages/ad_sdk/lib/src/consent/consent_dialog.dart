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
/// **Why binary only?** Other privacy flags ([ConsentSettings.isAgeRestrictedUser],
/// [ConsentSettings.doNotSell]) are app-level properties (e.g., COPPA is set
/// by the developer if the app targets children, not chosen per-user) — they
/// should be configured in code via [ConsentManager.set], not exposed as
/// user-facing toggles. Real-world apps (Spotify, Twitter, etc.) all use a
/// single binary "Allow personalized ads?" prompt.
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
    pageBuilder: (ctx, _, __) => _ConsentBinaryDialog(
      strings: strings,
      current: current,
      onPrivacyPolicyTap: onPrivacyPolicyTap,
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
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.72),
                  ),
                ),
              ),
              if (policyUrl != null) ...[
                const SizedBox(height: 12),
                InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => onPrivacyPolicyTap?.call(policyUrl),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Icon(Icons.open_in_new_rounded, size: 14, color: _kAccent),
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
              ],
              const SizedBox(height: 24),
              // Buttons.
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                child: Row(
                  children: [
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
                      flex: 2,
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
          child: Center(
            child: Text(
              label,
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
          child: Center(
            child: Text(
              label,
              style: const TextStyle(
                color: _kRejectFg,
                fontWeight: FontWeight.w600,
                fontSize: 14,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
