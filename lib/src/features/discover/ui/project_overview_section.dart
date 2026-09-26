import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/features/discover/ui/project_gallery_carousel.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:aml/src/shared/widgets/components/common/markdown_content.dart';
import 'package:flutter/material.dart';

/// 项目详情页「概述」标签页：画廊、分类/加载器标签、侧栏信息与介绍正文。
class ProjectOverviewSection extends StatelessWidget {
  const ProjectOverviewSection({
    super.key,
    required this.project,
    required this.showOriginal,
    required this.translating,
    required this.onToggleOriginal,
  });

  final ModrinthProjectDetail project;
  final bool showOriginal;
  final bool translating;
  final ValueChanged<bool> onToggleOriginal;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final gallery = project.gallery.where((g) => g.url.isNotEmpty).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (gallery.isNotEmpty) ...[
            ProjectGalleryCarousel(
              gallery: gallery,
              onTap: (index) {
                showImageLightbox(
                  context,
                  urls: gallery.map((g) => g.url).toList(),
                  initialIndex: index,
                  titles: gallery.map((g) => g.title).toList(),
                );
              },
            ),
            const SizedBox(height: 16),
          ],
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final cat in project.categories)
                Chip(
                  label: Text(displayCategory(cat)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: tokens.colorRaisedBg,
                ),
              for (final loader in project.loaders.take(6))
                Chip(
                  label: Text(displayLoader(loader)),
                  visualDensity: VisualDensity.compact,
                  backgroundColor: tokens.colorBrandHighlight,
                  labelStyle: TextStyle(
                    color: tokens.colorBrand,
                    fontWeight: FontWeight.w700,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          _sideInfo(tokens),
          const SizedBox(height: 16),
          Row(
            children: [
              Expanded(
                child: Text(
                  '介绍',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              SegmentedButton<bool>(
                style: ButtonStyle(
                  visualDensity: VisualDensity.compact,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  textStyle: WidgetStatePropertyAll(
                    TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w700,
                      color: tokens.colorContrast,
                    ),
                  ),
                ),
                segments: [
                  ButtonSegment<bool>(
                    value: false,
                    label: translating
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              SizedBox(
                                width: 12,
                                height: 12,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              ),
                              SizedBox(width: 4),
                              Text('译文'),
                            ],
                          )
                        : const Text('译文'),
                  ),
                  const ButtonSegment<bool>(
                    value: true,
                    label: Text('原文'),
                  ),
                ],
                selected: {showOriginal},
                onSelectionChanged: (next) {
                  if (next.isEmpty) return;
                  onToggleOriginal(next.first);
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          MarkdownContent(
            data: project.displayBody(original: showOriginal),
          ),
        ],
      ),
    );
  }

  Widget _sideInfo(tokens) {
    final games = project.gameVersions.reversed.take(8).toList().reversed;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _infoLine(
            tokens,
            '许可证',
            project.licenseName.isEmpty
                ? (project.licenseId.isEmpty ? '—' : project.licenseId)
                : project.licenseName,
          ),
          _infoLine(
            tokens,
            '游戏版本',
            games.isEmpty ? '—' : games.join(', '),
          ),
          _infoLine(
            tokens,
            '加载器',
            project.loaders.isEmpty
                ? '—'
                : project.loaders.map(displayLoader).join(', '),
          ),
        ],
      ),
    );
  }

  Widget _infoLine(tokens, String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              label,
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
          ),
          Expanded(
            child: Text(value, style: TextStyle(color: tokens.colorContrast)),
          ),
        ],
      ),
    );
  }
}
