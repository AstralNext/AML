import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';

class SkinStore {
  SkinStore();

  final skins = signal<List<rust.SkinDto>>([]);
  final capes = signal<List<rust.CapeDto>>([]);
  final loading = signal(false);
  final applying = signal(false);
  final error = signal<String?>(null);
  final previewBytes = signal<Uint8List?>(null);

  final Map<String, Uint8List> _pngCache = {};
  Future<void>? _refreshInflight;
  Directory? _diskCacheDir;

  /// Memory probe：当前 PNG 内存缓存条目数与总字节。
  (int count, int bytes) pngCacheStats() {
    var bytes = 0;
    for (final png in _pngCache.values) {
      bytes += png.length;
    }
    return (_pngCache.length, bytes);
  }

  List<rust.SkinDto> get savedSkins =>
      skins.value.where((s) => s.source != 'default').toList();

  rust.SkinDto? get equipped {
    for (final s in skins.value) {
      if (s.isEquipped) return s;
    }
    return null;
  }

  /// Show cached list immediately; only block when we have nothing yet.
  Future<void> ensureLoaded() async {
    if (skins.value.isNotEmpty) {
      unawaited(refresh(background: true));
      return;
    }
    await refresh();
  }

  Future<void> refresh({bool background = false}) {
    final existing = _refreshInflight;
    if (existing != null) return existing;
    final future = _refresh(background: background);
    _refreshInflight = future.whenComplete(() => _refreshInflight = null);
    return future;
  }

  Future<void> _refresh({required bool background}) async {
    if (!background) loading.value = true;
    error.value = null;
    try {
      final list = await rust.listAvailableSkins();
      skins.value = list;
      final keys = list.map((s) => s.textureKey).toSet();
      _pngCache.removeWhere((k, _) => !keys.contains(k));
      // Capes are optional and slow — never block the skin grid on them.
      unawaited(_refreshCapes());
      unawaited(_warmActiveAccountHead());
    } catch (e) {
      error.value = e.toString();
      debugPrint('listAvailableSkins failed: $e');
    } finally {
      if (!background) loading.value = false;
    }
  }

  /// Bake + cache the equipped skin as a head thumbnail for the active account.
  Future<void> warmAccountHead(String accountUuid) =>
      _warmHeadForUuid(accountUuid);

  Future<void> _warmActiveAccountHead() async {
    try {
      final accounts = getIt<AccountStore>();
      final active = accounts.activeAccount;
      if (active == null) return;
      await _warmHeadForUuid(active.uuid);
    } catch (e) {
      debugPrint('warm active account head failed: $e');
    }
  }

  Future<void> _warmHeadForUuid(String accountUuid) async {
    final equippedSkin = equipped;
    if (equippedSkin == null) return;
    final png = pngBytesFor(equippedSkin);
    if (png == null || png.isEmpty) return;
    await getIt<AccountAvatarCache>().ensureFromSkinPng(
      accountUuid,
      png,
      textureKey: equippedSkin.textureKey,
      force: true,
    );
  }

  Future<void> _refreshCapes() async {
    try {
      capes.value = await rust.listAvailableCapes();
    } catch (_) {
      capes.value = [];
    }
  }

  Uint8List? pngBytesFor(rust.SkinDto skin) {
    final cached = _pngCache[skin.textureKey];
    if (cached != null) return cached;

    final fromDisk = _readDiskCache(skin.textureKey);
    if (fromDisk != null) {
      _pngCache[skin.textureKey] = fromDisk;
      return fromDisk;
    }

    final decoded = decodeDataUrl(skin.textureDataUrl);
    if (decoded != null) {
      _pngCache[skin.textureKey] = decoded;
      unawaited(_writeDiskCache(skin.textureKey, decoded));
    }
    return decoded;
  }

  Directory? _cacheDir() {
    if (_diskCacheDir != null) return _diskCacheDir;
    final root = getIt<RuntimeState>().appDataDirectory.value;
    if (root == null || root.isEmpty) return null;
    final dir = Directory(p.join(root, 'cache', 'skins'));
    try {
      dir.createSync(recursive: true);
    } catch (_) {
      return null;
    }
    _diskCacheDir = dir;
    return dir;
  }

  Uint8List? _readDiskCache(String textureKey) {
    final dir = _cacheDir();
    if (dir == null) return null;
    final file = File(p.join(dir.path, '$textureKey.png'));
    try {
      if (!file.existsSync()) return null;
      return file.readAsBytesSync();
    } catch (_) {
      return null;
    }
  }

  Future<void> _writeDiskCache(String textureKey, Uint8List bytes) async {
    final dir = _cacheDir();
    if (dir == null) return;
    try {
      await File(p.join(dir.path, '$textureKey.png')).writeAsBytes(bytes, flush: false);
    } catch (_) {}
  }

  Future<void> bakePreview(rust.SkinDto skin, {int scale = 8}) async {
    try {
      previewBytes.value = await rust.bakeSkinPreview(
        textureDataUrl: skin.textureDataUrl,
        variant: skin.variant,
        scale: scale,
      );
    } catch (e) {
      debugPrint('bakeSkinPreview failed: $e');
      previewBytes.value = pngBytesFor(skin);
    }
  }

  Future<void> apply(rust.SkinDto skin) async {
    applying.value = true;
    error.value = null;
    try {
      await rust.equipSkin(
        textureKey: skin.textureKey,
        variant: skin.variant,
        capeId: skin.capeId,
        textureDataUrl: skin.textureDataUrl,
      );
      await refresh();
    } catch (e) {
      error.value = e.toString();
      rethrow;
    } finally {
      applying.value = false;
    }
  }

  Future<rust.SkinDto?> pickAndAddSkin() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.first;
    final bytes = file.bytes;
    if (bytes == null || bytes.isEmpty) {
      throw Exception('无法读取皮肤文件');
    }
    final variant = await rust.detectSkinVariant(pngBytes: bytes);
    final saved = await rust.saveCustomSkin(
      pngBytes: bytes,
      name: file.name.replaceAll(RegExp(r'\.png$', caseSensitive: false), ''),
      variant: variant,
      capeId: null,
    );
    await refresh();
    return saved;
  }

  Future<void> remove(rust.SkinDto skin) async {
    if (skin.source != 'custom') return;
    await rust.removeCustomSkin(textureKey: skin.textureKey);
    await refresh();
  }

  static Uint8List? decodeDataUrl(String dataUrl) {
    if (!dataUrl.startsWith('data:image')) return null;
    final comma = dataUrl.indexOf(',');
    if (comma < 0) return null;
    try {
      return Uint8List.fromList(base64Decode(dataUrl.substring(comma + 1)));
    } catch (_) {
      return null;
    }
  }
}
