import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/material.dart';

/// Home / discover project card — gallery cover, icon, stats, tags.
class DiscoverBox extends StatelessWidget {
  final ModrinthProject result;

  const DiscoverBox({super.key, required this.result});

  String? get _coverUrl {
    if (result.featuredGallery != null && result.featuredGallery!.isNotEmpty) {
      return result.featuredGallery;
    }
    if (result.gallery != null && result.gallery!.isNotEmpty) {
      return result.gallery!.first;
    }
    return null;
  }

  List<String> get _tags {
    final raw = (result.displayCategories != null &&
            result.displayCategories!.isNotEmpty)
        ? result.displayCategories!
        : result.categories;
    final out = <String>[];
    for (final id in raw) {
      final label = displayCategory(id);
      if (label.isEmpty) continue;
      if (!out.contains(label)) out.add(label);
      if (out.isNotEmpty) break;
    }
    return out;
  }

  List<String> get _versionLabels {
    if (result.projectType != 'modpack') return const [];
    return summarizeGameVersions(result.versions, maxVisible: 3);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final coverUrl = _coverUrl;
    final tags = _tags;
    final versionLabels = _versionLabels;
    final hasIcon = result.iconUrl != null && result.iconUrl!.isNotEmpty;

    return Material(
      color: tokens.colorRaisedBg,
      borderRadius: BorderRadius.circular(14),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => getIt<NavigationState>().openProject(
          result.projectId,
          preview: ProjectPreview.fromSearch(result),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: coverUrl != null
                  ? CachedRemoteImage(
                      url: coverUrl,
                      fit: BoxFit.cover,
                      width: double.infinity,
                      height: double.infinity,
                      placeholder: ColoredBox(
                        color: tokens.colorSuperRaisedBg,
                        child: const Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                      error: _CoverFallback(
                        iconUrl: result.iconUrl,
                        color: tokens.colorSuperRaisedBg,
                      ),
                    )
                  : _CoverFallback(
                      iconUrl: result.iconUrl,
                      color: tokens.colorSuperRaisedBg,
                    ),
            ),
            Expanded(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        ClipRRect(
                          borderRadius: BorderRadius.circular(8),
                          child: hasIcon
                              ? CachedRemoteImage(
                                  url: result.iconUrl!,
                                  width: 36,
                                  height: 36,
                                  placeholder: _IconPlaceholder(
                                    color: tokens.colorButtonBg,
                                  ),
                                  error: _IconPlaceholder(
                                    color: tokens.colorButtonBg,
                                  ),
                                )
                              : _IconPlaceholder(color: tokens.colorButtonBg),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            result.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: tokens.colorContrast,
                              fontWeight: FontWeight.w800,
                              fontSize: 17,
                              height: 1.2,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: Text(
                        result.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.72),
                          fontSize: 13,
                          height: 1.35,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        Icon(
                          Icons.download_rounded,
                          size: 18,
                          color: tokens.colorBase.withValues(alpha: 0.65),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          ModrinthApiService.formatDownloadCount(
                            result.downloads,
                          ),
                          style: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.8),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(width: 14),
                        Icon(
                          Icons.favorite_border_rounded,
                          size: 17,
                          color: tokens.colorBase.withValues(alpha: 0.65),
                        ),
                        const SizedBox(width: 5),
                        Text(
                          ModrinthApiService.formatDownloadCount(
                            result.follows,
                          ),
                          style: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.8),
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        if (versionLabels.isNotEmpty) ...[
                          const SizedBox(width: 14),
                          Icon(
                            Icons.sports_esports_outlined,
                            size: 16,
                            color: tokens.colorBase.withValues(alpha: 0.55),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              versionLabels.join(' · '),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: tokens.colorContrast.withValues(
                                  alpha: 0.88,
                                ),
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                        ] else if (tags.isNotEmpty) ...[
                          const SizedBox(width: 14),
                          Icon(
                            Icons.sell_outlined,
                            size: 16,
                            color: tokens.colorBase.withValues(alpha: 0.55),
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 9,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: tokens.colorButtonBg.withValues(
                                  alpha: 0.9,
                                ),
                                borderRadius: BorderRadius.circular(999),
                              ),
                              child: Text(
                                tags.first,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tokens.colorContrast.withValues(
                                    alpha: 0.88,
                                  ),
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _IconPlaceholder extends StatelessWidget {
  final Color color;

  const _IconPlaceholder({required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 36,
      height: 36,
      color: color.withValues(alpha: 0.55),
      alignment: Alignment.center,
      child: Icon(
        Icons.extension,
        size: 18,
        color: context.tokens.colorContrast.withValues(alpha: 0.7),
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  final String? iconUrl;
  final Color color;

  const _CoverFallback({required this.iconUrl, required this.color});

  @override
  Widget build(BuildContext context) {
    final hasIcon = iconUrl != null && iconUrl!.isNotEmpty;
    return ColoredBox(
      color: color,
      child: Center(
        child: hasIcon
            ? CachedRemoteImage(
                url: iconUrl!,
                width: 64,
                height: 64,
                borderRadius: BorderRadius.circular(12),
                placeholder: Icon(
                  Icons.image_outlined,
                  color: context.tokens.colorBase.withValues(alpha: 0.4),
                ),
                error: Icon(
                  Icons.image_outlined,
                  color: context.tokens.colorBase.withValues(alpha: 0.4),
                ),
              )
            : Icon(
                Icons.image_outlined,
                size: 36,
                color: context.tokens.colorBase.withValues(alpha: 0.4),
              ),
      ),
    );
  }
}
