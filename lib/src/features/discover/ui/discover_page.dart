import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/discover/application/discover_controller.dart';
import 'package:aml/src/features/discover/data/curseforge_repository.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/data/modrinth_repository.dart';
import 'package:aml/src/features/discover/domain/discover_repository.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/features/discover/ui/project_environment.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/cards/app_card.dart';
import 'package:aml/src/shared/widgets/components/common/pagination_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/filter_multi_select.dart';
import 'package:aml/src/shared/widgets/components/inputs/search_bar.dart';
import 'package:aml/src/shared/widgets/components/tabs/animated_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

enum DiscoverSource { modrinth, curseforge }

class DiscoverPage extends StatefulWidget {
  const DiscoverPage({super.key});

  @override
  State<DiscoverPage> createState() => _DiscoverPageState();
}

class _DiscoverPageState extends State<DiscoverPage> {
  DiscoverSource _source = DiscoverSource.modrinth;
  int _selectedTabIndex = 1;
  String _selectedSortValue = 'relevance';
  int _selectedPageSize = 20;
  final List<int> _currentPages = [1, 1, 1, 1, 1];
  int get _currentPage => _currentPages[_selectedTabIndex];
  String? _installingProjectId;
  final Set<String> _selectedEnvironments = {};
  final Set<String> _selectedLoaders = {};
  final Set<String> _selectedCategories = {};
  final Set<String> _selectedGameVersions = {};
  final List<rust.GameVersionDto> _gameVersions = [];
  bool _showAllGameVersions = false;
  /// projectId → installed versionId (from instance_content).
  final Map<String, String> _installedVersions = {};

  final List<String> _tabs = ['整合包', '模组', '资源包', '数据包', '着色器'];
  final List<String> _tabsFacets = [
    'modpack',
    'mod',
    'resourcepack',
    'datapack',
    'shader',
  ];

  String get _currentProjectType => _tabsFacets[_selectedTabIndex];

  bool get _isCurseForge => _source == DiscoverSource.curseforge;

  bool get _showEnvironmentFilter {
    if (_isCurseForge) return false;
    final t = _currentProjectType;
    return t == 'mod' || t == 'modpack';
  }

  bool get _showCategoryFilter => !_isCurseForge;

  List<String> get _availableLoaders => loadersForProjectType(_currentProjectType);
  List<String> get _availableCategories =>
      categoriesForProjectType(_currentProjectType);

  List<String> get _availableGameVersionIds {
    if (_showAllGameVersions) {
      return _gameVersions.map((v) => v.id).toList();
    }
    final releases = _gameVersions
        .where((v) => v.type == 'release')
        .map((v) => v.id)
        .toList();
    return releases.isEmpty
        ? _gameVersions.map((v) => v.id).toList()
        : releases;
  }

  bool _isSelectableReleaseVersion(String id) {
    for (final v in _gameVersions) {
      if (v.id == id) return v.type == 'release';
    }
    return isReleaseGameVersion(id);
  }

  String searchName = '';
  late DiscoverController _controller;
  late final NavigationState _nav = getIt<NavigationState>();
  String? _lastBrowseInstanceId;
  String? _lastFacetHint;
  Timer? _searchDebounce;

  DiscoverRepository _repoFor(DiscoverSource source) {
    return source == DiscoverSource.curseforge
        ? CurseForgeRepository()
        : ModrinthRepository();
  }

  void _switchSource(DiscoverSource source) {
    if (source == _source) return;
    setState(() {
      _source = source;
      _selectedCategories.clear();
      _selectedEnvironments.clear();
      if (_isCurseForge &&
          (_selectedSortValue == 'follows' ||
              _selectedPageSize > 50)) {
        if (_selectedSortValue == 'follows') {
          _selectedSortValue = 'relevance';
        }
        if (_selectedPageSize > 50) {
          _selectedPageSize = 50;
        }
      }
      _controller = DiscoverController(_repoFor(source));
    });
    _searchProjects(page: 0);
  }

  rust.InstanceDto? _instanceById(String? id) {
    if (id == null) return null;
    for (final i in getIt<InstanceStore>().instances.value) {
      if (i.id == id) return i;
    }
    return null;
  }

  /// Pre-select loader + game version to match the install target instance.
  void _applyBrowseInstanceFilters(rust.InstanceDto instance) {
    _selectedGameVersions
      ..clear()
      ..add(instance.gameVersion);
    if (!_isSelectableReleaseVersion(instance.gameVersion)) {
      _showAllGameVersions = true;
    }

    _selectedLoaders.clear();
    final loader = instance.loader.toLowerCase().trim();
    if (loader.isNotEmpty &&
        loader != 'vanilla' &&
        _availableLoaders.contains(loader)) {
      _selectedLoaders.add(loader);
    }
  }

  void _searchProjects({int page = 0, bool debounce = false}) {
    if (!debounce) {
      _searchDebounce?.cancel();
      _searchDebounce = null;
      _runSearch(page: page);
      return;
    }
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 300), () {
      _searchDebounce = null;
      if (!mounted) return;
      _runSearch(page: page);
    });
  }

  void _runSearch({int page = 0}) {
    final currentFacet = _currentProjectType;
    final facets = <List<String>>[
      ['project_type:$currentFacet'],
    ];

    if (_selectedLoaders.isNotEmpty) {
      facets.add(
        _selectedLoaders.map((l) => 'categories:$l').toList(),
      );
    }
    if (_selectedGameVersions.isNotEmpty) {
      facets.add(
        _selectedGameVersions.map((v) => 'versions:$v').toList(),
      );
    }

    if (!_isCurseForge && _selectedCategories.isNotEmpty) {
      facets.add(
        _selectedCategories.map((c) => 'categories:$c').toList(),
      );
    }

    if (_showEnvironmentFilter) {
      facets.addAll(
        environmentFacets(
          client: _selectedEnvironments.contains('client'),
          server: _selectedEnvironments.contains('server'),
        ),
      );
    }

    _controller.search(
      searchName,
      pageIndex: page,
      pageSize: _selectedPageSize,
      index: _selectedSortValue,
      facets: facets,
    );
  }

  @override
  void initState() {
    super.initState();
    _controller = DiscoverController(_repoFor(_source));
    // Shell lazy-builds this tab on first visit — safe to load immediately.
    _searchProjects(page: _currentPage - 1);
    _refreshInstalled(_nav.browseInstallInstanceId.value);
    unawaited(_loadGameVersions());
  }

  @override
  void dispose() {
    _searchDebounce?.cancel();
    super.dispose();
  }

  Future<void> _loadGameVersions() async {
    try {
      final versions = await rust.listMinecraftVersions();
      if (!mounted) return;
      setState(() {
        _gameVersions
          ..clear()
          ..addAll(versions);
        // Snapshot / non-release target must appear in the version dropdown.
        final browse = _instanceById(_nav.browseInstallInstanceId.value);
        if (browse != null &&
            !_isSelectableReleaseVersion(browse.gameVersion)) {
          _showAllGameVersions = true;
        }
      });
    } catch (_) {}
  }

  Future<void> _refreshInstalled(String? instanceId) async {
    if (instanceId == null) {
      if (_installedVersions.isNotEmpty) {
        setState(() => _installedVersions.clear());
      }
      return;
    }
    try {
      final mods = await rust.listInstanceMods(instanceId: instanceId);
      final map = <String, String>{};
      for (final m in mods) {
        final pid = m.projectId;
        final vid = m.versionId;
        if (pid != null && pid.isNotEmpty && vid != null && vid.isNotEmpty) {
          map[pid] = vid;
        }
      }
      if (!mounted) return;
      setState(() {
        _installedVersions
          ..clear()
          ..addAll(map);
      });
    } catch (_) {}
  }

  /// Button state from DB version vs search `latest_version`.
  ///
  /// If installed but absolute latest differs, show 「更新」. Clicking update
  /// resolves the newest *compatible* version; if already on that, we toast
  /// and keep 「已安装」 via [_compatCurrent].
  final Set<String> _compatCurrent = {};

  ({String label, bool disabled}) _installState(Project project) {
    final installedVid = _installedVersions[project.id];
    if (installedVid == null) {
      return (
        label: _nav.browseInstallInstanceId.value != null ? '安装到实例' : '安装',
        disabled: false,
      );
    }
    if (_compatCurrent.contains(project.id)) {
      return (label: '已安装', disabled: true);
    }
    final latest = project.latestVersion;
    if (latest != null && latest.isNotEmpty && latest != installedVid) {
      return (label: '更新', disabled: false);
    }
    return (label: '已安装', disabled: true);
  }

  Future<void> _install(Project project) async {
    final wasInstalled = _installedVersions.containsKey(project.id);
    final currentVid = _installedVersions[project.id];
    setState(() => _installingProjectId = project.id);
    try {
      await ContentInstallHelper.installProject(
        context: context,
        projectId: project.id,
        title: project.title,
        projectType: project.projectType.isNotEmpty
            ? project.projectType
            : _tabsFacets[_selectedTabIndex],
        preferredInstanceId: _nav.browseInstallInstanceId.value,
        latestVersionHint: project.latestVersion,
        projectIconUrl: project.iconUrl,
        asUpdate: wasInstalled,
        currentVersionId: currentVid,
      );
      await _refreshInstalled(_nav.browseInstallInstanceId.value);
      // After refresh: if still on same version as before attempt while
      // latest differs, mark as compat-current so button becomes 已安装.
      final nowVid = _installedVersions[project.id];
      if (nowVid != null &&
          project.latestVersion != null &&
          nowVid != project.latestVersion &&
          (currentVid == null || currentVid == nowVid)) {
        setState(() => _compatCurrent.add(project.id));
      } else if (nowVid != null && nowVid == project.latestVersion) {
        setState(() => _compatCurrent.remove(project.id));
      }
    } finally {
      if (mounted) setState(() => _installingProjectId = null);
    }
  }

  String _filterLabel(String name, Set<String> selected) {
    if (selected.isEmpty) return name;
    return '$name (${selected.length})';
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = context.tokens;
    final browseId = _nav.browseInstallInstanceId.watch(context);
    final facetHint = _nav.discoverFacetHint.watch(context);
    final discoverReturnPage = _nav.discoverReturnPage.watch(context);

    var needSearchAfterHint = false;
    if (facetHint == null) {
      _lastFacetHint = null;
    } else if (facetHint != _lastFacetHint) {
      final idx = _tabsFacets.indexOf(facetHint);
      if (idx >= 0) {
        _selectedTabIndex = idx;
        _selectedCategories.clear();
        _selectedEnvironments.clear();
        // Keep loader/version when jumping from an instance; otherwise reset.
        if (browseId == null) {
          _selectedLoaders.clear();
          _selectedGameVersions.clear();
        }
      }
      _lastFacetHint = facetHint;
      needSearchAfterHint = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _nav.clearDiscoverFacetHint();
        if (browseId == null) _searchProjects();
      });
    }

    if (browseId != _lastBrowseInstanceId) {
      final leavingBrowse = _lastBrowseInstanceId != null && browseId == null;
      _lastBrowseInstanceId = browseId;
      _compatCurrent.clear();
      if (browseId != null) {
        final instance = _instanceById(browseId);
        if (instance != null) {
          _applyBrowseInstanceFilters(instance);
        }
      } else if (leavingBrowse) {
        _selectedLoaders.clear();
        _selectedGameVersions.clear();
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _searchProjects(page: _currentPage - 1);
        _refreshInstalled(browseId);
      });
    } else if (needSearchAfterHint && browseId != null) {
      // Facet tab switched while targeting an instance: re-apply then search.
      final instance = _instanceById(browseId);
      if (instance != null) {
        _applyBrowseInstanceFilters(instance);
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _searchProjects(page: _currentPage - 1);
      });
    }

    final browseInstance = _instanceById(browseId);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 22),
      child: SizedBox(
        width: double.infinity,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const SizedBox(height: 12),
            if (browseInstance != null) ...[
              Container(
                width: double.infinity,
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                decoration: BoxDecoration(
                  color: tokens.colorRaisedBg,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  children: [
                    CustomButton(
                      icon: Icons.arrow_back,
                      size: ButtonSize.medium,
                      onTap: () => _nav.returnFromBrowseContent(),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '安装到 ${browseInstance.name}',
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: tokens.colorContrast,
                            ),
                          ),
                          Text(
                            '${browseInstance.loader} · ${browseInstance.gameVersion} · 切换页面也会保留此目标',
                            style: TextStyle(
                              fontSize: 12,
                              color: tokens.colorBase.withValues(alpha: 0.7),
                            ),
                          ),
                        ],
                      ),
                    ),
                    TextButton(
                      onPressed: () {
                        _nav.clearBrowseInstall();
                        _searchProjects(page: _currentPage - 1);
                        _refreshInstalled(null);
                      },
                      child: const Text('退出'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 12),
            ] else if (discoverReturnPage != null) ...[
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(
                  children: [
                    CustomButton(
                      icon: Icons.arrow_back,
                      size: ButtonSize.medium,
                      onTap: () => _nav.returnFromDiscoverBrowse(),
                    ),
                    const SizedBox(width: 10),
                    Text(
                      '返回${NavigationState.labelForPage(discoverReturnPage)}',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ],
                ),
              ),
            ],
            AnimatedTabBar(
              tabs: const ['Modrinth', 'CurseForge'],
              selectedIndex: _source == DiscoverSource.modrinth ? 0 : 1,
              onTabChanged: (index) {
                _switchSource(
                  index == 0
                      ? DiscoverSource.modrinth
                      : DiscoverSource.curseforge,
                );
              },
              colorScheme: colorScheme,
            ),
            const SizedBox(height: 12),
            AnimatedTabBar(
              tabs: _tabs,
              selectedIndex: _selectedTabIndex,
              onTabChanged: (index) {
                setState(() {
                  _selectedTabIndex = index;
                  _selectedCategories.clear();
                  _selectedEnvironments.clear();
                  if (browseInstance != null) {
                    _applyBrowseInstanceFilters(browseInstance);
                  } else {
                    _selectedLoaders.clear();
                    _selectedGameVersions.clear();
                  }
                });
                _searchProjects();
              },
              colorScheme: colorScheme,
            ),
            const SizedBox(height: 12),
            SearchBarWidget(
              prefixIcon: const Icon(Icons.search),
              colorScheme: colorScheme,
              hintText: '输入关键词，按 Enter 搜索',
              onSubmitted: (value) {
                setState(() => searchName = value.trim());
                _searchProjects(page: 0);
              },
            ),
            const SizedBox(height: 12),
            Row(
              children: [
                if (_availableLoaders.isNotEmpty) ...[
                  FilterMultiSelect(
                    label: _filterLabel('加载器', _selectedLoaders),
                    options: [
                      for (final loader in _availableLoaders)
                        FilterMultiSelectOption(
                          value: loader,
                          label: displayLoader(loader),
                        ),
                    ],
                    selected: _selectedLoaders,
                    colorScheme: colorScheme,
                    dropdownMinWidth: 200,
                    onChanged: (next) {
                      setState(() {
                        _selectedLoaders
                          ..clear()
                          ..addAll(next);
                      });
                      _searchProjects(debounce: true);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                if (_availableGameVersionIds.isNotEmpty) ...[
                  FilterMultiSelect(
                    label: _filterLabel('游戏版本', _selectedGameVersions),
                    options: [
                      for (final version in _availableGameVersionIds)
                        FilterMultiSelectOption(
                          value: version,
                          label: version,
                        ),
                    ],
                    selected: _selectedGameVersions,
                    colorScheme: colorScheme,
                    searchable: true,
                    searchPlaceholder: '搜索版本…',
                    dropdownMinWidth: 220,
                    maxHeight: 360,
                    footerLabel: '显示全部版本',
                    footerValue: _showAllGameVersions,
                    onFooterChanged: (value) {
                      setState(() {
                        _showAllGameVersions = value;
                        if (!value) {
                          _selectedGameVersions.removeWhere(
                            (v) => !_isSelectableReleaseVersion(v),
                          );
                        }
                      });
                      _searchProjects(debounce: true);
                    },
                    onChanged: (next) {
                      setState(() {
                        _selectedGameVersions
                          ..clear()
                          ..addAll(next);
                      });
                      _searchProjects(debounce: true);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                if (_showEnvironmentFilter) ...[
                  FilterMultiSelect(
                    label: _filterLabel('环境', _selectedEnvironments),
                    options: const [
                      FilterMultiSelectOption(
                        value: 'client',
                        label: '客户端',
                      ),
                      FilterMultiSelectOption(
                        value: 'server',
                        label: '服务端',
                      ),
                    ],
                    selected: _selectedEnvironments,
                    colorScheme: colorScheme,
                    dropdownMinWidth: 180,
                    onChanged: (next) {
                      setState(() {
                        _selectedEnvironments
                          ..clear()
                          ..addAll(next);
                      });
                      _searchProjects(debounce: true);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                if (_showCategoryFilter && _availableCategories.isNotEmpty) ...[
                  FilterMultiSelect(
                    label: _filterLabel('分类', _selectedCategories),
                    options: [
                      for (final cat in _availableCategories)
                        FilterMultiSelectOption(
                          value: cat,
                          label: displayCategory(cat),
                        ),
                    ],
                    selected: _selectedCategories,
                    colorScheme: colorScheme,
                    searchable: true,
                    searchPlaceholder: '搜索分类…',
                    dropdownMinWidth: 260,
                    maxHeight: 360,
                    onChanged: (next) {
                      setState(() {
                        _selectedCategories
                          ..clear()
                          ..addAll(next);
                      });
                      _searchProjects(debounce: true);
                    },
                  ),
                  const SizedBox(width: 8),
                ],
                DropdownButtonWidget(
                  items: [
                    const DropdownItem(display: '相关性', value: 'relevance'),
                    const DropdownItem(display: '下载量', value: 'downloads'),
                    if (!_isCurseForge)
                      const DropdownItem(display: '关注数', value: 'follows'),
                    const DropdownItem(display: '最新发布', value: 'newest'),
                    const DropdownItem(display: '最近更新', value: 'updated'),
                  ],
                  selectedValue: _selectedSortValue,
                  onChanged: (value) {
                    setState(() {
                      _selectedSortValue = value;
                    });
                    _searchProjects(debounce: true);
                  },
                  colorScheme: colorScheme,
                  prefix: '排序方式: ',
                ),
                const SizedBox(width: 8),
                DropdownButtonWidget(
                  items: [
                    const DropdownItem(display: '5', value: '5'),
                    const DropdownItem(display: '10', value: '10'),
                    const DropdownItem(display: '15', value: '15'),
                    const DropdownItem(display: '20', value: '20'),
                    const DropdownItem(display: '50', value: '50'),
                    if (!_isCurseForge)
                      const DropdownItem(display: '100', value: '100'),
                  ],
                  selectedValue: _selectedPageSize.toString(),
                  onChanged: (value) {
                    setState(() {
                      _selectedPageSize = int.tryParse(value) ?? 20;
                    });
                    _searchProjects(debounce: true);
                  },
                  colorScheme: colorScheme,
                  prefix: '查看: ',
                ),
                const Spacer(),
                ValueListenableBuilder<int>(
                  valueListenable: _controller.totalHits,
                  builder: (context, totalHits, child) {
                    final totalPages = totalHits == 0
                        ? 1
                        : ((totalHits - 1) ~/ _selectedPageSize) + 1;
                    return PaginationWidget(
                      totalPages: totalPages,
                      currentPage: _currentPage,
                      onPageChanged: (page) {
                        setState(() {
                          _currentPages[_selectedTabIndex] = page;
                        });
                        _searchProjects(page: page - 1);
                      },
                      colorScheme: colorScheme,
                    );
                  },
                ),
              ],
            ),
            const SizedBox(height: 12),
            Expanded(
              child: ValueListenableBuilder<bool>(
                valueListenable: _controller.loading,
                builder: (context, loading, child) {
                  if (loading) {
                    return const Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(),
                          SizedBox(height: 16),
                          Text('正在加载中...', style: TextStyle(fontSize: 14)),
                        ],
                      ),
                    );
                  }

                  return ValueListenableBuilder<String?>(
                    valueListenable: _controller.error,
                    builder: (context, error, _) {
                      if (error != null) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.cloud_off_outlined,
                                  size: 40,
                                  color: tokens.colorBase.withValues(alpha: 0.55),
                                ),
                                const SizedBox(height: 12),
                                Text(
                                  '加载失败',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.w800,
                                    color: tokens.colorContrast,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                Text(
                                  error,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 13,
                                    color: tokens.colorBase.withValues(alpha: 0.7),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                TextButton.icon(
                                  onPressed: () =>
                                      _searchProjects(page: _currentPage - 1),
                                  icon: const Icon(Icons.refresh, size: 18),
                                  label: const Text('重试'),
                                ),
                              ],
                            ),
                          ),
                        );
                      }

                      return ValueListenableBuilder<List<Project>>(
                        valueListenable: _controller.projects,
                        builder: (context, projects, child) {
                          if (projects.isEmpty) {
                            return Center(
                              child: Text(
                                '没有找到匹配的内容',
                                style: TextStyle(
                                  color: tokens.colorBase.withValues(alpha: 0.7),
                                ),
                              ),
                            );
                          }

                          return ListView.builder(
                            itemCount: projects.length,
                            itemBuilder: (context, index) {
                              final project = projects[index];
                              final state = _installState(project);
                              return Padding(
                                padding: const EdgeInsets.only(bottom: 12),
                                child: AppCard(
                                  title: project.title,
                                  description: project.description,
                                  author: project.author,
                                  downloads: project.downloads,
                                  followers: project.followers,
                                  iconUrl: project.iconUrl ?? '',
                                  categories: project.categories,
                                  displayCategories: project.displayCategories,
                                  gameVersions: project.gameVersions,
                                  projectType: project.projectType,
                                  dateCreated: project.dateCreated,
                                  dateModified: project.dateModified,
                                  showPublishedDate:
                                      _selectedSortValue == 'newest',
                                  installLabel: state.label,
                                  installDisabled: state.disabled,
                                  installing:
                                      _installingProjectId == project.id,
                                  onTap: () => _nav.openProject(
                                    project.id,
                                    preview: ProjectPreview.fromProject(
                                      id: project.id,
                                      title: project.title,
                                      description: project.description,
                                      iconUrl: project.iconUrl,
                                      downloads: project.downloads,
                                      projectType: project.projectType,
                                      clientSide: project.clientSide,
                                      serverSide: project.serverSide,
                                    ),
                                  ),
                                  onAuthorTap: project.author.trim().isEmpty
                                      ? null
                                      : () => _nav.openAuthor(
                                            project.author.trim(),
                                            type: 'user',
                                            preview: AuthorPreview(
                                              id: project.author.trim(),
                                              type: 'user',
                                              displayName: project.author.trim(),
                                            ),
                                          ),
                                  onInstall: state.disabled
                                      ? null
                                      : () => _install(project),
                                ),
                              );
                            },
                          );
                        },
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }
}
