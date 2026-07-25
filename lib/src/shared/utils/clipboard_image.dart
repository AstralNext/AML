import 'dart:io';

import 'package:pasteboard/pasteboard.dart';

/// Copy an image file to the system clipboard.
Future<void> copyImageFileToClipboard(File file) async {
  if (!await file.exists()) {
    throw StateError('图片文件不存在');
  }

  if (Platform.isWindows) {
    await _copyImageWindows(file.path);
    return;
  }

  final bytes = await file.readAsBytes();
  if (bytes.isEmpty) {
    throw StateError('图片文件为空');
  }
  await Pasteboard.writeImage(bytes);
}

Future<void> _copyImageWindows(String path) async {
  final escaped = path.replaceAll("'", "''");
  final result = await Process.run('powershell', [
    '-NoProfile',
    '-STA',
    '-WindowStyle',
    'Hidden',
    '-Command',
    '''
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
\$img = [System.Drawing.Image]::FromFile('$escaped')
[System.Windows.Forms.Clipboard]::SetImage(\$img)
\$img.Dispose()
''',
  ]);

  if (result.exitCode != 0) {
    final stderr = result.stderr.toString().trim();
    final stdout = result.stdout.toString().trim();
    final detail = stderr.isNotEmpty ? stderr : stdout;
    throw StateError(
      detail.isEmpty ? '复制到剪贴板失败' : detail,
    );
  }
}
