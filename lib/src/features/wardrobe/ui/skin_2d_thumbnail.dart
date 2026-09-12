import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';

/// Flat front-view thumbnail for skin grid tiles.
class Skin2DThumbnail extends StatefulWidget {
  final Uint8List skinPng;
  final bool slim;

  const Skin2DThumbnail({
    super.key,
    required this.skinPng,
    this.slim = false,
  });

  @override
  State<Skin2DThumbnail> createState() => _Skin2DThumbnailState();
}

class _Skin2DThumbnailState extends State<Skin2DThumbnail> {
  ui.Image? _image;

  @override
  void initState() {
    super.initState();
    _decode();
  }

  @override
  void didUpdateWidget(covariant Skin2DThumbnail oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.skinPng != widget.skinPng) _decode();
  }

  Future<void> _decode() async {
    final codec = await ui.instantiateImageCodec(widget.skinPng);
    final frame = await codec.getNextFrame();
    if (!mounted) {
      frame.image.dispose();
      return;
    }
    setState(() {
      _image?.dispose();
      _image = frame.image;
    });
  }

  @override
  void dispose() {
    _image?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final image = _image;
    if (image == null) {
      return const Center(child: SizedBox(
        width: 18,
        height: 18,
        child: CircularProgressIndicator(strokeWidth: 2),
      ));
    }
    return CustomPaint(
      painter: _FrontPainter(image: image, slim: widget.slim),
      child: const SizedBox.expand(),
    );
  }
}

class _FrontPainter extends CustomPainter {
  final ui.Image image;
  final bool slim;

  _FrontPainter({required this.image, required this.slim});

  @override
  void paint(Canvas canvas, Size size) {
    final armW = slim ? 3.0 : 4.0;
    final modelW = armW + 8 + armW;
    const modelH = 32.0;
    final scale = mathMin(size.width / modelW, size.height / modelH);
    final ox = (size.width - modelW * scale) / 2;
    final oy = (size.height - modelH * scale) / 2;

    final paint = Paint()
      ..isAntiAlias = false
      ..filterQuality = FilterQuality.none;

    void blit(Rect src, double dx, double dy, double dw, double dh) {
      canvas.drawImageRect(
        image,
        src,
        Rect.fromLTWH(ox + dx * scale, oy + dy * scale, dw * scale, dh * scale),
        paint,
      );
    }

    final bodyX = armW;
    // Head + hat
    blit(const Rect.fromLTWH(8, 8, 8, 8), bodyX, 0, 8, 8);
    blit(const Rect.fromLTWH(40, 8, 8, 8), bodyX, 0, 8, 8);
    // Body + jacket
    blit(const Rect.fromLTWH(20, 20, 8, 12), bodyX, 8, 8, 12);
    blit(const Rect.fromLTWH(20, 36, 8, 12), bodyX, 8, 8, 12);
    // Right arm (viewer left)
    blit(Rect.fromLTWH(44, 20, armW, 12), 0, 8, armW, 12);
    blit(Rect.fromLTWH(44, 36, armW, 12), 0, 8, armW, 12);
    // Left arm
    blit(Rect.fromLTWH(36, 52, armW, 12), bodyX + 8, 8, armW, 12);
    blit(Rect.fromLTWH(52, 52, armW, 12), bodyX + 8, 8, armW, 12);
    // Legs
    blit(const Rect.fromLTWH(4, 20, 4, 12), bodyX, 20, 4, 12);
    blit(const Rect.fromLTWH(4, 36, 4, 12), bodyX, 20, 4, 12);
    blit(const Rect.fromLTWH(20, 52, 4, 12), bodyX + 4, 20, 4, 12);
    blit(const Rect.fromLTWH(4, 52, 4, 12), bodyX + 4, 20, 4, 12);
  }

  double mathMin(double a, double b) => a < b ? a : b;

  @override
  bool shouldRepaint(covariant _FrontPainter old) =>
      old.image != image || old.slim != slim;
}
