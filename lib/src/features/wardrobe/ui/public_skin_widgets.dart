import 'dart:typed_data';

import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/features/wardrobe/ui/skin_2d_thumbnail.dart';
import 'package:aml/src/features/wardrobe/ui/skin_3d_viewer.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

/// MineSkin catalog entry used by the public skins browser.
class MineSkinItem {
  const MineSkinItem({
    required this.uuid,
    required this.shortId,
    required this.name,
    required this.texture,
    this.views,
    this.variant,
  });

  final String uuid;
  final String shortId;
  final String? name;
  final String texture;
  final int? views;
  final String? variant;

  factory MineSkinItem.fromJson(Map<String, dynamic> json) {
    return MineSkinItem(
      uuid: json['uuid'] as String,
      shortId: json['shortId'] as String? ?? '',
      name: json['name'] as String?,
      texture: json['texture'] as String,
      views: (json['views'] as num?)?.toInt(),
      variant: json['variant'] as String?,
    );
  }

  bool get hasDetails => views != null && variant != null;

  MineSkinItem withDetails(Map<String, dynamic> json) {
    return MineSkinItem(
      uuid: uuid,
      shortId: json['shortId'] as String? ?? shortId,
      name: json['name'] as String? ?? name,
      texture: texture,
      views: (json['views'] as num?)?.toInt() ?? views,
      variant: json['variant'] as String? ?? variant,
    );
  }

  String get displayName =>
      name == null || name!.trim().isEmpty ? shortId : name!;
  String get textureUrl => 'https://textures.minecraft.net/texture/$texture';
}

class PublicSkinCard extends StatelessWidget {
  const PublicSkinCard({
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
    return Material(
      color: selected
          ? tokens.colorBrand.withValues(alpha: 0.14)
          : tokens.colorRaisedBg,
      borderRadius: BorderRadius.circular(16),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.2),
              width: selected ? 2 : 1,
            ),
          ),
          child: Column(
            children: [
              Expanded(
                child: png == null
                    ? const Center(child: CircularProgressIndicator())
                    : Skin2DThumbnail(skinPng: png!),
              ),
              const SizedBox(height: 6),
              Text(
                item.displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: tokens.colorContrast,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 3),
              Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Icon(
                    Icons.visibility_outlined,
                    size: 13,
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 4),
                  Text(
                    item.views == null ? '读取中' : '${item.views} 次查看',
                    style: TextStyle(
                      color: tokens.colorBase.withValues(alpha: 0.55),
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class PublicSkinPreview extends StatelessWidget {
  const PublicSkinPreview({
    super.key,
    required this.item,
    required this.png,
    required this.variant,
    required this.msaAccounts,
    required this.selectedMsaAccountId,
    required this.applying,
    required this.onAccountChanged,
    required this.onDownload,
    required this.onApply,
  });

  final MineSkinItem? item;
  final Uint8List? png;
  final String variant;
  final List<rust.AccountDto> msaAccounts;
  final String selectedMsaAccountId;
  final bool applying;
  final ValueChanged<String> onAccountChanged;
  final VoidCallback onDownload;
  final VoidCallback onApply;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(
          color: tokens.colorSecondary.withValues(alpha: 0.22),
        ),
      ),
      child: item == null
          ? Center(
              child: Text(
                '选择一个皮肤进行预览',
                style: TextStyle(
                  color: tokens.colorBase.withValues(alpha: 0.65),
                ),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  item!.displayName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.colorContrast,
                    fontSize: 17,
                    fontWeight: FontWeight.w800,
                  ),
                ),
                const SizedBox(height: 5),
                Row(
                  children: [
                    Icon(
                      Icons.visibility_outlined,
                      size: 14,
                      color: tokens.colorBase.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      item!.views == null ? '浏览量读取中' : '${item!.views} 次查看',
                      style: TextStyle(
                        color: tokens.colorBase.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      variant == 'slim' ? '纤细模型' : '经典模型',
                      style: TextStyle(
                        color: tokens.colorBase.withValues(alpha: 0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: png == null
                      ? const Center(child: CircularProgressIndicator())
                      : Skin3DViewer(
                          skinPng: png!,
                          slim: variant == 'slim',
                        ),
                ),
                const SizedBox(height: 10),
                NavRectButton(
                  isSelected: false,
                  icon: Icons.download_outlined,
                  text: '下载 PNG',
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  onTap: png == null ? () {} : onDownload,
                ),
                if (msaAccounts.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  DropdownButtonWidget(
                    width: double.infinity,
                    dropdownMinWidth: 258,
                    colorScheme: Theme.of(context).colorScheme,
                    prefix: '应用到：',
                    selectedValue: selectedMsaAccountId,
                    items: [
                      for (final account in msaAccounts)
                        DropdownItem(
                          display: account.username,
                          value: account.id,
                        ),
                    ],
                    onChanged: onAccountChanged,
                  ),
                ],
                const SizedBox(height: 8),
                NavRectButton(
                  isSelected: msaAccounts.isNotEmpty,
                  icon: applying ? Icons.hourglass_top : Icons.check,
                  text: msaAccounts.isNotEmpty
                      ? applying
                          ? '应用中…'
                          : '应用到所选正版账号'
                      : '仅正版账号可应用',
                  selectedBackgroundColor: tokens.colorBrand,
                  selectedColor: tokens.colorOnBrand,
                  onTap: msaAccounts.isNotEmpty && !applying && png != null
                      ? onApply
                      : () {},
                ),
              ],
            ),
    );
  }
}
