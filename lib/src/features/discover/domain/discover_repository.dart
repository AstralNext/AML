abstract class DiscoverRepository {
  /// Search projects by query and page. Returns a SearchResult containing projects and total hits.
  ///
  /// [onLocalized] is invoked when background network translation finishes and
  /// may replace titles/descriptions; callers should ignore stale generations.
  Future<SearchResult> searchProjects({
    required String query,
    int page = 0,
    int pageSize = 20,
    String? index,
    List<List<String>>? facets,
    void Function(SearchResult localized)? onLocalized,
  });
}

class SearchResult {
  final List<Project> projects;
  final int totalHits;

  SearchResult({
    required this.projects,
    required this.totalHits,
  });
}

class Project {
  final String id;
  final String title;
  final String description;
  final String author;
  final int downloads;
  final int followers;
  final String? iconUrl;
  final String projectType;
  final String clientSide;
  final String serverSide;
  final String? latestVersion;
  final List<String> categories;
  final List<String>? displayCategories;
  /// Supported Minecraft versions from search hits (`versions`).
  final List<String> gameVersions;
  final String dateCreated;
  final String dateModified;

  Project({
    required this.id,
    required this.title,
    required this.description,
    required this.author,
    this.downloads = 0,
    this.followers = 0,
    this.iconUrl,
    this.projectType = '',
    this.clientSide = 'unknown',
    this.serverSide = 'unknown',
    this.latestVersion,
    this.categories = const [],
    this.displayCategories,
    this.gameVersions = const [],
    this.dateCreated = '',
    this.dateModified = '',
  });

  Project copyWith({
    String? id,
    String? title,
    String? description,
    String? author,
    int? downloads,
    int? followers,
    String? iconUrl,
    String? projectType,
    String? clientSide,
    String? serverSide,
    String? latestVersion,
    List<String>? categories,
    List<String>? displayCategories,
    List<String>? gameVersions,
    String? dateCreated,
    String? dateModified,
  }) {
    return Project(
      id: id ?? this.id,
      title: title ?? this.title,
      description: description ?? this.description,
      author: author ?? this.author,
      downloads: downloads ?? this.downloads,
      followers: followers ?? this.followers,
      iconUrl: iconUrl ?? this.iconUrl,
      projectType: projectType ?? this.projectType,
      clientSide: clientSide ?? this.clientSide,
      serverSide: serverSide ?? this.serverSide,
      latestVersion: latestVersion ?? this.latestVersion,
      categories: categories ?? this.categories,
      displayCategories: displayCategories ?? this.displayCategories,
      gameVersions: gameVersions ?? this.gameVersions,
      dateCreated: dateCreated ?? this.dateCreated,
      dateModified: dateModified ?? this.dateModified,
    );
  }
}
