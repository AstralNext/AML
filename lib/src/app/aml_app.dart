import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/features/shell/ui/main_screen.dart' show MainScreen;
import 'package:aml/src/shared/theme/color_schemes.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class AmlApp extends StatefulWidget {
  const AmlApp({super.key});

  @override
  State<AmlApp> createState() => _AmlAppState();
}

class _AmlAppState extends State<AmlApp> {
  @override
  Widget build(BuildContext context) {
    final uiSettings = getIt<UiSettingsState>();
    return Watch((context) {
      final selectedThemeId = uiSettings.themePresetId.watch(context);
      final selectedPreset = getThemePresetById(selectedThemeId);
      final baseTheme = ThemeData(
        colorScheme: selectedPreset.colorScheme,
        useMaterial3: true,
        fontFamily: 'MiSans',
        extensions: [selectedPreset.tokens],
      );

      return MaterialApp(
        scaffoldMessengerKey: appMessengerKey,
        debugShowCheckedModeBanner: false,
        theme: baseTheme.copyWith(
          textTheme: baseTheme.textTheme.apply(fontFamily: 'MiSans'),
          primaryTextTheme:
              baseTheme.primaryTextTheme.apply(fontFamily: 'MiSans'),
          // primary matches button/surface gray; use brand for text selection.
          textSelectionTheme: TextSelectionThemeData(
            cursorColor: selectedPreset.colorScheme.secondary,
            selectionColor:
                selectedPreset.colorScheme.secondary.withAlpha(64),
            selectionHandleColor: selectedPreset.colorScheme.secondary,
          ),
          // ColorScheme.primary is a muted surface gray (button bg),
          // but M3 TextButton uses primary as foreground — override for contrast.
          textButtonTheme: TextButtonThemeData(
            style: TextButton.styleFrom(
              foregroundColor: selectedPreset.colorScheme.secondary,
            ),
          ),
        ),
        home: const MainScreen(),
      );
    });
  }
}
