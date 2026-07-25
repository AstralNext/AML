import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

class AppThemePreset {
  final String id;
  final String name;
  final ColorScheme colorScheme;
  final AppThemeTokens tokens;

  const AppThemePreset({
    required this.id,
    required this.name,
    required this.colorScheme,
    required this.tokens,
  });
}

const String defaultThemePresetId = 'dark';

// Color tokens for the default dark preset.
const ColorScheme darkColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFF34363C),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFF34363C),
  onPrimaryContainer: Color(0xFFFFFFFF),
  secondary: Color(0xFF1BD96A),
  onSecondary: Color(0xFF000000),
  secondaryContainer: Color(0x401BD96A),
  onSecondaryContainer: Color(0xFF1BD96A),
  tertiary: Color(0xFF27292E),
  onTertiary: Color(0xFF1BD96A),
  tertiaryContainer: Color(0xFF34363C),
  onTertiaryContainer: Color(0xFFFFFFFF),
  error: Color(0xFFED1148),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0x40ED1148),
  onErrorContainer: Color(0xFFFFCAD3),
  surface: Color(0xFF16181C),
  onSurface: Color(0xFFFFFFFF),
  surfaceDim: Color(0xFF1A1C20),
  surfaceBright: Color(0xFF42444A),
  surfaceContainerLowest: Color(0xFF16181C),
  surfaceContainerLow: Color(0xFF1D1F23),
  surfaceContainer: Color(0xFF222429),
  surfaceContainerHigh: Color(0xFF27292E),
  surfaceContainerHighest: Color(0xFF34363C),
  onSurfaceVariant: Color(0xFFB0BAC5),
  outline: Color(0xFF96A2B0),
  outlineVariant: Color(0xFF646C75),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFFFFFFF),
  onInverseSurface: Color(0xFF16181C),
  inversePrimary: Color(0xFF0FAA4F),
  surfaceTint: Color(0xFF1BD96A),
);

const ColorScheme lightColorScheme = ColorScheme(
  brightness: Brightness.light,
  primary: Color(0xFFFFFFFF),
  onPrimary: Color(0xFF1A202C),
  primaryContainer: Color(0xFFFFFFFF),
  onPrimaryContainer: Color(0xFF1A202C),
  secondary: Color(0xFF00AF5C),
  onSecondary: Color(0xFFFFFFFF),
  secondaryContainer: Color(0xFF00AF5C),
  onSecondaryContainer: Color(0xFFFFFFFF),
  tertiary: Color(0xFFF8F8F8),
  onTertiary: Color(0xFFFFFFFF),
  tertiaryContainer: Color(0xFFFFFFFF),
  onTertiaryContainer: Color(0xFF1A202C),
  error: Color(0xFFCB2245),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0x40CB2245),
  onErrorContainer: Color(0xFFFCCFD3),
  surface: Color(0xFFEBEBEB),
  onSurface: Color(0xFF1A202C),
  surfaceDim: Color(0xFFEDEDED),
  surfaceBright: Color(0xFFFFFFFF),
  surfaceContainerLowest: Color(0xFFEBEBEB),
  surfaceContainerLow: Color(0xFFF5F5F5),
  surfaceContainer: Color(0xFFEEF1F5),
  surfaceContainerHigh: Color(0xFFF8F8F8),
  surfaceContainerHighest: Color(0xFFFFFFFF),
  onSurfaceVariant: Color(0xFF2C2E31),
  outline: Color(0xFF484D54),
  outlineVariant: Color(0x59A1A1A1),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFF1A202C),
  onInverseSurface: Color(0xFFFFFFFF),
  inversePrimary: Color(0xFF00AF5C),
  surfaceTint: Color(0xFF00AF5C),
);

const ColorScheme oledColorScheme = ColorScheme(
  brightness: Brightness.dark,
  primary: Color(0xFF1B1B20),
  onPrimary: Color(0xFFFFFFFF),
  primaryContainer: Color(0xFF1B1B20),
  onPrimaryContainer: Color(0xFFFFFFFF),
  secondary: Color(0xFF1BD96A),
  onSecondary: Color(0xFF000000),
  secondaryContainer: Color(0x401BD96A),
  onSecondaryContainer: Color(0xFF1BD96A),
  tertiary: Color(0xFF101013),
  onTertiary: Color(0xFF1BD96A),
  tertiaryContainer: Color(0xFF1B1B20),
  onTertiaryContainer: Color(0xFFFFFFFF),
  error: Color(0xFFED1148),
  onError: Color(0xFFFFFFFF),
  errorContainer: Color(0x40ED1148),
  onErrorContainer: Color(0xFFFFCAD3),
  surface: Color(0xFF000000),
  onSurface: Color(0xFFFFFFFF),
  surfaceDim: Color(0xFF050506),
  surfaceBright: Color(0xFF25262B),
  surfaceContainerLowest: Color(0xFF000000),
  surfaceContainerLow: Color(0xFF09090A),
  surfaceContainer: Color(0xFF0C0D11),
  surfaceContainerHigh: Color(0xFF101013),
  surfaceContainerHighest: Color(0xFF1B1B20),
  onSurfaceVariant: Color(0xFFB0BAC5),
  outline: Color(0xFF96A2B0),
  outlineVariant: Color(0xFF646C75),
  shadow: Color(0xFF000000),
  scrim: Color(0xFF000000),
  inverseSurface: Color(0xFFFFFFFF),
  onInverseSurface: Color(0xFF000000),
  inversePrimary: Color(0xFF0FAA4F),
  surfaceTint: Color(0xFF1BD96A),
);

const AppThemeTokens darkThemeTokens = AppThemeTokens(
  colorBg: Color(0xFF16181C),
  colorRaisedBg: Color(0xFF27292E),
  colorSuperRaisedBg: Color(0xFF34363C),
  colorDivider: Color(0xFF42444A),
  colorBase: Color(0xFFB0BAC5),
  colorSecondary: Color(0xFF96A2B0),
  colorContrast: Color(0xFFFFFFFF),
  colorButtonBg: Color(0xFF34363C),
  colorButtonBorder: Color(0x1FC1BED1),
  colorBrand: Color(0xFF1BD96A),
  colorBrandHighlight: Color(0x401BD96A),
  colorOnBrand: Color(0xFF0B0E0B),
  colorButtonBgSelected: Color(0x401BD96A),
  colorButtonTextSelected: Color(0xFF1BD96A),
);

const AppThemeTokens lightThemeTokens = AppThemeTokens(
  colorBg: Color(0xFFEBEBEB),
  colorRaisedBg: Color(0xFFF8F8F8),
  colorSuperRaisedBg: Color(0xFFFFFFFF),
  colorDivider: Color(0xFFDDDDDD),
  colorBase: Color(0xFF2C2E31),
  colorSecondary: Color(0xFF484D54),
  colorContrast: Color(0xFF1A202C),
  colorButtonBg: Color(0xFFFFFFFF),
  colorButtonBorder: Color(0x59A1A1A1),
  colorBrand: Color(0xFF00AF5C),
  colorBrandHighlight: Color(0x4000AF5C),
  colorOnBrand: Color(0xFFFFFFFF),
  colorButtonBgSelected: Color(0xFF00AF5C),
  colorButtonTextSelected: Color(0xFFFFFFFF),
);

const AppThemeTokens oledThemeTokens = AppThemeTokens(
  colorBg: Color(0xFF000000),
  colorRaisedBg: Color(0xFF101013),
  colorSuperRaisedBg: Color(0xFF1B1B20),
  colorDivider: Color(0xFF25262B),
  colorBase: Color(0xFFB0BAC5),
  colorSecondary: Color(0xFF96A2B0),
  colorContrast: Color(0xFFFFFFFF),
  colorButtonBg: Color(0xFF1B1B20),
  colorButtonBorder: Color(0x1FC1BED1),
  colorBrand: Color(0xFF1BD96A),
  colorBrandHighlight: Color(0x401BD96A),
  colorOnBrand: Color(0xFF0B0E0B),
  colorButtonBgSelected: Color(0x401BD96A),
  colorButtonTextSelected: Color(0xFF1BD96A),
);

const List<AppThemePreset> appThemePresets = [
  AppThemePreset(
    id: defaultThemePresetId,
    name: '深色',
    colorScheme: darkColorScheme,
    tokens: darkThemeTokens,
  ),
  AppThemePreset(
    id: 'light',
    name: '浅色',
    colorScheme: lightColorScheme,
    tokens: lightThemeTokens,
  ),
  AppThemePreset(
    id: 'oled',
    name: 'OLED',
    colorScheme: oledColorScheme,
    tokens: oledThemeTokens,
  ),
];

AppThemePreset getThemePresetById(String id) {
  return appThemePresets.firstWhere(
    (preset) => preset.id == id,
    orElse: () => appThemePresets.first,
  );
}
