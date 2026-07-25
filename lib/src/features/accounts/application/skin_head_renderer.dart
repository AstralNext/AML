import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/painting.dart';

/// Crops the Minecraft skin face (+ hat overlay) into a square head PNG.
///
/// UV: face `(8,8)` 8×8, hat `(40,8)` 8×8 — head only, not full body.
Future<Uint8List?> renderSkinHeadPng(
	Uint8List skinPng, {
	int size = 64,
}) async {
	if (skinPng.isEmpty || size <= 0) return null;

	ui.Image? skin;
	ui.Image? out;
	try {
		final codec = await ui.instantiateImageCodec(skinPng);
		final frame = await codec.getNextFrame();
		skin = frame.image;

		if (skin.width < 48 || skin.height < 16) {
			return null;
		}

		final recorder = ui.PictureRecorder();
		final canvas = Canvas(recorder);
		final paint = Paint()
			..isAntiAlias = false
			..filterQuality = FilterQuality.none;

		final dst = Rect.fromLTWH(0, 0, size.toDouble(), size.toDouble());
		canvas.drawImageRect(
			skin,
			const Rect.fromLTWH(8, 8, 8, 8),
			dst,
			paint,
		);
		canvas.drawImageRect(
			skin,
			const Rect.fromLTWH(40, 8, 8, 8),
			dst,
			paint,
		);

		final picture = recorder.endRecording();
		out = await picture.toImage(size, size);
		final bytes = await out.toByteData(format: ui.ImageByteFormat.png);
		return bytes?.buffer.asUint8List();
	} catch (_) {
		return null;
	} finally {
		skin?.dispose();
		out?.dispose();
	}
}
