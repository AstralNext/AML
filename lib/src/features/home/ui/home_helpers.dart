import 'dart:convert';
import 'dart:typed_data';

import 'package:aml/src/features/instances/ui/create_new_instance.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:flutter/material.dart';

/// Home "Jump back in" row — world/server/instance.
class HomeJumpItem {
  final String type; // world | server | instance
  final DateTime lastPlayed;
  final rust.InstanceDto instance;
  final rust.WorldDto? world;

  const HomeJumpItem({
    required this.type,
    required this.lastPlayed,
    required this.instance,
    this.world,
  });
}

void openCreateInstance(BuildContext context) {
  Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) => const CreateNewInstance(),
    ),
  );
}

String relativeTime(DateTime dt) {
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
  return '一年前';
}

ImageProvider? decodeDataUrlImage(String? dataUrl) {
  var raw = dataUrl?.trim();
  if (raw == null || raw.isEmpty) return null;
  if (!raw.startsWith('data:')) {
    raw = 'data:image/png;base64,$raw';
  }
  if (!raw.startsWith('data:image')) return null;
  final comma = raw.indexOf(',');
  if (comma <= 0) return null;
  try {
    final payload = raw.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
    if (payload.isEmpty) return null;
    return MemoryImage(Uint8List.fromList(base64Decode(payload)));
  } catch (_) {
    return null;
  }
}

Color pingColor(int? ms, AppThemeTokens tokens) {
  if (ms == null) return tokens.colorBase.withValues(alpha: 0.55);
  if (ms < 150) return const Color(0xFF55C057);
  if (ms < 300) return const Color(0xFFE0A100);
  return const Color(0xFFFF5555);
}
