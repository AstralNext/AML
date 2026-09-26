import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/progress_state.dart';
import 'package:aml/src/app/state/progress_item.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/progress_messages.dart';
import 'package:signals_flutter/signals_flutter.dart';

class ProgressBox extends StatefulWidget {
  const ProgressBox({super.key});

  @override
  State<ProgressBox> createState() => _ProgressBoxState();
}

class _ProgressBoxState extends State<ProgressBox>
    with SingleTickerProviderStateMixin {
  late final ProgressStore _progressStore = getIt<ProgressStore>();

  late final AnimationController _controller;
  late final Animation<double> _opacity;
  late final Animation<Offset> _slide;
  late final Animation<double> _scale;
  VoidCallback? _disposeEffect;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
      reverseDuration: const Duration(milliseconds: 130),
    );
    final curve = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeOutCubic,
      reverseCurve: Curves.easeInCubic,
    );
    _opacity = curve;
    _slide = Tween<Offset>(
      begin: const Offset(0, -0.08),
      end: Offset.zero,
    ).animate(curve);
    _scale = Tween<double>(begin: 0.96, end: 1).animate(curve);

    // 由可见性信号驱动进/退场动画（组件常驻挂载，避免硬切）。
    _disposeEffect = effect(() {
      if (_progressStore.progressVisibility.value) {
        _controller.forward();
      } else {
        _controller.reverse();
      }
    });
  }

  @override
  void dispose() {
    _disposeEffect?.call();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Watch((context) {
      final open = _progressStore.progressVisibility.value;
      final progressList = _progressStore.progressList.value;
      return Stack(
        children: [
          Positioned.fill(
            // 退场动画期间立即放行指针，不挡主界面操作。
            child: IgnorePointer(
              ignoring: !open,
              // 穿透式遮罩：pointer down 时关闭弹窗，但不参与手势竞技场、
              // 不阻断命中测试——同一次点击仍会激活下层元素，无需点两次。
              child: _DismissOnPointerDownBarrier(
                onDismiss: _progressStore.dismissByOutsideTap,
              ),
            ),
          ),
          Positioned(
            top: 10,
            right: 80,
            child: IgnorePointer(
              ignoring: !open,
              child: FadeTransition(
                opacity: _opacity,
                child: SlideTransition(
                  position: _slide,
                  child: ScaleTransition(
                    scale: _scale,
                    alignment: Alignment.topRight,
                    child: GestureDetector(
                      onTap: () {},
                      child: Material(
                        elevation: 8,
                        borderRadius: BorderRadius.circular(16),
                        child: Container(
                          width: 340,
                          constraints: const BoxConstraints(
                            minHeight: 50,
                            maxHeight: 420,
                          ),
                          decoration: BoxDecoration(
                            color: tokens.colorRaisedBg,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: const [
                              BoxShadow(
                                color: Colors.black12,
                                blurRadius: 12,
                                offset: Offset(0, 4),
                              ),
                            ],
                          ),
                          child: progressList.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(16),
                                    child: Text(
                                      '暂无进度',
                                      style: TextStyle(
                                        color:
                                            tokens.colorBase.withAlpha(180),
                                      ),
                                    ),
                                  ),
                                )
                              : SingleChildScrollView(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 8,
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      for (final item in progressList)
                                        Padding(
                                          padding: const EdgeInsets.symmetric(
                                            vertical: 10,
                                            horizontal: 16,
                                          ),
                                          child: ProgressItemWidget(item: item),
                                        ),
                                    ],
                                  ),
                                ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      );
    });
  }
}

/// 点击穿透的弹窗外遮罩。
///
/// 普通的全屏 GestureDetector 会赢得手势竞技场并消费第一次点击，
/// 导致“第一次点击只关闭弹窗，再点一次才能点中下面的元素”。
/// 这里通过自定义 RenderObject：把自身加入命中路径以接收 pointer down
/// （触发关闭），但 hitTest 始终返回 false，使 Stack 继续向下命中
/// 主界面元素；且不注册任何手势识别器、不参与竞技场，因此同一次点击
/// 既能关闭弹窗，又能正常激活下层的按钮/输入框。
class _DismissOnPointerDownBarrier extends SingleChildRenderObjectWidget {
  const _DismissOnPointerDownBarrier({required this.onDismiss});

  final VoidCallback onDismiss;

  @override
  RenderObject createRenderObject(BuildContext context) =>
      _RenderDismissBarrier(onDismiss);

  @override
  void updateRenderObject(
    BuildContext context,
    _RenderDismissBarrier renderObject,
  ) {
    renderObject.onDismiss = onDismiss;
  }
}

class _RenderDismissBarrier extends RenderProxyBox {
  _RenderDismissBarrier(this._onDismiss);

  VoidCallback _onDismiss;
  set onDismiss(VoidCallback value) => _onDismiss = value;

  @override
  bool hitTest(BoxHitTestResult result, {required Offset position}) {
    if (size.contains(position)) {
      // 加入命中路径以接收本次指针序列，但返回 false，
      // 让父级 Stack 继续命中其下方的兄弟节点。
      result.add(BoxHitTestEntry(this, position));
    }
    return false;
  }

  @override
  void handleEvent(PointerEvent event, BoxHitTestEntry entry) {
    if (event is PointerDownEvent) {
      _onDismiss();
    }
  }
}

class ProgressItemWidget extends StatelessWidget {
  final ProgressItem item;
  const ProgressItemWidget({super.key, required this.item});

  static const _failColor = Color(0xFFFF7B7B);

  @override
  Widget build(BuildContext context) {
    final name = item.name.watch(context);
    final progress = item.progress.watch(context);
    final progressText = item.progressText.watch(context);
    final failed = item.failed.watch(context);
    final retryAttempt = item.retryAttempt.watch(context);
    final subProgress = item.subProgress.watch(context);
    final subText = item.subText.watch(context);
    final tokens = context.tokens;
    final percent = (progress.clamp(0.0, 1.0) * 100).round();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: failed ? _failColor : tokens.colorContrast,
                ),
              ),
            ),
            if (!failed)
              Text(
                '$percent%',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: tokens.colorBase.withValues(alpha: 0.7),
                ),
              ),
            if (failed)
              IconButton(
                tooltip: '关闭',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                onPressed: item.dispose,
                icon: Icon(
                  Icons.close,
                  size: 18,
                  color: tokens.colorBase.withValues(alpha: 0.7),
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: LinearProgressIndicator(
            value: failed ? 1 : progress.clamp(0.0, 1.0),
            minHeight: 8,
            backgroundColor: tokens.colorButtonBorder.withValues(alpha: 0.5),
            valueColor: AlwaysStoppedAnimation<Color>(
              failed ? _failColor : tokens.colorBrand,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          humanizeProgressMessage(
            progressText.isEmpty
                ? (failed ? '失败' : '准备中…')
                : progressText,
          ),
          style: TextStyle(
            fontSize: 13,
            height: 1.35,
            color: failed
                ? _failColor.withValues(alpha: 0.95)
                : tokens.colorBase.withValues(alpha: 0.8),
          ),
        ),
        if (!failed && (subText.isNotEmpty || subProgress != null)) ...[
          const SizedBox(height: 8),
          if (subText.isNotEmpty)
            Text(
              subText,
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                height: 1.3,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
          if (subProgress != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(3),
              child: LinearProgressIndicator(
                value: subProgress.clamp(0.0, 1.0),
                minHeight: 4,
                backgroundColor: tokens.colorButtonBorder.withValues(alpha: 0.4),
                valueColor: AlwaysStoppedAnimation<Color>(
                  tokens.colorBrand.withValues(alpha: 0.75),
                ),
              ),
            ),
          ],
        ],
        if (failed && item.onRetry != null) ...[
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () {
                final retry = item.onRetry;
                if (retry == null) return;
                item.dispose();
                retry();
              },
              icon: const Icon(Icons.refresh, size: 16),
              label: Text(
                retryAttempt > 0 ? '再试一次（已重试 $retryAttempt 次）' : '重试',
              ),
              style: TextButton.styleFrom(
                foregroundColor: tokens.colorContrast,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ],
    );
  }
}
