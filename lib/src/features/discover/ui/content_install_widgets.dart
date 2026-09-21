import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:flutter/material.dart';

class ContentInstallModalHeader extends StatelessWidget {
  const ContentInstallModalHeader({
    super.key,
    required this.tokens,
    this.projectTitle,
    this.projectIconUrl,
    required this.onClose,
  });

  final AppThemeTokens tokens;
  final String? projectTitle;
  final String? projectIconUrl;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 20, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  '安装项目',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              CustomButton(
                icon: Icons.close,
                size: ButtonSize.medium,
                onTap: onClose,
              ),
            ],
          ),
        ),
        if (projectTitle != null) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
            child: Row(
              children: [
                if (projectIconUrl != null)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.network(
                      projectIconUrl!,
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, __, ___) => const SizedBox(
                        width: 48,
                        height: 48,
                      ),
                    ),
                  )
                else
                  Container(
                    width: 48,
                    height: 48,
                    decoration: BoxDecoration(
                      color: tokens.colorButtonBg,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Icon(
                      Icons.extension_outlined,
                      color: tokens.colorBase,
                    ),
                  ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    projectTitle!,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                      color: tokens.colorContrast,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class ContentInstallPillChoice extends StatelessWidget {
  const ContentInstallPillChoice({
    super.key,
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
