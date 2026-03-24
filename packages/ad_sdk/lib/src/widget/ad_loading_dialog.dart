import 'package:flutter/material.dart';

import '../core/ad_manager.dart';
import '../utils/safe_logger.dart';

/// Loading dialog shown before a fullscreen ad (inter / rewarded / app-open).
///
/// - Cannot be dismissed via back button, swipe, or tap outside
/// - Auto-dismisses after [durationMs] ms, then calls [onComplete]
///
/// The [durationMs] defaults to [AdManager]'s configured [AdConfig.loadingBufferMs].
class AdLoadingDialog {
  static const String _tag = 'AdLoadingDialog';

  /// Guard against concurrent calls (e.g. double-tap).
  /// If a dialog is already showing, the new call skips the dialog and
  /// immediately invokes [onComplete] — the caller still runs its ad flow.
  static bool _isShowing = false;

  /// Whether a loading dialog is currently on screen.
  /// Used by [AdManager.canShowInterstitial] / [canShowRewardedAd] to block
  /// a second ad flow while the first dialog buffer is still active.
  static bool get isShowing => _isShowing;

  /// Reset static state — called by [AdManager.destroy()] to ensure
  /// _isShowing doesn't stay stuck true after a mid-dialog destroy.
  static void resetState() {
    _isShowing = false;
  }

  /// Show the buffer dialog and call [onComplete] after the delay.
  ///
  /// [onComplete] is **always** called — even if the context becomes unmounted
  /// during the delay — so callers must guard with `mounted` checks themselves.
  static Future<void> showAdBuffer(
    BuildContext context, {
    required VoidCallback onComplete,
    int? durationMs,
  }) async {
    final ms = durationMs ?? AdManager().config?.loadingBufferMs ?? 1000;

    // ✅ FIX 1: Concurrent guard — prevents double-tap from stacking two dialogs.
    // If two dialogs stack, the first navigator.pop() dismisses the WRONG dialog.
    if (_isShowing) {
      SafeLogger.w(_tag, 'showAdBuffer: ⚠️ dialog already showing, skipping duplicate — calling onComplete immediately');
      onComplete();
      return;
    }

    _isShowing = true;
    SafeLogger.d(_tag, 'showAdBuffer: showing dialog, bufferMs=$ms');

    // ✅ FIX 2 (from 1.0.8): capture NavigatorState BEFORE any async gap.
    // NavigatorState is owned by the navigator widget (lives at app root),
    // NOT by the screen's State. It survives even when the screen is disposed.
    // Old code: checked `context.mounted` AFTER await → if screen was disposed
    // during the wait, pop() was skipped → dialog hangs forever.
    final navigator = Navigator.of(context, rootNavigator: true);

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (ctx) => _AdLoadingDialogContent(
        loadingText: AdManager().config?.adLoadingMessage ?? 'Loading…',
      ),
    );

    await Future.delayed(Duration(milliseconds: ms));

    // Always dismiss via pre-captured navigator — context.mounted is irrelevant here
    SafeLogger.d(_tag, 'showAdBuffer: timer done, dismissing dialog');
    try {
      navigator.pop();
      SafeLogger.d(_tag, 'showAdBuffer: dialog dismissed ✅');
    } catch (e) {
      // Only reachable if the navigator itself was disposed (app shutting down)
      SafeLogger.e(_tag, 'showAdBuffer: pop failed (navigator disposed?): $e');
    } finally {
      _isShowing = false;
    }

    // Always call onComplete — screen-side callers guard with mounted/isDisposed
    SafeLogger.d(_tag, 'showAdBuffer: calling onComplete()');
    onComplete();
  }
}

class _AdLoadingDialogContent extends StatefulWidget {
  const _AdLoadingDialogContent({required this.loadingText});

  final String loadingText;

  @override
  State<_AdLoadingDialogContent> createState() => _AdLoadingDialogContentState();
}

class _AdLoadingDialogContentState extends State<_AdLoadingDialogContent>
    with SingleTickerProviderStateMixin {
  late AnimationController _fadeController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _fadeAnimation = CurvedAnimation(parent: _fadeController, curve: Curves.easeOut);
    _fadeController.forward();
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: false,
      child: FadeTransition(
        opacity: _fadeAnimation,
        child: Center(
          child: Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.10),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  width: 44,
                  height: 44,
                  child: CircularProgressIndicator(
                    strokeWidth: 3.5,
                    valueColor: AlwaysStoppedAnimation<Color>(
                      Colors.white.withValues(alpha: 0.90),
                    ),
                    backgroundColor: Colors.white.withValues(alpha: 0.18),
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  widget.loadingText,
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.82),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    letterSpacing: 0.3,
                    decoration: TextDecoration.none,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
