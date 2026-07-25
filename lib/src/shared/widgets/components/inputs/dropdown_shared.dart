import 'dart:math' as math;

import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

/// Shared anchored-overlay lifecycle for single-select and multi-select dropdowns.
class AnchoredDropdownController {
  AnchoredDropdownController({
    required TickerProvider vsync,
    required this.onOpenChanged,
  }) {
    animation = AnimationController(
      vsync: vsync,
      duration: const Duration(milliseconds: 150),
    );
    fade = CurvedAnimation(parent: animation, curve: Curves.easeOut);
  }

  final VoidCallback onOpenChanged;
  final LayerLink layerLink = LayerLink();
  late final AnimationController animation;
  late final Animation<double> fade;

  OverlayEntry? entry;
  bool isOpen = false;
  bool _closing = false;

  void dispose() {
    entry?.remove();
    entry = null;
    animation.dispose();
  }

  void toggle({
    required BuildContext context,
    required OverlayEntry Function() createEntry,
  }) {
    if (isOpen) {
      close();
    } else {
      open(context: context, createEntry: createEntry);
    }
  }

  void open({
    required BuildContext context,
    required OverlayEntry Function() createEntry,
  }) {
    if (_closing || isOpen) return;
    entry = createEntry();
    Overlay.of(context).insert(entry!);
    animation.forward(from: 0);
    isOpen = true;
    onOpenChanged();
  }

  void close() {
    if (!isOpen || _closing) return;
    _closing = true;
    animation.reverse().then((_) {
      entry?.remove();
      entry = null;
      _closing = false;
      isOpen = false;
      onOpenChanged();
    });
  }

  void scheduleRebuild() {
    if (!isOpen || _closing || entry == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!isOpen || _closing) return;
      entry?.markNeedsBuild();
    });
  }

  OverlayEntry buildEntry({
    required BuildContext context,
    required double minWidth,
    required double openUpThreshold,
    required Widget Function(BuildContext context, bool openUp) panelBuilder,
  }) {
    final renderBox = context.findRenderObject() as RenderBox;
    final triggerSize = renderBox.size;
    final triggerOffset = renderBox.localToGlobal(Offset.zero);
    final screen = MediaQuery.sizeOf(context);
    final width = math.max(minWidth, triggerSize.width);
    final spaceBelow =
        screen.height - triggerOffset.dy - triggerSize.height - 12;
    final openUp = spaceBelow < openUpThreshold && triggerOffset.dy > spaceBelow;

    return OverlayEntry(
      builder: (overlayContext) {
        return SizedBox(
          width: screen.width,
          height: screen.height,
          child: Stack(
            children: [
              Positioned.fill(
                child: GestureDetector(
                  behavior: HitTestBehavior.translucent,
                  onTap: close,
                ),
              ),
              CompositedTransformFollower(
                link: layerLink,
                showWhenUnlinked: false,
                targetAnchor:
                    openUp ? Alignment.topLeft : Alignment.bottomLeft,
                followerAnchor:
                    openUp ? Alignment.bottomLeft : Alignment.topLeft,
                offset: Offset(0, openUp ? -6 : 6),
                child: Material(
                  color: Colors.transparent,
                  child: FadeTransition(
                    opacity: fade,
                    child: GestureDetector(
                      onTap: () {},
                      child: SizedBox(
                        width: width,
                        child: panelBuilder(overlayContext, openUp),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

BoxDecoration dropdownPanelDecoration(
  AppThemeTokens tokens, {
  required bool openUp,
  double radius = 12,
}) {
  return BoxDecoration(
    color: tokens.colorButtonBg,
    borderRadius: BorderRadius.circular(radius),
    border: Border.all(
      color: tokens.colorSecondary.withValues(alpha: 0.28),
    ),
    boxShadow: [
      BoxShadow(
        color: Colors.black.withValues(alpha: 0.35),
        blurRadius: 20,
        offset: Offset(0, openUp ? -6 : 6),
      ),
    ],
  );
}

/// Trigger / row hover surface (desktop MouseRegion — InkWell hover is unreliable on Windows).
class DropdownHoverSurface extends StatefulWidget {
  const DropdownHoverSurface({
    super.key,
    required this.tokens,
    required this.onTap,
    required this.child,
    this.borderRadius,
    this.padding,
    this.margin,
    this.baseColor,
    this.hoverColor,
    this.selected = false,
    this.selectedColor,
    this.width,
    this.height,
  });

  final AppThemeTokens tokens;
  final VoidCallback onTap;
  final Widget child;
  final BorderRadius? borderRadius;
  final EdgeInsetsGeometry? padding;
  final EdgeInsetsGeometry? margin;
  final Color? baseColor;
  final Color? hoverColor;
  final bool selected;
  final Color? selectedColor;
  final double? width;
  final double? height;

  @override
  State<DropdownHoverSurface> createState() => _DropdownHoverSurfaceState();
}

class _DropdownHoverSurfaceState extends State<DropdownHoverSurface> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final radius = widget.borderRadius ?? BorderRadius.circular(10);
    Color bg;
    if (widget.selected) {
      bg = widget.selectedColor ?? widget.tokens.colorBrandHighlight;
      if (_hovered) {
        bg = Color.alphaBlend(
          widget.tokens.colorContrast.withValues(alpha: 0.08),
          bg,
        );
      }
    } else if (_hovered) {
      bg = widget.hoverColor ??
          Color.alphaBlend(
            widget.tokens.colorContrast.withValues(alpha: 0.08),
            widget.baseColor ?? widget.tokens.colorButtonBg,
          );
    } else {
      bg = widget.baseColor ?? widget.tokens.colorButtonBg;
    }

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          curve: Curves.easeOut,
          width: widget.width,
          height: widget.height,
          margin: widget.margin,
          padding: widget.padding,
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: bg,
            borderRadius: radius,
          ),
          child: widget.child,
        ),
      ),
    );
  }
}
