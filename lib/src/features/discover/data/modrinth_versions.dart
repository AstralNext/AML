class ModrinthVersionInfo {
  final String id;
  final String projectId;
  final String name;
  final String versionNumber;
  final String changelog;
  final List<String> gameVersions;
  final List<String> loaders;
  final String datePublished;
  final int downloads;
  final String versionType;
  final List<ModrinthVersionFile> files;

  const ModrinthVersionInfo({
    required this.id,
    required this.projectId,
    required this.name,
    required this.versionNumber,
    required this.changelog,
    required this.gameVersions,
    required this.loaders,
    required this.datePublished,
    required this.downloads,
    required this.versionType,
    required this.files,
  });

  factory ModrinthVersionInfo.fromJson(Map<String, dynamic> json) {
    return ModrinthVersionInfo(
      id: json['id']?.toString() ?? '',
      projectId: json['project_id']?.toString() ?? '',
      name: json['name']?.toString() ?? '',
      versionNumber: json['version_number']?.toString() ?? '',
      changelog: json['changelog']?.toString() ?? '',
      gameVersions: List<String>.from(json['game_versions'] ?? const []),
      loaders: List<String>.from(json['loaders'] ?? const []),
      datePublished: json['date_published']?.toString() ?? '',
      downloads: json['downloads'] as int? ?? 0,
      versionType: json['version_type']?.toString() ?? 'release',
      files: (json['files'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ModrinthVersionFile.fromJson)
          .toList(),
    );
  }

  String? get primaryFileName {
    for (final f in files) {
      if (f.primary) return f.filename;
    }
    return files.isEmpty ? null : files.first.filename;
  }
}

class ModrinthVersionFile {
  final String url;
  final String filename;
  final bool primary;
  final int size;

  const ModrinthVersionFile({
    required this.url,
    required this.filename,
    required this.primary,
    required this.size,
  });

  factory ModrinthVersionFile.fromJson(Map<String, dynamic> json) {
    return ModrinthVersionFile(
      url: json['url']?.toString() ?? '',
      filename: json['filename']?.toString() ?? '',
      primary: json['primary'] == true,
      size: json['size'] as int? ?? 0,
    );
  }
}
