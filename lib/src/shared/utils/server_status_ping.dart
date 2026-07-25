import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/utils/minecraft_motd.dart';
import 'package:flutter/foundation.dart';

void _log(String message) {
  if (kDebugMode) debugPrint(message);
}

/// Shared Server List Ping used by instance worlds tab and home Jump Back In.
Future<rust.ServerStatusDto?> pingServerAddress(String address) async {
  rust.ServerStatusDto? status;
  try {
    _log('[AML ping] dart modern try $address');
    status = await rust.getServerStatus(address: address);
    _log('[AML ping] dart modern ok $address');
  } catch (e) {
    _log('[AML ping] dart modern fail $address: $e');
    try {
      _log('[AML ping] dart legacy try $address');
      status = await rust.getServerStatus(
        address: address,
        protocolVersion: 74,
        legacy: true,
      );
      _log('[AML ping] dart legacy ok $address');
    } catch (e2) {
      _log('[AML ping] dart legacy fail $address: $e2');
      return null;
    }
  }

  // Forge / proxies often return stub MOTD when handshake protocol is -1.
  final proto = status.versionProtocol;
  final stub = _isDefaultOrEmptyMotd(status.descriptionJson) ||
      status.favicon == null ||
      status.favicon!.isEmpty;
  if (!status.legacy && proto != null && proto > 0 && stub) {
    _log(
      '[AML ping] dart re-ping $address with protocol=$proto '
      '(stub MOTD/favicon on first response)',
    );
    try {
      final richer = await rust.getServerStatus(
        address: address,
        protocolVersion: proto,
      );
      if (_statusLooksRicher(richer, status)) {
        _log(
          '[AML ping] dart re-ping preferred: '
          'motdLen=${richer.descriptionJson?.length} '
          'faviconLen=${richer.favicon?.length}',
        );
        status = richer;
      } else {
        _log(
          '[AML ping] dart re-ping no improvement '
          'motdLen=${richer.descriptionJson?.length} '
          'faviconLen=${richer.favicon?.length}',
        );
      }
    } catch (e) {
      _log('[AML ping] dart re-ping fail $address: $e');
    }
  }
  return status;
}

bool _isDefaultOrEmptyMotd(String? raw) {
  if (raw == null || raw.trim().isEmpty) return true;
  final plain = MinecraftMotd.toSpan(raw).toPlainText().trim();
  return plain.isEmpty || plain == MinecraftMotd.defaultText;
}

bool _statusLooksRicher(
  rust.ServerStatusDto next,
  rust.ServerStatusDto prev,
) {
  final nextFav = next.favicon != null && next.favicon!.isNotEmpty;
  final prevFav = prev.favicon != null && prev.favicon!.isNotEmpty;
  if (nextFav && !prevFav) return true;
  final nextStub = _isDefaultOrEmptyMotd(next.descriptionJson);
  final prevStub = _isDefaultOrEmptyMotd(prev.descriptionJson);
  if (!nextStub && prevStub) return true;
  final nextLen = next.descriptionJson?.length ?? 0;
  final prevLen = prev.descriptionJson?.length ?? 0;
  return nextLen > prevLen;
}
