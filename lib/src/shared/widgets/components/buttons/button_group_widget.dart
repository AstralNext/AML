import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

/// 按钮组选项数据模型
///
/// 用于存储按钮组中每个选项的显示文本和对应的值
class ButtonGroupItem {
  /// 显示的文本内容
  final String text;

  /// 对应的实际值
  final String value;

  /// 图标（可选）
  final IconData? icon;

  /// 创建按钮组选项
  ///
  /// [text] 显示的文本内容
  /// [value] 对应的实际值
  /// [icon] 可选的图标
  const ButtonGroupItem({
    required this.text,
    required this.value,
    this.icon,
  });
}

/// 按钮组单选切换组件
///
/// 一个水平排列的按钮组，支持单选切换功能。
/// 适用于选项卡、过滤器、模式切换等场景。
///
/// 主要特性：
/// - 支持多个选项的单选切换
/// - 可自定义颜色主题
/// - 支持图标和文本显示
/// - 响应式布局适配
///
/// 使用示例：
/// ```dart
/// ButtonGroupWidget(
///   items: [
///     ButtonGroupItem(text: '全部', value: 'all'),
///     ButtonGroupItem(text: '进行中', value: 'active', icon: Icons.play_arrow),
///     ButtonGroupItem(text: '已完成', value: 'completed', icon: Icons.check),
///   ],
///   selectedValue: 'all',
///   onChanged: (value) => print('选中: $value'),
/// )
/// ```
class ButtonGroupWidget extends StatefulWidget {
  /// 按钮组选项列表
  final List<ButtonGroupItem> items;

  /// 当前选中的值
  final String selectedValue;

  /// 值改变时的回调函数
  final ValueChanged<String> onChanged;

  /// 颜色主题
  final ColorScheme? colorScheme;

  /// 按钮组高度
  final double height;

  /// 按钮间距
  final double spacing;

  /// 圆角半径
  final double borderRadius;

  /// 选中时显示的图标（可选，默认为对号）
  final IconData? selectedIcon;

  /// 按钮宽度是否随内容变化（默认为false，使用自适应布局）
  final bool fitContent;

  /// 创建按钮组单选切换组件
  ///
  /// [items] 按钮组选项列表，不能为空
  /// [selectedValue] 当前选中的值
  /// [onChanged] 值改变时的回调函数
  /// [colorScheme] 可选的颜色主题，默认使用当前主题
  /// [height] 按钮组高度，默认为40
  /// [spacing] 按钮间距，默认为4
  /// [borderRadius] 圆角半径，默认为8
  /// [selectedIcon] 选中时显示的图标，默认为对号
  /// [fitContent] 按钮宽度是否随内容变化，默认为false
  const ButtonGroupWidget({
    super.key,
    required this.items,
    required this.selectedValue,
    required this.onChanged,
    this.colorScheme,
    this.height = 37,
    this.spacing = 10,
    this.borderRadius = 12,
    this.selectedIcon = Icons.check,
    this.fitContent = false,
  }) : assert(items.length > 0, '按钮组选项不能为空');

  @override
  State<ButtonGroupWidget> createState() => _ButtonGroupWidgetState();
}

class _ButtonGroupWidgetState extends State<ButtonGroupWidget> {
  /// 处理按钮点击
  void _handleTap(String value) {
    if (value != widget.selectedValue) {
      widget.onChanged(value);
    }
  }

  /// 构建单个按钮
  Widget _buildButton(
      ButtonGroupItem item, bool isSelected, ColorScheme colorScheme) {
    final tokens = AppThemeTokens.fallback(colorScheme);
    final buttonChild = Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: isSelected
            ? tokens.colorButtonBgSelected.withValues(alpha: 0.22)
            : tokens.colorButtonBg.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(widget.borderRadius),
        border: Border.all(
          color: isSelected
              ? tokens.colorContrast.withValues(alpha: 0.28)
              : Colors.transparent,
          width: 1,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () => _handleTap(item.value),
          borderRadius: BorderRadius.circular(widget.borderRadius),
          splashColor: tokens.colorBrand.withValues(alpha: 0.1),
          highlightColor: tokens.colorBrand.withValues(alpha: 0.05),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              mainAxisSize: MainAxisSize.min,
              children: [
                if (item.icon != null) ...[
                  Icon(
                    item.icon,
                    size: 16,
                    color: isSelected
                        ? tokens.colorContrast
                        : tokens.colorBase.withValues(alpha: 0.8),
                  ),
                  const SizedBox(width: 6),
                ],
                if (isSelected && widget.selectedIcon != null) ...[
                  Icon(
                    widget.selectedIcon,
                    size: 16,
                    color: tokens.colorContrast,
                  ),
                  const SizedBox(width: 4),
                ],
                Flexible(
                  child: Text(
                    item.text,
                    style: TextStyle(
                      color: isSelected
                          ? tokens.colorContrast
                          : tokens.colorBase.withValues(alpha: 0.8),
                      fontSize: 14,
                      fontWeight:
                          isSelected ? FontWeight.w600 : FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );

    return widget.fitContent ? buttonChild : Expanded(child: buttonChild);
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = widget.colorScheme ?? Theme.of(context).colorScheme;

    return Row(
      children: widget.items
          .asMap()
          .entries
          .map((entry) {
            final index = entry.key;
            final item = entry.value;
            final isSelected = item.value == widget.selectedValue;

            return [
              _buildButton(item, isSelected, colorScheme),
              if (index < widget.items.length - 1)
                SizedBox(width: widget.spacing),
            ];
          })
          .expand((widgets) => widgets)
          .toList(),
    );
  }
}
