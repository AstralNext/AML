import 'package:aml/src/features/settings/ui/about_settings_page.dart';
import 'package:aml/src/features/settings/ui/cdn_settings_page.dart';
import 'package:aml/src/features/settings/ui/game_instance_settings_page.dart';
import 'package:aml/src/features/settings/ui/general_settings_page.dart';
import 'package:aml/src/features/settings/ui/java_settings_page.dart';
import 'package:aml/src/features/settings/ui/resource_settings_page.dart';
import 'package:aml/src/features/settings/ui/theme_settings_page.dart';
import 'package:aml/src/features/settings/ui/translation_settings_page.dart';
import 'package:aml/src/features/settings/ui/yggdrasil_settings_page.dart';
import 'package:flutter/material.dart';

class SettingsPageEntry {
  final String id;
  final String title;
  final IconData icon;
  final Widget page;

  const SettingsPageEntry({
    required this.id,
    required this.title,
    required this.icon,
    required this.page,
  });
}

class SettingsPages {
  static const List<SettingsPageEntry> pages = [
    SettingsPageEntry(
      id: 'general',
      title: '通用',
      icon: Icons.tune,
      page: GeneralSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'translation',
      title: '翻译',
      icon: Icons.translate,
      page: TranslationSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'theme',
      title: '主题',
      icon: Icons.palette,
      page: ThemeSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'java',
      title: 'JAVA 配置',
      icon: Icons.code,
      page: JavaSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'yggdrasil',
      title: '外置登录',
      icon: Icons.admin_panel_settings_outlined,
      page: YggdrasilSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'game_instance',
      title: '默认游戏实例配置',
      icon: Icons.videogame_asset,
      page: GameInstanceSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'cdn',
      title: '网络',
      icon: Icons.lan,
      page: CdnSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'resource',
      title: '资源管理',
      icon: Icons.folder,
      page: ResourceSettingsPage(),
    ),
    SettingsPageEntry(
      id: 'about',
      title: '关于',
      icon: Icons.info_outline,
      page: AboutSettingsPage(),
    ),
  ];
}
