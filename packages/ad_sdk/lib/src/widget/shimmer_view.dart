import 'package:flutter/material.dart';

/// Shimmer placeholder shown while ads are loading.
class ShimmerView extends StatefulWidget {
  final double cornerRadius;
  final double width;
  final double height;
  final bool active;
  final Color? baseColor;
  final Color? highlightColor;
  final Color? backgroundColor;

  const ShimmerView({
    super.key,
    required this.cornerRadius,
    required this.width,
    required this.height,
    this.active = true,
    this.baseColor,
    this.highlightColor,
    this.backgroundColor,
  });

  @override
  State<ShimmerView> createState() => _ShimmerViewState();
}

class _ShimmerViewState extends State<ShimmerView>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  AnimationController? _controller;
  final ValueNotifier<bool> _isBackgrounded = ValueNotifier<bool>(false);

  @visibleForTesting
  bool get debugIsAnimating => _controller?.isAnimating ?? false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _isBackgrounded.value = _isBackground(
      WidgetsBinding.instance.lifecycleState,
    );
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    );
    if (widget.active && !_isBackgrounded.value) _controller?.repeat();
  }

  // inactive is excluded on purpose: on Android it also fires while the app
  // is still visible (split-screen, notification shade, system dialogs).
  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.paused || state == AppLifecycleState.hidden;

  @override
  void didUpdateWidget(ShimmerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.active != oldWidget.active) {
      if (widget.active && !_isBackgrounded.value) {
        _controller?.repeat();
      } else {
        _controller?.stop();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_isBackground(state)) {
      _isBackgrounded.value = true;
      _controller?.stop();
    } else {
      _isBackgrounded.value = false;
      if (widget.active) _controller?.repeat();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller?.dispose();
    _controller = null;
    _isBackgrounded.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base =
        widget.baseColor ??
        (isDark ? const Color(0xFF2A2A2A) : const Color(0xFFE0E0E0));
    final highlight =
        widget.highlightColor ??
        (isDark ? const Color(0xFF383838) : const Color(0xFFF8F8F8));
    final bg =
        widget.backgroundColor ??
        (isDark ? const Color(0xFF1E1E1E) : Colors.white);

    Widget staticBox() => Container(
      width: widget.width,
      height: widget.height,
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(widget.cornerRadius),
      ),
    );

    if (!widget.active || _controller == null) return staticBox();

    final controller = _controller!;
    return ValueListenableBuilder<bool>(
      valueListenable: _isBackgrounded,
      builder: (context, backgrounded, _) {
        if (backgrounded) return staticBox();
        return AnimatedBuilder(
          animation: controller,
          builder: (context, child) {
            return ShaderMask(
              blendMode: BlendMode.srcIn,
              shaderCallback: (bounds) {
                final value = controller.value;
                return LinearGradient(
                  begin: Alignment(-1.0 + (value * 3), -0.3),
                  end: Alignment(1.0 + (value * 3), 0.3),
                  colors: [base, highlight, base],
                  stops: const [0.0, 0.5, 1.0],
                ).createShader(bounds);
              },
              child: Container(
                width: widget.width,
                height: widget.height,
                decoration: BoxDecoration(
                  color: bg,
                  borderRadius: BorderRadius.circular(widget.cornerRadius),
                ),
              ),
            );
          },
        );
      },
    );
  }
}
