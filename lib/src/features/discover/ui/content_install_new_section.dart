import 'package:aml/src/features/discover/ui/content_install_widgets.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class ContentInstallNewSection extends StatelessWidget {
  const ContentInstallNewSection({
    super.key,
    required this.tokens,
    required this.colorScheme,
    required this.nameController,
    required this.compatibleLoaders,
    required this.gameVersions,
    required this.selectedLoader,
    required this.selectedGameVersion,
    required this.iconPath,
    required this.onPickIcon,
    required this.onClearIcon,
    required this.onSelectLoader,
    required this.onSelectGameVersion,
  });

  final AppThemeTokens tokens;
  final ColorScheme colorScheme;
  final TextEditingController nameController;
  final List<String> compatibleLoaders;
  final List<String> gameVersions;
  final String? selectedLoader;
  final String? selectedGameVersion;
  final String? iconPath;
  final VoidCallback onPickIcon;
  final VoidCallback onClearIcon;
  final void Function(String loader) onSelectLoader;
  final void Function(String? gameVersion) onSelectGameVersion;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              InstanceIcon(
                instanceId: 'content-install-new',
                iconPath: iconPath,
                size: 80,
                borderRadius: 16,
              ),
              const SizedBox(width: 16),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  NavRectButton(
                    text: '选择图标',
                    icon: Icons.upload_outlined,
                    isSelected: false,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    onTap: onPickIcon,
                  ),
                  if (iconPath != null) ...[
                    const SizedBox(height: 8),
                    NavRectButton(
                      text: '移除图标',
                      icon: Icons.close,
                      isSelected: false,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      onTap: onClearIcon,
                    ),
                  ],
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '名称',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          InputBarWidget(
            colorScheme: colorScheme,
            size: InputBarSize.medium,
            hintText: '输入实例名称',
            controller: nameController,
          ),
          const SizedBox(height: 16),
          Text(
            '加载器',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final loader in compatibleLoaders)
                ContentInstallPillChoice(
                  tokens: tokens,
                  label: loaderLabel(loader),
                  selected: selectedLoader == loader,
                  onTap: () => onSelectLoader(loader),
                ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            '游戏版本',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          if (gameVersions.isEmpty)
            Text(
              '暂无可用游戏版本',
              style: TextStyle(color: tokens.colorBase.withValues(alpha: 0.7)),
            )
          else
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              decoration: BoxDecoration(
                color: tokens.colorButtonBg.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: tokens.colorSecondary.withValues(alpha: 0.35),
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<String>(
                  value: selectedGameVersion,
                  isExpanded: true,
                  dropdownColor: tokens.colorRaisedBg,
                  items: [
                    for (final v in gameVersions)
                      DropdownMenuItem(value: v, child: Text(v)),
                  ],
                  onChanged: (v) => onSelectGameVersion(v),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
