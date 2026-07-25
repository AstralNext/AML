import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:flutter/foundation.dart';
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
      await trayManager.setIcon(
        Platform.isWindows ? 'assets/tray_icon.ico' : 'assets/tray_icon.png',
      );
      await trayManager.setToolTip('AML');
      await trayManager.setContextMenu(
        Menu(
          items: [
            MenuItem(key: 'show', label: '显示主窗口'),
            MenuItem.separator(),
            MenuItem(key: 'exit', label: '退出 AML'),
          ],
        ),
      );
      trayManager.addListener(this);
    } catch (e, st) {
      debugPrint('tray init failed: $e\n$st');
    }

    _onCloseToTrayChanged = (enabled) {
      unawaited(_syncPreventClose(enabled));
    };
    ui.addCloseToTrayListener(_onCloseToTrayChanged!);

    _ready = true;
  }

  Future<void> _syncPreventClose(bool closeToTray) async {
    await windowManager.setPreventClose(closeToTray);
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
