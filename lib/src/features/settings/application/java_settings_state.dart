import 'dart:async';

import 'package:aml/src/features/settings/data/repositories/java_settings_repository.dart';
import 'package:aml/src/features/settings/domain/models/java_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';

class JavaSettingsState {
  JavaSettingsState(this._repository);

  final java8Directory = signal('');
  final java17Directory = signal('');
  final java21Directory = signal('');
  final java25Directory = signal('');

  final JavaSettingsRepository _repository;
  bool _initialized = false;
  bool _hydrating = false;
  Timer? _saveDebounce;
  VoidCallback? _disposeEffect;

  Future<void> initialize() async {
    if (_initialized) return;
    _hydrating = true;

    final settings = await _repository.load();
    _applySettings(settings);

    _hydrating = false;
    _initialized = true;

    _disposeEffect = effect(() {
      if (_hydrating) return;
      _scheduleSave(_snapshotSettings());
    });
  }

  void _applySettings(JavaSettings settings) {
    java8Directory.value =
        JavaSettings.canonicalizeExecutablePath(settings.java8Path);
    java17Directory.value =
        JavaSettings.canonicalizeExecutablePath(settings.java17Path);
    java21Directory.value =
        JavaSettings.canonicalizeExecutablePath(settings.java21Path);
    java25Directory.value =
        JavaSettings.canonicalizeExecutablePath(settings.java25Path);
  }

  JavaSettings _snapshotSettings() {
    return JavaSettings(
      java8Path: JavaSettings.canonicalizeExecutablePath(java8Directory.value),
      java17Path: JavaSettings.canonicalizeExecutablePath(java17Directory.value),
      java21Path: JavaSettings.canonicalizeExecutablePath(java21Directory.value),
      java25Path: JavaSettings.canonicalizeExecutablePath(java25Directory.value),
    );
  }

  Signal<String> pathSignalForMajor(int major) {
    switch (JavaSettings.settingsSlotForMajor(major)) {
      case 8:
        return java8Directory;
      case 17:
        return java17Directory;
      case 21:
        return java21Directory;
      default:
        return java25Directory;
    }
  }

  String pathForMajor(int major) => pathSignalForMajor(major).value;

  void setPathForMajor(int major, String path) {
    pathSignalForMajor(major).value =
        JavaSettings.canonicalizeExecutablePath(path);
  }

  void _scheduleSave(JavaSettings settings) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _repository.save(settings);
      } catch (e) {
        debugPrint('保存 Java 设置失败: $e');
      }
    });
  }

  Future<void> dispose() async {
    _disposeEffect?.call();
    _saveDebounce?.cancel();
  }
}
