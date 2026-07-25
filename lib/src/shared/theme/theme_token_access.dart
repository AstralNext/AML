import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

extension ThemeTokenAccess on BuildContext {
  AppThemeTokens get tokens {
    final theme = Theme.of(this);
    return theme.extension<AppThemeTokens>() ??
        AppThemeTokens.fallback(theme.colorScheme);
  }
}
