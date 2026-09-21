import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/instance_servers_edit_dialog.dart';
import 'package:aml/src/features/instances/ui/instance_servers_ping.dart';
import 'package:aml/src/features/instances/ui/instance_worlds_row.dart';
import 'package:aml/src/features/instances/ui/world_backup_actions.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/utils/minecraft_motd.dart';
import 'package:aml/src/shared/utils/reveal_in_explorer.dart';
import 'package:aml/src/shared/utils/server_status_ping.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:path/path.dart' as p;

/// 实例详情页「世界」标签页：单人世界与服务器列表、ping 状态、备份与快捷方式。
class InstanceWorldsTab extends StatefulWidget {
  const InstanceWorldsTab({
    super.key,
    required this.instanceId,
    required this.onViewLogs,
  });

  final String instanceId;

  /// 启动世界后回调（父页面切到日志页）。
  final VoidCallback onViewLogs;

  @override
  State<InstanceWorldsTab> createState() => _InstanceWorldsTabState();
}

class _InstanceWorldsTabState extends State<InstanceWorldsTab> {
  String? _instanceRoot;
  List<rust.WorldDto> _worlds = [];
  bool _worldsLoading = false;
  String _worldQuery = '';
  String _worldFilter = 'all'; // all | singleplayer | server
  String? _startingWorld;
  String? _backingUpWorld;
  bool _busy = false;
  /// address → ping / MOTD cache
  final Map<String, ServerPingState> _serverPings = {};
  int _serverPingGen = 0;

  InstanceStore get _store => getIt<InstanceStore>();

  rust.InstanceDto? get _instance {
    for (final i in _store.instances.value) {
      if (i.id == widget.instanceId) return i;
    }
    return null;
  }

  @override
  void initState() {
    super.initState();
    _refreshWorlds();
  }

  Future<void> _refreshWorlds() async {
    setState(() => _worldsLoading = true);
    try {
      final worlds =
          await rust.listInstanceWorlds(instanceId: widget.instanceId);
      if (!mounted) return;
      setState(() {
        _worlds = worlds;
        _worldsLoading = false;
      });
      unawaited(_refreshServerPings());
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _worldsLoading = false;
      });
      showAppSnackBar('$e', isError: true);
    }
  }

  Future<void> _refreshServerPings() async {
    final servers = _worlds
        .where((w) => w.kind == 'server')
        .map((w) => w.serverAddress ?? w.folder)
        .where((a) => a.trim().isNotEmpty)
        .toSet()
        .toList();
    if (servers.isEmpty) {
      serverPingLog('[AML ping] refresh skipped: no servers');
      return;
    }

    serverPingLog(
      '[AML ping] refresh start count=${servers.length} → $servers',
    );
    final gen = ++_serverPingGen;
    setState(() {
      for (final address in servers) {
        final prev = _serverPings[address];
        _serverPings[address] = ServerPingState(
          refreshing: true,
          status: prev?.status,
          offline: prev?.offline ?? false,
        );
      }
    });

    await Future.wait(servers.map((address) async {
      final status = await _pingServerAddress(address);
      if (!mounted || gen != _serverPingGen) {
        serverPingLog('[AML ping] stale result ignored for $address');
        return;
      }
      rust.WorldDto? world;
      for (final w in _worlds) {
        if (w.kind == 'server' &&
            (w.serverAddress ?? w.folder).trim() == address) {
          world = w;
          break;
        }
      }
      _logServerStatusUi(address, status, storedIcon: world?.iconDataUrl);
      setState(() {
        _serverPings[address] = ServerPingState(
          refreshing: false,
          status: status,
          offline: status == null,
        );
      });
    }));
    serverPingLog('[AML ping] refresh done gen=$gen');
  }

  Future<rust.ServerStatusDto?> _pingServerAddress(String address) =>
      pingServerAddress(address);

  /// One-shot analysis after ping — why icon / MOTD may not paint.
  void _logServerStatusUi(
    String address,
    rust.ServerStatusDto? status, {
    String? storedIcon,
  }) {
    if (status == null) {
      serverPingLog(
        '[AML ping] UI $address → OFFLINE (no status). '
        'storedIconLen=${storedIcon?.length}',
      );
      return;
    }

    final motdRaw = status.descriptionJson;
    if (motdRaw == null || motdRaw.trim().isEmpty) {
      serverPingLog('[AML ping] UI $address MOTD: empty/null → default text');
    } else {
      final preview = motdRaw.length > 160
          ? '${motdRaw.substring(0, 160)}…'
          : motdRaw;
      final span = MinecraftMotd.toSpan(motdRaw);
      final plain = span.toPlainText();
      serverPingLog(
        '[AML ping] UI $address MOTD: rawLen=${motdRaw.length} '
        'plain=${plain.length > 80 ? '${plain.substring(0, 80)}…' : plain} '
        'preview=$preview',
      );
    }

    final fav = status.favicon;
    if (fav == null || fav.isEmpty) {
      serverPingLog(
        '[AML ping] UI $address favicon: none from ping; '
        'fallback storedIconLen=${storedIcon?.length} '
        'storedPrefix=${storedIcon == null ? null : (storedIcon.length > 40 ? storedIcon.substring(0, 40) : storedIcon)}',
      );
      if (storedIcon != null && storedIcon.isNotEmpty) {
        final ok = tryDecodeIconDataUrl(storedIcon) != null;
        serverPingLog(
          '[AML ping] UI $address storedIcon decode=${ok ? 'ok' : 'FAIL'}',
        );
      }
    } else {
      final decoded = tryDecodeIconDataUrl(fav);
      serverPingLog(
        '[AML ping] UI $address favicon: len=${fav.length} '
        'prefix=${fav.length > 48 ? fav.substring(0, 48) : fav} '
        'decode=${decoded == null ? 'FAIL' : 'ok bytes=${decoded.length}'}',
      );
    }

    serverPingLog(
      '[AML ping] UI $address summary players=${status.playersOnline}/${status.playersMax} '
      'pingMs=${status.pingMs} version=${status.versionName} legacy=${status.legacy}',
    );
  }

  List<rust.WorldDto> get _filteredWorlds {
    var list = _worlds.toList();
    if (_worldFilter != 'all') {
      list = list.where((w) => w.kind == _worldFilter).toList();
    }
    final q = _worldQuery.trim().toLowerCase();
    if (q.isNotEmpty) {
      list = list
          .where((w) =>
              w.name.toLowerCase().contains(q) ||
              w.folder.toLowerCase().contains(q) ||
              (w.serverAddress?.toLowerCase().contains(q) ?? false))
          .toList();
    }
    return list;
  }

  Future<void> _startWorld(rust.WorldDto w) async {
    if (w.kind != 'singleplayer') {
      if (!await ensureAccountForLaunch(context)) return;
      final address = (w.serverAddress ?? w.folder).trim();
      if (address.isEmpty) {
        showAppSnackBar('服务器地址为空', isError: true);
        return;
      }
      setState(() {
        _busy = true;
        _startingWorld = w.folder;
      });
      try {
        await _store.launch(
          widget.instanceId,
          quickPlayMultiplayer: address,
        );
        widget.onViewLogs();
        if (mounted) showAppSnackBar('已启动并直连服务器');
        await _store.ensureLiveLogsLoaded(widget.instanceId);
      } catch (e) {
        if (mounted) showAppSnackBar('$e', isError: true);
      } finally {
        if (mounted) {
          setState(() {
            _busy = false;
            _startingWorld = null;
          });
        }
      }
      return;
    }
    if (!await ensureAccountForLaunch(context)) return;
    setState(() {
      _busy = true;
      _startingWorld = w.folder;
    });
    try {
      await _store.launch(
        widget.instanceId,
        quickPlaySingleplayer: w.folder,
      );
      widget.onViewLogs();
      if (mounted) showAppSnackBar('已启动');
      await _store.ensureLiveLogsLoaded(widget.instanceId);
    } catch (e) {
      if (mounted) showAppSnackBar('$e', isError: true);
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _startingWorld = null;
        });
      }
    }
  }

  Future<void> _backupWorldFromList(rust.WorldDto w) async {
    if (w.kind != 'singleplayer') return;
    if (_backingUpWorld != null) return;

    if (!mounted) return;
    final options = await showWorldBackupCreateDialog(context);
    if (options == null || !mounted) return;

    setState(() => _backingUpWorld = w.folder);
    try {
      await _store.backupWorld(
        widget.instanceId,
        w.folder,
        kind: 'full',
        compression: options.compression,
      );
      if (!mounted) return;
      showAppSnackBar('备份已创建');
      await _refreshWorlds();
    } catch (e) {
      if (mounted) showAppSnackBar('备份失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _backingUpWorld = null);
    }
  }

  void _openWorld(rust.WorldDto w, {int initialTab = 0}) {
    getIt<NavigationState>().openWorld(
      SelectedWorld(
        folder: w.folder,
        name: w.name,
        gameMode: w.gameMode,
        hardcore: w.hardcore,
        lastPlayedMs: w.lastPlayedMs?.toInt(),
        iconPath: w.iconPath,
        initialTab: initialTab,
      ),
    );
  }

  Future<void> _deleteWorld(rust.WorldDto w) async {
    if (w.kind == 'server') {
      final index = w.serverIndex;
      if (index == null) {
        showAppSnackBar('无法删除该服务器', isError: true);
        return;
      }
      final ok = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('删除服务器'),
          content: Text('确定从列表中移除「${w.name}」？'),
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
      if (ok != true) return;
      try {
        await rust.removeInstanceServer(
          instanceId: widget.instanceId,
          index: index,
        );
        await _refreshWorlds();
        if (mounted) showAppSnackBar('已移除服务器');
      } catch (e) {
        if (!mounted) return;
        showAppSnackBar('$e', isError: true);
      }
      return;
    }

    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除世界'),
        content: Text('确定删除「${w.name}」？此操作不可恢复。'),
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
    if (ok != true) return;
    try {
      await rust.deleteInstanceWorld(
        instanceId: widget.instanceId,
        folder: w.folder,
      );
      await _refreshWorlds();
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    }
  }

  Future<void> _addServer() async {
    final nameController = TextEditingController();
    final addressController = TextEditingController();
    final ok = await showInstanceServerEditDialog(
      context,
      title: '添加服务器',
      confirmLabel: '添加',
      nameController: nameController,
      addressController: addressController,
      nameHintText: '可选，默认使用地址',
      addressHintText: '例如 play.example.com 或 127.0.0.1:25565',
    );
    final name = nameController.text.trim();
    final address = addressController.text.trim();
    nameController.dispose();
    addressController.dispose();
    if (ok != true) return;
    if (address.isEmpty) {
      showAppSnackBar('请填写服务器地址', isError: true);
      return;
    }
    try {
      await rust.addInstanceServer(
        instanceId: widget.instanceId,
        name: name,
        address: address,
      );
      await _refreshWorlds();
      if (mounted) {
        setState(() => _worldFilter = 'server');
        showAppSnackBar('已添加服务器');
      }
    } catch (e) {
      if (mounted) showAppSnackBar('添加失败: $e', isError: true);
    }
  }

  Future<void> _editServer(rust.WorldDto w) async {
    final index = w.serverIndex;
    if (index == null) return;
    final nameController = TextEditingController(text: w.name);
    final addressController =
        TextEditingController(text: w.serverAddress ?? w.folder);
    final ok = await showInstanceServerEditDialog(
      context,
      title: '编辑服务器',
      confirmLabel: '保存',
      nameController: nameController,
      addressController: addressController,
    );
    final name = nameController.text.trim();
    final address = addressController.text.trim();
    nameController.dispose();
    addressController.dispose();
    if (ok != true) return;
    if (address.isEmpty) {
      showAppSnackBar('请填写服务器地址', isError: true);
      return;
    }
    try {
      await rust.editInstanceServer(
        instanceId: widget.instanceId,
        index: index,
        name: name,
        address: address,
      );
      await _refreshWorlds();
      if (mounted) showAppSnackBar('已保存');
    } catch (e) {
      if (mounted) showAppSnackBar('保存失败: $e', isError: true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final filtered = _filteredWorlds;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (v) => setState(() => _worldQuery = v),
                style: TextStyle(color: tokens.colorContrast),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索 ${filtered.length} 个世界……',
                  hintStyle: TextStyle(
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                  filled: true,
                  fillColor: tokens.colorRaisedBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 8),
            TextButton.icon(
              onPressed: _busy ? null : () => unawaited(_addServer()),
              icon: const Icon(Icons.add, size: 16),
              label: const Text('添加服务器'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
            const SizedBox(width: 4),
            TextButton.icon(
              onPressed: _refreshWorlds,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            FilterChip(
              label: const Text('全部'),
              selected: _worldFilter == 'all',
              onSelected: (_) => setState(() => _worldFilter = 'all'),
              selectedColor: tokens.colorBrandHighlight,
              checkmarkColor: tokens.colorBrand,
              labelStyle: TextStyle(
                fontWeight: FontWeight.w700,
                color: _worldFilter == 'all'
                    ? tokens.colorBrand
                    : tokens.colorContrast,
              ),
            ),
            const SizedBox(width: 6),
            FilterChip(
              label: const Text('单人游戏'),
              selected: _worldFilter == 'singleplayer',
              onSelected: (_) => setState(() => _worldFilter = 'singleplayer'),
              selectedColor: tokens.colorBrandHighlight,
              checkmarkColor: tokens.colorBrand,
              labelStyle: TextStyle(
                fontWeight: FontWeight.w700,
                color: _worldFilter == 'singleplayer'
                    ? tokens.colorBrand
                    : tokens.colorContrast,
              ),
            ),
            const SizedBox(width: 6),
            FilterChip(
              label: const Text('服务器'),
              selected: _worldFilter == 'server',
              onSelected: (_) => setState(() => _worldFilter = 'server'),
              selectedColor: tokens.colorBrandHighlight,
              checkmarkColor: tokens.colorBrand,
              labelStyle: TextStyle(
                fontWeight: FontWeight.w700,
                color: _worldFilter == 'server'
                    ? tokens.colorBrand
                    : tokens.colorContrast,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _worldsLoading
              ? const Center(child: CircularProgressIndicator())
              : filtered.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(
                            _worldFilter == 'server' ? '还没有服务器' : '还没有世界',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: tokens.colorContrast,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            _worldFilter == 'server'
                                ? '点击上方「添加服务器」写入 servers.dat'
                                : '启动游戏并创建存档后会出现在这里',
                            style: TextStyle(
                              color: tokens.colorBase.withValues(alpha: 0.7),
                            ),
                          ),
                          if (_worldFilter == 'server') ...[
                            const SizedBox(height: 12),
                            TextButton.icon(
                              onPressed: () => unawaited(_addServer()),
                              icon: const Icon(Icons.add, size: 16),
                              label: const Text('添加服务器'),
                            ),
                          ],
                        ],
                      ),
                    )
                  : ListView.separated(
                      itemCount: filtered.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 8),
                      itemBuilder: (context, index) {
                        final w = filtered[index];
                        final isSp = w.kind == 'singleplayer';
                        return InstanceWorldsRow(
                          tokens: tokens,
                          world: w,
                          busy: _busy,
                          starting: _startingWorld == w.folder,
                          backingUp: _backingUpWorld == w.folder,
                          ping: isSp
                              ? null
                              : _serverPings[
                                  (w.serverAddress ?? w.folder).trim()],
                          onOpenWorld: (initialTab) =>
                              _openWorld(w, initialTab: initialTab),
                          onBackup: () =>
                              unawaited(_backupWorldFromList(w)),
                          onStart: () => unawaited(_startWorld(w)),
                          onMenuSelected: (v) async {
                            if (v == 'delete') {
                              await _deleteWorld(w);
                            } else if (v == 'edit' && !isSp) {
                              await _editServer(w);
                            } else if (v == 'folder' && isSp) {
                              final root = _instanceRoot ??
                                  await rust.openInstanceFolder(
                                    instanceId: widget.instanceId,
                                  );
                              if (!context.mounted) return;
                              await revealInExplorer(
                                context,
                                p.join(root, 'saves', w.folder),
                              );
                            } else if (v == 'backups' && isSp) {
                              _openWorld(w, initialTab: 1);
                            } else if (v == 'shortcut' ||
                                v == 'shortcut_save_as') {
                              final address = isSp
                                  ? null
                                  : (w.serverAddress ?? w.folder);
                              final pingFav = address == null
                                  ? null
                                  : _serverPings[address.trim()]
                                      ?.status
                                      ?.favicon;
                              await createAmlDesktopShortcut(
                                displayName: w.name,
                                instanceId: widget.instanceId,
                                serverAddress: address,
                                worldFolder: isSp ? w.folder : null,
                                instanceIconPath: _instance?.icon,
                                iconDataUrl: pingFav ?? w.iconDataUrl,
                                iconPath: w.iconPath,
                                saveAs: v == 'shortcut_save_as',
                              );
                            }
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}
