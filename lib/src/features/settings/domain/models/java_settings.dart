import 'dart:io';

import 'package:path/path.dart' as p;

class JavaSettings {
  final String java8Path;
  final String java17Path;
  final String java21Path;
  final String java25Path;

  const JavaSettings({
    required this.java8Path,
    required this.java17Path,
    required this.java21Path,
    required this.java25Path,
  });

  factory JavaSettings.defaults() => const JavaSettings(
        java8Path: '',
        java17Path: '',
        java21Path: '',
        java25Path: '',
      );

  JavaSettings copyWith({
    String? java8Path,
    String? java17Path,
    String? java21Path,
    String? java25Path,
  }) {
    return JavaSettings(
      java8Path: java8Path ?? this.java8Path,
      java17Path: java17Path ?? this.java17Path,
      java21Path: java21Path ?? this.java21Path,
      java25Path: java25Path ?? this.java25Path,
    );
  }

  /// Canonical form: absolute path to the `java` console executable.
  static String canonicalizeExecutablePath(String path) {
    final trimmed = path.trim();
    if (trimmed.isEmpty) return '';

    final javaName = Platform.isWindows ? 'java.exe' : 'java';
    final name = p.basename(trimmed).toLowerCase();
    if (name == 'java' || name == 'java.exe') {
      return trimmed;
    }

    // Any file selected under .../bin → use .../bin/java[.exe]
    final parent = p.dirname(trimmed);
    if (p.basename(parent).toLowerCase() == 'bin') {
      final candidate = p.join(parent, javaName);
      if (File(candidate).existsSync()) {
        return candidate;
      }
    }

    // JDK/JRE home → bin/java[.exe]
    final fromHome = p.join(trimmed, 'bin', javaName);
    if (File(fromHome).existsSync()) {
      return fromHome;
    }

    return trimmed;
  }

  /// Map Mojang `javaVersion.majorVersion` to a settings slot.
  static int settingsSlotForMajor(int major) {
    if (major <= 8) return 8;
    if (major <= 17) return 17;
    if (major <= 21) return 21;
    return 25;
  }

  Map<String, dynamic> toJson() => {
        'java8Path': java8Path,
        'java17Path': java17Path,
        'java21Path': java21Path,
        'java25Path': java25Path,
      };

  factory JavaSettings.fromJson(Map<String, dynamic> json) {
    return JavaSettings(
      java8Path: canonicalizeExecutablePath(
        _nonEmpty(json['java8Path'] as String?) ?? '',
      ),
      java17Path: canonicalizeExecutablePath(
        _nonEmpty(json['java17Path'] as String?) ?? '',
      ),
      java21Path: canonicalizeExecutablePath(
        _nonEmpty(json['java21Path'] as String?) ?? '',
      ),
      java25Path: canonicalizeExecutablePath(
        _nonEmpty(json['java25Path'] as String?) ?? '',
      ),
    );
  }
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
