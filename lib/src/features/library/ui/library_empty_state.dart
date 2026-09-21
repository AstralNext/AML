import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';

class LibraryEmptyState extends StatelessWidget {
  const LibraryEmptyState({
    super.key,
    required this.create,
    this.message = '还没有实例',
    this.clearSearch = false,
    this.onClearSearch,
    this.onCreate,
  });

  final bool create;
  final String message;
  final bool clearSearch;
  final VoidCallback? onClearSearch;
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.inventory_2_outlined,
            size: 72,
            color: tokens.colorBase.withValues(alpha: 0.35),
          ),
          const SizedBox(height: 16),
          Text(
            message,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          if (clearSearch) ...[
            const SizedBox(height: 16),
            NavRectButton(
              text: '清除搜索',
              icon: Icons.clear,
              isSelected: false,
              defaultBackgroundColor: tokens.colorButtonBg,
              defaultColor: tokens.colorContrast,
              hoverColor: tokens.colorButtonBgSelected,
              hoverTextColor: tokens.colorButtonTextSelected,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              onTap: () => onClearSearch?.call(),
            ),
          ] else if (create) ...[
            const SizedBox(height: 8),
            Text(
              '创建一个实例，或先去发现整合包。',
              style: TextStyle(
                fontSize: 13,
                color: tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              alignment: WrapAlignment.center,
              children: [
                NavRectButton(
                  text: '创建实例',
                  icon: Icons.add,
                  isSelected: true,
                  selectedBackgroundColor: tokens.colorBrand,
                  selectedColor: tokens.colorOnBrand,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  onTap: () => onCreate?.call(),
                ),
                NavRectButton(
                  text: '发现整合包',
                  icon: Icons.explore_outlined,
                  isSelected: false,
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  padding:
                      const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                  onTap: () => getIt<NavigationState>().browseModpacks(),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }
}
