import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/account_avatar.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/create_new_instance.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/utils/minecraft_motd.dart';
import 'package:aml/src/shared/utils/server_status_ping.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/cards/discover_box.dart';
import 'package:aml/src/shared/widgets/components/cards/game_back_hover_card.dart';
import 'package:aml/src/shared/widgets/components/common/hover_text_with_arrow.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// Home "Jump back in" row — world/server/instance.
class _JumpItem {
  final String type; // world | server | instance
  final DateTime lastPlayed;
  final rust.InstanceDto instance;
  final rust.WorldDto? world;

  const _JumpItem({
    required this.type,
    required this.lastPlayed,
    required this.instance,
    this.world,
  });
}

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

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  static const _minJump = 3;
  static const _maxJump = 4;

  ModrinthSearchResult? _modResult;
  ModrinthSearchResult? _modpackResult;
  bool _isLoadingFeatured = true;
  String? _featuredError;
  List<_JumpItem> _jumpItems = [];
  bool _jumpLoading = true;
  String? _playingKey;
  VoidCallback? _instancesEffect;
  bool _skipFirstInstancesEffect = true;
  final Map<String, _HomeServerPing> _serverPings = {};
  int _serverPingGen = 0;

  @override
  void initState() {
    super.initState();
    // Local jump-back-in is cheap; defer Modrinth featured until after first frame
    // so cold start does not compete with shell paint / other tabs.
    _loadJumpBackIn();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_fetchFeatured());
    });
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

  Future<void> _fetchFeatured() async {
    try {
      final results = await Future.wait([
        _fetchWeeklyHotFeatured('modpack'),
        _fetchWeeklyHotFeatured('mod'),
      ]);
      if (!mounted) return;
      setState(() {
        _modpackResult = results[0];
        _modResult = results[1];
        _isLoadingFeatured = false;
        _featuredError = null;
      });
      unawaited(_localizeFeaturedInBackground(results[0], results[1]));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingFeatured = false;
        _featuredError = '$e';
      });
    }
  }

  Future<void> _localizeFeaturedInBackground(
    ModrinthSearchResult packs,
    ModrinthSearchResult mods,
  ) async {
    Future<ModrinthSearchResult> localizeOne(ModrinthSearchResult src) async {
      try {
        final map = await DiscoverTranslation.localizeModrinth(
          projects: [
            for (final p in src.hits)
              (
                id: p.projectId,
                slug: p.slug,
                title: p.title,
                description: p.description,
              ),
          ],
        );
        return ModrinthSearchResult(
          hits: [
            for (final p in src.hits)
              p.copyWith(
                title: map[p.projectId]?.title ?? p.title,
                description: map[p.projectId]?.description ?? p.description,
              ),
          ],
          offset: src.offset,
          limit: src.limit,
          totalHits: src.totalHits,
        );
      } catch (_) {
        return src;
      }
    }

    final localized = await Future.wait([
      localizeOne(packs),
      localizeOne(mods),
    ]);
    if (!mounted) return;
    setState(() {
      _modpackResult = localized[0];
      _modResult = localized[1];
    });
  }

  /// Recently updated (7 days) + popular pool, then random pick 3.
  Future<ModrinthSearchResult> _fetchWeeklyHotFeatured(
    String projectType,
  ) async {
    const poolSize = 20;
    const pickCount = 3;
    final weekAgo = DateTime.now().toUtc().subtract(const Duration(days: 7));

    final updated = await ModrinthApiService.searchProjects(
      query: '',
      facets: [
        ['project_type:$projectType'],
      ],
      index: 'updated',
      limit: poolSize,
      cacheDuration: const Duration(minutes: 10),
    );

    List<ModrinthProject> inWeek(List<ModrinthProject> hits) {
      return hits.where((p) {
        final modified = DateTime.tryParse(p.dateModified)?.toUtc();
        return modified != null && !modified.isBefore(weekAgo);
      }).toList();
    }

    var candidates = inWeek(updated.hits);
    if (candidates.length < pickCount) {
      final popular = await ModrinthApiService.searchProjects(
        query: '',
        facets: [
          ['project_type:$projectType'],
        ],
        index: 'downloads',
        limit: poolSize,
        cacheDuration: const Duration(minutes: 10),
      );
      final merged = <String, ModrinthProject>{
        for (final p in [...candidates, ...inWeek(popular.hits)]) p.projectId: p,
      };
      candidates = merged.values.toList();
    }
    if (candidates.isEmpty) {
      candidates = List<ModrinthProject>.from(updated.hits);
    }

    candidates.sort((a, b) => b.downloads.compareTo(a.downloads));
    final top = candidates.take(16).toList()..shuffle(Random());
    final picks = top.take(pickCount).toList();

    return ModrinthSearchResult(
      hits: picks,
      offset: 0,
      limit: picks.length,
      totalHits: picks.length,
    );
  }

  DateTime? _parseInstancePlayed(String? rfc3339) {
    if (rfc3339 == null || rfc3339.isEmpty) return null;
    return DateTime.tryParse(rfc3339)?.toLocal();
  }

  Future<void> _loadJumpBackIn() async {
    setState(() => _jumpLoading = true);
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
    final worldItems = <_JumpItem>[];

    for (final instance in instances) {
      try {
        final worlds = await rust.listInstanceWorlds(instanceId: instance.id);
        for (final w in worlds) {
          final ms = w.lastPlayedMs?.toInt();
          if (ms == null || ms <= 0) continue;
          worldItems.add(
            _JumpItem(
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

    final instanceItems = <_JumpItem>[];
    for (final instance in instances) {
      final played = _parseInstancePlayed(instance.lastPlayed);
      if (played == null) continue;
      final hasRecentWorld = topWorlds.any(
        (w) =>
            w.instance.id == instance.id && w.lastPlayed.isAfter(twoWeeksAgo),
      );
      if (hasRecentWorld) continue;
      instanceItems.add(
        _JumpItem(
          type: 'instance',
          lastPlayed: played,
          instance: instance,
        ),
      );
    }

    final merged = [...topWorlds, ...instanceItems]
      ..sort((a, b) => b.lastPlayed.compareTo(a.lastPlayed));
    final filtered = <_JumpItem>[];
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

  String _relative(DateTime dt) {
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inHours < 1) return '${diff.inMinutes} 分钟前';
    if (diff.inDays < 1) return '${diff.inHours} 小时前';
    if (diff.inDays < 30) return '${diff.inDays} 天前';
    if (diff.inDays < 365) return '${diff.inDays ~/ 30} 个月前';
    return '一年前';
  }

  String _greetingTitle(String? username) {
    final hour = DateTime.now().hour;
    final period = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    final name = username?.trim();
    if (name != null && name.isNotEmpty) {
      return '$period，$name';
    }
    final hasPlayed = getIt<InstanceStore>().instances.value.any(
          (i) => i.lastPlayed != null && i.lastPlayed!.isNotEmpty,
        );
    return hasPlayed ? '欢迎回来' : '欢迎来到 AML';
  }

  String _greetingSubtitle({
    required bool hasInstances,
    required bool jumpLoading,
  }) {
    if (!hasInstances) {
      return '新世界在等你——创建一个实例，或先去发现整合包。';
    }
    if (jumpLoading) return '正在看看你最近在玩什么…';
    if (_jumpItems.isNotEmpty) {
      final item = _jumpItems.first;
      final when = _relative(item.lastPlayed);
      if (item.world != null) {
        final kind = item.world!.kind == 'server' ? '服务器' : '世界';
        return '上次玩$kind「${item.world!.name}」是 $when';
      }
      return '上次打开「${item.instance.name}」是 $when';
    }
    return '选一个实例，开始今天的冒险吧。';
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
    final fromPing = _decodeDataUrlImage(favicon);
    if (fromPing != null) return fromPing;

    final path = w.iconPath;
    if (path != null && path.isNotEmpty && File(path).existsSync()) {
      return FileImage(File(path));
    }
    return _decodeDataUrlImage(w.iconDataUrl);
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

  ImageProvider? _decodeDataUrlImage(String? dataUrl) {
    var raw = dataUrl?.trim();
    if (raw == null || raw.isEmpty) return null;
    if (!raw.startsWith('data:')) {
      raw = 'data:image/png;base64,$raw';
    }
    if (!raw.startsWith('data:image')) return null;
    final comma = raw.indexOf(',');
    if (comma <= 0) return null;
    try {
      final payload = raw.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
      if (payload.isEmpty) return null;
      return MemoryImage(Uint8List.fromList(base64Decode(payload)));
    } catch (_) {
      return null;
    }
  }

  Color _pingColor(int? ms, tokens) {
    if (ms == null) return tokens.colorBase.withValues(alpha: 0.55);
    if (ms < 150) return const Color(0xFF55C057);
    if (ms < 300) return const Color(0xFFE0A100);
    return const Color(0xFFFF5555);
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
          color: _pingColor(status.pingMs?.toInt(), tokens),
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

  void _openCreate() {
    Navigator.of(context).push(
      PageRouteBuilder(
        opaque: false,
        pageBuilder: (_, __, ___) => const CreateNewInstance(),
      ),
    );
  }

  Future<void> _handlePlayJump(_JumpItem item) async {
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

  Future<void> _handleMore(_JumpItem item) async {
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

  Widget _buildOnboarding(BuildContext context) {
    final tokens = context.tokens;
    final ui = getIt<UiSettingsState>();
    final dismissed = ui.onboardingDismissed.watch(context);
    if (dismissed) return const SizedBox.shrink();

    final accounts = getIt<AccountStore>().accounts.watch(context);
    final instances = getIt<InstanceStore>().instances.watch(context);
    final hasAccount = accounts.isNotEmpty;
    final hasInstance = instances.isNotEmpty;
    final hasPlayed = instances.any(
      (i) => i.lastPlayed != null && i.lastPlayed!.isNotEmpty,
    );

    // Auto-dismiss once the user has gone through the core loop.
    if (hasAccount && hasInstance && hasPlayed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ui.onboardingDismissed.value) return;
        ui.dismissOnboarding();
      });
      return const SizedBox.shrink();
    }

    // Only show for truly new users (no account or no instance).
    if (hasAccount && hasInstance) return const SizedBox.shrink();

    Widget step({
      required int index,
      required String title,
      required String subtitle,
      required bool done,
      required VoidCallback? onTap,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: done ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? tokens.colorBrand.withValues(alpha: 0.2)
                      : tokens.colorButtonBg,
                ),
                child: done
                    ? Icon(Icons.check, size: 16, color: tokens.colorBrand)
                    : Text(
                        '$index',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                        decoration:
                            done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.colorBase.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              if (!done)
                Icon(
                  Icons.chevron_right,
                  color: tokens.colorBase.withValues(alpha: 0.45),
                ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: tokens.colorBrand.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '开始你的第一次冒险',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              TextButton(
                onPressed: ui.dismissOnboarding,
                child: const Text('跳过'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          step(
            index: 1,
            title: '添加账号',
            subtitle: hasAccount ? '已完成' : '登录正版、外置，或创建离线账号',
            done: hasAccount,
            onTap: () => showAccountsPopup(context),
          ),
          step(
            index: 2,
            title: '创建实例',
            subtitle: hasInstance ? '已完成' : '自定义安装，或去发现整合包',
            done: hasInstance,
            onTap: () {
              if (!hasAccount) {
                showAccountsPopup(context);
                return;
              }
              _openCreate();
            },
          ),
          step(
            index: 3,
            title: '启动游戏',
            subtitle: hasPlayed
                ? '已完成'
                : hasInstance
                    ? '打开库或首页「继续游玩」启动'
                    : '创建实例后再启动',
            done: hasPlayed,
            onTap: hasInstance
                ? () => getIt<NavigationState>().goToPage('library')
                : null,
          ),
        ],
      ),
    );
  }

  Widget _buildGreeting(BuildContext context) {
    final tokens = context.tokens;
    final accounts = getIt<AccountStore>().accounts.watch(context);
    rust.AccountDto? active;
    for (final a in accounts) {
      if (a.active) {
        active = a;
        break;
      }
    }
    final store = getIt<InstanceStore>();
    final hasInstances = store.instances.watch(context).isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (active != null) ...[
          AccountAvatar(account: active, size: 52),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greetingTitle(active?.username),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: tokens.colorContrast,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _greetingSubtitle(
                  hasInstances: hasInstances,
                  jumpLoading: _jumpLoading,
                ),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  color: tokens.colorBase.withValues(alpha: 0.72),
                ),
              ),
            ],
          ),
        ),
      ],
    );
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
                onTap: _openCreate,
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

  Widget _buildFeaturedSection({
    required String title,
    required VoidCallback onMore,
    required ModrinthSearchResult? result,
  }) {
    final hits = result?.hits ?? const <ModrinthProject>[];
    if (hits.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HoverTextWithArrow(text: title, onTap: onMore),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 420,
            childAspectRatio: 0.92,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: hits.length,
          itemBuilder: (context, index) {
            return DiscoverBox(result: hits[index]);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final store = getIt<InstanceStore>();
    final nav = getIt<NavigationState>();

    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          child: ConstrainedBox(
            constraints: BoxConstraints(minHeight: constraints.maxHeight),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 22),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const SizedBox(height: 12),
                  Watch((context) => _buildGreeting(context)),
                  const SizedBox(height: 12),
                  Watch((context) => _buildOnboarding(context)),
                  const SizedBox(height: 6),
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
                            playLabel:
                                operation ?? (isRunning ? '停止' : '开始游戏'),
                            leadingImage: _instanceImage(instance),
                            leadingIcon: Icons.inventory_2_outlined,
                            onTap: () =>
                                getIt<NavigationState>().openInstance(instance.id),
                            onPlay: operation == null
                                ? () => _handlePlayJump(
                                      _JumpItem(
                                        type: 'instance',
                                        lastPlayed: DateTime.now(),
                                        instance: instance,
                                      ),
                                    )
                                : null,
                            onMore: () => _handleMore(
                              _JumpItem(
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
                          final address =
                              (w.serverAddress ?? w.folder).trim();
                          final ping = isServer ? _serverPings[address] : null;
                          final tokens = context.tokens;
                          return GameBackHoverCard(
                            height: isServer ? 88 : 72,
                            title: w.name,
                            subtitle: isServer
                                ? '服务器 · ${instance.name}'
                                : '${_gameModeLabel(w)} · ${instance.name}',
                            subtitleSpan:
                                isServer ? _serverMotdSpan(tokens, w) : null,
                            meta: isServer
                                ? [
                                    instance.name,
                                    '上次游玩 ${_relative(item.lastPlayed)}',
                                  ].join(' · ')
                                : '上次游玩 ${_relative(item.lastPlayed)}',
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
                            leadingIcon:
                                isServer ? Icons.dns_outlined : Icons.terrain,
                            onTap: () {
                              getIt<NavigationState>()
                                  .openInstance(instance.id);
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
                          meta: '$loaderLabel · ${_relative(item.lastPlayed)}',
                          playLabel: operation ??
                              (busy ? '…' : (isRunning ? '停止' : '开始游戏')),
                          leadingImage: _instanceImage(instance),
                          leadingIcon: Icons.inventory_2_outlined,
                          onTap: () => getIt<NavigationState>()
                              .openInstance(instance.id),
                          onPlay: busy ? null : () => _handlePlayJump(item),
                          onMore: () => _handleMore(item),
                        );
                      },
                    );
                  }),
                  const SizedBox(height: 22),
                  if (_isLoadingFeatured)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 24),
                      child: Center(child: CircularProgressIndicator()),
                    )
                  else if (_featuredError != null)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: tokens.colorRaisedBg,
                        borderRadius: BorderRadius.circular(14),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.cloud_off_outlined,
                            color: tokens.colorBase.withValues(alpha: 0.65),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Text(
                              '推荐内容暂时无法加载',
                              style: TextStyle(
                                color: tokens.colorContrast,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          TextButton(
                            onPressed: () {
                              setState(() {
                                _isLoadingFeatured = true;
                                _featuredError = null;
                              });
                              _fetchFeatured();
                            },
                            child: const Text('重试'),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    _buildFeaturedSection(
                      title: '本周热门整合包',
                      onMore: nav.browseModpacks,
                      result: _modpackResult,
                    ),
                    const SizedBox(height: 18),
                    _buildFeaturedSection(
                      title: '本周热门模组',
                      onMore: nav.browseMods,
                      result: _modResult,
                    ),
                  ],
                  const SizedBox(height: 30),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}
