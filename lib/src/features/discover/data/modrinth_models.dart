class ModrinthSearchResult {
  final List<ModrinthProject> hits;
  final int offset;
  final int limit;
  final int totalHits;

  ModrinthSearchResult({
    required this.hits,
    required this.offset,
    required this.limit,
    required this.totalHits,
  });

  factory ModrinthSearchResult.fromJson(Map<String, dynamic> json) {
    return ModrinthSearchResult(
      hits: (json['hits'] as List)
          .map((item) => ModrinthProject.fromJson(item))
          .toList(),
      offset: json['offset'] ?? 0,
      limit: json['limit'] ?? 10,
      totalHits: json['total_hits'] ?? 0,
    );
  }
}

class ModrinthProject {
  final String slug;
  final String title;
  final String description;
  final List<String> categories;
  final String clientSide;
  final String serverSide;
  final String projectType;
  final int downloads;
  final String? iconUrl;
  final int? color;
  final String? threadId;
  final String? monetizationStatus;
  final String projectId;
  final String author;
  final List<String>? displayCategories;
  final List<String> versions;
  final int follows;
  final String dateCreated;
  final String dateModified;
  final String? latestVersion;
  final String license;
  final List<String>? gallery;
  final String? featuredGallery;

  ModrinthProject({
    required this.slug,
    required this.title,
    required this.description,
    required this.categories,
    required this.clientSide,
    required this.serverSide,
    required this.projectType,
    required this.downloads,
    this.iconUrl,
    this.color,
    this.threadId,
    this.monetizationStatus,
    required this.projectId,
    required this.author,
    this.displayCategories,
    required this.versions,
    required this.follows,
    required this.dateCreated,
    required this.dateModified,
    this.latestVersion,
    required this.license,
    this.gallery,
    this.featuredGallery,
  });

  factory ModrinthProject.fromJson(Map<String, dynamic> json) {
    return ModrinthProject(
      slug: json['slug'] ?? '',
      title: json['title'] ?? '',
      description: json['description'] ?? '',
      categories: List<String>.from(json['categories'] ?? []),
      clientSide: json['client_side'] ?? 'unknown',
      serverSide: json['server_side'] ?? 'unknown',
      projectType: json['project_type'] ?? '',
      downloads: json['downloads'] ?? 0,
      iconUrl: json['icon_url'],
      color: json['color'],
      threadId: json['thread_id'],
      monetizationStatus: json['monetization_status'],
      projectId: json['project_id'] ?? '',
      author: json['author'] ?? '',
      displayCategories: json['display_categories'] != null
          ? List<String>.from(json['display_categories'])
          : null,
      versions: List<String>.from(json['versions'] ?? []),
      follows: json['follows'] ?? 0,
      dateCreated: json['date_created'] ?? '',
      dateModified: json['date_modified'] ?? '',
      latestVersion: json['latest_version'],
      license: json['license'] ?? '',
      gallery:
          json['gallery'] != null ? List<String>.from(json['gallery']) : null,
      featuredGallery: json['featured_gallery'],
    );
  }

  ModrinthProject copyWith({String? title, String? description}) {
    return ModrinthProject(
      slug: slug,
      title: title ?? this.title,
      description: description ?? this.description,
      categories: categories,
      clientSide: clientSide,
      serverSide: serverSide,
      projectType: projectType,
      downloads: downloads,
      iconUrl: iconUrl,
      color: color,
      threadId: threadId,
      monetizationStatus: monetizationStatus,
      projectId: projectId,
      author: author,
      displayCategories: displayCategories,
      versions: versions,
      follows: follows,
      dateCreated: dateCreated,
      dateModified: dateModified,
      latestVersion: latestVersion,
      license: license,
      gallery: gallery,
      featuredGallery: featuredGallery,
    );
  }
}

class ModrinthProjectDetail {
  final String id;
  final String slug;
  final String title;
  final String description;
  final String body;
  /// Original (pre-translation) fields when [title]/[description]/[body] are localized.
  final String? sourceTitle;
  final String? sourceDescription;
  final String? sourceBody;
  final List<String> categories;
  final String clientSide;
  final String serverSide;
  final String projectType;
  final int downloads;
  final int followers;
  final String? iconUrl;
  final List<String> gameVersions;
  final List<String> loaders;
  final String published;
  final String updated;
  final List<ModrinthGalleryImage> gallery;
  final String licenseId;
  final String licenseName;
  final String? organizationId;
  final String? teamId;

  const ModrinthProjectDetail({
    required this.id,
    required this.slug,
    required this.title,
    required this.description,
    required this.body,
    this.sourceTitle,
    this.sourceDescription,
    this.sourceBody,
    required this.categories,
    required this.clientSide,
    required this.serverSide,
    required this.projectType,
    required this.downloads,
    required this.followers,
    this.iconUrl,
    required this.gameVersions,
    required this.loaders,
    required this.published,
    required this.updated,
    required this.gallery,
    required this.licenseId,
    required this.licenseName,
    this.organizationId,
    this.teamId,
  });

  /// True when at least one field differs from its preserved source text.
  bool get hasTranslation {
    final srcTitle = sourceTitle?.trim();
    final srcDesc = sourceDescription?.trim();
    final srcBody = sourceBody?.trim();
    if (srcTitle != null &&
        srcTitle.isNotEmpty &&
        srcTitle != title.trim()) {
      return true;
    }
    if (srcDesc != null &&
        srcDesc.isNotEmpty &&
        srcDesc != description.trim()) {
      return true;
    }
    if (srcBody != null && srcBody.isNotEmpty && srcBody != body.trim()) {
      return true;
    }
    return false;
  }

  String displayTitle({required bool original}) =>
      original ? (sourceTitle ?? title) : title;

  String displayDescription({required bool original}) =>
      original ? (sourceDescription ?? description) : description;

  String displayBody({required bool original}) {
    if (original) {
      final src = sourceBody?.trim();
      if (src != null && src.isNotEmpty) return src;
      final srcDesc = sourceDescription?.trim();
      if (srcDesc != null && srcDesc.isNotEmpty) return srcDesc;
    }
    return body.isNotEmpty ? body : description;
  }

  factory ModrinthProjectDetail.fromJson(Map<String, dynamic> json) {
    final license = json['license'];
    String licenseId = '';
    String licenseName = '';
    if (license is Map<String, dynamic>) {
      licenseId = license['id']?.toString() ?? '';
      licenseName = license['name']?.toString() ?? licenseId;
    } else if (license is String) {
      licenseId = license;
      licenseName = license;
    }
    return ModrinthProjectDetail(
      id: json['id']?.toString() ?? '',
      slug: json['slug']?.toString() ?? '',
      title: json['title']?.toString() ?? '',
      description: json['description']?.toString() ?? '',
      body: json['body']?.toString() ?? '',
      categories: List<String>.from(json['categories'] ?? const []),
      clientSide: json['client_side']?.toString() ?? 'unknown',
      serverSide: json['server_side']?.toString() ?? 'unknown',
      projectType: json['project_type']?.toString() ?? '',
      downloads: json['downloads'] as int? ?? 0,
      followers: json['followers'] as int? ?? 0,
      iconUrl: json['icon_url']?.toString(),
      gameVersions: List<String>.from(json['game_versions'] ?? const []),
      loaders: List<String>.from(json['loaders'] ?? const []),
      published: json['published']?.toString() ?? '',
      updated: json['updated']?.toString() ?? '',
      gallery: (json['gallery'] as List<dynamic>? ?? const [])
          .whereType<Map<String, dynamic>>()
          .map(ModrinthGalleryImage.fromJson)
          .toList(),
      licenseId: licenseId,
      licenseName: licenseName,
      organizationId: json['organization']?.toString(),
      teamId: json['team']?.toString(),
    );
  }

  ModrinthProjectDetail copyWith({
    String? title,
    String? description,
    String? body,
    String? sourceTitle,
    String? sourceDescription,
    String? sourceBody,
    bool clearSources = false,
  }) {
    return ModrinthProjectDetail(
      id: id,
      slug: slug,
      title: title ?? this.title,
      description: description ?? this.description,
      body: body ?? this.body,
      sourceTitle: clearSources ? null : (sourceTitle ?? this.sourceTitle),
      sourceDescription:
          clearSources ? null : (sourceDescription ?? this.sourceDescription),
      sourceBody: clearSources ? null : (sourceBody ?? this.sourceBody),
      categories: categories,
      clientSide: clientSide,
      serverSide: serverSide,
      projectType: projectType,
      downloads: downloads,
      followers: followers,
      iconUrl: iconUrl,
      gameVersions: gameVersions,
      loaders: loaders,
      published: published,
      updated: updated,
      gallery: gallery,
      licenseId: licenseId,
      licenseName: licenseName,
      organizationId: organizationId,
      teamId: teamId,
    );
  }
}

/// Lightweight project summary passed into detail for instant header paint.
class ProjectPreview {
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
  final List<String>? displayCategories;

  const ProjectPreview({
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
    this.displayCategories,
  });

  factory ProjectPreview.fromSearch(ModrinthProject project) {
    return ProjectPreview(
      id: project.projectId,
      slug: project.slug,
      title: project.title,
      description: project.description,
      iconUrl: project.iconUrl,
      downloads: project.downloads,
      followers: project.follows,
      projectType: project.projectType,
      clientSide: project.clientSide,
      serverSide: project.serverSide,
      categories: project.categories,
      displayCategories: project.displayCategories,
    );
  }

  factory ProjectPreview.fromProject({
    required String id,
    required String title,
    required String description,
    String? iconUrl,
    int downloads = 0,
    int followers = 0,
    String projectType = '',
    String clientSide = 'unknown',
    String serverSide = 'unknown',
    List<String> categories = const [],
    List<String>? displayCategories,
    String slug = '',
  }) {
    return ProjectPreview(
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
      displayCategories: displayCategories,
    );
  }

  factory ProjectPreview.fromDetail(ModrinthProjectDetail project) {
    return ProjectPreview(
      id: project.id,
      slug: project.slug,
      title: project.title,
      description: project.description,
      iconUrl: project.iconUrl,
      downloads: project.downloads,
      followers: project.followers,
      projectType: project.projectType,
      clientSide: project.clientSide,
      serverSide: project.serverSide,
      categories: project.categories,
    );
  }
}

class ModrinthGalleryImage {
  final String url;
  final String? title;
  final bool featured;

  const ModrinthGalleryImage({
    required this.url,
    this.title,
    this.featured = false,
  });

  factory ModrinthGalleryImage.fromJson(Map<String, dynamic> json) {
    return ModrinthGalleryImage(
      url: json['url']?.toString() ?? '',
      title: json['title']?.toString(),
      featured: json['featured'] == true,
    );
  }
}
