import 'dart:convert';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:aml/src/features/discover/data/mcim_fallback_http.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:http/http.dart' as http;

/// CurseForge Core API client used by Discover.
///
/// API key matches Rust `CURSEFORGE_API_KEY_DEFAULT` (override via env is
/// handled only on the Rust install path).
class CurseForgeApiService {
  CurseForgeApiService._();

  /// Official CurseForge API (MCIM used as automatic fallback).
  static String get baseUrl => McimApi.curseforgeOfficial;
  static const minecraftGameId = 432;
  static final CacheService _cacheService = McimApi.cache;

  static const _searchTtl = Duration(minutes: 30);
  static const _detailTtl = Duration(minutes: 5);

  /// Same default as `rust/src/config.rs` (do not log / print this value).
  static const _apiKey =
      r'$2a$10$i/H4OmVuV0kTE2CBsnYKkOiGeskyRssc5ehKCNha7cfUJVHOOJ01.';

  static const classIds = <String, int>{
    'mod': 6,
    'modpack': 4471,
    'resourcepack': 12,
    'datapack': 6945,
    'shader': 6552,
  };

  /// CurseForge `ModLoaderType` for Minecraft.
  static const loaderTypes = <String, int>{
    'forge': 1,
    'fabric': 4,
    'quilt': 5,
    'neoforge': 6,
  };

  static Map<String, String> get _headers => {
        'Accept': 'application/json',
        'x-api-key': _apiKey,
        'User-Agent': 'AML-App/1.0.0',
      };

  static Future<http.Response> _get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    return McimFallbackHttp.get(uri, headers: _headers, timeout: timeout);
  }

  static int sortFieldForIndex(String? index) {
    switch (index) {
      case 'downloads':
        return 6; // TotalDownloads
      case 'newest':
      case 'updated':
        return 3; // LastUpdated
      case 'relevance':
      default:
        return 2; // Popularity
    }
  }

  static void _cacheModPayload(int modId, Map<String, dynamic> data) {
    final encoded = jsonEncode(data);
    _cacheService.put('cf_mod_$modId', encoded);
    final slug = data['slug']?.toString();
    if (slug != null && slug.isNotEmpty) {
      _cacheService.put('cf_mod_slug_$slug', encoded);
    }
  }

  static Future<CurseForgeSearchResult> searchMods({
    required String query,
    int index = 0,
    int pageSize = 20,
    String? sortIndex,
    int? classId,
    String? gameVersion,
    List<String>? gameVersions,
    int? modLoaderType,
    Duration cacheDuration = _searchTtl,
  }) async {
    final params = <String, String>{
      'gameId': '$minecraftGameId',
      'index': '$index',
      'pageSize': '${pageSize.clamp(1, 50)}',
      'sortField': '${sortFieldForIndex(sortIndex)}',
      'sortOrder': 'desc',
    };
    if (query.trim().isNotEmpty) {
      params['searchFilter'] = query.trim();
    }
    if (classId != null) params['classId'] = '$classId';
    if (gameVersions != null && gameVersions.isNotEmpty) {
      params['gameVersions'] = jsonEncode(gameVersions.take(4).toList());
    } else if (gameVersion != null && gameVersion.isNotEmpty) {
      params['gameVersion'] = gameVersion;
    }
    if (modLoaderType != null &&
        (gameVersion != null && gameVersion.isNotEmpty ||
            (gameVersions != null && gameVersions.isNotEmpty))) {
      params['modLoaderType'] = '$modLoaderType';
    }

    final cacheKey =
        'cf_search_${params.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    final cached = _cacheService.get(cacheKey, cacheDuration);
    if (cached is String) {
      try {
        return CurseForgeSearchResult.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    final uri = Uri.parse('$baseUrl/v1/mods/search').replace(
      queryParameters: params,
    );
    final response = await _get(uri, timeout: const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('CurseForge 搜索失败: ${response.statusCode}');
    }
    _cacheService.put(cacheKey, response.body);

    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final result = CurseForgeSearchResult.fromJson(json);
    // Warm per-mod cache so opening a hit paints instantly.
    final list = json['data'] as List<dynamic>? ?? const [];
    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final id = item['id'] as int?;
      if (id == null) continue;
      _cacheModPayload(id, item);
    }
    return result;
  }

  static Future<CurseForgeMod> getMod(int modId) async {
    final cacheKey = 'cf_mod_$modId';
    final cached = _cacheService.get(cacheKey, _detailTtl);
    if (cached is String) {
      try {
        return CurseForgeMod.fromJson(
          jsonDecode(cached) as Map<String, dynamic>,
        );
      } catch (_) {}
    }

    final response = await _get(Uri.parse('$baseUrl/v1/mods/$modId'));
    if (response.statusCode != 200) {
      throw Exception('加载 CurseForge 项目失败: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final data = json['data'] as Map<String, dynamic>;
    _cacheModPayload(modId, data);
    return CurseForgeMod.fromJson(data);
  }

  static Future<String> getModDescription(int modId) async {
    final cacheKey = 'cf_desc_$modId';
    final cached = _cacheService.get(cacheKey, _detailTtl);
    if (cached is String) return cached;

    final response = await _get(Uri.parse('$baseUrl/v1/mods/$modId/description'));
    if (response.statusCode != 200) return '';
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final body = json['data']?.toString() ?? '';
    if (body.isNotEmpty) {
      _cacheService.put(cacheKey, body);
    }
    return body;
  }

  static Future<List<CurseForgeFile>> getModFiles(
    int modId, {
    String? gameVersion,
    String? loader,
    int pageSize = 50,
    int index = 0,
    Duration cacheDuration = _searchTtl,
  }) async {
    final params = <String, String>{
      'pageSize': '${pageSize.clamp(1, 50)}',
      'index': '$index',
    };
    if (gameVersion != null && gameVersion.isNotEmpty) {
      params['gameVersion'] = gameVersion;
    }
    final loaderType = loader == null ? null : loaderTypes[loader.toLowerCase()];
    if (loaderType != null &&
        gameVersion != null &&
        gameVersion.isNotEmpty) {
      params['modLoaderType'] = '$loaderType';
    }

    final cacheKey =
        'cf_files_$modId&${params.entries.map((e) => '${e.key}=${e.value}').join('&')}';
    final cached = _cacheService.get(cacheKey, cacheDuration);
    if (cached is String) {
      try {
        final list = jsonDecode(cached) as List<dynamic>;
        return list
            .whereType<Map<String, dynamic>>()
            .map(CurseForgeFile.fromJson)
            .toList();
      } catch (_) {}
    }

    final uri = Uri.parse('$baseUrl/v1/mods/$modId/files').replace(
      queryParameters: params,
    );
    final response = await _get(uri, timeout: const Duration(seconds: 15));
    if (response.statusCode != 200) {
      throw Exception('加载 CurseForge 文件失败: ${response.statusCode}');
    }
    final json = jsonDecode(response.body) as Map<String, dynamic>;
    final list = json['data'] as List<dynamic>? ?? const [];
    _cacheService.put(cacheKey, jsonEncode(list));
    return list
        .whereType<Map<String, dynamic>>()
        .map(CurseForgeFile.fromJson)
        .toList();
  }

  static Future<String?> getCompatibleFileId({
    required int modId,
    String? gameVersion,
    String? loader,
  }) async {
    try {
      final files = await getModFiles(
        modId,
        gameVersion: gameVersion,
        loader: loader,
        pageSize: 20,
      );
      if (files.isEmpty) return null;
      return files.first.id.toString();
    } catch (_) {
      return null;
    }
  }

  static Future<String?> getLatestFileId(int modId) async {
    try {
      final mod = await getMod(modId);
      if (mod.mainFileId != null) return mod.mainFileId.toString();
      if (mod.latestFiles.isNotEmpty) return mod.latestFiles.first.id.toString();
      final files = await getModFiles(modId, pageSize: 1);
      if (files.isEmpty) return null;
      return files.first.id.toString();
    } catch (_) {
      return null;
    }
  }

  /// Sync peek of a cached CF project detail (no network).
  static ModrinthProjectDetail? peekCachedProject(String projectIdOrModId) {
    final modId = parseCurseForgeModId(projectIdOrModId) ??
        int.tryParse(projectIdOrModId);
    if (modId == null) return null;
    final cached = _cacheService.get('cf_mod_$modId', _detailTtl);
    if (cached is! String) return null;
    try {
      final desc = _cacheService.get('cf_desc_$modId', _detailTtl);
      final body = desc is String ? desc : '';
      return CurseForgeMod.fromJson(
        jsonDecode(cached) as Map<String, dynamic>,
      ).toProjectDetail(body: body);
    } catch (_) {
      return null;
    }
  }

  /// Map a CF mod into the Modrinth-shaped detail model used by the UI.
  static Future<ModrinthProjectDetail> getProjectAsDetail(
    int modId, {
    bool localize = true,
  }) async {
    final mod = await getMod(modId);
    final body = await getModDescription(modId);
    final detail = mod.toProjectDetail(body: body);
    if (!localize) return detail;
    try {
      final localized = await DiscoverTranslation.localizeDetail(
        platform: DiscoverTranslation.platformCurseforge,
        projectId: '$modId',
        slug: mod.slug.isNotEmpty ? mod.slug : null,
        title: detail.title,
        description: detail.description,
        body: detail.body.trim().isNotEmpty ? detail.body : detail.description,
      );
      final sourceBody =
          detail.body.trim().isNotEmpty ? detail.body : detail.description;
      return detail.copyWith(
        title: localized.title,
        description: localized.description,
        body: localized.body,
        sourceTitle: detail.title,
        sourceDescription: detail.description,
        sourceBody: sourceBody,
      );
    } catch (_) {
      return detail;
    }
  }

  /// Map CF files into Modrinth-shaped version rows used by the UI.
  static Future<List<ModrinthVersionInfo>> getProjectVersionsAsModrinth(
    int modId, {
    String? gameVersion,
    String? loader,
  }) async {
    final files = await getModFiles(
      modId,
      gameVersion: gameVersion,
      loader: loader,
      pageSize: 50,
    );
    return files.map((f) => f.toVersionInfo(modId)).toList();
  }
}

class CurseForgeSearchResult {
  final List<CurseForgeMod> data;
  final int totalCount;

  CurseForgeSearchResult({required this.data, required this.totalCount});

  factory CurseForgeSearchResult.fromJson(Map<String, dynamic> json) {
    final pagination = json['pagination'] as Map<String, dynamic>? ?? const {};
    final list = json['data'] as List<dynamic>? ?? const [];
    return CurseForgeSearchResult(
      data: list
          .whereType<Map<String, dynamic>>()
          .map(CurseForgeMod.fromJson)
          .toList(),
      totalCount: pagination['totalCount'] as int? ?? list.length,
    );
  }
}

class CurseForgeMod {
  final int id;
  final String name;
  final String slug;
  final String summary;
  final int downloadCount;
  final int? classId;
  final int? mainFileId;
  final String dateCreated;
  final String dateModified;
  final String? logoUrl;
  final List<String> authors;
  final List<String> categories;
  final List<CurseForgeFile> latestFiles;
  final List<String> gameVersions;

  CurseForgeMod({
    required this.id,
    required this.name,
    required this.slug,
    required this.summary,
    required this.downloadCount,
    this.classId,
    this.mainFileId,
    required this.dateCreated,
    required this.dateModified,
    this.logoUrl,
    required this.authors,
    required this.categories,
    required this.latestFiles,
    required this.gameVersions,
  });

  factory CurseForgeMod.fromJson(Map<String, dynamic> json) {
    final authors = (json['authors'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((a) => a['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final categories = (json['categories'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map((c) => c['slug']?.toString() ?? c['name']?.toString() ?? '')
        .where((n) => n.isNotEmpty)
        .toList();
    final logo = json['logo'];
    final logoUrl = logo is Map<String, dynamic>
        ? logo['thumbnailUrl']?.toString() ?? logo['url']?.toString()
        : null;
    final latestFiles = (json['latestFiles'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .map(CurseForgeFile.fromJson)
        .toList();
    final versionSet = <String>{};
    for (final f in latestFiles) {
      versionSet.addAll(f.gameVersions.where(_looksLikeMcVersion));
    }
    final indexes = json['latestFilesIndexes'] as List<dynamic>? ?? const [];
    for (final item in indexes) {
      if (item is! Map<String, dynamic>) continue;
      final gv = item['gameVersion']?.toString();
      if (gv != null && _looksLikeMcVersion(gv)) versionSet.add(gv);
    }

    return CurseForgeMod(
      id: json['id'] as int? ?? 0,
      name: json['name']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      summary: json['summary']?.toString() ?? '',
      downloadCount: (json['downloadCount'] as num?)?.toInt() ?? 0,
      classId: json['classId'] as int?,
      mainFileId: json['mainFileId'] as int?,
      dateCreated: json['dateCreated']?.toString() ?? '',
      dateModified: json['dateModified']?.toString() ?? '',
      logoUrl: logoUrl,
      authors: authors,
      categories: categories,
      latestFiles: latestFiles,
      gameVersions: versionSet.toList(),
    );
  }

  String get projectType {
    switch (classId) {
      case 4471:
        return 'modpack';
      case 12:
        return 'resourcepack';
      case 6945:
        return 'datapack';
      case 6552:
        return 'shader';
      case 6:
      default:
        return 'mod';
    }
  }

  String? get latestFileId {
    if (mainFileId != null) return mainFileId.toString();
    if (latestFiles.isNotEmpty) return latestFiles.first.id.toString();
    return null;
  }

  ModrinthProjectDetail toProjectDetail({String body = ''}) {
    final loaders = <String>{};
    for (final f in latestFiles) {
      loaders.addAll(f.loaders);
    }
    return ModrinthProjectDetail(
      id: curseForgeProjectId(id),
      slug: slug,
      title: name,
      description: summary,
      body: body.isNotEmpty ? body : summary,
      categories: categories,
      clientSide: 'unknown',
      serverSide: 'unknown',
      projectType: projectType,
      downloads: downloadCount,
      followers: 0,
      iconUrl: logoUrl,
      gameVersions: gameVersions,
      loaders: loaders.toList(),
      published: dateCreated,
      updated: dateModified,
      gallery: const [],
      licenseId: '',
      licenseName: '',
    );
  }
}

class CurseForgeFile {
  final int id;
  final int? modId;
  final String displayName;
  final String fileName;
  final int releaseType;
  final String fileDate;
  final int downloadCount;
  final String? downloadUrl;
  final List<String> gameVersions;
  final List<String> loaders;

  CurseForgeFile({
    required this.id,
    this.modId,
    required this.displayName,
    required this.fileName,
    required this.releaseType,
    required this.fileDate,
    required this.downloadCount,
    this.downloadUrl,
    required this.gameVersions,
    required this.loaders,
  });

  factory CurseForgeFile.fromJson(Map<String, dynamic> json) {
    final rawVersions = (json['gameVersions'] as List<dynamic>? ?? const [])
        .map((e) => e.toString())
        .toList();
    final mcVersions = <String>[];
    final loaders = <String>{};
    for (final v in rawVersions) {
      final lower = v.toLowerCase();
      if (lower == 'forge') {
        loaders.add('forge');
      } else if (lower == 'fabric') {
        loaders.add('fabric');
      } else if (lower == 'quilt') {
        loaders.add('quilt');
      } else if (lower == 'neoforge' || lower == 'neo') {
        loaders.add('neoforge');
      } else if (_looksLikeMcVersion(v)) {
        mcVersions.add(v);
      }
    }

    // Newer CF responses may include structured module loaders.
    final modules = json['modules'] as List<dynamic>? ?? const [];
    for (final m in modules) {
      if (m is! Map<String, dynamic>) continue;
      final name = m['name']?.toString().toLowerCase() ?? '';
      if (name.contains('fabric')) loaders.add('fabric');
      if (name.contains('quilt')) loaders.add('quilt');
      if (name.contains('neoforge')) loaders.add('neoforge');
      if (name.contains('forge') && !name.contains('neoforge')) {
        loaders.add('forge');
      }
    }

    final sortable = json['sortableGameVersions'] as List<dynamic>? ?? const [];
    for (final item in sortable) {
      if (item is! Map<String, dynamic>) continue;
      final name = item['gameVersionName']?.toString();
      if (name != null && _looksLikeMcVersion(name)) {
        if (!mcVersions.contains(name)) mcVersions.add(name);
      }
      final loaderName = item['gameVersion']?.toString().toLowerCase() ?? '';
      if (loaderName == 'forge') loaders.add('forge');
      if (loaderName == 'fabric') loaders.add('fabric');
      if (loaderName == 'quilt') loaders.add('quilt');
      if (loaderName == 'neoforge') loaders.add('neoforge');
    }

    return CurseForgeFile(
      id: json['id'] as int? ?? 0,
      modId: json['modId'] as int?,
      displayName: json['displayName']?.toString() ?? '',
      fileName: json['fileName']?.toString() ?? '',
      releaseType: json['releaseType'] as int? ?? 1,
      fileDate: json['fileDate']?.toString() ?? '',
      downloadCount: (json['downloadCount'] as num?)?.toInt() ?? 0,
      downloadUrl: json['downloadUrl']?.toString(),
      gameVersions: mcVersions,
      loaders: loaders.toList(),
    );
  }

  String get versionType {
    switch (releaseType) {
      case 2:
        return 'beta';
      case 3:
        return 'alpha';
      case 1:
      default:
        return 'release';
    }
  }

  ModrinthVersionInfo toVersionInfo(int projectModId) {
    return ModrinthVersionInfo(
      id: id.toString(),
      projectId: curseForgeProjectId(projectModId),
      name: displayName.isNotEmpty ? displayName : fileName,
      versionNumber: fileName,
      changelog: '',
      gameVersions: gameVersions,
      loaders: loaders,
      datePublished: fileDate,
      downloads: downloadCount,
      versionType: versionType,
      files: [
        ModrinthVersionFile(
          url: downloadUrl ?? '',
          filename: fileName,
          primary: true,
          size: 0,
        ),
      ],
    );
  }
}

bool _looksLikeMcVersion(String v) {
  if (v.isEmpty) return false;
  final lower = v.toLowerCase();
  if (lower == 'forge' ||
      lower == 'fabric' ||
      lower == 'quilt' ||
      lower == 'neoforge' ||
      lower == 'neo' ||
      lower == 'rift' ||
      lower == 'liteloader' ||
      lower == 'cauldron') {
    return false;
  }
  return RegExp(r'^\d+\.\d+').hasMatch(v);
}
