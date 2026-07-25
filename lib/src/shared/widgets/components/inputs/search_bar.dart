import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

enum SearchBarSize { large, medium, small }

class SearchBarWidget extends StatefulWidget {
  const SearchBarWidget({
    super.key,
    required this.colorScheme,
    this.controller,
    this.onChanged,
    this.onSubmitted,
    this.hintText,
    this.prefixIcon,
    this.size = SearchBarSize.large,
    this.tailIcon,
    this.tailIconOnTap,
  });

  final ColorScheme colorScheme;
  final TextEditingController? controller;
  final ValueChanged<String>? onChanged;
  final ValueChanged<String>? onSubmitted;
  final String? hintText;
  final Widget? prefixIcon;
  final SearchBarSize size;
  final Widget? tailIcon;
  final VoidCallback? tailIconOnTap;

  @override
  State<SearchBarWidget> createState() => _SearchBarWidgetState();
}

class _SearchBarWidgetState extends State<SearchBarWidget> {
  late FocusNode _focusNode;
  late TextEditingController _controller;
  bool _isFocused = false;
  bool _ownsController = false;

  @override
  void initState() {
    super.initState();
    _focusNode = FocusNode();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? TextEditingController();
    _focusNode.addListener(() {
      setState(() {
        _isFocused = _focusNode.hasFocus;
      });
    });
  }

  void _clear() {
    _controller.clear();
    setState(() {});
    widget.onChanged?.call('');
    widget.onSubmitted?.call('');
  }

  void _handleChanged(String value) {
    setState(() {});
    widget.onChanged?.call(value);
  }

  void _handleSubmitted(String value) {
    widget.onSubmitted?.call(value);
  }

  @override
  void dispose() {
    _focusNode.dispose();
    if (_ownsController) {
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
      case SearchBarSize.large:
        height = 48;
        iconSize = 24;
        fontSize = 20;
        contentPadding =
            const EdgeInsets.only(left: 16, right: 16, top: 12, bottom: 12);
        hintText = widget.hintText ?? '搜索';
        break;
      case SearchBarSize.medium:
        height = 35;
        iconSize = 20;
        fontSize = 15;
        contentPadding =
            const EdgeInsets.only(left: 12, right: 12, top: 6, bottom: 6);
        hintText = widget.hintText ?? '输入关键字';
        break;
      case SearchBarSize.small:
        height = 20;
        iconSize = 16;
        fontSize = 12;
        contentPadding =
            const EdgeInsets.only(left: 8, right: 8, top: 2, bottom: 2);
        hintText = widget.hintText ?? '搜';
        break;
    }
    return Container(
      height: height,
      decoration: BoxDecoration(
        color: tokens.colorButtonBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: _isFocused
                ? tokens.colorBrand.withValues(alpha: 0.4)
                : Colors.transparent,
            width: 4,
          ),
        ),
        child: TextField(
          controller: _controller,
          focusNode: _focusNode,
          onChanged: _handleChanged,
          onSubmitted: widget.onSubmitted == null ? null : _handleSubmitted,
          textInputAction: widget.onSubmitted == null
              ? TextInputAction.done
              : TextInputAction.search,
          textAlign: TextAlign.left,
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
            suffixIcon: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_controller.text.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.clear, size: iconSize),
                    onPressed: _clear,
                  ),
                if (widget.tailIcon != null)
                  GestureDetector(
                    onTap: widget.tailIconOnTap,
                    child: IconTheme(
                      data: IconThemeData(size: iconSize),
                      child: widget.tailIcon!,
                    ),
                  ),
              ],
            ),
            border: InputBorder.none,
            contentPadding: contentPadding,
          ),
          style: TextStyle(
            color: tokens.colorBase,
            fontSize: fontSize,
          ),
          cursorColor: tokens.colorBrand,
        ),
      ),
    );
  }
}
