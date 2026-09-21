import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_controller.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class CreateInstanceCustomStage extends StatelessWidget {
  const CreateInstanceCustomStage({
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
    final maxBody = MediaQuery.sizeOf(context).height * 0.82 - 84 - 72;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        ConstrainedBox(
          constraints: BoxConstraints(maxHeight: maxBody.clamp(280, 560)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(30, 20, 30, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    InstanceIcon(
                      instanceId: 'new-instance',
                      iconPath: controller.iconPath,
                      size: 80,
                      borderRadius: 12,
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
                          onTap: controller.creating
                              ? () {}
                              : controller.pickIcon,
                        ),
                        if (controller.iconPath != null) ...[
                          const SizedBox(height: 8),
                          NavRectButton(
                            text: '移除图标',
                            icon: Icons.close,
                            isSelected: false,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 12,
                              vertical: 8,
                            ),
                            onTap: controller.creating
                                ? () {}
                                : controller.clearIcon,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '名称',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                InputBarWidget(
                  colorScheme: colorScheme,
                  size: InputBarSize.medium,
                  hintText: '输入实例名称',
                  controller: controller.nameController,
                ),
                const SizedBox(height: 16),
                const Text(
                  '加载器',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final item in const [
                      ('vanilla', 'Vanilla'),
                      ('fabric', 'Fabric'),
                      ('neoforge', 'NeoForge'),
                      ('forge', 'Forge'),
                      ('quilt', 'Quilt'),
                    ])
                      _PillChoice(
                        tokens: tokens,
                        label: item.$2,
                        selected: controller.loader == item.$1,
                        onTap: controller.creating
                            ? null
                            : () async {
                                await controller.setLoader(item.$1);
                              },
                      ),
                  ],
                ),
                const SizedBox(height: 16),
                const Text(
                  '游戏版本',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 8),
                if (controller.loadingVersions)
                  const Padding(
                    padding: EdgeInsets.all(12),
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                else
                  DropdownButtonWidget(
                    width: 220,
                    dropdownMinWidth: 240,
                    colorScheme: colorScheme,
                    items: controller.displayVersions
                        .map(
                          (v) => DropdownItem(
                            display: controller.versionLabel(v),
                            value: v.id,
                          ),
                        )
                        .toList(),
                    selectedValue: controller.gameVersion ?? '',
                    footerLabel: controller.hasNonReleaseVersions
                        ? (controller.showSnapshots ? '隐藏快照版本' : '显示所有版本')
                        : null,
                    footerValue: controller.showSnapshots,
                    onFooterChanged: controller.hasNonReleaseVersions
                        ? controller.setShowSnapshots
                        : null,
                    onChanged: (value) async {
                      await controller.setGameVersion(value);
                    },
                  ),
                if (controller.loader != 'vanilla') ...[
                  const SizedBox(height: 16),
                  const Text(
                    '加载器版本',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: [
                      _PillChoice(
                        tokens: tokens,
                        label: '稳定版',
                        selected: controller.loaderChannel == 'stable',
                        onTap: controller.creating
                            ? null
                            : () => controller.setLoaderChannelWithPick(
                                  'stable',
                                ),
                      ),
                      _PillChoice(
                        tokens: tokens,
                        label: '最新版',
                        selected: controller.loaderChannel == 'latest',
                        onTap: controller.creating
                            ? null
                            : () => controller.setLoaderChannelWithPick(
                                  'latest',
                                ),
                      ),
                      _PillChoice(
                        tokens: tokens,
                        label: '其他',
                        selected: controller.loaderChannel == 'other',
                        onTap: controller.creating
                            ? null
                            : () => controller.setLoaderChannel('other'),
                      ),
                    ],
                  ),
                  if (controller.loaderChannel == 'other') ...[
                    const SizedBox(height: 8),
                    DropdownButtonWidget(
                      width: 280,
                      dropdownMinWidth: 300,
                      colorScheme: colorScheme,
                      items: controller.loaderVersions
                          .map(
                            (v) => DropdownItem(
                              display: v.stable ? '${v.id} (stable)' : v.id,
                              value: v.id,
                            ),
                          )
                          .toList(),
                      selectedValue: controller.loaderVersion ?? '',
                      onChanged: (value) => controller.setLoaderVersion(value),
                    ),
                  ],
                ],
                if (controller.error != null) ...[
                  const SizedBox(height: 12),
                  Text(
                    controller.error!,
                    style: TextStyle(
                      color: colorScheme.error,
                      fontSize: 12,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(30, 8, 30, 24),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              NavRectButton(
                text: '返回',
                icon: Icons.arrow_back,
                isSelected: false,
                onTap: controller.creating
                    ? () {}
                    : controller.backFromCustomStage,
              ),
              const SizedBox(width: 10),
              NavRectButton(
                isSelected: false,
                icon: Icons.add,
                defaultBackgroundColor: tokens.colorBrand,
                text: controller.creating ? '创建中…' : '创建实例',
                label: '创建实例',
                onTap: controller.creating ? () {} : controller.submitCustom,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _PillChoice extends StatelessWidget {
  const _PillChoice({
    required this.tokens,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final AppThemeTokens tokens;
  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: selected
          ? tokens.colorBrand.withValues(alpha: 0.18)
          : tokens.colorButtonBg.withValues(alpha: 0.55),
      borderRadius: BorderRadius.circular(999),
      child: InkWell(
        borderRadius: BorderRadius.circular(999),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (selected) ...[
                Icon(Icons.check, size: 14, color: tokens.colorBrand),
                const SizedBox(width: 6),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: selected ? tokens.colorContrast : tokens.colorBase,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
