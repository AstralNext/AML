import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// System tray + close-to-tray window behavior for desktop builds.
class WindowTrayController with WindowListener, TrayListener {
  WindowTrayController();

  bool _ready = false;
  void Function(bool)? _onCloseToTrayChanged;

  Future<void> initialize() async {
    if (_ready) return;
    if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
      return;
    }

    final ui = getIt<UiSettingsState>();
    await windowManager.setPreventClose(ui.closeToTray.value);
    windowManager.addListener(this);

    try {
      final iconPath = await _resolveIconPath();
      if (iconPath == null) {
        debugPrint('tray icon not found, tray disabled');
        return;
      }
      debugPrint('tray using icon: $iconPath');

      await trayManager.setIcon(iconPath);
      // 各平台对托盘能力的支持并不一致：tray_manager 的 Linux 实现只提供了
      // setIcon / setTitle / setContextMenu，setToolTip 会抛 MissingPluginException
      // （libayatana-appindicator 本身也没有 tooltip 接口）。这里是逐项兜底，
      // 避免某个可选调用失败后，后面的右键菜单与事件监听被一起跳过。
      await _attemptOptional('setToolTip', () => trayManager.setToolTip('AML'));
      await _attemptOptional(
        'setContextMenu',
        () => trayManager.setContextMenu(
          Menu(
            items: [
              MenuItem(key: 'show', label: '显示主窗口'),
              MenuItem.separator(),
              MenuItem(key: 'exit', label: '退出 AML'),
            ],
          ),
        ),
      );
      trayManager.addListener(this);
    } catch (e, st) {
      debugPrint('tray init failed: $e\n$st');
      if (Platform.isLinux) {
        debugPrint(
          '[tray] Linux 需要 libayatana-appindicator3-1 或 libappindicator3-1，'
          '并且桌面面板需要提供 StatusNotifier 宿主（GNOME 需安装 AppIndicator '
          '扩展，wlroots/waybar 需启用 tray 模块）。',
        );
      }
    }

    _onCloseToTrayChanged = (enabled) {
      unawaited(_syncPreventClose(enabled));
    };
    ui.addCloseToTrayListener(_onCloseToTrayChanged!);

    _ready = true;
  }

  /// Resolve the tray icon to a path acceptable by the native tray API.
  /// On Linux the native AppIndicator needs a real file path, so we
  /// copy the bundled asset into a temp file and return that absolute path.
  Future<String?> _resolveIconPath() async {
    final assetKey =
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png';

    // On Linux / macOS tray_manager sometimes can't resolve Flutter's asset
    // bundle paths directly — copy into a temp file and use that absolute path.
    if (!Platform.isWindows) {
      try {
        final bytes = await rootBundle.load(assetKey);
        final dir = Directory.systemTemp;
        final ext = p.extension(assetKey);
        final tmp = File(p.join(dir.path, 'aml_tray_icon$ext'));
        await tmp.writeAsBytes(bytes.buffer.asUint8List());
        return tmp.path;
      } catch (e) {
        debugPrint('tray icon copy failed: $e');
        // Fall back to the asset path directly (may work on some platforms).
      }
    }
    return assetKey;
  }

  Future<void> _syncPreventClose(bool closeToTray) async {
    await windowManager.setPreventClose(closeToTray);
  }

  /// 执行可选的托盘能力调用；平台不支持时只记录日志，不影响其它能力。
  Future<void> _attemptOptional(
    String label,
    Future<void> Function() action,
  ) async {
    try {
      await action();
    } catch (e) {
      debugPrint('tray $label unsupported on this platform: $e');
    }
  }

  Future<void> showMainWindow() async {
    await windowManager.setSkipTaskbar(false);
    await windowManager.show();
    await windowManager.focus();
  }

  Future<void> hideToTray() async {
    await windowManager.hide();
    await windowManager.setSkipTaskbar(true);
  }

  Future<void> quitApp() async {
    await windowManager.setPreventClose(false);
    await windowManager.setSkipTaskbar(false);
    try {
      await trayManager.destroy();
    } catch (_) {}
    await windowManager.destroy();
  }

  @override
  void onWindowClose() {
    unawaited(_handleWindowClose());
  }

  Future<void> _handleWindowClose() async {
    final closeToTray = getIt<UiSettingsState>().closeToTray.value;
    if (closeToTray) {
      await hideToTray();
    } else {
      await quitApp();
    }
  }

  @override
  void onTrayIconMouseDown() {
    // Left-click: show / focus the main window.
    unawaited(showMainWindow());
  }

  @override
  void onTrayIconRightMouseDown() {
    // Right-click: context menu (显示主窗口 / 退出 AML).
    unawaited(trayManager.popUpContextMenu());
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        unawaited(showMainWindow());
      case 'exit':
        unawaited(quitApp());
    }
  }

  Future<void> dispose() async {
    if (!_ready) return;
    if (_onCloseToTrayChanged != null) {
      getIt<UiSettingsState>()
          .removeCloseToTrayListener(_onCloseToTrayChanged!);
      _onCloseToTrayChanged = null;
    }
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    try {
      await trayManager.destroy();
    } catch (_) {}
    _ready = false;
  }
}
