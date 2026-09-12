import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/features/discover/ui/content_install_modal.dart';
import 'package:aml/src/features/discover/ui/project_environment.dart';
import 'package:aml/src/features/discover/ui/project_gallery_carousel.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:aml/src/shared/widgets/components/common/markdown_content.dart';
import 'package:aml/src/shared/widgets/components/common/pagination_widget.dart';
import 'package:aml/src/shared/widgets/components/common/skeleton.dart';
import 'package:aml/src/shared/widgets/components/inputs/filter_multi_select.dart';
import 'package:aml/src/shared/widgets/components/tabs/animated_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

class ProjectDetailPage extends StatefulWidget {
  const ProjectDetailPage({
    super.key,
    required this.projectId,
    this.preview,
  });

  final String projectId;
  final ProjectPreview? preview;

  @override
  State<ProjectDetailPage> createState() => _ProjectDetailPageState();
}

class _ProjectDetailPageState extends State<ProjectDetailPage> {
  static const _pageSize = 20;

  int _tab = 0;
  bool _loading = true;
  String? _error;
  ModrinthProjectDetail? _project;
  ModrinthAuthor? _author;
  List<ModrinthVersionInfo> _versions = [];
  String? _installingVersionId;
  String? _installedVersionId;
  /// When true, show source (untranslated) title / description / intro.
  bool _showOriginal = false;

  final Set<String> _selectedGameVersions = {};
  final Set<String> _selectedChannels = {};
  bool _showAllGameVersions = false;
  int _versionPage = 1;

  NavigationState get _nav => getIt<NavigationState>();

  ProjectPreview? get _preview =>
      widget.preview ??
      (_project != null ? ProjectPreview.fromDetail(_project!) : null);

  @override
  void initState() {
    super.initState();
    final cached = isCurseForgeProjectId(widget.projectId)
        ? CurseForgeApiService.peekCachedProject(widget.projectId)
        : ModrinthApiService.peekCachedProject(widget.projectId);
    if (cached != null) {
      _project = cached;
    }
    _load();
  }

  @override
  void didUpdateWidget(covariant ProjectDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.projectId != widget.projectId) {
      final cached = isCurseForgeProjectId(widget.projectId)
          ? CurseForgeApiService.peekCachedProject(widget.projectId)
          : ModrinthApiService.peekCachedProject(widget.projectId);
      setState(() {
        _project = cached;
        _versions = [];
        _author = null;
        _error = null;
        _loading = true;
        _showOriginal = false;
      });
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final browseId = _nav.browseInstallInstanceId.value;
      rust.InstanceDto? instance;
      if (browseId != null) {
        for (final i in getIt<InstanceStore>().instances.value) {
          if (i.id == browseId) {
            instance = i;
            break;
          }
        }
      }

      final isCf = isCurseForgeProjectId(widget.projectId);
      final cfModId = parseCurseForgeModId(widget.projectId);

      final ModrinthProjectDetail project;
      final List<ModrinthVersionInfo> versions;
      String? installedVid;

      if (isCf && cfModId != null) {
        project = await CurseForgeApiService.getProjectAsDetail(
          cfModId,
          localize: false,
        );
        if (instance == null) {
          versions =
              await CurseForgeApiService.getProjectVersionsAsModrinth(cfModId);
        } else {
          versions = await CurseForgeApiService.getProjectVersionsAsModrinth(
            cfModId,
            gameVersion: instance.gameVersion,
            loader: _loaderForType(project.projectType, instance.loader),
          );
          try {
            final mods = await rust.listInstanceMods(instanceId: browseId!);
            for (final m in mods) {
              if (m.projectId == project.id) {
                installedVid = m.versionId;
                break;
              }
            }
          } catch (_) {}
        }
      } else if (instance == null) {
        final results = await Future.wait([
          ModrinthApiService.getProject(widget.projectId, localize: false),
          ModrinthApiService.getProjectVersions(widget.projectId),
        ]);
        project = results[0] as ModrinthProjectDetail;
        versions = results[1] as List<ModrinthVersionInfo>;
      } else {
        project = await ModrinthApiService.getProject(
          widget.projectId,
          localize: false,
        );
        final versionsFuture = ModrinthApiService.getProjectVersions(
          project.id,
          gameVersion: instance.gameVersion,
          loader: _loaderForType(project.projectType, instance.loader),
        );
        final installedFuture = () async {
          try {
            final mods = await rust.listInstanceMods(instanceId: browseId!);
            for (final m in mods) {
              if (m.projectId == project.id || m.projectId == project.slug) {
                return m.versionId;
              }
            }
          } catch (_) {}
          return null;
        }();
        versions = await versionsFuture;
        installedVid = await installedFuture;
      }

      if (!mounted) return;
      setState(() {
        _project = project;
        _versions = versions;
        _installedVersionId = installedVid;
        if (!project.hasTranslation) _showOriginal = false;
        _selectedGameVersions.clear();
        _selectedChannels.clear();
        _showAllGameVersions = false;
        if (instance != null) {
          _selectedGameVersions.add(instance.gameVersion);
          if (!_isReleaseGameVersion(instance.gameVersion)) {
            _showAllGameVersions = true;
          }
        }
        _versionPage = 1;
        _loading = false;
      });
      if (!isCf) {
        unawaited(_loadAuthor(project));
      }
      unawaited(_localizeInBackground(project, isCf: isCf));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _localizeInBackground(
    ModrinthProjectDetail project, {
    required bool isCf,
  }) async {
    try {
      final localized = await DiscoverTranslation.localizeDetail(
        platform: isCf
            ? DiscoverTranslation.platformCurseforge
            : DiscoverTranslation.platformModrinth,
        projectId: isCf
            ? (parseCurseForgeModId(project.id)?.toString() ?? project.id)
            : project.id,
        slug: project.slug,
        title: project.title,
        description: project.description,
        body: project.body.trim().isNotEmpty
            ? project.body
            : project.description,
      );
      if (!mounted) return;
      if (_project?.id != project.id) return;
      final sourceBody = project.body.trim().isNotEmpty
          ? project.body
          : project.description;
      setState(() {
        _project = project.copyWith(
          title: localized.title,
          description: localized.description,
          body: localized.body,
          sourceTitle: project.title,
          sourceDescription: project.description,
          sourceBody: sourceBody,
        );
        if (!_project!.hasTranslation) _showOriginal = false;
      });
    } catch (_) {}
  }

  Future<void> _loadAuthor(ModrinthProjectDetail project) async {
    try {
      final author = await ModrinthApiService.resolveProjectAuthor(
        organizationId: project.organizationId,
        teamId: project.teamId,
      );
      if (!mounted || _project?.id != project.id) return;
      setState(() => _author = author);
    } catch (_) {}
  }

  void _openAuthor() {
    final author = _author;
    if (author == null) return;
    _nav.openAuthor(
      author.id.isNotEmpty ? author.id : author.username,
      type: author.type,
      preview: AuthorPreview(
        id: author.id.isNotEmpty ? author.id : author.username,
        type: author.type,
        displayName: author.displayName,
        avatarUrl: author.avatarUrl,
      ),
    );
  }

  String? _loaderForType(String projectType, String? instanceLoader) {
    switch (projectType) {
      case 'datapack':
        return 'datapack';
      case 'resourcepack':
        return 'minecraft';
      case 'shader':
        return 'iris';
      case 'mod':
      case 'modpack':
        if (instanceLoader == null ||
            instanceLoader.isEmpty ||
            instanceLoader == 'vanilla') {
          return null;
        }
        return instanceLoader;
      default:
        return instanceLoader == 'vanilla' ? null : instanceLoader;
    }
  }

  Future<void> _install({String? versionId}) async {
    final project = _project;
    if (project == null) return;
    setState(() => _installingVersionId = versionId ?? 'latest');
    try {
      final isCf = isCurseForgeProjectId(project.id);
      final cfModId = parseCurseForgeModId(project.id);

      if (project.projectType == 'modpack') {
        rust.InstanceDto? linked;
        for (final i in getIt<InstanceStore>().instances.value) {
          final src = i.modpackSource?.toLowerCase();
          if (src == 'modrinth' &&
              i.modpackProjectId == project.id &&
              !isCf) {
            linked = i;
            break;
          }
          if (src == 'curseforge' &&
              isCf &&
              sameProjectId(i.modpackProjectId, project.id)) {
            linked = i;
            break;
          }
        }

        if (linked != null && versionId == null) {
          await ContentInstallHelper.switchModpackVersion(
            context: context,
            instanceId: linked.id,
            projectId: project.id,
            title: project.title,
            projectIconUrl: project.iconUrl,
            currentVersionId: linked.modpackVersionId,
            modpackSource: linked.modpackSource,
            versions: _versions.isNotEmpty ? _versions : null,
          );
          await _load();
          return;
        }

        await ContentInstallHelper.installProject(
          context: context,
          projectId: project.id,
          title: project.title,
          projectType: project.projectType,
          projectIconUrl: project.iconUrl,
          versionId: versionId,
          versions: _versions.isNotEmpty ? _versions : null,
        );
        return;
      } else if (versionId != null) {
        final store = getIt<InstanceStore>();
        final instances = store.instances.value;
        if (instances.isEmpty) {
          if (mounted) {
            showAppSnackBar('请先创建一个实例', isError: true);
          }
          return;
        }
        var targetId = _nav.browseInstallInstanceId.value;
        if (targetId == null) {
          final pick = await ContentInstallModal.show(
            context,
            projectId: project.id,
            projectType: project.projectType,
            projectTitle: project.title,
            projectIconUrl: project.iconUrl,
          );
          if (pick?.action != ContentInstallModalAction.installToExisting) {
            return;
          }
          targetId = pick?.instanceId;
          if (targetId == null) return;
        }
        if (isCf && cfModId != null) {
          final fileId = int.tryParse(versionId);
          if (fileId == null) {
            if (mounted) {
              showAppSnackBar('无效的 CurseForge 文件', isError: true);
            }
            return;
          }
          await store.installCurseforgeFile(
            instanceId: targetId,
            modId: cfModId,
            fileId: fileId,
            projectType: project.projectType,
          );
        } else {
          await store.installModrinthVersion(
            instanceId: targetId,
            versionId: versionId,
            projectType: project.projectType,
            installDeps: true,
          );
        }
        if (!mounted) return;
        setState(() => _installedVersionId = versionId);
      } else {
        await ContentInstallHelper.installProject(
          context: context,
          projectId: project.id,
          title: project.title,
          projectType: project.projectType,
          preferredInstanceId: _nav.browseInstallInstanceId.value,
          latestVersionHint: _versions.isNotEmpty ? _versions.first.id : null,
          projectIconUrl: project.iconUrl,
          asUpdate: _installedVersionId != null,
          currentVersionId: _installedVersionId,
        );
        await _load();
      }
    } catch (e) {
      debugPrint('install failed: $e');
    } finally {
      if (mounted) setState(() => _installingVersionId = null);
    }
  }

  String _firstCategoryLabelFrom({
    required List<String> categories,
    List<String>? displayCategories,
  }) {
    final raw = (displayCategories != null && displayCategories.isNotEmpty)
        ? displayCategories
        : categories;
    for (final id in raw) {
      final label = displayCategory(id);
      if (label.isNotEmpty) return label;
    }
    return '';
  }

  String _projectTypeLabel(String type) {
    switch (type) {
      case 'mod':
        return '模组';
      case 'modpack':
        return '整合包';
      case 'resourcepack':
        return '资源包';
      case 'shader':
        return '光影';
      case 'datapack':
        return '数据包';
      default:
        return type;
    }
  }

  String _relativeTime(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
    if (diff.inDays < 1) return '${diff.inHours}小时前';
    if (diff.inDays < 30) return '${diff.inDays}天前';
    if (diff.inDays < 365) return '${(diff.inDays / 30).floor()}个月前';
    return '${(diff.inDays / 365).floor()}年前';
  }

  Color _channelColor(String type) {
    switch (type.toLowerCase()) {
      case 'beta':
        return const Color(0xFFE67E22);
      case 'alpha':
        return const Color(0xFFE74C3C);
      default:
        return const Color(0xFF2ECC71);
    }
  }

  String _channelLetter(String type) {
    switch (type.toLowerCase()) {
      case 'beta':
        return 'B';
      case 'alpha':
        return 'A';
      default:
        return 'R';
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final project = _project;

    if (_error != null && project == null && preview == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CustomButton(
              icon: Icons.arrow_back,
              size: ButtonSize.medium,
              onTap: () => _nav.closeProject(),
            ),
            const SizedBox(height: 24),
            Text(
              _error ?? '未找到项目',
              style: TextStyle(color: tokens.colorContrast),
            ),
          ],
        ),
      );
    }

    if (_loading && project == null && preview == null) {
      return _buildSkeleton(tokens);
    }

    if (_loading && (project != null || preview != null)) {
      final title = project != null
          ? project.displayTitle(original: _showOriginal)
          : preview!.title;
      final description = project != null
          ? project.displayDescription(original: _showOriginal)
          : preview!.description;
      final iconUrl = project?.iconUrl ?? preview?.iconUrl;
      final downloads = project?.downloads ?? preview!.downloads;
      final followers = project?.followers ?? preview!.followers;
      final projectType = project?.projectType ?? preview!.projectType;
      final clientSide = project?.clientSide ?? preview!.clientSide;
      final serverSide = project?.serverSide ?? preview!.serverSide;
      final categories = project?.categories ?? preview!.categories;
      return CustomScrollView(
        slivers: [
          SliverToBoxAdapter(
            child: _buildHeader(
              tokens,
              title: title,
              description: description,
              iconUrl: iconUrl,
              downloads: downloads,
              followers: followers,
              projectType: projectType,
              clientSide: clientSide,
              serverSide: serverSide,
              categories: categories,
              displayCategories: preview?.displayCategories,
              installLabel: '加载中…',
              installEnabled: false,
              author: _author,
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Align(
                alignment: Alignment.centerLeft,
                child: AnimatedTabBar(
                  tabs: const ['概述', '版本'],
                  selectedIndex: _tab,
                  onTabChanged: (i) => setState(() => _tab = i),
                  colorScheme: colorScheme,
                ),
              ),
            ),
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 12)),
          if (project != null && _tab == 0)
            SliverToBoxAdapter(child: _buildOverview(tokens, project))
          else
            SliverToBoxAdapter(child: _buildBodySkeleton(tokens)),
          const SliverFillRemaining(
            hasScrollBody: false,
            child: SizedBox.shrink(),
          ),
        ],
      );
    }

    if (project == null) {
      return Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            CustomButton(
              icon: Icons.arrow_back,
              size: ButtonSize.medium,
              onTap: () => _nav.closeProject(),
            ),
            const SizedBox(height: 24),
            Text(
              _error ?? '未找到项目',
              style: TextStyle(color: tokens.colorContrast),
            ),
          ],
        ),
      );
    }

    final browseId = _nav.browseInstallInstanceId.value;
    rust.InstanceDto? linkedModpack;
    if (project.projectType == 'modpack') {
      final isCf = isCurseForgeProjectId(project.id);
      for (final i in getIt<InstanceStore>().instances.value) {
        final src = i.modpackSource?.toLowerCase();
        if (src == 'modrinth' &&
            !isCf &&
            i.modpackProjectId == project.id) {
          linkedModpack = i;
          break;
        }
        if (src == 'curseforge' &&
            isCf &&
            sameProjectId(i.modpackProjectId, project.id)) {
          linkedModpack = i;
          break;
        }
      }
    }
    final installLabel = project.projectType == 'modpack'
        ? (linkedModpack != null ? '切换版本' : '安装')
        : (_installedVersionId == null
            ? (browseId != null ? '安装到实例' : '安装')
            : (_versions.isNotEmpty &&
                    _versions.first.id != _installedVersionId
                ? '更新'
                : '已安装'));
    final installDisabled = installLabel == '已安装';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: _buildHeader(
            tokens,
            title: project.displayTitle(original: _showOriginal),
            description: project.displayDescription(original: _showOriginal),
            iconUrl: project.iconUrl,
            downloads: project.downloads,
            followers: project.followers,
            projectType: project.projectType,
            clientSide: project.clientSide,
            serverSide: project.serverSide,
            categories: project.categories,
            installLabel:
                _installingVersionId == 'latest' ? '安装中…' : installLabel,
            installEnabled: !installDisabled && _installingVersionId == null,
            installDisabledStyle: installDisabled,
            onInstall: () => _install(),
            author: _author,
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerLeft,
              child: AnimatedTabBar(
                tabs: const ['概述', '版本'],
                selectedIndex: _tab,
                onTabChanged: (i) => setState(() => _tab = i),
                colorScheme: colorScheme,
              ),
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 12)),
        if (_tab == 0)
          SliverToBoxAdapter(child: _buildOverview(tokens, project))
        else
          SliverToBoxAdapter(
            child: _buildVersions(tokens, project, colorScheme),
          ),
        const SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _metaPlain(tokens, IconData icon, String label) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 18, color: tokens.colorBase.withValues(alpha: 0.7)),
        const SizedBox(width: 5),
        Text(
          label,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: tokens.colorBase.withValues(alpha: 0.85),
          ),
        ),
      ],
    );
  }

  Widget _buildHeader(
    tokens, {
    required String title,
    required String description,
    required String? iconUrl,
    required int downloads,
    required int followers,
    required String projectType,
    required String clientSide,
    required String serverSide,
    required List<String> categories,
    List<String>? displayCategories,
    required String installLabel,
    required bool installEnabled,
    bool installDisabledStyle = false,
    VoidCallback? onInstall,
    ModrinthAuthor? author,
  }) {
    final env = ProjectEnvironmentBadge.fromSides(
      clientSide: clientSide,
      serverSide: serverSide,
      projectType: projectType,
    );
    final categoryLabel = _firstCategoryLabelFrom(
      categories: categories,
      displayCategories: displayCategories,
    );
    final showDisabled = !installEnabled || installDisabledStyle;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CustomButton(
            icon: Icons.arrow_back,
            size: ButtonSize.medium,
            onTap: () => _nav.closeProject(),
          ),
          const SizedBox(width: 14),
          iconUrl != null && iconUrl.isNotEmpty
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => showImageLightbox(
                      context,
                      urls: [iconUrl],
                    ),
                    child: CachedRemoteImage(
                      url: iconUrl,
                      width: 84,
                      height: 84,
                      borderRadius: BorderRadius.circular(14),
                      placeholder: Container(
                        width: 84,
                        height: 84,
                        color: tokens.colorSuperRaisedBg,
                        child: Icon(
                          Icons.extension,
                          color: tokens.colorContrast,
                        ),
                      ),
                      error: Container(
                        width: 84,
                        height: 84,
                        color: tokens.colorSuperRaisedBg,
                        child: Icon(
                          Icons.extension,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ),
                  ),
                )
              : Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: tokens.colorSuperRaisedBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.extension,
                    color: tokens.colorContrast,
                  ),
                ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
                if (author != null) ...[
                  const SizedBox(height: 6),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: _openAuthor,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (author.avatarUrl != null &&
                              author.avatarUrl!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: CachedRemoteImage(
                                url: author.avatarUrl!,
                                width: 18,
                                height: 18,
                                borderRadius: BorderRadius.circular(9),
                                placeholder: const SizedBox.shrink(),
                                error: const SizedBox.shrink(),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              'by ${author.displayName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: tokens.colorBrand,
                                decoration: TextDecoration.underline,
                                decorationColor:
                                    tokens.colorBrand.withValues(alpha: 0.55),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: tokens.colorBase.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _metaPlain(
                      tokens,
                      Icons.download_rounded,
                      ModrinthApiService.formatDownloadCount(downloads),
                    ),
                    _metaPlain(
                      tokens,
                      Icons.favorite_border_rounded,
                      ModrinthApiService.formatDownloadCount(followers),
                    ),
                    Text(
                      categoryLabel.isNotEmpty
                          ? categoryLabel
                          : _projectTypeLabel(projectType),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: tokens.colorBase.withValues(alpha: 0.8),
                      ),
                    ),
                    if (env != null) EnvironmentBadgeChip(badge: env),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: installEnabled ? onInstall : null,
            icon: Icon(
              installDisabledStyle ? Icons.check : Icons.download_rounded,
              size: 18,
            ),
            label: Text(installLabel),
            style: FilledButton.styleFrom(
              backgroundColor:
                  showDisabled ? tokens.colorButtonBg : tokens.colorBrand,
              foregroundColor:
                  showDisabled ? tokens.colorContrast : tokens.colorOnBrand,
              disabledBackgroundColor: tokens.colorButtonBg,
              disabledForegroundColor:
                  tokens.colorContrast.withValues(alpha: 0.85),
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBodySkeleton(tokens) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 6; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            SkeletonBox(
              tokens: tokens,
              width: i == 5 ? 180 : double.infinity,
              height: 14,
            ),
          ],
          const SizedBox(height: 20),
          SkeletonBox(
            tokens: tokens,
            width: double.infinity,
            height: 160,
            borderRadius: BorderRadius.circular(12),
          ),
        ],
      ),
    );
  }

  Widget _buildSkeleton(tokens) {
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CustomButton(
                  icon: Icons.arrow_back,
                  size: ButtonSize.medium,
                  onTap: () => _nav.closeProject(),
                ),
                const SizedBox(width: 14),
                SkeletonBox(
                  tokens: tokens,
                  width: 84,
                  height: 84,
                  borderRadius: BorderRadius.circular(14),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(tokens: tokens, width: 220, height: 28),
                      const SizedBox(height: 10),
                      SkeletonBox(
                        tokens: tokens,
                        width: double.infinity,
                        height: 14,
                      ),
                      const SizedBox(height: 6),
                      SkeletonBox(tokens: tokens, width: 280, height: 14),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SkeletonBox(tokens: tokens, width: 72, height: 16),
                          const SizedBox(width: 16),
                          SkeletonBox(tokens: tokens, width: 56, height: 16),
                          const SizedBox(width: 16),
                          SkeletonBox(tokens: tokens, width: 64, height: 16),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SkeletonBox(
                  tokens: tokens,
                  width: 96,
                  height: 44,
                  borderRadius: BorderRadius.circular(12),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SkeletonBox(
                  tokens: tokens,
                  width: 72,
                  height: 34,
                  borderRadius: BorderRadius.circular(20),
                ),
                const SizedBox(width: 8),
                SkeletonBox(
                  tokens: tokens,
                  width: 72,
                  height: 34,
                  borderRadius: BorderRadius.circular(20),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (var i = 0; i < 6; i++) ...[
                  if (i > 0) const SizedBox(height: 10),
                  SkeletonBox(
                    tokens: tokens,
                    width: i == 5 ? 180 : double.infinity,
                    height: 14,
                  ),
                ],
                const SizedBox(height: 20),
                SkeletonBox(
                  tokens: tokens,
                  width: double.infinity,
                  height: 160,
                  borderRadius: BorderRadius.circular(12),
                ),
              ],
            ),
          ),
        ),
        const SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox.shrink(),
        ),
      ],
    );
  }

  Widget _buildOverview(tokens, ModrinthProjectDetail project) {
    final gallery = project.gallery.where((g) => g.url.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (gallery.isNotEmpty) ...[
            ProjectGalleryCarousel(
              gallery: gallery,
              onTap: (index) {
                showImageLightbox(
                  context,
                  urls: gallery.map((g) => g.url).toList(),
                  initialIndex: index,
                  titles: gallery.map((g) => g.title).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final cat in project.categories)
                Chip(
                  label: Text(displayCategory(cat)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: tokens.colorRaisedBg,
                ),
              for (final loader in project.loaders.take(6))
                Chip(
                  label: Text(displayLoader(loader)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: tokens.colorBrandHighlight,
                  labelStyle: TextStyle(
                    color: tokens.colorBrand,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _sideInfo(tokens, project),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '介绍',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              if (project.hasTranslation)
                SegmentedButton<bool>(
                  style: ButtonStyle(
                    visualDensity: VisualDensity.compact,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    textStyle: WidgetStatePropertyAll(
                      TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                  segments: const [
                    ButtonSegment<bool>(
                      value: false,
                      label: Text('译文'),
                    ),
                    ButtonSegment<bool>(
                      value: true,
                      label: Text('原文'),
                    ),
                  ],
                  selected: {_showOriginal},
                  onSelectionChanged: (next) {
                    if (next.isEmpty) return;
                    setState(() => _showOriginal = next.first);
                  },
                ),
            ],
          ),
          const SizedBox(height: 8),
          MarkdownContent(
            data: project.displayBody(original: _showOriginal),
          ),
        ],
      ),
    );
  }

  Widget _sideInfo(tokens, ModrinthProjectDetail project) {
    final games = project.gameVersions.reversed.take(8).toList().reversed;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoLine(
            tokens,
            '许可证',
            project.licenseName.isEmpty
                ? (project.licenseId.isEmpty ? '—' : project.licenseId)
                : project.licenseName,
          ),
          _infoLine(
            tokens,
            '游戏版本',
            games.isEmpty ? '—' : games.join(', '),
          ),
          _infoLine(
            tokens,
            '加载器',
            project.loaders.isEmpty
                ? '—'
                : project.loaders.map(displayLoader).join(', '),
          ),
        ],
      ),
    );
  }

  Widget _infoLine(tokens, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: tokens.colorContrast)),
          ),
        ],
      ),
    );
  }

  Widget _pill(tokens, String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 5),
      decoration: BoxDecoration(
        color: tokens.colorButtonBg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: tokens.colorContrast.withValues(alpha: 0.9),
        ),
      ),
    );
  }

  /// Release-like game versions: `1.21.1`, `26.1.2`. Snapshots/pre/rc excluded.
  bool _isReleaseGameVersion(String version) {
    return RegExp(r'^\d+(\.\d+)+$').hasMatch(version);
  }

  List<String> get _allGameVersions {
    final set = <String>{};
    for (final v in _versions) {
      set.addAll(v.gameVersions);
    }
    final list = set.toList()..sort((a, b) => b.compareTo(a));
    return list;
  }

  List<String> get _availableGameVersions {
    final all = _allGameVersions;
    final hasRelease = all.any(_isReleaseGameVersion);
    final hasNonRelease = all.any((v) => !_isReleaseGameVersion(v));
    if (_showAllGameVersions || !hasRelease || !hasNonRelease) {
      return all;
    }
    return all.where(_isReleaseGameVersion).toList();
  }

  bool get _hasNonReleaseGameVersions =>
      _allGameVersions.any((v) => !_isReleaseGameVersion(v));

  List<String> get _availableChannels {
    final set = <String>{};
    for (final v in _versions) {
      set.add(v.versionType.toLowerCase());
    }
    const order = ['release', 'beta', 'alpha'];
    final list = set.toList()
      ..sort((a, b) {
        final ai = order.indexOf(a);
        final bi = order.indexOf(b);
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
      });
    return list;
  }

  List<ModrinthVersionInfo> get _filteredVersions {
    return _versions.where((v) {
      if (_selectedGameVersions.isNotEmpty &&
          !_selectedGameVersions.any(v.gameVersions.contains)) {
        return false;
      }
      if (_selectedChannels.isNotEmpty &&
          !_selectedChannels.contains(v.versionType.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();
  }

  String _channelLabel(String channel) {
    switch (channel.toLowerCase()) {
      case 'beta':
        return 'Beta';
      case 'alpha':
        return 'Alpha';
      default:
        return 'Release';
    }
  }

  void _setShowAllGameVersions(bool value) {
    setState(() {
      _showAllGameVersions = value;
      if (!value) {
        _selectedGameVersions.removeWhere((v) => !_isReleaseGameVersion(v));
      }
      _versionPage = 1;
    });
  }

  Widget _buildVersions(
    tokens,
    ModrinthProjectDetail project,
    ColorScheme colorScheme,
  ) {
    final filtered = _filteredVersions;
    final totalPages =
        filtered.isEmpty ? 1 : ((filtered.length - 1) ~/ _pageSize) + 1;
    final page = _versionPage.clamp(1, totalPages);
    if (page != _versionPage) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _versionPage = page);
      });
    }
    final start = (page - 1) * _pageSize;
    final pageItems = filtered.skip(start).take(_pageSize).toList();
    final gameOptions = _availableGameVersions
        .map((v) => FilterMultiSelectOption(value: v, label: v))
        .toList();
    final channelOptions = _availableChannels
        .map(
          (c) => FilterMultiSelectOption(value: c, label: _channelLabel(c)),
        )
        .toList();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              if (gameOptions.isNotEmpty)
                FilterMultiSelect(
                  label: '游戏版本',
                  options: gameOptions,
                  selected: _selectedGameVersions,
                  colorScheme: colorScheme,
                  searchable: true,
                  searchPlaceholder: '搜索…',
                  dropdownMinWidth: 240,
                  footerLabel: _hasNonReleaseGameVersions ? '显示全部版本' : null,
                  footerValue: _showAllGameVersions,
                  onFooterChanged: _hasNonReleaseGameVersions
                      ? _setShowAllGameVersions
                      : null,
                  onChanged: (next) {
                    setState(() {
                      _selectedGameVersions
                        ..clear()
                        ..addAll(next);
                      _versionPage = 1;
                    });
                  },
                ),
              if (gameOptions.isNotEmpty && channelOptions.isNotEmpty)
                const SizedBox(width: 8),
              if (channelOptions.isNotEmpty)
                FilterMultiSelect(
                  label: '通道',
                  options: channelOptions,
                  selected: _selectedChannels,
                  colorScheme: colorScheme,
                  dropdownMinWidth: 180,
                  onChanged: (next) {
                    setState(() {
                      _selectedChannels
                        ..clear()
                        ..addAll(next);
                      _versionPage = 1;
                    });
                  },
                ),
              const Spacer(),
              if (totalPages > 1)
                PaginationWidget(
                  currentPage: page,
                  totalPages: totalPages,
                  colorScheme: colorScheme,
                  onPageChanged: (p) => setState(() => _versionPage = p),
                ),
            ],
          ),
          const SizedBox(height: 12),
          if (filtered.isEmpty)
            Container(
              height: 220,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: tokens.colorRaisedBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: tokens.colorSecondary.withValues(alpha: 0.22),
                ),
              ),
              child: Text(
                _versions.isEmpty ? '没有匹配的版本' : '没有符合筛选条件的版本',
                style: TextStyle(color: tokens.colorBase),
              ),
            )
          else
            Container(
              decoration: BoxDecoration(
                color: tokens.colorRaisedBg,
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: tokens.colorSecondary.withValues(alpha: 0.22),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: const EdgeInsets.fromLTRB(16, 13, 12, 13),
                    decoration: BoxDecoration(
                      color: tokens.colorSuperRaisedBg.withValues(alpha: 0.55),
                      border: Border(
                        bottom: BorderSide(
                          color: tokens.colorSecondary.withValues(alpha: 0.35),
                          width: 1,
                        ),
                      ),
                    ),
                    child: Row(
                      children: [
                        Expanded(
                          flex: 3,
                          child: Text(
                            '版本',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tokens.colorBase.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '游戏版本',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tokens.colorBase.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        Expanded(
                          flex: 2,
                          child: Text(
                            '平台',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tokens.colorBase.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 96,
                          child: Text(
                            '发布时间',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tokens.colorBase.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        SizedBox(
                          width: 80,
                          child: Text(
                            '下载量',
                            textAlign: TextAlign.right,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: tokens.colorBase.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                        const SizedBox(width: 96),
                      ],
                    ),
                  ),
                  for (var i = 0; i < pageItems.length; i++)
                    _versionRow(
                      tokens,
                      project,
                      pageItems[i],
                      striped: i.isOdd,
                    ),
                ],
              ),
            ),
          if (totalPages > 1) ...[
            const SizedBox(height: 16),
            Center(
              child: PaginationWidget(
                currentPage: page,
                totalPages: totalPages,
                colorScheme: colorScheme,
                onPageChanged: (p) => setState(() => _versionPage = p),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _versionRow(
    tokens,
    ModrinthProjectDetail project,
    ModrinthVersionInfo v, {
    required bool striped,
  }) {
    final isInstalled = v.id == _installedVersionId;
    final installing = _installingVersionId == v.id;
    final gameLabel = v.gameVersions.isEmpty ? '—' : v.gameVersions.first;
    final loaderLabel =
        v.loaders.isEmpty ? '—' : displayLoader(v.loaders.first);
    final channel = v.versionType;
    final rowBg = striped
        ? tokens.colorSuperRaisedBg.withValues(alpha: 0.35)
        : Colors.transparent;

    return ColoredBox(
      color: rowBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
        child: Row(
          children: [
            Expanded(
              flex: 3,
              child: Row(
                children: [
                  Container(
                    width: 28,
                    height: 28,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: _channelColor(channel),
                      shape: BoxShape.circle,
                    ),
                    child: Text(
                      _channelLetter(channel),
                      style: const TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.w800,
                        fontSize: 13,
                      ),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      v.versionNumber.isNotEmpty ? v.versionNumber : v.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontWeight: FontWeight.w800,
                        fontSize: 16,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: _pill(tokens, gameLabel),
              ),
            ),
            Expanded(
              flex: 2,
              child: Align(
                alignment: Alignment.centerLeft,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.sell_outlined,
                      size: 16,
                      color: tokens.colorBase.withValues(alpha: 0.55),
                    ),
                    const SizedBox(width: 5),
                    Flexible(child: _pill(tokens, loaderLabel)),
                  ],
                ),
              ),
            ),
            SizedBox(
              width: 96,
              child: Text(
                _relativeTime(v.datePublished),
                style: TextStyle(
                  fontSize: 14,
                  color: tokens.colorBase.withValues(alpha: 0.75),
                ),
              ),
            ),
            SizedBox(
              width: 80,
              child: Text(
                ModrinthApiService.formatDownloadCount(v.downloads),
                textAlign: TextAlign.right,
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: tokens.colorContrast,
                ),
              ),
            ),
            SizedBox(
              width: 96,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    tooltip: isInstalled ? '已安装' : (installing ? '安装中' : '安装'),
                    onPressed: isInstalled || installing
                        ? null
                        : () => _install(versionId: v.id),
                    iconSize: 22,
                    icon: Icon(
                      isInstalled
                          ? Icons.check_circle_outline
                          : Icons.download_rounded,
                      color: isInstalled
                          ? tokens.colorBase.withValues(alpha: 0.45)
                          : tokens.colorBrand,
                    ),
                  ),
                  IconButton(
                    tooltip: '在浏览器打开',
                    iconSize: 20,
                    onPressed: () {
                      final Uri url;
                      if (isCurseForgeProjectId(project.id)) {
                        final cfPath = switch (project.projectType) {
                          'modpack' => 'modpacks',
                          'resourcepack' => 'texture-packs',
                          'shader' => 'shaders',
                          'datapack' => 'data-packs',
                          _ => 'mc-mods',
                        };
                        url = Uri.parse(
                          'https://www.curseforge.com/minecraft/$cfPath/${project.slug}/files/${v.id}',
                        );
                      } else {
                        final typePath = switch (project.projectType) {
                          'modpack' => 'modpack',
                          'resourcepack' => 'resourcepack',
                          'shader' => 'shader',
                          'datapack' => 'datapack',
                          _ => 'mod',
                        };
                        url = Uri.parse(
                          'https://modrinth.com/$typePath/${project.slug}/version/${v.id}',
                        );
                      }
                      launchUrl(url, mode: LaunchMode.externalApplication);
                    },
                    icon: Icon(
                      Icons.open_in_new,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
