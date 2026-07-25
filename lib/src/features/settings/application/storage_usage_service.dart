import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/features/discover/data/translation_cache_hub.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

class StorageItem {
	final String id;
	final String title;
	final String description;
	final String path;
	final int bytes;
	final int fileCount;
	final bool clearable;
	final List<StorageItem> children;

	const StorageItem({
		required this.id,
		required this.title,
		required this.description,
		required this.path,
		required this.bytes,
		required this.fileCount,
		this.clearable = false,
		this.children = const [],
	});
}

class StorageGroup {
	final String id;
	final String title;
	final String description;
	final List<StorageItem> items;

	const StorageGroup({
		required this.id,
		required this.title,
		required this.description,
		required this.items,
	});

	int get bytes => items.fold(0, (sum, item) => sum + item.bytes);

	int get fileCount => items.fold(0, (sum, item) => sum + item.fileCount);

	bool get hasClearable => items.any(
		(item) => item.clearable || item.children.any((c) => c.clearable),
	);
}

class StorageUsageReport {
	final List<StorageGroup> groups;
	final int totalBytes;
	final int totalFiles;
	final DateTime scannedAt;

	const StorageUsageReport({
		required this.groups,
		required this.totalBytes,
		required this.totalFiles,
		required this.scannedAt,
	});

	Iterable<StorageItem> get clearableItems sync* {
		for (final group in groups) {
			for (final item in group.items) {
				if (item.clearable) yield item;
				for (final child in item.children) {
					if (child.clearable) yield child;
				}
			}
		}
	}
}

class _PathSpec {
	final String id;
	final String title;
	final String description;
	final String path;
	final bool isFile;
	final bool clearable;
	final List<String> excludeChildNames;
	final bool onlyFilesAtRoot;

	const _PathSpec({
		required this.id,
		required this.title,
		required this.description,
		required this.path,
		this.isFile = false,
		this.clearable = false,
		this.excludeChildNames = const [],
		this.onlyFilesAtRoot = false,
	});
}

/// Scans known AML data/cache directories for a detailed settings breakdown.
class StorageUsageService {
	static const cacheTtl = Duration(minutes: 3);

	StorageUsageReport? _cached;
	String? _cacheKey;
	DateTime? _cachedAt;

	StorageUsageReport? get cachedReport => _cached;

	void invalidate() {
		_cached = null;
		_cachedAt = null;
		_cacheKey = null;
	}

	bool get isCacheFresh {
		if (_cached == null || _cachedAt == null) return false;
		return DateTime.now().difference(_cachedAt!) < cacheTtl;
	}

	String _cacheKeyFor(String resourceRoot, String appData) =>
		'$resourceRoot|$appData';

	Future<StorageUsageReport> scan({bool force = false}) async {
		final resourceRoot =
			getIt<ResourceSettingsState>().resourceDirectory.value.trim();
		final appData = getIt<RuntimeState>().appDataDirectory.value?.trim() ?? '';
		final key = _cacheKeyFor(resourceRoot, appData);

		if (!force && isCacheFresh && _cacheKey == key && _cached != null) {
			return _cached!;
		}

		final report = await _scanInternal(resourceRoot, appData);
		_cached = report;
		_cacheKey = key;
		_cachedAt = report.scannedAt;
		return report;
	}

	Future<int> clearItem(String id) async {
		if (id.startsWith('i18n_')) {
			final cleared = await _clearTranslationItem(id);
			_cached = null;
			return cleared;
		}
		final match = (_cached ?? await scan()).clearableItems.where((i) => i.id == id);
		if (match.isEmpty) return 0;
		final item = match.first;
		await _deletePath(item.path);
		if (item.clearable) {
			await _ensureDirectory(item.path);
		}
		_cached = null;
		return 1;
	}

	Future<int> _clearTranslationItem(String id) async {
		switch (id) {
			case 'i18n_project':
				return TranslationCacheHub.clearProjectTitles();
			case 'i18n_text':
				return TranslationCacheHub.clearBodies();
			case 'i18n_memory':
				final n = TranslationCacheHub.memoryEntries;
				TranslationCacheHub.clearMemory();
				return n;
			case 'i18n_all':
				TranslationCacheHub.clearMemory();
				return TranslationCacheHub.clearAllPersistent();
			default:
				return 0;
		}
	}

	Future<int> clearAllClearable() async {
		final report = _cached ?? await scan();
		var cleared = 0;
		final paths = <String>{};
		var clearedI18n = false;
		for (final item in report.clearableItems) {
			if (item.id.startsWith('i18n_')) {
				if (clearedI18n) continue;
				clearedI18n = true;
				TranslationCacheHub.clearMemory();
				cleared += await TranslationCacheHub.clearAllPersistent();
				continue;
			}
			if (!paths.add(item.path)) continue;
			await _deletePath(item.path);
			await _ensureDirectory(item.path);
			cleared++;
		}
		_cached = null;
		return cleared;
	}

	static String formatBytes(int bytes) {
		if (bytes < 1024) return '$bytes B';
		final kb = bytes / 1024;
		if (kb < 1024) return '${kb.toStringAsFixed(1)} KB';
		final mb = kb / 1024;
		if (mb < 1024) return '${mb.toStringAsFixed(1)} MB';
		final gb = mb / 1024;
		return '${gb.toStringAsFixed(2)} GB';
	}

	static String formatScanAge(DateTime scannedAt) {
		final diff = DateTime.now().difference(scannedAt);
		if (diff.inSeconds < 60) return '刚刚';
		if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
		if (diff.inHours < 24) return '${diff.inHours} 小时前';
		return '${diff.inDays} 天前';
	}

	static Future<void> openInExplorer(String path) async {
		final trimmed = path.trim();
		if (trimmed.isEmpty) return;

		final type = await FileSystemEntity.type(trimmed, followLinks: false);
		if (type == FileSystemEntityType.notFound) return;

		if (Platform.isWindows) {
			if (type == FileSystemEntityType.file) {
				await Process.run('explorer', ['/select,', trimmed]);
			} else {
				await Process.run('explorer', [trimmed]);
			}
			return;
		}
		if (Platform.isMacOS) {
			final target = type == FileSystemEntityType.file
				? p.dirname(trimmed)
				: trimmed;
			await Process.run('open', [target]);
			return;
		}
		if (Platform.isLinux) {
			final target = type == FileSystemEntityType.file
				? p.dirname(trimmed)
				: trimmed;
			await Process.run('xdg-open', [target]);
		}
	}

	Future<StorageUsageReport> _scanInternal(
		String resourceRoot,
		String appData,
	) async {
		final groupFutures = <Future<StorageGroup>>[];

		if (resourceRoot.isNotEmpty) {
			groupFutures.addAll([
				_scanInstances(resourceRoot),
				_scanGameMeta(resourceRoot),
				_scanCaches(resourceRoot),
				_scanSkins(resourceRoot),
				_scanLauncherData(resourceRoot),
				_scanTranslationCache(resourceRoot),
			]);
		}

		if (appData.isNotEmpty) {
			groupFutures.addAll([
				_scanJava(appData),
				_scanAppCache(appData),
				Future.value(
					StorageGroup(
						id: 'settings',
						title: '设置文件',
						description: '本地配置 JSON',
						items: await _itemsFromSpecs([
							_PathSpec(
								id: 'ui_settings',
								title: '界面设置',
								description: 'ui_settings.json',
								path: p.join(appData, 'ui_settings.json'),
								isFile: true,
							),
							_PathSpec(
								id: 'java_settings',
								title: 'Java 设置',
								description: 'java_settings.json',
								path: p.join(appData, 'java_settings.json'),
								isFile: true,
							),
							_PathSpec(
								id: 'resource_settings',
								title: '资源目录设置',
								description: 'resource_settings.json',
								path: p.join(appData, 'resource_settings.json'),
								isFile: true,
							),
						]),
					),
				),
			]);
		}

		final groups = await Future.wait(groupFutures);
		final nonEmpty = groups
			.map(
				(g) => StorageGroup(
					id: g.id,
					title: g.title,
					description: g.description,
					items: [...g.items]..sort((a, b) => b.bytes.compareTo(a.bytes)),
				),
			)
			.where((g) => g.items.isNotEmpty)
			.toList()
			..sort((a, b) => b.bytes.compareTo(a.bytes));

		final totalBytes = nonEmpty.fold(0, (sum, g) => sum + g.bytes);
		final totalFiles = nonEmpty.fold(0, (sum, g) => sum + g.fileCount);

		return StorageUsageReport(
			groups: nonEmpty,
			totalBytes: totalBytes,
			totalFiles: totalFiles,
			scannedAt: DateTime.now(),
		);
	}

	Future<List<StorageItem>> _itemsFromSpecs(List<_PathSpec> specs) async {
		final items = await Future.wait(specs.map(_itemFromSpec));
		return items;
	}

	Future<StorageItem> _itemFromSpec(_PathSpec spec) async {
		final measured = await compute(
			_measurePathDetailed,
			_MeasureArgs(
				path: spec.path,
				isFile: spec.isFile,
				excludeChildNames: spec.excludeChildNames,
				onlyFilesAtRoot: spec.onlyFilesAtRoot,
			),
		);
		return StorageItem(
			id: spec.id,
			title: spec.title,
			description: spec.description,
			path: spec.path,
			bytes: measured.bytes,
			fileCount: measured.fileCount,
			clearable: spec.clearable,
		);
	}

	Future<StorageGroup> _scanInstances(String resourceRoot) async {
		final root = Directory(p.join(resourceRoot, 'instances'));
		final items = <StorageItem>[];

		if (await root.exists()) {
			final entries = root
				.listSync(followLinks: false)
				.whereType<Directory>()
				.toList();
			final breakdowns = await Future.wait(
				entries.map((dir) => compute(_measureInstanceBreakdown, dir.path)),
			);
			for (var i = 0; i < entries.length; i++) {
				final instanceDir = entries[i];
				final name = p.basename(instanceDir.path);
				final breakdown = breakdowns[i];
				items.add(
					StorageItem(
						id: 'instance:$name',
						title: name,
						description: breakdown.summary,
						path: instanceDir.path,
						bytes: breakdown.totalBytes,
						fileCount: breakdown.totalFiles,
						children: breakdown.parts
							.map(
								(part) => StorageItem(
									id: 'instance:$name:${part.id}',
									title: part.title,
									description: part.description,
									path: part.path,
									bytes: part.bytes,
									fileCount: part.fileCount,
								),
							)
							.toList(),
					),
				);
			}
		}

		if (items.isEmpty) {
			items.add(
				await _itemFromSpec(
					_PathSpec(
						id: 'instances_empty',
						title: '暂无实例',
						description: '创建实例后会显示详细占用',
						path: root.path,
					),
				),
			);
		}

		return StorageGroup(
			id: 'instances',
			title: '游戏实例',
			description: '按实例展开：模组 / 存档 / 备份 / 资源包 / 光影 / 日志等',
			items: items,
		);
	}

	Future<StorageGroup> _scanGameMeta(String resourceRoot) async {
		final meta = p.join(resourceRoot, 'meta');
		return StorageGroup(
			id: 'game_meta',
			title: '游戏本体与依赖',
			description: 'Libraries、Assets、版本与 natives',
			items: await _itemsFromSpecs([
				_PathSpec(
					id: 'libraries',
					title: 'Libraries',
					description: 'Minecraft / Loader 依赖库',
					path: p.join(meta, 'libraries'),
				),
				_PathSpec(
					id: 'assets_objects',
					title: 'Assets · objects',
					description: '声音、材质等资源对象',
					path: p.join(meta, 'assets', 'objects'),
				),
				_PathSpec(
					id: 'assets_indexes',
					title: 'Assets · indexes',
					description: '资源索引文件',
					path: p.join(meta, 'assets', 'indexes'),
				),
				_PathSpec(
					id: 'assets_other',
					title: 'Assets · 其他',
					description: 'assets 根目录其他文件',
					path: p.join(meta, 'assets'),
					excludeChildNames: const ['objects', 'indexes'],
				),
				_PathSpec(
					id: 'versions',
					title: 'Versions',
					description: '客户端版本 jar / json',
					path: p.join(meta, 'versions'),
				),
				_PathSpec(
					id: 'natives',
					title: 'Natives',
					description: '原生库解压目录',
					path: p.join(meta, 'natives'),
				),
				_PathSpec(
					id: 'log_configs',
					title: '日志配置',
					description: 'log4j 等配置',
					path: p.join(meta, 'log_configs'),
				),
				_PathSpec(
					id: 'meta_manifests',
					title: 'Manifest 缓存',
					description: '版本清单与 loader 清单',
					path: meta,
					onlyFilesAtRoot: true,
				),
				_PathSpec(
					id: 'meta_java_versions',
					title: 'meta/java_versions',
					description: '布局占位目录',
					path: p.join(meta, 'java_versions'),
				),
			]),
		);
	}

	Future<StorageGroup> _scanCaches(String resourceRoot) async {
		final cacheRoot = p.join(resourceRoot, 'cache');
		return StorageGroup(
			id: 'caches',
			title: '下载与图片缓存',
			description: '可清理的加速缓存',
			items: await _itemsFromSpecs([
				_PathSpec(
					id: 'icons_local',
					title: '实例图标缓存',
					description: 'cache/icons（不含 by-url）',
					path: p.join(cacheRoot, 'icons'),
					excludeChildNames: const ['by-url'],
					clearable: true,
				),
				_PathSpec(
					id: 'icons_remote',
					title: '远程图片缓存',
					description: '发现页等 CDN 图片',
					path: p.join(cacheRoot, 'icons', 'by-url'),
					clearable: true,
				),
				_PathSpec(
					id: 'mrpacks',
					title: '整合包缓存',
					description: '已下载的 .mrpack',
					path: p.join(cacheRoot, 'mrpacks'),
					clearable: true,
				),
				_PathSpec(
					id: 'cache_other',
					title: '其他 cache',
					description: 'cache 根目录其余内容',
					path: cacheRoot,
					excludeChildNames: const ['icons', 'mrpacks'],
					clearable: true,
				),
			]),
		);
	}

	Future<StorageGroup> _scanSkins(String resourceRoot) async {
		final skinsRoot = p.join(resourceRoot, 'skins');
		return StorageGroup(
			id: 'skins',
			title: '皮肤数据',
			description: '纹理缓存与自定义皮肤',
			items: await _itemsFromSpecs([
				_PathSpec(
					id: 'skins_cache',
					title: '皮肤纹理缓存',
					description: '从 Mojang 拉取的皮肤 PNG',
					path: p.join(skinsRoot, 'cache'),
					clearable: true,
				),
				_PathSpec(
					id: 'skins_custom',
					title: '自定义皮肤',
					description: '本地导入的皮肤文件',
					path: p.join(skinsRoot, 'custom'),
				),
				_PathSpec(
					id: 'skins_other',
					title: '皮肤目录其他',
					description: 'skins 根目录其余内容',
					path: skinsRoot,
					excludeChildNames: const ['cache', 'custom'],
				),
			]),
		);
	}

	Future<StorageGroup> _scanLauncherData(String resourceRoot) async {
		return StorageGroup(
			id: 'launcher_data',
			title: '启动器数据',
			description: '数据库与元数据',
			items: await _itemsFromSpecs([
				_PathSpec(
					id: 'database',
					title: 'app.db',
					description: '实例、账号等本地数据（含译名缓存表）',
					path: p.join(resourceRoot, 'app.db'),
					isFile: true,
				),
			]),
		);
	}

	Future<StorageGroup> _scanTranslationCache(String resourceRoot) async {
		final dbPath = p.join(resourceRoot, 'app.db');
		try {
			final stats = await TranslationCacheHub.persistentStats();
			final projectBytes = stats.projectBytes.toInt();
			final textBytes = stats.textBytes.toInt();
			final projectCount = stats.projectEntries.toInt();
			final textCount = stats.textEntries.toInt();
			final hits = stats.totalHits.toInt();
			final memory = TranslationCacheHub.memoryEntries;

			return StorageGroup(
				id: 'translation',
				title: '翻译缓存',
				description: '命中 $hits 次 · 会话内存 $memory 条',
				items: [
					StorageItem(
						id: 'i18n_project',
						title: '标题 / 简介缓存',
						description: '$projectCount 条 · 命中累计 $hits',
						path: dbPath,
						bytes: projectBytes,
						fileCount: projectCount,
						clearable: true,
					),
					StorageItem(
						id: 'i18n_text',
						title: '详情正文缓存',
						description: '$textCount 条',
						path: dbPath,
						bytes: textBytes,
						fileCount: textCount,
						clearable: true,
					),
					StorageItem(
						id: 'i18n_memory',
						title: '会话内存译文',
						description:
							'命中 ${TranslationCacheHub.memoryHits} / 未命中 ${TranslationCacheHub.memoryMisses}',
						path: dbPath,
						bytes: 0,
						fileCount: memory,
						clearable: true,
					),
				],
			);
		} catch (e) {
			debugPrint('scan translation cache failed: $e');
			return const StorageGroup(
				id: 'translation',
				title: '翻译缓存',
				description: '暂时无法读取（数据库未就绪）',
				items: [],
			);
		}
	}

	Future<StorageGroup> _scanJava(String appData) async {
		final javaRoot = Directory(p.join(appData, 'java'));
		final specs = <_PathSpec>[];
		if (await javaRoot.exists()) {
			for (final entry in javaRoot.listSync(followLinks: false)) {
				if (entry is! Directory) continue;
				final name = p.basename(entry.path);
				specs.add(
					_PathSpec(
						id: 'java:$name',
						title: name,
						description: '自动安装的 Java 运行时',
						path: entry.path,
					),
				);
			}
		}
		if (specs.isEmpty) {
			specs.add(
				_PathSpec(
					id: 'java_empty',
					title: '尚未安装',
					description: '自动安装 Java 后会显示在这里',
					path: javaRoot.path,
				),
			);
		}
		return StorageGroup(
			id: 'java',
			title: 'Java 运行时',
			description: '按安装目录拆分',
			items: await _itemsFromSpecs(specs),
		);
	}

	Future<StorageGroup> _scanAppCache(String appData) async {
		final cacheRoot = p.join(appData, 'cache');
		return StorageGroup(
			id: 'app_cache',
			title: '应用缓存',
			description: '头像与皮肤缩略图',
			items: await _itemsFromSpecs([
				_PathSpec(
					id: 'heads',
					title: '账号头像缓存',
					description: '皮肤头部缩略图',
					path: p.join(cacheRoot, 'heads'),
					clearable: true,
				),
				_PathSpec(
					id: 'skin_decode',
					title: '皮肤解码缓存',
					description: '衣橱用 PNG 缓存',
					path: p.join(cacheRoot, 'skins'),
					clearable: true,
				),
				_PathSpec(
					id: 'app_cache_other',
					title: '应用缓存其他',
					description: 'cache 根目录其余内容',
					path: cacheRoot,
					excludeChildNames: const ['heads', 'skins'],
					clearable: true,
				),
			]),
		);
	}

	Future<void> _deletePath(String path) async {
		final type = FileSystemEntity.typeSync(path, followLinks: false);
		if (type == FileSystemEntityType.directory) {
			final dir = Directory(path);
			if (await dir.exists()) {
				await dir.delete(recursive: true);
			}
		} else if (type == FileSystemEntityType.file) {
			final file = File(path);
			if (await file.exists()) {
				await file.delete();
			}
		}
	}

	Future<void> _ensureDirectory(String path) async {
		final dir = Directory(path);
		if (!await dir.exists()) {
			await dir.create(recursive: true);
		}
	}
}

class _MeasureArgs {
	final String path;
	final bool isFile;
	final List<String> excludeChildNames;
	final bool onlyFilesAtRoot;

	const _MeasureArgs({
		required this.path,
		this.isFile = false,
		this.excludeChildNames = const [],
		this.onlyFilesAtRoot = false,
	});
}

class _MeasureResult {
	final int bytes;
	final int fileCount;

	const _MeasureResult(this.bytes, this.fileCount);
}

class _InstancePart {
	final String id;
	final String title;
	final String description;
	final String path;
	final int bytes;
	final int fileCount;

	const _InstancePart({
		required this.id,
		required this.title,
		required this.description,
		required this.path,
		required this.bytes,
		required this.fileCount,
	});
}

class _InstanceBreakdown {
	final int totalBytes;
	final int totalFiles;
	final String summary;
	final List<_InstancePart> parts;

	const _InstanceBreakdown({
		required this.totalBytes,
		required this.totalFiles,
		required this.summary,
		required this.parts,
	});
}

_MeasureResult _measurePathDetailed(_MeasureArgs args) {
	try {
		if (args.isFile) {
			final file = File(args.path);
			if (!file.existsSync()) return const _MeasureResult(0, 0);
			return _MeasureResult(file.lengthSync(), 1);
		}

		final dir = Directory(args.path);
		if (!dir.existsSync()) return const _MeasureResult(0, 0);

		if (args.onlyFilesAtRoot) {
			var bytes = 0;
			var files = 0;
			for (final entity in dir.listSync(followLinks: false)) {
				if (entity is File) {
					try {
						bytes += entity.lengthSync();
						files++;
					} catch (_) {}
				}
			}
			return _MeasureResult(bytes, files);
		}

		final excluded = args.excludeChildNames.map((e) => e.toLowerCase()).toSet();
		var bytes = 0;
		var files = 0;

		for (final entity in dir.listSync(followLinks: false)) {
			final name = p.basename(entity.path).toLowerCase();
			if (excluded.contains(name)) continue;
			if (entity is File) {
				try {
					bytes += entity.lengthSync();
					files++;
				} catch (_) {}
			} else if (entity is Directory) {
				final nested = _measurePathDetailed(
					_MeasureArgs(path: entity.path),
				);
				bytes += nested.bytes;
				files += nested.fileCount;
			}
		}
		return _MeasureResult(bytes, files);
	} catch (_) {
		return const _MeasureResult(0, 0);
	}
}

_InstanceBreakdown _measureInstanceBreakdown(String instancePath) {
	const partsMeta = <(String, String, String)>[
		('mods', '模组', 'mods/'),
		('resourcepacks', '资源包', 'resourcepacks/'),
		('shaderpacks', '光影包', 'shaderpacks/'),
		('datapacks', '数据包', 'datapacks/'),
		('saves', '存档', 'saves/'),
		('backups', '备份', 'backups/'),
		('logs', '日志', 'logs/'),
	];

	final parts = <_InstancePart>[];
	var accountedBytes = 0;
	var accountedFiles = 0;

	for (final (id, title, folder) in partsMeta) {
		final path = p.join(instancePath, folder.replaceAll('/', ''));
		final measured = _measurePathDetailed(_MeasureArgs(path: path));
		parts.add(
			_InstancePart(
				id: id,
				title: title,
				description: folder,
				path: path,
				bytes: measured.bytes,
				fileCount: measured.fileCount,
			),
		);
		accountedBytes += measured.bytes;
		accountedFiles += measured.fileCount;
	}

	final total = _measurePathDetailed(_MeasureArgs(path: instancePath));
	final otherBytes = (total.bytes - accountedBytes).clamp(0, total.bytes);
	final otherFiles = (total.fileCount - accountedFiles).clamp(0, total.fileCount);
	if (otherBytes > 0) {
		parts.add(
			_InstancePart(
				id: 'other',
				title: '其他',
				description: '配置、截图等其余文件',
				path: instancePath,
				bytes: otherBytes,
				fileCount: otherFiles,
			),
		);
	}

	final nonZero = parts.where((e) => e.bytes > 0).toList()
		..sort((a, b) => b.bytes.compareTo(a.bytes));
	final summary = nonZero.isEmpty
		? '空实例'
		: nonZero
			.take(3)
			.map((e) => '${e.title} ${StorageUsageService.formatBytes(e.bytes)}')
			.join(' · ');

	return _InstanceBreakdown(
		totalBytes: total.bytes,
		totalFiles: total.fileCount,
		summary: summary,
		parts: nonZero,
	);
}
