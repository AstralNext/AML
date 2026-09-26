import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/dialogs/create_instance_controller.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class CreateInstanceExternalStage extends StatelessWidget {
  const CreateInstanceExternalStage({
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
          constraints: BoxConstraints(maxHeight: maxBody.clamp(320, 580)),
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(28, 16, 28, 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '从 .minecraft 文件夹导入',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '使用正则在全部磁盘搜索现有 .minecraft 目录，AML 将物理完整复制游戏数据并将其转换为独立沙盒实例。',
                  style: TextStyle(
                    fontSize: 12,
                    height: 1.4,
                    color: tokens.colorBase.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 14),

                // 路径选择行
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    Expanded(
                      child: SizedBox(
                        height: 38,
                        child: InputBarWidget(
                          colorScheme: colorScheme,
                          controller: controller.externalPathController,
                          hintText: '输入或选择 .minecraft 路径',
                          size: InputBarSize.medium,
                          prefixIcon: Icon(
                            Icons.folder_outlined,
                            size: 18,
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                          onSubmitted: (val) => controller.scanExternalPath(val),
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    NavRectButton(
                      text: '浏览',
                      icon: Icons.folder_open_outlined,
                      isSelected: false,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 8,
                      ),
                      onTap: controller.importingExternal
                          ? () {}
                          : controller.pickExternalDirectory,
                    ),
                    const SizedBox(width: 6),
                    SizedBox(
                      height: 38,
                      width: 38,
                      child: CustomButton(
                        icon: Icons.search,
                        size: ButtonSize.medium,
                        backgroundColor: tokens.colorButtonBg.withAlpha(90),
                        onTap: controller.importingExternal
                            ? () {}
                            : () {
                                controller.startDiskSearch();
                                controller.scanExternalPath();
                              },
                      ),
                    ),
                  ],
                ),

                // 全盘正则搜索到的路径选择 Chips
                _buildDiscoveredPathChips(),

                if (controller.error != null) ...[
                  const SizedBox(height: 10),
                  Container(
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: colorScheme.error.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: colorScheme.error.withValues(alpha: 0.3),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 18,
                          color: colorScheme.error,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            controller.error!,
                            style: TextStyle(
                              color: colorScheme.error,
                              fontSize: 12,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],

                const SizedBox(height: 14),

                // 正在导入时的全屏遮罩/进度
                if (controller.importingExternal) ...[
                  _buildImportProgressWidget(),
                ] else if (controller.scanningExternal) ...[
                  const Padding(
                    padding: EdgeInsets.symmetric(vertical: 40),
                    child: Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          CircularProgressIndicator(strokeWidth: 2),
                          SizedBox(height: 12),
                          Text('正在扫描版本与数据…', style: TextStyle(fontSize: 13)),
                        ],
                      ),
                    ),
                  ),
                ] else if (controller.externalGames.isNotEmpty) ...[
                  _buildGameListHeader(),
                  const SizedBox(height: 8),
                  _buildGameCardsList(),
                ],
              ],
            ),
          ),
        ),

        // 底部按钮栏
        Divider(
          height: 1,
          thickness: 1,
          color: tokens.colorSecondary.withAlpha(35),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(28, 12, 28, 14),
          child: Row(
            children: [
              NavRectButton(
                text: '返回',
                icon: Icons.arrow_back,
                isSelected: false,
                onTap: controller.importingExternal
                    ? () {}
                    : controller.backFromExternalImportStage,
              ),
              const Spacer(),
              if (controller.externalGames.isNotEmpty &&
                  !controller.importingExternal) ...[
                Text(
                  '已选 ${controller.selectedExternalGameIds.length} / ${controller.externalGames.length}',
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(width: 14),
                NavRectButton(
                  text: '一键导入 (${controller.selectedExternalGameIds.length})',
                  icon: Icons.download_done_rounded,
                  isSelected: false,
                  defaultBackgroundColor: tokens.colorBrand,
                  onTap: controller.selectedExternalGameIds.isEmpty
                      ? () {}
                      : controller.confirmImportExternalGames,
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildDiscoveredPathChips() {
    final paths = controller.discoveredDiskPaths;
    final isSearching = controller.isSearchingDisks;

    if (paths.isEmpty && !isSearching) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              if (isSearching) ...[
                const SizedBox(
                  width: 11,
                  height: 11,
                  child: CircularProgressIndicator(strokeWidth: 1.8),
                ),
                const SizedBox(width: 6),
                Text(
                  '正在全盘检索 .minecraft 目录…',
                  style: TextStyle(
                    fontSize: 11,
                    color: tokens.colorBase.withValues(alpha: 0.75),
                  ),
                ),
              ] else ...[
                Icon(
                  Icons.folder_special_outlined,
                  size: 13,
                  color: tokens.colorBase.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 4),
                Text(
                  '全盘发现的 .minecraft 目录：',
                  style: TextStyle(
                    fontSize: 11,
                    color: tokens.colorBase.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ],
          ),
          if (paths.isNotEmpty) ...[
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: paths.map((path) {
                final isCurrent =
                    controller.externalPathController.text.trim() == path;
                return InkWell(
                  onTap: controller.importingExternal
                      ? null
                      : () {
                          controller.externalPathController.text = path;
                          controller.scanExternalPath(path);
                        },
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding:
                        const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    constraints: const BoxConstraints(maxWidth: 420),
                    decoration: BoxDecoration(
                      color: isCurrent
                          ? colorScheme.primary.withValues(alpha: 0.15)
                          : tokens.colorButtonBg.withAlpha(60),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isCurrent
                            ? colorScheme.primary.withValues(alpha: 0.5)
                            : tokens.colorSecondary.withValues(alpha: 0.2),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.check_circle_outline,
                          size: 13,
                          color: isCurrent
                              ? colorScheme.primary
                              : tokens.colorBase,
                        ),
                        const SizedBox(width: 4),
                        Flexible(
                          child: Text(
                            path,
                            overflow: TextOverflow.ellipsis,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 11,
                              color: isCurrent
                                  ? colorScheme.primary
                                  : tokens.colorBase,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildImportProgressWidget() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: colorScheme.primary.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  valueColor: AlwaysStoppedAnimation(colorScheme.primary),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  controller.importStatusText.isEmpty
                      ? '正在进行物理数据搬运与格式转换…'
                      : controller.importStatusText,
                  style: const TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              Text(
                '${(controller.importProgress * 100).toInt()}%',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: colorScheme.primary,
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: LinearProgressIndicator(
              value: controller.importProgress.clamp(0.0, 1.0),
              minHeight: 8,
              backgroundColor: tokens.colorButtonBg,
              valueColor: AlwaysStoppedAnimation(colorScheme.primary),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            '提示：正在完整复制模组、存档与配置文件并沙盒化隔离，原游戏不受任何影响。',
            style: TextStyle(
              fontSize: 11,
              color: tokens.colorBase.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGameListHeader() {
    final allSelected = controller.selectedExternalGameIds.length ==
        controller.externalGames.length;
    return Row(
      children: [
        InkWell(
          onTap: controller.toggleSelectAllExternalGames,
          borderRadius: BorderRadius.circular(6),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
            child: Row(
              children: [
                Checkbox(
                  value: allSelected,
                  onChanged: (_) => controller.toggleSelectAllExternalGames(),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 6),
                const Text(
                  '全选',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
              ],
            ),
          ),
        ),
        const Spacer(),
        Text(
          '共发现 ${controller.externalGames.length} 个版本',
          style: TextStyle(
            fontSize: 12,
            color: tokens.colorBase.withValues(alpha: 0.6),
          ),
        ),
      ],
    );
  }

  Widget _buildGameCardsList() {
    return ListView.separated(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: controller.externalGames.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final game = controller.externalGames[index];
        final isSelected = controller.selectedExternalGameIds.contains(game.id);

        return InkWell(
          onTap: () => controller.toggleSelectExternalGame(game.id),
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
            decoration: BoxDecoration(
              color: isSelected
                  ? tokens.colorSuperRaisedBg
                  : tokens.colorButtonBg.withAlpha(45),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: isSelected
                    ? colorScheme.primary.withValues(alpha: 0.5)
                    : tokens.colorSecondary.withValues(alpha: 0.22),
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                Checkbox(
                  value: isSelected,
                  onChanged: (_) => controller.toggleSelectExternalGame(game.id),
                  materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  visualDensity: VisualDensity.compact,
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        game.name,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: [
                          _buildBadge(
                            'MC ${game.gameVersion}',
                            color: tokens.colorBase,
                          ),
                          _buildBadge(
                            _loaderLabel(game.loader, game.loaderVersion),
                            color: _loaderColor(game.loader),
                          ),
                          if (game.modCount > 0)
                            _buildBadge(
                              '${game.modCount} 个模组',
                              color: Colors.purpleAccent,
                            ),
                          if (game.saveCount > 0)
                            _buildBadge(
                              '${game.saveCount} 个存档',
                              color: Colors.amberAccent,
                            ),
                          _buildBadge(
                            game.isIsolated ? '独立版本' : '共享根目录（将自动隔离）',
                            color: game.isIsolated
                                ? Colors.green
                                : Colors.orangeAccent,
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBadge(String text, {required Color color}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withValues(alpha: 0.25)),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  String _loaderLabel(String loader, String? version) {
    final base = switch (loader.toLowerCase()) {
      'fabric' => 'Fabric',
      'forge' => 'Forge',
      'neoforge' => 'NeoForge',
      'quilt' => 'Quilt',
      _ => 'Vanilla',
    };
    if (version != null && version.isNotEmpty) {
      return '$base $version';
    }
    return base;
  }

  Color _loaderColor(String loader) {
    return switch (loader.toLowerCase()) {
      'fabric' => Colors.blue,
      'forge' => Colors.deepOrangeAccent,
      'neoforge' => Colors.orange,
      'quilt' => Colors.purpleAccent,
      _ => Colors.teal,
    };
  }
}
