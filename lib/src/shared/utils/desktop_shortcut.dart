import 'dart:io';

import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

/// Create a desktop shortcut via Rust.
///
/// By default writes directly to the Desktop (one click). Set [saveAs] to pick
/// a custom path — useful when the default Desktop flow is not wanted.
///
/// Icon priority:
/// 1. [iconDataUrl] / [iconPath] when provided (callers should pass server
///    favicon first for server shortcuts)
/// 2. Rust fallback: `servers.dat` favicon for server shortcuts, else instance icon
Future<void> createAmlDesktopShortcut({
  required String displayName,
  required String instanceId,
  String? serverAddress,
  String? worldFolder,
  String? instanceIconPath,
  String? iconPath,
  String? iconDataUrl,
  bool saveAs = false,
}) async {
  if (!Platform.isWindows) {
    showAppSnackBar('当前仅支持在 Windows 上创建桌面快捷方式', isError: true);
    return;
  }
  if (serverAddress != null &&
      serverAddress.isNotEmpty &&
      worldFolder != null &&
      worldFolder.isNotEmpty) {
    showAppSnackBar('快捷方式不能同时指定服务器和世界', isError: true);
    return;
  }

  final safeName = _sanitizeFileName(
    displayName.trim().isEmpty ? 'AML' : displayName.trim(),
  );
  final defaultName = 'AML - $safeName.lnk';
  final desktopDir = _desktopDirectory();

  // Let popup menus / bottom sheets finish closing before any native dialog.
  await Future<void>.delayed(const Duration(milliseconds: 80));

  String? output;
  if (saveAs) {
    // Avoid FileType.custom + `lnk` — on Windows file_picker often returns null
    // immediately (looks like the button did nothing).
    final picked = await FilePicker.platform.saveFile(
      dialogTitle: '另存为桌面快捷方式',
      fileName: defaultName,
      type: FileType.any,
      initialDirectory: desktopDir,
    );
    if (picked == null || picked.trim().isEmpty) return;
    output = picked.trim().toLowerCase().endsWith('.lnk')
        ? picked.trim()
        : '${picked.trim()}.lnk';
  } else {
    if (desktopDir == null || desktopDir.isEmpty) {
      showAppSnackBar('找不到桌面目录，请改用另存为', isError: true);
      return;
    }
    output = _uniquePath(p.join(desktopDir, defaultName));
  }

  final isServer = serverAddress != null && serverAddress.trim().isNotEmpty;
  // Servers: favicon first. Everything else: instance icon.
  final preferredIcon = () {
    if (isServer) {
      final data = iconDataUrl?.trim();
      if (data != null && data.isNotEmpty) return data;
      final path = iconPath?.trim();
      if (path != null && path.isNotEmpty) return path;
    }
    final instance = instanceIconPath?.trim();
    if (instance != null && instance.isNotEmpty) return instance;
    return null;
  }();

  try {
    final path = await rust.createDesktopShortcut(
      displayName: safeName,
      outputPath: output,
      instanceId: instanceId,
      serverAddress: serverAddress,
      worldFolder: worldFolder,
      icon: preferredIcon,
    );
    debugPrint(
      '[AML shortcut] created $path iconPreferred=${preferredIcon != null}',
    );
    showAppSnackBar('已创建快捷方式：${p.basename(path)}');
  } catch (e) {
    debugPrint('[AML shortcut] failed: $e');
    showAppSnackBar('创建快捷方式失败: $e', isError: true);
  }
}

String? _desktopDirectory() {
  try {
    final home =
        Platform.environment['USERPROFILE'] ?? Platform.environment['HOME'];
    if (home == null || home.isEmpty) return null;
    final desktop = p.join(home, 'Desktop');
    if (Directory(desktop).existsSync()) return desktop;
    // Chinese Windows localized folder name fallback.
    final desktopZh = p.join(home, '桌面');
    if (Directory(desktopZh).existsSync()) return desktopZh;
    return desktop;
  } catch (_) {
    return null;
  }
}

String _sanitizeFileName(String name) {
  return name
      .replaceAll(RegExp(r'[<>:"/\\|?*]'), '_')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String _uniquePath(String path) {
  if (!File(path).existsSync()) return path;
  final dir = p.dirname(path);
  final base = p.basenameWithoutExtension(path);
  final ext = p.extension(path);
  for (var i = 1; i < 100; i++) {
    final candidate = p.join(dir, '$base ($i)$ext');
    if (!File(candidate).existsSync()) return candidate;
  }
  return path;
}
