import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/button_group_widget.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

Future<void> showExportPackDialog({
  required BuildContext context,
  required String instanceId,
  String initialFormat = 'mrpack',
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    builder: (_) => ExportPackDialog(
      instanceId: instanceId,
      initialFormat: initialFormat,
    ),
  );
}

class ExportPackDialog extends StatefulWidget {
  const ExportPackDialog({
    super.key,
    required this.instanceId,
    this.initialFormat = 'mrpack',
  });

  final String instanceId;
  final String initialFormat;

  @override
  State<ExportPackDialog> createState() => _ExportPackDialogState();
}

class _ExportPackDialogState extends State<ExportPackDialog>
    with SingleTickerProviderStateMixin {
  late final ModalMotion _motion;

  final _nameController = TextEditingController();
  final _versionController = TextEditingController(text: '1.0.0');
  final _descriptionController = TextEditingController();

  String _format = 'mrpack';
  bool _loading = true;
  bool _exporting = false;
  String? _error;
  rust.PackExportPreviewDto? _preview;
  final Set<String> _selectedPaths = {};
  final Set<String> _expanded = {};

  InstanceStore get _store => getIt<InstanceStore>();

  static const _categoryOrder = [
    ('mods', '模组'),
    ('resourcepacks', '资源包'),
    ('shaderpacks', '光影包'),
    ('datapacks', '数据包'),
    ('config', '配置与脚本'),
    ('options', '游戏选项'),
    ('saves', '存档'),
  ];

  @override
  void initState() {
    super.initState();
    _format = widget.initialFormat;
    _motion = ModalMotion(this)..forward();
    _loadPreview();
  }

  @override
  void dispose() {
    _motion.dispose();
    _nameController.dispose();
    _versionController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _close() async {
    await _motion.reverse();
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _loadPreview() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final preview =
          await rust.previewInstanceExport(instanceId: widget.instanceId);
      if (!mounted) return;
      _nameController.text = preview.name;
      _selectedPaths
        ..clear()
        ..addAll(
          preview.categories
              .where((c) => c.id != 'saves')
              .expand((c) => c.files.map((f) => f.path)),
        );
      // Auto-expand categories that have files (except empty/saves).
      _expanded
        ..clear()
        ..addAll(
          preview.categories
              .where((c) => c.files.isNotEmpty && c.id != 'saves')
              .map((c) => c.id)
              .take(2),
        );
      setState(() {
        _preview = preview;
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

  String get _extension => switch (_format) {
        'multimc' || 'mcbbs' => 'zip',
        _ => 'mrpack',
      };

  String get _formatLabel => switch (_format) {
        'multimc' => 'MultiMC',
        'mcbbs' => 'MCBBS',
        _ => 'Modrinth .mrpack',
      };

  List<rust.PackContentCategoryDto> get _orderedCategories {
    final preview = _preview;
    final byId = {
      for (final c in preview?.categories ?? const <rust.PackContentCategoryDto>[])
        c.id: c,
    };
    final ordered = <rust.PackContentCategoryDto>[];
    for (final (id, label) in _categoryOrder) {
      ordered.add(
        byId.remove(id) ??
            rust.PackContentCategoryDto(
              id: id,
              label: label,
              fileCount: 0,
              totalBytes: BigInt.zero,
              files: const [],
            ),
      );
    }
    ordered.addAll(byId.values);
    return ordered;
  }

  bool? _categoryCheckState(rust.PackContentCategoryDto cat) {
    if (cat.files.isEmpty) return false;
    final selected = cat.files.where((f) => _selectedPaths.contains(f.path));
    if (selected.isEmpty) return false;
    if (selected.length == cat.files.length) return true;
    return null; // partial
  }

  void _setCategorySelected(rust.PackContentCategoryDto cat, bool selected) {
    setState(() {
      if (selected) {
        for (final f in cat.files) {
          _selectedPaths.add(f.path);
        }
        _expanded.add(cat.id);
      } else {
        for (final f in cat.files) {
          _selectedPaths.remove(f.path);
        }
      }
    });
  }

  void _toggleFile(String path) {
    setState(() {
      if (_selectedPaths.contains(path)) {
        _selectedPaths.remove(path);
      } else {
        _selectedPaths.add(path);
      }
    });
  }

  Future<void> _startExport() async {
    if (_exporting) return;
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      setState(() => _error = '请填写整合包名称');
      return;
    }
    final version = _versionController.text.trim();
    if (version.isEmpty) {
      setState(() => _error = '请填写版本号');
      return;
    }
    if (_selectedPaths.isEmpty) {
      setState(() => _error = '请至少勾选一个导出文件');
      return;
    }

    final includeIds = _orderedCategories
        .where(
          (c) => c.files.any((f) => _selectedPaths.contains(f.path)),
        )
        .map((c) => c.id)
        .toList(growable: false);

    final path = await FilePicker.platform.saveFile(
      dialogTitle: '导出整合包（$_formatLabel）',
      fileName: '$name.$_extension',
      type: FileType.custom,
      allowedExtensions: [_extension],
    );
    if (path == null) return;
    final lower = path.toLowerCase();
    final exportPath =
        lower.endsWith('.$_extension') ? path : '$path.$_extension';

    setState(() {
      _exporting = true;
      _error = null;
    });
    try {
      await _store.exportPack(
        instanceId: widget.instanceId,
        exportPath: exportPath,
        format: _format,
        packName: name,
        versionId: version,
        description: _descriptionController.text.trim().isEmpty
            ? null
            : _descriptionController.text.trim(),
        includeIds: includeIds,
        includePaths: _selectedPaths.toList(growable: false),
      );
      if (!mounted) return;
      await _close();
    } catch (_) {
      if (mounted) setState(() => _exporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final scheme = Theme.of(context).colorScheme;
    final maxH = MediaQuery.sizeOf(context).height * 0.86;

    return AnimatedModalDialog.fromMotion(
      motion: _motion,
      onClose: _exporting ? () {} : _close,
      child: ConstrainedBox(
        constraints: BoxConstraints(
          minWidth: 580,
          maxWidth: 580,
          maxHeight: maxH,
        ),
        child: Material(
          color: tokens.colorRaisedBg,
          borderRadius: BorderRadius.circular(20),
          clipBehavior: Clip.antiAlias,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                height: 64,
                child: Row(
                  children: [
                    const SizedBox(width: 28),
                    Text(
                      '导出整合包',
                      style: TextStyle(
                        fontSize: 20,
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                    const Spacer(),
                    CustomButton(
                      icon: Icons.close,
                      size: ButtonSize.medium,
                      backgroundColor: tokens.colorButtonBg.withAlpha(80),
                      onTap: _exporting ? () {} : _close,
                    ),
                    const SizedBox(width: 22),
                  ],
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: tokens.colorSecondary.withAlpha(35),
              ),
              Flexible(
                child: _loading
                    ? const Padding(
                        padding: EdgeInsets.all(40),
                        child: Center(
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.fromLTRB(28, 20, 28, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            if (_preview != null) ...[
                              Text(
                                '${_preview!.gameVersion} · ${_preview!.loader}',
                                style: TextStyle(
                                  fontSize: 13,
                                  color:
                                      tokens.colorBase.withValues(alpha: 0.7),
                                ),
                              ),
                              const SizedBox(height: 14),
                            ],
                            Text(
                              '名称',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            const SizedBox(height: 8),
                            InputBarWidget(
                              colorScheme: scheme,
                              controller: _nameController,
                              size: InputBarSize.medium,
                              hintText: '整合包名称',
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '版本',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            const SizedBox(height: 8),
                            InputBarWidget(
                              colorScheme: scheme,
                              controller: _versionController,
                              size: InputBarSize.medium,
                              hintText: '例如 1.0.0',
                            ),
                            const SizedBox(height: 14),
                            Text(
                              '描述（可选）',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            const SizedBox(height: 8),
                            InputBarWidget(
                              colorScheme: scheme,
                              controller: _descriptionController,
                              size: InputBarSize.medium,
                              hintText: '简短说明',
                            ),
                            const SizedBox(height: 18),
                            Text(
                              '导出格式',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            const SizedBox(height: 8),
                            IgnorePointer(
                              ignoring: _exporting,
                              child: ButtonGroupWidget(
                                fitContent: true,
                                selectedValue: _format,
                                selectedIcon: null,
                                onChanged: (value) =>
                                    setState(() => _format = value),
                                items: const [
                                  ButtonGroupItem(
                                    value: 'mrpack',
                                    text: 'Modrinth',
                                  ),
                                  ButtonGroupItem(
                                    value: 'multimc',
                                    text: 'MultiMC',
                                  ),
                                  ButtonGroupItem(
                                    value: 'mcbbs',
                                    text: 'MCBBS',
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(height: 18),
                            Row(
                              children: [
                                Text(
                                  '导出内容',
                                  style: TextStyle(
                                    fontWeight: FontWeight.w700,
                                    color: tokens.colorContrast,
                                  ),
                                ),
                                const Spacer(),
                                Text(
                                  '已选 ${_selectedPaths.length} 项',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: tokens.colorBase
                                        .withValues(alpha: 0.65),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '可勾选分类或单个文件；模组/资源包等会显示图标。',
                              style: TextStyle(
                                fontSize: 12,
                                color: tokens.colorBase.withValues(alpha: 0.65),
                              ),
                            ),
                            const SizedBox(height: 10),
                            ..._orderedCategories.map(
                              (cat) => _CategoryBlock(
                                tokens: tokens,
                                category: cat,
                                checkState: _categoryCheckState(cat),
                                expanded: _expanded.contains(cat.id),
                                selectedPaths: _selectedPaths,
                                enabled: !_exporting,
                                onToggleCategory: (v) =>
                                    _setCategorySelected(cat, v),
                                onToggleExpand: () => setState(() {
                                  if (_expanded.contains(cat.id)) {
                                    _expanded.remove(cat.id);
                                  } else {
                                    _expanded.add(cat.id);
                                  }
                                }),
                                onToggleFile: _toggleFile,
                              ),
                            ),
                            if (_error != null) ...[
                              const SizedBox(height: 12),
                              Text(
                                _error!,
                                style: TextStyle(
                                  color: scheme.error,
                                  fontSize: 12,
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(28, 8, 28, 22),
                child: Row(
                  children: [
                    NavRectButton(
                      text: '取消',
                      icon: Icons.close,
                      isSelected: false,
                      defaultBackgroundColor: tokens.colorButtonBg,
                      defaultColor: tokens.colorContrast,
                      hoverColor: tokens.colorButtonBgSelected,
                      hoverTextColor: tokens.colorButtonTextSelected,
                      onTap: _exporting ? () {} : _close,
                    ),
                    const Spacer(),
                    NavRectButton(
                      text: _exporting ? '导出中…' : '开始导出',
                      icon: Icons.upload_file_outlined,
                      isSelected: true,
                      onTap: (_exporting || _loading) ? () {} : _startExport,
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

class _CategoryBlock extends StatelessWidget {
  const _CategoryBlock({
    required this.tokens,
    required this.category,
    required this.checkState,
    required this.expanded,
    required this.selectedPaths,
    required this.enabled,
    required this.onToggleCategory,
    required this.onToggleExpand,
    required this.onToggleFile,
  });

  final AppThemeTokens tokens;
  final rust.PackContentCategoryDto category;
  final bool? checkState;
  final bool expanded;
  final Set<String> selectedPaths;
  final bool enabled;
  final ValueChanged<bool> onToggleCategory;
  final VoidCallback onToggleExpand;
  final ValueChanged<String> onToggleFile;

  @override
  Widget build(BuildContext context) {
    final empty = category.files.isEmpty;
    final selectedCount =
        category.files.where((f) => selectedPaths.contains(f.path)).length;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Material(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(12),
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 2, 6, 2),
              child: Row(
                children: [
                  Checkbox(
                    tristate: true,
                    value: empty ? false : checkState,
                    activeColor: tokens.colorBrand,
                    onChanged: (!enabled || empty)
                        ? null
                        : (v) => onToggleCategory(v ?? false),
                  ),
                  Icon(
                    _categoryIcon(category.id),
                    size: 18,
                    color: empty
                        ? tokens.colorBase.withValues(alpha: 0.4)
                        : tokens.colorBrand,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          category.label,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: empty
                                ? tokens.colorBase.withValues(alpha: 0.55)
                                : tokens.colorContrast,
                          ),
                        ),
                        Text(
                          empty
                              ? '无文件'
                              : '$selectedCount / ${category.fileCount} · ${_formatBytes(category.totalBytes)}',
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.colorBase.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (!empty)
                    IconButton(
                      tooltip: expanded ? '收起' : '展开',
                      onPressed: onToggleExpand,
                      icon: Icon(
                        expanded ? Icons.expand_less : Icons.expand_more,
                        color: tokens.colorBase,
                      ),
                    ),
                ],
              ),
            ),
            if (expanded && !empty)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 10, 10),
                child: Column(
                  children: [
                    for (final file in category.files)
                      _FileRow(
                        tokens: tokens,
                        file: file,
                        categoryId: category.id,
                        selected: selectedPaths.contains(file.path),
                        enabled: enabled,
                        onToggle: () => onToggleFile(file.path),
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

class _FileRow extends StatelessWidget {
  const _FileRow({
    required this.tokens,
    required this.file,
    required this.categoryId,
    required this.selected,
    required this.enabled,
    required this.onToggle,
  });

  final AppThemeTokens tokens;
  final rust.PackContentFileDto file;
  final String categoryId;
  final bool selected;
  final bool enabled;
  final VoidCallback onToggle;

  @override
  Widget build(BuildContext context) {
    final title = (file.title?.trim().isNotEmpty ?? false)
        ? file.title!.trim()
        : file.name;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(8),
        onTap: enabled ? onToggle : null,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 3),
          child: Row(
            children: [
              Checkbox(
                value: selected,
                activeColor: tokens.colorBrand,
                onChanged: enabled ? (_) => onToggle() : null,
              ),
              _ContentIcon(
                tokens: tokens,
                iconUrl: file.iconUrl,
                categoryId: categoryId,
              ),
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
                        fontWeight: FontWeight.w600,
                        fontSize: 13,
                        color: tokens.colorContrast,
                      ),
                    ),
                    Text(
                      '${file.name} · ${_formatBytes(file.sizeBytes)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 11,
                        color: tokens.colorBase.withValues(alpha: 0.6),
                      ),
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

class _ContentIcon extends StatelessWidget {
  const _ContentIcon({
    required this.tokens,
    required this.iconUrl,
    required this.categoryId,
  });

  final AppThemeTokens tokens;
  final String? iconUrl;
  final String categoryId;

  @override
  Widget build(BuildContext context) {
    final fallback = _iconFallback(tokens, categoryId);
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

Widget _iconFallback(AppThemeTokens tokens, String categoryId) {
  return Container(
    width: 28,
    height: 28,
    alignment: Alignment.center,
    decoration: BoxDecoration(
      color: tokens.colorButtonBg,
      borderRadius: BorderRadius.circular(6),
    ),
    child: Icon(
      _categoryIcon(categoryId),
      size: 16,
      color: tokens.colorBase.withValues(alpha: 0.75),
    ),
  );
}

IconData _categoryIcon(String id) {
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

String _formatBytes(BigInt bytes) {
  final n = bytes.toDouble();
  if (n < 1024) return '${n.toInt()} B';
  if (n < 1024 * 1024) return '${(n / 1024).toStringAsFixed(1)} KB';
  if (n < 1024 * 1024 * 1024) {
    return '${(n / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(n / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}
