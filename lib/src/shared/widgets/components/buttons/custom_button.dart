import 'dart:async';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_tooltip.dart';
import 'package:flutter/material.dart';

enum ButtonSize {
  large, // 48x48
  medium, // 36x36
  small, // 24x24
}

class CustomButton extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  final Color? backgroundColor;
  final Color? hoverBackgroundColor;
  final Color? hoverIconColor;
  final Color? iconColor;
  final String? label;
  final ButtonSize size; // 新增尺寸参数
  final VoidCallback? onMouseEnter; // 鼠标进入回调
  final VoidCallback? onMouseExit; // 鼠标离开回调

  const CustomButton({
    super.key,
    required this.icon,
    required this.onTap,
    this.backgroundColor,
    this.hoverBackgroundColor,
    this.hoverIconColor,
    this.iconColor,
    this.label,
    this.size = ButtonSize.large, // 默认大尺寸
    this.onMouseEnter,
    this.onMouseExit,
  });

  @override
  State<CustomButton> createState() => _CustomButtonState();
}

class _CustomButtonState extends State<CustomButton>
    with TickerProviderStateMixin {
  bool _isHovered = false;
  late AnimationController _animationController;
  late Animation<double> _scaleAnimation;
  late AnimationController _hoverAnimationController;
  late Animation<double> _backgroundScaleAnimation;
  late Animation<Color?> _backgroundColorAnimation;
  late Animation<Color?> _iconColorAnimation;

  /// 按下时间记录
  DateTime? _tapDownTime;
  Timer? _reverseTimer;

  // 根据尺寸获取对应的数值
  double get _buttonSize {
    switch (widget.size) {
      case ButtonSize.large:
        return 48;
      case ButtonSize.medium:
        return 36;
      case ButtonSize.small:
        return 24;
    }
  }

  double get _iconSize {
    switch (widget.size) {
      case ButtonSize.large:
        return 24;
      case ButtonSize.medium:
        return 18;
      case ButtonSize.small:
        return 12;
    }
  }

  double get _padding {
    switch (widget.size) {
      case ButtonSize.large:
        return 8.0;
      case ButtonSize.medium:
        return 6.0;
      case ButtonSize.small:
        return 4.0;
    }
  }

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _scaleAnimation = Tween<double>(begin: 1.0, end: 0.9).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
    _hoverAnimationController = AnimationController(
      duration: const Duration(milliseconds: 100),
      vsync: this,
    );
    _backgroundScaleAnimation = Tween<double>(begin: 0.9, end: 1).animate(
      CurvedAnimation(
        parent: _hoverAnimationController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final tokens = context.tokens;

    // 初始化颜色动画
    _backgroundColorAnimation = ColorTween(
      begin: widget.backgroundColor ?? tokens.colorButtonBg.withAlpha(0),
      end: widget.hoverBackgroundColor ?? tokens.colorButtonBg,
    ).animate(
      CurvedAnimation(
        parent: _hoverAnimationController,
        curve: Curves.easeInOut,
      ),
    );

    _iconColorAnimation = ColorTween(
      begin: widget.iconColor ?? tokens.colorBase,
      end: widget.hoverIconColor ?? tokens.colorContrast,
    ).animate(
      CurvedAnimation(
        parent: _hoverAnimationController,
        curve: Curves.easeInOut,
      ),
    );
  }

  @override
  void dispose() {
    _reverseTimer?.cancel();
    _animationController.dispose();
    _hoverAnimationController.dispose();
    super.dispose();
  }

  void _scheduleTapReverse() {
    final elapsedTime = _tapDownTime != null
        ? DateTime.now().difference(_tapDownTime!).inMilliseconds
        : 0;
    const minAnimationTime = 100;
    final remainingTime = minAnimationTime - elapsedTime;

    _reverseTimer?.cancel();
    if (!mounted) return;

    if (remainingTime > 0) {
      _reverseTimer = Timer(Duration(milliseconds: remainingTime), () {
        if (!mounted) return;
        _animationController.reverse();
      });
    } else {
      _animationController.reverse();
    }
  }

  void _handleTapDown(TapDownDetails details) {
    _animationController.forward();
    _tapDownTime = DateTime.now();
  }

  void _handleTapUp(TapUpDetails details) {
    _scheduleTapReverse();
    widget.onTap();
  }

  void _handleTapCancel() {
    _scheduleTapReverse();
  }

  @override
  Widget build(BuildContext context) {
    Widget button = MouseRegion(
      onEnter: (_) {
        setState(() => _isHovered = true);
        _hoverAnimationController.forward();
        widget.onMouseEnter?.call();
      },
      onExit: (_) {
        setState(() => _isHovered = false);
        _hoverAnimationController.reverse();
        widget.onMouseExit?.call();
      },
      cursor: _isHovered ? SystemMouseCursors.click : MouseCursor.defer,
      child: GestureDetector(
        onTapDown: _handleTapDown,
        onTapUp: _handleTapUp,
        onTapCancel: _handleTapCancel,
        child: Stack(
          alignment: Alignment.center,
          children: [
            // 背景层 - 应用缩放和颜色渐变动画
            AnimatedBuilder(
              animation: _animationController,
              builder: (context, child) {
                return AnimatedBuilder(
                  animation: _hoverAnimationController,
                  builder: (context, child) {
                    return Transform.scale(
                      scale: _animationController.status ==
                                  AnimationStatus.forward ||
                              _animationController.status ==
                                  AnimationStatus.completed
                          ? _scaleAnimation.value // 按下状态优先
                          : (_isHovered
                              ? _backgroundScaleAnimation.value
                              : 1.0),
                      child: Container(
                        width: _buttonSize,
                        height: _buttonSize,
                        decoration: BoxDecoration(
                          color: _backgroundColorAnimation.value,
                          borderRadius: BorderRadius.circular(_buttonSize / 2),
                        ),
                      ),
                    );
                  },
                );
              },
            ),
            // 内容层 - 应用图标颜色渐变动画
            AnimatedBuilder(
              animation: _hoverAnimationController,
              builder: (context, child) {
                return Padding(
                  padding: EdgeInsets.all(_padding),
                  child: Icon(
                    widget.icon,
                    size: _iconSize,
                    color: _iconColorAnimation.value,
                  ),
                );
              },
            ),
          ],
        ),
      ),
    );

    // 如果 label 不为空，使用 Tooltip + Semantics 包裹
    if (widget.label != null && widget.label!.isNotEmpty) {
      return Semantics(
        button: true,
        label: widget.label,
        child: CustomTooltip(message: widget.label!, child: button),
      );
    } else {
      return Semantics(button: true, child: button);
    }
  }
}
