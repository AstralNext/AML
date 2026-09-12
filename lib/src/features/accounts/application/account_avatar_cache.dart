import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/features/accounts/application/skin_head_renderer.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';

/// Disk + memory cache for account head thumbnails.
///
/// Keyed by account UUID so reopening the app shows heads immediately.
class AccountAvatarCache {
	AccountAvatarCache();

	final revision = signal(0);
	final Map<String, Uint8List> _memory = {};
	Directory? _dir;

	(int count, int bytes) memoryStats() {
		var bytes = 0;
		for (final png in _memory.values) {
			bytes += png.length;
		}
		return (_memory.length, bytes);
	}

	static String normalizeUuid(String uuid) =>
		uuid.trim().toLowerCase().replaceAll('-', '');

	Uint8List? peek(String accountUuid) {
		final key = normalizeUuid(accountUuid);
		if (key.isEmpty) return null;

		final mem = _memory[key];
		if (mem != null) return mem;

		final disk = _readDisk(key);
		if (disk != null) {
			_memory[key] = disk;
		}
		return disk;
	}

	Future<Uint8List?> ensureFromSkinPng(
		String accountUuid,
		Uint8List skinPng, {
		String? textureKey,
		bool force = false,
	}) async {
		final key = normalizeUuid(accountUuid);
		if (key.isEmpty || skinPng.isEmpty) return null;

		if (!force) {
			final existing = peek(key);
			if (existing != null) return existing;
		}

		final head = await renderSkinHeadPng(skinPng);
		if (head == null || head.isEmpty) return peek(key);

		_memory[key] = head;
		unawaited(_writeDisk(key, head));
		if (textureKey != null && textureKey.isNotEmpty) {
			unawaited(_writeDisk('tex_$textureKey', head));
		}
		_bumpRevision();
		return head;
	}

	void invalidate(String accountUuid) {
		final key = normalizeUuid(accountUuid);
		if (key.isEmpty) return;
		_memory.remove(key);
		try {
			final file = File(p.join(_cacheDir()?.path ?? '', '$key.png'));
			if (file.existsSync()) file.deleteSync();
		} catch (_) {}
		_bumpRevision();
	}

	void _bumpRevision() {
		// Avoid notifying listeners during a Flutter build frame.
		scheduleMicrotask(() => revision.value++);
	}

	Directory? _cacheDir() {
		if (_dir != null) return _dir;
		final root = getIt<RuntimeState>().appDataDirectory.value;
		if (root == null || root.isEmpty) return null;
		final dir = Directory(p.join(root, 'cache', 'heads'));
		try {
			dir.createSync(recursive: true);
		} catch (_) {
			return null;
		}
		_dir = dir;
		return dir;
	}

	Uint8List? _readDisk(String key) {
		final dir = _cacheDir();
		if (dir == null) return null;
		try {
			final file = File(p.join(dir.path, '$key.png'));
			if (!file.existsSync() || file.lengthSync() <= 0) return null;
			return file.readAsBytesSync();
		} catch (_) {
			return null;
		}
	}

	Future<void> _writeDisk(String key, Uint8List bytes) async {
		final dir = _cacheDir();
		if (dir == null) return;
		try {
			await File(p.join(dir.path, '$key.png')).writeAsBytes(bytes, flush: false);
		} catch (e) {
			debugPrint('account head cache write failed: $e');
		}
	}
}
