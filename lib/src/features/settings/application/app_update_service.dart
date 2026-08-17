import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';

/// GitHub Releases based update checker for AML.
class AppUpdateService {
  AppUpdateService({
    http.Client? client,
    this.owner = 'AstralNext',
    this.repo = 'AML',
  }) : _client = client ?? http.Client();

  static const _userAgent = 'AML-App';
  static const _timeout = Duration(seconds: 12);

  final http.Client _client;
  final String owner;
  final String repo;

  Uri get releasesUri => Uri.https(
        'api.github.com',
        '/repos/$owner/$repo/releases',
        {'per_page': '15'},
      );

  Uri get latestReleaseUri =>
      Uri.https('api.github.com', '/repos/$owner/$repo/releases/latest');

  /// Manual or startup check. Prefer prereleases when current build is a prerelease.
  Future<AppUpdateCheckResult> check({bool? includePrereleases}) async {
    final info = await PackageInfo.fromPlatform();
    final currentRaw = info.version.trim();
    final current = AppVersion.parse(currentRaw);
    final wantPre = includePrereleases ?? current.isPrerelease;

    try {
      final release = await _fetchCandidate(includePrereleases: wantPre);
      if (release == null) {
        return AppUpdateCheckResult.noRelease(currentVersion: currentRaw);
      }

      final latest = AppVersion.parse(release.tagName);
      if (latest.compareTo(current) <= 0) {
        return AppUpdateCheckResult.upToDate(
          currentVersion: currentRaw,
          latestVersion: release.tagName,
        );
      }

      return AppUpdateCheckResult.available(
        AppUpdateInfo(
          currentVersion: currentRaw,
          latestVersion: release.tagName,
          releaseName: release.name.isEmpty ? release.tagName : release.name,
          htmlUrl: release.htmlUrl,
          body: release.body,
          prerelease: release.prerelease,
          publishedAt: release.publishedAt,
          downloadUrl: release.preferredAssetUrl(),
        ),
      );
    } catch (e) {
      return AppUpdateCheckResult.failed(
        currentVersion: currentRaw,
        error: e.toString(),
      );
    }
  }

  Future<_GhRelease?> _fetchCandidate({required bool includePrereleases}) async {
    if (!includePrereleases) {
      final latest = await _getJson(latestReleaseUri);
      if (latest != null) {
        return _GhRelease.fromJson(latest);
      }
    }

    final list = await _getJsonList(releasesUri);
    if (list == null || list.isEmpty) return null;

    for (final item in list) {
      if (item is! Map<String, dynamic>) continue;
      final release = _GhRelease.fromJson(item);
      if (release.draft) continue;
      if (!includePrereleases && release.prerelease) continue;
      return release;
    }
    return null;
  }

  Future<Map<String, dynamic>?> _getJson(Uri uri) async {
    final response = await _client
        .get(uri, headers: _headers())
        .timeout(_timeout);
    if (response.statusCode == 404) return null;
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('GitHub API ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  }

  Future<List<dynamic>?> _getJsonList(Uri uri) async {
    final response = await _client
        .get(uri, headers: _headers())
        .timeout(_timeout);
    if (response.statusCode == 404) return const [];
    if (response.statusCode < 200 || response.statusCode >= 300) {
      throw Exception('GitHub API ${response.statusCode}');
    }
    final decoded = jsonDecode(response.body);
    if (decoded is List) return decoded;
    return null;
  }

  Map<String, String> _headers() => {
        'Accept': 'application/vnd.github+json',
        'User-Agent': '$_userAgent/update-check',
        'X-GitHub-Api-Version': '2022-11-28',
      };
}

enum AppUpdateStatus { upToDate, available, noRelease, failed }

class AppUpdateCheckResult {
  const AppUpdateCheckResult._({
    required this.status,
    required this.currentVersion,
    this.update,
    this.error,
    this.latestVersion,
  });

  factory AppUpdateCheckResult.upToDate({
    required String currentVersion,
    String? latestVersion,
  }) =>
      AppUpdateCheckResult._(
        status: AppUpdateStatus.upToDate,
        currentVersion: currentVersion,
        latestVersion: latestVersion,
      );

  factory AppUpdateCheckResult.available(AppUpdateInfo update) =>
      AppUpdateCheckResult._(
        status: AppUpdateStatus.available,
        currentVersion: update.currentVersion,
        latestVersion: update.latestVersion,
        update: update,
      );

  factory AppUpdateCheckResult.noRelease({required String currentVersion}) =>
      AppUpdateCheckResult._(
        status: AppUpdateStatus.noRelease,
        currentVersion: currentVersion,
      );

  factory AppUpdateCheckResult.failed({
    required String currentVersion,
    required String error,
  }) =>
      AppUpdateCheckResult._(
        status: AppUpdateStatus.failed,
        currentVersion: currentVersion,
        error: error,
      );

  final AppUpdateStatus status;
  final String currentVersion;
  final String? latestVersion;
  final AppUpdateInfo? update;
  final String? error;

  bool get hasUpdate => status == AppUpdateStatus.available && update != null;
}

class AppUpdateInfo {
  const AppUpdateInfo({
    required this.currentVersion,
    required this.latestVersion,
    required this.releaseName,
    required this.htmlUrl,
    required this.prerelease,
    this.body,
    this.publishedAt,
    this.downloadUrl,
  });

  final String currentVersion;
  final String latestVersion;
  final String releaseName;
  final String htmlUrl;
  final String? body;
  final bool prerelease;
  final String? publishedAt;
  final String? downloadUrl;
}

/// SemVer-ish comparer: `1.2.3`, `v0.0.1-beta`, `0.0.1-beta.1`.
class AppVersion implements Comparable<AppVersion> {
  AppVersion(this.numbers, this.prerelease);

  factory AppVersion.parse(String raw) {
    var s = raw.trim();
    if (s.startsWith('v') || s.startsWith('V')) {
      s = s.substring(1);
    }
    final plus = s.indexOf('+');
    if (plus >= 0) s = s.substring(0, plus);

    String core;
    String pre;
    final dash = s.indexOf('-');
    if (dash >= 0) {
      core = s.substring(0, dash);
      pre = s.substring(dash + 1);
    } else {
      core = s;
      pre = '';
    }

    final parts = core.split('.').map((p) => int.tryParse(p) ?? 0).toList();
    while (parts.length < 3) {
      parts.add(0);
    }
    return AppVersion(parts.take(3).toList(growable: false), pre);
  }

  final List<int> numbers;
  final String prerelease;

  bool get isPrerelease => prerelease.isNotEmpty;

  @override
  int compareTo(AppVersion other) {
    for (var i = 0; i < 3; i++) {
      final a = numbers[i];
      final b = other.numbers[i];
      if (a != b) return a.compareTo(b);
    }
    // 正式版 > 预发布
    if (prerelease.isEmpty && other.prerelease.isNotEmpty) return 1;
    if (prerelease.isNotEmpty && other.prerelease.isEmpty) return -1;
    return _comparePre(prerelease, other.prerelease);
  }

  static int _comparePre(String a, String b) {
    if (a == b) return 0;
    final as = a.split('.');
    final bs = b.split('.');
    final n = as.length > bs.length ? as.length : bs.length;
    for (var i = 0; i < n; i++) {
      final x = i < as.length ? as[i] : '';
      final y = i < bs.length ? bs[i] : '';
      final xi = int.tryParse(x);
      final yi = int.tryParse(y);
      if (xi != null && yi != null) {
        if (xi != yi) return xi.compareTo(yi);
      } else {
        final c = x.compareTo(y);
        if (c != 0) return c;
      }
    }
    return 0;
  }

  @override
  String toString() =>
      '${numbers.join('.')}${prerelease.isEmpty ? '' : '-$prerelease'}';
}

class _GhRelease {
  _GhRelease({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.body,
    required this.prerelease,
    required this.draft,
    required this.publishedAt,
    required this.assets,
  });

  factory _GhRelease.fromJson(Map<String, dynamic> json) {
    final assetsRaw = json['assets'];
    final assets = <_GhAsset>[];
    if (assetsRaw is List) {
      for (final a in assetsRaw) {
        if (a is Map<String, dynamic>) {
          assets.add(_GhAsset.fromJson(a));
        }
      }
    }
    return _GhRelease(
      tagName: (json['tag_name'] as String? ?? '').trim(),
      name: (json['name'] as String? ?? '').trim(),
      htmlUrl: (json['html_url'] as String? ?? '').trim(),
      body: json['body'] as String?,
      prerelease: json['prerelease'] as bool? ?? false,
      draft: json['draft'] as bool? ?? false,
      publishedAt: json['published_at'] as String?,
      assets: assets,
    );
  }

  final String tagName;
  final String name;
  final String htmlUrl;
  final String? body;
  final bool prerelease;
  final bool draft;
  final String? publishedAt;
  final List<_GhAsset> assets;

  String? preferredAssetUrl() {
    if (assets.isEmpty) return null;

    int score(String name) {
      final n = name.toLowerCase();
      if (Platform.isLinux) {
        if (n.contains('linux') &&
            (n.endsWith('.tar.gz') ||
                n.endsWith('.tgz') ||
                n.endsWith('.appimage') ||
                n.endsWith('.zip'))) {
          return 50;
        }
      } else if (Platform.isWindows) {
        if (n.contains('windows') || n.contains('win') || n.contains('setup')) {
          if (n.contains('setup') && n.endsWith('.exe')) return 90;
          if (n.endsWith('.exe') || n.endsWith('.msi')) return 80;
          if (n.endsWith('.zip')) return 50;
        }
      } else if (Platform.isMacOS) {
        if ((n.contains('macos') || n.contains('darwin') || n.contains('osx')) &&
            (n.endsWith('.dmg') || n.endsWith('.zip') || n.endsWith('.pkg'))) {
          return 50;
        }
      }
      if (n.endsWith('.tar.gz') || n.endsWith('.zip')) return 10;
      return 0;
    }

    _GhAsset? best;
    var bestScore = -1;
    for (final asset in assets) {
      final s = score(asset.name);
      if (s > bestScore && asset.browserDownloadUrl.isNotEmpty) {
        bestScore = s;
        best = asset;
      }
    }
    return bestScore > 0 ? best?.browserDownloadUrl : null;
  }
}

class _GhAsset {
  _GhAsset({required this.name, required this.browserDownloadUrl});

  factory _GhAsset.fromJson(Map<String, dynamic> json) => _GhAsset(
        name: (json['name'] as String? ?? '').trim(),
        browserDownloadUrl:
            (json['browser_download_url'] as String? ?? '').trim(),
      );

  final String name;
  final String browserDownloadUrl;
}
