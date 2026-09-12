import 'package:aml/src/features/discover/data/cache_service.dart';

/// MCIM mirror host + shared discover HTTP cache.
class McimApi {
  McimApi._();

  static const mirrorHost = 'https://mod.mcimirror.top';

  /// Official Modrinth v2 base (no trailing slash).
  static const modrinthV2Official = 'https://api.modrinth.com/v2';

  /// Official CurseForge API root (no trailing slash).
  static const curseforgeOfficial = 'https://api.curseforge.com';

  /// Shared cache used by discover HTTP clients (LRU-capped).
  static final CacheService cache = CacheService(maxEntries: 192);
}
