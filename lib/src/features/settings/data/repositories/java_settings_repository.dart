import 'dart:convert';
import 'dart:io';

import 'package:aml/src/features/settings/domain/models/java_settings.dart';
import 'package:path/path.dart' as p;

class JavaSettingsRepository {
  JavaSettingsRepository({required this.baseDir});

  final String baseDir;

  File get _settingsFile => File(p.join(baseDir, 'java_settings.json'));

  Future<JavaSettings> load() async {
    try {
      final file = _settingsFile;
      if (!await file.exists()) {
        return JavaSettings.defaults();
      }

      final content = await file.readAsString(encoding: utf8);
      final json = jsonDecode(content) as Map<String, dynamic>;
      return JavaSettings.fromJson(json);
    } catch (_) {
      return JavaSettings.defaults();
    }
  }

  Future<void> save(JavaSettings settings) async {
    final file = _settingsFile;
    await file.parent.create(recursive: true);
    await file.writeAsString(
      jsonEncode(settings.toJson()),
      encoding: utf8,
    );
  }
}
