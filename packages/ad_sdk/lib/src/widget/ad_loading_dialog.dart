import 'package:flutter/material.dart';

import '../core/ad_manager.dart';

/// Loading dialog shown before a fullscreen ad (inter / rewarded / app-open).
///
/// - Cannot be dismissed via back button, swipe, or tap outside
/// - Auto-dismisses after [durationMs] ms, then calls [onComplete]
///
/// The [durationMs] defaults to [AdManager]'s configured [AdConfig.loadingBufferMs].
class AdLoadingDialog {
  /// Show the buffer dialog and call [onComplete] after the delay.
  static Future<void> showAdBuffer(
    BuildContext context, {
    required VoidCallback onComplete,
    int? durationMs,
  }) async {
    final ms = durationMs ?? 1000;
    final timer = Future.delayed(Duration(milliseconds: ms));

    showDialog(
      context: context,
      barrierDismissible: false,
      barrierColor: Colors.black.withValues(alpha: 0.72),
      builder: (ctx) => _AdLoadingDialogContent(
        loadingText: AdManager().config?.adLoadingMessage ?? 'Loading…',
      ),
    );

    await timer;

    if (context.mounted) {
      Navigator.of(context, rootNavigator: true).pop();
    }

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
