import 'package:aml/src/features/instances/ui/instance_settings_controller.dart';
import 'package:aml/src/features/instances/ui/instance_settings_widgets.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:flutter/material.dart';

/// 实例设置「启动 Hooks」标签页：启动前 / 包装器 / 退出后命令。
class InstanceSettingsHooksTab extends StatelessWidget {
  const InstanceSettingsHooksTab({super.key, required this.controller});

  final InstanceSettingsController controller;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          children: [
            instanceSettingsSectionHeader(
              context,
              '游戏启动钩子',
              description: 'Hooks 允许高级用户在启动游戏前后运行特定的系统命令。',
            ),
            const SizedBox(height: 16),
            instanceSettingsOverrideRow(
              context,
              saving: controller.saving,
              label: '自定义启动 Hooks',
              value: controller.overrideHooks,
              onChanged: controller.setOverrideHooks,
              child: Column(
                children: [
                  _hookField(
                    context,
                    title: '启动前',
                    hint: '输入启动前命令…',
                    description: '在实例启动前运行。',
                    controller: controller.preLaunchController,
                  ),
                  const SizedBox(height: 14),
                  _hookField(
                    context,
                    title: '包装器命令',
                    hint: '输入封装命令…',
                    description: '用于启动 Minecraft 的包装器命令，Java 会追加在末尾。',
                    controller: controller.wrapperController,
                  ),
                  const SizedBox(height: 14),
                  _hookField(
                    context,
                    title: '退出后执行',
                    hint: '输入退出后运行的命令…',
                    description: '在游戏正常关闭后运行。',
                    controller: controller.postExitController,
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _hookField(
    BuildContext context, {
    required String title,
    required String hint,
    required String description,
    required TextEditingController controller,
  }) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 6),
        InputBarWidget(
          colorScheme: Theme.of(context).colorScheme,
          size: InputBarSize.medium,
          hintText: hint,
          controller: controller,
          onChanged: (_) => this.controller.scheduleSave(
            () => this.controller.save(
              preLaunchCommand: this.controller.preLaunchController.text,
              wrapperCommand: this.controller.wrapperController.text,
              postExitCommand: this.controller.postExitController.text,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: TextStyle(
            fontSize: 12,
            color: tokens.colorBase.withValues(alpha: 0.65),
          ),
        ),
      ],
    );
  }
}
