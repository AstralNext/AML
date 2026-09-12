import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

enum _CreateStage { type, custom, modpack, importPreview }

class CreateInstanceContent extends StatefulWidget {
  final ColorScheme colorScheme;
  final VoidCallback onClose;
  final Future<void> Function()? onCreated;

  const CreateInstanceContent({
    super.key,
    required this.colorScheme,
    required this.onClose,
    this.onCreated,
  });

  @override
  State<CreateInstanceContent> createState() => _CreateInstanceContentState();
}

class _CreateInstanceContentState extends State<CreateInstanceContent> {
  final _nameController = TextEditingController(text: '新实例');
  List<rust.GameVersionDto> _allVersions = [];
  List<rust.LoaderVersionDto> _loaderVersions = [];
  String _loader = 'fabric';
  String? _gameVersion;
  String? _loaderVersion;
  String _loaderChannel = 'stable'; // stable | latest | other
  bool _showSnapshots = false;
  bool _loadingVersions = true;
  bool _creating = false;
  String? _error;
  String? _iconPath;
  _CreateStage _stage = _CreateStage.type;
  String? _importPath;
  rust.PackImportPreviewDto? _importPreview;
  final _importNameController = TextEditingController();
  final Set<String> _importExpanded = {};

  AppThemeTokens get _tokens => AppThemeTokens.fallback(widget.colorScheme);

  bool get _hasNonReleaseVersions =>
      _allVersions.any((v) => v.type != 'release');

  List<rust.GameVersionDto> get _displayVersions {
    if (_showSnapshots || !_hasNonReleaseVersions) {
      return _allVersions;
    }
    final releases = _allVersions.where((v) => v.type == 'release').toList();
    return releases.isEmpty ? _allVersions : releases;
  }

  String _versionLabel(rust.GameVersionDto version) {
    if (version.type == 'release') return version.id;
    return switch (version.type) {
      'snapshot' => '${version.id}（快照）',
      'old_beta' => '${version.id}（旧测试版）',
      'old_alpha' => '${version.id}（旧预览版）',
      _ => version.id,
    };
  }

  void _ensureValidGameVersion() {
    final visible = _displayVersions;
    if (visible.isEmpty) {
      _gameVersion = null;
      return;
    }
    if (_gameVersion == null ||
        !visible.any((v) => v.id == _gameVersion)) {
      _gameVersion = visible.first.id;
    }
  }

  void _setShowSnapshots(bool value) {
    setState(() {
      _showSnapshots = value;
      _ensureValidGameVersion();
      _syncDefaultName();
    });
    if (_gameVersion != null && _loader != 'vanilla') {
      unawaited(_loadLoaderVersions());
    }
  }

  @override
  void initState() {
    super.initState();
    _loadVersions();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _importNameController.dispose();
    super.dispose();
  }

  Future<void> _loadVersions() async {
    setState(() {
      _loadingVersions = true;
      _error = null;
    });
    try {
      final store = getIt<InstanceStore>();
      final versions = await store.listMinecraftVersions();
      setState(() {
        _allVersions = versions;
        _showSnapshots = false;
        _ensureValidGameVersion();
        if (_gameVersion != null) {
          _nameController.text = 'Fabric $_gameVersion';
        }
        _loadingVersions = false;
      });
      if (_gameVersion != null && _loader != 'vanilla') {
        await _loadLoaderVersions();
      }
    } catch (e) {
      setState(() {
        _loadingVersions = false;
        _error = e.toString();
      });
    }
  }

  Future<void> _loadLoaderVersions() async {
    if (_gameVersion == null || _loader == 'vanilla') {
      setState(() {
        _loaderVersions = [];
        _loaderVersion = null;
      });
      return;
    }
    try {
      final list = await getIt<InstanceStore>().listLoaderVersions(
        loader: _loader,
        gameVersion: _gameVersion!,
      );
      setState(() {
        _loaderVersions = list;
        _applyLoaderChannel();
      });
    } catch (e) {
      setState(() {
        _error = e.toString();
        _loaderVersions = [];
        _loaderVersion = null;
      });
    }
  }

  void _applyLoaderChannel() {
    if (_loaderVersions.isEmpty) {
      _loaderVersion = null;
      return;
    }
    switch (_loaderChannel) {
      case 'stable':
        _loaderVersion = _loaderVersions
            .firstWhere((e) => e.stable, orElse: () => _loaderVersions.first)
            .id;
      case 'latest':
        _loaderVersion = _loaderVersions.first.id;
      default:
        _loaderVersion ??= _loaderVersions.first.id;
    }
  }

  void _syncDefaultName() {
    final loaderLabel = switch (_loader) {
      'vanilla' => 'Vanilla',
      'fabric' => 'Fabric',
      'forge' => 'Forge',
      'quilt' => 'Quilt',
      'neoforge' => 'NeoForge',
      _ => _loader,
    };
    final gv = _gameVersion ?? '';
    _nameController.text = gv.isEmpty ? loaderLabel : '$loaderLabel $gv';
  }

  Future<void> _pickIcon() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    setState(() => _iconPath = path);
  }

  void _setStateIfMounted(VoidCallback fn) {
    if (mounted) setState(fn);
  }

  Future<void> _submitCustom() async {
    final name = _nameController.text.trim();
    if (name.isEmpty || _gameVersion == null) return;
    _setStateIfMounted(() {
      _creating = true;
      _error = null;
    });
    try {
      final store = getIt<InstanceStore>();
      final created = await store.create(
        name: name,
        gameVersion: _gameVersion!,
        loader: _loader,
        loaderVersion: _loader == 'vanilla' ? null : _loaderVersion,
        icon: _iconPath,
      );
      if (!mounted) return;
      await widget.onCreated?.call();
      // Close immediately — don't keep the dialog open for the full install.
      widget.onClose();
      getIt<NavigationState>().openInstance(created.id);
      unawaited(store.install(created.id));
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _creating = false;
      });
    }
  }

  Future<void> _pickImportPack() async {
    _setStateIfMounted(() {
      _creating = true;
      _error = null;
    });
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mrpack', 'zip'],
      );
      if (result == null ||
          result.files.isEmpty ||
          result.files.first.path == null) {
        _setStateIfMounted(() => _creating = false);
        return;
      }
      final path = result.files.first.path!;
      final fallbackName = result.files.first.name
          .replaceAll(RegExp(r'\.(mrpack|zip)$', caseSensitive: false), '');
      rust.PackImportPreviewDto preview;
      try {
        preview = await rust.previewPackFile(path: path);
      } catch (e) {
        _setStateIfMounted(() {
          _error = '无法预览整合包: $e';
          _creating = false;
        });
        return;
      }
      if (!mounted) return;
      _importNameController.text =
          preview.name.trim().isEmpty ? fallbackName : preview.name;
      _setStateIfMounted(() {
        _importPath = path;
        _importPreview = preview;
        _importExpanded.clear();
        _creating = false;
        _stage = _CreateStage.importPreview;
      });
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _creating = false;
      });
    }
  }

  Future<void> _confirmImportPack() async {
    final path = _importPath;
    if (path == null || _creating) return;
    final name = _importNameController.text.trim();
    if (name.isEmpty) {
      _setStateIfMounted(() => _error = '请填写实例名称');
      return;
    }
    _setStateIfMounted(() {
      _creating = true;
      _error = null;
    });
    try {
      final created = await getIt<InstanceStore>().createFromPackFile(
        path: path,
        name: name,
      );
      if (!mounted) return;
      await widget.onCreated?.call();
      widget.onClose();
      getIt<NavigationState>().openInstance(created.id);
    } catch (e) {
      _setStateIfMounted(() {
        _error = e.toString();
        _creating = false;
      });
    }
  }

  void _browseModpacksOnModrinth() {
    widget.onClose();
    getIt<NavigationState>().browseModpacks();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = _tokens;
    final maxH = MediaQuery.sizeOf(context).height * 0.82;
    return ConstrainedBox(
      constraints: BoxConstraints(
        minWidth: 520,
        maxWidth: 520,
        maxHeight: maxH,
      ),
      child: Material(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(20),
        clipBehavior: Clip.antiAlias,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(tokens),
            Divider(
              height: 1,
              thickness: 1,
              color: tokens.colorSecondary.withAlpha(35),
            ),
            _buildBody(tokens),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(AppThemeTokens tokens) {
    return SizedBox(
      height: 64,
      width: double.infinity,
      child: Row(
        children: [
          const SizedBox(width: 30),
          const Text(
            '创建实例',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700),
          ),
          const Spacer(),
          CustomButton(
            icon: Icons.close,
            size: ButtonSize.medium,
            backgroundColor: tokens.colorButtonBg.withAlpha(80),
            onTap: widget.onClose,
          ),
          const SizedBox(width: 30),
        ],
      ),
    );
  }

  Widget _buildBody(AppThemeTokens tokens) {
    switch (_stage) {
      case _CreateStage.type:
        return _buildTypeStage(tokens);
      case _CreateStage.custom:
        return _buildCustomStage(tokens);
      case _CreateStage.modpack:
        return _buildModpackStage(tokens);
      case _CreateStage.importPreview:
        return _buildImportPreviewStage(tokens);
    }
  }

  Widget _buildTypeStage(AppThemeTokens tokens) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 20, 30, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '选择实例类型',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 16),
          _TypeOption(
            tokens: tokens,
            icon: Icons.dashboard_customize_outlined,
            title: '自定义设置',
            description: '从头开始，选择一个加载器和游戏版本。',
            onTap: () => setState(() => _stage = _CreateStage.custom),
          ),
          const SizedBox(height: 12),
          _TypeOption(
            tokens: tokens,
            icon: Icons.inventory_2_outlined,
            title: '安装整合包',
            description: '在 Modrinth 上浏览整合包或从文件中导入一个。',
            onTap: () => setState(() => _stage = _CreateStage.modpack),
          ),
          const SizedBox(height: 20),
          Text(
            '实例是带有特定加载器、游戏版本和模组的一套 Minecraft 配置。',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: tokens.colorBase.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildModpackStage(AppThemeTokens tokens) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 20, 30, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '安装整合包',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 16),
          _TypeOption(
            tokens: tokens,
            icon: Icons.travel_explore_outlined,
            title: '在 Modrinth 浏览',
            description: '打开发现页，筛选并安装整合包到新实例。',
            onTap: _creating ? () {} : _browseModpacksOnModrinth,
          ),
          const SizedBox(height: 12),
          _TypeOption(
            tokens: tokens,
            icon: Icons.folder_open_outlined,
            title: '从文件导入',
            description:
                '支持 .mrpack、CurseForge、MCBBS、MultiMC 整合包 zip。',
            onTap: _creating ? () {} : _pickImportPack,
          ),
          if (_error != null) ...[
            const SizedBox(height: 12),
            Text(
              _error!,
              style: TextStyle(color: widget.colorScheme.error, fontSize: 12),
            ),
          ],
          if (_creating) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ],
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: NavRectButton(
              text: '返回',
              icon: Icons.arrow_back,
              isSelected: false,
              onTap: _creating
                  ? () {}
                  : () => setState(() {
                        _error = null;
                        _stage = _CreateStage.type;
                      }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildImportCover(
    AppThemeTokens tokens,
    rust.PackImportPreviewDto? preview,
  ) {
    final bytes = preview?.coverPng;
    final hasCover = preview?.hasCover == true && bytes != null && bytes.isNotEmpty;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: SizedBox(
            width: 72,
            height: 72,
            child: hasCover
                ? Image.memory(
                    bytes,
                    fit: BoxFit.cover,
                    errorBuilder: (_, __, ___) => _coverPlaceholder(tokens),
                  )
                : _coverPlaceholder(tokens),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Text(
            hasCover ? '整合包已携带封面，导入后将用作实例图标。' : '此整合包未携带封面图。',
            style: TextStyle(
              fontSize: 13,
              color: tokens.colorBase.withValues(alpha: 0.75),
            ),
          ),
        ),
      ],
    );
  }

  Widget _coverPlaceholder(AppThemeTokens tokens) {
    return ColoredBox(
      color: tokens.colorSuperRaisedBg,
      child: Icon(
        Icons.image_not_supported_outlined,
        size: 28,
        color: tokens.colorBase.withValues(alpha: 0.45),
      ),
    );
  }

  Widget _buildImportPreviewStage(AppThemeTokens tokens) {
    final preview = _importPreview;
    final maxBody = MediaQuery.sizeOf(context).height * 0.82 - 84 - 80;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxBody.clamp(280, 560)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(30, 20, 30, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '确认导入',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  preview == null
                      ? '请确认实例名称后开始导入。'
                      : '${preview.kindLabel}'
                          '${preview.version != null && preview.version!.isNotEmpty ? ' · v${preview.version}' : ''}'
                          '${preview.gameVersion != null ? ' · ${preview.gameVersion}' : ''}'
                          '${preview.loader != null ? ' · ${preview.loader}' : ''}',
                  style: TextStyle(
                    fontSize: 13,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 14),
                _buildImportCover(tokens, preview),
                const SizedBox(height: 16),
                Text(
                  '实例名称',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 8),
                InputBarWidget(
                  colorScheme: widget.colorScheme,
                  controller: _importNameController,
                  size: InputBarSize.medium,
                  hintText: '导入后的实例名称',
                ),
                const SizedBox(height: 18),
                Text(
                  '内容预览',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 8),
                if (preview == null || preview.categories.isEmpty)
                  Text(
                    '未能解析出内容列表，仍可继续导入。',
                    style: TextStyle(
                      fontSize: 13,
                      color: tokens.colorBase.withValues(alpha: 0.65),
                    ),
                  )
                else
                  ...preview.categories.map((cat) {
                    final expanded = _importExpanded.contains(cat.id);
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Material(
                        color: tokens.colorSuperRaisedBg,
                        borderRadius: BorderRadius.circular(12),
                        child: Column(
                          children: [
                            InkWell(
                              borderRadius: BorderRadius.circular(12),
                              onTap: cat.files.isEmpty
                                  ? null
                                  : () => setState(() {
                                        if (expanded) {
                                          _importExpanded.remove(cat.id);
                                        } else {
                                          _importExpanded.add(cat.id);
                                        }
                                      }),
                              child: Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(12, 10, 8, 10),
                                child: Row(
                                  children: [
                                    Icon(
                                      _packCategoryIcon(cat.id),
                                      size: 18,
                                      color: tokens.colorBrand,
                                    ),
                                    const SizedBox(width: 10),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            cat.label,
                                            style: TextStyle(
                                              fontWeight: FontWeight.w700,
                                              color: tokens.colorContrast,
                                            ),
                                          ),
                                          Text(
                                            '${cat.fileCount} 个文件 · ${_formatBytes(cat.totalBytes)}',
                                            style: TextStyle(
                                              fontSize: 12,
                                              color: tokens.colorBase
                                                  .withValues(alpha: 0.65),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    if (cat.files.isNotEmpty)
                                      Icon(
                                        expanded
                                            ? Icons.expand_less
                                            : Icons.expand_more,
                                        color: tokens.colorBase,
                                      ),
                                  ],
                                ),
                              ),
                            ),
                            if (expanded)
                              Padding(
                                padding:
                                    const EdgeInsets.fromLTRB(10, 0, 10, 10),
                                child: Column(
                                  children: [
                                    for (final file in cat.files.take(40))
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(bottom: 4),
                                        child: Row(
                                          children: [
                                            _PackFileIcon(
                                              tokens: tokens,
                                              categoryId: cat.id,
                                              iconUrl: file.iconUrl,
                                            ),
                                            const SizedBox(width: 10),
                                            Expanded(
                                              child: Column(
                                                crossAxisAlignment:
                                                    CrossAxisAlignment.start,
                                                children: [
                                                  Text(
                                                    (file.title?.trim()
                                                                .isNotEmpty ??
                                                            false)
                                                        ? file.title!.trim()
                                                        : file.name,
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 13,
                                                      fontWeight:
                                                          FontWeight.w600,
                                                      color:
                                                          tokens.colorContrast,
                                                    ),
                                                  ),
                                                  Text(
                                                    '${file.name} · ${_formatBytes(file.sizeBytes)}',
                                                    maxLines: 1,
                                                    overflow:
                                                        TextOverflow.ellipsis,
                                                    style: TextStyle(
                                                      fontSize: 11,
                                                      color: tokens.colorBase
                                                          .withValues(
                                                              alpha: 0.6),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    if (cat.files.length > 40)
                                      Padding(
                                        padding: const EdgeInsets.only(top: 4),
                                        child: Text(
                                          '…还有 ${cat.files.length - 40} 个文件',
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: tokens.colorBase
                                                .withValues(alpha: 0.55),
                                          ),
                                        ),
                                      ),
                                  ],
                                ),
                              ),
                          ],
                        ),
                      ),
                    );
                  }),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: widget.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (_creating) ...[
                  const SizedBox(height: 16),
                  const Center(
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 8, 30, 22),
          child: Row(
            children: [
              NavRectButton(
                text: '返回',
                icon: Icons.arrow_back,
                isSelected: false,
                onTap: _creating
                    ? () {}
                    : () => setState(() {
                          _error = null;
                          _importPath = null;
                          _importPreview = null;
                          _stage = _CreateStage.modpack;
                        }),
              ),
              const Spacer(),
              NavRectButton(
                text: _creating ? '导入中…' : '开始导入',
                icon: Icons.download_outlined,
                isSelected: true,
                onTap: _creating ? () {} : _confirmImportPack,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildCustomStage(AppThemeTokens tokens) {
    final maxBody = MediaQuery.sizeOf(context).height * 0.82 - 84 - 72;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxBody.clamp(280, 560)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(30, 20, 30, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    InstanceIcon(
                      instanceId: 'new-instance',
                      iconPath: _iconPath,
                      size: 80,
                      borderRadius: 12,
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
                          onTap: _creating ? () {} : _pickIcon,
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
                            onTap: _creating
                                ? () {}
                                : () => setState(() => _iconPath = null),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '名称',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                InputBarWidget(
                  colorScheme: widget.colorScheme,
                  size: InputBarSize.medium,
                  hintText: '输入实例名称',
                  controller: _nameController,
                ),
                const SizedBox(height: 16),
                const Text(
                  '加载器',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in const [
                      ('vanilla', 'Vanilla'),
                      ('fabric', 'Fabric'),
                      ('neoforge', 'NeoForge'),
                      ('forge', 'Forge'),
                      ('quilt', 'Quilt'),
                    ])
                      _PillChoice(
                        tokens: tokens,
                        label: item.$2,
                        selected: _loader == item.$1,
                        onTap: _creating
                            ? null
                            : () async {
                                setState(() {
                                  _loader = item.$1;
                                  _syncDefaultName();
                                });
                                await _loadLoaderVersions();
                              },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '游戏版本',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (_loadingVersions)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  DropdownButtonWidget(
                    width: 220,
                    dropdownMinWidth: 240,
                    colorScheme: widget.colorScheme,
                    items: _displayVersions
                        .map(
                          (v) => DropdownItem(
                            display: _versionLabel(v),
                            value: v.id,
                          ),
                        )
                        .toList(),
                    selectedValue: _gameVersion ?? '',
                    footerLabel: _hasNonReleaseVersions
                        ? (_showSnapshots ? '隐藏快照版本' : '显示所有版本')
                        : null,
                    footerValue: _showSnapshots,
                    onFooterChanged: _hasNonReleaseVersions
                        ? _setShowSnapshots
                        : null,
                    onChanged: (value) async {
                      setState(() {
                        _gameVersion = value;
                        _syncDefaultName();
                      });
                      await _loadLoaderVersions();
                    },
                  ),
                if (_loader != 'vanilla') ...[
                  const SizedBox(height: 16),
                  const Text(
                    '加载器版本',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _PillChoice(
                        tokens: tokens,
                        label: '稳定版',
                        selected: _loaderChannel == 'stable',
                        onTap: _creating
                            ? null
                            : () => setState(() {
                                  _loaderChannel = 'stable';
                                  _applyLoaderChannel();
                                }),
                      ),
                      _PillChoice(
                        tokens: tokens,
                        label: '最新版',
                        selected: _loaderChannel == 'latest',
                        onTap: _creating
                            ? null
                            : () => setState(() {
                                  _loaderChannel = 'latest';
                                  _applyLoaderChannel();
                                }),
                      ),
                      _PillChoice(
                        tokens: tokens,
                        label: '其他',
                        selected: _loaderChannel == 'other',
                        onTap: _creating
                            ? null
                            : () =>
                                setState(() => _loaderChannel = 'other'),
                      ),
                    ],
                  ),
                  if (_loaderChannel == 'other') ...[
                    const SizedBox(height: 8),
                    DropdownButtonWidget(
                      width: 280,
                      dropdownMinWidth: 300,
                      colorScheme: widget.colorScheme,
                      items: _loaderVersions
                          .map(
                            (v) => DropdownItem(
                              display: v.stable ? '${v.id} (stable)' : v.id,
                              value: v.id,
                            ),
                          )
                          .toList(),
                      selectedValue: _loaderVersion ?? '',
                      onChanged: (value) =>
                          setState(() => _loaderVersion = value),
                    ),
                  ],
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    _error!,
                    style: TextStyle(
                      color: widget.colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 8, 30, 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              NavRectButton(
                text: '返回',
                icon: Icons.arrow_back,
                isSelected: false,
                onTap: _creating
                    ? () {}
                    : () => setState(() => _stage = _CreateStage.type),
              ),
              const SizedBox(width: 10),
              NavRectButton(
                isSelected: false,
                icon: Icons.add,
                defaultBackgroundColor: tokens.colorBrand,
                text: _creating ? '创建中…' : '创建实例',
                label: '创建实例',
                onTap: _creating ? () {} : _submitCustom,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _TypeOption extends StatefulWidget {
  const _TypeOption({
    required this.tokens,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final AppThemeTokens tokens;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  State<_TypeOption> createState() => _TypeOptionState();
}

class _TypeOptionState extends State<_TypeOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _hovered
                ? tokens.colorSuperRaisedBg
                : tokens.colorButtonBg.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: tokens.colorSecondary.withValues(alpha: 0.28),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: tokens.colorSecondary.withValues(alpha: 0.4),
                  ),
                ),
                child: Icon(widget.icon, size: 28, color: tokens.colorBase),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.description,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: tokens.colorBase.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: _hovered ? 1 : 0,
                duration: const Duration(milliseconds: 100),
                child: Icon(
                  Icons.chevron_right,
                  color: tokens.colorBase.withValues(alpha: 0.7),
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

String _formatBytes(BigInt bytes) {
  final n = bytes.toDouble();
  if (n < 1024) return '${n.toInt()} B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

IconData _packCategoryIcon(String id) {
  return switch (id) {
    'mods' => Icons.extension_outlined,
    'resourcepacks' => Icons.image_outlined,
    'shaderpacks' => Icons.wb_sunny_outlined,
    'datapacks' => Icons.inventory_2_outlined,
    'config' => Icons.settings_outlined,
    'options' => Icons.tune_outlined,
    'saves' => Icons.public_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}

class _PackFileIcon extends StatelessWidget {
  const _PackFileIcon({
    required this.tokens,
    required this.categoryId,
    required this.iconUrl,
  });

  final AppThemeTokens tokens;
  final String categoryId;
  final String? iconUrl;

  @override
  Widget build(BuildContext context) {
    final fallback = Container(
      width: 28,
      height: 28,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: tokens.colorButtonBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(
        _packCategoryIcon(categoryId),
        size: 16,
        color: tokens.colorBase.withValues(alpha: 0.75),
      ),
    );
    final url = iconUrl?.trim();
    if (url == null || url.isEmpty) return fallback;
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: CachedRemoteImage(
        url: url,
        width: 28,
        height: 28,
        fit: BoxFit.cover,
        placeholder: fallback,
        error: fallback,
      ),
    );
  }
}
