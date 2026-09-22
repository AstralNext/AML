import 'dart:convert';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:aml/src/features/discover/data/mcim_fallback_http.dart';
import 'package:http/http.dart' as http;

import 'modrinth_authors.dart';
import 'modrinth_models.dart';
import 'modrinth_versions.dart';

export 'modrinth_authors.dart';
export 'modrinth_models.dart';
export 'modrinth_versions.dart';

class ModrinthApiService {
  /// Modrinth v2 official API (MCIM used as automatic fallback).
  static String get baseUrl => McimApi.modrinthV2Official;
  static final CacheService _cacheService = McimApi.cache;

  static Map<String, String> get _headers => {
        'Content-Type': 'application/json',
        'User-Agent': 'AML-App/1.0.0',
      };

  static Future<http.Response> _get(
    Uri uri, {
    Duration timeout = const Duration(seconds: 12),
  }) {
    return McimFallbackHttp.get(uri, headers: _headers, timeout: timeout);
  }

  static Future<ModrinthProjectDetail> getProject(
    String idOrSlug, {
    bool localize = true,
  }) async {
    final cacheKey = 'project_$idOrSlug';
    final cached = _cacheService.get(cacheKey, const Duration(minutes: 5));
    late final ModrinthProjectDetail detail;
    if (cached != null) {
      detail = ModrinthProjectDetail.fromJson(
        jsonDecode(cached) as Map<String, dynamic>,
      );
    } else {
      final response = await _get(Uri.parse('$baseUrl/project/$idOrSlug'));
      if (response.statusCode != 200) {
        throw Exception('加载项目失败: ${response.statusCode}');
      }
      _cacheService.put(cacheKey, response.body);
      detail = ModrinthProjectDetail.fromJson(
        jsonDecode(response.body) as Map<String, dynamic>,
      );
      // Also cache under canonical id / slug for later peek hits.
      if (detail.id.isNotEmpty && detail.id != idOrSlug) {
        _cacheService.put('project_${detail.id}', response.body);
      }
      if (detail.slug.isNotEmpty && detail.slug != idOrSlug) {
        _cacheService.put('project_${detail.slug}', response.body);
      }
    }

    if (!localize) return detail;

    try {
      final localized = await DiscoverTranslation.localizeDetail(
        platform: DiscoverTranslation.platformModrinth,
        projectId: detail.id,
        slug: detail.slug,
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

  /// Sync peek of a cached project detail (no network).
  static ModrinthProjectDetail? peekCachedProject(String idOrSlug) {
    final cached =
        _cacheService.get('project_$idOrSlug', const Duration(minutes: 5));
    if (cached is! String) return null;
    try {
      return ModrinthProjectDetail.fromJson(
        jsonDecode(cached) as Map<String, dynamic>,
      );
    } catch (_) {
      return null;
    }
  }

  static Future<List<ModrinthVersionInfo>> getProjectVersions(
    String idOrSlug, {
    String? gameVersion,
    String? loader,
  }) async {
    final params = <String, String>{};
    if (gameVersion != null && gameVersion.isNotEmpty) {
      params['game_versions'] = jsonEncode([gameVersion]);
    }
    if (loader != null && loader.isNotEmpty) {
      params['loaders'] = jsonEncode([loader.toLowerCase()]);
    }
    final uri = Uri.parse('$baseUrl/project/$idOrSlug/version').replace(
      queryParameters: params.isEmpty ? null : params,
    );
    final response = await _get(uri);
    if (response.statusCode != 200) {
      throw Exception('加载版本失败: ${response.statusCode}');
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return sortVersionsNewestFirst(
      list
          .whereType<Map<String, dynamic>>()
          .map(ModrinthVersionInfo.fromJson)
          .toList(),
    );
  }

  static Future<ModrinthSearchResult> searchProjects({
    String? query,
    int limit = 10,
    int offset = 0,
    String? index,
    List<List<String>>? facets,
    Duration cacheDuration = const Duration(minutes: 30),
  }) async {
    final cacheKey =
        'searchProjects_query=$query&limit=$limit&offset=$offset&index=$index&facets=${jsonEncode(facets)}';

    final cachedData = _cacheService.get(cacheKey, cacheDuration);
    if (cachedData != null) {
      return ModrinthSearchResult.fromJson(jsonDecode(cachedData));
    }

    try {
      final Map<String, String> queryParams = {
        'limit': limit.toString(),
        'offset': offset.toString(),
      };

      if (query != null && query.isNotEmpty) {
        queryParams['query'] = query;
      }

      if (index != null) {
        queryParams['index'] = index;
      }

      if (facets != null && facets.isNotEmpty) {
        queryParams['facets'] = jsonEncode(facets);
      }

      final uri = Uri.parse('$baseUrl/search').replace(
        queryParameters: queryParams,
      );

      final response = await _get(uri, timeout: const Duration(seconds: 10));

      if (response.statusCode == 200) {
        final jsonData = jsonDecode(response.body);
        _cacheService.put(cacheKey, response.body);
        return ModrinthSearchResult.fromJson(jsonData);
      } else {
        throw Exception('Failed to search projects: ${response.statusCode}');
      }
    } catch (e) {
      throw Exception('Error searching projects: $e');
    }
  }

  static Future<String?> getLatestVersionId(String projectId) async {
    try {
      final uri = Uri.parse('$baseUrl/project/$projectId/version');
      final response = await _get(uri, timeout: const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      final list = jsonDecode(response.body) as List<dynamic>;
      if (list.isEmpty) return null;
      final versions = sortVersionsNewestFirst(
        list
            .whereType<Map<String, dynamic>>()
            .map(ModrinthVersionInfo.fromJson)
            .toList(),
      );
      // 默认安装最新正式版，没有再退 Beta / Alpha。
      return pickPreferredVersion(versions)?.id;
    } catch (_) {
      return null;
    }
  }

  /// Prefer a version matching [gameVersion] and optional [loader]
  /// (loader may be fabric/forge/… or content prefs like minecraft/iris/datapack).
  static Future<String?> getCompatibleVersionId({
    required String projectId,
    String? gameVersion,
    String? loader,
  }) async {
    try {
      final params = <String, String>{};
      if (gameVersion != null && gameVersion.isNotEmpty) {
        params['game_versions'] = jsonEncode([gameVersion]);
      }
      if (loader != null && loader.isNotEmpty) {
        params['loaders'] = jsonEncode([loader.toLowerCase()]);
      }
      final uri = Uri.parse('$baseUrl/project/$projectId/version')
          .replace(queryParameters: params.isEmpty ? null : params);
      final response = await _get(uri, timeout: const Duration(seconds: 10));
      if (response.statusCode != 200) {
        return null;
      }
      final list = jsonDecode(response.body) as List<dynamic>;
      if (list.isEmpty) {
        return null;
      }
      final versions = sortVersionsNewestFirst(
        list
            .whereType<Map<String, dynamic>>()
            .map(ModrinthVersionInfo.fromJson)
            .toList(),
      );
      return pickPreferredVersion(versions)?.id;
    } catch (_) {
      return null;
    }
  }

  /// User profile (`GET /v2/user/{id|username}`).
  static Future<ModrinthAuthor> getUser(String idOrUsername) async {
    final cacheKey = 'user_$idOrUsername';
    final cached = _cacheService.get(cacheKey, const Duration(minutes: 5));
    if (cached != null) {
      return ModrinthAuthor.fromUserJson(
        jsonDecode(cached) as Map<String, dynamic>,
      );
    }
    final response = await _get(Uri.parse('$baseUrl/user/$idOrUsername'));
    if (response.statusCode != 200) {
      throw Exception('加载作者失败: ${response.statusCode}');
    }
    _cacheService.put(cacheKey, response.body);
    final author = ModrinthAuthor.fromUserJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if (author.id.isNotEmpty && author.id != idOrUsername) {
      _cacheService.put('user_${author.id}', response.body);
    }
    if (author.username.isNotEmpty && author.username != idOrUsername) {
      _cacheService.put('user_${author.username}', response.body);
    }
    return author;
  }

  /// Organization profile (`GET /v3/organization/{id|slug}`).
  static Future<ModrinthAuthor> getOrganization(String idOrSlug) async {
    final cacheKey = 'org_$idOrSlug';
    final cached = _cacheService.get(cacheKey, const Duration(minutes: 5));
    if (cached != null) {
      return ModrinthAuthor.fromOrgJson(
        jsonDecode(cached) as Map<String, dynamic>,
      );
    }
    final response = await _get(
      Uri.parse('https://api.modrinth.com/v3/organization/$idOrSlug'),
    );
    if (response.statusCode != 200) {
      throw Exception('加载组织失败: ${response.statusCode}');
    }
    _cacheService.put(cacheKey, response.body);
    final author = ModrinthAuthor.fromOrgJson(
      jsonDecode(response.body) as Map<String, dynamic>,
    );
    if (author.id.isNotEmpty && author.id != idOrSlug) {
      _cacheService.put('org_${author.id}', response.body);
    }
    if (author.username.isNotEmpty && author.username != idOrSlug) {
      _cacheService.put('org_${author.username}', response.body);
    }
    return author;
  }

  static Future<ModrinthAuthor> getAuthor({
    required String id,
    required String type,
  }) {
    if (type.toLowerCase() == 'organization') {
      return getOrganization(id);
    }
    return getUser(id);
  }

  /// Projects owned by a user (`GET /v2/user/{id}/projects`).
  static Future<List<ModrinthAuthorProject>> getUserProjects(
    String idOrUsername,
  ) async {
    final response =
        await _get(Uri.parse('$baseUrl/user/$idOrUsername/projects'));
    if (response.statusCode != 200) {
      throw Exception('加载作者项目失败: ${response.statusCode}');
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(ModrinthAuthorProject.fromJson)
        .toList();
  }

  /// Projects owned by an organization (`GET /v3/organization/{id}/projects`).
  static Future<List<ModrinthAuthorProject>> getOrganizationProjects(
    String idOrSlug,
  ) async {
    final response = await _get(
      Uri.parse('https://api.modrinth.com/v3/organization/$idOrSlug/projects'),
    );
    if (response.statusCode != 200) {
      throw Exception('加载组织项目失败: ${response.statusCode}');
    }
    final list = jsonDecode(response.body) as List<dynamic>;
    return list
        .whereType<Map<String, dynamic>>()
        .map(ModrinthAuthorProject.fromJson)
        .toList();
  }

  static Future<List<ModrinthAuthorProject>> getAuthorProjects({
    required String id,
    required String type,
  }) {
    if (type.toLowerCase() == 'organization') {
      return getOrganizationProjects(id);
    }
    return getUserProjects(id);
  }

  /// Resolve display author for a project (organization preferred, else team lead).
  static Future<ModrinthAuthor?> resolveProjectAuthor({
    String? organizationId,
    String? teamId,
  }) async {
    final org = organizationId?.trim();
    if (org != null && org.isNotEmpty) {
      try {
        return await getOrganization(org);
      } catch (_) {}
    }
    final team = teamId?.trim();
    if (team == null || team.isEmpty) return null;
    try {
      final response = await _get(Uri.parse('$baseUrl/team/$team/members'));
      if (response.statusCode != 200) return null;
      final list = jsonDecode(response.body) as List<dynamic>;
      Map<String, dynamic>? chosen;
      for (final raw in list) {
        if (raw is! Map<String, dynamic>) continue;
        if (raw['is_owner'] == true) {
          chosen = raw;
          break;
        }
        final role = (raw['role']?.toString() ?? '').toLowerCase();
        if (role.contains('owner') || role.contains('lead')) {
          chosen = raw;
          break;
        }
        chosen ??= raw;
      }
      final user = chosen?['user'];
      if (user is! Map<String, dynamic>) return null;
      return ModrinthAuthor.fromUserJson(user);
    } catch (_) {
      return null;
    }
  }

  static String formatRelativeTime(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 7) return '${diff.inDays}天前';
    if (diff.inDays < 30) return '${(diff.inDays / 7).floor()}周前';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
    return '${(diff.inDays / 365).floor()}年前';
  }

  static String formatDownloadCount(int downloads) {
    if (downloads >= 100000000) {
      final v = downloads / 100000000;
      final s = v >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
      return '${_trimTrailingZeros(s)}亿';
    }
    if (downloads >= 10000) {
      final v = downloads / 10000;
      final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
      return '${_trimTrailingZeros(s)}万';
    }
    if (downloads >= 1000) {
      return '${_trimTrailingZeros((downloads / 1000).toStringAsFixed(1))}K';
    }
    return downloads.toString();
  }

  static String _trimTrailingZeros(String s) {
    if (!s.contains('.')) return s;
    return s.replaceFirst(RegExp(r'\.?0+$'), '');
  }
}
