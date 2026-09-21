import 'package:aml/src/features/discover/ui/content_install_models.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:flutter/material.dart';

class ContentInstallExistingSection extends StatelessWidget {
  const ContentInstallExistingSection({
    super.key,
    required this.tokens,
    required this.colorScheme,
    required this.loading,
    required this.instances,
    required this.searchController,
    required this.hideUnavailable,
    required this.onToggleHideUnavailable,
    required this.onInstall,
  });

  final AppThemeTokens tokens;
  final ColorScheme colorScheme;
  final bool loading;
  final List<ContentInstallInstanceRow> instances;
  final TextEditingController searchController;
  final bool hideUnavailable;
  final VoidCallback onToggleHideUnavailable;
  final void Function(ContentInstallInstanceRow row) onInstall;

  int _instanceScore(ContentInstallInstanceRow row) {
    if (!row.compatible) return 2;
    if (row.installed) return 1;
    return 0;
  }

  List<ContentInstallInstanceRow> get _filteredInstances {
    var list = instances;
    if (hideUnavailable) {
      list = list.where((i) => i.compatible && !i.installed).toList();
    }
    final query = searchController.text.trim().toLowerCase();
    if (query.isNotEmpty) {
      list = list.where((i) => i.name.toLowerCase().contains(query)).toList();
    }
    return list.toList()
      ..sort((a, b) {
        final diff = _instanceScore(a) - _instanceScore(b);
        if (diff != 0) return diff;
        return a.name.compareTo(b.name);
      });
  }

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: tokens.colorBg.withValues(alpha: 0.35),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 8),
            child: Row(
              children: [
                Expanded(
                  child: InputBarWidget(
                    colorScheme: colorScheme,
                    size: InputBarSize.medium,
                    hintText: '搜索实例',
                    controller: searchController,
                    prefixIcon: Icon(
                      Icons.search,
                      size: 18,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                CustomButton(
                  icon: hideUnavailable ? Icons.visibility_off : Icons.visibility,
                  size: ButtonSize.medium,
                  onTap: onToggleHideUnavailable,
                  label: hideUnavailable ? '显示不可用实例' : '隐藏不可用实例',
                ),
              ],
            ),
          ),
          Expanded(
            child: loading
                ? const Center(child: CircularProgressIndicator(strokeWidth: 2))
                : _filteredInstances.isEmpty
                    ? Center(
                        child: Text(
                          '没有可用的实例',
                          style: TextStyle(
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
                        itemCount: _filteredInstances.length,
                        itemBuilder: (context, index) {
                          final row = _filteredInstances[index];
                          return _InstanceRow(
                            tokens: tokens,
                            row: row,
                            onInstall: () => onInstall(row),
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _InstanceRow extends StatelessWidget {
  const _InstanceRow({
    required this.tokens,
    required this.row,
    required this.onInstall,
  });

  final AppThemeTokens tokens;
  final ContentInstallInstanceRow row;
  final VoidCallback onInstall;

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: row.installed ? 0.6 : 1,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: row.installed ? null : onInstall,
          borderRadius: BorderRadius.circular(8),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(
              children: [
                InstanceIcon(
                  instanceId: row.id,
                  iconPath: row.iconPath,
                  size: 32,
                  borderRadius: 8,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    row.name,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: tokens.colorContrast,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                if (row.installed)
                  _StatusButton(
                    tokens: tokens,
                    label: '已安装',
                    icon: Icons.check,
                    enabled: false,
                  )
                else
                  _StatusButton(
                    tokens: tokens,
                    label: '安装',
                    icon: row.compatible ? null : Icons.warning_amber_rounded,
                    warning: !row.compatible,
                    onTap: onInstall,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _StatusButton extends StatelessWidget {
  const _StatusButton({
    required this.tokens,
    required this.label,
    this.icon,
    this.warning = false,
    this.enabled = true,
    this.onTap,
  });

  final AppThemeTokens tokens;
  final String label;
  final IconData? icon;
  final bool warning;
  final bool enabled;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final borderColor = warning
        ? const Color(0xFFF97316)
        : tokens.colorSecondary.withValues(alpha: 0.35);
    final textColor = enabled
        ? (warning ? const Color(0xFFF97316) : tokens.colorContrast)
        : tokens.colorBase.withValues(alpha: 0.55);

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: enabled ? onTap : null,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: borderColor),
            color: tokens.colorButtonBg.withValues(alpha: enabled ? 0.55 : 0.25),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: textColor),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: textColor,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
