import 'package:aml/src/features/discover/data/cache_service.dart';

/// 共享的发现页 HTTP 缓存与平台官方 API 常量。
///
/// MCIM 简介翻译的请求/回退/回写已下沉到 Rust
/// （`crate::api::project_i18n::localize_projects`），Dart 侧不再直连 MCIM。
class McimApi {
  McimApi._();

  /// Official Modrinth v2 base (no trailing slash).
  static const modrinthV2Official = 'https://api.modrinth.com/v2';

  /// Official CurseForge API root (no trailing slash).
  static const curseforgeOfficial = 'https://api.curseforge.com';

  /// Shared cache used by discover HTTP clients (LRU-capped).
  static final CacheService cache = CacheService(maxEntries: 192);
}
