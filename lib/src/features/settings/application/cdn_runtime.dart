import 'dart:convert';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/domain/models/ui_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// In-memory CDN flags used by Discover HTTP, plus `cdn_settings.json` for Rust.
class CdnRuntime {
  CdnRuntime._();

  static const mcimHost = 'https://mod.mcimirror.top';
  static const pysioHost = 'https://mcim-files.pysio.online';

  static bool officialFirst = false;
  static bool mcim = true;
  static bool pysio = true;
  static bool bmclapi = true;

  static void apply(UiSettings settings) {
    officialFirst = settings.cdnOfficialFirst;
    mcim = settings.cdnMcim;
    pysio = settings.cdnPysio;
    bmclapi = settings.cdnBmclapi;
  }

  static Map<String, dynamic> toJson() => {
        'officialFirst': officialFirst,
        'mcim': mcim,
        'pysio': pysio,
        'bmclapi': bmclapi,
      };

  static Future<void> syncToResourceDir(UiSettings settings) async {
    apply(settings);
    try {
      if (!getIt.isRegistered<ResourceSettingsState>()) return;
      final dir = getIt<ResourceSettingsState>().resourceDirectory.value.trim();
      if (dir.isEmpty) return;
      final file = File(p.join(dir, 'cdn_settings.json'));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(toJson()), encoding: utf8);
    } catch (e) {
      debugPrint('写入 CDN 设置失败: $e');
    }
  }
}
