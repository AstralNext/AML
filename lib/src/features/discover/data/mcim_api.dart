import 'dart:convert';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:http/http.dart' as http;

/// MCIM mirror host + shared discover HTTP cache.
class McimApi {
  McimApi._();

  static const mirrorHost = 'https://mod.mcimirror.top';

  /// Official Modrinth v2 base (no trailing slash).
  static const modrinthV2Official = 'https://api.modrinth.com/v2';

  /// Official CurseForge API root (no trailing slash).
  static const curseforgeOfficial = 'https://api.curseforge.com';

  /// Shared cache used by discover HTTP clients (LRU-capped).
  static final CacheService cache = CacheService(maxEntries: 192);

  /// Fetch the MCIM community translation (description / intro) for a project.
  ///
  /// Returns the Chinese translation string, or `null` when MCIM has no
  /// translation for this project. `platform` must be `modrinth` or
  /// `curseforge`; for CurseForge `id` should be the numeric mod id.
  static Future<String?> fetchTranslation({
    required String platform,
    required String id,
  }) async {
    final path = platform == 'curseforge'
        ? '/translate/curseforge/$id'
        : '/translate/modrinth/$id';
    final uri = Uri.parse('$mirrorHost$path');
    try {
      print('[mcim] GET $path');
      final resp = await http
          .get(uri, headers: const {'User-Agent': 'AML-App/1.0'})
          .timeout(const Duration(seconds: 10));
      print('[mcim] HTTP ${resp.statusCode} for $path');
      if (resp.statusCode != 200) return null;
      final json = jsonDecode(utf8.decode(resp.bodyBytes)) as Map<String, dynamic>;
      final translated = json['translated'] as String?;
      if (translated == null || translated.trim().isEmpty) {
        print('[mcim] empty translation for $path');
        return null;
      }
      return translated;
    } catch (e) {
      print('[mcim] error for $path: $e');
      return null;
    }
  }

  /// Batch fetch MCIM community translations for multiple Modrinth projects.
  ///
  /// Uses `POST /translate/modrinth` with `{"project_ids": [...]}`.
  /// Returns a map of projectId → translated description.
  static Future<Map<String, String>> fetchTranslationsBatch({
    required List<String> projectIds,
  }) async {
    if (projectIds.isEmpty) return const {};
    final uri = Uri.parse('$mirrorHost/translate/modrinth');
    try {
      print('[mcim] POST /translate/modrinth count=${projectIds.length}');
      final resp = await http
          .post(
            uri,
            headers: const {
              'User-Agent': 'AML-App/1.0',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'project_ids': projectIds}),
          )
          .timeout(const Duration(seconds: 15));
      print('[mcim] batch HTTP ${resp.statusCode}');
      if (resp.statusCode != 200) return const {};
      final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List<dynamic>;
      final result = <String, String>{};
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final id = map['project_id'] as String?;
        final translated = map['translated'] as String?;
        if (id != null && translated != null && translated.trim().isNotEmpty) {
          result[id] = translated;
        }
      }
      print('[mcim] batch got ${result.length}/${projectIds.length}');
      return result;
    } catch (e) {
      print('[mcim] batch error: $e');
      return const {};
    }
  }

  /// Batch fetch MCIM community translations for multiple CurseForge mods.
  ///
  /// Uses `POST /translate/curseforge` with `{"modids": [...]}`.
  /// Returns a map of modId(String) → translated description.
  static Future<Map<String, String>> fetchCurseForgeTranslationsBatch({
    required List<int> modIds,
  }) async {
    if (modIds.isEmpty) return const {};
    final uri = Uri.parse('$mirrorHost/translate/curseforge');
    try {
      print('[mcim] POST /translate/curseforge count=${modIds.length}');
      final resp = await http
          .post(
            uri,
            headers: const {
              'User-Agent': 'AML-App/1.0',
              'Content-Type': 'application/json',
            },
            body: jsonEncode({'modids': modIds}),
          )
          .timeout(const Duration(seconds: 15));
      print('[mcim] cf batch HTTP ${resp.statusCode}');
      if (resp.statusCode != 200) return const {};
      final list = jsonDecode(utf8.decode(resp.bodyBytes)) as List<dynamic>;
      final result = <String, String>{};
      for (final item in list) {
        final map = item as Map<String, dynamic>;
        final id = map['modid'];
        final translated = map['translated'] as String?;
        if (id != null && translated != null && translated.trim().isNotEmpty) {
          result['$id'] = translated;
        }
      }
      print('[mcim] cf batch got ${result.length}/${modIds.length}');
      return result;
    } catch (e) {
      print('[mcim] cf batch error: $e');
      return const {};
    }
  }
}
