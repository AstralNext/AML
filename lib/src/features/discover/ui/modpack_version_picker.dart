import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/inputs/filter_multi_select.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

/// Result of [ModpackVersionPicker.show].
class ModpackVersionPick {
  const ModpackVersionPick(this.version);

  final ModrinthVersionInfo version;
}

/// Modrinth-style version picker for installing / switching a modpack version.
class ModpackVersionPicker extends StatefulWidget {
  const ModpackVersionPicker({
    super.key,
    required this.projectId,
    required this.projectTitle,
    this.projectIconUrl,
    this.currentVersionId,
    this.initialVersions,
    this.switchMode = false,
  });

  final String projectId;
  final String projectTitle;
  final String? projectIconUrl;
  final String? currentVersionId;
  final List<ModrinthVersionInfo>? initialVersions;
  final bool switchMode;

  static Future<ModpackVersionPick?> show(
    BuildContext context, {
    required String projectId,
    required String projectTitle,
    String? projectIconUrl,
    String? currentVersionId,
    List<ModrinthVersionInfo>? versions,
    bool switchMode = false,
  }) {
    return Navigator.of(context).push<ModpackVersionPick>(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => ModpackVersionPicker(
          projectId: projectId,
          projectTitle: projectTitle,
          projectIconUrl: projectIconUrl,
          currentVersionId: currentVersionId,
          initialVersions: versions,
          switchMode: switchMode,
        ),
      ),
    );
  }

  @override
  State<ModpackVersionPicker> createState() => _ModpackVersionPickerState();
}

class _ModpackVersionPickerState extends State<ModpackVersionPicker>
    with SingleTickerProviderStateMixin {
  late final ModalMotion _motion;

  final _searchController = TextEditingController();
  List<ModrinthVersionInfo> _versions = [];
  ModrinthVersionInfo? _selected;
  bool _loading = true;
  String? _error;
  String _query = '';
  final Set<String> _selectedGameVersions = {};
  final Set<String> _selectedChannels = {};

  @override
  void initState() {
    super.initState();
    _motion = ModalMotion(this)..forward();
    _load();
  }

  @override
  void dispose() {
    _motion.dispose();
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _close([ModpackVersionPick? result]) async {
    await _motion.reverse();
    if (mounted) Navigator.of(context).pop(result);
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      List<ModrinthVersionInfo> list;
      if (widget.initialVersions != null) {
        list = widget.initialVersions!;
      } else if (isCurseForgeProjectId(widget.projectId)) {
        final modId = parseCurseForgeModId(widget.projectId);
        if (modId == null) throw Exception('无效的 CurseForge 项目');
        list = await CurseForgeApiService.getProjectVersionsAsModrinth(modId);
      } else {
        list = await ModrinthApiService.getProjectVersions(widget.projectId);
      }
      if (!mounted) return;
      ModrinthVersionInfo? selected;
      if (widget.currentVersionId != null) {
        for (final v in list) {
          if (v.id == widget.currentVersionId) {
            selected = v;
            break;
          }
        }
      }
      selected ??= list.isNotEmpty ? list.first : null;
      setState(() {
        _versions = list;
        _selected = selected;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = e.toString();
        _loading = false;
      });
    }
  }

  /// Game versions that appear on at least one pack version (optionally
  /// narrowed by the selected release channels).
  List<String> get _availableGameVersions {
    final set = <String>{};
    for (final v in _versions) {
      if (_selectedChannels.isNotEmpty &&
          !_selectedChannels.contains(v.versionType.toLowerCase())) {
        continue;
      }
      set.addAll(v.gameVersions);
    }
    final list = set.toList()
      ..sort((a, b) {
        final ar = isReleaseGameVersion(a);
        final br = isReleaseGameVersion(b);
        if (ar != br) return ar ? -1 : 1;
        return b.compareTo(a);
      });
    return list;
  }

  /// Channels that appear on at least one pack version (optionally narrowed
  /// by the selected game versions).
  List<String> get _availableChannels {
    final set = <String>{};
    for (final v in _versions) {
      if (_selectedGameVersions.isNotEmpty &&
          !_selectedGameVersions.any(v.gameVersions.contains)) {
        continue;
      }
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

  List<ModrinthVersionInfo> get _filtered {
    final q = _query.trim().toLowerCase();
    return _versions.where((v) {
      if (_selectedChannels.isNotEmpty &&
          !_selectedChannels.contains(v.versionType.toLowerCase())) {
        return false;
      }
      if (_selectedGameVersions.isNotEmpty &&
          !_selectedGameVersions.any(v.gameVersions.contains)) {
        return false;
      }
      if (q.isEmpty) return true;
      return v.versionNumber.toLowerCase().contains(q) ||
          v.name.toLowerCase().contains(q) ||
          v.gameVersions.any((g) => g.toLowerCase().contains(q)) ||
          v.loaders.any((l) => l.toLowerCase().contains(q));
    }).toList();
  }

  void _ensureSelectionInFiltered(List<ModrinthVersionInfo> filtered) {
    if (filtered.isEmpty) {
      _selected = null;
      return;
    }
    final currentId = _selected?.id;
    if (currentId != null && filtered.any((v) => v.id == currentId)) {
      return;
    }
    _selected = filtered.first;
  }

  void _updateFilters(VoidCallback update) {
    setState(() {
      update();
      // Drop selections that are no longer offered for the other filter.
      _selectedGameVersions.removeWhere(
        (v) => !_availableGameVersions.contains(v),
      );
      _selectedChannels.removeWhere(
        (c) => !_availableChannels.contains(c),
      );
      _ensureSelectionInFiltered(_filtered);
    });
  }

  Color _channelColor(String type) {
    return switch (type.toLowerCase()) {
      'release' => const Color(0xFF1BD96A),
      'beta' => const Color(0xFFFFA347),
      'alpha' => const Color(0xFFFF496E),
      _ => const Color(0xFF94A3B8),
    };
  }

  String _filterLabel(String name, Set<String> selected) {
    if (selected.isEmpty) return name;
    return '$name (${selected.length})';
  }

  String _channelLabel(String type) {
    return switch (type.toLowerCase()) {
      'release' => '正式版',
      'beta' => 'Beta',
      'alpha' => 'Alpha',
      _ => type,
    };
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.86;
    final filtered = _filtered;
    final selected = _selected;
    final isCurrent = selected != null &&
        widget.currentVersionId != null &&
        selected.id == widget.currentVersionId;

    return AnimatedModalDialog.fromMotion(
      motion: _motion,
      onClose: () => _close(),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 720,
          maxWidth: 860,
          maxHeight: maxH,
        ),
        child: Material(
          color: tokens.colorRaisedBg,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              SizedBox(
                height: 64,
                child: Row(
                  children: [
                    const SizedBox(width: 24),
                    Icon(
                      widget.switchMode
                          ? Icons.swap_horiz
                          : Icons.download_outlined,
                      color: tokens.colorBrand,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        widget.switchMode
                            ? '切换整合包版本'
                            : '选择整合包版本',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ),
                    CustomButton(
                      icon: Icons.close,
                      size: ButtonSize.medium,
                      backgroundColor: tokens.colorButtonBg.withAlpha(80),
                      onTap: () => _close(),
                    ),
                    const SizedBox(width: 18),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: tokens.colorSecondary.withAlpha(35),
              ),
              Expanded(
                child: _loading
                    ? const Center(
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : _error != null
                        ? Center(
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '加载版本失败',
                                    style: TextStyle(
                                      fontWeight: FontWeight.w700,
                                      color: tokens.colorContrast,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    _error!,
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: scheme.error,
                                      fontSize: 12,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  NavRectButton(
                                    text: '重试',
                                    icon: Icons.refresh,
                                    isSelected: true,
                                    onTap: _load,
                                  ),
                                ],
                              ),
                            ),
                          )
                        : Row(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              SizedBox(
                                width: 320,
                                child: Column(
                                  children: [
                                    Padding(
                                      padding: const EdgeInsets.fromLTRB(
                                        14,
                                        14,
                                        14,
                                        8,
                                      ),
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.stretch,
                                        children: [
                                          InputBarWidget(
                                            colorScheme: scheme,
                                            controller: _searchController,
                                            size: InputBarSize.medium,
                                            hintText: '搜索版本…',
                                            prefixIcon: Icon(
                                              Icons.search,
                                              size: 18,
                                              color: tokens.colorBase
                                                  .withValues(alpha: 0.6),
                                            ),
                                            onChanged: (v) => _updateFilters(
                                              () => _query = v,
                                            ),
                                          ),
                                          if (_availableGameVersions
                                                  .isNotEmpty ||
                                              _availableChannels
                                                  .isNotEmpty) ...[
                                            const SizedBox(height: 8),
                                            Row(
                                              children: [
                                                if (_availableGameVersions
                                                    .isNotEmpty)
                                                  Expanded(
                                                    child: FilterMultiSelect(
                                                      label: _filterLabel(
                                                        '游戏版本',
                                                        _selectedGameVersions,
                                                      ),
                                                      options: [
                                                        for (final v
                                                            in _availableGameVersions)
                                                          FilterMultiSelectOption(
                                                            value: v,
                                                            label: v,
                                                          ),
                                                      ],
                                                      selected:
                                                          _selectedGameVersions,
                                                      colorScheme: scheme,
                                                      expand: true,
                                                      searchable: true,
                                                      searchPlaceholder:
                                                          '搜索版本…',
                                                      dropdownMinWidth: 220,
                                                      maxHeight: 320,
                                                      onChanged: (next) =>
                                                          _updateFilters(() {
                                                        _selectedGameVersions
                                                          ..clear()
                                                          ..addAll(next);
                                                      }),
                                                    ),
                                                  ),
                                                if (_availableGameVersions
                                                        .isNotEmpty &&
                                                    _availableChannels
                                                        .isNotEmpty)
                                                  const SizedBox(width: 8),
                                                if (_availableChannels
                                                    .isNotEmpty)
                                                  Expanded(
                                                    child: FilterMultiSelect(
                                                      label: _filterLabel(
                                                        '通道',
                                                        _selectedChannels,
                                                      ),
                                                      options: [
                                                        for (final c
                                                            in _availableChannels)
                                                          FilterMultiSelectOption(
                                                            value: c,
                                                            label:
                                                                _channelLabel(
                                                              c,
                                                            ),
                                                          ),
                                                      ],
                                                      selected:
                                                          _selectedChannels,
                                                      colorScheme: scheme,
                                                      expand: true,
                                                      dropdownMinWidth: 160,
                                                      onChanged: (next) =>
                                                          _updateFilters(() {
                                                        _selectedChannels
                                                          ..clear()
                                                          ..addAll(next);
                                                      }),
                                                    ),
                                                  ),
                                              ],
                                            ),
                                          ],
                                        ],
                                      ),
                                    ),
                                    Expanded(
                                      child: filtered.isEmpty
                                          ? Center(
                                              child: Text(
                                                '没有匹配的版本',
                                                style: TextStyle(
                                                  color: tokens.colorBase
                                                      .withValues(alpha: 0.65),
                                                ),
                                              ),
                                            )
                                          : ListView.builder(
                                              padding:
                                                  const EdgeInsets.fromLTRB(
                                                10,
                                                0,
                                                10,
                                                12,
                                              ),
                                              itemCount: filtered.length,
                                              itemBuilder: (context, index) {
                                                final v = filtered[index];
                                                final selectedRow =
                                                    selected?.id == v.id;
                                                final current = widget
                                                            .currentVersionId !=
                                                        null &&
                                                    v.id ==
                                                        widget.currentVersionId;
                                                return Padding(
                                                  padding:
                                                      const EdgeInsets.only(
                                                    bottom: 4,
                                                  ),
                                                  child: Material(
                                                    color: selectedRow
                                                        ? tokens
                                                            .colorBrandHighlight
                                                        : Colors.transparent,
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                      12,
                                                    ),
                                                    child: InkWell(
                                                      borderRadius:
                                                          BorderRadius.circular(
                                                        12,
                                                      ),
                                                      onTap: () => setState(
                                                        () => _selected = v,
                                                      ),
                                                      child: Padding(
                                                        padding:
                                                            const EdgeInsets
                                                                .fromLTRB(
                                                          10,
                                                          10,
                                                          10,
                                                          10,
                                                        ),
                                                        child: Row(
                                                          children: [
                                                            Container(
                                                              width: 8,
                                                              height: 8,
                                                              decoration:
                                                                  BoxDecoration(
                                                                color:
                                                                    _channelColor(
                                                                  v.versionType,
                                                                ),
                                                                shape: BoxShape
                                                                    .circle,
                                                              ),
                                                            ),
                                                            const SizedBox(
                                                              width: 10,
                                                            ),
                                                            Expanded(
                                                              child: Column(
                                                                crossAxisAlignment:
                                                                    CrossAxisAlignment
                                                                        .start,
                                                                children: [
                                                                  Text(
                                                                    v.versionNumber
                                                                            .isNotEmpty
                                                                        ? v.versionNumber
                                                                        : v.name,
                                                                    maxLines: 1,
                                                                    overflow:
                                                                        TextOverflow
                                                                            .ellipsis,
                                                                    style:
                                                                        TextStyle(
                                                                      fontWeight:
                                                                          FontWeight
                                                                              .w700,
                                                                      color: tokens
                                                                          .colorContrast,
                                                                    ),
                                                                  ),
                                                                  Text(
                                                                    current
                                                                        ? '当前版本'
                                                                        : _channelLabel(
                                                                            v.versionType,
                                                                          ),
                                                                    style:
                                                                        TextStyle(
                                                                      fontSize:
                                                                          11,
                                                                      color: tokens
                                                                          .colorBase
                                                                          .withValues(
                                                                        alpha:
                                                                            0.65,
                                                                      ),
                                                                    ),
                                                                  ),
                                                                ],
                                                              ),
                                                            ),
                                                            if (current)
                                                              Icon(
                                                                Icons.check,
                                                                size: 18,
                                                                color: tokens
                                                                    .colorBrand,
                                                              ),
                                                          ],
                                                        ),
                                                      ),
                                                    ),
                                                  ),
                                                );
                                              },
                                            ),
                                    ),
                                  ],
                                ),
                              ),
                              VerticalDivider(
                                width: 1,
                                thickness: 1,
                                color: tokens.colorSecondary.withAlpha(35),
                              ),
                              Expanded(
                                child: selected == null
                                    ? Center(
                                        child: Text(
                                          '从左侧选择一个版本',
                                          style: TextStyle(
                                            color: tokens.colorBase
                                                .withValues(alpha: 0.65),
                                          ),
                                        ),
                                      )
                                    : _VersionDetail(
                                        version: selected,
                                        projectTitle: widget.projectTitle,
                                        channelLabel: _channelLabel(
                                          selected.versionType,
                                        ),
                                        channelColor: _channelColor(
                                          selected.versionType,
                                        ),
                                        isCurrent: isCurrent,
                                      ),
                              ),
                            ],
                          ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 10, 20, 18),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        widget.projectTitle,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    ),
                    NavRectButton(
                      text: '取消',
                      icon: Icons.close,
                      isSelected: false,
                      defaultBackgroundColor: tokens.colorButtonBg,
                      defaultColor: tokens.colorContrast,
                      hoverColor: tokens.colorButtonBgSelected,
                      hoverTextColor: tokens.colorButtonTextSelected,
                      onTap: () => _close(),
                    ),
                    const SizedBox(width: 10),
                    NavRectButton(
                      text: widget.switchMode
                          ? (isCurrent ? '已是当前版本' : '切换到此版本')
                          : '安装此版本',
                      icon: widget.switchMode
                          ? Icons.swap_horiz
                          : Icons.download_outlined,
                      isSelected: true,
                      onTap: (selected == null || isCurrent)
                          ? () {}
                          : () => _close(ModpackVersionPick(selected)),
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
}

class _VersionDetail extends StatelessWidget {
  const _VersionDetail({
    required this.version,
    required this.projectTitle,
    required this.channelLabel,
    required this.channelColor,
    required this.isCurrent,
  });

  final ModrinthVersionInfo version;
  final String projectTitle;
  final String channelLabel;
  final Color channelColor;
  final bool isCurrent;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final title = version.versionNumber.isNotEmpty
        ? version.versionNumber
        : version.name;
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(22, 18, 22, 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  title,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              if (isCurrent)
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: tokens.colorBrandHighlight,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    '当前',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: tokens.colorBrand,
                    ),
                  ),
                ),
            ],
          ),
          if (version.name.isNotEmpty && version.name != title) ...[
            const SizedBox(height: 6),
            Text(
              version.name,
              style: TextStyle(
                color: tokens.colorBase.withValues(alpha: 0.75),
              ),
            ),
          ],
          const SizedBox(height: 14),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              _chip(
                tokens,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: channelColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Text(channelLabel),
                  ],
                ),
              ),
              _chip(
                tokens,
                child: Text('${version.downloads} 次下载'),
              ),
              if (version.datePublished.isNotEmpty)
                _chip(
                  tokens,
                  child: Text(_shortDate(version.datePublished)),
                ),
            ],
          ),
          const SizedBox(height: 18),
          Text(
            '游戏版本',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final g in version.gameVersions.take(24))
                _chip(tokens, child: Text(g)),
              if (version.gameVersions.length > 24)
                _chip(
                  tokens,
                  child: Text('+${version.gameVersions.length - 24}'),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '加载器',
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: [
              for (final l in version.loaders)
                _chip(tokens, child: Text(l)),
              if (version.loaders.isEmpty)
                Text(
                  '无',
                  style: TextStyle(
                    color: tokens.colorBase.withValues(alpha: 0.6),
                  ),
                ),
            ],
          ),
          if (version.changelog.trim().isNotEmpty) ...[
            const SizedBox(height: 18),
            Text(
              '更新说明',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              version.changelog.trim(),
              style: TextStyle(
                height: 1.45,
                color: tokens.colorBase.withValues(alpha: 0.85),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _chip(AppThemeTokens tokens, {required Widget child}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: DefaultTextStyle(
        style: const TextStyle(
          fontFamily: 'MiSans',
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ).copyWith(
          color: tokens.colorContrast,
        ),
        child: child,
      ),
    );
  }

  String _shortDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
