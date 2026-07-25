import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

class HoverTextWithArrow extends StatefulWidget {
  final String text;
  final TextStyle? textStyle;
  final VoidCallback? onTap;
  final double arrowSize;
  final double arrowOffset;
  final Duration animationDuration;

  const HoverTextWithArrow({
    super.key,
    required this.text,
    this.textStyle,
    this.onTap,
    this.arrowSize = 24,
    this.arrowOffset = 6,
    this.animationDuration = const Duration(milliseconds: 80),
  });

  @override
  State<HoverTextWithArrow> createState() => _HoverTextWithArrowState();
}

class _HoverTextWithArrowState extends State<HoverTextWithArrow> {
  bool _isHovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final defaultTextStyle = TextStyle(
      fontSize: 20,
      fontWeight: FontWeight.w800,
      color: tokens.colorContrast,
    );

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.text,
                style: (widget.textStyle ?? defaultTextStyle).copyWith(
                  decoration: _isHovered
                      ? TextDecoration.underline
                      : TextDecoration.none,
                  decorationColor:
                      widget.textStyle?.color ?? defaultTextStyle.color!,
                  decorationThickness: 2,
                ),
              ),
              const SizedBox(width: 8),
              AnimatedContainer(
                duration: widget.animationDuration,
                transform: Matrix4.translationValues(
                  _isHovered ? widget.arrowOffset : 0.0,
                  0.0,
                  0.0,
                ),
                child: Align(
                  alignment: Alignment.center,
                  child: Icon(
                    Icons.chevron_right,
                    color: widget.textStyle?.color ?? defaultTextStyle.color!,
                    size: widget.arrowSize,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
