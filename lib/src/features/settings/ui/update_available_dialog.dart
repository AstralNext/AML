import 'package:aml/src/features/settings/application/app_update_service.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';

enum UpdateDialogAction { later, skip, open }

Future<UpdateDialogAction?> showUpdateAvailableDialog(
  BuildContext context, {
  required AppUpdateInfo update,
  bool allowSkip = true,
}) {
  return showDialog<UpdateDialogAction>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _UpdateAvailableDialog(
      update: update,
      allowSkip: allowSkip,
    ),
  );
}

class _UpdateAvailableDialog extends StatelessWidget {
  const _UpdateAvailableDialog({
    required this.update,
    required this.allowSkip,
  });

  final AppUpdateInfo update;
  final bool allowSkip;

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final notes = (update.body ?? '').trim();
    final preview = notes.isEmpty
        ? '发现新版本，建议前往发布页查看更新说明并下载。'
        : (notes.length > 420 ? '${notes.substring(0, 420)}…' : notes);

    return AlertDialog(
      backgroundColor: tokens.colorRaisedBg,
      title: Text(
        '发现新版本',
        style: TextStyle(
          color: tokens.colorContrast,
          fontWeight: FontWeight.w800,
        ),
      ),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '${update.currentVersion}  →  ${update.latestVersion}',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: tokens.colorBrand,
              ),
            ),
            if (update.releaseName.isNotEmpty) ...[
              const SizedBox(height: 6),
              Text(
                update.releaseName,
                style: TextStyle(
                  fontSize: 13,
                  color: tokens.colorContrast.withValues(alpha: 0.9),
                ),
              ),
            ],
            if (update.prerelease) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: tokens.colorButtonBg,
                  borderRadius: BorderRadius.circular(999),
                ),
                child: Text(
                  '预发布',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: tokens.colorBase,
                  ),
                ),
              ),
            ],
            const SizedBox(height: 12),
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 180),
              child: SingleChildScrollView(
                child: Text(
                  preview,
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: tokens.colorBase.withValues(alpha: 0.85),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 14),
      actions: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: [
            NavRectButton(
              isSelected: false,
              icon: Icons.schedule,
              text: '稍后',
              defaultBackgroundColor: tokens.colorButtonBg,
              defaultColor: tokens.colorContrast,
              onTap: () => Navigator.pop(context, UpdateDialogAction.later),
            ),
            if (allowSkip)
              NavRectButton(
                isSelected: false,
                icon: Icons.notifications_off_outlined,
                text: '跳过此版本',
                defaultBackgroundColor: tokens.colorButtonBg,
                defaultColor: tokens.colorContrast,
                onTap: () => Navigator.pop(context, UpdateDialogAction.skip),
              ),
            NavRectButton(
              isSelected: true,
              icon: Icons.open_in_new,
              text: update.downloadUrl != null ? '下载更新' : '查看发布',
              selectedBackgroundColor: tokens.colorBrand,
              selectedColor: tokens.colorOnBrand,
              onTap: () async {
                final url = update.downloadUrl ?? update.htmlUrl;
                await _open(url);
                if (context.mounted) {
                  Navigator.pop(context, UpdateDialogAction.open);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}
