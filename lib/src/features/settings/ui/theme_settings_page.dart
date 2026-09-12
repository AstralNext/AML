import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/shared/theme/color_schemes.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class ThemeSettingsPage extends StatelessWidget {
  const ThemeSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final uiSettings = getIt<UiSettingsState>();
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Watch(
        (_) {
          final selectedThemeId = uiSettings.themePresetId.watch(context);
          final selectedTheme = getThemePresetById(selectedThemeId);
          final dropdownItems = appThemePresets
              .map((preset) =>
                  DropdownItem(display: preset.name, value: preset.id))
              .toList();

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                '主题设置',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                '手动切换主题配色（不跟随系统主题）',
                style: TextStyle(
                  fontSize: 14,
                  color: tokens.colorBase.withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                '主题预设',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              SizedBox(
                width: 260,
                child: DropdownButtonWidget(
                  items: dropdownItems,
                  selectedValue: selectedThemeId,
                  colorScheme: colorScheme,
                  onChanged: (value) => uiSettings.themePresetId.value = value,
                ),
              ),
              const SizedBox(height: 20),
              Container(
                width: 420,
                padding: const EdgeInsets.all(14),
                decoration: BoxDecoration(
                  color: selectedTheme.tokens.colorRaisedBg,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: selectedTheme.tokens.colorSecondary.withValues(
                      alpha: 0.4,
                    ),
                  ),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 32,
                      height: 32,
                      decoration: BoxDecoration(
                        color: selectedTheme.tokens.colorBrand,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '当前主题：${selectedTheme.name}',
                        style: TextStyle(
                          color: selectedTheme.tokens.colorContrast,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}
