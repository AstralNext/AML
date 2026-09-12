import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/button_group_widget.dart';
import 'package:flutter/material.dart';

class WorldBackupCreateOptions {
  const WorldBackupCreateOptions({
    required this.compression,
  });

  /// `store` | `fast` | `balanced` | `max`
  final String compression;
}

/// Dialog to pick compression before creating a full world backup.
Future<WorldBackupCreateOptions?> showWorldBackupCreateDialog(
  BuildContext context,
) {
  var compression = 'balanced';

  return showDialog<WorldBackupCreateOptions>(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          final tokens = ctx.tokens;
          return AlertDialog(
            title: const Text('创建备份'),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '压缩效率',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(height: 8),
                  ButtonGroupWidget(
                    fitContent: true,
                    selectedValue: compression,
                    selectedIcon: null,
                    onChanged: (value) => setLocal(() => compression = value),
                    items: const [
                      ButtonGroupItem(value: 'store', text: '不压缩'),
                      ButtonGroupItem(value: 'fast', text: '快速'),
                      ButtonGroupItem(value: 'balanced', text: '均衡'),
                      ButtonGroupItem(value: 'max', text: '最大'),
                    ],
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '将创建一份完整世界备份，可独立恢复。',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(
                  WorldBackupCreateOptions(compression: compression),
                ),
                child: const Text('开始备份'),
              ),
            ],
          );
        },
      );
    },
  );
}
