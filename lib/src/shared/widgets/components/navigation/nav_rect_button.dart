import 'dart:async';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_tooltip.dart';
import 'package:flutter/material.dart';

/// 导航矩形按钮组件
///
/// 一个功能丰富的自定义按钮组件，支持多种交互状态和视觉效果。
/// 适用于导航栏、工具栏等场景。
///
/// 主要特性：
/// - 支持图标、图片和文本显示
/// - 多种状态：默认、悬停、选中
/// - 丰富的交互：点击、长按、鼠标移入移出
/// - 完全可自定义的颜色和样式
/// - 内置动画效果和工具提示
///
/// 使用示例：
/// ```dart
/// NavRectButton(
///   icon: Icons.home,
///   text: '首页',
///   label: '返回首页',
///   isSelected: false,
///   onTap: () => print('点击首页'),
///   onLongPress: () => print('长按首页'),
///   onMouseEnter: () => print('鼠标移入'),
///   onMouseExit: () => print('鼠标移出'),
/// )
/// ```
class NavRectButton extends StatefulWidget {
  /// 图标数据
  ///
  /// 显示在按钮左侧的图标，与 [image] 互斥，优先显示 [icon]
  final IconData? icon;

  /// 图片资源
  ///
  /// 显示在按钮左侧的图片，当 [icon] 为 null 时生效
  final ImageProvider? image;

  /// 按钮文本
  ///
  /// 显示在图标/图片右侧的文本内容
  final String? text;

  /// 按钮标签
  ///
  /// 用于显示工具提示(tooltip)的文本，当鼠标悬停时显示
  final String? label;

  /// 是否选中状态
  ///
  /// 控制按钮的选中状态，影响颜色和样式显示
  final bool isSelected;

  /// 点击回调
  ///
  /// 当用户点击按钮时触发的回调函数
  final VoidCallback onTap;

  /// 长按回调
  ///
  /// 当用户长按按钮超过500毫秒时触发的回调函数
  final VoidCallback? onLongPress;

  /// 鼠标移入回调
  ///
  /// 当鼠标指针进入按钮区域时触发的回调函数
  final VoidCallback? onMouseEnter;

  /// 鼠标移出回调
  ///
  /// 当鼠标指针离开按钮区域时触发的回调函数
  final VoidCallback? onMouseExit;

  /// 按钮宽度
  ///
  /// 指定按钮的固定宽度，为 null 时自适应内容宽度
  final double? width;

  /// 内边距
  ///
  /// 按钮内容的内边距，默认为水平14像素
  final EdgeInsetsGeometry? padding;

  /// 默认文本和图标颜色
  ///
  /// 按钮在默认状态下的文本和图标颜色
  final Color? defaultColor;

  /// 悬停时的背景颜色
  ///
  /// 鼠标悬停时的按钮背景颜色
  final Color? hoverColor;

  /// 悬停时的文本和图标颜色
  ///
  /// 鼠标悬停时的文本和图标颜色
  final Color? hoverTextColor;

  /// 选中状态的文本和图标颜色
  ///
  /// 按钮处于选中状态时的文本和图标颜色
  final Color? selectedColor;

  /// 默认背景色
  ///
  /// 按钮在默认状态下的背景颜色，默认为透明
  final Color? defaultBackgroundColor;

  /// 选中状态的背景色
  ///
  /// 按钮处于选中状态时的背景颜色
  final Color? selectedBackgroundColor;

  /// 默认边框颜色
  ///
  /// 按钮在默认状态下的边框颜色，默认为透明
  final Color? defaultBorderColor;

  /// 选中状态的边框颜色
  ///
  /// 按钮处于选中状态时的边框颜色
  final Color? selectedBorderColor;

  /// 创建一个导航矩形按钮
  ///
  /// 必需参数：
  /// - [isSelected] 按钮的选中状态
  /// - [onTap] 点击按钮时的回调函数
  ///
  /// 可选参数：
  /// - [icon] 显示在按钮左侧的图标，与 [image] 互斥，优先显示 [icon]
  /// - [image] 显示在按钮左侧的图片，当 [icon] 为 null 时生效
  /// - [text] 显示在图标/图片右侧的文本内容
  /// - [label] 鼠标悬停时显示的工具提示文本
  /// - [onLongPress] 长按按钮时的回调函数
  /// - [onMouseEnter] 鼠标进入按钮区域时的回调函数
  /// - [onMouseExit] 鼠标离开按钮区域时的回调函数
  /// - [width] 按钮的固定宽度，为 null 时自适应内容
  /// - [padding] 按钮内容的内边距
  ///
  /// 颜色自定义参数（未指定时使用主题默认颜色）：
  /// - [defaultColor] 默认状态下的文本和图标颜色
  /// - [hoverColor] 鼠标悬停时的背景颜色
  /// - [hoverTextColor] 鼠标悬停时的文本和图标颜色
  /// - [selectedColor] 选中状态的文本和图标颜色
  /// - [defaultBackgroundColor] 默认状态的背景颜色
  /// - [selectedBackgroundColor] 选中状态的背景颜色
  /// - [defaultBorderColor] 默认状态的边框颜色
  /// - [selectedBorderColor] 选中状态的边框颜色
  const NavRectButton({
    super.key,
    this.icon,
    this.image,
    this.text,
    this.label,
    required this.isSelected,
    required this.onTap,
    this.onLongPress,
    this.onMouseEnter,
    this.onMouseExit,
    this.width,
    this.padding,
    this.defaultColor,
    this.hoverColor,
    this.hoverTextColor,
    this.selectedColor,
    this.defaultBackgroundColor = Colors.transparent,
    this.selectedBackgroundColor,
    this.defaultBorderColor,
    this.selectedBorderColor,
  });

  @override
  State<NavRectButton> createState() => _NavRectButtonState();
}

/// NavRectButton 的状态管理类
///
/// 负责处理按钮的交互状态、动画效果和事件响应
class _NavRectButtonState extends State<NavRectButton>
    with TickerProviderStateMixin {
  /// 鼠标悬停状态
  bool _isHovered = false;

  /// 缩放动画控制器
  late AnimationController _animationController;

  /// 缩放动画
  late Animation<double> _scaleAnimation;

  /// 长按计时器
  Timer? _longPressTimer;

  /// 是否已触发长按
  bool _isLongPressed = false;

  /// 按下时间记录
  DateTime? _tapDownTime;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.95).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _longPressTimer?.cancel();
    _animationController.dispose();
    super.dispose();
  }

  /// 处理按下事件
  ///
  /// 启动缩放动画和长按计时器
  void _handleTapDown(TapDownDetails details) {
    _animationController.forward();
    _isLongPressed = false;
    _tapDownTime = DateTime.now();

    // 启动长按计时器
    if (widget.onLongPress != null) {
      _longPressTimer = Timer(const Duration(milliseconds: 100), () {
        _isLongPressed = true;
        widget.onLongPress!();
      });
    }
  }

  /// 处理抬起事件
  ///
  /// 取消长按计时器，执行动画恢复，触发点击回调
  void _handleTapUp(TapUpDetails details) {
    _longPressTimer?.cancel();

    // 计算已经过去的时间
    final elapsedTime = _tapDownTime != null
        ? DateTime.now().difference(_tapDownTime!).inMilliseconds
        : 0;

    // 确保动画至少播放0.1秒（100毫秒）
    const minAnimationTime = 100;
    final remainingTime = minAnimationTime - elapsedTime;

    if (remainingTime > 0) {
      // 如果还没有达到最小动画时间，延迟执行reverse
      Timer(Duration(milliseconds: remainingTime), () {
        _animationController.reverse();
      });
    } else {
      // 已经达到最小时间，立即执行reverse
      _animationController.reverse();
    }

    // 如果不是长按，则执行点击回调
    if (!_isLongPressed) {
      widget.onTap();
    }
  }

  /// 处理取消事件
  ///
  /// 当手势被取消时（如手指滑出按钮区域），恢复动画状态
  void _handleTapCancel() {
    _longPressTimer?.cancel();

    // 计算已经过去的时间
    final elapsedTime = _tapDownTime != null
        ? DateTime.now().difference(_tapDownTime!).inMilliseconds
        : 0;

    // 确保动画至少播放0.1秒（100毫秒）
    const minAnimationTime = 100;
    final remainingTime = minAnimationTime - elapsedTime;

    if (remainingTime > 0) {
      // 如果还没有达到最小动画时间，延迟执行reverse
      Timer(Duration(milliseconds: remainingTime), () {
        _animationController.reverse();
      });
    } else {
      // 已经达到最小时间，立即执行reverse
      _animationController.reverse();
    }
  }

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final tokens = Theme.of(context).extension<AppThemeTokens>() ??
        AppThemeTokens.fallback(colorScheme);

    // 定义默认颜色
    final defaultTextColor = widget.defaultColor ?? tokens.colorBase;
    final hoverTextColor = widget.hoverTextColor ?? tokens.colorContrast;
    final selectedTextColor =
        widget.selectedColor ?? tokens.colorButtonTextSelected;
    final defaultBgColor = widget.defaultBackgroundColor ?? Colors.transparent;
    final hoverBgColor = widget.hoverColor ?? tokens.colorButtonBg;
    final selectedBgColor =
        widget.selectedBackgroundColor ?? tokens.colorButtonBgSelected;
    final defaultBorderColor = widget.defaultBorderColor ?? Colors.transparent;
    final selectedBorderColor = widget.selectedBorderColor ?? tokens.colorBrand;

    // 根据状态确定当前颜色
    Color currentTextColor;
    Color currentBgColor;
    Color currentBorderColor;

    if (widget.isSelected) {
      currentTextColor = selectedTextColor;
      currentBgColor = selectedBgColor;
      currentBorderColor = selectedBorderColor;
    } else if (_isHovered) {
      currentTextColor = hoverTextColor;
      currentBgColor = hoverBgColor;
      currentBorderColor = defaultBorderColor;
    } else {
      currentTextColor = defaultTextColor;
      currentBgColor = defaultBgColor;
      currentBorderColor = defaultBorderColor;
    }

    Widget content = MouseRegion(
      cursor: SystemMouseCursors.click, // 添加手型光标
      onEnter: (_) {
        setState(() => _isHovered = true);
        widget.onMouseEnter?.call();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        widget.onMouseExit?.call();
      },
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: AnimatedBuilder(
          animation: _animationController,
          builder: (context, child) {
            return Transform.scale(
              scale: _scaleAnimation.value,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                curve: Curves.easeInOut,
                width: widget.width,
                padding: widget.padding ??
                    const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                constraints: widget.width != null
                    ? BoxConstraints(maxWidth: widget.width!)
                    : null,
                clipBehavior: Clip.none,
                decoration: BoxDecoration(
                  color: currentBgColor,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: currentBorderColor, width: 1),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (widget.icon != null)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 100),
                        child: Icon(
                          widget.icon,
                          key: ValueKey(
                            'icon_${widget.icon?.codePoint}_${widget.text ?? widget.label ?? ''}_${currentTextColor.toString()}',
                          ),
                          size: 20,
                          color: currentTextColor,
                        ),
                      ),
                    if (widget.image != null)
                      AnimatedSwitcher(
                        duration: const Duration(milliseconds: 100),
                        child: Image(
                          key: ValueKey(
                            'image_${widget.image.hashCode}_${widget.text ?? widget.label ?? ''}_${currentTextColor.toString()}',
                          ),
                          image: widget.image!,
                          width: 20,
                          height: 20,
                          color: currentTextColor,
                        ),
                      ),
                    if (widget.text != null) ...[
                      if (widget.icon != null || widget.image != null)
                        const SizedBox(width: 8),
                      _buttonLabel(context, currentTextColor),
                    ],
                  ],
                ),
              ),
            );
          },
        ),
      ),
    );

    // 只有在有label时才显示tooltip
    return widget.label != null && widget.label!.isNotEmpty
        ? CustomTooltip(message: widget.label ?? '', child: content)
        : content;
  }

  Widget _buttonLabel(BuildContext context, Color currentTextColor) {
    final label = AnimatedDefaultTextStyle(
      duration: const Duration(milliseconds: 100),
      curve: Curves.easeInOut,
      style: DefaultTextStyle.of(context).style.copyWith(
        fontSize: 16,
        fontWeight: FontWeight.w700,
        height: 1.25,
        color: currentTextColor,
      ),
      child: Text(
        widget.text!,
        maxLines: 1,
        softWrap: false,
        overflow: TextOverflow.ellipsis,
      ),
    );
    if (widget.width == null) return label;
    return Flexible(child: label);
  }
}
