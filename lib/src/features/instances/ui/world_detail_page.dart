import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/world_backup_actions.dart';
import 'package:aml/src/features/instances/ui/world_map_viewer.dart';
import 'package:aml/src/features/settings/application/storage_usage_service.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/buttons/button_group_widget.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class WorldDetailPage extends StatefulWidget {
  const WorldDetailPage({
    super.key,
    required this.instanceId,
    required this.world,
  });

  final String instanceId;
  final SelectedWorld world;

  @override
  State<WorldDetailPage> createState() => _WorldDetailPageState();
}

class _WorldDetailPageState extends State<WorldDetailPage> {
  static const _chunksPerTile = 8;
  static const _tilePixels = _chunksPerTile * 16;

  bool _starting = false;
  bool _loadingMap = true;
  String? _mapError;
  int _viewerKey = 0;
  int _mapGeneration = 0;
  bool _mapRepaintScheduled = false;
  final Map<(int, int), WorldMapChunkImage> _mapChunks = {};
  final Map<(int, int), Uint8List> _mapTilePixels = {};
  int? _minChunkX;
  int? _minChunkZ;
  int? _maxChunkX;
  int? _maxChunkZ;
  double? _mapProgress;

  List<rust.WorldBackupDto> _backups = [];
  bool _loadingBackups = true;
  bool _backingUp = false;
  String? _busyBackupPath;
  late int _tab; // 0 map, 1 backups
  rust.WorldBackupDto? _selectedBackup;

  InstanceStore get _store => getIt<InstanceStore>();
  NavigationState get _nav => getIt<NavigationState>();

  @override
  void initState() {
    super.initState();
    _tab = widget.world.initialTab.clamp(0, 1);
    unawaited(_loadMap());
    unawaited(_loadBackups());
  }

  @override
  void didUpdateWidget(covariant WorldDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.instanceId != widget.instanceId ||
        oldWidget.world.folder != widget.world.folder) {
      _viewerKey++;
      unawaited(_loadMap());
      unawaited(_loadBackups());
    }
  }

  @override
  void dispose() {
    _mapGeneration++;
    for (final chunk in _mapChunks.values) {
      chunk.dispose();
    }
    super.dispose();
  }

  void _scheduleMapRepaint() {
    if (_mapRepaintScheduled || !mounted) return;
    _mapRepaintScheduled = true;
    WidgetsBinding.instance.scheduleFrameCallback((_) {
      _mapRepaintScheduled = false;
      if (mounted) setState(() => _viewerKey++);
    });
  }

  Future<void> _loadBackups({bool selectLatest = false}) async {
    setState(() => _loadingBackups = true);
    try {
      final list = await _store.listWorldBackups(
        widget.instanceId,
        widget.world.folder,
      );
      if (!mounted) return;
      setState(() {
        _backups = list;
        _loadingBackups = false;
        if (selectLatest && list.isNotEmpty) {
          _selectedBackup = list.first;
        } else if (_selectedBackup != null &&
            !list.any((b) => b.path == _selectedBackup!.path)) {
          _selectedBackup = list.isNotEmpty ? list.first : null;
        } else if (_selectedBackup == null && list.isNotEmpty) {
          _selectedBackup = list.first;
        }
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingBackups = false);
      showAppSnackBar('加载备份失败: $e', isError: true);
    }
  }

  void _selectBackup(rust.WorldBackupDto backup) {
    setState(() => _selectedBackup = backup);
  }

  Future<void> _createBackup() async {
    if (_backingUp) return;
    final options = await showWorldBackupCreateDialog(context);
    if (options == null || !mounted) return;

    setState(() => _backingUp = true);
    try {
      await _store.backupWorld(
        widget.instanceId,
        widget.world.folder,
        kind: 'full',
        compression: options.compression,
      );
      if (!mounted) return;
      showAppSnackBar('备份已创建');
      await _loadBackups(selectLatest: true);
    } catch (e) {
      if (mounted) showAppSnackBar('备份失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _backingUp = false);
    }
  }

  Future<void> _restoreBackup(rust.WorldBackupDto backup) async {
    final kindLabel = backup.kind == 'incremental' ? '增量' : '完整';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('回溯到此版本'),
        content: Text(
          '将世界恢复到 ${backup.createdAt}（$kindLabel'
          '${backup.auto ? ' · 自动' : ''}）。\n'
          '当前存档会先另存为安全备份。请先退出游戏中的该世界。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('回溯'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyBackupPath = backup.path);
    try {
      await _store.restoreWorldBackup(widget.instanceId, backup.path);
      if (!mounted) return;
      showAppSnackBar('已回溯到 ${backup.createdAt}');
      await _loadBackups();
      unawaited(_loadMap());
    } catch (e) {
      if (mounted) showAppSnackBar('回溯失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyBackupPath = null);
    }
  }

  Future<void> _deleteBackup(rust.WorldBackupDto backup) async {
    final cascade = backup.kind == 'full'
        ? '\n删除完整备份时，依赖它的增量备份也会一并删除。'
        : '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除备份'),
        content: Text('确定删除 ${backup.createdAt} 的备份？$cascade'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('删除'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _busyBackupPath = backup.path);
    try {
      await _store.deleteWorldBackup(widget.instanceId, backup.path);
      if (!mounted) return;
      showAppSnackBar('备份已删除');
      await _loadBackups();
    } catch (e) {
      if (mounted) showAppSnackBar('删除失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyBackupPath = null);
    }
  }

  Future<void> _loadMap() async {
    final generation = ++_mapGeneration;
    final oldChunks = _mapChunks.values.toList();
    _mapChunks.clear();
    _mapTilePixels.clear();
    setState(() {
      _loadingMap = true;
      _mapError = null;
      _mapProgress = null;
      _minChunkX = null;
      _minChunkZ = null;
      _maxChunkX = null;
      _maxChunkZ = null;
      _viewerKey++;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      for (final chunk in oldChunks) {
        chunk.dispose();
      }
    });
    try {
      await rust.streamWorldMapPreview(
        instanceId: widget.instanceId,
        folder: widget.world.folder,
        onEvent: (event) async {
          if (!mounted || generation != _mapGeneration) return false;
          final chunk = event.chunk;
          WorldMapChunkImage? image;
          (int, int)? imageKey;
          if (chunk != null) {
            final tileX = (chunk.chunkX / _chunksPerTile).floor();
            final tileZ = (chunk.chunkZ / _chunksPerTile).floor();
            imageKey = (tileX, tileZ);
            final pixels = _mapTilePixels.putIfAbsent(
              imageKey,
              () => Uint8List(_tilePixels * _tilePixels * 4),
            );
            final localChunkX = chunk.chunkX - tileX * _chunksPerTile;
            final localChunkZ = chunk.chunkZ - tileZ * _chunksPerTile;
            for (var row = 0; row < 16; row++) {
              final sourceStart = row * 16 * 4;
              final targetStart =
                  ((localChunkZ * 16 + row) * _tilePixels + localChunkX * 16) *
                      4;
              pixels.setRange(
                targetStart,
                targetStart + 16 * 4,
                chunk.rgba,
                sourceStart,
              );
            }
            image = await WorldMapChunkImage.fromRgba(
              tileX * _chunksPerTile,
              tileZ * _chunksPerTile,
              pixels,
              _tilePixels,
            );
          }
          if (!mounted || generation != _mapGeneration) {
            image?.dispose();
            return false;
          }
          _mapProgress = event.chunksTotal == 0
              ? null
              : event.chunksDone / event.chunksTotal;
          if (image != null && chunk != null) {
            final previous = _mapChunks.remove(imageKey);
            _mapChunks[imageKey!] = image;
            if (previous != null) {
              WidgetsBinding.instance.addPostFrameCallback(
                (_) => previous.dispose(),
              );
            }
            // Bounds from actual content only (not empty region file extents).
            _minChunkX = _minChunkX == null
                ? chunk.chunkX
                : (_minChunkX! < chunk.chunkX ? _minChunkX : chunk.chunkX);
            _minChunkZ = _minChunkZ == null
                ? chunk.chunkZ
                : (_minChunkZ! < chunk.chunkZ ? _minChunkZ : chunk.chunkZ);
            _maxChunkX = _maxChunkX == null
                ? chunk.chunkX
                : (_maxChunkX! > chunk.chunkX ? _maxChunkX : chunk.chunkX);
            _maxChunkZ = _maxChunkZ == null
                ? chunk.chunkZ
                : (_maxChunkZ! > chunk.chunkZ ? _maxChunkZ : chunk.chunkZ);
          }
          if (event.done) _loadingMap = false;
          _scheduleMapRepaint();
          return true;
        },
      );
      if (!mounted || generation != _mapGeneration) return;
      if (_loadingMap) {
        _loadingMap = false;
        _scheduleMapRepaint();
      }
    } catch (e) {
      if (!mounted || generation != _mapGeneration) return;
      setState(() {
        _mapError = '$e';
        _loadingMap = false;
      });
    }
  }

  Future<void> _playOrStop() async {
    if (_starting) return;
    final running = _store.isRunning(widget.instanceId);
    setState(() => _starting = true);
    try {
      if (running) {
        await _store.kill(widget.instanceId);
      } else {
        if (!await ensureAccountForLaunch(context)) return;
        await _store.launch(
          widget.instanceId,
          quickPlaySingleplayer: widget.world.folder,
        );
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  String _gameModeLabel() {
    return switch (widget.world.gameMode) {
      'creative' => '创造',
      'adventure' => '冒险',
      'spectator' => '旁观',
      _ => '生存',
    };
  }

  String _formatSize(BigInt bytes) {
    final n = bytes.toInt();
    return StorageUsageService.formatBytes(n < 0 ? 0 : n);
  }

  String _kindLabel(String kind) =>
      kind == 'incremental' ? '增量' : '完整';

  String _compressionLabel(String compression) => switch (compression) {
        'store' => '不压缩',
        'fast' => '快速',
        'max' => '最大',
        _ => '均衡',
      };

  @override
  Widget build(BuildContext context) {
    return Watch((context) {
      final tokens = context.tokens;
      final running = _store.runningIds.value.contains(widget.instanceId);
      final backupLabel = _loadingBackups
          ? '备份'
          : '备份${_backups.isEmpty ? '' : ' (${_backups.length})'}';

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 16, 8),
            child: Row(
              children: [
                IconButton(
                  tooltip: '返回',
                  onPressed: _nav.closeWorld,
                  icon: Icon(Icons.arrow_back, color: tokens.colorContrast),
                ),
                const SizedBox(width: 4),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        widget.world.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          '单人世界',
                          _gameModeLabel(),
                          if (widget.world.hardcore) '极限',
                          if (running) '运行中',
                        ].join(' · '),
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                if (_tab == 1) ...[
                  NavRectButton(
                    isSelected: false,
                    icon: Icons.backup_outlined,
                    text: _backingUp ? '备份中…' : '备份',
                    label: '创建世界备份',
                    defaultBackgroundColor: tokens.colorButtonBg,
                    defaultColor: tokens.colorContrast,
                    hoverColor: tokens.colorButtonBgSelected,
                    hoverTextColor: tokens.colorButtonTextSelected,
                    onTap:
                        _backingUp ? () {} : () => unawaited(_createBackup()),
                  ),
                  const SizedBox(width: 8),
                ],
                if (_tab == 0) ...[
                  TextButton.icon(
                    onPressed:
                        _loadingMap ? null : () => unawaited(_loadMap()),
                    icon: const Icon(Icons.refresh, size: 16),
                    label: const Text('刷新'),
                    style: TextButton.styleFrom(
                      foregroundColor: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(width: 8),
                ],
                NavRectButton(
                  isSelected: false,
                  icon: running ? Icons.stop : Icons.play_arrow,
                  text: _starting
                      ? (running ? '停止中' : '启动中')
                      : (running ? '停止游戏' : '开始游戏'),
                  label: running ? '停止' : '启动',
                  defaultBackgroundColor: running
                      ? const Color(0x33FF6B6B)
                      : tokens.colorBrand,
                  defaultColor:
                      running ? const Color(0xFFFF7B7B) : tokens.colorOnBrand,
                  hoverColor: running ? const Color(0x55FF6B6B) : null,
                  hoverTextColor: running
                      ? const Color(0xFFFF8F8F)
                      : tokens.colorOnBrand,
                  onTap: _starting ? () {} : () => unawaited(_playOrStop()),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: ButtonGroupWidget(
                fitContent: true,
                selectedValue: _tab == 0 ? 'map' : 'backups',
                selectedIcon: null,
                onChanged: (value) {
                  setState(() => _tab = value == 'backups' ? 1 : 0);
                  if (value == 'backups' &&
                      _backups.isEmpty &&
                      !_loadingBackups) {
                    unawaited(_loadBackups());
                  }
                },
                items: [
                  const ButtonGroupItem(value: 'map', text: '地图预览'),
                  ButtonGroupItem(value: 'backups', text: backupLabel),
                ],
              ),
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              child:
                  _tab == 0 ? _buildMapTab(tokens) : _buildBackupPanel(tokens),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildMapTab(AppThemeTokens tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            decoration: BoxDecoration(
              color: tokens.colorRaisedBg,
              borderRadius: BorderRadius.circular(14),
            ),
            clipBehavior: Clip.antiAlias,
            child: _buildMapBody(tokens),
          ),
        ),
        const SizedBox(height: 6),
        Text(
          '拖动平移 · 滚轮缩放 · 右下角可放大缩小',
          style: TextStyle(
            fontSize: 11,
            color: tokens.colorBase.withValues(alpha: 0.5),
          ),
        ),
      ],
    );
  }

  Widget _buildBackupPanel(AppThemeTokens tokens) {
    final selected = _selectedBackup;
    return Container(
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(14),
      ),
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '备份列表',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w800,
                        color: tokens.colorContrast,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '点击选择 · 长按删除',
                      style: TextStyle(
                        fontSize: 11,
                        color: tokens.colorBase.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              TextButton.icon(
                onPressed:
                    _loadingBackups ? null : () => unawaited(_loadBackups()),
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新'),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.colorContrast,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (selected != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      '${selected.createdAt} · ${_kindLabel(selected.kind)}'
                      '${selected.auto ? ' · 自动' : ''} · '
                      '${_formatSize(selected.sizeBytes)} · '
                      '${_compressionLabel(selected.compression)}',
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: _busyBackupPath == selected.path
                        ? null
                        : () => unawaited(_restoreBackup(selected)),
                    child: const Text('回溯'),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: _busyBackupPath == selected.path
                        ? null
                        : () => unawaited(_deleteBackup(selected)),
                    icon: Icon(
                      Icons.delete_outline,
                      size: 18,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(child: _buildBackupList(tokens)),
        ],
      ),
    );
  }

  Widget _buildBackupList(AppThemeTokens tokens) {
    if (_loadingBackups) {
      return Center(
        child: SizedBox(
          width: 22,
          height: 22,
          child: CircularProgressIndicator(
            strokeWidth: 2,
            color: tokens.colorBrand,
          ),
        ),
      );
    }
    if (_backups.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.history_toggle_off,
              size: 36,
              color: tokens.colorBase.withValues(alpha: 0.35),
            ),
            const SizedBox(height: 8),
            Text(
              '还没有备份',
              style: TextStyle(
                color: tokens.colorBase.withValues(alpha: 0.6),
              ),
            ),
            const SizedBox(height: 12),
            NavRectButton(
              isSelected: false,
              icon: Icons.backup_outlined,
              text: _backingUp ? '备份中…' : '创建第一份备份',
              label: '创建世界备份',
              defaultBackgroundColor: tokens.colorBrand,
              defaultColor: tokens.colorOnBrand,
              hoverTextColor: tokens.colorOnBrand,
              onTap: _backingUp ? () {} : () => unawaited(_createBackup()),
            ),
          ],
        ),
      );
    }

    return ListView.separated(
      itemCount: _backups.length,
      separatorBuilder: (_, __) => const SizedBox(height: 8),
      itemBuilder: (context, index) {
        final backup = _backups[index];
        final busy = _busyBackupPath == backup.path;
        final selected = _selectedBackup?.path == backup.path;
        return Material(
          color: selected
              ? tokens.colorBrand.withValues(alpha: 0.12)
              : tokens.colorBg.withValues(alpha: 0.35),
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: busy ? null : () => _selectBackup(backup),
            onLongPress: busy ? null : () => unawaited(_deleteBackup(backup)),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 10, 10, 10),
              child: Row(
                children: [
                  Container(
                    width: 52,
                    height: 52,
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: selected
                            ? tokens.colorBrand
                            : tokens.colorBase.withValues(alpha: 0.25),
                        width: selected ? 2 : 1,
                      ),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        _backupIcon(tokens, backup),
                        if (busy)
                          ColoredBox(
                            color: Colors.black.withValues(alpha: 0.45),
                            child: const Center(
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(strokeWidth: 2),
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          backup.createdAt,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w700,
                            color: tokens.colorContrast,
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          [
                            _kindLabel(backup.kind),
                            if (backup.auto) '自动',
                            _formatSize(backup.sizeBytes),
                            _compressionLabel(backup.compression),
                          ].join(' · '),
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton(
                    onPressed: busy
                        ? null
                        : () => unawaited(_restoreBackup(backup)),
                    child: const Text('回溯'),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _backupIcon(AppThemeTokens tokens, rust.WorldBackupDto backup) {
    final path = backup.iconPath ?? widget.world.iconPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return Image.file(
        File(path),
        width: 52,
        height: 52,
        fit: BoxFit.cover,
        errorBuilder: (_, __, ___) => _backupIconFallback(tokens, backup),
      );
    }
    return _backupIconFallback(tokens, backup);
  }

  Widget _backupIconFallback(
    AppThemeTokens tokens,
    rust.WorldBackupDto backup,
  ) {
    return ColoredBox(
      color: tokens.colorBg,
      child: Center(
        child: Icon(
          backup.kind == 'incremental'
              ? Icons.layers_outlined
              : Icons.public_outlined,
          size: 28,
          color: tokens.colorBase.withValues(alpha: 0.55),
        ),
      ),
    );
  }

  Widget _buildMapBody(AppThemeTokens tokens) {
    if (_mapError != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '地图加载失败：$_mapError',
            textAlign: TextAlign.center,
            style: TextStyle(color: tokens.colorBase.withValues(alpha: 0.8)),
          ),
        ),
      );
    }
    return WorldMapViewer(
      key: ValueKey(
        '${widget.instanceId}:${widget.world.folder}',
      ),
      chunks: _mapChunks.values.toList(growable: false),
      minChunkX: _minChunkX,
      minChunkZ: _minChunkZ,
      maxChunkX: _maxChunkX,
      maxChunkZ: _maxChunkZ,
      progress: _mapProgress,
      generating: _loadingMap,
      revision: _viewerKey,
      emptyLabel: '暂无地图（世界尚未生成区块）',
    );
  }
}
