import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/ui/instance_settings_controller.dart';
import 'package:aml/src/features/instances/ui/instance_settings_widgets.dart';
import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/ui/widgets/java_selector.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:flutter/material.dart';

/// 实例设置「Java 及内存」标签页：Java 安装、内存、JVM 参数与环境变量覆盖。
class InstanceSettingsJavaTab extends StatelessWidget {
  const InstanceSettingsJavaTab({super.key, required this.controller});

  final InstanceSettingsController controller;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final resourceDir = getIt<ResourceSettingsState>().resourceDirectory.value;
    final activeJavaPath =
        controller.overrideJava ? controller.javaPath : controller.defaultJavaPath;
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        return ListView(
          padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
          children: [
            instanceSettingsOverrideRow(
              context,
              saving: controller.saving,
              label: '自定义 Java 安装',
              value: controller.overrideJava,
              onChanged: controller.setOverrideJava,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Java ${controller.requiredJavaMajor}',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(height: 8),
                  JavaSelector(
                    version: controller.requiredJavaMajor,
                    path: activeJavaPath,
                    appDataDir: resourceDir,
                    javaDownloadService: getIt<JavaDownloadService>(),
                    disabled: !controller.overrideJava || controller.saving,
                    onPathChanged: controller.setJavaPath,
                  ),
                  if (!controller.overrideJava &&
                      controller.defaultJavaPath.isEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      '启动时将自动选择或安装所需的 '
                      'Java ${controller.requiredJavaMajor}。',
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.colorBase.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(height: 22),
            instanceSettingsOverrideRow(
              context,
              saving: controller.saving,
              label: '自定义内存分配',
              value: controller.overrideMemory,
              onChanged: controller.setOverrideMemory,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Slider(
                          value: controller.memoryMb.clamp(
                            512,
                            controller.maxMemoryMb.toDouble(),
                          ),
                          min: 512,
                          max: controller.maxMemoryMb.toDouble(),
                          divisions:
                              ((controller.maxMemoryMb - 512) ~/ 64).clamp(
                            1,
                            512,
                          ),
                          label: '${controller.memoryMb.round()} MB',
                          activeColor: tokens.colorBrand,
                          onChanged: controller.setMemoryMb,
                        ),
                      ),
                      SizedBox(
                        width: 84,
                        child: Text(
                          '${controller.memoryMb.round()} MB',
                          textAlign: TextAlign.right,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorContrast,
                          ),
                        ),
                      ),
                    ],
                  ),
                  Text(
                    '512 MB - ${controller.maxMemoryMb} MB',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.65),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 22),
            instanceSettingsOverrideRow(
              context,
              saving: controller.saving,
              label: '自定义 Java 参数',
              value: controller.overrideJvmArgs,
              onChanged: controller.setOverrideJvmArgs,
              child: InputBarWidget(
                colorScheme: Theme.of(context).colorScheme,
                size: InputBarSize.medium,
                hintText: '输入 Java 参数，如 -Xmx4G -Dfoo=bar…',
                controller: controller.jvmArgsController,
                focusNode: controller.jvmArgsFocusNode,
                onChanged: controller.scheduleJvmArgsSave,
              ),
            ),
            const SizedBox(height: 22),
            instanceSettingsOverrideRow(
              context,
              saving: controller.saving,
              label: '自定义环境变量',
              value: controller.overrideEnvVars,
              onChanged: controller.setOverrideEnvVars,
              child: InputBarWidget(
                colorScheme: Theme.of(context).colorScheme,
                size: InputBarSize.medium,
                hintText: '每行一个，格式 KEY=VALUE',
                controller: controller.envVarsController,
                focusNode: controller.envVarsFocusNode,
                minLines: 3,
                maxLines: 6,
                onChanged: controller.scheduleEnvVarsSave,
              ),
            ),
          ],
        );
      },
    );
  }
}
