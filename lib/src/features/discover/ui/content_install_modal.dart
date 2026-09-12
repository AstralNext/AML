import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

enum ContentInstallModalAction {
  installToExisting,
  createAndInstall,
}

class ContentInstallModalResult {
  const ContentInstallModalResult.installToExisting({
    required this.instanceId,
    this.installDespiteIncompatibility = false,
  })  : action = ContentInstallModalAction.installToExisting,
        newInstance = null;

  const ContentInstallModalResult.createAndInstall({
    required this.newInstance,
  })  : action = ContentInstallModalAction.createAndInstall,
        instanceId = null,
        installDespiteIncompatibility = false;

  final ContentInstallModalAction action;
  final String? instanceId;
  final bool installDespiteIncompatibility;
  final ContentInstallNewInstance? newInstance;
}

class ContentInstallNewInstance {
  const ContentInstallNewInstance({
    required this.name,
    required this.loader,
    required this.gameVersion,
    this.icon,
  });

  final String name;
  final String loader;
  final String gameVersion;
  final String? icon;
}

class ContentInstallInstanceRow {
  const ContentInstallInstanceRow({
    required this.id,
    required this.name,
    this.iconPath,
    required this.compatible,
    required this.installed,
  });

  final String id;
  final String name;
  final String? iconPath;
  final bool compatible;
  final bool installed;
}

/// "安装项目" modal for picking an instance or creating a new one.
class ContentInstallModal extends StatefulWidget {
  const ContentInstallModal({
    super.key,
    required this.projectId,
    required this.projectType,
    this.projectTitle,
    this.projectIconUrl,
  });

  final String projectId;
  final String projectType;
  final String? projectTitle;
  final String? projectIconUrl;

  static Future<ContentInstallModalResult?> show(
    BuildContext context, {
    required String projectId,
    required String projectType,
    String? projectTitle,
    String? projectIconUrl,
  }) {
    return Navigator.of(context).push<ContentInstallModalResult>(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => ContentInstallModal(
          projectId: projectId,
          projectType: projectType,
          projectTitle: projectTitle,
          projectIconUrl: projectIconUrl,
        ),
      ),
    );
  }

  @override
  State<ContentInstallModal> createState() => _ContentInstallModalState();
}

class _ContentInstallModalState extends State<ContentInstallModal>
    with SingleTickerProviderStateMixin {
  static const _supportedLoaders = {
    'vanilla',
    'forge',
    'fabric',
    'quilt',
    'neoforge',
  };
  static const _vanillaCompatibleLoaders = {'minecraft', 'datapack'};
  static const _loaderOrder = ['vanilla', 'fabric', 'quilt', 'neoforge', 'forge'];

  late final ModalMotion _motion;

  final _searchController = TextEditingController();
  final _nameController = TextEditingController();

  _InstallTab _tab = _InstallTab.existing;
  bool _loading = true;
  bool _hideUnavailable = true;
  List<ContentInstallInstanceRow> _instances = [];
  List<String> _compatibleLoaders = [];
  List<String> _gameVersions = [];
  String? _selectedLoader;
  String? _selectedGameVersion;
  String? _iconPath;

  @override
  void initState() {
    super.initState();
    _motion = ModalMotion(this)..forward();
    _loadData();
    _searchController.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _searchController.dispose();
    _nameController.dispose();
    _motion.dispose();
    super.dispose();
  }

  void _close([ContentInstallModalResult? result]) {
    _motion.reverse();
    Navigator.of(context).pop(result);
  }

  String? _loaderForProjectType(String? projectType, String instanceLoader) {
    switch (projectType) {
      case 'datapack':
        return 'datapack';
      case 'resourcepack':
        return 'minecraft';
      case 'shader':
        return 'iris';
      case 'mod':
      case 'modpack':
        if (instanceLoader.isEmpty || instanceLoader == 'vanilla') {
          return null;
        }
        return instanceLoader;
      default:
        return instanceLoader == 'vanilla' ? null : instanceLoader;
    }
  }

  List<String> _sortLoaders(Iterable<String> loaders) {
    return loaders.toList()
      ..sort((a, b) {
        final aIdx = _loaderOrder.indexOf(a);
        final bIdx = _loaderOrder.indexOf(b);
        if (aIdx == -1 && bIdx == -1) return a.compareTo(b);
        if (aIdx == -1) return 1;
        if (bIdx == -1) return -1;
        return aIdx.compareTo(bIdx);
      });
  }

  int _instanceScore(ContentInstallInstanceRow row) {
    if (!row.compatible) return 2;
    if (row.installed) return 1;
    return 0;
  }

  Future<void> _loadData() async {
    final store = getIt<InstanceStore>();
    final rawInstances = store.instances.value;
    final isCf = isCurseForgeProjectId(widget.projectId);
    final cfModId = parseCurseForgeModId(widget.projectId);

    List<ModrinthVersionInfo> versions = const [];
    try {
      if (isCf && cfModId != null) {
        versions =
            await CurseForgeApiService.getProjectVersionsAsModrinth(cfModId);
      } else {
        versions = await ModrinthApiService.getProjectVersions(widget.projectId);
      }
    } catch (_) {}

    final loaderSet = <String>{};
    final gameVersionSet = <String>{};
    for (final version in versions) {
      for (final loader in version.loaders) {
        if (_supportedLoaders.contains(loader)) {
          loaderSet.add(loader);
        } else if (_vanillaCompatibleLoaders.contains(loader)) {
          loaderSet.add('vanilla');
        }
      }
      gameVersionSet.addAll(version.gameVersions);
    }

    final rows = <ContentInstallInstanceRow>[];
    await Future.wait(
      rawInstances.map((instance) async {
        final loader = _loaderForProjectType(widget.projectType, instance.loader);
        String? compatibleId;
        if (isCf && cfModId != null) {
          compatibleId = await CurseForgeApiService.getCompatibleFileId(
            modId: cfModId,
            gameVersion: instance.gameVersion,
            loader: loader,
          );
        } else {
          compatibleId = await ModrinthApiService.getCompatibleVersionId(
            projectId: widget.projectId,
            gameVersion: instance.gameVersion,
            loader: loader,
          );
        }
        var installed = false;
        try {
          final mods = await rust.listInstanceMods(instanceId: instance.id);
          installed = mods.any((m) => m.projectId == widget.projectId);
        } catch (_) {}
        rows.add(
          ContentInstallInstanceRow(
            id: instance.id,
            name: instance.name,
            iconPath: instance.icon,
            compatible: compatibleId != null,
            installed: installed,
          ),
        );
      }),
    );

    if (!mounted) return;
    final compatibleLoaders = _sortLoaders(loaderSet);
    final gameVersions = gameVersionSet.toList()
      ..sort((a, b) => _compareGameVersions(b, a));

    final defaultTab = rows.any((r) => r.compatible && !r.installed)
        ? _InstallTab.existing
        : compatibleLoaders.isNotEmpty
            ? _InstallTab.newInstance
            : _InstallTab.existing;

    setState(() {
      _instances = rows;
      _compatibleLoaders = compatibleLoaders;
      _gameVersions = gameVersions;
      _selectedLoader = compatibleLoaders.isNotEmpty ? compatibleLoaders.first : null;
      _selectedGameVersion =
          gameVersions.isNotEmpty ? gameVersions.first : null;
      _nameController.text = '新实例 (${rawInstances.length + 1})';
      _tab = compatibleLoaders.isEmpty ? _InstallTab.existing : defaultTab;
      _loading = false;
    });
  }

  int _compareGameVersions(String a, String b) {
    final ap = a.split('.').map(int.tryParse).toList();
    final bp = b.split('.').map(int.tryParse).toList();
    for (var i = 0; i < ap.length || i < bp.length; i++) {
      final av = i < ap.length ? (ap[i] ?? 0) : 0;
      final bv = i < bp.length ? (bp[i] ?? 0) : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  List<ContentInstallInstanceRow> get _filteredInstances {
    var list = _instances;
    if (_hideUnavailable) {
      list = list.where((i) => i.compatible && !i.installed).toList();
    }
    final query = _searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((i) => i.name.toLowerCase().contains(query)).toList();
    }
    return list.toList()
      ..sort((a, b) {
        final diff = _instanceScore(a) - _instanceScore(b);
        if (diff != 0) return diff;
        return a.name.compareTo(b.name);
      });
  }

  int get _compatibleCount => _instances.where((i) => i.compatible).length;

  Future<void> _pickIcon() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    final path = result?.files.single.path;
    if (path == null || path.isEmpty) return;
    setState(() => _iconPath = path);
  }

  void _installTo(ContentInstallInstanceRow row) {
    _close(
      ContentInstallModalResult.installToExisting(
        instanceId: row.id,
        installDespiteIncompatibility: !row.compatible,
      ),
    );
  }

  void _createAndInstall() {
    final name = _nameController.text.trim();
    final loader = _selectedLoader;
    final gameVersion = _selectedGameVersion;
    if (name.isEmpty || loader == null || gameVersion == null) return;
    _close(
      ContentInstallModalResult.createAndInstall(
        newInstance: ContentInstallNewInstance(
          name: name,
          loader: loader,
          gameVersion: gameVersion,
          icon: _iconPath,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedModalDialog.fromMotion(
      motion: _motion,
      onClose: () => _close(),
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 560,
          constraints: const BoxConstraints(maxHeight: 640),
          decoration: BoxDecoration(
            color: tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: tokens.colorSecondary.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        '安装项目',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ),
                    CustomButton(
                      icon: Icons.close,
                      size: ButtonSize.medium,
                      onTap: () => _close(),
                    ),
                  ],
                ),
              ),
              if (widget.projectTitle != null) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                  child: Row(
                    children: [
                      if (widget.projectIconUrl != null)
                        ClipRRect(
                          borderRadius: BorderRadius.circular(12),
                          child: Image.network(
                            widget.projectIconUrl!,
                            width: 48,
                            height: 48,
                            fit: BoxFit.cover,
                            errorBuilder: (_, __, ___) => const SizedBox(
                              width: 48,
                              height: 48,
                            ),
                          ),
                        )
                      else
                        Container(
                          width: 48,
                          height: 48,
                          decoration: BoxDecoration(
                            color: tokens.colorButtonBg,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Icon(
                            Icons.extension_outlined,
                            color: tokens.colorBase,
                          ),
                        ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          widget.projectTitle!,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w600,
                            color: tokens.colorContrast,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '实例类型',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: tokens.colorContrast,
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        _PillChoice(
                          tokens: tokens,
                          label: '已有实例',
                          selected: _tab == _InstallTab.existing,
                          onTap: () => setState(() => _tab = _InstallTab.existing),
                        ),
                        if (_compatibleLoaders.isNotEmpty)
                          _PillChoice(
                            tokens: tokens,
                            label: '新实例',
                            selected: _tab == _InstallTab.newInstance,
                            onTap: () =>
                                setState(() => _tab = _InstallTab.newInstance),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: tokens.colorSecondary.withValues(alpha: 0.25),
              ),
              Expanded(
                child: _tab == _InstallTab.existing
                    ? _buildExistingTab(tokens, colorScheme)
                    : _buildNewTab(tokens, colorScheme),
              ),
              Divider(
                height: 1,
                color: tokens.colorSecondary.withValues(alpha: 0.25),
              ),
              _buildFooter(tokens),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildExistingTab(AppThemeTokens tokens, ColorScheme colorScheme) {
    return ColoredBox(
      color: tokens.colorBg.withValues(alpha: 0.35),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: InputBarWidget(
                    colorScheme: colorScheme,
                    size: InputBarSize.medium,
                    hintText: '搜索实例',
                    controller: _searchController,
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                CustomButton(
                  icon: _hideUnavailable ? Icons.visibility_off : Icons.visibility,
                  size: ButtonSize.medium,
                  onTap: () => setState(() => _hideUnavailable = !_hideUnavailable),
                  label: _hideUnavailable ? '显示不可用实例' : '隐藏不可用实例',
                ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _filteredInstances.isEmpty
                    ? Center(
                        child: Text(
                          '没有可用的实例',
                          style: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        itemCount: _filteredInstances.length,
                        itemBuilder: (context, index) {
                          final row = _filteredInstances[index];
                          return _InstanceRow(
                            tokens: tokens,
                            row: row,
                            onInstall: () => _installTo(row),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }

  Widget _buildNewTab(AppThemeTokens tokens, ColorScheme colorScheme) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              InstanceIcon(
                instanceId: 'content-install-new',
                iconPath: _iconPath,
                size: 80,
                borderRadius: 16,
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NavRectButton(
                    text: '选择图标',
                    icon: Icons.upload_outlined,
                    isSelected: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    onTap: _pickIcon,
                  ),
                  if (_iconPath != null) ...[
                    const SizedBox(height: 8),
                    NavRectButton(
                      text: '移除图标',
                      icon: Icons.close,
                      isSelected: false,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      onTap: () => setState(() => _iconPath = null),
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '名称',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          InputBarWidget(
            colorScheme: colorScheme,
            size: InputBarSize.medium,
            hintText: '输入实例名称',
            controller: _nameController,
          ),
          const SizedBox(height: 16),
          Text(
            '加载器',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final loader in _compatibleLoaders)
                _PillChoice(
                  tokens: tokens,
                  label: loaderLabel(loader),
                  selected: _selectedLoader == loader,
                  onTap: () => setState(() => _selectedLoader = loader),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '游戏版本',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          if (_gameVersions.isEmpty)
            Text(
              '暂无可用游戏版本',
              style: TextStyle(color: tokens.colorBase.withValues(alpha: 0.7)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: tokens.colorButtonBg.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: tokens.colorSecondary.withValues(alpha: 0.35),
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: _selectedGameVersion,
                  isExpanded: true,
                  dropdownColor: tokens.colorRaisedBg,
                  items: [
                    for (final v in _gameVersions)
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => setState(() => _selectedGameVersion = v),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildFooter(AppThemeTokens tokens) {
    if (_tab == _InstallTab.existing) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
        child: Row(
          children: [
            Icon(Icons.inventory_2_outlined, size: 18, color: tokens.colorBase),
            const SizedBox(width: 6),
            Text(
              '$_compatibleCount 个兼容实例',
              style: TextStyle(
                fontSize: 13,
                color: tokens.colorBase.withValues(alpha: 0.85),
              ),
            ),
            const Spacer(),
            NavRectButton(
              text: '取消',
              icon: Icons.close,
              isSelected: false,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              onTap: () => _close(),
            ),
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          NavRectButton(
            text: '取消',
            icon: Icons.close,
            isSelected: false,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            onTap: () => _close(),
          ),
          const SizedBox(width: 10),
          NavRectButton(
            text: '安装',
            icon: Icons.download_outlined,
            isSelected: false,
            defaultBackgroundColor: tokens.colorBrand,
            defaultColor: tokens.colorOnBrand,
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            onTap: _nameController.text.trim().isEmpty ? () {} : _createAndInstall,
          ),
        ],
      ),
    );
  }
}

enum _InstallTab { existing, newInstance }

class _InstanceRow extends StatelessWidget {
  const _InstanceRow({
    required this.tokens,
    required this.row,
    required this.onInstall,
  });

  final AppThemeTokens tokens;
  final ContentInstallInstanceRow row;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: row.installed ? 0.6 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: row.installed ? null : onInstall,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                InstanceIcon(
                  instanceId: row.id,
                  iconPath: row.iconPath,
                  size: 32,
                  borderRadius: 8,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    row.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tokens.colorContrast,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (row.installed)
                  _StatusButton(
                    tokens: tokens,
                    label: '已安装',
                    icon: Icons.check,
                    enabled: false,
                  )
                else
                  _StatusButton(
                    tokens: tokens,
                    label: '安装',
                    icon: row.compatible ? null : Icons.warning_amber_rounded,
                    warning: !row.compatible,
                    onTap: onInstall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.tokens,
    required this.label,
    this.icon,
    this.warning = false,
    this.enabled = true,
    this.onTap,
  });

  final AppThemeTokens tokens;
  final String label;
  final IconData? icon;
  final bool warning;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = warning
        ? const Color(0xFFF97316)
        : tokens.colorSecondary.withValues(alpha: 0.35);
    final textColor = enabled
        ? (warning ? const Color(0xFFF97316) : tokens.colorContrast)
        : tokens.colorBase.withValues(alpha: 0.55);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
            color: tokens.colorButtonBg.withValues(alpha: enabled ? 0.55 : 0.25),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: textColor),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PillChoice extends StatelessWidget {
  const _PillChoice({
    required this.tokens,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final AppThemeTokens tokens;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? tokens.colorBrand.withValues(alpha: 0.18)
          : tokens.colorButtonBg.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check, size: 14, color: tokens.colorBrand),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? tokens.colorContrast : tokens.colorBase,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
