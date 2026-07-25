import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/material.dart';

/// Discover list card layout.
class AppCard extends StatelessWidget {
  final String title;
  final String description;
  final String author;
  final int downloads;
  final int followers;
  final String iconUrl;
  final String installLabel;
  final VoidCallback? onInstall;
  final VoidCallback? onTap;
  final VoidCallback? onAuthorTap;
  final bool installing;
  final bool installDisabled;
  final List<String> categories;
  final List<String>? displayCategories;
  /// Supported Minecraft versions (shown for modpacks on the outer card).
  final List<String> gameVersions;
  final String projectType;
  final String dateCreated;
  final String dateModified;
  final bool showPublishedDate;
  final int maxTags;

  const AppCard({
    super.key,
    required this.title,
    required this.description,
    required this.author,
    required this.downloads,
    this.followers = 0,
    required this.iconUrl,
    this.installLabel = '安装',
    this.onInstall,
    this.onTap,
    this.onAuthorTap,
    this.installing = false,
    this.installDisabled = false,
    this.categories = const [],
    this.displayCategories,
    this.gameVersions = const [],
    this.projectType = '',
    this.dateCreated = '',
    this.dateModified = '',
    this.showPublishedDate = false,
    this.maxTags = 4,
  });

  static const _iconSize = 68.0;

  static const _loaderIds = {
    'fabric',
    'forge',
    'neoforge',
    'quilt',
    'iris',
    'optifine',
    'canvas',
    'vanilla',
  };

  List<String> get _tagIds {
    final raw = (displayCategories != null && displayCategories!.isNotEmpty)
        ? displayCategories!
        : categories;
    final out = <String>[];
    for (final id in raw) {
      final key = id.toLowerCase();
      if (_loaderIds.contains(key)) continue;
      if (!out.contains(id)) out.add(id);
    }
    return out;
  }

  List<String> get _versionLabels {
    if (projectType != 'modpack') return const [];
    return summarizeGameVersions(gameVersions, maxVisible: 4);
  }

  String get _dateLabel {
    final iso = showPublishedDate ? dateCreated : dateModified;
    if (iso.isEmpty) return '';
    return ModrinthApiService.formatRelativeTime(iso);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final tagIds = _tagIds;
    final versionLabels = _versionLabels;
    final visibleTags = tagIds.take(maxTags).toList();
    final overflow = tagIds.length - visibleTags.length;
    final canInstall = !installing && !installDisabled && onInstall != null;
    final hasRemoteIcon = Uri.tryParse(iconUrl)?.hasAbsolutePath ?? false;
    final dateLabel = _dateLabel;
    final showFooter = versionLabels.isNotEmpty ||
        visibleTags.isNotEmpty ||
        dateLabel.isNotEmpty;

    return Material(
      color: tokens.colorRaisedBg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        borderRadius: BorderRadius.circular(16),
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: tokens.colorSecondary.withValues(alpha: 0.22),
            ),
          ),
          padding: const EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _ProjectIcon(
                    size: _iconSize,
                    iconUrl: iconUrl,
                    hasRemoteIcon: hasRemoteIcon,
                    tokens: tokens,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              _TitleAuthorRow(
                                title: title,
                                author: author,
                                tokens: tokens,
                                onAuthorTap: onAuthorTap,
                              ),
                              const SizedBox(height: 4),
                              Text(
                                description,
                                maxLines: 2,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tokens.colorBase
                                      .withValues(alpha: 0.78),
                                  fontSize: 14,
                                  height: 1.4,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.end,
                          children: [
                            _InstallButton(
                              label: installing ? '安装中…' : installLabel,
                              enabled: canInstall,
                              disabled: installDisabled || installing,
                              onPressed: canInstall ? onInstall : null,
                              tokens: tokens,
                            ),
                            const SizedBox(height: 10),
                            _DownloadsFollowersRow(
                              downloads: downloads,
                              followers: followers,
                              tokens: tokens,
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (showFooter) ...[
                const SizedBox(height: 10),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        alignment: WrapAlignment.start,
                        children: [
                          for (final label in versionLabels)
                            _TagChip(
                              label: label,
                              tokens: tokens,
                              emphasize: true,
                            ),
                          for (final id in visibleTags)
                            _TagChip(
                              label: displayCategory(id),
                              tokens: tokens,
                            ),
                          if (overflow > 0)
                            _TagChip(
                              label: '+$overflow',
                              tokens: tokens,
                            ),
                        ],
                      ),
                    ),
                    if (dateLabel.isNotEmpty) ...[
                      const SizedBox(width: 12),
                      _StatRow(
                        icon: Icons.history_rounded,
                        value: dateLabel,
                        tokens: tokens,
                      ),
                    ],
                  ],
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class _ProjectIcon extends StatelessWidget {
  const _ProjectIcon({
    required this.size,
    required this.iconUrl,
    required this.hasRemoteIcon,
    required this.tokens,
  });

  final double size;
  final String iconUrl;
  final bool hasRemoteIcon;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: tokens.colorSecondary.withValues(alpha: 0.15),
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: hasRemoteIcon
          ? CachedRemoteImage(
              url: iconUrl,
              width: size,
              height: size,
              placeholder: Image.asset('assets/logo.png', fit: BoxFit.cover),
              error: Image.asset('assets/logo.png', fit: BoxFit.cover),
            )
          : Image.asset('assets/logo.png', fit: BoxFit.cover),
    );
  }
}

class _TitleAuthorRow extends StatelessWidget {
  const _TitleAuthorRow({
    required this.title,
    required this.author,
    required this.tokens,
    this.onAuthorTap,
  });

  final String title;
  final String author;
  final AppThemeTokens tokens;
  final VoidCallback? onAuthorTap;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 2,
      children: [
        Text(
          title,
          style: TextStyle(
            color: tokens.colorContrast,
            fontSize: 17,
            fontWeight: FontWeight.w800,
            height: 1.2,
          ),
        ),
        if (author.isNotEmpty)
          onAuthorTap != null
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTap: onAuthorTap,
                    child: Text(
                      'by $author',
                      style: TextStyle(
                        color: tokens.colorBrand,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        decoration: TextDecoration.underline,
                        decorationColor:
                            tokens.colorBrand.withValues(alpha: 0.55),
                      ),
                    ),
                  ),
                )
              : Text(
                  'by $author',
                  style: TextStyle(
                    color: tokens.colorBase.withValues(alpha: 0.72),
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                  ),
                ),
      ],
    );
  }
}

class _InstallButton extends StatelessWidget {
  const _InstallButton({
    required this.label,
    required this.enabled,
    required this.disabled,
    required this.onPressed,
    required this.tokens,
  });

  final String label;
  final bool enabled;
  final bool disabled;
  final VoidCallback? onPressed;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    final brand = tokens.colorBrand;
    final isInstalled = disabled && label == '已安装';

    return OutlinedButton.icon(
      onPressed: onPressed,
      icon: Icon(
        isInstalled ? Icons.check_rounded : Icons.add_rounded,
        size: 18,
      ),
      label: Text(label),
      style: OutlinedButton.styleFrom(
        foregroundColor: disabled
            ? tokens.colorBase.withValues(alpha: 0.75)
            : brand,
        disabledForegroundColor: tokens.colorBase.withValues(alpha: 0.55),
        side: BorderSide(
          color: disabled
              ? tokens.colorSecondary.withValues(alpha: 0.35)
              : brand.withValues(alpha: enabled ? 1 : 0.45),
          width: 1.5,
        ),
        backgroundColor: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        minimumSize: const Size(108, 40),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        textStyle: const TextStyle(
          fontFamily: 'MiSans',
          fontSize: 14,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _DownloadsFollowersRow extends StatelessWidget {
  const _DownloadsFollowersRow({
    required this.downloads,
    required this.followers,
    required this.tokens,
  });

  final int downloads;
  final int followers;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _StatRow(
          icon: Icons.download_rounded,
          value: ModrinthApiService.formatDownloadCount(downloads),
          tokens: tokens,
        ),
        const SizedBox(width: 14),
        _StatRow(
          icon: Icons.favorite_border_rounded,
          value: ModrinthApiService.formatDownloadCount(followers),
          tokens: tokens,
        ),
      ],
    );
  }
}

class _StatRow extends StatelessWidget {
  const _StatRow({
    required this.icon,
    required this.value,
    required this.tokens,
    this.iconSize = 22,
    this.fontSize = 16,
  });

  final IconData icon;
  final String value;
  final AppThemeTokens tokens;
  final double iconSize;
  final double fontSize;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: iconSize,
          color: tokens.colorBase.withValues(alpha: 0.62),
        ),
        const SizedBox(width: 6),
        Text(
          value,
          style: TextStyle(
            color: tokens.colorBase.withValues(alpha: 0.88),
            fontSize: fontSize,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
  }
}

class _TagChip extends StatelessWidget {
  const _TagChip({
    required this.label,
    required this.tokens,
    this.emphasize = false,
  });

  final String label;
  final AppThemeTokens tokens;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: emphasize
            ? tokens.colorBrand.withValues(alpha: 0.14)
            : tokens.colorButtonBg.withValues(alpha: 0.85),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(
          color: emphasize
              ? tokens.colorBrand.withValues(alpha: 0.35)
              : tokens.colorSecondary.withValues(alpha: 0.18),
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: emphasize
              ? tokens.colorBrand
              : tokens.colorContrast.withValues(alpha: 0.88),
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
