import 'dart:typed_data';

import 'package:aml/src/features/wardrobe/ui/public_skin_widgets.dart';
import 'package:aml/src/features/wardrobe/ui/skin_2d_thumbnail.dart';
import 'package:aml/src/features/wardrobe/ui/skin_3d_viewer.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

/// 皮肤编辑对话框左栏：3D 预览 + 应用/取消按钮。
class SkinEditorPreviewPane extends StatelessWidget {
  const SkinEditorPreviewPane({
    super.key,
    required this.username,
    required this.skin,
    required this.skinPng,
    required this.hasPending,
    required this.applying,
    required this.onApply,
    required this.onReset,
  });

  final String username;
  final rust.SkinDto? skin;
  final Uint8List? skinPng;
  final bool hasPending;
  final bool applying;
  final VoidCallback onApply;
  final VoidCallback onReset;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final slim = skin?.variant.toLowerCase() == 'slim';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          '皮肤选择器',
          style: TextStyle(
            fontSize: 28,
            fontWeight: FontWeight.w800,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 12),
        Expanded(
          child: Column(
            children: [
              if (hasPending)
                Padding(
                  padding: const EdgeInsets.only(bottom: 8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: tokens.colorBrand.withValues(alpha: 0.16),
                      borderRadius: BorderRadius.circular(20),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.visibility_outlined,
                          size: 16,
                          color: tokens.colorBrand,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '预览中',
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorBrand,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: const Color(0xE6000000),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  username,
                  style: const TextStyle(
                    fontFamily: 'Consolas',
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                    color: Colors.white,
                    letterSpacing: 0.3,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: skinPng != null
                    ? Skin3DViewer(
                        key: ValueKey(skin?.textureKey ?? 'skin'),
                        skinPng: skinPng!,
                        slim: slim,
                      )
                    : Center(
                        child: Icon(
                          Icons.person_outline,
                          size: 96,
                          color: tokens.colorBrand,
                        ),
                      ),
              ),
              const SizedBox(height: 6),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.open_with,
                    size: 14,
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '拖动旋转',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
              if (hasPending) ...[
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: NavRectButton(
                        isSelected: false,
                        icon: Icons.close,
                        text: '取消',
                        defaultBackgroundColor: tokens.colorButtonBg,
                        onTap: applying ? () {} : onReset,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: NavRectButton(
                        isSelected: true,
                        icon: applying ? Icons.hourglass_top : Icons.check,
                        text: applying ? '应用中…' : '应用',
                        selectedBackgroundColor: tokens.colorBrand,
                        selectedColor: tokens.colorOnBrand,
                        onTap: applying ? () {} : onApply,
                      ),
                    ),
                  ],
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

/// 皮肤编辑对话框右栏：「已保存皮肤」与「MineSkin」两个可折叠区块。
class SkinEditorSectionList extends StatelessWidget {
  const SkinEditorSectionList({
    super.key,
    required this.saved,
    required this.mineItems,
    required this.mineLoading,
    required this.mineError,
    required this.mineHasMore,
    required this.mineSearch,
    required this.openSections,
    required this.previewKey,
    required this.equippedKey,
    required this.pngFor,
    required this.minePngFor,
    required this.onToggle,
    required this.onSelect,
    required this.onSelectMine,
    required this.onMineSearch,
    required this.onMineMore,
    required this.onAdd,
    required this.onDelete,
  });

  final List<rust.SkinDto> saved;
  final List<MineSkinItem> mineItems;
  final bool mineLoading;
  final String? mineError;
  final bool mineHasMore;
  final TextEditingController mineSearch;
  final Set<String> openSections;
  final String? previewKey;
  final String? equippedKey;
  final Uint8List? Function(rust.SkinDto skin) pngFor;
  final Future<Uint8List?> Function(MineSkinItem item) minePngFor;
  final ValueChanged<String> onToggle;
  final ValueChanged<rust.SkinDto> onSelect;
  final ValueChanged<MineSkinItem> onSelectMine;
  final VoidCallback onMineSearch;
  final VoidCallback onMineMore;
  final VoidCallback onAdd;
  final ValueChanged<rust.SkinDto> onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    Widget sectionHeader(String key, String title) {
      return InkWell(
        onTap: () => onToggle(key),
        borderRadius: BorderRadius.circular(8),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10),
          child: Row(
            children: [
              Icon(
                openSections.contains(key)
                    ? Icons.expand_more
                    : Icons.chevron_right,
                color: tokens.colorBase,
              ),
              const SizedBox(width: 4),
              Text(
                title,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: tokens.colorContrast,
                ),
              ),
            ],
          ),
        ),
      );
    }

    return ListView(
      children: [
        sectionHeader('saved', '已保存皮肤'),
        if (openSections.contains('saved'))
          LayoutBuilder(
            builder: (context, constraints) {
              final maxW = constraints.maxWidth;
              final cols = maxW > 980
                  ? 5
                  : maxW > 760
                      ? 4
                      : maxW > 480
                          ? 3
                          : 2;
              const gap = 12.0;
              final cardW = (maxW - gap * (cols - 1)) / cols;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: [
                  SizedBox(
                    width: cardW,
                    child: AddSkinTile(onTap: onAdd),
                  ),
                  for (final skin in saved)
                    SizedBox(
                      width: cardW,
                      child: SkinTile(
                        skin: skin,
                        pngBytes: pngFor(skin),
                        selected: skin.textureKey == previewKey,
                        equipped: skin.textureKey == equippedKey,
                        onTap: () => onSelect(skin),
                        onDelete: skin.source == 'custom'
                            ? () => onDelete(skin)
                            : null,
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 12),
        sectionHeader('mineskin', 'MineSkin'),
        if (openSections.contains('mineskin')) ...[
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: mineSearch,
                  onSubmitted: (_) => onMineSearch(),
                  decoration: const InputDecoration(
                    hintText: '搜索 MineSkin',
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 18),
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 10,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              NavRectButton(
                isSelected: false,
                icon: Icons.refresh,
                text: '刷新',
                defaultBackgroundColor: tokens.colorButtonBg,
                defaultColor: tokens.colorContrast,
                onTap: onMineSearch,
              ),
            ],
          ),
          const SizedBox(height: 10),
          if (mineError != null)
            Text(
              mineError!,
              style: TextStyle(
                color: tokens.colorBase.withValues(alpha: 0.75),
              ),
            )
          else if (mineLoading && mineItems.isEmpty)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            )
          else
            LayoutBuilder(
              builder: (context, constraints) {
                final maxW = constraints.maxWidth;
                final cols = maxW > 980
                    ? 5
                    : maxW > 760
                        ? 4
                        : maxW > 480
                            ? 3
                            : 2;
                const gap = 12.0;
                final cardW = (maxW - gap * (cols - 1)) / cols;
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Wrap(
                      spacing: gap,
                      runSpacing: gap,
                      children: [
                        for (final item in mineItems)
                          SizedBox(
                            width: cardW,
                            child: FutureBuilder<Uint8List?>(
                              future: minePngFor(item),
                              builder: (context, snapshot) {
                                return MineSkinTile(
                                  item: item,
                                  png: snapshot.data,
                                  selected: item.texture == previewKey,
                                  onTap: () => onSelectMine(item),
                                );
                              },
                            ),
                          ),
                      ],
                    ),
                    if (mineHasMore || mineLoading) ...[
                      const SizedBox(height: 12),
                      Align(
                        alignment: Alignment.center,
                        child: TextButton(
                          onPressed: mineLoading ? null : onMineMore,
                          child: Text(mineLoading ? '加载中…' : '加载更多'),
                        ),
                      ),
                    ],
                  ],
                );
              },
            ),
        ],
        const SizedBox(height: 20),
      ],
    );
  }
}

/// MineSkin 列表瓦片（编辑对话框内）。
class MineSkinTile extends StatelessWidget {
  const MineSkinTile({
    super.key,
    required this.item,
    required this.png,
    required this.selected,
    required this.onTap,
  });

  final MineSkinItem item;
  final Uint8List? png;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final slim = item.variant?.toLowerCase() == 'slim';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: selected
                ? tokens.colorBrand.withValues(alpha: 0.14)
                : tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.22),
              width: selected ? 2 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 31 / 40,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
              child: Column(
                children: [
                  Expanded(
                    child: png != null
                        ? Skin2DThumbnail(skinPng: png!, slim: slim)
                        : Icon(Icons.person, color: tokens.colorBrand),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    item.displayName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      fontSize: 13,
                      color: tokens.colorContrast,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// 已保存皮肤瓦片（编辑对话框内）。
class SkinTile extends StatelessWidget {
  const SkinTile({
    super.key,
    required this.skin,
    required this.pngBytes,
    required this.selected,
    required this.equipped,
    required this.onTap,
    this.onDelete,
  });

  final rust.SkinDto skin;
  final Uint8List? pngBytes;
  final bool selected;
  final bool equipped;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final slim = skin.variant.toLowerCase() == 'slim';
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 120),
          decoration: BoxDecoration(
            color: selected
                ? tokens.colorBrand.withValues(alpha: 0.14)
                : tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : equipped
                      ? tokens.colorBrand.withValues(alpha: 0.35)
                      : tokens.colorSecondary.withValues(alpha: 0.22),
              width: selected ? 2 : 1,
            ),
          ),
          child: AspectRatio(
            aspectRatio: 31 / 40,
            child: Stack(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(10, 12, 10, 10),
                  child: Column(
                    children: [
                      Expanded(
                        child: pngBytes != null
                            ? Skin2DThumbnail(
                                skinPng: pngBytes!,
                                slim: slim,
                              )
                            : Icon(Icons.person, color: tokens.colorBrand),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        skin.name ?? '皮肤',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 13,
                          color: tokens.colorContrast,
                        ),
                      ),
                      if (equipped)
                        Text(
                          '使用中',
                          style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: tokens.colorBrand,
                          ),
                        ),
                    ],
                  ),
                ),
                if (onDelete != null)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: IconButton(
                      tooltip: '删除皮肤',
                      iconSize: 18,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 28,
                        minHeight: 28,
                      ),
                      onPressed: onDelete,
                      icon: Icon(
                        Icons.delete_outline,
                        color: tokens.colorBase.withValues(alpha: 0.7),
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 「添加皮肤」虚线占位瓦片。
class AddSkinTile extends StatelessWidget {
  const AddSkinTile({super.key, required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: CustomPaint(
          painter: DashedRRectPainter(
            color: tokens.colorSecondary.withValues(alpha: 0.45),
            radius: 20,
          ),
          child: Container(
            decoration: BoxDecoration(
              color: tokens.colorRaisedBg.withValues(alpha: 0.55),
              borderRadius: BorderRadius.circular(20),
            ),
            child: AspectRatio(
              aspectRatio: 31 / 40,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.add,
                    size: 40,
                    color: tokens.colorBase.withValues(alpha: 0.75),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '添加皮肤',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 14,
                      color: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    '拖放',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.55),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class DashedRRectPainter extends CustomPainter {
  DashedRRectPainter({required this.color, required this.radius});

  final Color color;
  final double radius;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    final rrect = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(radius),
    );
    final path = Path()..addRRect(rrect);
    for (final metric in path.computeMetrics()) {
      var distance = 0.0;
      const dash = 6.0;
      const gap = 4.0;
      while (distance < metric.length) {
        final next = (distance + dash).clamp(0, metric.length).toDouble();
        canvas.drawPath(metric.extractPath(distance, next), paint);
        distance = next + gap;
      }
    }
  }

  @override
  bool shouldRepaint(covariant DashedRRectPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
