import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/discover/data/content_translator.dart';
import 'package:aml/src/features/discover/data/markup_safe_translator.dart';
import 'package:aml/src/features/discover/data/mcdb_client.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:aml/src/features/discover/data/microsoft_translator.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/rust/api/project_i18n.dart' as i18n;
import 'package:flutter/foundation.dart';

/// One MCDB title search hit used to expand Chinese search.
class LexiconSearchHit {
  const LexiconSearchHit({
    required this.platform,
    required this.projectId,
    required this.sourceTitle,
    this.zhTitle,
    this.slug,
    required this.score,
    required this.matchVia,
  });

  final String platform;
  final String projectId;
  final String sourceTitle;
  final String? zhTitle;
  final String? slug;
  final double score;
  final String matchVia;
}

/// Localized title + summary for a discover project.
class LocalizedFields {
  const LocalizedFields({
    required this.title,
    required this.description,
  });

  final String title;
  final String description;
}

/// Discover 翻译：列表先读本地 `project_i18n`，再补 MCDB；详情正文才走云翻译。
class DiscoverTranslation {
  DiscoverTranslation._();

  static const platformModrinth = 'modrinth';
  static const platformCurseforge = 'curseforge';

  /// 标题汉化（MCDB）开关。
  static bool get titleEnabled {
    try {
      return getIt<UiSettingsState>().translateTitle.value;
    } catch (_) {
      return true;
    }
  }

  /// 简介汉化（MCIM）开关。
  static bool get descriptionEnabled {
    try {
      return getIt<UiSettingsState>().translateDescription.value;
    } catch (_) {
      return true;
    }
  }

  /// 详情页云翻译（正文 HTML/Markdown）开关。
  static bool get detailBodyEnabled {
    try {
      return getIt<UiSettingsState>().translateBody.value;
    } catch (_) {
      return false;
    }
  }

  static bool get useMcdbSearch {
    try {
      return getIt<UiSettingsState>().useMcdbSearch.value;
    } catch (_) {
      return true;
    }
  }

  /// 含中文时才走 MCDB 标题搜索改写；纯英文/拉丁文直接搜平台原文。
  static bool shouldRewriteSearchQuery(String query) {
    final q = query.trim();
    if (q.isEmpty) return false;
    return MicrosoftTranslator.isMostlyChinese(q) ||
        MicrosoftTranslator.looksChinese(q);
  }

  static Future<List<LexiconSearchHit>> resolveLexiconHits(
    String query, {
    String? platform,
    int limit = 12,
  }) async {
    final q = query.trim();
    if (q.isEmpty || !useMcdbSearch || !shouldRewriteSearchQuery(q)) {
      return const [];
    }
    if (platform != null && platform != platformModrinth) return const [];

    try {
      final hits = await McdbClient.search(q, limit: limit);
      return [
        for (final h in hits)
          LexiconSearchHit(
            platform: platformModrinth,
            projectId: h.id,
            sourceTitle: h.en,
            zhTitle: h.zh,
            slug: h.slug,
            score: h.score,
            matchVia: 'mcdb-title',
          ),
      ];
    } catch (e) {
      debugPrint('MCDB search failed: $e');
      return const [];
    }
  }

  static String remoteQueryFromHits(String original, List<LexiconSearchHit> hits) {
    if (hits.isEmpty) return original;
    final titles = <String>[];
    for (final h in hits) {
      final t = h.sourceTitle.trim();
      if (t.isEmpty) continue;
      if (titles.any((x) => x.toLowerCase() == t.toLowerCase())) continue;
      titles.add(t);
      if (titles.length >= 3) break;
    }
    return titles.isEmpty ? original : titles.first;
  }

  /// Modrinth 列表：`network:false` 读本地 `project_i18n`；`true` 走 MCDB 并写回本地。
  static Future<Map<String, LocalizedFields>> localizeModrinth({
    required List<({String id, String? slug, String title, String description})>
        projects,
    bool network = true,
  }) async {
    if (projects.isEmpty) return const {};
    if (!network) {
      return _localizeModrinthFromLocal(projects);
    }

    try {
      final rows =
          await McdbClient.lookupByIds(projects.map((p) => p.id).toSet());
      // 简介走 MCIM 批量接口（MCDB 无 descZh）。
      Map<String, String> mcimDescs = const {};
      if (descriptionEnabled) {
        mcimDescs = await McimApi.fetchTranslationsBatch(
          projectIds: projects.map((p) => p.id).toList(),
        );
      }
      final mapped = {
        for (final p in projects)
          p.id: LocalizedFields(
            title: titleEnabled
                ? _preferZh(rows[p.id]?.zh, p.title)
                : p.title,
            description: descriptionEnabled
                ? (mcimDescs[p.id] ?? p.description)
                : p.description,
          ),
      };
      unawaited(_persistMcdbToLocal(projects, rows));
      return mapped;
    } catch (e) {
      debugPrint('localizeModrinth mcdb failed: $e');
      return _localizeModrinthFromLocal(projects);
    }
  }

  static String _preferZh(String? zh, String fallback) {
    final t = zh?.trim();
    return (t != null && t.isNotEmpty) ? t : fallback;
  }

  static Future<Map<String, LocalizedFields>> _localizeModrinthFromLocal(
    List<({String id, String? slug, String title, String description})>
        projects,
  ) async {
    try {
      final rows = await i18n.getProjectI18N(
        keys: [
          for (final p in projects)
            i18n.ProjectI18nKeyDto(
              platform: platformModrinth,
              projectId: p.id,
            ),
        ],
      );
      final byId = {for (final r in rows) r.projectId: r};
      return {
        for (final p in projects)
          p.id: LocalizedFields(
            title: titleEnabled
                ? _preferZh(byId[p.id]?.zhTitle, p.title)
                : p.title,
            description: descriptionEnabled
                ? _preferZh(byId[p.id]?.zhSummary, p.description)
                : p.description,
          ),
      };
    } catch (e) {
      debugPrint('localizeModrinth local cache failed: $e');
      return {
        for (final p in projects)
          p.id: LocalizedFields(title: p.title, description: p.description),
      };
    }
  }

  static Future<void> _persistMcdbToLocal(
    List<({String id, String? slug, String title, String description})>
        projects,
    Map<String, McdbRow> rows,
  ) async {
    final upserts = <i18n.ProjectI18nUpsertDto>[];
    for (final p in projects) {
      final row = rows[p.id];
      if (row == null) continue;
      final zhTitle = row.zh.trim();
      final zhSummary = row.descZh?.trim() ?? '';
      if (zhTitle.isEmpty && zhSummary.isEmpty) continue;
      upserts.add(
        i18n.ProjectI18nUpsertDto(
          platform: platformModrinth,
          projectId: p.id,
          slug: p.slug ?? row.slug,
          sourceTitle: p.title,
          zhTitle: zhTitle.isEmpty ? null : zhTitle,
          sourceSummary: p.description,
          zhSummary: zhSummary.isEmpty ? null : zhSummary,
          titleProvider: 'mcdb',
          summaryProvider: 'mcdb',
          titleConfidence: 1.0,
          summaryConfidence: 1.0,
          status: 'auto',
        ),
      );
    }
    if (upserts.isEmpty) return;
    try {
      await i18n.upsertProjectI18N(rows: upserts);
    } catch (e) {
      debugPrint('upsert project i18n failed: $e');
    }
  }

  /// 仅标题汉化（MCDB `row.zh`），用于详情页加载时立即显示中文标题，
  /// 与列表页行为一致。不走云翻译。
  static Future<String> localizeTitle({
    required String platform,
    required String projectId,
    required String title,
  }) async {
    if (!titleEnabled || platform != platformModrinth) return title;
    try {
      final rows = await McdbClient.lookupByIds({projectId});
      final row = rows[projectId];
      if (row != null && row.zh.trim().isNotEmpty) {
        return row.zh;
      }
    } catch (e) {
      debugPrint('localizeTitle mcdb failed: $e');
    }
    return title;
  }

  /// 详情页翻译。
  ///
  /// - 标题：MCDB `row.zh`，缺失则保留原文。
  /// - 简介：MCIM `/translate/{platform}/{id}`，缺失则保留原文。
  /// - 正文：`MarkupSafeTranslator` 云翻译，`kind='body_html'` 哈希缓存。
  static Future<({String title, String description, String body})>
      localizeDetail({
    required String platform,
    required String projectId,
    String? slug,
    required String title,
    required String description,
    required String body,
  }) async {
    // 标题走 MCDB。
    var locTitle = title;
    if (titleEnabled && platform == platformModrinth) {
      try {
        final rows = await McdbClient.lookupByIds({projectId});
        final row = rows[projectId];
        if (row != null && row.zh.trim().isNotEmpty) {
          locTitle = row.zh;
        }
      } catch (e) {
        debugPrint('localizeDetail mcdb title failed: $e');
      }
    }

    // 简介走 MCIM。
    var locDesc = description;
    if (descriptionEnabled) {
      final mcimZh = await McimApi.fetchTranslation(
        platform: platform,
        id: projectId,
      );
      if (mcimZh != null && mcimZh.trim().isNotEmpty) {
        locDesc = mcimZh;
      }
    }

    // 正文走云翻译 + 哈希缓存。
    final overview = body.trim().isNotEmpty ? body : description;
    final zhBody = detailBodyEnabled
        ? await _localizeBody(
            platform: platform,
            projectId: projectId,
            overview: overview,
          )
        : overview;

    return (
      title: locTitle,
      description: locDesc,
      body: zhBody,
    );
  }

  /// 纯文本云翻译 + 哈希持久缓存（标题/简介等短文本）。
  static Future<String> _localizeText({
    required String platform,
    required String projectId,
    required String kind,
    required String source,
  }) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return source;
    if (MicrosoftTranslator.isMostlyChinese(trimmed)) return trimmed;

    try {
      final hash = await i18n.textI18NHash(
        platform: platform,
        projectId: projectId,
        kind: kind,
        sourceText: trimmed,
      );
      final cached = await i18n.getTextI18N(contentHash: hash);
      if (cached != null && cached.zhText.trim().isNotEmpty) {
        return cached.zhText;
      }

      final zh = await ContentTranslator.translateToZhHans(trimmed, html: false);
      if (zh.trim().isNotEmpty && zh != trimmed) {
        unawaited(i18n.upsertTextI18N(
          contentHash: hash,
          platform: platform,
          projectId: projectId,
          kind: kind,
          sourceText: trimmed,
          zhText: zh,
          provider: ContentTranslator.providerId,
        ));
      }
      return zh;
    } catch (e) {
      debugPrint('localize $kind failed: $e');
      return source;
    }
  }

  /// 仅正文云翻译（带哈希缓存）。标题/简介由加载时的 MCDB/MCIM 处理。
  static Future<String> localizeBody({
    required String platform,
    required String projectId,
    required String overview,
  }) async {
    if (!detailBodyEnabled) return overview;
    return _localizeBody(platform: platform, projectId: projectId, overview: overview);
  }

  static Future<String> _localizeBody({
    required String platform,
    required String projectId,
    required String overview,
  }) async {
    final trimmed = overview.trim();
    if (trimmed.isEmpty) return overview;
    if (MicrosoftTranslator.isMostlyChinese(trimmed)) return trimmed;

    const kind = 'body_html';

    try {
      final hash = await i18n.textI18NHash(
        platform: platform,
        projectId: projectId,
        kind: kind,
        sourceText: trimmed,
      );
      final cached = await i18n.getTextI18N(contentHash: hash);
      if (cached != null && cached.zhText.trim().isNotEmpty) {
        return cached.zhText;
      }

      final zh = await MarkupSafeTranslator.translateBody(trimmed);
      if (zh.trim().isNotEmpty && zh != trimmed) {
        unawaited(i18n.upsertTextI18N(
          contentHash: hash,
          platform: platform,
          projectId: projectId,
          kind: kind,
          sourceText: trimmed,
          zhText: zh,
          provider: ContentTranslator.bodyProviderId,
        ));
      }
      return zh;
    } catch (e) {
      debugPrint('localize body failed: $e');
      return MarkupSafeTranslator.translateBody(trimmed);
    }
  }

  static bool looksLikeHtml(String text) {
    final head = text.trimLeft();
    if (head.length > 500) {
      return head.startsWith('<') &&
          RegExp(r'<\/?[a-zA-Z][^>]*>').hasMatch(head.substring(0, 500));
    }
    return head.startsWith('<') && RegExp(r'<\/?[a-zA-Z][^>]*>').hasMatch(head);
  }
}
