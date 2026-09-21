import 'package:aml/src/features/discover/ui/content_install_controller.dart';
import 'package:aml/src/features/discover/ui/content_install_existing_section.dart';
import 'package:aml/src/features/discover/ui/content_install_models.dart';
import 'package:aml/src/features/discover/ui/content_install_new_section.dart';
import 'package:aml/src/features/discover/ui/content_install_widgets.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

export 'content_install_models.dart';

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
  late final ModalMotion _motion;
  late final ContentInstallController _controller;

  final _searchController = TextEditingController();
  final _nameController = TextEditingController();

  ContentInstallTab _tab = ContentInstallTab.existing;
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
    _controller = ContentInstallController(
      projectId: widget.projectId,
      projectType: widget.projectType,
    );
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

  Future<void> _loadData() async {
    final data = await _controller.loadData();
    if (!mounted) return;
    setState(() {
      _instances = data.instances;
      _compatibleLoaders = data.compatibleLoaders;
      _gameVersions = data.gameVersions;
      _selectedLoader =
          data.compatibleLoaders.isNotEmpty ? data.compatibleLoaders.first : null;
      _selectedGameVersion =
          data.gameVersions.isNotEmpty ? data.gameVersions.first : null;
      _nameController.text = '新实例 (${data.totalInstanceCount + 1})';
      _tab = data.initialTab;
      _loading = false;
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
              ContentInstallModalHeader(
                tokens: tokens,
                projectTitle: widget.projectTitle,
                projectIconUrl: widget.projectIconUrl,
                onClose: () => _close(),
              ),
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
                        ContentInstallPillChoice(
                          tokens: tokens,
                          label: '已有实例',
                          selected: _tab == ContentInstallTab.existing,
                          onTap: () =>
                              setState(() => _tab = ContentInstallTab.existing),
                        ),
                        if (_compatibleLoaders.isNotEmpty)
                          ContentInstallPillChoice(
                            tokens: tokens,
                            label: '新实例',
                            selected: _tab == ContentInstallTab.newInstance,
                            onTap: () => setState(
                              () => _tab = ContentInstallTab.newInstance,
                            ),
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
                child: _tab == ContentInstallTab.existing
                    ? ContentInstallExistingSection(
                        tokens: tokens,
                        colorScheme: colorScheme,
                        loading: _loading,
                        instances: _instances,
                        searchController: _searchController,
                        hideUnavailable: _hideUnavailable,
                        onToggleHideUnavailable: () =>
                            setState(() => _hideUnavailable = !_hideUnavailable),
                        onInstall: _installTo,
                      )
                    : ContentInstallNewSection(
                        tokens: tokens,
                        colorScheme: colorScheme,
                        nameController: _nameController,
                        compatibleLoaders: _compatibleLoaders,
                        gameVersions: _gameVersions,
                        selectedLoader: _selectedLoader,
                        selectedGameVersion: _selectedGameVersion,
                        iconPath: _iconPath,
                        onPickIcon: _pickIcon,
                        onClearIcon: () => setState(() => _iconPath = null),
                        onSelectLoader: (loader) =>
                            setState(() => _selectedLoader = loader),
                        onSelectGameVersion: (v) =>
                            setState(() => _selectedGameVersion = v),
                      ),
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

  Widget _buildFooter(AppThemeTokens tokens) {
    if (_tab == ContentInstallTab.existing) {
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
