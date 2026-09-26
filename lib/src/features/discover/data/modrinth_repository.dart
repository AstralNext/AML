import 'dart:async';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/mcdb_client.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:flutter/foundation.dart';

import '../domain/discover_repository.dart';
import 'modrinth_api.dart';

class ModrinthRepository implements DiscoverRepository {
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
    final cacheKey = _cacheKey(query, page, pageSize, index, facets);
    final cached = _cache.get(cacheKey, _searchTtl);
    if (cached is SearchResult) {
      return SearchResult(
        projects: cached.projects,
        totalHits: cached.totalHits,
      );
    }

    // MCDB 标题词库改写中文 query 为英文搜索词。
    final (rewritten, lexicon) = await _rewriteQuery(query);
    final remote = await ModrinthApiService.searchProjects(
      query: rewritten,
      limit: pageSize,
      offset: page * pageSize,
      index: index,
      facets: facets,
      cacheDuration: _searchTtl,
    );

    final lexiconById = {for (final h in lexicon) h.projectId: h};
    final lexiconZhById = <String, String>{
      for (final h in lexicon)
        if ((h.zhTitle ?? '').trim().isNotEmpty) h.projectId: h.zhTitle!.trim(),
    };

    // Page 0：词库命中的项目置顶（最多 4 个 detail GET）。
    final pinned = await _pinnedProjects(lexicon, page, facets);
    final pageHits = _mergePage(pinned, remote.hits, pageSize);

    final inputs = [
      for (final p in pageHits)
        (
          id: p.projectId,
          slug: p.slug,
          // Prefer English source title for i18n upsert keys.
          title: lexiconById[p.projectId]?.sourceTitle ?? p.title,
          description: p.description,
        ),
    ];

    Map<String, LocalizedFields> localized = {};
    try {
      localized = await DiscoverTranslation.localizeModrinth(
        projects: inputs,
        network: false,
      );
    } catch (_) {}
    _seedLexiconZh(localized, lexiconById, lexiconZhById);

    SearchResult mapResult(Map<String, LocalizedFields> loc) => _mapResult(
      pageHits: pageHits,
      localized: loc,
      pinned: pinned,
      remoteHits: remote.hits,
      page: page,
      remoteTotalHits: remote.totalHits,
    );

    final provisional = mapResult(localized);
    final ids = {for (final p in inputs) p.id};

    // Warm shards: await ZH before first paint (no flicker).
    // Cold shards: return local/lexicon ZH when available, patch via onLocalized.
    if (McdbClient.areShardsCached(ids)) {
      try {
        final full = await DiscoverTranslation.localizeModrinth(
          projects: inputs,
        );
        final updated = mapResult(full);
        _cache.put(cacheKey, updated);
        return updated;
      } catch (_) {
        return provisional;
      }
    }

    unawaited(() async {
      try {
        final full = await DiscoverTranslation.localizeModrinth(
          projects: inputs,
        );
        final updated = mapResult(full);
        _cache.put(cacheKey, updated);
        onLocalized?.call(updated);
      } catch (_) {}
    }());

    // Do not cache provisional (may still be English on cold miss).
    return provisional;
  }

  String _cacheKey(
    String query,
    int page,
    int pageSize,
    String? index,
    List<List<String>>? facets,
  ) =>
      'discover_mr_q=$query&p=$page&ps=$pageSize&i=$index&f=$facets';

  Future<(String, List<LexiconSearchHit>)> _rewriteQuery(String query) async {
    final lexicon = await DiscoverTranslation.resolveLexiconHits(
      query,
      platform: DiscoverTranslation.platformModrinth,
      limit: 12,
    );
    final rewritten =
        DiscoverTranslation.remoteQueryFromHits(query.trim(), lexicon);
    if (kDebugMode) {
      debugPrint(
        '[Discover/MR] 输入="${query.trim()}" '
        '实际搜索="$rewritten" '
        'MCDB=${lexicon.isEmpty ? "(无)" : lexicon.take(5).map((h) => '${h.score.toStringAsFixed(3)} ${h.sourceTitle}${h.zhTitle != null ? " (${h.zhTitle})" : ""}').join(" | ")}',
      );
    }
    return (rewritten, lexicon);
  }

  /// 词库命中项目置顶（仅第 0 页）；带 project_type facet 软过滤。
  Future<List<ModrinthProject>> _pinnedProjects(
    List<LexiconSearchHit> lexicon,
    int page,
    List<List<String>>? facets,
  ) async {
    if (page != 0 || lexicon.isEmpty) return const [];

    // Cap pin fan-out: 4 detail GETs is enough for Chinese title search UX.
    final fetched = await Future.wait(
      lexicon.take(4).map((hit) => _pinnedFromDetail(hit, facets)),
    );
    return [for (final p in fetched) if (p != null) p];
  }

  Future<ModrinthProject?> _pinnedFromDetail(
    LexiconSearchHit hit,
    List<List<String>>? facets,
  ) async {
    try {
      final detail = await ModrinthApiService.getProject(
        hit.projectId,
        localize: false,
      );
      if (!_matchesProjectTypeFacet(detail.projectType, facets)) return null;
      final zhTitle = hit.zhTitle?.trim();
      return ModrinthProject(
        slug: detail.slug,
        title: (zhTitle != null && zhTitle.isNotEmpty) ? zhTitle : detail.title,
        description: detail.description,
        categories: detail.categories,
        clientSide: detail.clientSide,
        serverSide: detail.serverSide,
        projectType: detail.projectType,
        downloads: detail.downloads,
        iconUrl: detail.iconUrl,
        projectId: detail.id,
        author: '',
        displayCategories: detail.categories,
        versions: detail.gameVersions,
        follows: detail.followers,
        dateCreated: detail.published,
        dateModified: detail.updated,
        latestVersion: null,
        license: detail.licenseId,
      );
    } catch (_) {
      return null;
    }
  }

  bool _matchesProjectTypeFacet(
    String projectType,
    List<List<String>>? facets,
  ) {
    if (facets == null || facets.isEmpty) return true;
    for (final group in facets) {
      for (final f in group) {
        if (f.startsWith('project_type:')) {
          final want = f.substring('project_type:'.length);
          if (want.isNotEmpty && projectType != want) return false;
        }
      }
    }
    return true;
  }

  /// 置顶在前、按 projectId 去重，截取整页。
  List<ModrinthProject> _mergePage(
    List<ModrinthProject> pinned,
    List<ModrinthProject> remoteHits,
    int pageSize,
  ) {
    final seen = <String>{};
    final merged = <ModrinthProject>[];
    for (final p in [...pinned, ...remoteHits]) {
      if (seen.add(p.projectId)) merged.add(p);
    }
    return merged.take(pageSize).toList();
  }

  /// 用 MCDB 标题搜索已知的中文标题覆盖本地化结果。
  void _seedLexiconZh(
    Map<String, LocalizedFields> localized,
    Map<String, LexiconSearchHit> lexiconById,
    Map<String, String> lexiconZhById,
  ) {
    for (final entry in lexiconZhById.entries) {
      final cur = localized[entry.key];
      if (cur == null) continue;
      final src = lexiconById[entry.key]?.sourceTitle;
      if (cur.title == src ||
          cur.title == entry.value ||
          cur.title.trim().isEmpty) {
        localized[entry.key] = LocalizedFields(
          title: entry.value,
          description: cur.description,
        );
      }
    }
  }

  SearchResult _mapResult({
    required List<ModrinthProject> pageHits,
    required Map<String, LocalizedFields> localized,
    required List<ModrinthProject> pinned,
    required List<ModrinthProject> remoteHits,
    required int page,
    required int remoteTotalHits,
  }) {
    final projects = pageHits.map((p) {
      final fields = localized[p.projectId];
      return Project(
        id: p.projectId,
        title: fields?.title ?? p.title,
        description: fields?.description ?? p.description,
        author: p.author,
        downloads: p.downloads,
        followers: p.follows,
        iconUrl: p.iconUrl,
        projectType: p.projectType,
        clientSide: p.clientSide,
        serverSide: p.serverSide,
        latestVersion: p.latestVersion,
        categories: p.categories,
        displayCategories: p.displayCategories,
        gameVersions: p.versions,
        dateCreated: p.dateCreated,
        dateModified: p.dateModified,
      );
    }).toList();

    final extraPinned = page == 0
        ? pinned
            .where((p) => !remoteHits.any((r) => r.projectId == p.projectId))
            .length
        : 0;

    return SearchResult(
      projects: projects,
      totalHits: remoteTotalHits + extraPinned,
    );
  }
}
