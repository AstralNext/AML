import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:aml/src/features/instances/ui/instance_settings_widgets.dart';
import 'package:flutter/material.dart';

/// Install / repair / modpack actions for instance settings.
class InstanceSettingsInstallTab extends StatelessWidget {
  const InstanceSettingsInstallTab({
    super.key,
    required this.instance,
    required this.busy,
    required this.onSwitchModpackVersion,
    required this.onReinstallModpack,
    required this.onUnlinkModpack,
    required this.onRepair,
    required this.onReinstall,
  });

  final rust.InstanceDto instance;
  final bool busy;
  final VoidCallback onSwitchModpackVersion;
  final VoidCallback onReinstallModpack;
  final VoidCallback onUnlinkModpack;
  final VoidCallback onRepair;
  final VoidCallback onReinstall;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        instanceSettingsSectionHeader(context, '安装信息'),
        const SizedBox(height: 12),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: tokens.colorBg.withValues(alpha: 0.35),
            borderRadius: BorderRadius.circular(12),
          ),
          child: Column(
            children: [
              instanceSettingsInfoRow(context, '平台', loaderLabel(instance.loader)),
              instanceSettingsInfoRow(context, '游戏版本', instance.gameVersion),
              if (instance.loader.toLowerCase() != 'vanilla')
                instanceSettingsInfoRow(
                  context,
                  '${loaderLabel(instance.loader)} 版本',
                  instance.loaderVersion ?? '未知',
                ),
              instanceSettingsInfoRow(
                context,
                '安装状态',
                installStageLabel(instance.installStage),
              ),
            ],
          ),
        ),
        if (instance.modpackSource != null) ...[
          const SizedBox(height: 24),
          instanceSettingsSectionHeader(context, '已安装整合包'),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: tokens.colorBg.withValues(alpha: 0.35),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Row(
              children: [
                InstanceIcon(
                  instanceId: instance.id,
                  iconPath: instance.icon,
                  size: 48,
                  borderRadius: 10,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        instance.modpackTitle ?? instance.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
                      Text(
                        instance.modpackVersionNumber ??
                            instance.modpackVersionId ??
                            instance.modpackSource!,
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
          if (instance.modpackSource == 'modrinth' ||
              instance.modpackSource == 'curseforge') ...[
            const SizedBox(height: 12),
            NavRectButton(
              isSelected: false,
              icon: Icons.swap_horiz,
              text: busy ? '处理中…' : '切换版本',
              defaultBackgroundColor: tokens.colorButtonBg,
              defaultColor: tokens.colorContrast,
              hoverColor: tokens.colorButtonBgSelected,
              hoverTextColor: tokens.colorButtonTextSelected,
              onTap: busy ? () {} : onSwitchModpackVersion,
            ),
            const SizedBox(height: 10),
            NavRectButton(
              isSelected: false,
              icon: Icons.sync,
              text: busy ? '处理中…' : '重新安装整合包',
              defaultBackgroundColor: tokens.colorButtonBg,
              defaultColor: tokens.colorContrast,
              hoverColor: tokens.colorButtonBgSelected,
              hoverTextColor: tokens.colorButtonTextSelected,
              onTap: busy ? () {} : onReinstallModpack,
            ),
          ],
          const SizedBox(height: 12),
          NavRectButton(
            isSelected: true,
            icon: Icons.link_off,
            text: '解除整合包关联',
            selectedBackgroundColor: const Color(0xFFE67E22),
            selectedColor: Colors.white,
            onTap: busy ? () {} : onUnlinkModpack,
          ),
          const SizedBox(height: 8),
          Text(
            '解除关联后可自由更改加载器与 Minecraft 版本，但将失去自动更新。',
            style: TextStyle(
              fontSize: 12,
              color: tokens.colorBase.withValues(alpha: 0.65),
            ),
          ),
        ],
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '修复实例',
          description: '检查 Minecraft 依赖是否损坏，可修复启动器相关错误。',
        ),
        const SizedBox(height: 10),
        NavRectButton(
          isSelected: false,
          icon: Icons.build_circle_outlined,
          text: busy ? '处理中…' : '修复',
          defaultBackgroundColor: tokens.colorButtonBg,
          defaultColor: tokens.colorContrast,
          hoverColor: tokens.colorButtonBgSelected,
          hoverTextColor: tokens.colorButtonTextSelected,
          onTap: busy ? () {} : onRepair,
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '重新安装',
          description: '重新下载并安装 Minecraft 与加载器文件。不会删除你的世界和配置。',
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: NavRectButton(
            isSelected: false,
            icon: Icons.download_outlined,
            text: busy ? '处理中…' : '重新安装',
            defaultBackgroundColor: const Color(0x33FF6B6B),
            defaultColor: const Color(0xFFFF7B7B),
            hoverColor: const Color(0x55FF6B6B),
            hoverTextColor: const Color(0xFFFF8F8F),
            onTap: busy ? () {} : onReinstall,
          ),
        ),
      ],
    );
  }
}
