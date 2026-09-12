import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/features/settings/application/settings_registry.dart';
class AppStore {
  AppStore({
    required this.navigation,
    required this.runtime,
    required this.settings,
  });

  final NavigationState navigation;
  final RuntimeState runtime;
  final SettingsRegistry settings;

  Future<void> initialize() async {
    await settings.initialize();
  }

  Future<void> dispose() async {
    await settings.dispose();
  }
}

