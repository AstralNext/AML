import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/discover/data/content_translator.dart';
import 'package:aml/src/features/discover/data/markup_safe_translator.dart';
import 'package:aml/src/features/discover/data/mcdb_client.dart';
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

  /// 详情页云翻译（正文 HTML/Markdown）开关。
  static bool get detailBodyEnabled {
    try {
      return getIt<UiSettingsState>().translateDiscoverContent.value;
    } catch (_) {
      return true;
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
      final mapped = {
        for (final p in projects)
          p.id: LocalizedFields(
            title: _preferZh(rows[p.id]?.zh, p.title),
            description: _preferZh(rows[p.id]?.descZh, p.description),
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
            title: _preferZh(byId[p.id]?.zhTitle, p.title),
            description: _preferZh(byId[p.id]?.zhSummary, p.description),
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

  /// 详情页：Modrinth 标题/简介走 MCDB；正文走云翻译。CF 仅正文走云翻译。
  static Future<({String title, String description, String body})>
      localizeDetail({
    required String platform,
    required String projectId,
    String? slug,
    required String title,
    required String description,
    required String body,
  }) async {
    var locTitle = title;
    var locDesc = description;

    if (platform == platformModrinth) {
      try {
        final rows = await McdbClient.lookupByIds({projectId});
        final row = rows[projectId];
        if (row != null) {
          locTitle = row.zh.isNotEmpty ? row.zh : title;
          locDesc = row.descZh ?? description;
        }
      } catch (e) {
        debugPrint('localizeDetail mcdb failed: $e');
      }
    }

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
