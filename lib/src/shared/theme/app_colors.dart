import 'package:flutter/material.dart';

/// 应用统一调色板，按用途命名，避免散落的魔法色值。
class AppColors {
  AppColors._();

  // 品牌 / 主要色
  static const Color primary = Color(0xFF26292F); // 主色-深底
  static const Color primaryContainer = Color(0xFF33363D); // 主色容器/卡片
  static const Color secondary = Color(0xFFFFD270); // 次色-高亮/强调
  static const Color tertiary = Color(0xFF494F58); // 第三色-辅助背景
  static const Color tertiaryAccent =
      Color.fromARGB(255, 21, 255, 119); // 第三色高亮（成功/激活）

  // 表面与分层（Dark 默认）
  static const Color surface = Color(0xFF16181C); // 整体背景
  static const Color surfaceContainer = Color(0xFF151515); // 默认容器
  static const Color surfaceContainerHigh = Color(0xFF1D1D1D); // 高层容器
  static const Color surfaceContainerHighest = Color(0xFF282828); // 最顶层容器
  static const Color surfaceDim = Color(0xFF060606); // 暗面（分隔/阴影层）
  static const Color surfaceBright = Color(0xFF2C2C2C); // 亮面（内嵌/浮层）
  static const Color surfaceLow = Color(0xFF0E0E0E); // 较低层
  static const Color surfaceLowest = Color(0xFF010101); // 最低层

  // 表面与分层（Light）
  static const Color lightSurface = Colors.white; // 背景
  static const Color lightSurfaceDim = Color(0xFFE0E0E0);
  static const Color lightSurfaceBright = Color(0xFFFDFDFD);
  static const Color lightSurfaceLowest = Colors.white;
  static const Color lightSurfaceLow = Color(0xFFF8F8F8);
  static const Color lightSurfaceDefault = Color(0xFFF3F3F3);
  static const Color lightSurfaceHigh = Color(0xFFEDEDED);
  static const Color lightSurfaceHighest = Color(0xFFE7E7E7);

  // 文本与描边
  static const Color onPrimary = Color(0xFF2E3137); // 主色上的文字
  static const Color onPrimaryContainer = Color(0xFFFFFFFF); // 主容器上的文字
  static const Color onSurface = Color(0xFFF1F1F1); // Dark 表面文字
  static const Color onSurfaceVariant = Color(0xFFCACACA); // Dark 表面次级文字
  static const Color outline = Color(0xFF777777); // Dark 轮廓/边框
  static const Color outlineVariant = Color(0xFF414141); // Dark 次级轮廓
  static const Color lightOnSurface = Colors.black; // Light 表面文字
  static const Color lightOnSurfaceVariant = Color(0xFF393939);
  static const Color lightOutline = Color(0xFF919191);
  static const Color lightOutlineVariant = Color(0xFFD1D1D1);
  static const Color inverseSurface = Color(0xFF2A2A2A); // Dark 反转表面
  static const Color inverseSurfaceOn = Color(0xFFF1F1F1); // Dark 反转文字
  static const Color lightInverseSurface = Color(0xFF2A2A2A); // Light 反转表面
  static const Color lightOnInverseSurface = Color(0xFFF1F1F1); // Light 反转文字
  static const Color inversePrimary = Color(0xFF515D6B); // Dark 反转主色
  static const Color lightInversePrimary = Color(0xFF8DACDD); // Light 反转主色

  // 状态与反馈
  static const Color error = Color(0xFFCF6679);
  static const Color onError = Color(0xFF000000);
  static const Color errorContainer = Color(0xFFB1384E);
  static const Color onErrorContainer = Color(0xFFFFFFFF);
  static const Color dangerHover = Color(0xFFD93E5D); // 关闭按钮等危险悬停
  static const Color dangerOnHover = Color(0xFF000000); // 危险悬停文字/图标

  // 组件专用 / 容器
  static const Color neutralPanel = Color(0xFF33363D); // 导航、按钮面板
  static const Color cardHoverOverlay = Color(0xFF2F333B); // 卡片悬停底色
  static const Color darkSecondaryContainer = Color(0xFFD26900); // Dark 次色容器
  static const Color darkTertiaryContainer = Color(0xFFB0BAC5); // Dark 第三色容器
  static const Color darkSurfaceTint = Color(0xFFB1CFF5); // Dark 蒙版/高光

  // 遮罩与阴影
  static const Color scrim = Color(0xFF000000);
  static const Color shadow = Color(0xFF000000);
}
