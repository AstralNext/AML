import 'package:window_manager/window_manager.dart';
import 'dart:io';
import 'package:flutter/material.dart';

class WindowManagerUtils {
  static Future<void> initializeWindow() async {
    // 检查当前平台是否为 Windows、MacOS 或 Linux
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      // 确保窗口管理器已初始化
      await windowManager.ensureInitialized();

      // 定义窗口选项配置
      const windowOptions = WindowOptions(
        size: Size(1080, 690),
        // 设置窗口最小大小为 300x300
        minimumSize: Size(1080, 690),
        // 设置窗口居中显示
        center: true,
        // 设置窗口标题
        title: "AML",
        // 设置标题栏样式为隐藏
        titleBarStyle: TitleBarStyle.hidden,
        // 设置窗口背景为透明
        backgroundColor: Colors.transparent,
        // 设置是否在任务栏显示
        skipTaskbar: false,
      );

      // 等待窗口准备就绪并显示
      await windowManager.waitUntilReadyToShow(windowOptions, () async {
        await windowManager.show();
        await windowManager.focus();
      });
    }
  }
}
