import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/application/storage_usage_service.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class ResourceSettingsPage extends StatefulWidget {
	const ResourceSettingsPage({super.key});

	@override
	State<ResourceSettingsPage> createState() => _ResourceSettingsPageState();
}

class _ResourceSettingsPageState extends State<ResourceSettingsPage> {
	late final ResourceSettingsState _resourceSettings =
		getIt<ResourceSettingsState>();
	late final StorageUsageService _storage =
		getIt.isRegistered<StorageUsageService>()
			? getIt<StorageUsageService>()
			: StorageUsageService();

	late TextEditingController _controller;
	StorageUsageReport? _report;
	bool _scanning = false;
	String? _clearingId;
	String? _error;
	final Set<String> _expandedGroups = {'caches'};

	@override
	void initState() {
		super.initState();
		_controller = TextEditingController();
		final cached = _storage.cachedReport;
		if (cached != null) {
			_report = cached;
		}
		unawaited(_refreshStorage(force: true));
	}

	@override
	void dispose() {
		_controller.dispose();
		super.dispose();
	}

	Future<void> _refreshStorage({bool force = false}) async {
		if (_scanning && !force) return;
		setState(() {
			_scanning = true;
			_error = null;
		});
		try {
			final report = await _storage.scan(force: force);
			if (!mounted) return;
			setState(() => _report = report);
		} catch (e) {
			if (!mounted) return;
			setState(() => _error = '$e');
		} finally {
			if (mounted) setState(() => _scanning = false);
		}
	}

	String _storageSubtitle(StorageUsageReport? report, int total) {
		if (report == null) return '正在细分扫描缓存与数据目录…';
		final age = StorageUsageService.formatScanAge(report.scannedAt);
		final base =
			'合计 ${StorageUsageService.formatBytes(total)}'
			' · ${report.totalFiles} 个文件'
			' · ${report.groups.length} 组'
			' · 扫描于 $age';
		if (_scanning) return '$base · 正在刷新…';
		return base;
	}

	Future<void> _openPath(StorageItem item) async {
		try {
			await StorageUsageService.openInExplorer(item.path);
		} catch (e) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('无法打开目录: $e')),
			);
		}
	}

	Future<void> _pickDirectory() async {
		try {
			final path = await FilePicker.platform.getDirectoryPath(
				dialogTitle: '选择数据目录',
			);
			if (path == null || path.isEmpty) return;
			_resourceSettings.resourceDirectory.value = path;
			_controller.text = path;
			unawaited(_refreshStorage(force: true));
		} catch (e) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('选择目录失败: $e')),
			);
		}
	}

	Future<void> _clearItem(StorageItem item) async {
		final confirmed = await showDialog<bool>(
			context: context,
			builder: (ctx) {
				final tokens = ctx.tokens;
				return AlertDialog(
					backgroundColor: tokens.colorRaisedBg,
					shape: RoundedRectangleBorder(
						borderRadius: BorderRadius.circular(12),
					),
					title: Text(
						'清理 ${item.title}？',
						style: TextStyle(
							color: tokens.colorContrast,
							fontWeight: FontWeight.w700,
						),
					),
					content: Text(
						'将删除可重建的缓存文件。下次加载时可能会稍慢。',
						style: TextStyle(color: tokens.colorBase),
					),
					actions: [
						NavRectButton(
							text: '取消',
							isSelected: false,
							onTap: () => Navigator.of(ctx).pop(false),
							onMouseEnter: () {},
							onMouseExit: () {},
						),
						const SizedBox(width: 8),
						NavRectButton(
							text: '清理',
							icon: Icons.delete_outline,
							isSelected: true,
							onTap: () => Navigator.of(ctx).pop(true),
							onMouseEnter: () {},
							onMouseExit: () {},
						),
					],
				);
			},
		);
		if (confirmed != true) return;

		setState(() => _clearingId = item.id);
		try {
			await _storage.clearItem(item.id);
			await _refreshStorage(force: true);
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('已清理 ${item.title}')),
			);
		} catch (e) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('清理失败: $e')),
			);
		} finally {
			if (mounted) setState(() => _clearingId = null);
		}
	}

	Future<void> _clearAllCaches() async {
		final confirmed = await showDialog<bool>(
			context: context,
			builder: (ctx) {
				final tokens = ctx.tokens;
				return AlertDialog(
					backgroundColor: tokens.colorRaisedBg,
					shape: RoundedRectangleBorder(
						borderRadius: BorderRadius.circular(12),
					),
					title: Text(
						'清理全部可重建缓存？',
						style: TextStyle(
							color: tokens.colorContrast,
							fontWeight: FontWeight.w700,
						),
					),
					content: Text(
						'将清理图标、整合包、皮肤纹理缓存和应用缓存。实例、Libraries、Assets 不会被删除。',
						style: TextStyle(color: tokens.colorBase),
					),
					actions: [
						NavRectButton(
							text: '取消',
							isSelected: false,
							onTap: () => Navigator.of(ctx).pop(false),
							onMouseEnter: () {},
							onMouseExit: () {},
						),
						const SizedBox(width: 8),
						NavRectButton(
							text: '全部清理',
							icon: Icons.delete_sweep_outlined,
							isSelected: true,
							onTap: () => Navigator.of(ctx).pop(true),
							onMouseEnter: () {},
							onMouseExit: () {},
						),
					],
				);
			},
		);
		if (confirmed != true) return;

		setState(() => _clearingId = '__all__');
		try {
			await _storage.clearAllClearable();
			await _refreshStorage(force: true);
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				const SnackBar(content: Text('已清理可重建缓存')),
			);
		} catch (e) {
			if (!mounted) return;
			ScaffoldMessenger.of(context).showSnackBar(
				SnackBar(content: Text('清理失败: $e')),
			);
		} finally {
			if (mounted) setState(() => _clearingId = null);
		}
	}

	void _toggleGroup(String id) {
		setState(() {
			if (_expandedGroups.contains(id)) {
				_expandedGroups.remove(id);
			} else {
				_expandedGroups.add(id);
			}
		});
	}

	@override
	Widget build(BuildContext context) {
		final tokens = context.tokens;
		final report = _report;
		final total = report?.totalBytes ?? 0;

		return ListView(
			padding: const EdgeInsets.fromLTRB(16, 10, 24, 16),
			children: [
				Text(
					'数据目录',
					style: TextStyle(
						fontSize: 18,
						fontWeight: FontWeight.w600,
						color: tokens.colorContrast,
					),
				),
				const SizedBox(height: 6),
				Text(
					'游戏资源、实例与缓存的存放位置',
					style: TextStyle(
						fontSize: 13,
						color: tokens.colorBase.withValues(alpha: 0.7),
					),
				),
				const SizedBox(height: 10),
				Row(
					children: [
						Expanded(
							child: Watch(
								(_) {
									final currentPath =
										_resourceSettings.resourceDirectory.watch(context);
									if (_controller.text != currentPath) {
										WidgetsBinding.instance.addPostFrameCallback((_) {
											if (_controller.text != currentPath) {
												_controller.text = currentPath;
											}
										});
									}
									return InputBarWidget(
										colorScheme: Theme.of(context).colorScheme,
										size: InputBarSize.medium,
										hintText: '选择数据目录路径',
										controller: _controller,
										onChanged: (value) {
											_resourceSettings.resourceDirectory.value = value;
										},
									);
								},
							),
						),
						const SizedBox(width: 10),
						NavRectButton(
							text: '浏览',
							padding: const EdgeInsets.symmetric(horizontal: 5),
							icon: Icons.folder_open,
							isSelected: false,
							width: 80,
							onMouseEnter: () {},
							onMouseExit: () {},
							onTap: _pickDirectory,
						),
					],
				),
				const SizedBox(height: 28),
				Row(
					children: [
						Expanded(
							child: Column(
								crossAxisAlignment: CrossAxisAlignment.start,
								children: [
									Text(
										'储存占用',
										style: TextStyle(
											fontSize: 18,
											fontWeight: FontWeight.w600,
											color: tokens.colorContrast,
										),
									),
									const SizedBox(height: 4),
									Text(
										_storageSubtitle(report, total),
										style: TextStyle(
											fontSize: 13,
											color: tokens.colorBase.withValues(alpha: 0.7),
										),
									),
								],
							),
						),
						NavRectButton(
							text: _scanning ? '分析中' : '刷新',
							icon: Icons.refresh,
							isSelected: false,
							onTap: _scanning
								? () {}
								: () => _refreshStorage(force: true),
							onMouseEnter: () {},
							onMouseExit: () {},
						),
						const SizedBox(width: 8),
						NavRectButton(
							text: '清理缓存',
							icon: Icons.delete_sweep_outlined,
							isSelected: false,
							onTap: (_scanning || _clearingId != null)
								? () {}
								: _clearAllCaches,
							onMouseEnter: () {},
							onMouseExit: () {},
						),
					],
				),
				const SizedBox(height: 12),
				if (_error != null)
					Padding(
						padding: const EdgeInsets.only(bottom: 8),
						child: Text(
							_error!,
							style: TextStyle(color: Colors.red.shade400, fontSize: 13),
						),
					),
				if (_scanning && report == null)
					const Padding(
						padding: EdgeInsets.symmetric(vertical: 24),
						child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
					)
				else if (report != null)
					...report.groups.map(
						(group) => _StorageGroupCard(
							group: group,
							totalBytes: total,
							expanded: _expandedGroups.contains(group.id),
							clearingId: _clearingId,
							onToggle: () => _toggleGroup(group.id),
							onClear: _clearingId == null ? _clearItem : null,
							onOpenPath: _openPath,
						),
					),
			],
		);
	}
}

class _StorageGroupCard extends StatelessWidget {
	const _StorageGroupCard({
		required this.group,
		required this.totalBytes,
		required this.expanded,
		required this.clearingId,
		required this.onToggle,
		this.onClear,
		this.onOpenPath,
	});

	final StorageGroup group;
	final int totalBytes;
	final bool expanded;
	final String? clearingId;
	final VoidCallback onToggle;
	final Future<void> Function(StorageItem item)? onClear;
	final Future<void> Function(StorageItem item)? onOpenPath;

	@override
	Widget build(BuildContext context) {
		final tokens = context.tokens;
		final groupRatio = totalBytes <= 0
			? 0.0
			: (group.bytes / totalBytes).clamp(0.0, 1.0);

		return Padding(
			padding: const EdgeInsets.only(bottom: 12),
			child: Container(
				decoration: BoxDecoration(
					color: tokens.colorBg.withValues(alpha: 0.35),
					borderRadius: BorderRadius.circular(12),
					border: Border.all(
						color: tokens.colorSecondary.withValues(alpha: 0.2),
					),
				),
				child: Column(
					children: [
						InkWell(
							borderRadius: BorderRadius.circular(12),
							onTap: onToggle,
							child: Padding(
								padding: const EdgeInsets.fromLTRB(12, 12, 12, 10),
								child: Column(
									crossAxisAlignment: CrossAxisAlignment.start,
									children: [
										Row(
											children: [
												Icon(
													expanded
														? Icons.expand_more
														: Icons.chevron_right,
													size: 20,
													color: tokens.colorContrast,
												),
												const SizedBox(width: 4),
												Expanded(
													child: Column(
														crossAxisAlignment: CrossAxisAlignment.start,
														children: [
															Text(
																group.title,
																style: TextStyle(
																	fontSize: 15,
																	fontWeight: FontWeight.w700,
																	color: tokens.colorContrast,
																),
															),
															const SizedBox(height: 2),
															Text(
																'${group.description}'
																' · ${group.items.length} 项'
																' · ${group.fileCount} 文件',
																style: TextStyle(
																	fontSize: 12,
																	color: tokens.colorBase.withValues(
																		alpha: 0.65,
																	),
																),
															),
														],
													),
												),
												Column(
													crossAxisAlignment: CrossAxisAlignment.end,
													children: [
														Text(
															StorageUsageService.formatBytes(group.bytes),
															style: TextStyle(
																fontSize: 14,
																fontWeight: FontWeight.w700,
																color: tokens.colorBrand,
															),
														),
														Text(
															totalBytes <= 0
																? '0%'
																: '${(groupRatio * 100).toStringAsFixed(1)}%',
															style: TextStyle(
																fontSize: 11,
																color: tokens.colorBase.withValues(
																	alpha: 0.6,
																),
															),
														),
													],
												),
											],
										),
										const SizedBox(height: 8),
										ClipRRect(
											borderRadius: BorderRadius.circular(999),
											child: LinearProgressIndicator(
												value: groupRatio,
												minHeight: 6,
												backgroundColor: tokens.colorSecondary.withValues(
													alpha: 0.15,
												),
												color: tokens.colorBrand,
											),
										),
									],
								),
							),
						),
						if (expanded)
							Padding(
								padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
								child: Column(
									children: [
										for (final item in group.items)
											_StorageItemTile(
												item: item,
												parentBytes: group.bytes,
												clearingId: clearingId,
												onClear: onClear,
												onOpenPath: onOpenPath,
												depth: 0,
												initiallyExpanded: false,
											),
									],
								),
							),
					],
				),
			),
		);
	}
}

class _StorageItemTile extends StatefulWidget {
	const _StorageItemTile({
		required this.item,
		required this.parentBytes,
		required this.clearingId,
		this.onClear,
		this.onOpenPath,
		required this.depth,
		this.initiallyExpanded = false,
	});

	final StorageItem item;
	final int parentBytes;
	final String? clearingId;
	final Future<void> Function(StorageItem item)? onClear;
	final Future<void> Function(StorageItem item)? onOpenPath;
	final int depth;
	final bool initiallyExpanded;

	@override
	State<_StorageItemTile> createState() => _StorageItemTileState();
}

class _StorageItemTileState extends State<_StorageItemTile> {
	late bool _expanded = widget.initiallyExpanded;

	@override
	void didUpdateWidget(covariant _StorageItemTile oldWidget) {
		super.didUpdateWidget(oldWidget);
		if (oldWidget.item.id != widget.item.id) {
			_expanded = widget.initiallyExpanded;
		}
	}

	@override
	Widget build(BuildContext context) {
		final tokens = context.tokens;
		final item = widget.item;
		final ratio = widget.parentBytes <= 0
			? 0.0
			: (item.bytes / widget.parentBytes).clamp(0.0, 1.0);
		final clearing = widget.clearingId == item.id;
		final hasChildren = item.children.isNotEmpty;

		return Padding(
			padding: EdgeInsets.only(left: widget.depth * 10.0, top: 6),
			child: Container(
				padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
				decoration: BoxDecoration(
					color: tokens.colorRaisedBg.withValues(alpha: 0.35),
					borderRadius: BorderRadius.circular(8),
				),
				child: Column(
					crossAxisAlignment: CrossAxisAlignment.start,
					children: [
						InkWell(
							borderRadius: BorderRadius.circular(6),
							onTap: hasChildren
								? () => setState(() => _expanded = !_expanded)
								: null,
							child: Row(
								children: [
									if (hasChildren)
										Icon(
											_expanded ? Icons.expand_more : Icons.chevron_right,
											size: 18,
											color: tokens.colorContrast,
										)
									else
										const SizedBox(width: 18),
									const SizedBox(width: 2),
									Expanded(
										child: Column(
											crossAxisAlignment: CrossAxisAlignment.start,
											children: [
												Text(
													item.title,
													style: TextStyle(
														fontSize: widget.depth == 0 ? 13.5 : 12.5,
														fontWeight: FontWeight.w600,
														color: tokens.colorContrast,
													),
												),
												const SizedBox(height: 2),
												Text(
													'${item.description}'
													' · ${item.fileCount} 文件'
													' · ${(ratio * 100).toStringAsFixed(1)}%'
													'${hasChildren ? ' · ${item.children.length} 项' : ''}',
													style: TextStyle(
														fontSize: 11,
														color: tokens.colorBase.withValues(alpha: 0.6),
													),
												),
											],
										),
									),
									Text(
										StorageUsageService.formatBytes(item.bytes),
										style: TextStyle(
											fontSize: 12.5,
											fontWeight: FontWeight.w700,
											color: tokens.colorBrand,
										),
									),
									if (widget.onOpenPath != null) ...[
										const SizedBox(width: 4),
										NavRectButton(
											icon: Icons.folder_open_outlined,
											isSelected: false,
											onTap: () => widget.onOpenPath!(item),
											onMouseEnter: () {},
											onMouseExit: () {},
										),
									],
									if (item.clearable && widget.onClear != null) ...[
										const SizedBox(width: 6),
										NavRectButton(
											text: clearing ? '…' : '清理',
											icon: Icons.delete_outline,
											isSelected: false,
											onTap: clearing
												? () {}
												: () => widget.onClear!(item),
											onMouseEnter: () {},
											onMouseExit: () {},
										),
									],
								],
							),
						),
						const SizedBox(height: 6),
						ClipRRect(
							borderRadius: BorderRadius.circular(999),
							child: LinearProgressIndicator(
								value: ratio,
								minHeight: 4,
								backgroundColor:
									tokens.colorSecondary.withValues(alpha: 0.12),
								color: tokens.colorBrand.withValues(alpha: 0.85),
							),
						),
						if (hasChildren && _expanded)
							...item.children.map(
								(child) => _StorageItemTile(
									item: child,
									parentBytes: item.bytes,
									clearingId: widget.clearingId,
									onClear: widget.onClear,
									onOpenPath: widget.onOpenPath,
									depth: widget.depth + 1,
									initiallyExpanded: false,
								),
							),
					],
				),
			),
		);
	}
}
