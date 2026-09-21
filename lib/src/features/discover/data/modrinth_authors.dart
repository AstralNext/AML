import 'modrinth_models.dart';

/// User or organization profile for the author detail page.
class ModrinthAuthor {
  final String id;
  /// Username (user) or slug (organization).
  final String username;
  final String displayName;
  final String bio;
  final String? avatarUrl;
  /// `user` | `organization`
  final String type;

  const ModrinthAuthor({
    required this.id,
    required this.username,
    required this.displayName,
    required this.bio,
    this.avatarUrl,
    required this.type,
  });

  factory ModrinthAuthor.fromUserJson(Map<String, dynamic> json) {
    final username = json['username']?.toString() ?? '';
    final name = json['name']?.toString();
    return ModrinthAuthor(
      id: json['id']?.toString() ?? '',
      username: username,
      displayName: (name != null && name.trim().isNotEmpty) ? name : username,
      bio: json['bio']?.toString() ?? '',
      avatarUrl: json['avatar_url']?.toString(),
      type: 'user',
    );
  }

  factory ModrinthAuthor.fromOrgJson(Map<String, dynamic> json) {
    final slug = json['slug']?.toString() ?? '';
    final name = json['name']?.toString();
    return ModrinthAuthor(
      id: json['id']?.toString() ?? '',
      username: slug,
      displayName: (name != null && name.trim().isNotEmpty) ? name : slug,
      bio: json['description']?.toString() ?? '',
      avatarUrl: json['icon_url']?.toString(),
      type: 'organization',
    );
  }
}

/// Lightweight project row on an author page (user/org projects list).
class ModrinthAuthorProject {
  final String id;
  final String slug;
  final String title;
  final String description;
  final String? iconUrl;
  final int downloads;
  final int followers;
  final String projectType;
  final String clientSide;
  final String serverSide;
  final List<String> categories;
  final String published;
  final String updated;

  const ModrinthAuthorProject({
    required this.id,
    required this.slug,
    required this.title,
    required this.description,
    this.iconUrl,
    required this.downloads,
    required this.followers,
    required this.projectType,
    required this.clientSide,
    required this.serverSide,
    required this.categories,
    required this.published,
    required this.updated,
  });

  factory ModrinthAuthorProject.fromJson(Map<String, dynamic> json) {
    return ModrinthAuthorProject(
      id: json['id']?.toString() ?? json['project_id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      iconUrl: json['icon_url']?.toString(),
      downloads: json['downloads'] as int? ?? 0,
      followers: json['followers'] as int? ?? json['follows'] as int? ?? 0,
      projectType: json['project_type']?.toString() ?? '',
      clientSide: json['client_side']?.toString() ?? 'unknown',
      serverSide: json['server_side']?.toString() ?? 'unknown',
      categories: List<String>.from(json['categories'] ?? const []),
      published: json['published']?.toString() ??
          json['date_created']?.toString() ??
          '',
      updated:
          json['updated']?.toString() ?? json['date_modified']?.toString() ?? '',
    );
  }

  ProjectPreview toPreview() => ProjectPreview(
        id: id,
        slug: slug,
        title: title,
        description: description,
        iconUrl: iconUrl,
        downloads: downloads,
        followers: followers,
        projectType: projectType,
        clientSide: clientSide,
        serverSide: serverSide,
        categories: categories,
      );
}

/// Instant header while author profile loads.
class AuthorPreview {
  final String id;
  final String type;
  final String displayName;
  final String? avatarUrl;

  const AuthorPreview({
    required this.id,
    required this.type,
    required this.displayName,
    this.avatarUrl,
  });
}
