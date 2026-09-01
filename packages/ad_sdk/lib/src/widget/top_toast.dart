import 'dart:async';
import 'dart:ui';
import 'package:flutter/material.dart';
import '../utils/safe_logger.dart';

/// Displays a beautiful animated toast at the top-center of the screen.
///
/// Uses an [OverlayEntry] so it floats above all content with no Scaffold dependency.
/// Animates with slide-down + fade-in on show, and slide-up + fade-out on dismiss.
/// Supports glassmorphism styling with a glowing icon.
///
/// Usage:
/// ```dart
/// TopToast.show(
///   context,
///   icon: Icons.hourglass_top,
///   message: 'Ad not ready — please try again.',
/// );
/// ```
class TopToast {
  TopToast._();

  static OverlayEntry? _current;

  /// Shows the toast. Dismisses any existing one first.
  static void show(
    BuildContext context, {
    required IconData icon,
    required String message,
    Color iconColor = const Color(0xFFFFA726),
    Color bgColor = const Color(0xFF1E1E2E),
    Duration duration = const Duration(seconds: 3),
  }) {
    SafeLogger.d('TopToast', '🍞 show() message="$message"');
    try {
      _dismiss();
      final overlay = Overlay.of(context, rootOverlay: true);
      late final OverlayEntry entry;
      entry = OverlayEntry(
        builder: (_) => _TopToastWidget(
          icon: icon,
          message: message,
          iconColor: iconColor,
          bgColor: bgColor,
          duration: duration,
          // Round-27 backlog B4 — NOT the plain `_dismiss` (which always
          // tears down whatever `_current` is right now, regardless of who
          // is calling). A's own manual-tap dismiss firing after `show()`
          // already swapped `_current` to B must not remove B. Only remove
          // if this entry is still the one actually on screen.
          onDismiss: () => _dismissIfCurrent(entry),
        ),
      );
      _current = entry;
      overlay.insert(entry);
      SafeLogger.d('TopToast', '✅ inserted into overlay');
    } catch (e, st) {
      SafeLogger.e('TopToast', '❌ show() failed: $e\n$st');
    }
  }

  static void _dismiss() {
    final entry = _current;
    _current = null;
    if (entry == null) return;
    try {
      entry.remove();
    } catch (_) {
      // OverlayEntry already removed (e.g. widget disposed by navigation)
    }
  }

  /// Round-27 backlog B4 — the identity-scoped half of the fix: only tears
  /// down [_current] if [entry] is still it. A toast whose own auto-dismiss
  /// timer or manual tap fires after a NEWER toast already replaced it as
  /// [_current] must be a no-op, not remove the newer one out from under it.
  static void _dismissIfCurrent(OverlayEntry entry) {
    if (!identical(_current, entry)) return;
    _dismiss();
  }
}

// ─────────────────────────────────────────────────────────────────────────────

class _TopToastWidget extends StatefulWidget {
  const _TopToastWidget({
    required this.icon,
    required this.message,
    required this.iconColor,
    required this.bgColor,
    required this.duration,
    required this.onDismiss,
  });

  final IconData icon;
  final String message;
  final Color iconColor;
  final Color bgColor;
  final Duration duration;
  final VoidCallback onDismiss;

  @override
  State<_TopToastWidget> createState() => _TopToastWidgetState();
}

class _TopToastWidgetState extends State<_TopToastWidget>
    with SingleTickerProviderStateMixin {
  AnimationController? _ctrl;
  Animation<double>? _opacity;
  Animation<Offset>? _slide;
  Timer? _autoDismissTimer;

  @override
  void initState() {
    super.initState();
    final ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 380),
    );
    _ctrl = ctrl;
    _opacity = CurvedAnimation(parent: ctrl, curve: Curves.easeOut);
    _slide = Tween<Offset>(
      begin: const Offset(0, -1.4),
      end: Offset.zero,
    ).animate(CurvedAnimation(parent: ctrl, curve: Curves.easeOutBack));

    ctrl.forward();
    // Round-27 backlog B4 — a cancellable Timer, not a bare Future.delayed:
    // dispose() below cancels it, so a toast superseded before its own
    // duration elapses can never fire its dismiss at all (the identity
    // check in TopToast._dismissIfCurrent is the remaining defense for the
    // OTHER trigger, a manual tap racing a supersede — see onTap below).
    _autoDismissTimer = Timer(widget.duration, _animateOut);
  }

  Future<void> _animateOut() async {
    if (!mounted) return;
    final ctrl = _ctrl;
    if (ctrl == null) return;
    // Round-29 audit (MINOR) — a plain `await ctrl.reverse()` never
    // completes if `dispose()` runs mid-reverse (a superseding toast calls
    // `entry.remove()` directly, bypassing this animation): `Ticker.dispose()`
    // only completes the `.orCancel` completer, not the primary one a bare
    // `await` waits on. That permanently suspended continuation (holding
    // `this`/`widget`/the disposed controller) leaked for the rest of the
    // process. `.orCancel` + catching `TickerCanceled` gives this a way out.
    try {
      await ctrl.reverse().orCancel;
    } on TickerCanceled {
      return;
    }
    if (!mounted) return;
    widget.onDismiss();
  }

  @override
  void dispose() {
    _autoDismissTimer?.cancel();
    _autoDismissTimer = null;
    _ctrl?.dispose();
    _ctrl = null;
    _opacity = null;
    _slide = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final topPadding = MediaQuery.of(context).padding.top + 12;
    final slide = _slide;
    final opacity = _opacity;
    if (slide == null || opacity == null) return const SizedBox.shrink();
    return Positioned(
      top: topPadding,
      left: 24,
      right: 24,
      child: SlideTransition(
        position: slide,
        child: FadeTransition(
          opacity: opacity,
          child: Material(
            color: Colors.transparent,
            child: GestureDetector(
              onTap: _animateOut,
              child: ClipRRect(
                borderRadius: BorderRadius.circular(20),
                child: BackdropFilter(
                  filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 14,
                    ),
                    decoration: BoxDecoration(
                      color: widget.bgColor.withValues(alpha: 0.88),
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(
                        color: widget.iconColor.withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 24,
                          offset: const Offset(0, 8),
                        ),
                        BoxShadow(
                          color: widget.iconColor.withValues(alpha: 0.12),
                          blurRadius: 16,
                          spreadRadius: 2,
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        // Glowing icon badge
                        Container(
                          padding: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: widget.iconColor.withValues(alpha: 0.15),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            widget.icon,
                            color: widget.iconColor,
                            size: 22,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Message text
                        Flexible(
                          child: Text(
                            widget.message,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              height: 1.4,
                            ),
                          ),
                        ),
                      ],
                    ),
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
