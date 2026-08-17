import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/domain/models/ui_settings.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// In-memory proxy flags for Dart HTTP, plus `proxy_settings.json` for Rust.
///
/// Does not set process `HTTP_PROXY` so Minecraft child processes stay unaffected.
class ProxyRuntime {
  ProxyRuntime._();

  static String mode = 'off';
  static String url = '';
  static String resolvedUrl = '';

  static String? _iePac;
  static List<String> _ieBypass = const [];
  static Timer? _refreshTimer;
  static bool _overridesInstalled = false;
  static bool _refreshing = false;

  static void installHttpOverrides() {
    if (_overridesInstalled) return;
    _overridesInstalled = true;
    HttpOverrides.global = _AmlHttpOverrides();
    unawaited(refreshSystemProxy(persist: false));
  }

  static void apply(UiSettings settings) {
    mode = settings.proxyMode;
    url = settings.proxyUrl.trim();
    if (mode != 'system') {
      resolvedUrl = '';
      _iePac = null;
      _ieBypass = const [];
    }
    _ensureRefreshTimer();
  }

  static Map<String, dynamic> toJson() {
    final manual = mode == 'manual' ? parseProxyUrl(url) : null;
    return {
      'mode': mode,
      'url': manual?.requestUrl ?? url,
      'resolvedUrl': resolvedUrl,
    };
  }

  static Future<void> syncToResourceDir(UiSettings settings) async {
    apply(settings);
    if (mode == 'system') {
      await refreshSystemProxy(persist: false);
    }
    await _writeJson();
  }

  static Future<void> refreshSystemProxy({bool persist = true}) async {
    if (mode != 'system' || _refreshing) return;
    _refreshing = true;
    try {
      var nextResolved = '';
      String? nextPac;
      var nextBypass = const <String>[];

      final fromEnv = HttpClient.findProxyFromEnvironment(
        Uri.parse('https://example.com'),
      );
      if (fromEnv.trim().toUpperCase() != 'DIRECT') {
        // Dart reads env live; leave resolvedUrl empty so Rust also follows env/NO_PROXY.
      } else if (Platform.isWindows) {
        final ie = await _readWindowsIeProxy();
        if (ie != null) {
          nextPac = ie.pac;
          nextResolved = ie.url;
          nextBypass = ie.bypass;
        }
      }

      final changed = resolvedUrl != nextResolved ||
          _iePac != nextPac ||
          !_listEquals(_ieBypass, nextBypass);
      resolvedUrl = nextResolved;
      _iePac = nextPac;
      _ieBypass = nextBypass;
      if (persist && changed) {
        await _writeJson();
      }
    } catch (e) {
      debugPrint('读取系统代理失败: $e');
    } finally {
      _refreshing = false;
    }
  }

  /// PAC directive for dart:io (`DIRECT` / `PROXY host:port` / `SOCKS host:port`).
  static String findProxyDirective(Uri uri) {
    if (_isLoopback(uri.host)) return 'DIRECT';
    switch (mode) {
      case 'off':
        return 'DIRECT';
      case 'manual':
        final spec = parseProxyUrl(url);
        if (spec == null) return 'DIRECT';
        return spec.pacDirective;
      case 'system':
      default:
        if (_matchesBypass(uri.host, _ieBypass)) return 'DIRECT';
        try {
          final fromEnv = HttpClient.findProxyFromEnvironment(uri);
          if (fromEnv.trim().toUpperCase() != 'DIRECT') {
            return fromEnv;
          }
        } catch (_) {}
        final cached = _iePac?.trim();
        if (cached != null && cached.isNotEmpty) return cached;
        return 'DIRECT';
    }
  }

  static HttpClientCredentials? get proxyCredentials {
    final spec = mode == 'manual' ? parseProxyUrl(url) : null;
    if (spec == null || spec.user == null || spec.user!.isEmpty) return null;
    return HttpClientBasicCredentials(spec.user!, spec.password ?? '');
  }

  static ParsedProxy? parseProxyUrl(String raw) {
    var text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('://')) {
      text = 'http://$text';
    }
    final uri = Uri.tryParse(text);
    if (uri == null || uri.host.isEmpty) return null;
    final scheme = uri.scheme.toLowerCase();
    if (scheme != 'http' &&
        scheme != 'https' &&
        scheme != 'socks' &&
        scheme != 'socks4' &&
        scheme != 'socks5' &&
        scheme != 'socks5h') {
      return null;
    }
    final socks = scheme.startsWith('socks');
    final port = uri.hasPort ? uri.port : (socks ? 1080 : 8080);
    if (port <= 0 || port > 65535) return null;
    return ParsedProxy(
      scheme: socks
          ? (scheme == 'socks5h' ? 'socks5h' : 'socks5')
          : (scheme == 'https' ? 'https' : 'http'),
      host: uri.host,
      port: port,
      user: uri.userInfo.isEmpty ? null : Uri.decodeComponent(uri.userInfo.split(':').first),
      password: uri.userInfo.contains(':')
          ? Uri.decodeComponent(uri.userInfo.substring(uri.userInfo.indexOf(':') + 1))
          : null,
    );
  }

  static void _ensureRefreshTimer() {
    if (mode != 'system') {
      _refreshTimer?.cancel();
      _refreshTimer = null;
      return;
    }
    _refreshTimer ??= Timer.periodic(const Duration(seconds: 8), (_) {
      unawaited(refreshSystemProxy());
    });
    unawaited(refreshSystemProxy());
  }

  static Future<void> _writeJson() async {
    try {
      if (!getIt.isRegistered<ResourceSettingsState>()) return;
      final dir = getIt<ResourceSettingsState>().resourceDirectory.value.trim();
      if (dir.isEmpty) return;
      final file = File(p.join(dir, 'proxy_settings.json'));
      await file.parent.create(recursive: true);
      await file.writeAsString(jsonEncode(toJson()), encoding: utf8);
    } catch (e) {
      debugPrint('写入代理设置失败: $e');
    }
  }

  static bool _isLoopback(String host) {
    final h = host.trim().toLowerCase();
    return h == 'localhost' ||
        h == '127.0.0.1' ||
        h == '::1' ||
        h == '[::1]';
  }

  static bool _matchesBypass(String host, List<String> patterns) {
    for (final pattern in patterns) {
      if (_matchOverride(host, pattern)) return true;
    }
    return false;
  }

  static bool _matchOverride(String host, String pattern) {
    final ptn = pattern.trim().toLowerCase();
    final h = host.trim().toLowerCase();
    if (ptn.isEmpty) return false;
    if (ptn == '<local>') return !h.contains('.');
    if (ptn.contains('*')) {
      final re = RegExp(
        '^${RegExp.escape(ptn).replaceAll('\\*', '.*')}\$',
      );
      return re.hasMatch(h);
    }
    return h == ptn;
  }

  static Future<_WindowsIeProxy?> _readWindowsIeProxy() async {
    try {
      final result = await Process.run(
        'reg',
        [
          'query',
          r'HKCU\Software\Microsoft\Windows\CurrentVersion\Internet Settings',
        ],
      );
      if (result.exitCode != 0) return null;
      final stdout = '${result.stdout}';
      final enabled = _regDword(stdout, 'ProxyEnable') == 1;
      if (!enabled) return null;
      final server = _regSz(stdout, 'ProxyServer');
      if (server == null || server.isEmpty) return null;
      final override = _regSz(stdout, 'ProxyOverride') ?? '';
      final picked = _pickWindowsProxyServer(server);
      if (picked == null) return null;
      return _WindowsIeProxy(
        pac: picked.pacDirective,
        url: picked.requestUrl,
        bypass: override
            .split(';')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList(),
      );
    } catch (_) {
      return null;
    }
  }

  static ParsedProxy? _pickWindowsProxyServer(String raw) {
    final text = raw.trim();
    if (text.isEmpty) return null;
    if (!text.contains('=')) {
      return parseProxyUrl(text);
    }
    String? http;
    String? https;
    String? socks;
    for (final part in text.split(';')) {
      final idx = part.indexOf('=');
      if (idx <= 0) continue;
      final key = part.substring(0, idx).trim().toLowerCase();
      final value = part.substring(idx + 1).trim();
      if (value.isEmpty) continue;
      switch (key) {
        case 'http':
          http = value;
        case 'https':
          https = value;
        case 'socks':
          socks = value;
      }
    }
    if (https != null) return parseProxyUrl(https);
    if (http != null) return parseProxyUrl(http);
    if (socks != null) {
      return parseProxyUrl(
        socks.contains('://') ? socks : 'socks5://$socks',
      );
    }
    return null;
  }

  static int? _regDword(String stdout, String name) {
    final match = RegExp(
      '$name\\s+REG_DWORD\\s+0x([0-9a-fA-F]+)',
      caseSensitive: false,
    ).firstMatch(stdout);
    if (match == null) return null;
    return int.tryParse(match.group(1)!, radix: 16);
  }

  static String? _regSz(String stdout, String name) {
    final match = RegExp(
      '$name\\s+REG_SZ\\s+(.+)\$',
      caseSensitive: false,
      multiLine: true,
    ).firstMatch(stdout);
    return match?.group(1)?.trim();
  }

  static bool _listEquals(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

class ParsedProxy {
  const ParsedProxy({
    required this.scheme,
    required this.host,
    required this.port,
    this.user,
    this.password,
  });

  final String scheme;
  final String host;
  final int port;
  final String? user;
  final String? password;

  String get pacDirective {
    if (scheme.startsWith('socks')) return 'SOCKS $host:$port';
    return 'PROXY $host:$port';
  }

  String get requestUrl {
    final auth = (user != null && user!.isNotEmpty)
        ? '${Uri.encodeComponent(user!)}:${Uri.encodeComponent(password ?? '')}@'
        : '';
    return '$scheme://$auth$host:$port';
  }
}

class _WindowsIeProxy {
  const _WindowsIeProxy({
    required this.pac,
    required this.url,
    required this.bypass,
  });

  final String pac;
  final String url;
  final List<String> bypass;
}

class _AmlHttpOverrides extends HttpOverrides {
  @override
  HttpClient createHttpClient(SecurityContext? context) {
    final client = super.createHttpClient(context);
    client.findProxy = ProxyRuntime.findProxyDirective;
    client.authenticateProxy = (host, port, scheme, realm) async {
      final creds = ProxyRuntime.proxyCredentials;
      if (creds == null) return false;
      client.addProxyCredentials(host, port, realm ?? 'proxy', creds);
      return true;
    };
    return client;
  }
}
