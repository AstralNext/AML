import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_controller.dart';
import 'package:flutter/material.dart';

class CreateInstanceTypeStage extends StatelessWidget {
  const CreateInstanceTypeStage({
    super.key,
    required this.tokens,
    required this.controller,
  });

  final AppThemeTokens tokens;
  final CreateInstanceController controller;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(30, 20, 30, 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            '选择实例类型',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 16),
          CreateInstanceTypeOption(
            tokens: tokens,
            icon: Icons.dashboard_customize_outlined,
            title: '自定义设置',
            description: '从头开始，选择一个加载器和游戏版本。',
            onTap: controller.selectCustomType,
          ),
          const SizedBox(height: 12),
          CreateInstanceTypeOption(
            tokens: tokens,
            icon: Icons.inventory_2_outlined,
            title: '安装整合包',
            description: '在 Modrinth 上浏览整合包或从文件中导入一个。',
            onTap: controller.selectModpackType,
          ),
          const SizedBox(height: 20),
          Text(
            '实例是带有特定加载器、游戏版本和模组的一套 Minecraft 配置。',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: tokens.colorBase.withValues(alpha: 0.7),
            ),
          ),
        ],
      ),
    );
  }
}

class CreateInstanceTypeOption extends StatefulWidget {
  const CreateInstanceTypeOption({
    super.key,
    required this.tokens,
    required this.icon,
    required this.title,
    required this.description,
    required this.onTap,
  });

  final AppThemeTokens tokens;
  final IconData icon;
  final String title;
  final String description;
  final VoidCallback onTap;

  @override
  State<CreateInstanceTypeOption> createState() =>
      _CreateInstanceTypeOptionState();
}

class _CreateInstanceTypeOptionState extends State<CreateInstanceTypeOption> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: _hovered
                ? tokens.colorSuperRaisedBg
                : tokens.colorButtonBg.withValues(alpha: 0.55),
            borderRadius: BorderRadius.circular(18),
            border: Border.all(
              color: tokens.colorSecondary.withValues(alpha: 0.28),
            ),
          ),
          child: Row(
            children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(14),
                  border: Border.all(
                    color: tokens.colorSecondary.withValues(alpha: 0.4),
                  ),
                ),
                child: Icon(widget.icon, size: 28, color: tokens.colorBase),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      widget.title,
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.description,
                      style: TextStyle(
                        fontSize: 13,
                        height: 1.35,
                        color: tokens.colorBase.withValues(alpha: 0.75),
                      ),
                    ),
                  ],
                ),
              ),
              AnimatedOpacity(
                opacity: _hovered ? 1 : 0,
                duration: const Duration(milliseconds: 100),
                child: Icon(
                  Icons.chevron_right,
                  color: tokens.colorBase.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
