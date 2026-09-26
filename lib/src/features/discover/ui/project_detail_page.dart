import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/content_install_modal.dart';
import 'package:aml/src/features/discover/ui/content_version_picker.dart';
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
  bool _showOriginal = true;

  /// True while a user-requested translation is running.
  bool _translating = false;

  /// Incremented on each completed load; remounts the versions section
  /// (resetting its filters, matching the previous in-place reset).
  int _loadEpoch = 0;

  /// Instance game version the versions filter preselects (browse context).
  String? _instanceGameVersion;

  /// Instance platform (loader) the versions filter preselects (browse context).
  String? _instanceLoader;

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
    } else if (widget.preview != null) {
      // 列表数据已包含头部所需全部字段，先渲染头部，后台拉详情补全正文/画廊/版本。
      _project = ModrinthProjectDetail.fromPreview(widget.preview!);
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
      final initial = cached ??
          (widget.preview != null
              ? ModrinthProjectDetail.fromPreview(widget.preview!)
              : null);
      setState(() {
        _project = initial;
        _versions = [];
        _author = null;
        _error = null;
        _loading = true;
        _showOriginal = true;
        _translating = false;
        _instanceGameVersion = null;
        _instanceLoader = null;
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
      String? effectiveLoader;

      if (isCf && cfModId != null) {
        project = await CurseForgeApiService.getProjectAsDetail(
          cfModId,
          localize: false,
        );
        if (instance == null) {
          versions =
              await CurseForgeApiService.getProjectVersionsAsModrinth(cfModId);
        } else {
          effectiveLoader = _loaderForType(
            project.projectType,
            instance.loader,
          );
          versions = await CurseForgeApiService.getProjectVersionsAsModrinth(
            cfModId,
            gameVersion: instance.gameVersion,
            loader: effectiveLoader,
          );
          try {
            final mods = await rust.listInstanceMods(instanceId: browseId!);
            for (final m in mods) {
              if (sameProjectId(m.projectId, project.id)) {
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
        effectiveLoader = _loaderForType(
          project.projectType,
          instance.loader,
        );
        final versionsFuture = ModrinthApiService.getProjectVersions(
          project.id,
          gameVersion: instance.gameVersion,
          loader: effectiveLoader,
        );
        final installedFuture = () async {
          try {
            final mods = await rust.listInstanceMods(instanceId: browseId!);
            for (final m in mods) {
              if (sameProjectId(m.projectId, project.id) ||
                  m.projectId == project.slug) {
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

      // 标题(MCDB) + 简介(MCIM) 立即汉化，与列表页一致；正文等待用户点「译文」。
      final platformStr = isCf
          ? DiscoverTranslation.platformCurseforge
          : DiscoverTranslation.platformModrinth;
      final projectIdStr = isCf
          ? (cfModId?.toString() ?? widget.projectId)
          : widget.projectId;

      final header = await DiscoverTranslation.localizeHeader(
        platform: platformStr,
        projectId: projectIdStr,
        slug: project.slug.isNotEmpty ? project.slug : null,
        title: project.title,
        description: project.description,
      );

      final localizedProject = project.copyWith(
        title: header.title,
        description: header.description,
        sourceTitle: project.title,
        sourceDescription: project.description,
      );

      setState(() {
        _project = localizedProject;
        _versions = versions;
        _installedVersionId = installedVid;
        _instanceGameVersion = instance?.gameVersion;
        _instanceLoader = effectiveLoader;
        _loadEpoch++;
        _loading = false;
      });
      if (!isCf) {
        unawaited(_loadAuthor(project));
      }
      // 正文翻译改为按需触发：用户点击「译文」时才调用 _translateOnDemand。
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  /// 用户点击「译文」时按需翻译正文。标题/简介已在加载时汉化。
  Future<void> _translateOnDemand(ModrinthProjectDetail project) async {
    if (_translating) return;
    if (project.sourceBody != null) return;
    setState(() => _translating = true);
    final sourceBody =
        project.body.trim().isNotEmpty ? project.body : project.description;
    try {
      final isCf = isCurseForgeProjectId(project.id);
      final zhBody = await DiscoverTranslation.localizeBody(
        platform: isCf
            ? DiscoverTranslation.platformCurseforge
            : DiscoverTranslation.platformModrinth,
        projectId: isCf
            ? (parseCurseForgeModId(project.id)?.toString() ?? project.id)
            : project.id,
        overview: sourceBody,
      );
      if (!mounted) return;
      if (_project?.id != project.id) return;
      final changed = zhBody != sourceBody;
      setState(() {
        _project = project.copyWith(
          body: zhBody,
          sourceBody: sourceBody,
        );
      });
      if (!changed) {
        showAppSnackBar('翻译未返回结果，已保持原文');
      }
    } catch (e) {
      debugPrint('[translate] body failed: $e');
      if (mounted) showAppSnackBar('翻译失败：$e');
    } finally {
      if (mounted) setState(() => _translating = false);
    }
  }

  /// 原文/译文切换。仅控制正文；标题/简介已在加载时汉化。
  void _toggleOriginal(bool v) {
    // 选「译文」但正文云翻译开关关闭时，提示用户去设置开启。
    if (!v && !DiscoverTranslation.detailBodyEnabled) {
      showAppSnackBar('正文云翻译已关闭，请在 设置 → 翻译 中开启');
      return;
    }
    setState(() => _showOriginal = v);
    if (!v && _project != null && _project!.sourceBody == null) {
      unawaited(_translateOnDemand(_project!));
    }
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
          if (src == 'modrinth' && i.modpackProjectId == project.id && !isCf) {
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
        // 从实例「浏览内容」进入：先弹窗选择版本（默认最新），再装入该实例。
        final browseInstanceId = _nav.browseInstallInstanceId.value;
        if (browseInstanceId != null && _versions.isNotEmpty) {
          final picked = await ContentVersionPicker.show(
            context,
            versions: _versions,
            projectTitle: project.title,
            currentVersionId: _installedVersionId,
          );
          if (picked == null || !mounted) return;
          await _install(versionId: picked.id);
          return;
        }
        await ContentInstallHelper.installProject(
          context: context,
          projectId: project.id,
          title: project.title,
          projectType: project.projectType,
          preferredInstanceId: _nav.browseInstallInstanceId.value,
          latestVersionHint: pickPreferredVersion(_versions)?.id,
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

    if (project == null) {
      if (_loading) {
        return ProjectDetailSkeleton(onBack: () => _nav.closeProject());
      }
      return errorView(_error ?? '未找到项目');
    }

    final browseId = _nav.browseInstallInstanceId.value;
    rust.InstanceDto? linkedModpack;
    if (project.projectType == 'modpack') {
      final isCf = isCurseForgeProjectId(project.id);
      for (final i in getIt<InstanceStore>().instances.value) {
        final src = i.modpackSource?.toLowerCase();
        if (src == 'modrinth' && !isCf && i.modpackProjectId == project.id) {
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
    // 「更新」判定基于默认推荐版本（最新正式版 → Beta → Alpha），
    // 而不是时间上最新（可能是 Alpha）的版本。
    final preferredVersionId = pickPreferredVersion(_versions)?.id;
    final installLabel = _loading
        ? '加载中…'
        : (_installingVersionId != null
            ? '安装中…'
            : (project.projectType == 'modpack'
                ? (linkedModpack != null ? '切换版本' : '安装')
                : (_installedVersionId == null
                    ? (browseId != null ? '安装到实例' : '安装')
                    : (preferredVersionId != null &&
                            preferredVersionId != _installedVersionId
                        ? '更新'
                        : '已安装'))));
    final installDisabled = installLabel == '已安装';

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: ProjectDetailHeader(
            title: project.displayTitle(original: false),
            description: project.displayDescription(original: false),
            iconUrl: project.iconUrl,
            downloads: project.downloads,
            followers: project.followers,
            projectType: project.projectType,
            clientSide: project.clientSide,
            serverSide: project.serverSide,
            categories: project.categories,
            displayCategories: preview?.displayCategories,
            installLabel: installLabel,
            installEnabled:
                !_loading && !installDisabled && _installingVersionId == null,
            installDisabledStyle:
                installDisabled || _installingVersionId != null,
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
          if (_loading && project.body.isEmpty)
            const SliverToBoxAdapter(child: ProjectDetailBodySkeleton())
          else
            SliverToBoxAdapter(
              child: ProjectOverviewSection(
                project: project,
                showOriginal: _showOriginal,
                translating: _translating,
                onToggleOriginal: _toggleOriginal,
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
              initialSelectedLoader: _instanceLoader,
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
