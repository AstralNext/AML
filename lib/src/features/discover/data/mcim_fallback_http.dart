import 'package:aml/src/rust/api/mcim_fallback_api.dart' as rust;
import 'package:http/http.dart' as http;

/// Official-first HTTP with MCIM mirror fallback (API + CDN URLs).
///
/// URL 候选生成与回退重试统一在 Rust（`config::mcim_url_candidates`），
/// 本类只是薄壳，保持旧签名以免改动调用方。
class McimFallbackHttp {
  McimFallbackHttp._();

  static Future<http.Response> get(
    Uri officialUri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    final r = await rust.mcimGet(
      url: officialUri.toString(),
      headers: headers,
      timeoutSecs: BigInt.from(timeout.inSeconds),
    );
    return http.Response.bytes(
      r.body,
      r.statusCode,
      headers: r.headers,
    );
  }

  /// Download bytes via official URL then MCIM/CDN mirrors.
  ///
  /// 并发闸门（全局 8 路）在 Rust 侧用信号量实现。
  static Future<List<int>> downloadBytes(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) async {
    final bytes = await rust.mcimGetBytes(
      url: url,
      headers: headers,
      timeoutSecs: BigInt.from(timeout.inSeconds),
    );
    return bytes;
  }
}
