import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:aml/src/features/discover/domain/discover_repository.dart';
import 'package:flutter/foundation.dart';

class CurseForgeRepository implements DiscoverRepository {
  static const _searchTtl = Duration(minutes: 30);
  static final CacheService _cache = McimApi.cache;

  @override
  Future<SearchResult> searchProjects({
    required String query,
    int page = 0,
    int pageSize = 20,
    String? index,
    List<List<String>>? facets,
    void Function(SearchResult localized)? onLocalized,
  }) async {
    final cacheKey =
        'discover_cf_q=$query&p=$page&ps=$pageSize&i=$index&f=$facets';
    final cached = _cache.get(cacheKey, _searchTtl);
    if (cached is SearchResult) return cached;

    String? projectType;
    final gameVersions = <String>[];
    final loaders = <String>[];

    for (final group in facets ?? const <List<String>>[]) {
      for (final facet in group) {
        final parts = facet.split(':');
        if (parts.length < 2) continue;
        final key = parts.first;
        final value = parts.sublist(1).join(':');
        switch (key) {
          case 'project_type':
            projectType = value;
          case 'versions':
            gameVersions.add(value);
          case 'categories':
            if (CurseForgeApiService.loaderTypes.containsKey(value)) {
              loaders.add(value);
            }
        }
      }
    }

    final classId = projectType == null
        ? null
        : CurseForgeApiService.classIds[projectType];
    final loaderType = loaders.isEmpty
        ? null
        : CurseForgeApiService.loaderTypes[loaders.first];

    final remoteQuery = query.trim();
    if (kDebugMode) {
      debugPrint('[Discover/CF] 搜索="$remoteQuery"');
    }

    final result = await CurseForgeApiService.searchMods(
      query: remoteQuery,
      index: page * pageSize,
      pageSize: pageSize,
      sortIndex: index,
      classId: classId,
      gameVersions: gameVersions.isEmpty ? null : gameVersions,
      gameVersion: gameVersions.length == 1 ? gameVersions.first : null,
      modLoaderType: loaderType,
      cacheDuration: _searchTtl,
    );

    final projects = result.data.map((m) {
      return Project(
        id: curseForgeProjectId(m.id),
        title: m.name,
        description: m.summary,
        author: m.authors.isNotEmpty ? m.authors.first : '',
        downloads: m.downloadCount,
        followers: 0,
        iconUrl: m.logoUrl,
        projectType: projectType ?? m.projectType,
        clientSide: 'unknown',
        serverSide: 'unknown',
        latestVersion: m.latestFileId,
        categories: m.categories,
        displayCategories: m.categories,
        gameVersions: m.gameVersions,
        dateCreated: m.dateCreated,
        dateModified: m.dateModified,
      );
    }).toList();

    final out = SearchResult(
      projects: projects,
      totalHits: result.totalCount,
    );
    _cache.put(cacheKey, out);

    return out;
  }
}
