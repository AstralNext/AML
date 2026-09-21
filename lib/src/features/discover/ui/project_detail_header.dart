import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/features/discover/ui/project_environment.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:flutter/material.dart';

String _firstCategoryLabelFrom({
  required List<String> categories,
  List<String>? displayCategories,
}) {
  final raw = (displayCategories != null && displayCategories.isNotEmpty)
      ? displayCategories
      : categories;
  for (final id in raw) {
    final label = displayCategory(id);
    if (label.isNotEmpty) return label;
  }
  return '';
}

String _projectTypeLabel(String type) {
  switch (type) {
    case 'mod':
      return '模组';
    case 'modpack':
      return '整合包';
    case 'resourcepack':
      return '资源包';
    case 'shader':
      return '光影';
    case 'datapack':
      return '数据包';
    default:
      return type;
  }
}

/// 项目详情页头部：返回按钮、图标、标题、作者、简介、元信息与安装按钮。
class ProjectDetailHeader extends StatelessWidget {
  const ProjectDetailHeader({
    super.key,
    required this.title,
    required this.description,
    required this.iconUrl,
    required this.downloads,
    required this.followers,
    required this.projectType,
    required this.clientSide,
    required this.serverSide,
    required this.categories,
    this.displayCategories,
    required this.installLabel,
    required this.installEnabled,
    this.installDisabledStyle = false,
    this.onInstall,
    this.author,
    this.onAuthorTap,
    required this.onBack,
  });

  final String title;
  final String description;
  final String? iconUrl;
  final int downloads;
  final int followers;
  final String projectType;
  final String clientSide;
  final String serverSide;
  final List<String> categories;
  final List<String>? displayCategories;
  final String installLabel;
  final bool installEnabled;
  final bool installDisabledStyle;
  final VoidCallback? onInstall;
  final ModrinthAuthor? author;
  final VoidCallback? onAuthorTap;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final env = ProjectEnvironmentBadge.fromSides(
      clientSide: clientSide,
      serverSide: serverSide,
      projectType: projectType,
    );
    final categoryLabel = _firstCategoryLabelFrom(
      categories: categories,
      displayCategories: displayCategories,
    );
    final showDisabled = !installEnabled || installDisabledStyle;

    Widget metaPlain(IconData icon, String label) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 18, color: tokens.colorBase.withValues(alpha: 0.7)),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorBase.withValues(alpha: 0.85),
            ),
          ),
        ],
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CustomButton(
            icon: Icons.arrow_back,
            size: ButtonSize.medium,
            onTap: onBack,
          ),
          const SizedBox(width: 14),
          iconUrl != null && iconUrl!.isNotEmpty
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => showImageLightbox(
                      context,
                      urls: [iconUrl!],
                    ),
                    child: CachedRemoteImage(
                      url: iconUrl!,
                      width: 84,
                      height: 84,
                      borderRadius: BorderRadius.circular(14),
                      placeholder: Container(
                        width: 84,
                        height: 84,
                        color: tokens.colorSuperRaisedBg,
                        child: Icon(
                          Icons.extension,
                          color: tokens.colorContrast,
                        ),
                      ),
                      error: Container(
                        width: 84,
                        height: 84,
                        color: tokens.colorSuperRaisedBg,
                        child: Icon(
                          Icons.extension,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ),
                  ),
                )
              : Container(
                  width: 84,
                  height: 84,
                  decoration: BoxDecoration(
                    color: tokens.colorSuperRaisedBg,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Icon(
                    Icons.extension,
                    color: tokens.colorContrast,
                  ),
                ),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
                if (author != null) ...[
                  const SizedBox(height: 6),
                  MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: GestureDetector(
                      onTap: onAuthorTap,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (author!.avatarUrl != null &&
                              author!.avatarUrl!.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(right: 6),
                              child: CachedRemoteImage(
                                url: author!.avatarUrl!,
                                width: 18,
                                height: 18,
                                borderRadius: BorderRadius.circular(9),
                                placeholder: const SizedBox.shrink(),
                                error: const SizedBox.shrink(),
                              ),
                            ),
                          Flexible(
                            child: Text(
                              'by ${author!.displayName}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w600,
                                color: tokens.colorBrand,
                                decoration: TextDecoration.underline,
                                decorationColor:
                                    tokens.colorBrand.withValues(alpha: 0.55),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 6),
                Text(
                  description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 14,
                    height: 1.35,
                    color: tokens.colorBase.withValues(alpha: 0.8),
                  ),
                ),
                const SizedBox(height: 10),
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    metaPlain(
                      Icons.download_rounded,
                      ModrinthApiService.formatDownloadCount(downloads),
                    ),
                    metaPlain(
                      Icons.favorite_border_rounded,
                      ModrinthApiService.formatDownloadCount(followers),
                    ),
                    Text(
                      categoryLabel.isNotEmpty
                          ? categoryLabel
                          : _projectTypeLabel(projectType),
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                        color: tokens.colorBase.withValues(alpha: 0.8),
                      ),
                    ),
                    if (env != null) EnvironmentBadgeChip(badge: env),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          FilledButton.icon(
            onPressed: installEnabled ? onInstall : null,
            icon: Icon(
              installDisabledStyle ? Icons.check : Icons.download_rounded,
              size: 18,
            ),
            label: Text(installLabel),
            style: FilledButton.styleFrom(
              backgroundColor:
                  showDisabled ? tokens.colorButtonBg : tokens.colorBrand,
              foregroundColor:
                  showDisabled ? tokens.colorContrast : tokens.colorOnBrand,
              disabledBackgroundColor: tokens.colorButtonBg,
              disabledForegroundColor:
                  tokens.colorContrast.withValues(alpha: 0.85),
              elevation: 0,
              padding: const EdgeInsets.symmetric(
                horizontal: 18,
                vertical: 14,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
