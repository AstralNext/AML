import 'package:signals_flutter/signals_flutter.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';

class SelectedWorld {
  const SelectedWorld({
    required this.folder,
    required this.name,
    required this.gameMode,
    required this.hardcore,
    this.lastPlayedMs,
    this.iconPath,
    this.initialTab = 0,
  });

  final String folder;
  final String name;
  final String gameMode;
  final bool hardcore;
  final int? lastPlayedMs;
  final String? iconPath;

  /// `0` = 地图预览, `1` = 备份
  final int initialTab;
}

class NavigationState {
  NavigationState();

  final currentPage = signal('home');
  final selectedInstanceId = signal<String?>(null);
  final selectedWorld = signal<SelectedWorld?>(null);

  /// When set, Discover installs into this instance.
  final browseInstallInstanceId = signal<String?>(null);

  /// Page id to restore when backing out of browse-install (e.g. `library`).
  String? _browseReturnPage;

  /// If true, back from browse-install reopens the target instance detail.
  bool _browseReturnOpenInstance = false;

  /// Tab to restore when leaving Discover entered via browseMods/Modpacks.
  final discoverReturnPage = signal<String?>(null);

  /// Modrinth project id or slug — when set, show project detail overlay.
  final selectedProjectId = signal<String?>(null);

  /// Optional search-card summary for instant detail header.
  final selectedProjectPreview = signal<ProjectPreview?>(null);

  /// Author / organization id — when set (and no project), show author page.
  final selectedAuthorId = signal<String?>(null);

  /// `user` | `organization`
  final selectedAuthorType = signal<String>('user');

  /// Optional summary for instant author header.
  final selectedAuthorPreview = signal<AuthorPreview?>(null);

  /// Project to restore when closing an author page opened from project detail.
  String? _authorReturnProjectId;
  ProjectPreview? _authorReturnProjectPreview;

  /// Project to restore when closing an instance opened from project (e.g. modpack install).
  String? _instanceReturnProjectId;
  ProjectPreview? _instanceReturnProjectPreview;

  void openInstance(String id, {bool returnToProject = false}) {
    if (returnToProject) {
      _instanceReturnProjectId = selectedProjectId.value;
      _instanceReturnProjectPreview = selectedProjectPreview.value;
    } else {
      _instanceReturnProjectId = null;
      _instanceReturnProjectPreview = null;
    }

    _authorReturnProjectId = null;
    _authorReturnProjectPreview = null;
    selectedAuthorId.value = null;
    selectedAuthorPreview.value = null;
    selectedProjectId.value = null;
    selectedProjectPreview.value = null;
    browseInstallInstanceId.value = null;
    _browseReturnOpenInstance = false;
    _browseReturnPage = null;
    selectedWorld.value = null;
    selectedInstanceId.value = id;
  }

  void closeInstance() {
    selectedWorld.value = null;
    selectedInstanceId.value = null;

    final returnId = _instanceReturnProjectId;
    final returnPreview = _instanceReturnProjectPreview;
    _instanceReturnProjectId = null;
    _instanceReturnProjectPreview = null;
    if (returnId != null && returnId.isNotEmpty) {
      selectedProjectPreview.value = returnPreview;
      selectedProjectId.value = returnId;
    }
  }

  void openWorld(SelectedWorld world) {
    selectedWorld.value = world;
  }

  void closeWorld() {
    selectedWorld.value = null;
  }

  void openProject(String projectIdOrSlug, {ProjectPreview? preview}) {
    selectedProjectPreview.value = preview;
    selectedProjectId.value = projectIdOrSlug;
  }

  void closeProject() {
    selectedProjectId.value = null;
    selectedProjectPreview.value = null;
  }

  void openAuthor(
    String authorId, {
    String type = 'user',
    AuthorPreview? preview,
  }) {
    _authorReturnProjectId = selectedProjectId.value;
    _authorReturnProjectPreview = selectedProjectPreview.value;
    selectedProjectId.value = null;
    selectedProjectPreview.value = null;
    selectedAuthorType.value =
        type.toLowerCase() == 'organization' ? 'organization' : 'user';
    selectedAuthorPreview.value = preview;
    selectedAuthorId.value = authorId;
  }

  void closeAuthor() {
    selectedAuthorId.value = null;
    selectedAuthorPreview.value = null;
    final returnId = _authorReturnProjectId;
    final returnPreview = _authorReturnProjectPreview;
    _authorReturnProjectId = null;
    _authorReturnProjectPreview = null;
    if (returnId != null && returnId.isNotEmpty) {
      selectedProjectPreview.value = returnPreview;
      selectedProjectId.value = returnId;
    }
  }

  /// Leave instance detail / library and open Discover filtered for this instance.
  ///
  /// Return target:
  /// - From instance detail → back reopens that instance on the prior tab
  /// - From library (or other tab) → back restores that tab
  void browseContentForInstance(String instanceId) {
    final returnToInstance = selectedInstanceId.value != null;
    final returnPage = currentPage.value;

    _authorReturnProjectId = null;
    _authorReturnProjectPreview = null;
    selectedAuthorId.value = null;
    selectedAuthorPreview.value = null;
    selectedProjectId.value = null;
    selectedProjectPreview.value = null;
    selectedWorld.value = null;
    selectedInstanceId.value = null;
    _instanceReturnProjectId = null;
    _instanceReturnProjectPreview = null;

    // Always keep the underlying tab (library/home/…) so closing the instance
    // later does not strand the user on Discover.
    _browseReturnOpenInstance = returnToInstance;
    _browseReturnPage = returnPage;
    discoverReturnPage.value = null;
    browseInstallInstanceId.value = instanceId;
    discoverFacetHint.value = 'mod';
    currentPage.value = 'discover';
  }

  /// Pop browse-install mode and restore the previous navigation tree.
  void returnFromBrowseContent() {
    final id = browseInstallInstanceId.value;
    final shouldOpenInstance = _browseReturnOpenInstance;
    final page = _browseReturnPage;
    _browseReturnOpenInstance = false;
    _browseReturnPage = null;
    browseInstallInstanceId.value = null;

    if (page != null && page.isNotEmpty) {
      currentPage.value = page;
    }
    if (shouldOpenInstance && id != null && id.isNotEmpty) {
      openInstance(id);
    }
  }

  /// Leave overlays and open Discover on the modpack tab.
  void browseModpacks() {
    _openDiscoverFacet('modpack');
  }

  /// Leave overlays and open Discover on the mod tab.
  void browseMods() {
    _openDiscoverFacet('mod');
  }

  void _openDiscoverFacet(String facet) {
    final returnPage =
        currentPage.value == 'discover' ? discoverReturnPage.value : currentPage.value;

    _authorReturnProjectId = null;
    _authorReturnProjectPreview = null;
    selectedAuthorId.value = null;
    selectedAuthorPreview.value = null;
    selectedProjectId.value = null;
    selectedProjectPreview.value = null;
    selectedWorld.value = null;
    selectedInstanceId.value = null;
    _instanceReturnProjectId = null;
    _instanceReturnProjectPreview = null;
    browseInstallInstanceId.value = null;
    _browseReturnOpenInstance = false;
    _browseReturnPage = null;
    discoverReturnPage.value =
        (returnPage != null && returnPage != 'discover') ? returnPage : null;
    discoverFacetHint.value = facet;
    currentPage.value = 'discover';
  }

  /// Back from Discover entered via browseMods / browseModpacks.
  void returnFromDiscoverBrowse() {
    final page = discoverReturnPage.value;
    discoverReturnPage.value = null;
    discoverFacetHint.value = null;
    if (page != null && page.isNotEmpty) {
      currentPage.value = page;
    }
  }

  /// Optional Discover tab hint: modpack | mod | resourcepack | datapack | shader
  final discoverFacetHint = signal<String?>(null);

  void clearDiscoverFacetHint() {
    discoverFacetHint.value = null;
  }

  void clearBrowseInstall() {
    browseInstallInstanceId.value = null;
    _browseReturnOpenInstance = false;
    _browseReturnPage = null;
  }

  void goToPage(String pageId) {
    // Keep browseInstallInstanceId so "安装到 xxx" context survives
    // sidebar switches (cleared only via clearBrowseInstall / openInstance / etc).
    if (pageId != 'discover') {
      discoverFacetHint.value = null;
      discoverReturnPage.value = null;
    }
    _authorReturnProjectId = null;
    _authorReturnProjectPreview = null;
    selectedAuthorId.value = null;
    selectedAuthorPreview.value = null;
    selectedProjectId.value = null;
    selectedProjectPreview.value = null;
    selectedWorld.value = null;
    selectedInstanceId.value = null;
    _instanceReturnProjectId = null;
    _instanceReturnProjectPreview = null;
    currentPage.value = pageId;
  }

  static String labelForPage(String pageId) {
    switch (pageId) {
      case 'home':
        return '首页';
      case 'library':
        return '库';
      case 'wardrobe':
        return '皮肤库';
      case 'discover':
        return '发现';
      default:
        return '上一页';
    }
  }
}
