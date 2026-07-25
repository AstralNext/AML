import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Modrinth 汉化/搜索在线客户端（mcdb.astral.fan + search.mcdb.astral.fan）。
class McdbClient {
  McdbClient._();

  static const i18nBase = 'https://mcdb.astral.fan/api/v1/i18n';
  static const searchUrl = 'https://search.mcdb.astral.fan/v1/search';

  static const _timeout = Duration(seconds: 15);
  static const _maxShardCache = 48;

  static final http.Client _client = http.Client();
  static final Map<String, Map<String, dynamic>> _shardCache = {};

  static String shardHex(String projectId) {
    final prefix =
        projectId.length >= 2 ? projectId.substring(0, 2) : projectId.padRight(2, '_');
    return utf8
        .encode(prefix)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
  }

  /// True when every needed shard is already in memory (no network).
  static bool areShardsCached(Iterable<String> ids) {
    final needed = <String>{};
    for (final id in ids) {
      final trimmed = id.trim();
      if (trimmed.isEmpty) continue;
      needed.add(shardHex(trimmed));
    }
    if (needed.isEmpty) return true;
    return needed.every(_shardCache.containsKey);
  }

  static Future<Map<String, dynamic>> _fetchShard(String hex) async {
    final cached = _shardCache[hex];
    if (cached != null) return cached;

    final uri = Uri.parse('$i18nBase/$hex.json');
    final res = await _client.get(uri).timeout(_timeout);
    if (res.statusCode != 200) {
      throw Exception('i18n/$hex.json HTTP ${res.statusCode}');
    }

    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map<String, dynamic>) {
      throw Exception('i18n/$hex.json invalid JSON');
    }

    if (_shardCache.length >= _maxShardCache && _shardCache.isNotEmpty) {
      _shardCache.remove(_shardCache.keys.first);
    }
    _shardCache[hex] = body;
    return body;
  }

  static Future<Map<String, McdbRow>> lookupByIds(Set<String> ids) async {
    if (ids.isEmpty) return const {};

    final byShard = <String, List<String>>{};
    for (final id in ids) {
      final trimmed = id.trim();
      if (trimmed.isEmpty) continue;
      byShard.putIfAbsent(shardHex(trimmed), () => []).add(trimmed);
    }

    final out = <String, McdbRow>{};
    // Limit parallel shard GETs (each shard is a full JSON map).
    const maxParallel = 4;
    final entries = byShard.entries.toList();
    for (var i = 0; i < entries.length; i += maxParallel) {
      final chunk = entries.skip(i).take(maxParallel);
      await Future.wait(
        chunk.map((e) async {
          try {
            final shard = await _fetchShard(e.key);
            for (final id in e.value) {
              final raw = shard[id];
              if (raw is! Map) continue;
              final row = McdbRow.fromJson(id, raw);
              if (row != null) out[id] = row;
            }
          } catch (err, st) {
            debugPrint('McdbClient shard ${e.key}: $err\n$st');
          }
        }),
      );
    }
    return out;
  }

  static Future<Map<String, String>> lookupDescriptions(
    Iterable<String> projectIds,
  ) async {
    final ids = projectIds.map((e) => e.trim()).where((e) => e.isNotEmpty).toSet();
    if (ids.isEmpty) return const {};
    final rows = await lookupByIds(ids);
    final out = <String, String>{};
    for (final id in ids) {
      final d = rows[id]?.descZh;
      if (d != null && d.isNotEmpty) out[id] = d;
    }
    return out;
  }

  static Future<List<McdbSearchHit>> search(
    String query, {
    int limit = 12,
  }) async {
    final q = query.trim();
    if (q.isEmpty || limit <= 0) return const [];

    final res = await _client
        .post(
          Uri.parse(searchUrl),
          headers: const {'Content-Type': 'application/json; charset=utf-8'},
          body: jsonEncode({'q': q, 'limit': limit}),
        )
        .timeout(_timeout);

    if (res.statusCode != 200) {
      throw Exception('search HTTP ${res.statusCode}');
    }

    final body = jsonDecode(utf8.decode(res.bodyBytes));
    if (body is! Map<String, dynamic>) return const [];

    final hits = body['hits'];
    if (hits is! List) return const [];

    return [
      for (final h in hits)
        if (h is Map<String, dynamic>) McdbSearchHit.fromJson(h),
    ];
  }

  static void clearMemoryCache() => _shardCache.clear();
}

class McdbRow {
  const McdbRow({
    required this.id,
    required this.en,
    required this.zh,
    this.slug,
    this.type,
    this.descZh,
  });

  final String id;
  final String en;
  final String zh;
  final String? slug;
  final String? type;
  final String? descZh;

  static McdbRow? fromJson(String id, Map<dynamic, dynamic> raw) {
    final en = raw['en']?.toString().trim() ?? '';
    final zh = raw['zh']?.toString().trim() ?? '';
    if (en.isEmpty && zh.isEmpty) return null;

    final desc = raw['desc_zh']?.toString().trim();
    final slug = raw['slug']?.toString().trim();
    final type = raw['type']?.toString().trim();

    return McdbRow(
      id: id,
      en: en,
      zh: zh,
      slug: slug == null || slug.isEmpty ? null : slug,
      type: type == null || type.isEmpty ? null : type,
      descZh: desc == null || desc.isEmpty ? null : desc,
    );
  }
}

class McdbSearchHit {
  const McdbSearchHit({
    required this.id,
    required this.en,
    required this.zh,
    required this.score,
    this.slug,
    this.type,
  });

  final String id;
  final String en;
  final String zh;
  final double score;
  final String? slug;
  final String? type;

  static McdbSearchHit fromJson(Map<String, dynamic> raw) {
    return McdbSearchHit(
      id: raw['id']?.toString() ?? '',
      en: raw['en']?.toString() ?? '',
      zh: raw['zh']?.toString() ?? '',
      score: (raw['score'] as num?)?.toDouble() ?? 0,
      slug: raw['slug']?.toString(),
      type: raw['type']?.toString(),
    );
  }
}
