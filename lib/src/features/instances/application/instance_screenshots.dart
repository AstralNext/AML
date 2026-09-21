import 'dart:io';

import 'package:path/path.dart' as p;

/// 一张实例截图（screenshots 目录下的图片文件）。
class InstanceScreenshotEntry {
  const InstanceScreenshotEntry({
    required this.name,
    required this.path,
    required this.size,
    this.modified,
  });

  final String name;
  final String path;
  final int size;
  final DateTime? modified;
}

final _screenshotExt = RegExp(r'\.(png|jpe?g)$', caseSensitive: false);

/// 扫描实例 screenshots 目录，按修改时间倒序返回。
Future<List<InstanceScreenshotEntry>> scanInstanceScreenshots(
  String instanceRoot,
) async {
  final dir = Directory(p.join(instanceRoot, 'screenshots'));
  final entries = <InstanceScreenshotEntry>[];
  if (await dir.exists()) {
    await for (final entity in dir.list(followLinks: false)) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      if (!_screenshotExt.hasMatch(name)) continue;
      int size = 0;
      DateTime? modified;
      try {
        final stat = await entity.stat();
        size = stat.size;
        modified = stat.modified;
      } catch (_) {}
      entries.add(
        InstanceScreenshotEntry(
          name: name,
          path: entity.path,
          size: size,
          modified: modified,
        ),
      );
    }
  }
  entries.sort((a, b) {
    final am = a.modified?.millisecondsSinceEpoch ?? 0;
    final bm = b.modified?.millisecondsSinceEpoch ?? 0;
    if (am != bm) return bm.compareTo(am);
    return b.name.compareTo(a.name);
  });
  return entries;
}
