import 'package:flutter/material.dart';

@immutable
class AppThemeTokens extends ThemeExtension<AppThemeTokens> {
  final Color colorBg;
  final Color colorRaisedBg;
  final Color colorSuperRaisedBg;
  /// Divider / panel edge (surface-5): content border against raised chrome.
  final Color colorDivider;
  final Color colorBase;
  final Color colorSecondary;
  final Color colorContrast;
  final Color colorButtonBg;
  final Color colorButtonBorder;
  final Color colorBrand;
  final Color colorBrandHighlight;
  /// Text / icon color on solid brand buttons (primary CTA).
  final Color colorOnBrand;
  final Color colorButtonBgSelected;
  final Color colorButtonTextSelected;

  const AppThemeTokens({
    required this.colorBg,
    required this.colorRaisedBg,
    required this.colorSuperRaisedBg,
    required this.colorDivider,
    required this.colorBase,
    required this.colorSecondary,
    required this.colorContrast,
    required this.colorButtonBg,
    required this.colorButtonBorder,
    required this.colorBrand,
    required this.colorBrandHighlight,
    required this.colorOnBrand,
    required this.colorButtonBgSelected,
    required this.colorButtonTextSelected,
  });

  factory AppThemeTokens.fallback(ColorScheme colorScheme) {
    return AppThemeTokens(
      colorBg: colorScheme.surface,
      colorRaisedBg: colorScheme.surfaceContainerHigh,
      colorSuperRaisedBg: colorScheme.surfaceContainerHighest,
      colorDivider: colorScheme.surfaceBright,
      colorBase: colorScheme.onSurfaceVariant,
      colorSecondary: colorScheme.outline,
      colorContrast: colorScheme.onSurface,
      colorButtonBg: colorScheme.primaryContainer,
      colorButtonBorder: colorScheme.outlineVariant,
      colorBrand: colorScheme.secondary,
      colorBrandHighlight: colorScheme.secondary.withAlpha(64),
      colorOnBrand: const Color(0xFF0B0E0B),
      colorButtonBgSelected: colorScheme.secondary.withAlpha(64),
      colorButtonTextSelected: colorScheme.secondary,
    );
  }

  @override
  AppThemeTokens copyWith({
    Color? colorBg,
    Color? colorRaisedBg,
    Color? colorSuperRaisedBg,
    Color? colorDivider,
    Color? colorBase,
    Color? colorSecondary,
    Color? colorContrast,
    Color? colorButtonBg,
    Color? colorButtonBorder,
    Color? colorBrand,
    Color? colorBrandHighlight,
    Color? colorOnBrand,
    Color? colorButtonBgSelected,
    Color? colorButtonTextSelected,
  }) {
    return AppThemeTokens(
      colorBg: colorBg ?? this.colorBg,
      colorRaisedBg: colorRaisedBg ?? this.colorRaisedBg,
      colorSuperRaisedBg: colorSuperRaisedBg ?? this.colorSuperRaisedBg,
      colorDivider: colorDivider ?? this.colorDivider,
      colorBase: colorBase ?? this.colorBase,
      colorSecondary: colorSecondary ?? this.colorSecondary,
      colorContrast: colorContrast ?? this.colorContrast,
      colorButtonBg: colorButtonBg ?? this.colorButtonBg,
      colorButtonBorder: colorButtonBorder ?? this.colorButtonBorder,
      colorBrand: colorBrand ?? this.colorBrand,
      colorBrandHighlight: colorBrandHighlight ?? this.colorBrandHighlight,
      colorOnBrand: colorOnBrand ?? this.colorOnBrand,
      colorButtonBgSelected:
          colorButtonBgSelected ?? this.colorButtonBgSelected,
      colorButtonTextSelected:
          colorButtonTextSelected ?? this.colorButtonTextSelected,
    );
  }

  @override
  AppThemeTokens lerp(ThemeExtension<AppThemeTokens>? other, double t) {
    if (other is! AppThemeTokens) {
      return this;
    }

    return AppThemeTokens(
      colorBg: Color.lerp(colorBg, other.colorBg, t)!,
      colorRaisedBg: Color.lerp(colorRaisedBg, other.colorRaisedBg, t)!,
      colorSuperRaisedBg:
          Color.lerp(colorSuperRaisedBg, other.colorSuperRaisedBg, t)!,
      colorDivider: Color.lerp(colorDivider, other.colorDivider, t)!,
      colorBase: Color.lerp(colorBase, other.colorBase, t)!,
      colorSecondary: Color.lerp(colorSecondary, other.colorSecondary, t)!,
      colorContrast: Color.lerp(colorContrast, other.colorContrast, t)!,
      colorButtonBg: Color.lerp(colorButtonBg, other.colorButtonBg, t)!,
      colorButtonBorder:
          Color.lerp(colorButtonBorder, other.colorButtonBorder, t)!,
      colorBrand: Color.lerp(colorBrand, other.colorBrand, t)!,
      colorBrandHighlight:
          Color.lerp(colorBrandHighlight, other.colorBrandHighlight, t)!,
      colorOnBrand: Color.lerp(colorOnBrand, other.colorOnBrand, t)!,
      colorButtonBgSelected:
          Color.lerp(colorButtonBgSelected, other.colorButtonBgSelected, t)!,
      colorButtonTextSelected: Color.lerp(
          colorButtonTextSelected, other.colorButtonTextSelected, t)!,
    );
  }
}
