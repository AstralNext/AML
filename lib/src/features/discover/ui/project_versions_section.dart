import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/common/pagination_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/filter_multi_select.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

/// 项目详情页「版本」标签页：游戏版本/通道筛选 + 分页版本列表。
/// 筛选状态由本组件持有；父层通过更换 key（项目或加载轮次变化）重置。
class ProjectVersionsSection extends StatefulWidget {
  const ProjectVersionsSection({
    super.key,
    required this.project,
    required this.versions,
    required this.installedVersionId,
    required this.installingVersionId,
    this.initialSelectedGameVersion,
    this.initialSelectedLoader,
    required this.onInstall,
    required this.colorScheme,
  });

  final ModrinthProjectDetail project;
  final List<ModrinthVersionInfo> versions;
  final String? installedVersionId;
  final String? installingVersionId;
  final String? initialSelectedGameVersion;
  final String? initialSelectedLoader;
  final void Function(String versionId) onInstall;
  final ColorScheme colorScheme;

  @override
  State<ProjectVersionsSection> createState() => _ProjectVersionsSectionState();
}

class _ProjectVersionsSectionState extends State<ProjectVersionsSection> {
  static const _pageSize = 20;

  final Set<String> _selectedGameVersions = {};
  final Set<String> _selectedChannels = {};
  final Set<String> _selectedLoaders = {};
  bool _showAllGameVersions = false;
  int _versionPage = 1;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialSelectedGameVersion;
    if (initial != null && initial.isNotEmpty) {
      _selectedGameVersions.add(initial);
      if (!_isReleaseGameVersion(initial)) {
        _showAllGameVersions = true;
      }
    }
    // 从实例进入时自动预选该实例的平台（加载器）。
    final initialLoader = widget.initialSelectedLoader;
    if (initialLoader != null && initialLoader.isNotEmpty) {
      final available = <String>{
        for (final v in widget.versions) ...v.loaders,
      };
      if (available.contains(initialLoader)) {
        _selectedLoaders.add(initialLoader);
      }
    }
  }

  /// Release-like game versions: `1.21.1`, `26.1.2`. Snapshots/pre/rc excluded.
  bool _isReleaseGameVersion(String version) {
    return RegExp(r'^\d+(\.\d+)+$').hasMatch(version);
  }

  List<String> get _allGameVersions {
    final set = <String>{};
    for (final v in widget.versions) {
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
    for (final v in widget.versions) {
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

  /// 出现在版本列表中的平台（Fabric / Forge / Iris …），固定展示顺序。
  List<String> get _availableLoaders {
    final set = <String>{};
    for (final v in widget.versions) {
      set.addAll(v.loaders);
    }
    const order = [
      'fabric',
      'quilt',
      'forge',
      'neoforge',
      'iris',
      'optifine',
      'minecraft',
      'datapack',
    ];
    final list = set.toList()
      ..sort((a, b) {
        final ai = order.indexOf(a);
        final bi = order.indexOf(b);
        return (ai < 0 ? 99 : ai).compareTo(bi < 0 ? 99 : bi);
      });
    return list;
  }

  List<ModrinthVersionInfo> get _filteredVersions {
    return widget.versions.where((v) {
      if (_selectedGameVersions.isNotEmpty &&
          !_selectedGameVersions.any(v.gameVersions.contains)) {
        return false;
      }
      if (_selectedChannels.isNotEmpty &&
          !_selectedChannels.contains(v.versionType.toLowerCase())) {
        return false;
      }
      if (_selectedLoaders.isNotEmpty &&
          !_selectedLoaders.any(v.loaders.contains)) {
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

  void _setShowAllGameVersions(bool value) {
    setState(() {
      _showAllGameVersions = value;
      if (!value) {
        _selectedGameVersions.removeWhere((v) => !_isReleaseGameVersion(v));
      }
      _versionPage = 1;
    });
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
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
    final loaderOptions = _availableLoaders
        .map(
          (l) => FilterMultiSelectOption(value: l, label: displayLoader(l)),
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
                  colorScheme: widget.colorScheme,
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
                  colorScheme: widget.colorScheme,
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
              if (loaderOptions.isNotEmpty &&
                  (gameOptions.isNotEmpty || channelOptions.isNotEmpty))
                const SizedBox(width: 8),
              if (loaderOptions.isNotEmpty)
                FilterMultiSelect(
                  label: _selectedLoaders.isEmpty
                      ? '平台'
                      : '平台 (${_selectedLoaders.length})',
                  options: loaderOptions,
                  selected: _selectedLoaders,
                  colorScheme: widget.colorScheme,
                  dropdownMinWidth: 160,
                  onChanged: (next) {
                    setState(() {
                      _selectedLoaders
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
                  colorScheme: widget.colorScheme,
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
                widget.versions.isEmpty ? '没有匹配的版本' : '没有符合筛选条件的版本',
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
                    _versionRow(tokens, pageItems[i], striped: i.isOdd),
                ],
              ),
            ),
          if (totalPages > 1) ...[
            const SizedBox(height: 16),
            Center(
              child: PaginationWidget(
                currentPage: page,
                totalPages: totalPages,
                colorScheme: widget.colorScheme,
                onPageChanged: (p) => setState(() => _versionPage = p),
              ),
            ),
          ],
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

  Widget _versionRow(
    tokens,
    ModrinthVersionInfo v, {
    required bool striped,
  }) {
    final isInstalled = v.id == widget.installedVersionId;
    final installing = widget.installingVersionId == v.id;
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
                    tooltip: isInstalled
                        ? '已安装'
                        : (installing ? '安装中' : '安装'),
                    onPressed: isInstalled || installing
                        ? null
                        : () => widget.onInstall(v.id),
                    iconSize: 22,
                    icon: isInstalled
                        ? Icon(
                            Icons.check_circle_outline,
                            color: tokens.colorBase.withValues(alpha: 0.45),
                          )
                        : installing
                        ? SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.colorBrand,
                            ),
                          )
                        : Icon(
                            Icons.download_rounded,
                            color: tokens.colorBrand,
                          ),
                  ),
                  IconButton(
                    tooltip: '在浏览器打开',
                    iconSize: 20,
                    onPressed: () {
                      final Uri url;
                      if (isCurseForgeProjectId(widget.project.id)) {
                        final cfPath = switch (widget.project.projectType) {
                          'modpack' => 'modpacks',
                          'resourcepack' => 'texture-packs',
                          'shader' => 'shaders',
                          'datapack' => 'data-packs',
                          _ => 'mc-mods',
                        };
                        url = Uri.parse(
                          'https://www.curseforge.com/minecraft/$cfPath/${widget.project.slug}/files/${v.id}',
                        );
                      } else {
                        final typePath = switch (widget.project.projectType) {
                          'modpack' => 'modpack',
                          'resourcepack' => 'resourcepack',
                          'shader' => 'shader',
                          'datapack' => 'datapack',
                          _ => 'mod',
                        };
                        url = Uri.parse(
                          'https://modrinth.com/$typePath/${widget.project.slug}/version/${v.id}',
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
