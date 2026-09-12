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
    final cacheKey =
        'discover_mr_q=$query&p=$page&ps=$pageSize&i=$index&f=$facets';

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

    final cached = _cache.get(cacheKey, _searchTtl);
    if (cached is SearchResult) {
      return SearchResult(
        projects: cached.projects,
        totalHits: cached.totalHits,
      );
    }

    final offset = page * pageSize;
    final remote = await ModrinthApiService.searchProjects(
      query: rewritten,
      limit: pageSize,
      offset: offset,
      index: index,
      facets: facets,
      cacheDuration: _searchTtl,
    );

    // Page 0: pin lexicon matches before remote hits.
    final pinned = <ModrinthProject>[];
    final lexiconById = {
      for (final h in lexicon) h.projectId: h,
    };
    final lexiconZhById = <String, String>{
      for (final h in lexicon)
        if ((h.zhTitle ?? '').trim().isNotEmpty) h.projectId: h.zhTitle!.trim(),
    };
    if (page == 0 && lexicon.isNotEmpty) {
      // Cap pin fan-out: 4 detail GETs is enough for Chinese title search UX.
      final fetched = await Future.wait(
        lexicon.take(4).map((hit) async {
          try {
            final detail = await ModrinthApiService.getProject(
              hit.projectId,
              localize: false,
            );
            if (facets != null && facets.isNotEmpty) {
              // Soft filter by project_type facet when present.
              for (final group in facets) {
                for (final f in group) {
                  if (f.startsWith('project_type:')) {
                    final want = f.substring('project_type:'.length);
                    if (want.isNotEmpty && detail.projectType != want) {
                      return null;
                    }
                  }
                }
              }
            }
            final zhTitle = hit.zhTitle?.trim();
            return ModrinthProject(
              slug: detail.slug,
              title: (zhTitle != null && zhTitle.isNotEmpty)
                  ? zhTitle
                  : detail.title,
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
        }),
      );
      for (final p in fetched) {
        if (p != null) pinned.add(p);
      }
    }

    final seen = <String>{};
    final merged = <ModrinthProject>[];
    for (final p in [...pinned, ...remote.hits]) {
      if (seen.add(p.projectId)) merged.add(p);
    }
    final pageHits = merged.take(pageSize).toList();

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

    // Seed ZH titles already known from MCDB title search.
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

    SearchResult mapResult(Map<String, LocalizedFields> loc) {
      final projects = pageHits.map((p) {
        final fields = loc[p.projectId];
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
              .where((p) => !remote.hits.any((r) => r.projectId == p.projectId))
              .length
          : 0;

      return SearchResult(
        projects: projects,
        totalHits: remote.totalHits + extraPinned,
      );
    }

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
}
