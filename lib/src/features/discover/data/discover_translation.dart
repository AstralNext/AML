import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
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

  /// Modrinth 列表：`network:false` 纯读本地 `project_i18n`；
  /// `true` 先查 MCDB 标题词条作为 hint，再由 Rust 合并缓存并批量拉 MCIM 简介。
  static Future<Map<String, LocalizedFields>> localizeModrinth({
    required List<({String id, String? slug, String title, String description})>
        projects,
    bool network = true,
  }) async {
    if (projects.isEmpty) return const {};

    final hints = <String, String>{};
    if (network && titleEnabled) {
      try {
        final rows =
            await McdbClient.lookupByIds(projects.map((p) => p.id).toSet());
        for (final entry in rows.entries) {
          final zh = entry.value.zh.trim();
          if (zh.isNotEmpty) hints[entry.key] = zh;
        }
      } catch (e) {
        debugPrint('localizeModrinth mcdb lookup failed: $e');
      }
    }

    return _localizeViaRust(
      platform: platformModrinth,
      projects: projects,
      network: network,
      hints: hints,
    );
  }

  /// 通用批量本地化（无 MCDB 标题词条），供 CurseForge 列表使用。
  /// [projects] 的 `id` 必须是平台侧原始 id（CF 传纯数字 mod id）。
  static Future<Map<String, LocalizedFields>> localizeProjects({
    required String platform,
    required List<({String id, String? slug, String title, String description})>
        projects,
    bool network = true,
  }) {
    return _localizeViaRust(
      platform: platform,
      projects: projects,
      network: network,
      hints: const {},
    );
  }

  static String _preferZh(String? zh, String fallback) {
    final t = zh?.trim();
    return (t != null && t.isNotEmpty) ? t : fallback;
  }

  /// Rust 统一编排：本地 `project_i18n` 缓存 → 缺失简介 MCIM 批量 → 回写。
  static Future<Map<String, LocalizedFields>> _localizeViaRust({
    required String platform,
    required List<({String id, String? slug, String title, String description})>
        projects,
    required bool network,
    required Map<String, String> hints,
  }) async {
    try {
      final rows = await i18n.localizeProjects(
        platform: platform,
        includeSummary: descriptionEnabled && network,
        items: [
          for (final p in projects)
            i18n.LocalizeProjectInputDto(
              projectId: p.id,
              slug: p.slug,
              sourceTitle: p.title,
              sourceSummary: p.description,
              hintZhTitle: titleEnabled ? hints[p.id] : null,
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
      debugPrint('localizeProjects rust failed: $e');
      return {
        for (final p in projects)
          p.id: LocalizedFields(title: p.title, description: p.description),
      };
    }
  }

  /// 详情页头部汉化：MCDB 标题（仅 Modrinth）+ MCIM 简介（本地缓存优先）。
  /// CurseForge 的 [projectId] 必须是纯数字 mod id。
  static Future<({String title, String description})> localizeHeader({
    required String platform,
    required String projectId,
    String? slug,
    required String title,
    required String description,
  }) async {
    String? hint;
    if (titleEnabled && platform == platformModrinth) {
      try {
        final rows = await McdbClient.lookupByIds({projectId});
        final zh = rows[projectId]?.zh.trim();
        if (zh != null && zh.isNotEmpty) hint = zh;
      } catch (e) {
        debugPrint('localizeHeader mcdb failed: $e');
      }
    }

    var locTitle = title;
    var locDesc = description;
    try {
      final rows = await i18n.localizeProjects(
        platform: platform,
        includeSummary: descriptionEnabled,
        items: [
          i18n.LocalizeProjectInputDto(
            projectId: projectId,
            slug: slug,
            sourceTitle: title,
            sourceSummary: description,
            hintZhTitle: titleEnabled ? hint : null,
          ),
        ],
      );
      if (rows.isNotEmpty) {
        locTitle = titleEnabled ? _preferZh(rows.first.zhTitle, title) : title;
        locDesc = descriptionEnabled
            ? _preferZh(rows.first.zhSummary, description)
            : description;
      }
    } catch (e) {
      debugPrint('localizeHeader rust failed: $e');
    }
    return (title: locTitle, description: locDesc);
  }

  /// 详情页翻译。
  ///
  /// - 标题/简介：见 [localizeHeader]（MCDB 标题 + MCIM 简介，缓存优先）。
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
    final header = await localizeHeader(
      platform: platform,
      projectId: projectId,
      slug: slug,
      title: title,
      description: description,
    );

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
      title: header.title,
      description: header.description,
      body: zhBody,
    );
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
          provider: TranslationProviders.microsoft,
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
