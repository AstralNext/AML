import 'dart:convert';

import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:flutter/foundation.dart';

class ServerPingState {
  const ServerPingState({
    required this.refreshing,
    this.status,
    this.offline = false,
  });

  final bool refreshing;
  final rust.ServerStatusDto? status;
  final bool offline;
}

void serverPingLog(String msg) {
  assert(() {
    // ignore: avoid_print
    debugPrint(msg);
    return true;
  }());
}

Uint8List? tryDecodeIconDataUrl(
  String dataUrl, {
  void Function(String message)? onLog,
}) {
  final log = onLog ?? serverPingLog;
  var raw = dataUrl.trim();
  if (raw.isEmpty) return null;
  if (!raw.startsWith('data:')) {
    raw = 'data:image/png;base64,$raw';
  }
  if (!raw.startsWith('data:image')) {
    log(
      '[AML ping] icon reject: not data:image (startsWith=${raw.length > 24 ? raw.substring(0, 24) : raw})',
    );
    return null;
  }
  final comma = raw.indexOf(',');
  if (comma <= 0) {
    log('[AML ping] icon reject: no comma in data URL');
    return null;
  }
  try {
    final payload = raw.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
    if (payload.isEmpty) {
      log('[AML ping] icon reject: empty base64 payload');
      return null;
    }
    final bytes = base64Decode(payload);
    if (bytes.isEmpty) {
      log('[AML ping] icon reject: decoded empty');
      return null;
    }
    return Uint8List.fromList(bytes);
  } catch (e) {
    log('[AML ping] icon decode error: $e');
    return null;
  }
}
