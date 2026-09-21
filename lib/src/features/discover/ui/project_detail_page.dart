import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/content_install_modal.dart';
import 'package:aml/src/features/discover/ui/project_detail_header.dart';
import 'package:aml/src/features/discover/ui/project_detail_skeletons.dart';
import 'package:aml/src/features/discover/ui/project_overview_section.dart';
import 'package:aml/src/features/discover/ui/project_versions_section.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/tabs/animated_tab_bar.dart';
import 'package:flutter/material.dart';

/// 项目详情页（数据加载 + 安装编排 + 页面装配）。
/// 头部 / 骨架 / 概述 / 版本列表分别在独立子组件文件中。
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
  /// Incremented on each completed load; remounts the versions section
  /// (resetting its filters, matching the previous in-place reset).
  int _loadEpoch = 0;
  /// Instance game version the versions filter preselects (browse context).
  String? _instanceGameVersion;

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
        _instanceGameVersion = instance?.gameVersion;
        _loadEpoch++;
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

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;
    final preview = _preview;
    final project = _project;

    Widget errorView(String message) {
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
              message,
              style: TextStyle(color: tokens.colorContrast),
            ),
          ],
        ),
      );
    }

    if (project == null && preview == null) {
      if (_loading) {
        return ProjectDetailSkeleton(onBack: () => _nav.closeProject());
      }
      return errorView(_error ?? '未找到项目');
    }
    if (project == null) {
      // Preview available but the full detail failed to load.
      return errorView(_error ?? '未找到项目');
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
    final installLabel = _loading
        ? '加载中…'
        : (project.projectType == 'modpack'
            ? (linkedModpack != null ? '切换版本' : '安装')
            : (_installedVersionId == null
                ? (browseId != null ? '安装到实例' : '安装')
                : (_versions.isNotEmpty &&
                        _versions.first.id != _installedVersionId
                    ? '更新'
                    : '已安装')));
    final installDisabled = installLabel == '已安装';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ProjectDetailHeader(
            title: project.displayTitle(original: _showOriginal),
            description:
                project.displayDescription(original: _showOriginal),
            iconUrl: project.iconUrl,
            downloads: project.downloads,
            followers: project.followers,
            projectType: project.projectType,
            clientSide: project.clientSide,
            serverSide: project.serverSide,
            categories: project.categories,
            displayCategories: preview?.displayCategories,
            installLabel:
                _installingVersionId == 'latest' ? '安装中…' : installLabel,
            installEnabled: !_loading && !installDisabled &&
                _installingVersionId == null,
            installDisabledStyle: installDisabled,
            onInstall: () => _install(),
            author: _author,
            onAuthorTap: _openAuthor,
            onBack: () => _nav.closeProject(),
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
          SliverToBoxAdapter(
            child: ProjectOverviewSection(
              project: project,
              showOriginal: _showOriginal,
              onToggleOriginal: (v) => setState(() => _showOriginal = v),
            ),
          )
        else if (_loading)
          const SliverToBoxAdapter(child: ProjectDetailBodySkeleton())
        else
          SliverToBoxAdapter(
            child: ProjectVersionsSection(
              key: ValueKey('versions:${widget.projectId}:$_loadEpoch'),
              project: project,
              versions: _versions,
              installedVersionId: _installedVersionId,
              installingVersionId: _installingVersionId,
              initialSelectedGameVersion: _instanceGameVersion,
              onInstall: (versionId) => _install(versionId: versionId),
              colorScheme: colorScheme,
            ),
          ),
        const SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox.shrink(),
        ),
      ],
    );
  }
}
