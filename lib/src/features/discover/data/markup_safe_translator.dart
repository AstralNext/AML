import 'package:aml/src/features/discover/data/content_translator.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/microsoft_translator.dart';
import 'package:flutter/foundation.dart';
import 'package:markdown/markdown.dart' as md;

/// Translate Modrinth/CurseForge body text without destroying HTML / Markdown.
///
/// Flow: normalize to HTML → strip heavy payloads → protect code/pre/svg →
/// HTML-mode translate (chunked) → restore → sanity-check.
class MarkupSafeTranslator {
  MarkupSafeTranslator._();

  static final _protectPatterns = <RegExp>[
    RegExp(r'<pre\b[^>]*>[\s\S]*?</pre>', caseSensitive: false),
    RegExp(r'<code\b[^>]*>[\s\S]*?</code>', caseSensitive: false),
    RegExp(r'<kbd\b[^>]*>[\s\S]*?</kbd>', caseSensitive: false),
    RegExp(r'<samp\b[^>]*>[\s\S]*?</samp>', caseSensitive: false),
    RegExp(r'<svg\b[^>]*>[\s\S]*?</svg>', caseSensitive: false),
    RegExp(r'<math\b[^>]*>[\s\S]*?</math>', caseSensitive: false),
    RegExp(r'<!--[\s\S]*?-->'),
  ];

  /// Huge data-URIs / long URLs inflate payloads and make Edge MT fail silently.
  static final _heavyAttr = RegExp(
    r'''((?:src|href|poster)\s*=\s*)(["'])(data:[^"']+|https?:[^"']{400,})\2''',
    caseSensitive: false,
  );

  /// Translate [source] (Markdown or HTML) to zh-Hans HTML when possible.
  /// Always returns a string safe to feed into [MarkdownContent].
  static Future<String> translateBody(String source) async {
    final trimmed = source.trim();
    if (trimmed.isEmpty) return source;
    if (MicrosoftTranslator.isMostlyChinese(trimmed)) return source;

    try {
      final asHtml = toTranslatableHtml(trimmed);
      final heavy = <String>[];
      final slim = _stripHeavyAttrs(asHtml, heavy);
      final protected = protectSegments(slim);
      final zh = await ContentTranslator.translateToZhHans(
        protected.text,
        html: true,
      );
      var out = unprotectSegments(zh, protected.tokens);
      out = _restoreHeavyAttrs(out, heavy).trim();
      if (out.isEmpty) return source;
      if (!isPlausibleTranslation(sourceHtml: asHtml, translatedHtml: out)) {
        debugPrint('MarkupSafeTranslator: rejected corrupt body translation');
        return source;
      }
      // If nothing actually changed in visible text, keep original source form.
      if (out == slim || out == asHtml) {
        // Still prefer HTML form when source was Markdown (renderer expects it).
        return DiscoverTranslation.looksLikeHtml(trimmed) ? source : asHtml;
      }
      return out;
    } catch (e) {
      debugPrint('MarkupSafeTranslator failed: $e');
      return source;
    }
  }

  /// Markdown → HTML; HTML left as-is.
  static String toTranslatableHtml(String source) {
    if (DiscoverTranslation.looksLikeHtml(source)) {
      return source;
    }
    return md.markdownToHtml(
      source,
      extensionSet: md.ExtensionSet.gitHubWeb,
      encodeHtml: true,
    );
  }

  static String _stripHeavyAttrs(String html, List<String> store) {
    return html.replaceAllMapped(_heavyAttr, (m) {
      final idx = store.length;
      store.add(m[3]!);
      return '${m[1]}${m[2]}aml-heavy://$idx${m[2]}';
    });
  }

  static String _restoreHeavyAttrs(String html, List<String> store) {
    var out = html;
    for (var i = 0; i < store.length; i++) {
      for (final ph in [
        'aml-heavy://$i',
        'aml-heavy&#58;//$i',
        'aml-heavy&amp;#58;//$i',
      ]) {
        if (out.contains(ph)) {
          out = out.replaceAll(ph, store[i]);
          break;
        }
      }
    }
    return out;
  }

  static ({String text, List<String> tokens}) protectSegments(String html) {
    final tokens = <String>[];
    var text = html;
    for (final pattern in _protectPatterns) {
      text = text.replaceAllMapped(pattern, (m) {
        final idx = tokens.length;
        tokens.add(m[0]!);
        return '&#xE000;AML$idx&#xE001;';
      });
    }
    return (text: text, tokens: tokens);
  }

  static String unprotectSegments(String html, List<String> tokens) {
    var out = html;
    for (var i = 0; i < tokens.length; i++) {
      final variants = <String>[
        '&#xE000;AML$i&#xE001;',
        '\uE000AML$i\uE001',
        '&#xe000;AML$i&#xe001;',
        '&amp;#xE000;AML$i&amp;#xE001;',
      ];
      for (final v in variants) {
        if (out.contains(v)) {
          out = out.replaceAll(v, tokens[i]);
          break;
        }
      }
    }
    return out;
  }

  /// Reject translations that lost most markup.
  static bool isPlausibleTranslation({
    required String sourceHtml,
    required String translatedHtml,
  }) {
    final srcTags = _tagCount(sourceHtml);
    final zhTags = _tagCount(translatedHtml);
    // Large HTML: allow more tag drift from chunk stitching; only reject collapse.
    final minKeep = srcTags >= 40 ? 0.25 : 0.4;
    if (srcTags >= 4 && zhTags < (srcTags * minKeep).floor()) {
      return false;
    }
    return true;
  }

  static int _tagCount(String html) =>
      RegExp(r'<\/?[a-zA-Z][^>]*>').allMatches(html).length;
}
