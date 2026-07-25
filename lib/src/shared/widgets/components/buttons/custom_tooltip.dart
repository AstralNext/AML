// 自定义 Tooltip 组件
import 'package:flutter/material.dart';
import 'dart:async';

// Tooltip 位置枚举
enum TooltipPosition { top, bottom, left, right }

class CustomTooltip extends StatefulWidget {
  final Widget child;
  final String message;
  final Color backgroundColor;
  final Color textColor;
  final TooltipPosition position;

  const CustomTooltip({
    super.key,
    required this.child,
    required this.message,
    this.backgroundColor = Colors.black,
    this.textColor = Colors.white,
    this.position = TooltipPosition.right,
  });

  @override
  State<CustomTooltip> createState() => _CustomTooltipState();
}

class _CustomTooltipState extends State<CustomTooltip>
    with SingleTickerProviderStateMixin {
  final LayerLink _layerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  Timer? _showTimer;
  Timer? _removeTimer;
  late AnimationController _animationController;
  late Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _animationController = AnimationController(
      duration: const Duration(milliseconds: 200),
      vsync: this,
    );
    _fadeAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _animationController, curve: Curves.easeInOut),
    );
  }

  @override
  void dispose() {
    _showTimer?.cancel();
    _removeTimer?.cancel();
    _animationController.dispose();
    _overlayEntry?.remove();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) {
        _showTooltip();
      },
      onExit: (_) {
        _removeTooltip();
      },
      child: CompositedTransformTarget(link: _layerLink, child: widget.child),
    );
  }

  void _showTooltip() {
    _removeTimer?.cancel();
    _showTimer?.cancel();

    // 延迟 0.3 秒后显示
    _showTimer = Timer(const Duration(milliseconds: 300), () {
      if (_overlayEntry == null) {
        _overlayEntry = _createOverlayEntry();
        Overlay.of(context).insert(_overlayEntry!);
        _animationController.forward();
      }
    });
  }

  void _removeTooltip() {
    _showTimer?.cancel();
    _removeTimer?.cancel();

    if (_overlayEntry != null) {
      // 渐隐动画
      _animationController.reverse().then((_) {
        _overlayEntry?.remove();
        _overlayEntry = null;
      });
    }
  }

  OverlayEntry _createOverlayEntry() {
    RenderBox renderBox = context.findRenderObject() as RenderBox;
    var size = renderBox.size;
    var offset = renderBox.localToGlobal(Offset.zero);

    // 计算文本尺寸
    final textPainter = TextPainter(
      text: TextSpan(
        text: widget.message,
        style: TextStyle(
          color: widget.textColor,
          fontSize: 16,
          fontWeight: FontWeight.w700,
        ),
      ),
      textDirection: TextDirection.ltr,
    );
    textPainter.layout();
    final tooltipWidth = textPainter.size.width + 10; // 加上padding
    final tooltipHeight =
        textPainter.size.height + 10 + 8; // 文本高度 + padding + 三角形高度

    // 根据位置计算偏移量和布局
    Offset tooltipOffset;
    Widget tooltipContent;

    switch (widget.position) {
      case TooltipPosition.top:
        tooltipOffset = Offset((size.width - tooltipWidth) / 2, -tooltipHeight);
        tooltipContent = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              elevation: 4.0,
              color: widget.backgroundColor,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            CustomPaint(
              size: const Size(16, 8),
              painter: TrianglePainter(
                color: widget.backgroundColor,
                direction: TooltipPosition.top,
              ),
            ),
          ],
        );
        break;
      case TooltipPosition.bottom:
        tooltipOffset = Offset((size.width - tooltipWidth) / 2, size.height);
        tooltipContent = Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size(16, 8),
              painter: TrianglePainter(
                color: widget.backgroundColor,
                direction: TooltipPosition.bottom,
              ),
            ),
            Material(
              elevation: 4.0,
              color: widget.backgroundColor,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        );
        break;
      case TooltipPosition.left:
        tooltipOffset = Offset(
          -tooltipWidth - 16,
          (size.height - tooltipHeight) / 2,
        );
        tooltipContent = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Material(
              elevation: 4.0,
              color: widget.backgroundColor,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
            CustomPaint(
              size: const Size(8, 16),
              painter: TrianglePainter(
                color: widget.backgroundColor,
                direction: TooltipPosition.left,
              ),
            ),
          ],
        );
        break;
      case TooltipPosition.right:
        tooltipOffset = Offset(size.width + 4, (size.height / 2) - 18);
        tooltipContent = Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            CustomPaint(
              size: const Size(8, 16),
              painter: TrianglePainter(
                color: widget.backgroundColor,
                direction: TooltipPosition.right,
              ),
            ),
            Material(
              elevation: 4.0,
              color: widget.backgroundColor,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(5, 5, 5, 5),
                child: Text(
                  widget.message,
                  style: TextStyle(
                    color: widget.textColor,
                    fontSize: 16,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ),
          ],
        );
        break;
    }

    return OverlayEntry(
      builder: (context) => Positioned(
        left: offset.dx,
        top: offset.dy,
        child: CompositedTransformFollower(
          link: _layerLink,
          showWhenUnlinked: false,
          offset: tooltipOffset,
          child: MouseRegion(
            onEnter: (_) {
              _removeTimer?.cancel();
              _showTimer?.cancel();
            },
            onExit: (_) {
              _removeTooltip();
            },
            child: FadeTransition(
              opacity: _fadeAnimation,
              child: tooltipContent,
            ),
          ),
        ),
      ),
    );
  }
}

// 三角形绘制器
class TrianglePainter extends CustomPainter {
  final Color color;
  final TooltipPosition direction;

  TrianglePainter({required this.color, required this.direction});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill;

    final path = Path();

    switch (direction) {
      case TooltipPosition.top:
        // 向下的三角形
        path.moveTo(size.width / 2 - 8, 0); // 左上
        path.lineTo(size.width / 2, size.height); // 底部顶点
        path.lineTo(size.width / 2 + 8, 0); // 右上
        break;
      case TooltipPosition.bottom:
        // 向上的三角形
        path.moveTo(size.width / 2 - 8, size.height); // 左下
        path.lineTo(size.width / 2, 0); // 顶部顶点
        path.lineTo(size.width / 2 + 8, size.height); // 右下
        break;
      case TooltipPosition.left:
        // 向右的三角形
        path.moveTo(0, size.height / 2 - 8); // 左上
        path.lineTo(size.width, size.height / 2); // 右侧顶点
        path.lineTo(0, size.height / 2 + 8); // 左下
        break;
      case TooltipPosition.right:
        // 向左的三角形
        path.moveTo(size.width, size.height / 2 - 8); // 右上
        path.lineTo(0, size.height / 2); // 左侧顶点
        path.lineTo(size.width, size.height / 2 + 8); // 右下
        break;
    }

    path.close();
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
