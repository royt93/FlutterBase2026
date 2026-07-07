import 'package:flutter/material.dart';

// ignore_for_file: unused_field

/// Shimmer placeholder shown while the banner ad is loading.
/// Uses AnimationController + ShaderMask — no external library needed.
class ShimmerView extends StatefulWidget {
  final double cornerRadius;
  final double width;
  final double height;

  const ShimmerView({
    super.key,
    required this.cornerRadius,
    required this.width,
    required this.height,
  });

  @override
  State<ShimmerView> createState() => _ShimmerViewState();
}

class _ShimmerViewState extends State<ShimmerView>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  @override
  void initState() {
    super.initState();
    // T14 — guard against ever creating a second controller on top of an
    // existing one (leaks a Ticker). initState() only runs once per State
    // in normal Flutter lifecycle, but this makes that invariant explicit
    // and safe if a future refactor calls this path again.
    if (_controller != null) return;
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller?.dispose();
    _controller = null;
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final controller = _controller;
    if (controller == null) return const SizedBox();

    return AnimatedBuilder(
      animation: controller,
      builder: (context, child) {
        return ShaderMask(
          shaderCallback: (bounds) {
            final value = controller.value;
            return LinearGradient(
              begin: Alignment(-1.0 + (value * 3), -0.3),
              end: Alignment(1.0 + (value * 3), 0.3),
              colors: const [
                Color(0xFFE0E0E0),
                Color(0xFFF8F8F8),
                Color(0xFFE0E0E0),
              ],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(bounds);
          },
          child: Container(
            width: widget.width,
            height: widget.height,
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(widget.cornerRadius),
            ),
          ),
        );
      },
    );
  }
}
