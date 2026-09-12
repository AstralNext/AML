import 'package:aml/src/app/app_store.dart';
import 'package:aml/src/app/state/minecraft_state.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/app/state/pending_launch_state.dart';
import 'package:aml/src/app/state/progress_state.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/app/window_tray_controller.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/features/java/data/rust_java_download.dart';
import 'package:aml/src/features/settings/application/app_update_service.dart';
import 'package:aml/src/features/settings/application/java_settings_state.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/application/settings_registry.dart';
import 'package:aml/src/features/settings/application/storage_usage_service.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/features/settings/data/repositories/java_settings_repository.dart';
import 'package:aml/src/features/settings/data/repositories/resource_settings_repository.dart';
import 'package:aml/src/features/settings/data/repositories/ui_settings_repository.dart';
import 'package:aml/src/features/wardrobe/application/skin_store.dart';
import 'package:get_it/get_it.dart';

final getIt = GetIt.instance;

void setupServiceLocator({required String appDataDir}) {
  if (!getIt.isRegistered<String>(instanceName: 'appDataDir')) {
    getIt.registerSingleton<String>(appDataDir, instanceName: 'appDataDir');
  }

  if (!getIt.isRegistered<PendingLaunchState>()) {
    getIt.registerSingleton<PendingLaunchState>(PendingLaunchState());
  }

  if (!getIt.isRegistered<UiSettingsRepository>()) {
    getIt.registerLazySingleton<UiSettingsRepository>(
      () => UiSettingsRepository(baseDir: getIt<String>(instanceName: 'appDataDir')),
    );
  }
  if (!getIt.isRegistered<JavaSettingsRepository>()) {
    getIt.registerLazySingleton<JavaSettingsRepository>(
      () => JavaSettingsRepository(baseDir: getIt<String>(instanceName: 'appDataDir')),
    );
  }
  if (!getIt.isRegistered<ResourceSettingsRepository>()) {
    getIt.registerLazySingleton<ResourceSettingsRepository>(
      () => ResourceSettingsRepository(baseDir: getIt<String>(instanceName: 'appDataDir')),
    );
  }

  if (!getIt.isRegistered<RustJavaDownloadDataSource>()) {
    getIt.registerLazySingleton<RustJavaDownloadDataSource>(
      RustJavaDownloadDataSource.new,
    );
  }
  if (!getIt.isRegistered<JavaDownloadService>()) {
    getIt.registerLazySingleton<JavaDownloadService>(
      () => JavaDownloadService(
        dataSource: getIt<RustJavaDownloadDataSource>(),
        runtimeState: getIt<RuntimeState>(),
        progressStore: getIt<ProgressStore>(),
      ),
    );
  }

  if (!getIt.isRegistered<NavigationState>()) {
    getIt.registerSingleton<NavigationState>(NavigationState());
  }
  if (!getIt.isRegistered<RuntimeState>()) {
    getIt.registerSingleton<RuntimeState>(RuntimeState());
  }
  if (!getIt.isRegistered<MinecraftState>()) {
    getIt.registerSingleton<MinecraftState>(MinecraftState());
  }
  if (!getIt.isRegistered<ProgressStore>()) {
    getIt.registerSingleton<ProgressStore>(ProgressStore());
  }
  if (!getIt.isRegistered<UiSettingsState>()) {
    getIt.registerSingleton<UiSettingsState>(
      UiSettingsState(getIt<UiSettingsRepository>()),
    );
  }
  if (!getIt.isRegistered<JavaSettingsState>()) {
    getIt.registerSingleton<JavaSettingsState>(
      JavaSettingsState(getIt<JavaSettingsRepository>()),
    );
  }
  if (!getIt.isRegistered<ResourceSettingsState>()) {
    getIt.registerSingleton<ResourceSettingsState>(
      ResourceSettingsState(getIt<ResourceSettingsRepository>()),
    );
  }
  if (!getIt.isRegistered<StorageUsageService>()) {
    getIt.registerLazySingleton<StorageUsageService>(StorageUsageService.new);
  }
  if (!getIt.isRegistered<AppUpdateService>()) {
    getIt.registerLazySingleton<AppUpdateService>(AppUpdateService.new);
  }
  if (!getIt.isRegistered<SettingsRegistry>()) {
    getIt.registerSingleton<SettingsRegistry>(
      SettingsRegistry(
        java: getIt<JavaSettingsState>(),
        resource: getIt<ResourceSettingsState>(),
        ui: getIt<UiSettingsState>(),
      ),
    );
  }
  if (!getIt.isRegistered<InstanceStore>()) {
    getIt.registerSingleton<InstanceStore>(InstanceStore());
  }
  if (!getIt.isRegistered<AccountStore>()) {
    getIt.registerSingleton<AccountStore>(AccountStore());
  }
  if (!getIt.isRegistered<AccountAvatarCache>()) {
    getIt.registerSingleton<AccountAvatarCache>(AccountAvatarCache());
  }
  if (!getIt.isRegistered<SkinStore>()) {
    getIt.registerSingleton<SkinStore>(SkinStore());
  }
  if (!getIt.isRegistered<WindowTrayController>()) {
    getIt.registerSingleton<WindowTrayController>(WindowTrayController());
  }

  if (!getIt.isRegistered<AppStore>()) {
    getIt.registerSingleton<AppStore>(
      AppStore(
        navigation: getIt<NavigationState>(),
        runtime: getIt<RuntimeState>(),
        settings: getIt<SettingsRegistry>(),
      ),
    );
  }
}
