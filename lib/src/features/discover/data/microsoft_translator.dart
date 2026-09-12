import 'dart:convert';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:http/http.dart' as http;

/// Microsoft Edge Translator (same public endpoints Axolotl uses).
class MicrosoftTranslator {
  MicrosoftTranslator._();

  static const _authUrl = 'https://edge.microsoft.com/translate/auth';
  static const _translateUrl =
      'https://api-edge.cognitive.microsofttranslator.com/translate';

  /// Edge/public endpoint is happier with smaller payloads.
  static const _maxCharsPerRequest = 4000;

  static const _cacheTtl = Duration(days: 7);
  static final CacheService cache = CacheService(maxEntries: 128);

  static String? _token;
  static DateTime? _tokenExpiresAt;

  static bool looksChinese(String text) =>
      RegExp(r'[\u4e00-\u9fff]').hasMatch(text);

  /// True when visible text is predominantly CJK (ignores HTML tags).
  /// A few Chinese characters in a large English page must NOT skip translation.
  static bool isMostlyChinese(String text, {double threshold = 0.5}) {
    final sample = text
        .replaceAll(RegExp(r'<[^>]+>'), ' ')
        .replaceAll(RegExp(r'&[a-zA-Z0-9#]+;'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
    if (sample.isEmpty) return false;
    var cjk = 0;
    var latin = 0;
    for (final cu in sample.runes) {
      if (cu >= 0x4E00 && cu <= 0x9FFF) {
        cjk++;
      } else if ((cu >= 0x41 && cu <= 0x5A) || (cu >= 0x61 && cu <= 0x7A)) {
        latin++;
      }
    }
    final total = cjk + latin;
    if (total < 8) return cjk > 0 && latin == 0;
    return cjk / total >= threshold;
  }

  /// Translate text to Simplified Chinese. Returns [text] on failure.
  static Future<String> translateToZhHans(
    String text, {
    bool html = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty || isMostlyChinese(trimmed)) return trimmed;

    final cacheKey = 'ms_tr_${html ? 'h' : 'p'}_${trimmed.hashCode}';
    final cached = cache.get(cacheKey, _cacheTtl);
    if (cached is String && cached.isNotEmpty) return cached;

    try {
      // HTML payloads: smaller chunks — Edge public API often drops/fails on large ones.
      final limit = html ? 2500 : _maxCharsPerRequest;
      final zh = trimmed.length <= limit
          ? (await _translateChunk([trimmed], html: html)).first
          : await _translateLong(trimmed, html: html, maxChars: limit);
      final out = zh.trim();
      if (out.isEmpty) return trimmed;
      cache.put(cacheKey, out);
      return out;
    } catch (_) {
      return trimmed;
    }
  }

  /// Translate many strings (order preserved). Failed items keep the original.
  static Future<List<String>> translateMany(
    List<String> texts, {
    bool html = false,
  }) async {
    if (texts.isEmpty) return const [];

    final out = List<String>.from(texts);
    final pendingIndexes = <int>[];
    final pendingTexts = <String>[];

    for (var i = 0; i < texts.length; i++) {
      final t = texts[i].trim();
      if (t.isEmpty || isMostlyChinese(t)) {
        out[i] = t;
        continue;
      }
      final cacheKey = 'ms_tr_${html ? 'h' : 'p'}_${t.hashCode}';
      final cached = cache.get(cacheKey, _cacheTtl);
      if (cached is String && cached.isNotEmpty) {
        out[i] = cached;
        continue;
      }
      pendingIndexes.add(i);
      pendingTexts.add(t);
    }
    if (pendingTexts.isEmpty) return out;

    const chunkSize = 10;
    for (var start = 0; start < pendingTexts.length; start += chunkSize) {
      final end = (start + chunkSize).clamp(0, pendingTexts.length);
      final chunk = pendingTexts.sublist(start, end);
      // Long items are handled one-by-one. Never throw — keep originals.
      for (var j = 0; j < chunk.length; j++) {
        final src = chunk[j];
        final idx = pendingIndexes[start + j];
        try {
          final limit = html ? 2500 : _maxCharsPerRequest;
          final zh = src.length <= limit
              ? (await _translateChunk([src], html: html)).first
              : await _translateLong(src, html: html, maxChars: limit);
          final trimmed = zh.trim();
          if (trimmed.isEmpty) continue;
          out[idx] = trimmed;
          cache.put('ms_tr_${html ? 'h' : 'p'}_${src.hashCode}', trimmed);
        } catch (_) {
          // Keep original text; never fail the discover load path.
        }
      }
    }
    return out;
  }

  /// Map id → source text to id → Chinese (best-effort).
  static Future<Map<String, String>> translateMap(
    Map<String, String> idToText, {
    bool html = false,
  }) async {
    if (idToText.isEmpty) return const {};
    try {
      final ids = idToText.keys.toList();
      final sources = ids.map((id) => idToText[id] ?? '').toList();
      final translated = await translateMany(sources, html: html);
      final out = <String, String>{};
      for (var i = 0; i < ids.length; i++) {
        final zh = translated[i].trim();
        if (zh.isNotEmpty) out[ids[i]] = zh;
      }
      return out;
    } catch (_) {
      return Map<String, String>.from(idToText);
    }
  }

  static Future<String> _translateLong(
    String text, {
    required bool html,
    int maxChars = _maxCharsPerRequest,
  }) async {
    final parts = _splitForTranslation(text, html: html, maxChars: maxChars);
    final buf = StringBuffer();
    for (final part in parts) {
      if (part.trim().isEmpty) {
        buf.write(part);
        continue;
      }
      if (isMostlyChinese(part)) {
        buf.write(part);
        continue;
      }
      try {
        final zh = (await _translateChunk([part], html: html)).first;
        buf.write(zh.trim().isEmpty ? part : zh);
      } catch (_) {
        // Keep this chunk; do not abort the whole document.
        buf.write(part);
      }
    }
    return buf.toString();
  }

  /// Prefer paragraph / block-tag boundaries; never cut inside an HTML tag.
  static List<String> _splitForTranslation(
    String text, {
    required bool html,
    int maxChars = _maxCharsPerRequest,
  }) {
    if (text.length <= maxChars) return [text];
    final parts = <String>[];
    var start = 0;
    while (start < text.length) {
      var end = (start + maxChars).clamp(0, text.length);
      if (end < text.length) {
        final window = text.substring(start, end);
        final minBreak = maxChars ~/ 3;
        final candidates = <int>[
          if (html) ...[
            window.lastIndexOf('</p>'),
            window.lastIndexOf('</div>'),
            window.lastIndexOf('</li>'),
            window.lastIndexOf('</h1>'),
            window.lastIndexOf('</h2>'),
            window.lastIndexOf('</h3>'),
            window.lastIndexOf('</tr>'),
            window.lastIndexOf('</table>'),
            window.lastIndexOf('</section>'),
            window.lastIndexOf('>'),
          ],
          window.lastIndexOf('\n\n'),
          window.lastIndexOf('\n'),
          window.lastIndexOf('. '),
          window.lastIndexOf('。'),
          window.lastIndexOf(' '),
        ];
        final breakAt = candidates
            .where((i) => i > minBreak)
            .fold<int>(-1, (a, b) => a > b ? a : b);
        if (breakAt > 0) {
          final token = window.substring(breakAt);
          var advance = 1;
          if (token.startsWith('</')) {
            final close = token.indexOf('>');
            advance = close >= 0 ? close + 1 : 1;
          } else if (token.startsWith('\n\n')) {
            advance = 2;
          }
          end = start + breakAt + advance;
        }
        final slice = text.substring(start, end);
        final lastLt = slice.lastIndexOf('<');
        final lastGt = slice.lastIndexOf('>');
        if (lastLt > lastGt && lastLt > maxChars ~/ 4) {
          end = start + lastLt;
        }
      }
      if (end <= start) {
        end = (start + maxChars).clamp(0, text.length);
      }
      parts.add(text.substring(start, end));
      start = end;
    }
    return parts;
  }

  static Future<String> _ensureToken() async {
    final now = DateTime.now();
    if (_token != null &&
        _tokenExpiresAt != null &&
        now.isBefore(_tokenExpiresAt!)) {
      return _token!;
    }
    final response = await http
        .get(Uri.parse(_authUrl), headers: {'User-Agent': 'AML-App/1.0.0'})
        .timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('Microsoft translate auth failed: ${response.statusCode}');
    }
    final token = response.body.trim();
    if (token.isEmpty) {
      throw Exception('Microsoft translate auth returned empty token');
    }
    _token = token;
    _tokenExpiresAt = now.add(const Duration(minutes: 8));
    return token;
  }

  static Future<List<String>> _translateChunk(
    List<String> texts, {
    required bool html,
  }) async {
    if (texts.isEmpty) return const [];
    var token = await _ensureToken();

    Future<http.Response> send(String auth) {
      final uri = Uri.parse(_translateUrl).replace(
        queryParameters: {
          'api-version': '3.0',
          'to': 'zh-Hans',
          'textType': html ? 'html' : 'plain',
        },
      );
      return http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'Authorization': 'Bearer $auth',
              'User-Agent': 'AML-App/1.0.0',
            },
            body: jsonEncode([
              for (final t in texts) {'Text': t},
            ]),
          )
          .timeout(const Duration(seconds: 30));
    }

    var response = await send(token);
    if (response.statusCode == 401 || response.statusCode == 403) {
      _token = null;
      _tokenExpiresAt = null;
      token = await _ensureToken();
      response = await send(token);
    }
    if (response.statusCode == 429) {
      await Future<void>.delayed(const Duration(seconds: 2));
      response = await send(token);
    }
    if (response.statusCode != 200) {
      throw Exception(
        'Microsoft translate failed: ${response.statusCode}',
      );
    }

    final list = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    final out = <String>[];
    for (var i = 0; i < texts.length; i++) {
      if (i >= list.length) {
        out.add(texts[i]);
        continue;
      }
      final item = list[i];
      if (item is! Map<String, dynamic>) {
        out.add(texts[i]);
        continue;
      }
      final translations = item['translations'];
      if (translations is! List || translations.isEmpty) {
        out.add(texts[i]);
        continue;
      }
      final first = translations.first;
      final text = first is Map ? first['text']?.toString() : null;
      out.add((text == null || text.isEmpty) ? texts[i] : text);
    }
    return out;
  }
}
