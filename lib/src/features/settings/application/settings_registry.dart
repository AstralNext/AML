import 'package:aml/src/features/settings/application/java_settings_state.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';

class SettingsRegistry {
  SettingsRegistry({
    required this.java,
    required this.resource,
    required this.ui,
  });

  final JavaSettingsState java;
  final ResourceSettingsState resource;
  final UiSettingsState ui;

  Future<void> initialize() async {
    await java.initialize();
    await resource.initialize();
    await ui.initialize();
  }

  Future<void> dispose() async {
    await java.dispose();
    await resource.dispose();
    await ui.dispose();
  }
}
