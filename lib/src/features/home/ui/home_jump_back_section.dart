import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/home/ui/home_helpers.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/utils/minecraft_motd.dart';
import 'package:aml/src/shared/utils/server_status_ping.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/cards/game_back_hover_card.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class _HomeServerPing {
  const _HomeServerPing({
    required this.refreshing,
    this.status,
    this.offline = false,
  });

  final bool refreshing;
  final rust.ServerStatusDto? status;
  final bool offline;
}

class HomeJumpBackSection extends StatefulWidget {
  const HomeJumpBackSection({super.key, this.onSummaryChanged});

  final void Function(bool jumpLoading, HomeJumpItem? firstJump)?
      onSummaryChanged;

  @override
  State<HomeJumpBackSection> createState() => _HomeJumpBackSectionState();
}

class _HomeJumpBackSectionState extends State<HomeJumpBackSection> {
  static const _minJump = 3;
  static const _maxJump = 4;

  List<HomeJumpItem> _jumpItems = [];
  bool _jumpLoading = true;
  String? _playingKey;
  VoidCallback? _instancesEffect;
  bool _skipFirstInstancesEffect = true;
  final Map<String, _HomeServerPing> _serverPings = {};
  int _serverPingGen = 0;

  @override
  void initState() {
    super.initState();
    _loadJumpBackIn(notifyLoading: false);
    // Reload when instances are added/removed/updated.
    _instancesEffect = effect(() {
      final _ = getIt<InstanceStore>().instances.value;
      if (_skipFirstInstancesEffect) {
        _skipFirstInstancesEffect = false;
        return;
      }
      _loadJumpBackIn();
    });
  }

  @override
  void dispose() {
    _instancesEffect?.call();
    super.dispose();
  }

  void _notifySummary() {
    final loading = _jumpLoading;
    final first = _jumpItems.isEmpty ? null : _jumpItems.first;
    final cb = widget.onSummaryChanged;
    if (cb == null) return;
    // Defer to post-frame: _notifySummary may be reached synchronously from
    // initState (e.g. when the instance list is empty), and the parent
    // callback calls setState on HomePage while it is still building.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      cb(loading, first);
    });
  }

  DateTime? _parseInstancePlayed(String? rfc3339) {
    if (rfc3339 == null || rfc3339.isEmpty) return null;
    return DateTime.tryParse(rfc3339)?.toLocal();
  }

  Future<void> _loadJumpBackIn({bool notifyLoading = true}) async {
    if (mounted && !_jumpLoading) {
      setState(() => _jumpLoading = true);
    }
    if (notifyLoading) _notifySummary();
    final store = getIt<InstanceStore>();
    final instances = List<rust.InstanceDto>.from(store.instances.value);
    instances.sort((a, b) {
      final ak = _parseInstancePlayed(a.lastPlayed) ??
          DateTime.tryParse(a.createdAt) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final bk = _parseInstancePlayed(b.lastPlayed) ??
          DateTime.tryParse(b.createdAt) ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bk.compareTo(ak);
    });

    final twoWeeksAgo = DateTime.now().subtract(const Duration(days: 14));
    final worldItems = <HomeJumpItem>[];

    for (final instance in instances) {
      try {
        final worlds = await rust.listInstanceWorlds(instanceId: instance.id);
        for (final w in worlds) {
          final ms = w.lastPlayedMs?.toInt();
          if (ms == null || ms <= 0) continue;
          worldItems.add(
            HomeJumpItem(
              type: w.kind == 'server' ? 'server' : 'world',
              lastPlayed: DateTime.fromMillisecondsSinceEpoch(ms),
              instance: instance,
              world: w,
            ),
          );
        }
      } catch (_) {}
    }

    worldItems.sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
    final topWorlds = worldItems.take(_maxJump).toList();

    final instanceItems = <HomeJumpItem>[];
    for (final instance in instances) {
      final played = _parseInstancePlayed(instance.lastPlayed);
      if (played == null) continue;
      final hasRecentWorld = topWorlds.any(
        (w) =>
            w.instance.id == instance.id && w.lastPlayed.isAfter(twoWeeksAgo),
      );
      if (hasRecentWorld) continue;
      instanceItems.add(
        HomeJumpItem(
          type: 'instance',
          lastPlayed: played,
          instance: instance,
        ),
      );
    }

    final merged = [...topWorlds, ...instanceItems]
      ..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
    final filtered = <HomeJumpItem>[];
    for (var i = 0; i < merged.length && filtered.length < _maxJump; i++) {
      final item = merged[i];
      if (i < _minJump || item.lastPlayed.isAfter(twoWeeksAgo)) {
        filtered.add(item);
      }
    }

    if (!mounted) return;
    setState(() {
      _jumpItems = filtered;
      _jumpLoading = false;
    });
    _notifySummary();
    unawaited(_refreshServerPings());
  }

  Future<void> _refreshServerPings() async {
    final addresses = _jumpItems
        .where((i) => i.world?.kind == 'server')
        .map((i) => (i.world!.serverAddress ?? i.world!.folder).trim())
        .where((a) => a.isNotEmpty)
        .toSet()
        .toList();
    if (addresses.isEmpty) return;

    final gen = ++_serverPingGen;
    setState(() {
      for (final address in addresses) {
        final prev = _serverPings[address];
        _serverPings[address] = _HomeServerPing(
          refreshing: true,
          status: prev?.status,
          offline: prev?.offline ?? false,
        );
      }
    });

    await Future.wait(addresses.map((address) async {
      final status = await pingServerAddress(address);
      if (!mounted || gen != _serverPingGen) return;
      setState(() {
        _serverPings[address] = _HomeServerPing(
          refreshing: false,
          status: status,
          offline: status == null,
        );
      });
    }));
  }

  String _gameModeLabel(rust.WorldDto w) {
    if (w.hardcore) return '极限模式';
    switch (w.gameMode) {
      case 'creative':
        return '创造模式';
      case 'adventure':
        return '冒险模式';
      case 'spectator':
        return '旁观模式';
      default:
        return '生存模式';
    }
  }

  ImageProvider? _worldImage(rust.WorldDto w, {String? favicon}) {
    final fromPing = decodeDataUrlImage(favicon);
    if (fromPing != null) return fromPing;

    final path = w.iconPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return FileImage(File(path));
    }
    return decodeDataUrlImage(w.iconDataUrl);
  }

  /// Instance pack / custom icon for "开始游戏" rows.
  ImageProvider? _instanceImage(rust.InstanceDto instance) {
    final path = instance.icon?.trim();
    if (path == null || path.isEmpty) return null;
    if (path.startsWith('http://') || path.startsWith('https://')) {
      return NetworkImage(path);
    }
    final file = File(path);
    if (file.existsSync()) return FileImage(file);
    return null;
  }

  Widget? _serverTitleTrailing(tokens, rust.WorldDto w) {
    final address = (w.serverAddress ?? w.folder).trim();
    final ping = _serverPings[address];
    if (ping == null) return null;
    if (ping.refreshing && ping.status == null) {
      return SizedBox(
        width: 12,
        height: 12,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          color: tokens.colorBase.withValues(alpha: 0.55),
        ),
      );
    }
    final status = ping.status;
    if (status == null) {
      return Text(
        '离线',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: const Color(0xFFFF5555).withValues(alpha: 0.9),
        ),
      );
    }
    final parts = <String>[
      if (status.playersOnline != null)
        '${status.playersOnline}'
            '${status.playersMax != null ? '/${status.playersMax}' : ''}',
      if (status.pingMs != null) '${status.pingMs}ms',
    ];
    if (parts.isEmpty) return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.signal_cellular_alt,
          size: 14,
          color: pingColor(status.pingMs?.toInt(), tokens),
        ),
        const SizedBox(width: 4),
        Text(
          parts.join(' · '),
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: tokens.colorBase.withValues(alpha: 0.75),
          ),
        ),
      ],
    );
  }

  InlineSpan _serverMotdSpan(tokens, rust.WorldDto w) {
    final address = (w.serverAddress ?? w.folder).trim();
    final ping = _serverPings[address];
    final fallback = tokens.colorBase.withValues(alpha: 0.7);
    if (ping == null || (ping.refreshing && ping.status == null)) {
      return TextSpan(
        text: '正在查询…',
        style: TextStyle(fontSize: 14, color: fallback),
      );
    }
    if (ping.offline || ping.status == null) {
      return const TextSpan(
        text: '无法连接到服务器',
        style: TextStyle(fontSize: 14, color: Color(0xFFFF5555)),
      );
    }
    return MinecraftMotd.toSpan(
      ping.status!.descriptionJson,
      fallbackColor: fallback,
      fontSize: 14,
    );
  }

  Future<void> _handlePlayJump(HomeJumpItem item) async {
    final store = getIt<InstanceStore>();
    final key = item.world != null
        ? '${item.instance.id}:${item.world!.folder}'
        : item.instance.id;
    final running = store.runningIds.value.contains(item.instance.id);
    if (!running) {
      if (!await ensureAccountForLaunch(context)) return;
      if (!mounted) return;
    }
    setState(() => _playingKey = key);
    try {
      if (running) {
        await store.kill(item.instance.id);
        if (!mounted) return;
        showAppSnackBar('已停止');
      } else if (item.world != null && item.world!.kind == 'singleplayer') {
        // Play button = continue this world. Row tap opens the instance only.
        await store.launch(
          item.instance.id,
          quickPlaySingleplayer: item.world!.folder,
        );
        if (!mounted) return;
        showAppSnackBar('已启动 ${item.world!.name}');
        getIt<NavigationState>().openInstance(item.instance.id);
      } else if (item.world != null && item.world!.kind == 'server') {
        final address =
            (item.world!.serverAddress ?? item.world!.folder).trim();
        await store.launch(
          item.instance.id,
          quickPlayMultiplayer: address.isEmpty ? null : address,
        );
        if (!mounted) return;
        showAppSnackBar(
          address.isEmpty
              ? '已启动「${item.instance.name}」'
              : '已启动并直连「${item.world!.name}」',
        );
        getIt<NavigationState>().openInstance(item.instance.id);
      } else {
        await store.launch(item.instance.id);
        if (!mounted) return;
        showAppSnackBar('已启动');
        getIt<NavigationState>().openInstance(item.instance.id);
      }
      await _loadJumpBackIn();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('启动失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _playingKey = null);
    }
  }

  Future<void> _handleMore(HomeJumpItem item) async {
    final id = item.instance.id;
    final store = getIt<InstanceStore>();
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.open_in_new),
              title: const Text('打开实例'),
              onTap: () => Navigator.pop(context, 'open'),
            ),
            ListTile(
              leading: const Icon(Icons.shortcut_outlined),
              title: const Text('创建桌面快捷方式'),
              onTap: () => Navigator.pop(context, 'shortcut'),
            ),
            ListTile(
              leading: const Icon(Icons.save_as_outlined),
              title: const Text('另存为快捷方式…'),
              onTap: () => Navigator.pop(context, 'shortcut_save_as'),
            ),
            ListTile(
              leading: const Icon(Icons.build),
              title: const Text('重新安装 / 修复'),
              onTap: () => Navigator.pop(context, 'repair'),
            ),
            ListTile(
              leading: const Icon(Icons.delete_outline),
              title: const Text('删除实例'),
              onTap: () => Navigator.pop(context, 'delete'),
            ),
          ],
        ),
      ),
    );
    if (action == 'open') {
      getIt<NavigationState>().openInstance(id);
    } else if (action == 'shortcut' || action == 'shortcut_save_as') {
      final w = item.world;
      final isServer = w != null && w.kind == 'server';
      final address = isServer ? (w.serverAddress ?? w.folder) : null;
      final pingFav = address == null
          ? null
          : _serverPings[address.trim()]?.status?.favicon;
      await createAmlDesktopShortcut(
        displayName: w?.name ?? item.instance.name,
        instanceId: id,
        serverAddress: address,
        worldFolder: w != null && w.kind == 'singleplayer' ? w.folder : null,
        instanceIconPath: item.instance.icon,
        iconDataUrl: pingFav ?? w?.iconDataUrl,
        iconPath: w?.iconPath,
        saveAs: action == 'shortcut_save_as',
      );
    } else if (action == 'repair') {
      try {
        await store.install(id, force: true);
      } catch (e) {
        if (!mounted) return;
        showAppSnackBar('$e', isError: true);
      }
    } else if (action == 'delete') {
      if (!mounted) return;
      rust.InstanceDto? target;
      for (final i in store.instances.value) {
        if (i.id == id) {
          target = i;
          break;
        }
      }
      final name = target?.name ?? '该实例';
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除实例'),
          content: Text('确定删除「$name」？\n此操作不可撤销。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              style: AppDialogActions.destructive(ctx),
              child: const Text('删除'),
            ),
          ],
        ),
      );
      if (ok != true || !mounted) return;
      if (getIt<NavigationState>().selectedInstanceId.value == id) {
        getIt<NavigationState>().closeInstance();
      }
      await store.remove(id);
      await _loadJumpBackIn();
    }
  }

  Widget _buildEmptyInstances(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(18, 18, 18, 16),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '还没有自己的世界',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '创建一个原版或模组实例，也可以先逛逛整合包，挑一个合眼缘的出发。',
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              color: tokens.colorBase.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 14),
          Wrap(
            spacing: 10,
            runSpacing: 10,
            children: [
              NavRectButton(
                isSelected: true,
                icon: Icons.add,
                text: '创建实例',
                selectedBackgroundColor: tokens.colorButtonBgSelected,
                selectedColor: tokens.colorButtonTextSelected,
                onTap: () => openCreateInstance(context),
              ),
              NavRectButton(
                isSelected: false,
                icon: Icons.explore_outlined,
                text: '发现整合包',
                defaultBackgroundColor: tokens.colorButtonBg,
                defaultColor: tokens.colorContrast,
                hoverColor: tokens.colorButtonBgSelected,
                hoverTextColor: tokens.colorButtonTextSelected,
                onTap: () => getIt<NavigationState>().browseModpacks(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final store = getIt<InstanceStore>();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '继续游玩',
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            const Spacer(),
            if (store.instances.value.isNotEmpty)
              TextButton(
                onPressed: _loadJumpBackIn,
                style: TextButton.styleFrom(
                  foregroundColor: tokens.colorContrast,
                ),
                child: const Text('刷新'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        Watch((context) {
          // Rebuild jump list when instances change.
          final _ = store.instances.value;
          final running = store.runningIds.value;
          final operations = store.instanceOperations.value;

          if (_jumpLoading) {
            return const Padding(
              padding: EdgeInsets.symmetric(vertical: 24),
              child: Center(child: CircularProgressIndicator()),
            );
          }

          if (store.instances.value.isEmpty) {
            return _buildEmptyInstances(context);
          }

          if (_jumpItems.isEmpty) {
            // Fallback: show recent instances by lastPlayed.
            final list = List<rust.InstanceDto>.from(
              store.instances.value,
            )..sort((a, b) {
                final ak = a.lastPlayed ?? a.createdAt;
                final bk = b.lastPlayed ?? b.createdAt;
                return bk.compareTo(ak);
              });
            return ListView.separated(
              shrinkWrap: true,
              physics: const NeverScrollableScrollPhysics(),
              itemCount: list.take(_maxJump).length,
              separatorBuilder: (_, __) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final instance = list[index];
                final isRunning = running.contains(instance.id);
                final operation = operations[instance.id];
                final loaderLabel = instance.loader == 'vanilla'
                    ? instance.gameVersion
                    : '${instance.loader} · ${instance.gameVersion}';
                return GameBackHoverCard(
                  title: instance.name,
                  subtitle: isRunning ? '运行中' : '实例',
                  meta: loaderLabel,
                  playLabel: operation ?? (isRunning ? '停止' : '开始游戏'),
                  leadingImage: _instanceImage(instance),
                  leadingIcon: Icons.inventory_2_outlined,
                  onTap: () =>
                      getIt<NavigationState>().openInstance(instance.id),
                  onPlay: operation == null
                      ? () => _handlePlayJump(
                            HomeJumpItem(
                              type: 'instance',
                              lastPlayed: DateTime.now(),
                              instance: instance,
                            ),
                          )
                      : null,
                  onMore: () => _handleMore(
                    HomeJumpItem(
                      type: 'instance',
                      lastPlayed: DateTime.now(),
                      instance: instance,
                    ),
                  ),
                );
              },
            );
          }

          return ListView.separated(
            shrinkWrap: true,
            physics: const NeverScrollableScrollPhysics(),
            itemCount: _jumpItems.length,
            separatorBuilder: (_, __) => const SizedBox(height: 8),
            itemBuilder: (context, index) {
              final item = _jumpItems[index];
              final instance = item.instance;
              final isRunning = running.contains(instance.id);
              final key = item.world != null
                  ? '${instance.id}:${item.world!.folder}'
                  : instance.id;
              final operation = operations[instance.id];
              final busy = _playingKey == key || operation != null;

              if (item.world != null) {
                final w = item.world!;
                final isServer = w.kind == 'server';
                final address = (w.serverAddress ?? w.folder).trim();
                final ping = isServer ? _serverPings[address] : null;
                final tokens = context.tokens;
                return GameBackHoverCard(
                  height: isServer ? 88 : 72,
                  title: w.name,
                  subtitle: isServer
                      ? '服务器 · ${instance.name}'
                      : '${_gameModeLabel(w)} · ${instance.name}',
                  subtitleSpan: isServer ? _serverMotdSpan(tokens, w) : null,
                  meta: isServer
                      ? [
                          instance.name,
                          '上次游玩 ${relativeTime(item.lastPlayed)}',
                        ].join(' · ')
                      : '上次游玩 ${relativeTime(item.lastPlayed)}',
                  titleTrailing: isServer
                      ? _serverTitleTrailing(tokens, w)
                      : null,
                  playLabel: operation ??
                      (busy
                          ? '…'
                          : (isRunning
                              ? '停止'
                              : (isServer ? '开始游戏' : '继续游戏'))),
                  leadingImage: _worldImage(
                        w,
                        favicon: ping?.status?.favicon,
                      ) ??
                      _instanceImage(instance),
                  leadingIcon: isServer ? Icons.dns_outlined : Icons.terrain,
                  onTap: () {
                    getIt<NavigationState>().openInstance(instance.id);
                  },
                  onPlay: busy ? null : () => _handlePlayJump(item),
                  onMore: () => _handleMore(item),
                );
              }

              final loaderLabel = instance.loader == 'vanilla'
                  ? instance.gameVersion
                  : '${instance.loader} · ${instance.gameVersion}';
              return GameBackHoverCard(
                title: instance.name,
                subtitle: isRunning ? '运行中' : '实例',
                meta: '$loaderLabel · ${relativeTime(item.lastPlayed)}',
                playLabel: operation ??
                    (busy ? '…' : (isRunning ? '停止' : '开始游戏')),
                leadingImage: _instanceImage(instance),
                leadingIcon: Icons.inventory_2_outlined,
                onTap: () =>
                    getIt<NavigationState>().openInstance(instance.id),
                onPlay: busy ? null : () => _handlePlayJump(item),
                onMore: () => _handleMore(item),
              );
            },
          );
        }),
      ],
    );
  }
}
