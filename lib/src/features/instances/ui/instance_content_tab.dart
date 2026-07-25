import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/app/state/progress_state.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

/// Content tab (mods / resource packs / shaders / datapacks) for an instance.
class InstanceContentTab extends StatefulWidget {
  const InstanceContentTab({super.key, required this.instanceId});

  final String instanceId;

  @override
  State<InstanceContentTab> createState() => InstanceContentTabState();
}

class InstanceContentTabState extends State<InstanceContentTab> {
  List<rust.ModFileDto> _mods = [];
  bool _busy = false;
  Set<String> _updatingContentPaths = {};
  String _contentQuery = '';
  String _contentFilter =
      'all'; // all | mod | resourcepack | shader | datapack | updates
  bool _contentLoading = false;
  bool _contentSyncing = false;
  bool _contentSyncedOnce = false;
  int _contentSyncGen = 0;

  /// Whether a full metadata sync has completed at least once.
  bool get syncedOnce => _contentSyncedOnce;

  InstanceStore get _store => getIt<InstanceStore>();

  rust.InstanceDto? get _instance {
    for (final i in _store.instances.value) {
      if (i.id == widget.instanceId) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    unawaited(refresh(syncMetadata: true, checkUpdates: true));
  }

  /// Reload local content list; optionally sync Modrinth/CF metadata.
  Future<void> refresh({
    bool syncMetadata = false,
    bool checkUpdates = false,
  }) =>
      _refreshContent(
        syncMetadata: syncMetadata,
        checkUpdates: checkUpdates,
      );

  @override
  Widget build(BuildContext context) {
    return _buildMods(context.tokens);
  }

  Future<void> _refreshContent({
    bool syncMetadata = false,
    bool checkUpdates = false,
  }) async {
    final showSpinner = _mods.isEmpty;
    if (showSpinner && mounted) {
      setState(() => _contentLoading = true);
    }
    try {
      // Fast path: local files + cached DB metadata.
      final mods = await rust.listInstanceMods(instanceId: widget.instanceId);
      if (!mounted) return;
      setState(() {
        _mods = mods;
        _contentLoading = false;
      });

      if (!syncMetadata) return;
      // Don't stack syncs — overlapping full syncs leave "同步中" stuck.
      if (_contentSyncing) return;
      unawaited(_syncContentMetadata(checkUpdates: checkUpdates));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _contentLoading = false;
        _contentSyncing = false;
      });
    }
  }

  Future<void> _syncContentMetadata({required bool checkUpdates}) async {
    final gen = ++_contentSyncGen;
    if (mounted) setState(() => _contentSyncing = true);
    try {
      await rust
          .syncInstanceContentMetadata(
            instanceId: widget.instanceId,
            checkUpdates: checkUpdates,
          )
          .timeout(Duration(seconds: checkUpdates ? 90 : 45));
      if (!mounted || gen != _contentSyncGen) return;
      final refreshed =
          await rust.listInstanceMods(instanceId: widget.instanceId);
      if (!mounted || gen != _contentSyncGen) return;
      setState(() {
        _mods = refreshed;
        _contentSyncedOnce = true;
      });
    } catch (e) {
      debugPrint('content metadata sync failed: $e');
    } finally {
      if (mounted && gen == _contentSyncGen) {
        setState(() => _contentSyncing = false);
      }
    }
  }

  List<rust.ModFileDto> get _filteredMods {
    var list = _mods.toList();
    if (_contentFilter == 'updates') {
      list = list.where((m) => m.hasUpdate).toList();
    } else if (_contentFilter != 'all') {
      list = list.where((m) => m.projectType == _contentFilter).toList();
    }
    final q = _contentQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list.where((m) {
        final title = (m.projectTitle ?? m.name).toLowerCase();
        final author = (m.author ?? '').toLowerCase();
        return title.contains(q) ||
            m.name.toLowerCase().contains(q) ||
            author.contains(q) ||
            (m.versionNumber?.toLowerCase().contains(q) ?? false);
      }).toList();
    }
    list.sort((a, b) {
      final ta = (a.projectTitle ?? a.name).toLowerCase();
      final tb = (b.projectTitle ?? b.name).toLowerCase();
      return ta.compareTo(tb);
    });
    return list;
  }

  int get _updateCount => _mods.where((m) => m.hasUpdate).length;

  Set<String> get _presentTypes =>
      _mods.map((m) => m.projectType).where((t) => t.isNotEmpty).toSet();

  Widget _buildMods(tokens) {
    final filtered = _filteredMods;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _contentQuery = v),
                style: TextStyle(color: tokens.colorContrast),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索到 ${filtered.length} 个项目……',
                  hintStyle: TextStyle(
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                  filled: true,
                  fillColor: tokens.colorRaisedBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 10),
            ElevatedButton.icon(
              onPressed: () => getIt<NavigationState>()
                  .browseContentForInstance(widget.instanceId),
              style: ElevatedButton.styleFrom(
                backgroundColor: tokens.colorBrand,
                foregroundColor: tokens.colorOnBrand,
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 12,
                ),
              ),
              icon: const Icon(Icons.explore_outlined, size: 18),
              label: const Text('浏览内容'),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Icon(Icons.filter_list, size: 18, color: tokens.colorBase),
            const SizedBox(width: 8),
            _filterChip(tokens, 'all', '全部'),
            for (final t in ['mod', 'resourcepack', 'shader', 'datapack'])
              if (_presentTypes.contains(t) || _contentFilter == t)
                Padding(
                  padding: const EdgeInsets.only(left: 6),
                  child: _filterChip(tokens, t, contentTypeLabel(t)),
                ),
            if (_updateCount > 0)
              Padding(
                padding: const EdgeInsets.only(left: 6),
                child: _filterChip(tokens, 'updates', '更新 ($_updateCount)'),
              ),
            const Spacer(),
            if (_updateCount > 0)
              TextButton(
                onPressed: _busy ? null : _updateAllContent,
                style: TextButton.styleFrom(foregroundColor: tokens.colorBrand),
                child: const Text('更新全部'),
              ),
            if (_contentSyncing)
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: tokens.colorBrand,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '同步中',
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.colorBase.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
            TextButton.icon(
              onPressed: _contentSyncing
                  ? null
                  : () => _refreshContent(
                        syncMetadata: true,
                        checkUpdates: true,
                      ),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_contentLoading)
          const Expanded(
            child: Center(child: CircularProgressIndicator()),
          )
        else if (_mods.isEmpty)
          Expanded(
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    '还没有内容',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '从 Modrinth 浏览并安装模组、资源包等内容',
                    style: TextStyle(
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 16),
                  NavRectButton(
                    isSelected: true,
                    icon: Icons.explore_outlined,
                    text: '浏览内容',
                    selectedBackgroundColor: tokens.colorBrand,
                    selectedColor: tokens.colorOnBrand,
                    onTap: () => getIt<NavigationState>()
                        .browseContentForInstance(widget.instanceId),
                  ),
                ],
              ),
            ),
          )
        else ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
            child: Row(
              children: [
                Expanded(
                  flex: 5,
                  child: Text(
                    '项目',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: tokens.colorBase.withValues(alpha: 0.75),
                    ),
                  ),
                ),
                Expanded(
                  flex: 4,
                  child: Text(
                    '版本',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: tokens.colorBase.withValues(alpha: 0.75),
                    ),
                  ),
                ),
                SizedBox(
                  width: 168,
                  child: Text(
                    '操作',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: tokens.colorBase.withValues(alpha: 0.75),
                    ),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      '没有匹配的内容',
                      style: TextStyle(color: tokens.colorBase),
                    ),
                  )
                : ListView.separated(
                    itemCount: filtered.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 6),
                    itemBuilder: (context, index) {
                      return _contentRow(tokens, filtered[index]);
                    },
                  ),
          ),
        ],
      ],
    );
  }

  Widget _filterChip(tokens, String id, String label) {
    final selected = _contentFilter == id;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (_) => setState(() => _contentFilter = id),
      selectedColor: tokens.colorBrandHighlight,
      checkmarkColor: tokens.colorBrand,
      labelStyle: TextStyle(
        fontWeight: FontWeight.w700,
        fontSize: 12,
        color: selected ? tokens.colorBrand : tokens.colorContrast,
      ),
      visualDensity: VisualDensity.compact,
    );
  }

  Widget _contentRow(tokens, rust.ModFileDto mod) {
    final title =
        mod.projectTitle?.isNotEmpty == true ? mod.projectTitle! : mod.name;
    final versionNumber = mod.versionNumber ?? mod.versionName;
    final fileName = mod.name;
    final author = mod.author;
    final canOpenProject = mod.projectId != null && mod.projectId!.isNotEmpty;
    final canOpenAuthor =
        mod.authorId != null && mod.authorId!.trim().isNotEmpty;
    final canSwitch = canOpenProject;

    void openProject() {
      if (canOpenProject) {
        getIt<NavigationState>().openProject(mod.projectId!);
      } else {
        _showContentDetail(mod);
      }
    }

    void openAuthor() {
      final id = mod.authorId?.trim();
      if (id == null || id.isEmpty) return;
      final kind = (mod.authorType ?? 'user').toLowerCase() == 'organization'
          ? 'organization'
          : 'user';
      getIt<NavigationState>().openAuthor(
        id,
        type: kind,
        preview: AuthorPreview(
          id: id,
          type: kind,
          displayName: author ?? id,
          avatarUrl: mod.authorAvatarUrl,
        ),
      );
    }

    return Material(
      color: tokens.colorRaisedBg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: openProject,
        hoverColor: tokens.colorSuperRaisedBg.withValues(alpha: 0.65),
        splashColor: tokens.colorBrand.withValues(alpha: 0.12),
        highlightColor: tokens.colorBrand.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    mod.projectIconUrl != null && mod.projectIconUrl!.isNotEmpty
                        ? CachedRemoteImage(
                            url: mod.projectIconUrl!,
                            width: 40,
                            height: 40,
                            borderRadius: BorderRadius.circular(8),
                            placeholder: _iconFallback(tokens),
                            error: _iconFallback(tokens),
                          )
                        : _iconFallback(tokens),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: tokens.colorContrast,
                              decoration: mod.enabled
                                  ? null
                                  : TextDecoration.lineThrough,
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (author != null && author.isNotEmpty)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: canOpenAuthor ? openAuthor : null,
                              child: MouseRegion(
                                cursor: canOpenAuthor
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.basic,
                                child: Row(
                                  children: [
                                    if (mod.authorAvatarUrl != null &&
                                        mod.authorAvatarUrl!.isNotEmpty)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: CachedRemoteImage(
                                          url: mod.authorAvatarUrl!,
                                          width: 14,
                                          height: 14,
                                          borderRadius:
                                              BorderRadius.circular(7),
                                          placeholder: const SizedBox.shrink(),
                                          error: const SizedBox.shrink(),
                                        ),
                                      ),
                                    Flexible(
                                      child: Text(
                                        author,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: tokens.colorBase
                                              .withValues(alpha: 0.7),
                                          decoration: canOpenAuthor
                                              ? TextDecoration.underline
                                              : null,
                                          decorationColor: tokens.colorBase
                                              .withValues(alpha: 0.35),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Text(
                              mod.projectId == null
                                  ? '本地文件 · ${contentTypeLabel(mod.projectType)}'
                                  : '${sourceLabel(contentSourceOf(projectId: mod.projectId))} · ${contentTypeLabel(mod.projectType)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: tokens.colorBase.withValues(alpha: 0.65),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                // Absorb taps so version area does not open project; switch via button only.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        versionNumber ?? '未知版本',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                      Text(
                        [
                          if (mod.projectId != null)
                            sourceLabel(
                              contentSourceOf(projectId: mod.projectId),
                            ),
                          fileName,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.colorBase.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: 168,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (mod.hasUpdate)
                      IconButton(
                        tooltip: '更新',
                        onPressed: _busy ? null : () => _updateContent(mod),
                        icon: _updatingContentPaths.contains(mod.relativePath)
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: tokens.colorBrand,
                                ),
                              )
                            : Icon(
                                Icons.download_rounded,
                                color: tokens.colorBrand,
                              ),
                      )
                    else if (canSwitch)
                      IconButton(
                        tooltip: '切换版本',
                        onPressed:
                            _busy ? null : () => _switchContentVersion(mod),
                        icon: Icon(
                          Icons.swap_horiz_rounded,
                          color: tokens.colorBase.withValues(alpha: 0.85),
                        ),
                      ),
                    Switch(
                      value: mod.enabled,
                      activeThumbColor: tokens.colorOnBrand,
                      activeTrackColor: tokens.colorBrand,
                      onChanged: (v) async {
                        try {
                          await rust.setModEnabled(
                            instanceId: widget.instanceId,
                            relativePath: mod.relativePath,
                            enabled: v,
                          );
                          await _refreshContent(syncMetadata: false);
                        } catch (e) {
                          if (!mounted) return;
                          showAppSnackBar('$e', isError: true);
                        }
                      },
                    ),
                    IconButton(
                      tooltip: '删除',
                      icon: Icon(
                        Icons.delete_outline,
                        color: tokens.colorBase.withValues(alpha: 0.85),
                      ),
                      onPressed: () => _confirmDelete(mod),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _installContentVersion({
    required rust.ModFileDto mod,
    required String versionId,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装 ${mod.projectTitle ?? mod.name}',
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    try {
      final projectId = mod.projectId;
      final isCf = projectId != null && isCurseForgeProjectId(projectId);
      if (isCf) {
        final modId = parseCurseForgeModId(projectId);
        final fileId = int.tryParse(versionId);
        if (modId == null || fileId == null) {
          throw StateError('无效的 CurseForge 版本');
        }
        await _store.installCurseforgeFile(
          instanceId: widget.instanceId,
          modId: modId,
          fileId: fileId,
          projectType: mod.projectType,
        );
      } else {
        await rust.installModrinthVersion(
          instanceId: widget.instanceId,
          versionId: versionId,
          projectType: mod.projectType,
          installDeps: true,
          onProgress: (p, msg) async {
            progress.setProgress(p, msg);
          },
        );
      }
    } finally {
      progress.dispose();
    }
  }

  Future<void> _updateContent(rust.ModFileDto mod) async {
    final versionId = mod.updateVersionId;
    if (versionId == null || versionId.isEmpty) return;
    setState(() {
      _busy = true;
      _updatingContentPaths = {mod.relativePath};
    });
    _store.beginInstanceOperation(widget.instanceId, '更新内容中…');
    try {
      await _installContentVersion(mod: mod, versionId: versionId);
      // Install already wrote DB metadata; skip full sync (was sticking on 同步中).
      await _refreshContent(syncMetadata: false);
      await _store.refresh();
      if (mounted) showAppSnackBar('已更新 ${mod.projectTitle ?? mod.name}');
    } catch (e) {
      if (mounted) showAppSnackBar('更新失败: $e', isError: true);
    } finally {
      _store.endInstanceOperation(widget.instanceId);
      if (mounted) {
        setState(() {
          _busy = false;
          _updatingContentPaths = {};
        });
      }
    }
  }

  Future<void> _updateAllContent() async {
    final pending = _mods.where((m) => m.hasUpdate).toList();
    if (pending.isEmpty) return;
    setState(() {
      _busy = true;
      _updatingContentPaths = {
        for (final mod in pending) mod.relativePath,
      };
    });
    _store.beginInstanceOperation(widget.instanceId, '更新全部内容中…');
    var ok = 0;
    var fail = 0;
    try {
      for (final mod in pending) {
        final versionId = mod.updateVersionId;
        if (versionId == null) continue;
        try {
          await _installContentVersion(mod: mod, versionId: versionId);
          ok++;
        } catch (_) {
          fail++;
        }
      }
      await _refreshContent(syncMetadata: false);
      await _store.refresh();
      if (mounted) {
        showAppSnackBar(
          fail == 0 ? '已更新 $ok 个项目' : '更新完成：成功 $ok，失败 $fail',
          isError: fail > 0,
        );
      }
    } finally {
      _store.endInstanceOperation(widget.instanceId);
      if (mounted) {
        setState(() {
          _busy = false;
          _updatingContentPaths = {};
        });
      }
    }
  }

  Future<void> _switchContentVersion(rust.ModFileDto mod) async {
    final projectId = mod.projectId;
    if (projectId == null || projectId.isEmpty) return;
    final instance = _instance;
    if (instance == null) return;
    final isCf = isCurseForgeProjectId(projectId);
    final cfModId = parseCurseForgeModId(projectId);

    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (_) => const Center(child: CircularProgressIndicator()),
    );
    List<ModrinthVersionInfo> versions;
    try {
      if (isCf && cfModId != null) {
        versions = await CurseForgeApiService.getProjectVersionsAsModrinth(
          cfModId,
          gameVersion: instance.gameVersion,
          loader: instance.loader.toLowerCase() == 'vanilla'
              ? null
              : instance.loader,
        );
      } else {
        versions = await ModrinthApiService.getProjectVersions(
          projectId,
          gameVersion: instance.gameVersion,
          loader: instance.loader.toLowerCase() == 'vanilla'
              ? null
              : instance.loader,
        );
      }
    } catch (e) {
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
      if (mounted) showAppSnackBar('加载版本失败: $e', isError: true);
      return;
    }
    if (!mounted) return;
    Navigator.of(context, rootNavigator: true).pop();

    if (versions.isEmpty) {
      showAppSnackBar('没有兼容的版本', isError: true);
      return;
    }

    final selected = await showModalBottomSheet<ModrinthVersionInfo>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.tokens.colorRaisedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        final tokens = ctx.tokens;
        final source = sourceLabel(contentSourceOf(projectId: projectId));
        return SafeArea(
          child: SizedBox(
            height: MediaQuery.of(ctx).size.height * 0.6,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    '切换版本 · $source · ${mod.projectTitle ?? mod.name}',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w800,
                      color: tokens.colorContrast,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.separated(
                    itemCount: versions.length,
                    separatorBuilder: (_, __) => Divider(
                      height: 1,
                      color: tokens.colorSecondary.withValues(alpha: 0.25),
                    ),
                    itemBuilder: (context, index) {
                      final v = versions[index];
                      final current = v.id == mod.versionId;
                      return ListTile(
                        selected: current,
                        title: Text(
                          v.versionNumber.isNotEmpty ? v.versionNumber : v.name,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorContrast,
                          ),
                        ),
                        subtitle: Text(
                          '${v.versionType} · ${v.loaders.join(", ")}'
                          '${current ? " · 当前" : ""}',
                          style: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                        ),
                        trailing: current
                            ? Icon(Icons.check, color: tokens.colorBrand)
                            : null,
                        onTap: current ? null : () => Navigator.pop(ctx, v),
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
    if (selected == null || !mounted) return;

    setState(() {
      _busy = true;
    });
    try {
      await _installContentVersion(mod: mod, versionId: selected.id);
      await _refreshContent(syncMetadata: false);
      if (mounted) {
        showAppSnackBar(
          '已切换到 ${selected.versionNumber.isNotEmpty ? selected.versionNumber : selected.name}',
        );
      }
    } catch (e) {
      if (mounted) showAppSnackBar('切换版本失败: $e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Widget _iconFallback(tokens) {
    return Container(
      width: 40,
      height: 40,
      color: tokens.colorSuperRaisedBg,
      child: Icon(Icons.extension, color: tokens.colorContrast),
    );
  }

  Future<void> _confirmDelete(rust.ModFileDto mod) async {
    final title = mod.projectTitle ?? mod.name;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除内容'),
        content: Text('确定删除 $title？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: AppDialogActions.destructive(ctx),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    try {
      await _store.removeMod(
        instanceId: widget.instanceId,
        relativePath: mod.relativePath,
      );
      await _refreshContent(syncMetadata: false);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    }
  }

  void _showContentDetail(rust.ModFileDto mod) {
    final tokens = context.tokens;
    final title =
        mod.projectTitle?.isNotEmpty == true ? mod.projectTitle! : mod.name;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: tokens.colorRaisedBg,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (ctx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  if (mod.projectIconUrl != null &&
                      mod.projectIconUrl!.isNotEmpty)
                    CachedRemoteImage(
                      url: mod.projectIconUrl!,
                      width: 48,
                      height: 48,
                      borderRadius: BorderRadius.circular(10),
                      placeholder: Icon(
                        Icons.extension,
                        size: 48,
                        color: tokens.colorContrast,
                      ),
                      error: Icon(
                        Icons.extension,
                        size: 48,
                        color: tokens.colorContrast,
                      ),
                    )
                  else
                    Icon(Icons.extension,
                        size: 48, color: tokens.colorContrast),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                            color: tokens.colorContrast,
                          ),
                        ),
                        Text(
                          mod.projectType,
                          style: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              _detailRow(tokens, '文件', mod.name),
              _detailRow(tokens, '路径', mod.relativePath),
              if (mod.versionNumber != null)
                _detailRow(tokens, '版本号', mod.versionNumber!),
              if (mod.versionName != null)
                _detailRow(tokens, '版本名', mod.versionName!),
              if (mod.versionId != null)
                _detailRow(tokens, 'Version ID', mod.versionId!),
              if (mod.projectId != null) ...[
                _detailRow(tokens, 'Project ID', mod.projectId!),
                _detailRow(
                  tokens,
                  '来源',
                  sourceLabel(contentSourceOf(projectId: mod.projectId)),
                ),
              ],
              _detailRow(
                tokens,
                '大小',
                '${(mod.sizeBytes.toDouble() / 1024).toStringAsFixed(1)} KB',
              ),
              _detailRow(tokens, '状态', mod.enabled ? '已启用' : '已禁用'),
              if (mod.projectId != null) ...[
                const SizedBox(height: 12),
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tokens.colorBrand,
                      foregroundColor: tokens.colorOnBrand,
                      elevation: 0,
                    ),
                    onPressed: () {
                      Navigator.pop(ctx);
                      getIt<NavigationState>().openProject(mod.projectId!);
                    },
                    child: const Text('查看详情'),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }

  Widget _detailRow(tokens, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 88,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              style: TextStyle(color: tokens.colorContrast),
            ),
          ),
        ],
      ),
    );
  }
}
