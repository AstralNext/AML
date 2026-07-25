import 'dart:io';

import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:aml/src/features/settings/ui/settings_pages.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';

class SettingsNavigationPanel extends StatelessWidget {
  final String selectedPageId;
  final ValueChanged<String> onPageSelected;

  const SettingsNavigationPanel({
    super.key,
    required this.selectedPageId,
    required this.onPageSelected,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: EdgeInsets.zero,
            children: SettingsPages.pages
                .map(
                  (config) => Padding(
                    padding: const EdgeInsets.only(
                        left: 25, top: 2, right: 0, bottom: 1),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: NavRectButton(
                        icon: config.icon,
                        text: config.title,
                        label: config.title,
                        isSelected: selectedPageId == config.id,
                        width: 245,
                        onTap: () => onPageSelected(config.id),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ),
        const SizedBox(height: 12),
        const AppInfoCard(),
        const SizedBox(height: 12),
      ],
    );
  }
}

class AppInfoCard extends StatelessWidget {
  const AppInfoCard({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.only(left: 25, right: 25),
      child: Container(
        width: 235,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: tokens.colorBg.withValues(alpha: 0.3),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: tokens.colorSecondary.withValues(alpha: 0.2),
            width: 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: tokens.colorButtonBg,
                borderRadius: BorderRadius.circular(6),
              ),
              child: Icon(
                Icons.rocket_launch,
                size: 20,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  FutureBuilder<PackageInfo>(
                    future: PackageInfo.fromPlatform(),
                    builder: (context, snapshot) {
                      final version = snapshot.data?.version;
                      final label = version == null || version.isEmpty
                          ? 'AML'
                          : 'AML $version';
                      return Text(
                        label,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: tokens.colorContrast,
                        ),
                        overflow: TextOverflow.ellipsis,
                      );
                    },
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '${Platform.operatingSystem} ${Platform.operatingSystemVersion}',
                    style: TextStyle(
                      fontSize: 10,
                      color: tokens.colorBase.withValues(alpha: 0.6),
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
