import 'dart:io';

import 'package:aml/src/features/instances/ui/instance_servers_ping.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/utils/minecraft_motd.dart';
import 'package:flutter/material.dart';

class InstanceWorldsRow extends StatelessWidget {
  const InstanceWorldsRow({
    super.key,
    required this.tokens,
    required this.world,
    required this.busy,
    required this.starting,
    required this.backingUp,
    required this.ping,
    required this.onOpenWorld,
    required this.onBackup,
    required this.onStart,
    required this.onMenuSelected,
  });

  final AppThemeTokens tokens;
  final rust.WorldDto world;
  final bool busy;
  final bool starting;
  final bool backingUp;
  final ServerPingState? ping;
  final void Function(int initialTab) onOpenWorld;
  final VoidCallback onBackup;
  final VoidCallback onStart;
  final Future<void> Function(String value) onMenuSelected;

  @override
  Widget build(BuildContext context) {
    final w = world;
    final isSp = w.kind == 'singleplayer';
    return Material(
      color: tokens.colorRaisedBg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: isSp ? () => onOpenWorld(0) : null,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 10, 10, 10),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              _worldIcon(w),
              const SizedBox(width: 12),
              Expanded(
                child: isSp ? _singleplayerWorldMeta(w) : _serverWorldMeta(w),
              ),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (isSp) ...[
                    TextButton(
                      onPressed: busy || backingUp ? null : onBackup,
                      child: Text(backingUp ? '备份中…' : '备份'),
                    ),
                    TextButton(
                      onPressed: () => onOpenWorld(1),
                      child: const Text('管理'),
                    ),
                  ],
                  ElevatedButton(
                    onPressed: busy || starting ? null : onStart,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: tokens.colorBrand,
                      foregroundColor: tokens.colorOnBrand,
                      disabledBackgroundColor:
                          tokens.colorBrand.withValues(alpha: 0.4),
                      elevation: 0,
                    ),
                    child: Text(starting ? '启动中…' : '开始游戏'),
                  ),
                  PopupMenuButton<String>(
                    onSelected: onMenuSelected,
                    itemBuilder: (_) => [
                      const PopupMenuItem(
                        value: 'shortcut',
                        child: Text('创建桌面快捷方式'),
                      ),
                      const PopupMenuItem(
                        value: 'shortcut_save_as',
                        child: Text('另存为快捷方式…'),
                      ),
                      if (isSp)
                        const PopupMenuItem(
                          value: 'backups',
                          child: Text('管理备份'),
                        ),
                      if (isSp)
                        const PopupMenuItem(
                          value: 'folder',
                          child: Text('打开文件夹'),
                        ),
                      if (!isSp)
                        const PopupMenuItem(
                          value: 'edit',
                          child: Text('编辑'),
                        ),
                      const PopupMenuItem(
                        value: 'delete',
                        child: Text('删除'),
                      ),
                    ],
                    icon: Icon(
                      Icons.more_vert,
                      color: tokens.colorBase,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _singleplayerWorldMeta(rust.WorldDto w) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          w.name,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontWeight: FontWeight.w800,
            fontSize: 16,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          [
            '单人游戏',
            _relativePlayed(w.lastPlayedMs?.toInt()),
            _gameModeLabel(w),
            w.backupCount > 0 ? '备份 ${w.backupCount}' : '尚未备份',
          ].where((s) => s.isNotEmpty).join(' · '),
          style: TextStyle(
            fontSize: 12,
            color: tokens.colorBase.withValues(alpha: 0.7),
          ),
        ),
      ],
    );
  }

  Widget _serverWorldMeta(rust.WorldDto w) {
    final ping = this.ping;
    final status = ping?.status;
    final refreshing = ping?.refreshing ?? false;
    final offline = ping != null && ping.offline && !refreshing;

    // Two lines only: title (+ ping) / MOTD — no address or version.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Flexible(
              child: Text(
                w.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  fontSize: 16,
                  color: tokens.colorContrast,
                ),
              ),
            ),
            const SizedBox(width: 8),
            if (refreshing)
              SizedBox(
                width: 12,
                height: 12,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: tokens.colorBase.withValues(alpha: 0.6),
                ),
              )
            else if (status != null) ...[
              Icon(
                Icons.signal_cellular_alt,
                size: 14,
                color: _pingColor(status.pingMs?.toInt()),
              ),
              const SizedBox(width: 4),
              Text(
                [
                  if (status.playersOnline != null)
                    '${status.playersOnline}'
                        '${status.playersMax != null ? '/${status.playersMax}' : ''}',
                  if (status.pingMs != null) '${status.pingMs}ms',
                ].join(' · '),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: tokens.colorBase.withValues(alpha: 0.75),
                ),
              ),
            ] else if (offline)
              const Text(
                '离线',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: Color(0xFFFF5555),
                ),
              ),
          ],
        ),
        const SizedBox(height: 4),
        if (refreshing && status == null)
          Text(
            '正在查询…',
            style: TextStyle(
              fontSize: 12,
              color: tokens.colorBase.withValues(alpha: 0.55),
            ),
          )
        else if (offline || status == null)
          const Text(
            '无法连接到服务器',
            style: TextStyle(
              fontSize: 12,
              color: Color(0xFFFF5555),
            ),
          )
        else
          Text.rich(
            MinecraftMotd.toSpan(
              status.descriptionJson,
              fallbackColor: tokens.colorBase.withValues(alpha: 0.75),
              fontSize: 12,
            ),
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
      ],
    );
  }

  Color _pingColor(int? ms) {
    if (ms == null) return tokens.colorBase.withValues(alpha: 0.55);
    if (ms < 150) return const Color(0xFF55C057);
    if (ms < 300) return const Color(0xFFE0A100);
    return const Color(0xFFFF5555);
  }

  Widget _worldIcon(rust.WorldDto w) {
    if (w.kind == 'server') {
      final favicon = ping?.status?.favicon;
      if (favicon != null && favicon.isNotEmpty) {
        final painted = _dataUrlImage(favicon, w);
        if (painted != null) return painted;
      }
    }
    final path = w.iconPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return ClipRRect(
        borderRadius: BorderRadius.circular(8),
        child: Image.file(
          File(path),
          width: 64,
          height: 64,
          fit: BoxFit.cover,
          errorBuilder: (_, __, ___) => _worldIconFallback(w),
        ),
      );
    }
    final dataUrl = w.iconDataUrl;
    final painted = dataUrl == null ? null : _dataUrlImage(dataUrl, w);
    if (painted != null) return painted;
    return _worldIconFallback(w);
  }

  Widget? _dataUrlImage(String dataUrl, rust.WorldDto w) {
    final bytes = tryDecodeIconDataUrl(dataUrl);
    if (bytes == null) return null;
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Image.memory(
        bytes,
        width: 64,
        height: 64,
        fit: BoxFit.cover,
        gaplessPlayback: true,
        errorBuilder: (context, error, stack) {
          serverPingLog(
            '[AML ping] Image.memory paint fail '
            '${w.serverAddress ?? w.folder}: $error',
          );
          return _worldIconFallback(w);
        },
      ),
    );
  }

  Widget _worldIconFallback(rust.WorldDto w) {
    return Container(
      width: 64,
      height: 64,
      decoration: BoxDecoration(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Icon(
        w.kind == 'server' ? Icons.dns_outlined : Icons.terrain,
        color: tokens.colorBase.withValues(alpha: 0.7),
      ),
    );
  }
}

String _gameModeLabel(rust.WorldDto w) => worldGameModeLabel(
      gameMode: w.gameMode,
      hardcore: w.hardcore,
      emptyIfNotSingleplayer: true,
      kind: w.kind,
    );

String _relativePlayed(int? ms) {
  if (ms == null) return '暂未游玩';
  final dt = DateTime.fromMillisecondsSinceEpoch(ms);
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚游玩';
  if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
  if (diff.inDays < 1) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
  return '上次游玩于去年';
}
