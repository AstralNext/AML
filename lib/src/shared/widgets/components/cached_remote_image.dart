import 'dart:convert';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/discover/data/mcim_fallback_http.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// Disk-backed remote image cache under `{resource}/cache/icons/by-url/{sha1}.{ext}`.
///
/// Flutter has no browser HTTP disk cache; this keeps content lists instant after first fetch.
class RemoteImageCache {
  RemoteImageCache._();

  static final Map<String, Future<File?>> _inflight = {};

  static Directory _dir() {
    final root = getIt<ResourceSettingsState>().resourceDirectory.value;
    return Directory(p.join(root, 'cache', 'icons', 'by-url'));
  }

  static String _key(String url) =>
      sha1.convert(utf8.encode(url)).toString();

  static String _extFromUrl(String url) {
    final path = Uri.tryParse(url)?.path ?? url;
    final ext = p.extension(path).replaceFirst('.', '').toLowerCase();
    if (ext == 'png' ||
        ext == 'jpg' ||
        ext == 'jpeg' ||
        ext == 'webp' ||
        ext == 'gif') {
      return ext == 'jpeg' ? 'jpg' : ext;
    }
    return 'png';
  }

  /// Sync hit when the file is already on disk (avoids spinner flash in lists).
  static File? peek(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return null;
    if (!(trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
      final local = File(trimmed);
      return local.existsSync() ? local : null;
    }
    try {
      final file =
          File(p.join(_dir().path, '${_key(trimmed)}.${_extFromUrl(trimmed)}'));
      if (file.existsSync() && file.lengthSync() > 0) return file;
    } catch (_) {}
    return null;
  }

  /// Returns a local file for [url], downloading once if needed.
  static Future<File?> resolve(String url) {
    final trimmed = url.trim();
    if (trimmed.isEmpty) return Future.value(null);
    if (!(trimmed.startsWith('http://') || trimmed.startsWith('https://'))) {
      final local = File(trimmed);
      return Future.value(local.existsSync() ? local : null);
    }
    final cached = peek(trimmed);
    if (cached != null) return Future.value(cached);
    return _inflight.putIfAbsent(trimmed, () => _resolveOnce(trimmed));
  }

  static Future<File?> _resolveOnce(String url) async {
    try {
      final dir = _dir();
      await dir.create(recursive: true);
      final file = File(p.join(dir.path, '${_key(url)}.${_extFromUrl(url)}'));
      if (await file.exists() && await file.length() > 0) {
        return file;
      }
      try {
        final bytes = await McimFallbackHttp.downloadBytes(url);
        await file.writeAsBytes(bytes, flush: true);
        return file;
      } catch (_) {
        return null;
      }
    } catch (e, st) {
      debugPrint('RemoteImageCache failed for $url: $e\n$st');
      return null;
    } finally {
      // Allow a later retry if this attempt failed / file was deleted.
      _inflight.remove(url);
    }
  }
}

/// Loads [url] from disk cache when possible; downloads once on miss.
class CachedRemoteImage extends StatefulWidget {
  const CachedRemoteImage({
    super.key,
    required this.url,
    this.width,
    this.height,
    this.fit = BoxFit.cover,
    this.placeholder,
    this.error,
    this.borderRadius,
  });

  final String url;
  final double? width;
  final double? height;
  final BoxFit fit;
  final Widget? placeholder;
  final Widget? error;
  final BorderRadius? borderRadius;

  @override
  State<CachedRemoteImage> createState() => _CachedRemoteImageState();
}

class _CachedRemoteImageState extends State<CachedRemoteImage> {
  File? _file;
  bool _failed = false;
  Object? _loadToken;

  @override
  void initState() {
    super.initState();
    _file = RemoteImageCache.peek(widget.url);
    if (_file == null) {
      _load();
    }
  }

  @override
  void didUpdateWidget(covariant CachedRemoteImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url) {
      _failed = false;
      _file = RemoteImageCache.peek(widget.url);
      if (_file == null) {
        _load();
      }
    }
  }

  Future<void> _load() async {
    final token = Object();
    _loadToken = token;
    final file = await RemoteImageCache.resolve(widget.url);
    if (!mounted || !identical(_loadToken, token)) return;
    setState(() {
      _file = file;
      _failed = file == null;
    });
  }

  @override
  Widget build(BuildContext context) {
    Widget child;
    if (_failed) {
      child = widget.error ??
          widget.placeholder ??
          SizedBox(width: widget.width, height: widget.height);
    } else if (_file != null) {
      child = Image.file(
        _file!,
        width: widget.width,
        height: widget.height,
        fit: widget.fit,
        gaplessPlayback: true,
        filterQuality: FilterQuality.medium,
        errorBuilder: (_, __, ___) =>
            widget.error ??
            widget.placeholder ??
            SizedBox(width: widget.width, height: widget.height),
      );
    } else {
      child = widget.placeholder ??
          SizedBox(
            width: widget.width,
            height: widget.height,
            child: const Center(
              child: SizedBox(
                width: 14,
                height: 14,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          );
    }

    if (widget.borderRadius != null) {
      return ClipRRect(borderRadius: widget.borderRadius!, child: child);
    }
    return child;
  }
}
