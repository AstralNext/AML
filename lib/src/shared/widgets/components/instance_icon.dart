import 'dart:io';

import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/material.dart';

/// Instance avatar: cached local file, remote URL (legacy), or tinted placeholder.
class InstanceIcon extends StatelessWidget {
  const InstanceIcon({
    super.key,
    required this.instanceId,
    this.iconPath,
    this.size = 48,
    this.borderRadius = 8,
  });

  final String instanceId;
  final String? iconPath;
  final double size;
  final double borderRadius;

  static int _hash(String value) {
    var hash = 0;
    for (var i = 0; i < value.length; i++) {
      hash = ((hash << 5) - hash + value.codeUnitAt(i)) | 0;
    }
    return hash;
  }

  static Color _tintFor(String id) {
    final hue = _hash(id).abs() % 360;
    return HSLColor.fromAHSL(1, hue.toDouble(), 0.75, 0.5).toColor();
  }

  @override
  Widget build(BuildContext context) {
    final path = iconPath?.trim();
    if (path != null && path.isNotEmpty) {
      if (path.startsWith('http://') || path.startsWith('https://')) {
        return CachedRemoteImage(
          url: path,
          width: size,
          height: size,
          borderRadius: BorderRadius.circular(borderRadius),
          placeholder: _placeholder(),
          error: _placeholder(),
        );
      }
      final file = File(path);
      if (file.existsSync()) {
        return _framed(
          Image.file(
            file,
            width: size,
            height: size,
            fit: BoxFit.cover,
            errorBuilder: (_, __, ___) => _placeholder(),
          ),
        );
      }
    }
    return _placeholder();
  }

  Widget _framed(Widget child) {
    return ClipRRect(
      borderRadius: BorderRadius.circular(borderRadius),
      child: child,
    );
  }

  Widget _placeholder() {
    final tint = _tintFor(instanceId);
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: tint.withValues(alpha: 0.22),
        borderRadius: BorderRadius.circular(borderRadius),
        border: Border.all(color: tint.withValues(alpha: 0.55)),
      ),
      child: Icon(
        Icons.inventory_2_outlined,
        color: tint,
        size: size * 0.48,
      ),
    );
  }
}
