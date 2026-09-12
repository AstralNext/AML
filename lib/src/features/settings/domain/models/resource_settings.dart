import 'package:path/path.dart' as p;

class ResourceSettings {
  final String resourceDirectory;

  const ResourceSettings({required this.resourceDirectory});

  factory ResourceSettings.defaults(String baseDir) => ResourceSettings(
        resourceDirectory: p.join(baseDir, 'resourceDirectory'),
      );

  ResourceSettings copyWith({String? resourceDirectory}) {
    return ResourceSettings(
      resourceDirectory: resourceDirectory ?? this.resourceDirectory,
    );
  }

  Map<String, dynamic> toJson() => {
        'resourceDirectory': resourceDirectory,
      };

  factory ResourceSettings.fromJson(
    Map<String, dynamic> json, {
    required String baseDir,
  }) {
    return ResourceSettings(
      resourceDirectory: _nonEmpty(json['resourceDirectory'] as String?) ??
          p.join(baseDir, 'resourceDirectory'),
    );
  }
}

String? _nonEmpty(String? value) {
  if (value == null) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
