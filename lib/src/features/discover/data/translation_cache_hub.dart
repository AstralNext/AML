import 'package:aml/src/features/discover/data/mcdb_client.dart';
import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:aml/src/features/discover/data/microsoft_translator.dart';
import 'package:aml/src/rust/api/project_i18n.dart' as i18n;

/// Session memory + persistent DB translation cache helpers.
class TranslationCacheHub {
  TranslationCacheHub._();

  static int get memoryHits => MicrosoftTranslator.cache.hits;

  static int get memoryMisses => MicrosoftTranslator.cache.misses;

  static int get microsoftEntries => MicrosoftTranslator.cache.entryCount;

  static int get memoryEntries => microsoftEntries;

  static void clearMemory() {
    MicrosoftTranslator.cache.clear();
    McdbClient.clearMemoryCache();
    McimApi.cache.clear();
  }

  static Future<i18n.TranslationCacheStatsDto> persistentStats() =>
      i18n.translationCacheStats();

  static Future<int> clearProjectTitles() async =>
      (await i18n.clearProjectI18NCache()).toInt();

  static Future<int> clearBodies() async =>
      (await i18n.clearTextI18NCache()).toInt();

  static Future<int> clearAllPersistent() async =>
      (await i18n.clearAllTranslationCaches()).toInt();
}
