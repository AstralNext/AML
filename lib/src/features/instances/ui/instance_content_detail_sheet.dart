import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/material.dart';

void showInstanceContentDetailSheet({
  required BuildContext context,
  required rust.ModFileDto mod,
  String? instanceId,
}) {
  final tokens = context.tokens;
  final title =
      mod.projectTitle?.isNotEmpty == true ? mod.projectTitle! : mod.name;
  showModalBottomSheet<void>(
    context: context,
    backgroundColor: tokens.colorRaisedBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                if (mod.projectIconUrl != null &&
                    mod.projectIconUrl!.isNotEmpty)
                  CachedRemoteImage(
                    url: mod.projectIconUrl!,
                    width: 48,
                    height: 48,
                    borderRadius: BorderRadius.circular(10),
                    placeholder: Icon(
                      Icons.extension,
                      size: 48,
                      color: tokens.colorContrast,
                    ),
                    error: Icon(
                      Icons.extension,
                      size: 48,
                      color: tokens.colorContrast,
                    ),
                  )
                else
                  Icon(Icons.extension, size: 48, color: tokens.colorContrast),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
                      Text(
                        mod.projectType,
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            _detailRow(tokens, '文件', mod.name),
            _detailRow(tokens, '路径', mod.relativePath),
            if (mod.versionNumber != null)
              _detailRow(tokens, '版本号', mod.versionNumber!),
            if (mod.versionName != null)
              _detailRow(tokens, '版本名', mod.versionName!),
            if (mod.versionId != null)
              _detailRow(tokens, 'Version ID', mod.versionId!),
            if (mod.projectId != null) ...[
              _detailRow(tokens, 'Project ID', mod.projectId!),
              _detailRow(
                tokens,
                '来源',
                sourceLabel(contentSourceOf(projectId: mod.projectId)),
              ),
            ],
            _detailRow(
              tokens,
              '大小',
              '${(mod.sizeBytes.toDouble() / 1024).toStringAsFixed(1)} KB',
            ),
            _detailRow(tokens, '状态', mod.enabled ? '已启用' : '已禁用'),
            if (mod.projectId != null) ...[
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: tokens.colorBrand,
                    foregroundColor: tokens.colorOnBrand,
                    elevation: 0,
                  ),
                  onPressed: () {
                    Navigator.pop(ctx);
                    getIt<NavigationState>().openProject(
                      mod.projectId!,
                      installInstanceId: instanceId,
                    );
                  },
                  child: const Text('查看详情'),
                ),
              ),
            ],
          ],
        ),
      );
    },
  );
}

Widget _detailRow(tokens, String label, String value) {
  return Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 88,
          child: Text(
            label,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.colorBase.withValues(alpha: 0.7),
            ),
          ),
        ),
        Expanded(
          child: SelectableText(
            value,
            style: TextStyle(color: tokens.colorContrast),
          ),
        ),
      ],
    ),
  );
}
