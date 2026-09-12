import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/instance_settings_page.dart';
import 'package:aml/src/features/instances/ui/create_new_instance.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/relative_time.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/search_bar.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';

enum _LibraryTab { all, modpacks, servers, custom }

enum _SortBy { name, gameVersion, lastPlayed, created }

enum _GroupBy { none, loader, gameVersion, libraryGroup }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  late _LibraryTab _tab;
  late _SortBy _sortBy;
  late _GroupBy _groupBy;
  String _search = '';
  late final Set<String> _collapsed;

  InstanceStore get _store => getIt<InstanceStore>();
  UiSettingsState get _ui => getIt<UiSettingsState>();

  @override
  void initState() {
    super.initState();
    _tab = _parseTab(_ui.libraryTab.value);
    _sortBy = _parseSortBy(_ui.librarySortBy.value);
    _groupBy = _parseGroupBy(_ui.libraryGroupBy.value);
    _collapsed = {..._ui.libraryCollapsedGroups.value};
  }

  _LibraryTab _parseTab(String raw) {
    for (final v in _LibraryTab.values) {
      if (v.name == raw) return v;
    }
    return _LibraryTab.all;
  }

  _SortBy _parseSortBy(String raw) {
    for (final v in _SortBy.values) {
      if (v.name == raw) return v;
    }
    return _SortBy.name;
  }

  _GroupBy _parseGroupBy(String raw) {
    for (final v in _GroupBy.values) {
      if (v.name == raw) return v;
    }
    return _GroupBy.none;
  }

  void _setTab(_LibraryTab value) {
    if (_tab == value) return;
    setState(() => _tab = value);
    _ui.setLibraryTab(value.name);
  }

  void _setSortBy(_SortBy value) {
    if (_sortBy == value) return;
    setState(() => _sortBy = value);
    _ui.setLibrarySortBy(value.name);
  }

  void _setGroupBy(_GroupBy value) {
    if (_groupBy == value) return;
    setState(() => _groupBy = value);
    _ui.setLibraryGroupBy(value.name);
  }

  void _toggleCollapsed(String title) {
    setState(() {
      if (_collapsed.contains(title)) {
        _collapsed.remove(title);
      } else {
        _collapsed.add(title);
      }
    });
    _ui.setLibraryCollapsedGroups(_collapsed);
  }

  List<rust.InstanceDto> _filterByTab(List<rust.InstanceDto> all) {
    switch (_tab) {
      case _LibraryTab.all:
        return all;
      case _LibraryTab.custom:
        return all
            .where(
              (i) => i.modpackSource == null || i.modpackSource!.isEmpty,
            )
            .toList();
      case _LibraryTab.modpacks:
        return all
            .where(
              (i) => i.modpackSource != null && i.modpackSource!.isNotEmpty,
            )
            .toList();
      case _LibraryTab.servers:
        return const [];
    }
  }

  List<rust.InstanceDto> _applySearchSort(List<rust.InstanceDto> input) {
    final q = _search.trim().toLowerCase();
    final list = input
        .where((i) => q.isEmpty || i.name.toLowerCase().contains(q))
        .toList();

    switch (_sortBy) {
      case _SortBy.name:
        list.sort(
          (a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()),
        );
      case _SortBy.gameVersion:
        list.sort((a, b) => _compareVersion(a.gameVersion, b.gameVersion));
      case _SortBy.lastPlayed:
        list.sort((a, b) {
          final ak = a.lastPlayed ?? '';
          final bk = b.lastPlayed ?? '';
          return bk.compareTo(ak);
        });
      case _SortBy.created:
        list.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    }
    return list;
  }

  int _compareVersion(String a, String b) {
    final ap = a.split(RegExp(r'[^0-9]+')).where((e) => e.isNotEmpty).toList();
    final bp = b.split(RegExp(r'[^0-9]+')).where((e) => e.isNotEmpty).toList();
    final n = ap.length > bp.length ? ap.length : bp.length;
    for (var i = 0; i < n; i++) {
      final av = i < ap.length ? int.tryParse(ap[i]) ?? 0 : 0;
      final bv = i < bp.length ? int.tryParse(bp[i]) ?? 0 : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return a.compareTo(b);
  }

  Map<String, List<rust.InstanceDto>> _group(List<rust.InstanceDto> list) {
    if (_groupBy == _GroupBy.none) {
      return {'': list};
    }
    final map = <String, List<rust.InstanceDto>>{};
    for (final instance in list) {
      if (_groupBy == _GroupBy.libraryGroup) {
        final groups = instance.groups;
        if (groups.isEmpty) {
          map.putIfAbsent('未分组', () => []).add(instance);
        } else {
          for (final group in groups) {
            map.putIfAbsent(group, () => []).add(instance);
          }
        }
        continue;
      }
      final key = _groupBy == _GroupBy.loader
          ? loaderLabel(instance.loader)
          : instance.gameVersion;
      map.putIfAbsent(key, () => []).add(instance);
    }
    final entries = map.entries.toList();
    if (_groupBy == _GroupBy.gameVersion) {
      entries.sort((a, b) => _compareVersion(a.key, b.key));
    } else {
      entries.sort((a, b) => a.key.compareTo(b.key));
    }
    return {for (final e in entries) e.key: e.value};
  }

  void _openCreate(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => const CreateNewInstance(),
      ),
    );
  }

  Future<void> _playOrStop(rust.InstanceDto instance) async {
    final store = _store;
    try {
      if (store.isRunning(instance.id)) {
        await store.kill(instance.id);
      } else {
        if (!await ensureAccountForLaunch(context)) return;
        await store.launch(instance.id);
      }
    } catch (e) {
      showAppSnackBar('操作失败: $e', isError: true);
    }
  }

  Future<void> _openInstanceFolder(rust.InstanceDto instance) async {
    try {
      final path = await _store.instanceFolderPath(instance.id);
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      showAppSnackBar('打开文件夹失败: $e', isError: true);
    }
  }

  Future<void> _copyInstancePath(rust.InstanceDto instance) async {
    try {
      final path = await _store.instanceFolderPath(instance.id);
      await Clipboard.setData(ClipboardData(text: path));
      showAppSnackBar('实例路径已复制');
    } catch (e) {
      showAppSnackBar('复制路径失败: $e', isError: true);
    }
  }

  Future<void> _duplicateInstance(rust.InstanceDto instance) async {
    try {
      await _store.duplicate(instance.id);
    } catch (_) {
      // Errors are already surfaced by InstanceStore.duplicate.
    }
  }

  Future<void> _renameInstance(rust.InstanceDto instance) async {
    if (_store.isRunning(instance.id)) {
      showAppSnackBar('实例正在运行，请先停止后再重命名', isError: true);
      return;
    }
    final controller = TextEditingController(text: instance.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('重命名实例'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: '名称',
              helperText: '不可使用 \\ / : * ? " < > |',
            ),
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'[\\/:*?"<>|]')),
            ],
            onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == instance.name) return;
    try {
      final updated =
          await _store.updateSettings(id: instance.id, name: newName);
      showAppSnackBar('已重命名为「${updated.name}」');
    } catch (e) {
      showAppSnackBar('重命名失败: $e', isError: true);
    }
  }

  Future<void> _confirmDeleteInstance(rust.InstanceDto instance) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除实例'),
        content: Text('确定删除「${instance.name}」？\n此操作不可撤销。'),
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
      if (getIt<NavigationState>().selectedInstanceId.value == instance.id) {
        getIt<NavigationState>().closeInstance();
      }
      await _store.remove(instance.id);
      showAppSnackBar('已删除「${instance.name}」');
    } catch (e) {
      showAppSnackBar('删除失败: $e', isError: true);
    }
  }

  Future<void> _showInstanceContextMenu(
    Offset globalPosition,
    rust.InstanceDto instance,
  ) async {
    final running = _store.isRunning(instance.id);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'play',
          child: _contextMenuRow(
            icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
            label: running ? '停止' : '启动',
          ),
        ),
        if (_store.isInstallFailed(instance.id))
          PopupMenuItem(
            value: 'retry_install',
            child: _contextMenuRow(
              icon: Icons.refresh,
              label: '重试安装',
            ),
          ),
        PopupMenuItem(
          value: 'add_content',
          child: _contextMenuRow(
            icon: Icons.add,
            label: '添加内容',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'view',
          child: _contextMenuRow(
            icon: Icons.visibility_outlined,
            label: '查看实例',
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: _contextMenuRow(
            icon: Icons.settings_outlined,
            label: '设置',
          ),
        ),
        PopupMenuItem(
          value: 'rename',
          child: _contextMenuRow(
            icon: Icons.edit_outlined,
            label: '重命名',
          ),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: _contextMenuRow(
            icon: Icons.copy_all_outlined,
            label: '复制实例',
          ),
        ),
        PopupMenuItem(
          value: 'open_folder',
          child: _contextMenuRow(
            icon: Icons.folder_outlined,
            label: '打开文件夹',
          ),
        ),
        PopupMenuItem(
          value: 'shortcut',
          child: _contextMenuRow(
            icon: Icons.shortcut_outlined,
            label: '创建桌面快捷方式',
          ),
        ),
        PopupMenuItem(
          value: 'shortcut_save_as',
          child: _contextMenuRow(
            icon: Icons.save_as_outlined,
            label: '另存为快捷方式…',
          ),
        ),
        PopupMenuItem(
          value: 'copy_path',
          child: _contextMenuRow(
            icon: Icons.content_copy_outlined,
            label: '复制路径',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: _contextMenuRow(
            icon: Icons.delete_outline,
            label: '删除',
            destructive: true,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'play':
        await _playOrStop(instance);
      case 'retry_install':
        try {
          await _store.install(instance.id, force: true);
        } catch (e) {
          showAppSnackBar('重试安装失败: $e', isError: true);
        }
      case 'add_content':
        getIt<NavigationState>().browseContentForInstance(instance.id);
      case 'view':
        getIt<NavigationState>().openInstance(instance.id);
      case 'settings':
        await showInstanceSettingsDialog(
          context: context,
          instanceId: instance.id,
        );
      case 'rename':
        await _renameInstance(instance);
      case 'duplicate':
        await _duplicateInstance(instance);
      case 'open_folder':
        await _openInstanceFolder(instance);
      case 'shortcut':
        await createAmlDesktopShortcut(
          displayName: instance.name,
          instanceId: instance.id,
          instanceIconPath: instance.icon,
        );
      case 'shortcut_save_as':
        await createAmlDesktopShortcut(
          displayName: instance.name,
          instanceId: instance.id,
          instanceIconPath: instance.icon,
          saveAs: true,
        );
      case 'copy_path':
        await _copyInstancePath(instance);
      case 'delete':
        await _confirmDeleteInstance(instance);
    }
  }

  Widget _contextMenuRow({
    required IconData icon,
    required String label,
    bool destructive = false,
  }) {
    final color = destructive ? const Color(0xFFB3261E) : null;
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return Watch((context) {
      final all = _store.instances.value;
      // Subscribe so cards rebuild while installs / runs change.
      final installing = _store.installingIds.value;
      final operations = _store.instanceOperations.value;
      final running = _store.runningIds.value;
      final filtered = _applySearchSort(_filterByTab(all));
      final grouped = _group(filtered);
      final _ = (installing, operations, running);

      return Padding(
        padding: const EdgeInsets.fromLTRB(22, 16, 22, 22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                _tabChip('全部实例', _LibraryTab.all),
                // Modpack/server tabs hidden until instance links are tracked —
                // showing empty lists would mislead users into thinking installs vanished.
                _tabChip('自定义', _LibraryTab.custom),
              ],
            ),
            const SizedBox(height: 14),
            if (all.isEmpty)
              Expanded(child: _emptyState(context, create: true))
            else ...[
              Row(
                children: [
                  Expanded(
                    child: SearchBarWidget(
                      prefixIcon: const Icon(Icons.search),
                      colorScheme: colorScheme,
                      onChanged: (v) => setState(() => _search = v),
                    ),
                  ),
                  const SizedBox(width: 12),
                  DropdownButtonWidget(
                    width: 160,
                    height: 48,
                    colorScheme: colorScheme,
                    prefix: '排序: ',
                    selectedValue: _sortBy.name,
                    items: const [
                      DropdownItem(display: '名称', value: 'name'),
                      DropdownItem(display: '游戏版本', value: 'gameVersion'),
                      DropdownItem(display: '最近游玩', value: 'lastPlayed'),
                      DropdownItem(display: '创建时间', value: 'created'),
                    ],
                    onChanged: (v) => _setSortBy(_SortBy.values.byName(v)),
                  ),
                  const SizedBox(width: 8),
                  DropdownButtonWidget(
                    width: 160,
                    height: 48,
                    colorScheme: colorScheme,
                    prefix: '分组: ',
                    selectedValue: _groupBy.name,
                    items: const [
                      DropdownItem(display: '无', value: 'none'),
                      DropdownItem(display: '加载器', value: 'loader'),
                      DropdownItem(display: '游戏版本', value: 'gameVersion'),
                      DropdownItem(display: '库分组', value: 'libraryGroup'),
                    ],
                    onChanged: (v) => _setGroupBy(_GroupBy.values.byName(v)),
                  ),
                ],
              ),
              const SizedBox(height: 16),
              Expanded(
                child: filtered.isEmpty
                    ? _emptyState(
                        context,
                        create: (_tab == _LibraryTab.all ||
                                _tab == _LibraryTab.custom) &&
                            _search.trim().isEmpty,
                        clearSearch: _search.trim().isNotEmpty,
                        message: _search.trim().isNotEmpty
                            ? '没有匹配的实例'
                            : _tab == _LibraryTab.modpacks
                                ? '还没有关联整合包的实例'
                                : _tab == _LibraryTab.servers
                                    ? '服务器分类尚未就绪'
                                    : '没有匹配的实例',
                      )
                    : ListView(
                        children: [
                          for (final entry in grouped.entries) ...[
                            if (entry.key.isNotEmpty) ...[
                              _groupHeader(entry.key, entry.value.length),
                              if (!_collapsed.contains(entry.key))
                                _instanceGrid(entry.value),
                            ] else
                              _instanceGrid(entry.value),
                            const SizedBox(height: 12),
                          ],
                        ],
                      ),
              ),
            ],
          ],
        ),
      );
    });
  }

  Widget _tabChip(String label, _LibraryTab tab) {
    final tokens = context.tokens;
    final selected = _tab == tab;
    return NavRectButton(
      text: label,
      isSelected: selected,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      defaultBackgroundColor: tokens.colorRaisedBg,
      selectedBackgroundColor: tokens.colorBrand,
      selectedColor: tokens.colorOnBrand,
      onTap: () => _setTab(tab),
    );
  }

  Widget _groupHeader(String title, int count) {
    final tokens = context.tokens;
    final collapsed = _collapsed.contains(title);
    return InkWell(
      onTap: () => _toggleCollapsed(title),
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            Icon(
              collapsed ? Icons.chevron_right : Icons.expand_more,
              color: tokens.colorBase,
            ),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '$count',
              style: TextStyle(
                color: tokens.colorBase.withValues(alpha: 0.6),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _instanceGrid(List<rust.InstanceDto> instances) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final maxW = constraints.maxWidth;
        final columns = maxW > 1100
            ? 3
            : maxW > 720
                ? 2
                : 1;
        const gap = 10.0;
        final cardW = (maxW - gap * (columns - 1)) / columns;

        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: [
            for (final instance in instances)
              SizedBox(
                width: cardW,
                child: _InstanceCard(
                  instance: instance,
                  installing: _store.isInstalling(instance.id),
                  operationLabel: _store.operationFor(instance.id),
                  installFailed: _store.isInstallFailed(instance.id),
                  running: _store.isRunning(instance.id),
                  loaderLabel: instance.loader.toLowerCase() == 'vanilla'
                      ? instance.gameVersion
                      : '${loaderLabel(instance.loader)} ${instance.gameVersion}',
                  lastPlayedLabel: relativeAge(
                    instance.lastPlayed,
                    empty: '从未游玩',
                  ),
                  onTap: () =>
                      getIt<NavigationState>().openInstance(instance.id),
                  onPlayOrStop: () => _playOrStop(instance),
                  onRename: () => _renameInstance(instance),
                  onContextMenu: (pos) =>
                      _showInstanceContextMenu(pos, instance),
                ),
              ),
          ],
        );
      },
    );
  }

  Widget _emptyState(
    BuildContext context, {
    required bool create,
    String message = '还没有实例',
    bool clearSearch = false,
  }) {
    final tokens = context.tokens;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 72,
            color: tokens.colorBase.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          if (clearSearch && _search.trim().isNotEmpty) ...[
            const SizedBox(height: 16),
            NavRectButton(
              text: '清除搜索',
              icon: Icons.clear,
              isSelected: false,
              defaultBackgroundColor: tokens.colorButtonBg,
              defaultColor: tokens.colorContrast,
              hoverColor: tokens.colorButtonBgSelected,
              hoverTextColor: tokens.colorButtonTextSelected,
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              onTap: () => setState(() => _search = ''),
            ),
          ] else if (create) ...[
            const SizedBox(height: 8),
            Text(
              '创建一个实例，或先去发现整合包。',
              style: TextStyle(
                fontSize: 13,
                color: tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                NavRectButton(
                  text: '创建实例',
                  icon: Icons.add,
                  isSelected: true,
                  selectedBackgroundColor: tokens.colorBrand,
                  selectedColor: tokens.colorOnBrand,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  onTap: () => _openCreate(context),
                ),
                NavRectButton(
                  text: '发现整合包',
                  icon: Icons.explore_outlined,
                  isSelected: false,
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  onTap: () => getIt<NavigationState>().browseModpacks(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}

class _InstanceCard extends StatefulWidget {
  final rust.InstanceDto instance;
  final bool installing;
  final String? operationLabel;
  final bool installFailed;
  final bool running;
  final String loaderLabel;
  final String lastPlayedLabel;
  final VoidCallback onTap;
  final VoidCallback onPlayOrStop;
  final VoidCallback onRename;
  final void Function(Offset globalPosition) onContextMenu;

  const _InstanceCard({
    required this.instance,
    required this.installing,
    this.operationLabel,
    required this.installFailed,
    required this.running,
    required this.loaderLabel,
    required this.lastPlayedLabel,
    required this.onTap,
    required this.onPlayOrStop,
    required this.onRename,
    required this.onContextMenu,
  });

  @override
  State<_InstanceCard> createState() => _InstanceCardState();
}

class _InstanceCardState extends State<_InstanceCard> {
  bool _hover = false;
  final GlobalKey _moreKey = GlobalKey();

  void _openMoreMenu() {
    final box = _moreKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset(0, box.size.height));
    widget.onContextMenu(offset);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final installing = widget.installing;
    final operationLabel = widget.operationLabel;
    final operating = operationLabel != null;
    final failed = widget.installFailed;
    final running = widget.running;
    final busy = installing || operating;
    final dimIcon = busy || running;
    final subtitle = busy
        ? (operationLabel ?? '安装中…')
        : running
            ? '运行中'
            : '${widget.loaderLabel} · ${widget.lastPlayedLabel}';
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onSecondaryTapUp: (details) =>
            widget.onContextMenu(details.globalPosition),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: widget.onTap,
            borderRadius: BorderRadius.circular(14),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              height: 76,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color:
                    _hover ? tokens.colorSuperRaisedBg : tokens.colorRaisedBg,
                borderRadius: BorderRadius.circular(14),
                border: failed
                    ? Border.all(
                        color: const Color(0xFFB3261E).withValues(alpha: 0.55),
                      )
                    : null,
              ),
              child: Row(
                children: [
                  SizedBox(
                    width: 48,
                    height: 48,
                    child: Stack(
                      alignment: Alignment.center,
                      children: [
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: dimIcon ? 0.28 : (_hover ? 0.75 : 1),
                          child: AnimatedScale(
                            duration: const Duration(milliseconds: 150),
                            scale: busy ? 0.85 : 1,
                            child: InstanceIcon(
                              instanceId: widget.instance.id,
                              iconPath: widget.instance.icon,
                              size: 48,
                              borderRadius: 8,
                            ),
                          ),
                        ),
                        if (busy)
                          SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(
                              strokeWidth: 2.5,
                              color: tokens.colorBrand,
                            ),
                          )
                        else if (failed)
                          const Icon(
                            Icons.error_outline,
                            color: Color(0xFFB3261E),
                            size: 28,
                          )
                        else if (running || _hover)
                          Material(
                            color: running
                                ? const Color(0xFFB3261E)
                                : tokens.colorBrand,
                            shape: const CircleBorder(),
                            child: InkWell(
                              customBorder: const CircleBorder(),
                              onTap: busy
                                  ? null
                                  : () {
                                      widget.onPlayOrStop();
                                    },
                              child: SizedBox(
                                width: 32,
                                height: 32,
                                child: Icon(
                                  running
                                      ? Icons.stop_rounded
                                      : Icons.play_arrow_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Flexible(
                              child: Text(
                                widget.instance.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.w800,
                                  color: tokens.colorContrast,
                                ),
                              ),
                            ),
                            if (_hover) ...[
                              const SizedBox(width: 4),
                              InkWell(
                                onTap: widget.onRename,
                                borderRadius: BorderRadius.circular(6),
                                child: Padding(
                                  padding: const EdgeInsets.all(2),
                                  child: Icon(
                                    Icons.edit_outlined,
                                    size: 16,
                                    color: tokens.colorBase
                                        .withValues(alpha: 0.75),
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Icon(
                              busy
                                  ? Icons.downloading_outlined
                                  : running
                                      ? Icons.circle
                                      : Icons.sports_esports_outlined,
                              size: running && !busy ? 10 : 14,
                              color: running && !busy
                                  ? const Color(0xFF3BA55D)
                                  : tokens.colorBase.withValues(alpha: 0.7),
                            ),
                            const SizedBox(width: 4),
                            Expanded(
                              child: Text(
                                subtitle,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 13,
                                  color:
                                      tokens.colorBase.withValues(alpha: 0.7),
                                ),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                  InkWell(
                    key: _moreKey,
                    onTap: _openMoreMenu,
                    borderRadius: BorderRadius.circular(8),
                    child: Padding(
                      padding: const EdgeInsets.all(6),
                      child: Icon(
                        Icons.more_vert,
                        size: 20,
                        color: tokens.colorBase.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
