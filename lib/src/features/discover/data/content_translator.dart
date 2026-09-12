import 'package:aml/src/features/discover/data/microsoft_translator.dart';
import 'package:flutter/foundation.dart';

/// Translation provider ids used in persistent cache / MCDB metadata.
abstract final class TranslationProviders {
  static const mcdb = 'mcdb';
  static const microsoft = 'microsoft';
}

/// Routes title/body translation through Microsoft Edge translator.
/// Never throws to callers — failures fall back to original text.
class ContentTranslator {
  ContentTranslator._();

  static String get providerId => TranslationProviders.microsoft;

  static String get bodyProviderId => TranslationProviders.microsoft;

  static Future<String> translateToZhHans(
    String text, {
    bool html = false,
  }) async {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return trimmed;
    try {
      return await MicrosoftTranslator.translateToZhHans(trimmed, html: html);
    } catch (e) {
      debugPrint('ContentTranslator.translateToZhHans failed: $e');
      return trimmed;
    }
  }

  static Future<Map<String, String>> translateMap(
    Map<String, String> idToText, {
    bool html = false,
  }) async {
    if (idToText.isEmpty) return const {};
    try {
      return await MicrosoftTranslator.translateMap(idToText, html: html);
    } catch (e) {
      debugPrint('ContentTranslator.translateMap failed: $e');
      return Map<String, String>.from(idToText);
    }
  }
}
