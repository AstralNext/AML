import 'dart:async';
import 'dart:io';

import 'package:aml/src/features/settings/data/repositories/resource_settings_repository.dart';
import 'package:aml/src/features/settings/domain/models/resource_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';

class ResourceSettingsState {
  ResourceSettingsState(this._repository);

  final resourceDirectory = signal('');

  final ResourceSettingsRepository _repository;
  bool _initialized = false;
  bool _hydrating = false;
  Timer? _saveDebounce;
  VoidCallback? _disposeEffect;

  Future<void> initialize() async {
    if (_initialized) return;
    _hydrating = true;

    final settings = await _repository.load();
    await _applySettings(settings);

    _hydrating = false;
    _initialized = true;

    _disposeEffect = effect(() {
      if (_hydrating) return;
      _scheduleSave(_snapshotSettings());
    });
  }

  Future<void> _applySettings(ResourceSettings settings) async {
    final resolvedResourceDir = settings.resourceDirectory.isEmpty
        ? p.join(_repository.baseDir, 'resourceDirectory')
        : settings.resourceDirectory;

    resourceDirectory.value = resolvedResourceDir;
    final directory = Directory(resolvedResourceDir);
    if (!await directory.exists()) {
      await directory.create(recursive: true);
    }
  }

  ResourceSettings _snapshotSettings() {
    final resolvedResourceDir = resourceDirectory.value.isEmpty
        ? p.join(_repository.baseDir, 'resourceDirectory')
        : resourceDirectory.value;

    return ResourceSettings(resourceDirectory: resolvedResourceDir);
  }

  void _scheduleSave(ResourceSettings settings) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _repository.save(settings);
      } catch (e) {
        debugPrint('保存资源设置失败: $e');
      }
    });
  }

  Future<void> dispose() async {
    _disposeEffect?.call();
    _saveDebounce?.cancel();
  }
}
