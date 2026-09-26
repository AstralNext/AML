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

/// 按发布时间降序排列（最新在前），原地排序并返回同一列表。
///
/// Modrinth 官方接口默认如此，但 CurseForge 官方接口默认按游戏版本排序、
/// MCIM 镜像顺序也不稳定，因此所有来源在进入 UI / 安装流程前统一排序。
List<ModrinthVersionInfo> sortVersionsNewestFirst(
  List<ModrinthVersionInfo> versions,
) {
  versions.sort((a, b) {
    final da = DateTime.tryParse(a.datePublished);
    final db = DateTime.tryParse(b.datePublished);
    if (da != null && db != null) return db.compareTo(da);
    return b.datePublished.compareTo(a.datePublished);
  });
  return versions;
}

/// 安装默认版本：最新正式版 → 最新 Beta → 最新 Alpha。
/// 列表应已按发布时间降序排列；都不匹配时回退到列表第一个。
ModrinthVersionInfo? pickPreferredVersion(
  List<ModrinthVersionInfo> versions,
) {
  if (versions.isEmpty) return null;
  for (final channel in const ['release', 'beta', 'alpha']) {
    for (final v in versions) {
      if (v.versionType.toLowerCase() == channel) return v;
    }
  }
  return versions.first;
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
