import 'dart:convert';

import 'package:aml/src/features/discover/data/cache_service.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Translation provider ids used in persistent cache / MCDB metadata.
abstract final class TranslationProviders {
  static const mcdb = 'mcdb';
  static const microsoft = 'microsoft';
}

/// Microsoft Edge Translator (public endpoint, no auth required).
///
/// As of 2026-08 the old token endpoint
/// `https://edge.microsoft.com/translate/auth` returns 404. The current free
/// path is `https://edge.microsoft.com/translate/translatetext`, which accepts
/// a JSON array of plain strings and requires only a browser-like User-Agent.
class MicrosoftTranslator {
  MicrosoftTranslator._();

  static const _translateUrl =
      'https://edge.microsoft.com/translate/translatetext';

  /// Browser-like UA is required by the Edge translatetext endpoint.
  static const _userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/113.0.0.0 Safari/537.36 Edg/113.0.1774.35';

  /// Edge/public endpoint is happier with smaller payloads.
  static const _maxCharsPerRequest = 4000;

  static const _cacheTtl = Duration(days: 7);
  static final CacheService cache = CacheService(maxEntries: 128);

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

  // —— 受保护片段（代码块/终端载荷）占位 token 的唯一出处 ——
  // MarkupSafeTranslator 也从这里取用，不要再复制字面量。
  static const protectOpenEntity = '&#xE000;';
  static const protectCloseEntity = '&#xE001;';

  /// 生成第 [idx] 个受保护片段的占位 token：`&#xE000;AML$idx&#xE001;`。
  /// A split must never fall inside a token or the `<pre>`/`<code>`/terminal
  /// payload it stands for gets leaked to the translator and corrupted.
  static String protectToken(int idx) =>
      '${protectOpenEntity}AML$idx$protectCloseEntity';

  static final _protectOpen = RegExp(r'&(?:amp;)?#x[Ee]000;');
  static final _protectClose = RegExp(r'&(?:amp;)?#x[Ee]001;');

  /// If [pos] sits inside a protected token, return the index right after its
  /// closing marker. Otherwise return null.
  static int? _protectedTokenEnd(String text, int pos) {
    final open = _protectOpen.allMatches(text.substring(0, pos));
    if (open.isEmpty) return null;
    final lastOpen = open.last;
    final close = _protectClose.firstMatch(text.substring(lastOpen.start));
    if (close == null) return null;
    final tokenEnd = lastOpen.start + close.end;
    if (pos < tokenEnd) return tokenEnd;
    return null;
  }

  /// Prefer paragraph / block-tag boundaries; never cut inside an HTML tag
  /// or a protected segment token.
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
        // Never split inside a protected (code/pre/terminal) token.
        final tokenEnd = _protectedTokenEnd(text, end);
        if (tokenEnd != null) {
          end = tokenEnd;
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

  static Future<List<String>> _translateChunk(
    List<String> texts, {
    required bool html,
  }) async {
    if (texts.isEmpty) return const [];

    final uri = Uri.parse(_translateUrl).replace(
      queryParameters: {
        'to': 'zh-Hans',
        'textType': html ? 'html' : 'plain',
        'isEnterpriseClient': 'false',
      },
    );

    http.Response response = await http
        .post(
          uri,
          headers: {
            'Content-Type': 'application/json; charset=utf-8',
            'User-Agent': _userAgent,
          },
          // New endpoint expects a plain JSON array of strings, NOT
          // [{"Text": "..."}] as the old Azure-style endpoint did.
          body: jsonEncode(texts),
        )
        .timeout(const Duration(seconds: 30));

    if (response.statusCode == 429) {
      await Future<void>.delayed(const Duration(seconds: 2));
      response = await http
          .post(
            uri,
            headers: {
              'Content-Type': 'application/json; charset=utf-8',
              'User-Agent': _userAgent,
            },
            body: jsonEncode(texts),
          )
          .timeout(const Duration(seconds: 30));
    }
    if (response.statusCode != 200) {
      final body = utf8.decode(response.bodyBytes, allowMalformed: true);
      debugPrint(
        '[ms-translate] HTTP ${response.statusCode} '
        'body=${body.length > 200 ? body.substring(0, 200) : body}',
      );
      throw Exception(
        'Microsoft translate failed: ${response.statusCode}',
      );
    }

    final list = jsonDecode(utf8.decode(response.bodyBytes)) as List<dynamic>;
    debugPrint('[ms-translate] HTTP 200 items=${list.length}');
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
