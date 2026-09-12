import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

class WorldMapChunkImage {
  WorldMapChunkImage({
    required this.chunkX,
    required this.chunkZ,
    required this.image,
  });

  final int chunkX;
  final int chunkZ;
  final ui.Image image;

  static Future<WorldMapChunkImage> fromRgba(
    int chunkX,
    int chunkZ,
    Uint8List rgba,
    int pixelSize,
  ) async {
    final buffer = await ui.ImmutableBuffer.fromUint8List(rgba);
    final descriptor = ui.ImageDescriptor.raw(
      buffer,
      width: pixelSize,
      height: pixelSize,
      rowBytes: pixelSize * 4,
      pixelFormat: ui.PixelFormat.rgba8888,
    );
    final codec = await descriptor.instantiateCodec();
    final frame = await codec.getNextFrame();
    codec.dispose();
    descriptor.dispose();
    buffer.dispose();
    return WorldMapChunkImage(
      chunkX: chunkX,
      chunkZ: chunkZ,
      image: frame.image,
    );
  }

  void dispose() => image.dispose();
}

/// Zoomable / pannable map assembled from independent Minecraft chunks.
class WorldMapViewer extends StatefulWidget {
  const WorldMapViewer({
    super.key,
    this.chunks = const [],
    this.minChunkX,
    this.minChunkZ,
    this.maxChunkX,
    this.maxChunkZ,
    this.progress,
    this.generating = false,
    this.revision = 0,
    this.emptyLabel = '暂无地图',
  });

  final List<WorldMapChunkImage> chunks;
  final int? minChunkX;
  final int? minChunkZ;
  final int? maxChunkX;
  final int? maxChunkZ;
  final double? progress;
  final bool generating;
  final int revision;
  final String emptyLabel;

  @override
  State<WorldMapViewer> createState() => _WorldMapViewerState();
}

class _WorldMapViewerState extends State<WorldMapViewer> {
  final _controller = TransformationController();
  static const _minScale = 0.2;
  static const _maxScale = 12.0;
  int _lastCenteredChunkCount = 0;
  bool _didInitialCenter = false;

  /// Once the user pans / zooms, never auto-frame again for this map session.
  bool _userAdjustedView = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant WorldMapViewer oldWidget) {
    super.didUpdateWidget(oldWidget);

    final hadBounds = _boundsOf(oldWidget) != null;
    final hasBounds = _hasContentBounds;

    // Full reload cleared content — allow a fresh initial frame.
    if (hadBounds && !hasBounds) {
      _userAdjustedView = false;
      _didInitialCenter = false;
      _lastCenteredChunkCount = 0;
      _controller.value = Matrix4.identity();
    }

    // Expanding min bounds remaps child coordinates; keep the camera visually
    // locked so progressive loads don't yank the view under the user's finger.
    if (hadBounds && hasBounds) {
      _compensateOriginShift(oldWidget);
    }

    _scheduleAutoCenterIfNeeded();
  }

  @override
  void initState() {
    super.initState();
    _scheduleAutoCenterIfNeeded();
  }

  bool get _hasContentBounds => _boundsOf(widget) != null;

  static ({int minX, int minZ, int maxX, int maxZ})? _boundsOf(
    WorldMapViewer w,
  ) {
    if (w.chunks.isEmpty ||
        w.minChunkX == null ||
        w.minChunkZ == null ||
        w.maxChunkX == null ||
        w.maxChunkZ == null) {
      return null;
    }
    return (
      minX: w.minChunkX!,
      minZ: w.minChunkZ!,
      maxX: w.maxChunkX!,
      maxZ: w.maxChunkZ!,
    );
  }

  void _markUserAdjusted() {
    _userAdjustedView = true;
  }

  /// When minChunk shrinks, every tile's local (x,z) increases by the delta.
  /// Counter-translate so world points stay under the same screen pixels.
  void _compensateOriginShift(WorldMapViewer oldWidget) {
    final oldMinX = oldWidget.minChunkX;
    final oldMinZ = oldWidget.minChunkZ;
    final newMinX = widget.minChunkX;
    final newMinZ = widget.minChunkZ;
    if (oldMinX == null ||
        oldMinZ == null ||
        newMinX == null ||
        newMinZ == null) {
      return;
    }
    final dx = (oldMinX - newMinX) * 16.0;
    final dy = (oldMinZ - newMinZ) * 16.0;
    if (dx == 0 && dy == 0) return;

    final m = _controller.value.clone();
    // parent = M * child  ⇒  M_new * (child + δ) = M_old * child
    // ⇒ M_new = M_old * T(-δ)
    m.multiply(Matrix4.translationValues(-dx, -dy, 0));
    _controller.value = m;
  }

  void _scheduleAutoCenterIfNeeded() {
    if (!_hasContentBounds || _userAdjustedView) return;

    final count = widget.chunks.length;
    // Frame once when content first appears; optionally once more after a few
    // tiles so early framing isn't stuck on a single corner chunk.
    final shouldCenter = !_didInitialCenter ||
        (_lastCenteredChunkCount < 4 && count >= 4 && !_userAdjustedView);
    if (!shouldCenter) return;

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _userAdjustedView) return;
      if (_centerOnContent()) {
        _didInitialCenter = true;
        _lastCenteredChunkCount = count;
      }
    });
  }

  /// Fit & center the viewport on the bounding box of loaded chunks.
  bool _centerOnContent() {
    if (!_hasContentBounds) return false;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize || box.size.isEmpty) return false;

    final minX = widget.minChunkX!;
    final minZ = widget.minChunkZ!;
    final maxX = widget.maxChunkX!;
    final maxZ = widget.maxChunkZ!;
    final mapW = (maxX - minX + 1) * 16.0;
    final mapH = (maxZ - minZ + 1) * 16.0;
    if (mapW <= 0 || mapH <= 0) return false;

    var sumX = 0.0;
    var sumZ = 0.0;
    for (final chunk in widget.chunks) {
      final tileW = chunk.image.width.toDouble();
      final tileH = chunk.image.height.toDouble();
      sumX += (chunk.chunkX - minX) * 16.0 + tileW / 2;
      sumZ += (chunk.chunkZ - minZ) * 16.0 + tileH / 2;
    }
    final contentCx = sumX / widget.chunks.length;
    final contentCz = sumZ / widget.chunks.length;

    final viewW = box.size.width;
    final viewH = box.size.height;
    final fit = (viewW / mapW < viewH / mapH) ? viewW / mapW : viewH / mapH;
    final scale = (fit * 0.88).clamp(_minScale, _maxScale);

    final m = Matrix4.identity();
    m.translateByDouble(viewW / 2, viewH / 2, 0, 1);
    m.scaleByDouble(scale, scale, 1, 1);
    m.translateByDouble(-contentCx, -contentCz, 0, 1);
    _controller.value = m;
    return true;
  }

  void _zoomBy(double factor) {
    _markUserAdjusted();
    final m = _controller.value.clone();
    final current = m.getMaxScaleOnAxis();
    final next = (current * factor).clamp(_minScale, _maxScale);
    if ((next - current).abs() < 1e-6) return;
    final ratio = next / current;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final center = box.size.center(Offset.zero);
    final scene = _controller.toScene(center);
    m.translateByDouble(scene.dx, scene.dy, 0, 1);
    m.scaleByDouble(ratio, ratio, ratio, 1);
    m.translateByDouble(-scene.dx, -scene.dy, 0, 1);
    _controller.value = m;
  }

  void _reset() {
    // Explicit recenter — still counts as user control so loads won't steal again.
    _markUserAdjusted();
    if (!_centerOnContent()) {
      _controller.value = Matrix4.identity();
    }
  }

  @override
  Widget build(BuildContext context) {
    final hasChunks = _hasContentBounds;

    if (!hasChunks && !widget.generating) {
      return Center(
        child: Text(
          widget.emptyLabel,
          style: TextStyle(
            color:
                Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55),
          ),
        ),
      );
    }

    return Stack(
      children: [
        Positioned.fill(
          child: InteractiveViewer(
            transformationController: _controller,
            minScale: _minScale,
            maxScale: _maxScale,
            constrained: false,
            // Allow free panning when zoomed out (default margins pin to a corner).
            boundaryMargin: const EdgeInsets.all(double.infinity),
            onInteractionStart: (_) => _markUserAdjusted(),
            child: hasChunks
                ? _progressiveMap()
                : const SizedBox(width: 1, height: 1),
          ),
        ),
        if (widget.generating)
          Positioned(
            left: 12,
            top: 12,
            child: Material(
              color: Colors.black.withValues(alpha: 0.65),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      widget.progress == null
                          ? '正在读取区块…'
                          : '正在读取区块 ${(widget.progress! * 100).clamp(0, 100).toStringAsFixed(0)}%',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          right: 8,
          bottom: 8,
          child: Material(
            color: Colors.black.withValues(alpha: 0.5),
            borderRadius: BorderRadius.circular(8),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: '缩小',
                  icon: const Icon(Icons.remove, color: Colors.white, size: 18),
                  onPressed: () => _zoomBy(1 / 1.35),
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: '居中',
                  icon: const Icon(Icons.center_focus_weak,
                      color: Colors.white, size: 18),
                  onPressed: _reset,
                  visualDensity: VisualDensity.compact,
                ),
                IconButton(
                  tooltip: '放大',
                  icon: const Icon(Icons.add, color: Colors.white, size: 18),
                  onPressed: () => _zoomBy(1.35),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  Widget _progressiveMap() {
    final width = (widget.maxChunkX! - widget.minChunkX! + 1) * 16;
    final height = (widget.maxChunkZ! - widget.minChunkZ! + 1) * 16;
    return CustomPaint(
      size: Size(width.toDouble(), height.toDouble()),
      isComplex: true,
      willChange: widget.generating,
      painter: _ChunkMapPainter(
        chunks: widget.chunks,
        minChunkX: widget.minChunkX!,
        minChunkZ: widget.minChunkZ!,
        revision: widget.revision,
        chunkCount: widget.chunks.length,
      ),
    );
  }
}

class _ChunkMapPainter extends CustomPainter {
  const _ChunkMapPainter({
    required this.chunks,
    required this.minChunkX,
    required this.minChunkZ,
    required this.revision,
    required this.chunkCount,
  });

  final List<WorldMapChunkImage> chunks;
  final int minChunkX;
  final int minChunkZ;
  final int revision;
  final int chunkCount;

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = const Color(0xFF121216),
    );
    final chunkPaint = Paint()..filterQuality = FilterQuality.none;
    for (final chunk in chunks) {
      canvas.drawImage(
        chunk.image,
        Offset(
          (chunk.chunkX - minChunkX) * 16.0,
          (chunk.chunkZ - minChunkZ) * 16.0,
        ),
        chunkPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _ChunkMapPainter oldDelegate) =>
      revision != oldDelegate.revision ||
      chunkCount != oldDelegate.chunkCount ||
      minChunkX != oldDelegate.minChunkX ||
      minChunkZ != oldDelegate.minChunkZ;
}
