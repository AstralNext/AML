import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

/// Soft pulsing placeholder block for loading states.
class SkeletonBox extends StatefulWidget {
  const SkeletonBox({
    super.key,
    required this.tokens,
    this.width,
    this.height = 14,
    this.borderRadius,
  });

  final AppThemeTokens tokens;
  final double? width;
  final double height;
  final BorderRadius? borderRadius;

  @override
  State<SkeletonBox> createState() => _SkeletonBoxState();
}

class _SkeletonBoxState extends State<SkeletonBox>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
    _t = CurvedAnimation(parent: _controller, curve: Curves.easeInOut);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final base = widget.tokens.colorSuperRaisedBg;
    final highlight = Color.alphaBlend(
      widget.tokens.colorContrast.withValues(alpha: 0.1),
      base,
    );
    return AnimatedBuilder(
      animation: _t,
      builder: (context, _) {
        return Container(
          width: widget.width,
          height: widget.height,
          decoration: BoxDecoration(
            color: Color.lerp(base, highlight, _t.value),
            borderRadius: widget.borderRadius ?? BorderRadius.circular(8),
          ),
        );
      },
    );
  }
}
