import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_shared.dart';
import 'package:flutter/material.dart';

class DropdownItem {
  final String display;
  final String value;

  const DropdownItem({required this.display, required this.value});
}

/// Single-select dropdown (variant A): `前缀 + 当前值`, green selected row.
class DropdownButtonWidget extends StatefulWidget {
  const DropdownButtonWidget({
    super.key,
    this.width,
    this.height = 36,
    this.dropdownMinWidth,
    required this.items,
    required this.onChanged,
    required this.colorScheme,
    required this.selectedValue,
    this.prefix,
    this.footerLabel,
    this.footerValue = false,
    this.onFooterChanged,
  });

  final double? width;
  final double height;
  /// Panel min width when [width] is null; defaults to [width] or 160.
  final double? dropdownMinWidth;
  final List<DropdownItem> items;
  final ValueChanged<String> onChanged;
  final ColorScheme colorScheme;
  final String selectedValue;
  final String? prefix;
  final String? footerLabel;
  final bool footerValue;
  final ValueChanged<bool>? onFooterChanged;

  @override
  State<DropdownButtonWidget> createState() => _DropdownButtonWidgetState();
}

class _DropdownButtonWidgetState extends State<DropdownButtonWidget>
    with SingleTickerProviderStateMixin {
  late final AnchoredDropdownController _overlay;

  AppThemeTokens get _tokens =>
      AppThemeTokens.fallback(widget.colorScheme);

  DropdownItem get _selectedItem => widget.items.firstWhere(
        (item) => item.value == widget.selectedValue,
        orElse: () => DropdownItem(
          display: widget.selectedValue,
          value: widget.selectedValue,
        ),
      );

  @override
  void initState() {
    super.initState();
    _overlay = AnchoredDropdownController(
      vsync: this,
      onOpenChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void didUpdateWidget(covariant DropdownButtonWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    _overlay.scheduleRebuild();
  }

  @override
  void dispose() {
    _overlay.dispose();
    super.dispose();
  }

  void _toggle() {
    final panelMinWidth =
        widget.dropdownMinWidth ?? widget.width ?? 160;
    _overlay.toggle(
      context: context,
      createEntry: () => _overlay.buildEntry(
        context: context,
        minWidth: panelMinWidth,
        openUpThreshold: 200,
        panelBuilder: (context, openUp) {
          final tokens = _tokens;
          final hasFooter =
              widget.footerLabel != null && widget.onFooterChanged != null;
          return Container(
            decoration: dropdownPanelDecoration(tokens, openUp: openUp),
            clipBehavior: Clip.antiAlias,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: hasFooter ? 360 : 320,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: ListView.builder(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      shrinkWrap: true,
                      itemCount: widget.items.length,
                      itemBuilder: (context, index) {
                        final item = widget.items[index];
                        final selected = widget.selectedValue == item.value;
                        return DropdownHoverSurface(
                          tokens: tokens,
                          selected: selected,
                          selectedColor: tokens.colorBrandHighlight,
                          borderRadius: BorderRadius.circular(8),
                          margin: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          baseColor: tokens.colorButtonBg,
                          onTap: () {
                            widget.onChanged(item.value);
                            _overlay.close();
                          },
                          child: Text(
                            item.display,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                              color: selected
                                  ? tokens.colorBrand
                                  : tokens.colorContrast,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (hasFooter) ...[
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: tokens.colorSecondary.withValues(alpha: 0.22),
                    ),
                    DropdownHoverSurface(
                      tokens: tokens,
                      borderRadius: BorderRadius.zero,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                      baseColor: tokens.colorButtonBg,
                      onTap: () =>
                          widget.onFooterChanged!(!widget.footerValue),
                      child: Row(
                        children: [
                          Icon(
                            widget.footerValue
                                ? Icons.visibility_off_outlined
                                : Icons.visibility_outlined,
                            size: 16,
                            color: tokens.colorBase.withValues(alpha: 0.75),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              widget.footerLabel!,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: tokens.colorContrast,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    return CompositedTransformTarget(
      link: _overlay.layerLink,
      child: DropdownHoverSurface(
        tokens: tokens,
        width: widget.width,
        height: widget.height,
        borderRadius: BorderRadius.circular(10),
        padding: const EdgeInsets.symmetric(horizontal: 12),
        baseColor: tokens.colorButtonBg.withValues(alpha: 0.95),
        onTap: _toggle,
        child: Row(
          mainAxisSize:
              widget.width == null ? MainAxisSize.min : MainAxisSize.max,
          children: [
            if (widget.width == null)
              Text.rich(
                TextSpan(
                  children: [
                    if (widget.prefix != null)
                      TextSpan(
                        text: widget.prefix,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: tokens.colorBase.withValues(alpha: 0.85),
                        ),
                      ),
                    TextSpan(
                      text: _selectedItem.display,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ],
                ),
              )
            else
              Flexible(
                child: Text.rich(
                  TextSpan(
                    children: [
                      if (widget.prefix != null)
                        TextSpan(
                          text: widget.prefix,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                            color: tokens.colorBase.withValues(alpha: 0.85),
                          ),
                        ),
                      TextSpan(
                        text: _selectedItem.display,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ],
                  ),
                  overflow: TextOverflow.ellipsis,
                  maxLines: 1,
                ),
              ),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _overlay.isOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.expand_more,
                size: 18,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
