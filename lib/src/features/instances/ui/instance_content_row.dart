import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/material.dart';

class InstanceContentRow extends StatelessWidget {
  const InstanceContentRow({
    super.key,
    required this.tokens,
    required this.instanceId,
    required this.mod,
    required this.busy,
    required this.updatingContentPaths,
    required this.onShowDetail,
    required this.onToggleEnabled,
    required this.onDownloadMissing,
    required this.onUpdate,
    required this.onSwitchVersion,
    required this.onDelete,
  });

  final AppThemeTokens tokens;
  final String instanceId;
  final rust.ModFileDto mod;
  final bool busy;
  final Set<String> updatingContentPaths;
  final VoidCallback onShowDetail;
  final Future<void> Function(bool enabled) onToggleEnabled;
  final VoidCallback onDownloadMissing;
  final VoidCallback onUpdate;
  final VoidCallback onSwitchVersion;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final title =
        mod.projectTitle?.isNotEmpty == true ? mod.projectTitle! : mod.name;
    final versionNumber = mod.versionNumber ?? mod.versionName;
    final fileName = mod.name;
    final author = mod.author;
    final canOpenProject = mod.projectId != null && mod.projectId!.isNotEmpty;
    final canOpenAuthor =
        mod.authorId != null && mod.authorId!.trim().isNotEmpty;
    final canSwitch = canOpenProject;

    void openProject() {
      if (canOpenProject) {
        getIt<NavigationState>().openProject(
          mod.projectId!,
          installInstanceId: instanceId,
        );
      } else {
        onShowDetail();
      }
    }

    void openAuthor() {
      final id = mod.authorId?.trim();
      if (id == null || id.isEmpty) return;
      final kind = (mod.authorType ?? 'user').toLowerCase() == 'organization'
          ? 'organization'
          : 'user';
      getIt<NavigationState>().openAuthor(
        id,
        type: kind,
        preview: AuthorPreview(
          id: id,
          type: kind,
          displayName: author ?? id,
          avatarUrl: mod.authorAvatarUrl,
        ),
      );
    }

    return Material(
      color: tokens.colorRaisedBg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: openProject,
        hoverColor: tokens.colorSuperRaisedBg.withValues(alpha: 0.65),
        splashColor: tokens.colorBrand.withValues(alpha: 0.12),
        highlightColor: tokens.colorBrand.withValues(alpha: 0.06),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
          child: Row(
            children: [
              Expanded(
                flex: 5,
                child: Row(
                  children: [
                    ExcludeSemantics(
                      child: mod.projectIconUrl != null &&
                              mod.projectIconUrl!.isNotEmpty
                          ? CachedRemoteImage(
                              url: mod.projectIconUrl!,
                              width: 40,
                              height: 40,
                              borderRadius: BorderRadius.circular(8),
                              placeholder: _iconFallback(tokens),
                              error: _iconFallback(tokens),
                            )
                          : _iconFallback(tokens),
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
                              fontWeight: FontWeight.w800,
                              color: tokens.colorContrast,
                              decoration: !mod.isMissing && !mod.enabled
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                          ),
                          const SizedBox(height: 2),
                          if (!mod.isMissing &&
                              author != null &&
                              author.isNotEmpty)
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: canOpenAuthor ? openAuthor : null,
                              child: MouseRegion(
                                cursor: canOpenAuthor
                                    ? SystemMouseCursors.click
                                    : SystemMouseCursors.basic,
                                child: Row(
                                  children: [
                                    if (mod.authorAvatarUrl != null &&
                                        mod.authorAvatarUrl!.isNotEmpty)
                                      Padding(
                                        padding:
                                            const EdgeInsets.only(right: 6),
                                        child: CachedRemoteImage(
                                          url: mod.authorAvatarUrl!,
                                          width: 14,
                                          height: 14,
                                          borderRadius:
                                              BorderRadius.circular(7),
                                          placeholder: const SizedBox.shrink(),
                                          error: const SizedBox.shrink(),
                                        ),
                                      ),
                                    Flexible(
                                      child: Text(
                                        author,
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: tokens.colorBase
                                              .withValues(alpha: 0.7),
                                          decoration: canOpenAuthor
                                              ? TextDecoration.underline
                                              : null,
                                          decorationColor: tokens.colorBase
                                              .withValues(alpha: 0.35),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            )
                          else
                            Text(
                              mod.isMissing
                                  ? '未下载 · ${contentTypeLabel(mod.projectType)}'
                                  : mod.projectId == null
                                      ? '本地文件 · ${contentTypeLabel(mod.projectType)}'
                                      : '${sourceLabel(contentSourceOf(projectId: mod.projectId))} · ${contentTypeLabel(mod.projectType)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: tokens.colorBase.withValues(alpha: 0.65),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
              Expanded(
                flex: 4,
                // Absorb taps so version area does not open project; switch via button only.
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () {},
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        versionNumber ?? '未知版本',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                      Text(
                        [
                          if (mod.projectId != null)
                            sourceLabel(
                              contentSourceOf(projectId: mod.projectId),
                            ),
                          fileName,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.colorBase.withValues(alpha: 0.65),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              SizedBox(
                width: mod.isMissing ? 196 : 168,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (mod.isMissing)
                      TextButton.icon(
                        onPressed: busy ? null : onDownloadMissing,
                        icon: updatingContentPaths.contains(mod.relativePath)
                            ? SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: tokens.colorBrand,
                                ),
                              )
                            : Icon(
                                Icons.download_rounded,
                                size: 18,
                                color: tokens.colorBrand,
                              ),
                        label: Text(
                          '下载',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorBrand,
                          ),
                        ),
                      )
                    else if (mod.hasUpdate)
                      _tooltipIconButton(
                        message: '更新',
                        onPressed: busy ? null : onUpdate,
                        icon: updatingContentPaths.contains(mod.relativePath)
                            ? SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: tokens.colorBrand,
                                ),
                              )
                            : Icon(
                                Icons.download_rounded,
                                color: tokens.colorBrand,
                              ),
                      )
                    else if (canSwitch)
                      _tooltipIconButton(
                        message: '切换版本',
                        onPressed: busy ? null : onSwitchVersion,
                        icon: Icon(
                          Icons.swap_horiz_rounded,
                          color: tokens.colorBase.withValues(alpha: 0.85),
                        ),
                      ),
                    if (!mod.isMissing)
                      Switch(
                        value: mod.enabled,
                        activeThumbColor: tokens.colorOnBrand,
                        activeTrackColor: tokens.colorBrand,
                        onChanged: (v) => onToggleEnabled(v),
                      ),
                    _tooltipIconButton(
                      message: '删除',
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        color: tokens.colorBase.withValues(alpha: 0.85),
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

Widget _tooltipIconButton({
  required String message,
  required VoidCallback? onPressed,
  required Widget icon,
}) {
  // Windows AXTree breaks when Tooltip overlays are scrolled out of a ListView.
  return Tooltip(
    message: message,
    excludeFromSemantics: true,
    waitDuration: const Duration(milliseconds: 400),
    child: IconButton(
      onPressed: onPressed,
      icon: icon,
    ),
  );
}

Widget _iconFallback(tokens) {
  return Container(
    width: 40,
    height: 40,
    color: tokens.colorSuperRaisedBg,
    child: Icon(Icons.extension, color: tokens.colorContrast),
  );
}
