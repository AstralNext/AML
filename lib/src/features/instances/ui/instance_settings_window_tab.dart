import 'package:aml/src/features/instances/ui/instance_settings_controller.dart';
import 'package:aml/src/features/instances/ui/instance_settings_widgets.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:flutter/material.dart';

/// 实例设置「游戏窗口」标签页：全屏开关与宽高覆盖。
class InstanceSettingsWindowTab extends StatelessWidget {
  const InstanceSettingsWindowTab({super.key, required this.controller});

  final InstanceSettingsController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          children: [
            instanceSettingsOverrideRow(
              context,
              saving: controller.saving,
              label: '自定义窗口设置',
              value: controller.overrideWindow,
              onChanged: controller.setOverrideWindow,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(
                      '全屏',
                      style: TextStyle(color: tokens.colorContrast),
                    ),
                    subtitle: Text(
                      '以全屏模式启动游戏。',
                      style: TextStyle(
                        color: tokens.colorBase.withValues(alpha: 0.65),
                      ),
                    ),
                    value: controller.fullscreen,
                    activeThumbColor: tokens.colorOnBrand,
                    activeTrackColor: tokens.colorBrand,
                    onChanged: controller.setFullscreen,
                  ),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(
                        child: IgnorePointer(
                          ignoring: controller.fullscreen,
                          child: Opacity(
                            opacity: controller.fullscreen ? 0.45 : 1,
                            child: _labeledNumberField(
                              context,
                              label: '宽度',
                              controller: controller.widthController,
                              onChanged: (_) => controller.scheduleSave(
                                () => controller.save(
                                  windowWidth: int.tryParse(
                                    controller.widthController.text,
                                  ),
                                  windowHeight: int.tryParse(
                                    controller.heightController.text,
                                  ),
                                  fullscreen: controller.fullscreen,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: IgnorePointer(
                          ignoring: controller.fullscreen,
                          child: Opacity(
                            opacity: controller.fullscreen ? 0.45 : 1,
                            child: _labeledNumberField(
                              context,
                              label: '高度',
                              controller: controller.heightController,
                              onChanged: (_) => controller.scheduleSave(
                                () => controller.save(
                                  windowWidth: int.tryParse(
                                    controller.widthController.text,
                                  ),
                                  windowHeight: int.tryParse(
                                    controller.heightController.text,
                                  ),
                                  fullscreen: controller.fullscreen,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _labeledNumberField(
    BuildContext context, {
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
  }) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: tokens.colorContrast)),
        const SizedBox(height: 6),
        InputBarWidget(
          colorScheme: Theme.of(context).colorScheme,
          size: InputBarSize.medium,
          controller: controller,
          onChanged: onChanged,
        ),
      ],
    );
  }
}
