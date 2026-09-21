import 'dart:io';

import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';

/// 在系统文件管理器中打开路径（Windows / macOS / Linux）。
/// 失败时弹出错误提示。
Future<void> revealInExplorer(BuildContext context, String path) async {
  try {
    if (Platform.isWindows) {
      await Process.run('explorer', [path]);
    } else if (Platform.isMacOS) {
      await Process.run('open', [path]);
    } else {
      await Process.run('xdg-open', [path]);
    }
  } catch (e) {
    if (context.mounted) showAppSnackBar('$e', isError: true);
  }
}
