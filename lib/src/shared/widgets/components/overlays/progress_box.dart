import 'package:flutter/material.dart';
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

class _ProgressBoxState extends State<ProgressBox> {
  late final ProgressStore _progressStore = getIt<ProgressStore>();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final progressList = _progressStore.progressList.watch(context);
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: () => _progressStore.progressVisibility.value = false,
          ),
        ),
        Positioned(
          top: 10,
          right: 80,
          child: GestureDetector(
            onTap: () {},
            child: Material(
              elevation: 8,
              borderRadius: BorderRadius.circular(16),
              child: Container(
                width: 340,
                constraints: const BoxConstraints(minHeight: 50, maxHeight: 420),
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
                              color: tokens.colorBase.withAlpha(180),
                            ),
                          ),
                        ),
                      )
                    : SingleChildScrollView(
                        padding: const EdgeInsets.symmetric(vertical: 8),
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
      ],
    );
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
