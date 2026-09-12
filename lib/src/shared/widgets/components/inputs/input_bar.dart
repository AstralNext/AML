import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

enum InputBarSize { large, medium, small }

class InputBarWidget extends StatefulWidget {
  const InputBarWidget({
    super.key,
    required this.colorScheme,
    this.onChanged,
    this.onSubmitted,
    this.onFocusChange,
    this.hintText,
    this.prefixIcon,
    this.size = InputBarSize.large,
    this.tailIcon,
    this.tailIconOnTap,
    this.obscureText = false,
    this.controller,
    this.focusNode,
  });

  final ColorScheme colorScheme;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final ValueChanged<bool>? onFocusChange;
  final String? hintText;
  final Widget? prefixIcon;
  final InputBarSize size;
  final Widget? tailIcon;
  final VoidCallback? tailIconOnTap;
  final bool obscureText;
  final TextEditingController? controller;
  final FocusNode? focusNode;

  @override
  State<InputBarWidget> createState() => _InputBarWidgetState();
}

class _InputBarWidgetState extends State<InputBarWidget> {
  late FocusNode _focusNode;
  late TextEditingController _controller;
  bool _ownsFocusNode = false;
  bool _isFocused = false;

  @override
  void initState() {
    super.initState();
    _ownsFocusNode = widget.focusNode == null;
    _focusNode = widget.focusNode ?? FocusNode();
    _controller = widget.controller ?? TextEditingController();
    _focusNode.addListener(_handleFocusChange);
  }

  void _handleFocusChange() {
    final focused = _focusNode.hasFocus;
    if (_isFocused != focused) {
      setState(() => _isFocused = focused);
      widget.onFocusChange?.call(focused);
    }
  }

  @override
  void dispose() {
    _focusNode.removeListener(_handleFocusChange);
    if (_ownsFocusNode) {
      _focusNode.dispose();
    }
    // 只有当controller是内部创建的时候才dispose
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.fallback(widget.colorScheme);
    double height;
    double iconSize;
    double fontSize;
    EdgeInsets contentPadding;
    String hintText;
    switch (widget.size) {
      case InputBarSize.large:
        height = 48;
        iconSize = 24;
        fontSize = 20;
        contentPadding = const EdgeInsets.symmetric(horizontal: 16);
        hintText = widget.hintText ?? '输入内容';
        break;
      case InputBarSize.medium:
        height = 35;
        iconSize = 20;
        fontSize = 16;
        contentPadding = const EdgeInsets.symmetric(horizontal: 12);
        hintText = widget.hintText ?? '请输入';
        break;
      case InputBarSize.small:
        height = 20;
        iconSize = 16;
        fontSize = 12;
        contentPadding = const EdgeInsets.symmetric(horizontal: 8);
        hintText = widget.hintText ?? '填';
        break;
    }

    return Container(
      height: height,
      decoration: BoxDecoration(
        color: tokens.colorButtonBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 140),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isFocused
                ? tokens.colorBrand.withValues(alpha: 0.4)
                : Colors.transparent,
            width: 4,
          ),
        ),
        child: Center(
          child: TextField(
            controller: _controller,
            focusNode: _focusNode,
            onChanged: widget.onChanged,
            onSubmitted: widget.onSubmitted,
            textAlign: TextAlign.left,
            obscureText: widget.obscureText,
            textInputAction: TextInputAction.done,
            decoration: InputDecoration(
              hintText: hintText,
              prefixIcon: widget.prefixIcon != null
                  ? IconTheme(
                      data: IconThemeData(
                        size: iconSize,
                        color: tokens.colorBase,
                      ),
                      child: widget.prefixIcon!,
                    )
                  : null,
              suffixIcon: widget.tailIcon != null
                  ? GestureDetector(
                      onTap: widget.tailIconOnTap,
                      child: IconTheme(
                        data: IconThemeData(size: iconSize),
                        child: widget.tailIcon!,
                      ),
                    )
                  : null,
              border: InputBorder.none,
              contentPadding: contentPadding,
              isDense: true,
            ),
            style: TextStyle(
              color: tokens.colorBase,
              fontSize: fontSize,
            ),
            cursorColor: tokens.colorBrand,
          ),
        ),
      ),
    );
  }
}
