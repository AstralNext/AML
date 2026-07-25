import 'package:aml/src/features/discover/ui/discover_page.dart';
import 'package:aml/src/features/home/ui/home_page.dart';
import 'package:aml/src/features/library/ui/library_page.dart';
import 'package:aml/src/features/wardrobe/ui/wardrobe_page.dart';
import 'package:flutter/material.dart';

class MainNavigationItem {
  final String id;
  final IconData icon;
  final String label;
  final Widget Function() pageBuilder;

  const MainNavigationItem({
    required this.id,
    required this.icon,
    required this.label,
    required this.pageBuilder,
  });
}

class MainNavigationConfig {
  static final List<MainNavigationItem> pages = [
    MainNavigationItem(
      id: 'home',
      icon: Icons.home_outlined,
      label: '首页',
      pageBuilder: () => const HomePage(),
    ),
    MainNavigationItem(
      id: 'discover',
      icon: Icons.explore_outlined,
      label: '发现',
      pageBuilder: () => const DiscoverPage(),
    ),
    MainNavigationItem(
      id: 'wardrobe',
      icon: Icons.checkroom_outlined,
      label: '皮肤库',
      pageBuilder: () => const WardrobePage(),
    ),
    MainNavigationItem(
      id: 'library',
      icon: Icons.grid_view_rounded,
      label: '库',
      pageBuilder: () => const LibraryPage(),
    ),
  ];
}
