import 'dart:io';

import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/clipboard_image.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Fullscreen image lightbox with swipe + pinch zoom.
Future<void> showImageLightbox(
  BuildContext context, {
  required List<String> urls,
  int initialIndex = 0,
  List<String?>? titles,
}) {
  final safe = urls.where((u) => u.trim().isNotEmpty).toList();
  if (safe.isEmpty) return Future.value();
  final index = initialIndex.clamp(0, safe.length - 1);

  return showGeneralDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierLabel: '关闭预览',
    barrierColor: Colors.black.withValues(alpha: 0.88),
    transitionDuration: const Duration(milliseconds: 180),
    pageBuilder: (context, animation, secondaryAnimation) {
      return _ImageLightbox(
        urls: safe,
        initialIndex: index,
        titles: titles,
      );
    },
    transitionBuilder: (context, animation, secondary, child) {
      return FadeTransition(
        opacity: CurvedAnimation(parent: animation, curve: Curves.easeOut),
        child: child,
      );
    },
  );
}

class _ImageLightbox extends StatefulWidget {
  const _ImageLightbox({
    required this.urls,
    required this.initialIndex,
    this.titles,
  });

  final List<String> urls;
  final int initialIndex;
  final List<String?>? titles;

  @override
  State<_ImageLightbox> createState() => _ImageLightboxState();
}

class _ImageLightboxState extends State<_ImageLightbox> {
  late final PageController _pageController;
  late int _index;
  final Map<int, TransformationController> _transforms = {};
  bool _actionBusy = false;

  @override
  void initState() {
    super.initState();
    _index = widget.initialIndex;
    _pageController = PageController(initialPage: _index);
  }

  @override
  void dispose() {
    _pageController.dispose();
    for (final c in _transforms.values) {
      c.dispose();
    }
    super.dispose();
  }

  TransformationController _controllerFor(int i) {
    return _transforms.putIfAbsent(i, TransformationController.new);
  }

  void _resetZoom(int i) {
    _controllerFor(i).value = Matrix4.identity();
  }

  void _goTo(int delta) {
    final next = _index + delta;
    if (next < 0 || next >= widget.urls.length) return;
    _pageController.animateToPage(
      next,
      duration: const Duration(milliseconds: 220),
      curve: Curves.easeOut,
    );
  }

  String _fileNameForIndex(int index) {
    final title = widget.titles != null && index < widget.titles!.length
        ? widget.titles![index]
        : null;
    if (title != null && title.trim().isNotEmpty) {
      return title.trim();
    }

    final url = widget.urls[index];
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      return p.basename(url);
    }

    final pathPart = Uri.tryParse(url)?.path ?? url;
    final base = p.basename(pathPart);
    if (base.isNotEmpty && base.contains('.')) return base;
    return 'image.png';
  }

  Future<File?> _resolveCurrentFile() {
    return RemoteImageCache.resolve(widget.urls[_index]);
  }

  Future<void> _downloadImage() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final file = await _resolveCurrentFile();
      if (file == null) {
        showAppSnackBar('图片未就绪，请稍后再试', isError: true);
        return;
      }

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存图片',
        fileName: _fileNameForIndex(_index),
        type: FileType.image,
      );
      if (savePath == null) return;

      final bytes = await file.readAsBytes();
      var target = savePath;
      final suggestedExt = p.extension(file.path);
      if (suggestedExt.isNotEmpty &&
          !target.toLowerCase().endsWith(suggestedExt.toLowerCase())) {
        target = '$target$suggestedExt';
      }
      await File(target).writeAsBytes(bytes);
      showAppSnackBar('已保存图片');
    } catch (e) {
      showAppSnackBar('下载失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Future<void> _copyImage() async {
    if (_actionBusy) return;
    setState(() => _actionBusy = true);
    try {
      final file = await _resolveCurrentFile();
      if (file == null) {
        showAppSnackBar('图片未就绪，请稍后再试', isError: true);
        return;
      }

      await copyImageFileToClipboard(file);
      showAppSnackBar('已复制到剪贴板');
    } catch (e) {
      showAppSnackBar('复制失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _actionBusy = false);
    }
  }

  Widget _navButton({
    required IconData icon,
    required String tooltip,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: enabled ? onTap : null,
      icon: Icon(icon, color: Colors.white, size: 28),
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: enabled ? 0.5 : 0.25),
        disabledBackgroundColor: Colors.black.withValues(alpha: 0.2),
        disabledForegroundColor: Colors.white38,
        minimumSize: const Size(48, 48),
        padding: const EdgeInsets.all(10),
      ),
    );
  }

  Widget _actionButton({
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return FilledButton.icon(
      onPressed: _actionBusy ? null : onTap,
      icon: Icon(icon, size: 18),
      label: Text(label),
      style: FilledButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        foregroundColor: Colors.white,
        disabledBackgroundColor: Colors.black.withValues(alpha: 0.3),
        disabledForegroundColor: Colors.white54,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final title = widget.titles != null && _index < widget.titles!.length
        ? widget.titles![_index]
        : null;
    final multi = widget.urls.length > 1;
    final canPrev = _index > 0;
    final canNext = _index < widget.urls.length - 1;

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.escape): () {
          Navigator.of(context).maybePop();
        },
        const SingleActivator(LogicalKeyboardKey.arrowLeft): () => _goTo(-1),
        const SingleActivator(LogicalKeyboardKey.arrowRight): () => _goTo(1),
      },
      child: Focus(
        autofocus: true,
        child: Material(
          color: Colors.transparent,
          child: Stack(
            children: [
              PageView.builder(
                controller: _pageController,
                itemCount: widget.urls.length,
                onPageChanged: (i) {
                  _resetZoom(_index);
                  setState(() => _index = i);
                },
                itemBuilder: (context, i) {
                  return Center(
                    child: InteractiveViewer(
                      transformationController: _controllerFor(i),
                      minScale: 1,
                      maxScale: 5,
                      child: CachedRemoteImage(
                        url: widget.urls[i],
                        fit: BoxFit.contain,
                        width: MediaQuery.sizeOf(context).width,
                        height: MediaQuery.sizeOf(context).height * 0.78,
                        borderRadius: BorderRadius.zero,
                        placeholder: const Center(
                          child: SizedBox(
                            width: 28,
                            height: 28,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                        error: Icon(
                          Icons.broken_image_outlined,
                          size: 48,
                          color: tokens.colorBase,
                        ),
                      ),
                    ),
                  );
                },
              ),
              if (multi) ...[
                Align(
                  alignment: Alignment.centerLeft,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: _navButton(
                      icon: Icons.chevron_left_rounded,
                      tooltip: '上一张',
                      enabled: canPrev,
                      onTap: () => _goTo(-1),
                    ),
                  ),
                ),
                Align(
                  alignment: Alignment.centerRight,
                  child: Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: _navButton(
                      icon: Icons.chevron_right_rounded,
                      tooltip: '下一张',
                      enabled: canNext,
                      onTap: () => _goTo(1),
                    ),
                  ),
                ),
              ],
              Positioned(
                top: 12,
                left: 12,
                right: 12,
                child: SafeArea(
                  child: Row(
                    children: [
                      if (multi)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 6,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.45),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '${_index + 1} / ${widget.urls.length}',
                            style: const TextStyle(
                              color: Colors.white,
                              fontWeight: FontWeight.w700,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      if (title != null && title.isNotEmpty) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: Colors.white.withValues(alpha: 0.9),
                              fontWeight: FontWeight.w600,
                              fontSize: 14,
                            ),
                          ),
                        ),
                      ] else
                        const Spacer(),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: () => Navigator.of(context).maybePop(),
                        icon: const Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                        ),
                        style: IconButton.styleFrom(
                          backgroundColor:
                              Colors.black.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned(
                left: 0,
                right: 0,
                bottom: 0,
                child: SafeArea(
                  child: Padding(
                    padding: const EdgeInsets.only(bottom: 20),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        _actionButton(
                          icon: Icons.download_rounded,
                          label: '下载',
                          onTap: _downloadImage,
                        ),
                        const SizedBox(width: 12),
                        _actionButton(
                          icon: Icons.copy_rounded,
                          label: '复制',
                          onTap: _copyImage,
                        ),
                        if (_actionBusy) ...[
                          const SizedBox(width: 12),
                          const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
