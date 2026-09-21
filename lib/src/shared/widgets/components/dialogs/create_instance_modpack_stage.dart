import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_controller.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_type_stage.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class CreateInstanceModpackStage extends StatelessWidget {
  const CreateInstanceModpackStage({
    super.key,
    required this.tokens,
    required this.controller,
    required this.colorScheme,
  });

  final AppThemeTokens tokens;
  final CreateInstanceController controller;
  final ColorScheme colorScheme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 20, 30, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '安装整合包',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 16),
          CreateInstanceTypeOption(
            tokens: tokens,
            icon: Icons.travel_explore_outlined,
            title: '在 Modrinth 浏览',
            description: '打开发现页，筛选并安装整合包到新实例。',
            onTap: controller.creating
                ? () {}
                : controller.browseModpacksOnModrinth,
          ),
          const SizedBox(height: 12),
          CreateInstanceTypeOption(
            tokens: tokens,
            icon: Icons.folder_open_outlined,
            title: '从文件导入',
            description:
                '支持 .mrpack、CurseForge、MCBBS、MultiMC 整合包 zip。',
            onTap: controller.creating ? () {} : controller.pickImportPack,
          ),
          if (controller.error != null) ...[
            const SizedBox(height: 12),
            Text(
              controller.error!,
              style: TextStyle(color: colorScheme.error, fontSize: 12),
            ),
          ],
          if (controller.creating) ...[
            const SizedBox(height: 16),
            const Center(child: CircularProgressIndicator(strokeWidth: 2)),
          ],
          const SizedBox(height: 20),
          Align(
            alignment: Alignment.centerRight,
            child: NavRectButton(
              text: '返回',
              icon: Icons.arrow_back,
              isSelected: false,
              onTap: controller.creating
                  ? () {}
                  : controller.backFromModpackStage,
            ),
          ),
        ],
      ),
    );
  }
}
