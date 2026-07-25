import 'dart:async';
import 'dart:collection';

import 'package:aml/src/features/discover/data/mcim_api.dart';
import 'package:http/http.dart' as http;

/// Official-first HTTP with MCIM mirror fallback (API + CDN URLs).
class McimFallbackHttp {
  McimFallbackHttp._();

  static final http.Client _client = http.Client();
  static const _maxConcurrentDownloads = 8;
  static int _activeDownloads = 0;
  static final Queue<Completer<void>> _downloadWaiters = Queue();

  static Future<http.Response> get(
    Uri officialUri, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 12),
  }) async {
    Object? lastError;
    http.Response? lastResponse;
    for (final uri in apiUriCandidates(officialUri)) {
      try {
        final response =
            await _client.get(uri, headers: headers).timeout(timeout);
        if (_isSuccess(response.statusCode)) {
          return response;
        }
        lastResponse = response;
        // Keep trying mirror on non-2xx (aligned with Rust mcim_fallback).
      } catch (e) {
        lastError = e;
      }
    }
    if (lastResponse != null) return lastResponse;
    if (lastError != null) throw lastError;
    throw Exception('请求失败: $officialUri');
  }

  /// Download bytes via official URL then MCIM CDN mirror.
  ///
  /// Globally limited to [_maxConcurrentDownloads] in-flight downloads so
  /// Discover list scroll does not open dozens of TLS streams at once.
  static Future<List<int>> downloadBytes(
    String url, {
    Map<String, String>? headers,
    Duration timeout = const Duration(seconds: 20),
  }) {
    return _withDownloadSlot(() async {
      Object? lastError;
      for (final candidate in downloadUrlCandidates(url)) {
        try {
          final response = await _client
              .get(Uri.parse(candidate), headers: headers)
              .timeout(timeout);
          if (_isSuccess(response.statusCode) &&
              response.bodyBytes.isNotEmpty) {
            return response.bodyBytes;
          }
        } catch (e) {
          lastError = e;
        }
      }
      if (lastError != null) throw lastError;
      throw Exception('下载失败: $url');
    });
  }

  static Future<T> _withDownloadSlot<T>(Future<T> Function() run) async {
    while (_activeDownloads >= _maxConcurrentDownloads) {
      final gate = Completer<void>();
      _downloadWaiters.add(gate);
      await gate.future;
    }
    _activeDownloads++;
    try {
      return await run();
    } finally {
      _activeDownloads--;
      if (_downloadWaiters.isNotEmpty) {
        _downloadWaiters.removeFirst().complete();
      }
    }
  }

  static List<Uri> apiUriCandidates(Uri official) {
    final mirror = mirrorApiUri(official);
    if (mirror == null || mirror == official) return [official];
    return [official, mirror];
  }

  static Uri? mirrorApiUri(Uri official) {
    if (official.host == 'api.modrinth.com') {
      final path = official.path;
      final suffix = path.startsWith('/v2')
          ? path.substring(3)
          : (path.startsWith('/v2/') ? path.substring(3) : path);
      return official.replace(
        scheme: 'https',
        host: 'mod.mcimirror.top',
        path: '/modrinth/v2$suffix',
        port: 443,
      );
    }
    if (official.host == 'api.curseforge.com') {
      return official.replace(
        scheme: 'https',
        host: 'mod.mcimirror.top',
        path: '/curseforge${official.path}',
        port: 443,
      );
    }
    return null;
  }

  static List<String> downloadUrlCandidates(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return const [];
    final mirror = mirrorDownloadUrl(trimmed);
    if (mirror == null || mirror == trimmed) return [trimmed];
    return [trimmed, mirror];
  }

  static String? mirrorDownloadUrl(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null) return null;
    switch (uri.host) {
      case 'cdn.modrinth.com':
        return url.replaceFirst(
          '${uri.scheme}://cdn.modrinth.com',
          McimApi.mirrorHost,
        );
      case 'edge.forgecdn.net':
      case 'mediafilez.forgecdn.net':
        return url.replaceFirst(
          '${uri.scheme}://${uri.host}',
          McimApi.mirrorHost,
        );
      default:
        return null;
    }
  }

  static bool _isSuccess(int code) => code >= 200 && code < 300;
}
