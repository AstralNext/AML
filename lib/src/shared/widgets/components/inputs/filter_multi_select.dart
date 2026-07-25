import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_shared.dart';
import 'package:flutter/material.dart';

class FilterMultiSelectOption {
  const FilterMultiSelectOption({
    required this.value,
    required this.label,
  });

  final String value;
  final String label;
}

/// Multi-select filter dropdown (variant B): checkboxes, optional search/footer.
class FilterMultiSelect extends StatefulWidget {
  const FilterMultiSelect({
    super.key,
    required this.label,
    required this.options,
    required this.selected,
    required this.onChanged,
    required this.colorScheme,
    this.expand = false,
    this.searchable = false,
    this.searchPlaceholder = '搜索…',
    this.dropdownMinWidth = 240,
    this.maxHeight = 280,
    this.footerLabel,
    this.footerValue = false,
    this.onFooterChanged,
  });

  final String label;
  final List<FilterMultiSelectOption> options;
  final Set<String> selected;
  final ValueChanged<Set<String>> onChanged;
  final ColorScheme colorScheme;
  /// When true, the trigger fills the parent width (e.g. half-row layouts).
  final bool expand;
  final bool searchable;
  final String searchPlaceholder;
  final double dropdownMinWidth;
  final double maxHeight;
  final String? footerLabel;
  final bool footerValue;
  final ValueChanged<bool>? onFooterChanged;

  @override
  State<FilterMultiSelect> createState() => _FilterMultiSelectState();
}

class _FilterMultiSelectState extends State<FilterMultiSelect>
    with SingleTickerProviderStateMixin {
  late final AnchoredDropdownController _overlay;
  final TextEditingController _searchController = TextEditingController();
  String _query = '';

  AppThemeTokens get _tokens => AppThemeTokens.fallback(widget.colorScheme);

  bool get _active => widget.selected.isNotEmpty;

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
  void didUpdateWidget(covariant FilterMultiSelect oldWidget) {
    super.didUpdateWidget(oldWidget);
    _overlay.scheduleRebuild();
  }

  @override
  void dispose() {
    _overlay.dispose();
    _searchController.dispose();
    super.dispose();
  }

  List<FilterMultiSelectOption> get _filteredOptions {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return widget.options;
    return widget.options
        .where((o) => o.label.toLowerCase().contains(q))
        .toList();
  }

  void _toggleValue(String value) {
    final next = Set<String>.from(widget.selected);
    if (!next.add(value)) next.remove(value);
    widget.onChanged(next);
  }

  void _toggle() {
    _overlay.toggle(
      context: context,
      createEntry: () {
        _query = '';
        _searchController.clear();
        return _overlay.buildEntry(
          context: context,
          minWidth: widget.dropdownMinWidth,
          openUpThreshold: 220,
          panelBuilder: (context, openUp) {
            final tokens = _tokens;
            final options = _filteredOptions;
            return Container(
              decoration: dropdownPanelDecoration(
                tokens,
                openUp: openUp,
                radius: 14,
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (widget.searchable) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
                      child: TextField(
                        controller: _searchController,
                        autofocus: true,
                        onChanged: (v) {
                          _query = v;
                          _overlay.entry?.markNeedsBuild();
                        },
                        style: TextStyle(
                          fontSize: 14,
                          color: tokens.colorContrast,
                        ),
                        decoration: InputDecoration(
                          isDense: true,
                          hintText: widget.searchPlaceholder,
                          hintStyle: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.55),
                            fontSize: 14,
                          ),
                          prefixIcon: Icon(
                            Icons.search_rounded,
                            size: 20,
                            color: tokens.colorBase.withValues(alpha: 0.65),
                          ),
                          prefixIconConstraints: const BoxConstraints(
                            minWidth: 36,
                            minHeight: 32,
                          ),
                          border: InputBorder.none,
                          contentPadding:
                              const EdgeInsets.symmetric(vertical: 8),
                        ),
                      ),
                    ),
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: tokens.colorSecondary.withValues(alpha: 0.22),
                    ),
                  ],
                  if (options.isEmpty)
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                        '无结果',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    )
                  else
                    ConstrainedBox(
                      constraints:
                          BoxConstraints(maxHeight: widget.maxHeight),
                      child: ListView.builder(
                        padding: EdgeInsets.zero,
                        shrinkWrap: true,
                        itemCount: options.length,
                        itemBuilder: (context, index) {
                          final opt = options[index];
                          return _CheckboxRow(
                            tokens: tokens,
                            label: opt.label,
                            checked: widget.selected.contains(opt.value),
                            onTap: () => _toggleValue(opt.value),
                          );
                        },
                      ),
                    ),
                  if (widget.footerLabel != null &&
                      widget.onFooterChanged != null) ...[
                    Divider(
                      height: 1,
                      thickness: 1,
                      color: tokens.colorSecondary.withValues(alpha: 0.22),
                    ),
                    _CheckboxRow(
                      tokens: tokens,
                      label: widget.footerLabel!,
                      checked: widget.footerValue,
                      onTap: () => widget
                          .onFooterChanged!(!widget.footerValue),
                    ),
                  ],
                ],
              ),
            );
          },
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    return CompositedTransformTarget(
      link: _overlay.layerLink,
      child: DropdownHoverSurface(
        tokens: tokens,
        borderRadius: BorderRadius.circular(10),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        width: widget.expand ? double.infinity : null,
        baseColor: _active
            ? tokens.colorBrandHighlight
            : tokens.colorButtonBg.withValues(alpha: 0.9),
        selected: _active,
        selectedColor: tokens.colorBrandHighlight,
        hoverColor: _active
            ? Color.alphaBlend(
                tokens.colorBrand.withValues(alpha: 0.12),
                tokens.colorBrandHighlight,
              )
            : null,
        onTap: _toggle,
        child: Row(
          mainAxisSize:
              widget.expand ? MainAxisSize.max : MainAxisSize.min,
          children: [
            Icon(
              Icons.filter_list_rounded,
              size: 16,
              color: _active
                  ? tokens.colorBrand
                  : tokens.colorBase.withValues(alpha: 0.75),
            ),
            const SizedBox(width: 6),
            if (widget.expand)
              Expanded(
                child: Text(
                  widget.label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: _active ? tokens.colorBrand : tokens.colorContrast,
                  ),
                ),
              )
            else
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: _active ? tokens.colorBrand : tokens.colorContrast,
                ),
              ),
            const SizedBox(width: 4),
            AnimatedRotation(
              turns: _overlay.isOpen ? 0.5 : 0,
              duration: const Duration(milliseconds: 150),
              child: Icon(
                Icons.expand_more,
                size: 18,
                color: tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CheckboxRow extends StatelessWidget {
  const _CheckboxRow({
    required this.tokens,
    required this.label,
    required this.checked,
    required this.onTap,
  });

  final AppThemeTokens tokens;
  final String label;
  final bool checked;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return DropdownHoverSurface(
      tokens: tokens,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
      baseColor: tokens.colorButtonBg,
      child: Row(
        children: [
          AnimatedContainer(
            duration: const Duration(milliseconds: 120),
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: checked ? tokens.colorBrand : tokens.colorRaisedBg,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: checked
                    ? tokens.colorBrand
                    : tokens.colorSecondary.withValues(alpha: 0.45),
                width: 1.2,
              ),
            ),
            child: checked
                ? Icon(
                    Icons.check_rounded,
                    size: 14,
                    color: tokens.colorOnBrand,
                  )
                : null,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: tokens.colorContrast,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
