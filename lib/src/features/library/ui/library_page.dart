import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/create_new_instance.dart';
import 'package:aml/src/features/library/ui/library_empty_state.dart';
import 'package:aml/src/features/library/ui/library_instance_actions.dart';
import 'package:aml/src/features/library/ui/library_instance_card.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/relative_time.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/search_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

enum _LibraryTab { all, modpacks, servers, custom }

enum _SortBy { name, gameVersion, lastPlayed, created }

enum _GroupBy { none, loader, gameVersion, libraryGroup }

class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage>
    with LibraryInstanceActions<LibraryPage> {
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
              Expanded(
                child: LibraryEmptyState(
                  create: true,
                  onCreate: () => _openCreate(context),
                ),
              )
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
                    ? LibraryEmptyState(
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
                        onClearSearch: () => setState(() => _search = ''),
                        onCreate: () => _openCreate(context),
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
                child: LibraryInstanceCard(
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
                  onPlayOrStop: () => playOrStop(instance),
                  onRename: () => renameInstance(instance),
                  onContextMenu: (pos) =>
                      showInstanceContextMenu(pos, instance),
                ),
              ),
          ],
        );
      },
    );
  }
}
