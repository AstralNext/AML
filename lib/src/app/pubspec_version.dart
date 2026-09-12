import 'dart:io';

import 'package:path/path.dart' as p;

/// Mirrors [pubspec.yaml] `version:`. The test `pubspec_version_test` fails if
/// this drifts; `PubspecVersion.load()` also re-reads the project file when
/// running from a source / build tree.
const String kPubspecVersionRaw = '1.0.1';

/// App version from pubspec.yaml, not Windows exe FileVersion (that fallback
/// is hardcoded to 1.0.0 in Runner.rc and is why the settings card was wrong).
class PubspecVersion {
  const PubspecVersion({
    required this.version,
    required this.buildNumber,
    required this.raw,
  });

  /// Semver before `+`, e.g. `1.0.0` or `1.0.0-beta.1`.
  final String version;

  /// Optional build after `+`.
  final String buildNumber;

  /// Full `version:` value from pubspec.
  final String raw;

  static final PubspecVersion baked = parseRaw(kPubspecVersionRaw);

  String get display {
    if (version.isEmpty) return '';
    if (buildNumber.isEmpty) return version;
    return '$version ($buildNumber)';
  }

  static PubspecVersion? _cache;
  static Future<PubspecVersion>? _pending;

  static Future<PubspecVersion> load() {
    if (_cache != null) return Future.value(_cache);
    return _pending ??= _load().whenComplete(() => _pending = null);
  }

  static Future<PubspecVersion> _load() async {
    final fromDisk = await _readProjectPubspec();
    if (fromDisk != null) {
      _cache = parseYaml(fromDisk);
      return _cache!;
    }
    _cache = baked;
    return _cache!;
  }

  static PubspecVersion parseRaw(String raw) {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) {
      return const PubspecVersion(version: '', buildNumber: '', raw: '');
    }
    final plus = trimmed.indexOf('+');
    if (plus < 0) {
      return PubspecVersion(version: trimmed, buildNumber: '', raw: trimmed);
    }
    return PubspecVersion(
      version: trimmed.substring(0, plus),
      buildNumber: trimmed.substring(plus + 1),
      raw: trimmed,
    );
  }

  static PubspecVersion parseYaml(String pubspec) {
    final match = RegExp(
      r'^version:\s*(\S+)',
      multiLine: true,
    ).firstMatch(pubspec);
    return parseRaw(match?.group(1) ?? '');
  }

  static Future<String?> _readProjectPubspec() async {
    final seen = <String>{};
    final starts = <Directory>[
      Directory.current,
      File(Platform.resolvedExecutable).parent,
    ];
    for (final start in starts) {
      var dir = start;
      for (var i = 0; i < 10; i++) {
        if (!seen.add(dir.path)) break;
        final file = File(p.join(dir.path, 'pubspec.yaml'));
        if (await file.exists()) {
          try {
            final text = await file.readAsString();
            final isAml = RegExp(r'^name:\s*aml\s*$', multiLine: true)
                .hasMatch(text.replaceAll('\r', ''));
            if (isAml) return text;
          } catch (_) {}
        }
        final parent = dir.parent;
        if (parent.path == dir.path) break;
        dir = parent;
      }
    }
    return null;
  }
}
