import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/utils/format.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_controller.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class CreateInstanceImportPreviewStage extends StatelessWidget {
  const CreateInstanceImportPreviewStage({
    super.key,
    required this.tokens,
    required this.controller,
    required this.colorScheme,
  });

  final AppThemeTokens tokens;
  final CreateInstanceController controller;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    final preview = controller.importPreview;
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
                  colorScheme: colorScheme,
                  controller: controller.importNameController,
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
                    final expanded = controller.importExpanded.contains(cat.id);
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
                                  : () => controller.toggleImportCategory(
                                        cat.id,
                                      ),
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
                                            '${cat.fileCount} 个文件 · ${formatBytes(cat.totalBytes.toInt())}',
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
                                                    '${file.name} · ${formatBytes(file.sizeBytes.toInt())}',
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
                if (controller.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    controller.error!,
                    style: TextStyle(
                      color: colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
                if (controller.creating) ...[
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
                onTap: controller.creating
                    ? () {}
                    : controller.backFromImportPreviewStage,
              ),
              const Spacer(),
              NavRectButton(
                text: controller.creating ? '导入中…' : '开始导入',
                icon: Icons.download_outlined,
                isSelected: true,
                onTap: controller.creating ? () {} : controller.confirmImportPack,
              ),
            ],
          ),
        ),
      ],
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
