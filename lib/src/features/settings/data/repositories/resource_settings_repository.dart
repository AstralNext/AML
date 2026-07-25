import 'dart:convert';
import 'dart:io';

import 'package:aml/src/features/settings/domain/models/resource_settings.dart';
import 'package:path/path.dart' as p;

class ResourceSettingsRepository {
  ResourceSettingsRepository({required this.baseDir});

  final String baseDir;

  File get _settingsFile => File(p.join(baseDir, 'resource_settings.json'));

  Future<ResourceSettings> load() async {
    try {
      final file = _settingsFile;
      if (!await file.exists()) {
        return ResourceSettings.defaults(baseDir);
      }

      final content = await file.readAsString(encoding: utf8);
      final json = jsonDecode(content) as Map<String, dynamic>;
      return ResourceSettings.fromJson(json, baseDir: baseDir);
    } catch (_) {
      return ResourceSettings.defaults(baseDir);
    }
  }

  Future<void> save(ResourceSettings settings) async {
    final file = _settingsFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(settings.toJson()),
      encoding: utf8,
    );
  }
}
