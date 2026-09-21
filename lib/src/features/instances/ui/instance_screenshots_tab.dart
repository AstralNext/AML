import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/instances/application/instance_screenshots.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/reveal_in_explorer.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';

/// 实例详情页「截图」标签页：screenshots 目录网格浏览。
class InstanceScreenshotsTab extends StatefulWidget {
  const InstanceScreenshotsTab({super.key, required this.instanceId});

  final String instanceId;

  @override
  State<InstanceScreenshotsTab> createState() => _InstanceScreenshotsTabState();
}

class _InstanceScreenshotsTabState extends State<InstanceScreenshotsTab> {
  String? _instanceRoot;
  List<InstanceScreenshotEntry> _screenshots = [];
  bool _screenshotsLoading = false;
  VoidCallback? _disposeRunningEffect;

  InstanceStore get _store => getIt<InstanceStore>();

  @override
  void initState() {
    super.initState();
    _refreshScreenshots();
    var wasRunning = _store.isRunning(widget.instanceId);
    _disposeRunningEffect = effect(() {
      final running = _store.isRunning(widget.instanceId);
      if (wasRunning && !running) {
        _refreshScreenshots();
      }
      wasRunning = running;
    });
  }

  @override
  void dispose() {
    _disposeRunningEffect?.call();
    super.dispose();
  }

  Future<void> _refreshScreenshots() async {
    setState(() => _screenshotsLoading = true);
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final entries = await scanInstanceScreenshots(root);
      if (!mounted) return;
      setState(() {
        _instanceRoot = root;
        _screenshots = entries;
        _screenshotsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _screenshotsLoading = false;
      });
    }
  }

  Future<void> _openScreenshotsFolder() async {
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final dir = Directory(p.join(root, 'screenshots'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      if (!mounted) return;
      await revealInExplorer(context, dir.path);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    }
  }

  void _previewScreenshot(int index) {
    final paths = _screenshots.map((e) => e.path).toList();
    final titles = _screenshots.map((e) => e.name).toList();
    unawaited(
      showImageLightbox(
        context,
        urls: paths,
        initialIndex: index,
        titles: titles,
      ),
    );
  }

  String _formatScreenshotTime(DateTime? dt) {
    if (dt == null) return '';
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '截图',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_screenshots.length} 张',
              style: TextStyle(
                fontSize: 13,
                color: tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _openScreenshotsFolder,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('打开文件夹'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
            TextButton.icon(
              onPressed: _screenshotsLoading ? null : _refreshScreenshots,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _screenshotsLoading && _screenshots.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _screenshots.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.photo_camera_outlined,
                            size: 40,
                            color: tokens.colorBase.withValues(alpha: 0.45),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '暂无截图',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: tokens.colorContrast,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '在游戏中按 F2 截图后会显示在这里',
                            style: TextStyle(
                              fontSize: 13,
                              color: tokens.colorBase.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final columns = width >= 1100
                            ? 4
                            : width >= 760
                                ? 3
                                : 2;
                        return GridView.builder(
                          padding: EdgeInsets.zero,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 16 / 9,
                          ),
                          itemCount: _screenshots.length,
                          itemBuilder: (context, index) {
                            final shot = _screenshots[index];
                            return Material(
                              color: tokens.colorRaisedBg,
                              borderRadius: BorderRadius.circular(10),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => _previewScreenshot(index),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CachedRemoteImage(
                                      url: shot.path,
                                      fit: BoxFit.cover,
                                      placeholder: ColoredBox(
                                        color: tokens.colorSecondary
                                            .withValues(alpha: 0.12),
                                        child: const Center(
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                      error: ColoredBox(
                                        color: tokens.colorSecondary
                                            .withValues(alpha: 0.12),
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          color: tokens.colorBase
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                              Colors.black
                                                  .withValues(alpha: 0.72),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            8,
                                            18,
                                            8,
                                            8,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                shot.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              if (shot.modified != null)
                                                Text(
                                                  _formatScreenshotTime(
                                                    shot.modified,
                                                  ),
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                      alpha: 0.85,
                                                    ),
                                                    fontSize: 10,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
