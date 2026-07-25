import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

class AnimatedTabBar extends StatefulWidget {
  final List<String> tabs;
  final int selectedIndex;
  final ValueChanged<int> onTabChanged;
  final ColorScheme colorScheme;

  const AnimatedTabBar({
    super.key,
    required this.tabs,
    required this.selectedIndex,
    required this.onTabChanged,
    required this.colorScheme,
  });

  @override
  State<AnimatedTabBar> createState() => _AnimatedTabBarState();
}

class _AnimatedTabBarState extends State<AnimatedTabBar>
    with TickerProviderStateMixin {
  int _pressedTabIndex = -1;
  bool _isAnimating = false;

  late AnimationController _backgroundController;
  late Animation<double> _backgroundPositionAnimation;
  late Animation<double> _backgroundWidthAnimation;

  final List<GlobalKey> _tabKeys = [];
  final GlobalKey _stackKey = GlobalKey();

  // 缓存tab位置信息
  final Map<int, Rect> _tabRects = {};

  @override
  void initState() {
    super.initState();

    // 初始化tab keys
    for (int i = 0; i < widget.tabs.length; i++) {
      _tabKeys.add(GlobalKey());
    }

    _backgroundController = AnimationController(
      duration: const Duration(milliseconds: 250),
      vsync: this,
    );

    _backgroundPositionAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _backgroundController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _backgroundWidthAnimation = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(
        parent: _backgroundController,
        curve: Curves.easeInOutCubic,
      ),
    );

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _updateTabRects();
    });
  }

  @override
  void dispose() {
    _backgroundController.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(AnimatedTabBar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.tabs.length != widget.tabs.length) {
      // 如果tabs数量发生变化，重新初始化keys
      _tabKeys.clear();
      for (int i = 0; i < widget.tabs.length; i++) {
        _tabKeys.add(GlobalKey());
      }
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _updateTabRects();
      });
    }
  }

  void _animateToTab(int targetIndex) async {
    if (targetIndex == widget.selectedIndex) return;

    _updateTabRects();
    final targetRect = _tabRects[targetIndex];
    if (targetRect == null) return;

    // 获取当前动画的实时位置和宽度作为新动画的起点
    double currentLeft;
    double currentWidth;

    if (_isAnimating) {
      // 如果正在动画中，使用当前动画值
      currentLeft = _backgroundPositionAnimation.value;
      currentWidth = _backgroundWidthAnimation.value;
    } else {
      // 如果没有动画，使用当前选中标签的位置
      final currentRect = _tabRects[widget.selectedIndex];
      if (currentRect == null) return;
      currentLeft = currentRect.left;
      currentWidth = currentRect.width;
    }

    setState(() {
      _isAnimating = true;
    });

    // 创建从当前位置到目标位置的平滑动画
    _backgroundPositionAnimation = Tween<double>(
      begin: currentLeft,
      end: targetRect.left,
    ).animate(
      CurvedAnimation(
        parent: _backgroundController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _backgroundWidthAnimation = Tween<double>(
      begin: currentWidth,
      end: targetRect.width,
    ).animate(
      CurvedAnimation(
        parent: _backgroundController,
        curve: Curves.easeInOutCubic,
      ),
    );

    _backgroundController.reset();
    await _backgroundController.forward();

    setState(() {
      _isAnimating = false;
    });

    // 通知父组件选中的tab发生了变化
    widget.onTabChanged(targetIndex);
  }

  void _updateTabRects() {
    final stackContext = _stackKey.currentContext;
    if (stackContext == null) return;

    final RenderBox stackRenderBox =
        stackContext.findRenderObject() as RenderBox;

    for (int i = 0; i < _tabKeys.length; i++) {
      final tabContext = _tabKeys[i].currentContext;
      if (tabContext != null) {
        final RenderBox tabRenderBox =
            tabContext.findRenderObject() as RenderBox;
        final offset = tabRenderBox.localToGlobal(
          Offset.zero,
          ancestor: stackRenderBox,
        );
        _tabRects[i] = Rect.fromLTWH(
          offset.dx,
          offset.dy,
          tabRenderBox.size.width,
          tabRenderBox.size.height,
        );
      }
    }
  }

  Rect? _getTabRect(int index) {
    return _tabRects[index];
  }

  @override
  Widget build(BuildContext context) {
    final tokens = AppThemeTokens.fallback(widget.colorScheme);
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(22),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.1),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Stack(
        key: _stackKey,
        children: [
          // 动画背景
          AnimatedBuilder(
            animation: _backgroundController,
            builder: (context, child) {
              final currentRect = _getTabRect(widget.selectedIndex);
              if (currentRect == null) {
                // 如果还没有位置信息，先更新位置信息再使用
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _updateTabRects();
                  if (mounted) {
                    setState(() {});
                  }
                });
                // 返回一个不可见的占位符
                return const SizedBox.shrink();
              }

              return Positioned(
                left: _isAnimating
                    ? _backgroundPositionAnimation.value
                    : currentRect.left,
                top: 6,
                child: Container(
                  width: _isAnimating
                      ? _backgroundWidthAnimation.value
                      : currentRect.width,
                  height: 32,
                  decoration: BoxDecoration(
                    color: tokens.colorButtonBgSelected.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(16),
                  ),
                ),
              );
            },
          ),
          // Tab按钮行
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 6),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: widget.tabs.asMap().entries.map((entry) {
                final index = entry.key;
                final tab = entry.value;
                final isSelected = index == widget.selectedIndex;

                return GestureDetector(
                  onTap: () {
                    _animateToTab(index);
                  },
                  onTapDown: (_) {
                    setState(() {
                      _pressedTabIndex = index;
                    });
                  },
                  onTapUp: (_) {
                    Future.delayed(const Duration(milliseconds: 100), () {
                      if (mounted) {
                        setState(() {
                          _pressedTabIndex = -1;
                        });
                      }
                    });
                  },
                  onTapCancel: () {
                    setState(() {
                      _pressedTabIndex = -1;
                    });
                  },
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: AnimatedContainer(
                      key: _tabKeys[index],
                      duration: const Duration(milliseconds: 150),
                      curve: Curves.easeInOutCubic,
                      transformAlignment: Alignment.center,
                      transform: _pressedTabIndex == index
                          ? Matrix4.diagonal3Values(0.95, 0.95, 1.0)
                          : Matrix4.identity(),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 6,
                      ),
                      child: AnimatedDefaultTextStyle(
                        duration: const Duration(milliseconds: 200),
                        curve: Curves.easeInOutCubic,
                        style: DefaultTextStyle.of(context).style.copyWith(
                          color: isSelected
                              ? tokens.colorButtonTextSelected
                              : tokens.colorBase,
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                        ),
                        child: Text(tab),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ],
      ),
    );
  }
}
