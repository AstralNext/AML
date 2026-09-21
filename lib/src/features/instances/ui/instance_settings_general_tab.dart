import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/instance_settings_controller.dart';
import 'package:aml/src/features/instances/ui/instance_settings_widgets.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/buttons/button_group_widget.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

/// 实例设置「通用」标签页：名称/图标、库分组、更新渠道、自动备份与
/// 复制 / 导出 / 删除等实例级操作入口。
class InstanceSettingsGeneralTab extends StatelessWidget {
  const InstanceSettingsGeneralTab({
    super.key,
    required this.controller,
    required this.instance,
    required this.busy,
    required this.onDuplicate,
    required this.onExport,
    required this.onDelete,
  });

  final InstanceSettingsController controller;
  final rust.InstanceDto instance;
  final bool busy;
  final VoidCallback onDuplicate;
  final VoidCallback onExport;
  final VoidCallback onDelete;

  Future<void> _pickIcon(BuildContext context) async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    try {
      await getIt<InstanceStore>().editIcon(instance.id, path: path);
      if (context.mounted) showAppSnackBar('实例图标已更新');
    } catch (error) {
      if (context.mounted) showAppSnackBar('更新图标失败: $error', isError: true);
    }
  }

  Future<void> _setAutoBackup(BuildContext context, bool enabled) async {
    try {
      await getIt<InstanceStore>()
          .setAutoBackupWorlds(instance.id, enabled);
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar('设置失败: $error', isError: true);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '名称',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                      const SizedBox(height: 8),
                      InputBarWidget(
                        colorScheme: Theme.of(context).colorScheme,
                        size: InputBarSize.medium,
                        controller: controller.nameController,
                        focusNode: controller.nameFocusNode,
                        onSubmitted: (_) => unawaited(controller.commitName()),
                        onFocusChange: (focused) {
                          if (!focused) unawaited(controller.commitName());
                        },
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 18),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '图标',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Material(
                      color: Colors.transparent,
                      child: InkWell(
                        onTap: controller.saving ? null : () => _pickIcon(context),
                        borderRadius: BorderRadius.circular(12),
                        child: InstanceIcon(
                          instanceId: instance.id,
                          iconPath: instance.icon,
                          size: 72,
                          borderRadius: 12,
                        ),
                      ),
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            instanceSettingsSectionHeader(
              context,
              '库分组',
              description: '库分组功能可以让你将实例整理到库中的不同部分。',
            ),
            const SizedBox(height: 10),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final group in {...controller.availableGroups, ...controller.groups})
                  FilterChip(
                    label: Text(group),
                    selected: controller.groups.contains(group),
                    onSelected: controller.saving
                        ? null
                        : (selected) {
                            final next = List<String>.from(controller.groups);
                            if (selected) {
                              if (!next.contains(group)) next.add(group);
                            } else {
                              next.remove(group);
                            }
                            unawaited(controller.persistGroups(next));
                          },
                  ),
              ],
            ),
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: InputBarWidget(
                    colorScheme: Theme.of(context).colorScheme,
                    size: InputBarSize.medium,
                    hintText: '输入分组名称',
                    controller: controller.groupController,
                  ),
                ),
                const SizedBox(width: 8),
                NavRectButton(
                  isSelected: false,
                  icon: Icons.add,
                  text: '创建新的分组',
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  onTap: controller.saving
                      ? () {}
                      : () {
                          final name = controller.groupController.text.trim();
                          if (name.isEmpty) return;
                          controller.groupController.clear();
                          final next = List<String>.from(controller.groups);
                          if (!next.contains(name)) next.add(name);
                          unawaited(controller.persistGroups(next));
                        },
                ),
              ],
            ),
            const SizedBox(height: 24),
            instanceSettingsSectionHeader(
              context,
              '更新渠道',
              description: switch (controller.updateChannel) {
                'alpha' => '正式版、Beta 与 Alpha 测试版都会显示为可用更新。',
                'beta' => '正式版与 Beta 测试版会显示为可用更新。',
                _ => '只有正式版会被显示为可用更新。',
              },
            ),
            const SizedBox(height: 10),
            IgnorePointer(
              ignoring: controller.saving,
              child: ButtonGroupWidget(
                fitContent: true,
                selectedValue: controller.updateChannel,
                selectedIcon: null,
                onChanged: controller.setUpdateChannel,
                items: const [
                  ButtonGroupItem(value: 'release', text: '正式版'),
                  ButtonGroupItem(value: 'beta', text: 'Beta 测试版'),
                  ButtonGroupItem(value: 'alpha', text: 'Alpha 测试版'),
                ],
              ),
            ),
            const SizedBox(height: 24),
            instanceSettingsSectionHeader(
              context,
              '存档备份',
              description: '退出游戏后自动完整备份本次游玩的世界（默认关闭）。计入资源管理。',
            ),
            const SizedBox(height: 10),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(
                '退出时自动备份世界',
                style: TextStyle(
                  fontWeight: FontWeight.w600,
                  color: tokens.colorContrast,
                ),
              ),
              subtitle: Text(
                '优先备份 Quick Play 进入的世界；否则备份最近游玩且未占用的世界。',
                style: TextStyle(
                  fontSize: 12,
                  color: tokens.colorBase.withValues(alpha: 0.7),
                ),
              ),
              value: instance.autoBackupWorlds,
              onChanged: controller.saving
                  ? null
                  : (enabled) =>
                      unawaited(_setAutoBackup(context, enabled)),
            ),
            const SizedBox(height: 24),
            instanceSettingsSectionHeader(
              context,
              '复制实例',
              description: '创建此实例的副本，包含世界、配置、模组等所有内容。',
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: NavRectButton(
                isSelected: false,
                icon: Icons.copy_all_outlined,
                text: busy ? '复制中…' : '复制',
                defaultBackgroundColor: tokens.colorButtonBg,
                defaultColor: tokens.colorContrast,
                hoverColor: tokens.colorButtonBgSelected,
                hoverTextColor: tokens.colorButtonTextSelected,
                onTap: busy ? () {} : onDuplicate,
              ),
            ),
            const SizedBox(height: 24),
            instanceSettingsSectionHeader(
              context,
              '导出整合包',
              description: '设置名称、版本与导出内容后，导出为 Modrinth / MultiMC / MCBBS。',
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: NavRectButton(
                isSelected: false,
                icon: Icons.upload_file_outlined,
                text: '导出整合包…',
                defaultBackgroundColor: tokens.colorButtonBg,
                defaultColor: tokens.colorContrast,
                hoverColor: tokens.colorButtonBgSelected,
                hoverTextColor: tokens.colorButtonTextSelected,
                onTap: busy ? () {} : onExport,
              ),
            ),
            const SizedBox(height: 24),
            instanceSettingsSectionHeader(
              context,
              '删除实例',
              description: '此操作将永久删除实例及其所有数据，且无法恢复。',
            ),
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: NavRectButton(
                isSelected: false,
                icon: Icons.delete_outline,
                text: '删除实例',
                defaultBackgroundColor: const Color(0x33FF6B6B),
                defaultColor: const Color(0xFFFF7B7B),
                hoverColor: const Color(0x55FF6B6B),
                hoverTextColor: const Color(0xFFFF8F8F),
                onTap: busy ? () {} : onDelete,
              ),
            ),
          ],
        );
      },
    );
  }
}
