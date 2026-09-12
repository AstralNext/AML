import 'dart:convert';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:aml/src/features/discover/data/mcim_fallback_http.dart';
import 'package:http/http.dart' as http;

class ModrinthSearchResult {
  final List<ModrinthProject> hits;
  final int offset;
  final int limit;
  final int totalHits;

  ModrinthSearchResult({
    required this.hits,
    required this.offset,
    required this.limit,
    required this.totalHits,
  });

  factory ModrinthSearchResult.fromJson(Map<String, dynamic> json) {
    return ModrinthSearchResult(
      hits: (json['hits'] as List)
          .map((item) => ModrinthProject.fromJson(item))
          .toList(),
      offset: json['offset'] ?? 0,
      limit: json['limit'] ?? 10,
      totalHits: json['total_hits'] ?? 0,
    );
  }
}

class ModrinthProject {
  final String slug;
  final String title;
  final String description;
  final List<String> categories;
  final String clientSide;
  final String serverSide;
  final String projectType;
  final int downloads;
  final String? iconUrl;
  final int? color;
  final String? threadId;
  final String? monetizationStatus;
  final String projectId;
  final String author;
  final List<String>? displayCategories;
  final List<String> versions;
  final int follows;
  final String dateCreated;
  final String dateModified;
  final String? latestVersion;
  final String license;
  final List<String>? gallery;
  final String? featuredGallery;

  ModrinthProject({
    required this.slug,
    required this.title,
    required this.description,
    required this.categories,
    required this.clientSide,
    required this.serverSide,
    required this.projectType,
    required this.downloads,
    this.iconUrl,
    this.color,
    this.threadId,
    this.monetizationStatus,
    required this.projectId,
    required this.author,
    this.displayCategories,
    required this.versions,
    required this.follows,
    required this.dateCreated,
    required this.dateModified,
    this.latestVersion,
    required this.license,
    this.gallery,
    this.featuredGallery,
  });

  factory ModrinthProject.fromJson(Map<String, dynamic> json) {
    return ModrinthProject(
      slug: json['slug'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      categories: List<String>.from(json['categories'] ?? []),
      clientSide: json['client_side'] ?? 'unknown',
      serverSide: json['server_side'] ?? 'unknown',
      projectType: json['project_type'] ?? '',
      downloads: json['downloads'] ?? 0,
      iconUrl: json['icon_url'],
      color: json['color'],
      threadId: json['thread_id'],
      monetizationStatus: json['monetization_status'],
      projectId: json['project_id'] ?? '',
      author: json['author'] ?? '',
      displayCategories: json['display_categories'] != null
          ? List<String>.from(json['display_categories'])
          : null,
      versions: List<String>.from(json['versions'] ?? []),
      follows: json['follows'] ?? 0,
      dateCreated: json['date_created'] ?? '',
      dateModified: json['date_modified'] ?? '',
      latestVersion: json['latest_version'],
      license: json['license'] ?? '',
      gallery:
          json['gallery'] != null ? List<String>.from(json['gallery']) : null,
      featuredGallery: json['featured_gallery'],
    );
  }

  ModrinthProject copyWith({String? title, String? description}) {
    return ModrinthProject(
      slug: slug,
      title: title ?? this.title,
      description: description ?? this.description,
      categories: categories,
      clientSide: clientSide,
      serverSide: serverSide,
      projectType: projectType,
      downloads: downloads,
      iconUrl: iconUrl,
      color: color,
      threadId: threadId,
      monetizationStatus: monetizationStatus,
      projectId: projectId,
      author: author,
      displayCategories: displayCategories,
      versions: versions,
      follows: follows,
      dateCreated: dateCreated,
      dateModified: dateModified,
      latestVersion: latestVersion,
      license: license,
      gallery: gallery,
      featuredGallery: featuredGallery,
    );
  }
}

class ModrinthProjectDetail {
  final String id;
  final String slug;
  final String title;
  final String description;
  final String body;
  /// Original (pre-translation) fields when [title]/[description]/[body] are localized.
  final String? sourceTitle;
  final String? sourceDescription;
  final String? sourceBody;
  final List<String> categories;
  final String clientSide;
  final String serverSide;
  final String projectType;
  final int downloads;
  final int followers;
  final String? iconUrl;
  final List<String> gameVersions;
  final List<String> loaders;
  final String published;
  final String updated;
  final List<ModrinthGalleryImage> gallery;
  final String licenseId;
  final String licenseName;
  final String? organizationId;
  final String? teamId;

  const ModrinthProjectDetail({
    required this.id,
    required this.slug,
    required this.title,
    required this.description,
    required this.body,
    this.sourceTitle,
    this.sourceDescription,
    this.sourceBody,
    required this.categories,
    required this.clientSide,
    required this.serverSide,
    required this.projectType,
    required this.downloads,
    required this.followers,
    this.iconUrl,
    required this.gameVersions,
    required this.loaders,
    required this.published,
    required this.updated,
    required this.gallery,
    required this.licenseId,
    required this.licenseName,
    this.organizationId,
    this.teamId,
  });

  /// True when at least one field differs from its preserved source text.
  bool get hasTranslation {
    final srcTitle = sourceTitle?.trim();
    final srcDesc = sourceDescription?.trim();
    final srcBody = sourceBody?.trim();
    if (srcTitle != null &&
        srcTitle.isNotEmpty &&
        srcTitle != title.trim()) {
      return true;
    }
    if (srcDesc != null &&
        srcDesc.isNotEmpty &&
        srcDesc != description.trim()) {
      return true;
    }
    if (srcBody != null && srcBody.isNotEmpty && srcBody != body.trim()) {
      return true;
    }
    return false;
  }

  String displayTitle({required bool original}) =>
      original ? (sourceTitle ?? title) : title;

  String displayDescription({required bool original}) =>
      original ? (sourceDescription ?? description) : description;

  String displayBody({required bool original}) {
    if (original) {
      final src = sourceBody?.trim();
      if (src != null && src.isNotEmpty) return src;
      final srcDesc = sourceDescription?.trim();
      if (srcDesc != null && srcDesc.isNotEmpty) return srcDesc;
    }
    return body.isNotEmpty ? body : description;
  }

  factory ModrinthProjectDetail.fromJson(Map<String, dynamic> json) {
    final license = json['license'];
    String licenseId = '';
    String licenseName = '';
    if (license is Map<String, dynamic>) {
      licenseId = license['id']?.toString() ?? '';
      licenseName = license['name']?.toString() ?? licenseId;
    } else if (license is String) {
      licenseId = license;
      licenseName = license;
    }
    return ModrinthProjectDetail(
      id: json['id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      categories: List<String>.from(json['categories'] ?? const []),
      clientSide: json['client_side']?.toString() ?? 'unknown',
      serverSide: json['server_side']?.toString() ?? 'unknown',
      projectType: json['project_type']?.toString() ?? '',
      downloads: json['downloads'] as int? ?? 0,
      followers: json['followers'] as int? ?? 0,
      iconUrl: json['icon_url']?.toString(),
      gameVersions: List<String>.from(json['game_versions'] ?? const []),
      loaders: List<String>.from(json['loaders'] ?? const []),
      published: json['published']?.toString() ?? '',
      updated: json['updated']?.toString() ?? '',
      gallery: (json['gallery'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ModrinthGalleryImage.fromJson)
          .toList(),
      licenseId: licenseId,
      licenseName: licenseName,
      organizationId: json['organization']?.toString(),
      teamId: json['team']?.toString(),
    );
  }

  ModrinthProjectDetail copyWith({
    String? title,
    String? description,
    String? body,
    String? sourceTitle,
    String? sourceDescription,
    String? sourceBody,
    bool clearSources = false,
  }) {
    return ModrinthProjectDetail(
      id: id,
      slug: slug,
      title: title ?? this.title,
      description: description ?? this.description,
      body: body ?? this.body,
      sourceTitle: clearSources ? null : (sourceTitle ?? this.sourceTitle),
      sourceDescription:
          clearSources ? null : (sourceDescription ?? this.sourceDescription),
      sourceBody: clearSources ? null : (sourceBody ?? this.sourceBody),
      categories: categories,
      clientSide: clientSide,
      serverSide: serverSide,
      projectType: projectType,
      downloads: downloads,
      followers: followers,
      iconUrl: iconUrl,
      gameVersions: gameVersions,
      loaders: loaders,
      published: published,
      updated: updated,
      gallery: gallery,
      licenseId: licenseId,
      licenseName: licenseName,
      organizationId: organizationId,
      teamId: teamId,
    );
  }
}

/// Lightweight project summary passed into detail for instant header paint.
class ProjectPreview {
  final String id;
  final String slug;
  final String title;
  final String description;
  final String? iconUrl;
  final int downloads;
  final int followers;
  final String projectType;
  final String clientSide;
  final String serverSide;
  final List<String> categories;
  final List<String>? displayCategories;

  const ProjectPreview({
    required this.id,
    required this.slug,
    required this.title,
    required this.description,
    this.iconUrl,
    required this.downloads,
    required this.followers,
    required this.projectType,
    required this.clientSide,
    required this.serverSide,
    required this.categories,
    this.displayCategories,
  });

  factory ProjectPreview.fromSearch(ModrinthProject project) {
    return ProjectPreview(
      id: project.projectId,
      slug: project.slug,
      title: project.title,
      description: project.description,
      iconUrl: project.iconUrl,
      downloads: project.downloads,
      followers: project.follows,
      projectType: project.projectType,
      clientSide: project.clientSide,
      serverSide: project.serverSide,
      categories: project.categories,
      displayCategories: project.displayCategories,
    );
  }

  factory ProjectPreview.fromProject({
    required String id,
    required String title,
    required String description,
    String? iconUrl,
    int downloads = 0,
    int followers = 0,
    String projectType = '',
    String clientSide = 'unknown',
    String serverSide = 'unknown',
    List<String> categories = const [],
    List<String>? displayCategories,
    String slug = '',
  }) {
    return ProjectPreview(
      id: id,
      slug: slug,
      title: title,
      description: description,
      iconUrl: iconUrl,
      downloads: downloads,
      followers: followers,
      projectType: projectType,
      clientSide: clientSide,
      serverSide: serverSide,
      categories: categories,
      displayCategories: displayCategories,
    );
  }

  factory ProjectPreview.fromDetail(ModrinthProjectDetail project) {
    return ProjectPreview(
      id: project.id,
      slug: project.slug,
      title: project.title,
      description: project.description,
      iconUrl: project.iconUrl,
      downloads: project.downloads,
      followers: project.followers,
      projectType: project.projectType,
      clientSide: project.clientSide,
      serverSide: project.serverSide,
      categories: project.categories,
    );
  }
}

/// User or organization profile for the author detail page.
class ModrinthAuthor {
  final String id;
  /// Username (user) or slug (organization).
  final String username;
  final String displayName;
  final String bio;
  final String? avatarUrl;
  /// `user` | `organization`
  final String type;

  const ModrinthAuthor({
    required this.id,
    required this.username,
    required this.displayName,
    required this.bio,
    this.avatarUrl,
    required this.type,
  });

  factory ModrinthAuthor.fromUserJson(Map<String, dynamic> json) {
    final username = json['username']?.toString() ?? '';
    final name = json['name']?.toString();
    return ModrinthAuthor(
      id: json['id']?.toString() ?? '',
      username: username,
      displayName: (name != null && name.trim().isNotEmpty) ? name : username,
      bio: json['bio']?.toString() ?? '',
      avatarUrl: json['avatar_url']?.toString(),
      type: 'user',
    );
  }

  factory ModrinthAuthor.fromOrgJson(Map<String, dynamic> json) {
    final slug = json['slug']?.toString() ?? '';
    final name = json['name']?.toString();
    return ModrinthAuthor(
      id: json['id']?.toString() ?? '',
      username: slug,
      displayName: (name != null && name.trim().isNotEmpty) ? name : slug,
      bio: json['description']?.toString() ?? '',
      avatarUrl: json['icon_url']?.toString(),
      type: 'organization',
    );
  }
}

/// Lightweight project row on an author page (user/org projects list).
class ModrinthAuthorProject {
  final String id;
  final String slug;
  final String title;
  final String description;
  final String? iconUrl;
  final int downloads;
  final int followers;
  final String projectType;
  final String clientSide;
  final String serverSide;
  final List<String> categories;
  final String published;
  final String updated;

  const ModrinthAuthorProject({
    required this.id,
    required this.slug,
    required this.title,
    required this.description,
    this.iconUrl,
    required this.downloads,
    required this.followers,
    required this.projectType,
    required this.clientSide,
    required this.serverSide,
    required this.categories,
    required this.published,
    required this.updated,
  });

  factory ModrinthAuthorProject.fromJson(Map<String, dynamic> json) {
    return ModrinthAuthorProject(
      id: json['id']?.toString() ?? json['project_id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      iconUrl: json['icon_url']?.toString(),
      downloads: json['downloads'] as int? ?? 0,
      followers: json['followers'] as int? ?? json['follows'] as int? ?? 0,
      projectType: json['project_type']?.toString() ?? '',
      clientSide: json['client_side']?.toString() ?? 'unknown',
      serverSide: json['server_side']?.toString() ?? 'unknown',
      categories: List<String>.from(json['categories'] ?? const []),
      published: json['published']?.toString() ??
          json['date_created']?.toString() ??
          '',
      updated:
          json['updated']?.toString() ?? json['date_modified']?.toString() ?? '',
    );
  }

  ProjectPreview toPreview() => ProjectPreview(
        id: id,
        slug: slug,
        title: title,
        description: description,
        iconUrl: iconUrl,
        downloads: downloads,
        followers: followers,
        projectType: projectType,
        clientSide: clientSide,
        serverSide: serverSide,
        categories: categories,
      );
}

/// Instant header while author profile loads.
class AuthorPreview {
  final String id;
  final String type;
  final String displayName;
  final String? avatarUrl;

  const AuthorPreview({
    required this.id,
    required this.type,
    required this.displayName,
    this.avatarUrl,
  });
}

class ModrinthGalleryImage {
  final String url;
  final String? title;
  final bool featured;

  const ModrinthGalleryImage({
    required this.url,
    this.title,
    this.featured = false,
  });

  factory ModrinthGalleryImage.fromJson(Map<String, dynamic> json) {
    return ModrinthGalleryImage(
      url: json['url']?.toString() ?? '',
      title: json['title']?.toString(),
      featured: json['featured'] == true,
    );
  }
}

class ModrinthVersionInfo {
  final String id;
  final String projectId;
  final String name;
  final String versionNumber;
  final String changelog;
  final List<String> gameVersions;
  final List<String> loaders;
  final String datePublished;
  final int downloads;
  final String versionType;
  final List<ModrinthVersionFile> files;

  const ModrinthVersionInfo({
    required this.id,
    required this.projectId,
    required this.name,
    required this.versionNumber,
    required this.changelog,
    required this.gameVersions,
    required this.loaders,
    required this.datePublished,
    required this.downloads,
    required this.versionType,
    required this.files,
  });

  factory ModrinthVersionInfo.fromJson(Map<String, dynamic> json) {
    return ModrinthVersionInfo(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      versionNumber: json['version_number']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      gameVersions: List<String>.from(json['game_versions'] ?? const []),
      loaders: List<String>.from(json['loaders'] ?? const []),
      datePublished: json['date_published']?.toString() ?? '',
      downloads: json['downloads'] as int? ?? 0,
      versionType: json['version_type']?.toString() ?? 'release',
      files: (json['files'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ModrinthVersionFile.fromJson)
          .toList(),
    );
  }

  String? get primaryFileName {
    for (final f in files) {
      if (f.primary) return f.filename;
    }
    return files.isEmpty ? null : files.first.filename;
  }
}

class ModrinthVersionFile {
  final String url;
  final String filename;
  final bool primary;
  final int size;

  const ModrinthVersionFile({
    required this.url,
    required this.filename,
    required this.primary,
    required this.size,
  });

  factory ModrinthVersionFile.fromJson(Map<String, dynamic> json) {
    return ModrinthVersionFile(
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      primary: json['primary'] == true,
      size: json['size'] as int? ?? 0,
    );
  }
}

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
    return list
        .whereType<Map<String, dynamic>>()
        .map(ModrinthVersionInfo.fromJson)
        .toList();
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
      final first = list.first as Map<String, dynamic>;
      return first['id'] as String?;
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
      return (list.first as Map<String, dynamic>)['id'] as String?;
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
    final response = await _get(Uri.parse('$baseUrl/user/$idOrUsername/projects'));
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
