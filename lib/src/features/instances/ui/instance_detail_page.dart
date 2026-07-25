import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_play_stats.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/instance_content_tab.dart';
import 'package:aml/src/features/instances/ui/instance_overview_tab.dart';
import 'package:aml/src/features/instances/ui/instance_settings_page.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/utils/relative_time.dart';
import 'package:aml/src/features/instances/ui/log_line.dart';
import 'package:aml/src/features/instances/ui/world_backup_actions.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/utils/minecraft_motd.dart';
import 'package:aml/src/shared/utils/server_status_ping.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:file_picker/file_picker.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:aml/src/shared/widgets/components/tabs/animated_tab_bar.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;
import 'package:signals_flutter/signals_flutter.dart';

class InstanceDetailPage extends StatefulWidget {
  const InstanceDetailPage({super.key, required this.instanceId});

  final String instanceId;

  @override
  State<InstanceDetailPage> createState() => _InstanceDetailPageState();
}

class _InstanceDetailPageState extends State<InstanceDetailPage> {
  void _pingLog(String msg) {
    assert(() {
      // ignore: avoid_print
      debugPrint(msg);
      return true;
    }());
  }

  static const _tabOverview = 0;
  static const _tabContent = 1;
  static const _tabFiles = 2;
  static const _tabWorlds = 3;
  static const _tabLogs = 4;
  static const _tabScreenshots = 5;

  int _tab = 0;
  bool _busy = false;
  final GlobalKey<InstanceContentTabState> _contentTabKey =
      GlobalKey<InstanceContentTabState>();
  final ScrollController _logScroll = ScrollController();
  String _fileLog = '';
  VoidCallback? _disposeRunningEffect;
  VoidCallback? _disposeLogEffect;
  int _lastLiveLogCount = 0;
  String? _lastLiveLogTail;

  String? _instanceRoot;
  String _filesRel = '';
  List<_FsEntry> _fileEntries = [];
  bool _filesLoading = false;
  List<rust.WorldDto> _worlds = [];
  bool _worldsLoading = false;
  String _worldQuery = '';
  String _worldFilter = 'all'; // all | singleplayer | server
  String? _startingWorld;
  String? _backingUpWorld;
  /// address → ping / MOTD cache
  final Map<String, _ServerPingState> _serverPings = {};
  int _serverPingGen = 0;
  String _logFilter = 'all'; // all | error | warn | info | debug | trace
  String _logQuery = '';
  Timer? _logSearchDebounce;
  final IncrementalLogParser _liveLogParser = IncrementalLogParser();
  List<ParsedLogLine> _parsedLogs = [];
  int _parsedRawLogCount = 0;
  String? _parsedLastRawLine;
  bool _parsedFromLiveLogs = false;
  String _parsedFileLogKey = '';
  Set<LogLevel> _presentLogLevels = {};
  String _filteredLogsKey = '';
  List<ParsedLogLine> _filteredLogs = const [];
  bool _logFollowTail = true;
  List<_ScreenshotEntry> _screenshots = [];
  bool _screenshotsLoading = false;
  InstancePlayStats? _playStats;
  bool _playStatsLoading = false;

  static const _logLineExtent = 17.0;
  static final _screenshotExt = RegExp(r'\.(png|jpe?g)$', caseSensitive: false);

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
    // First open: overview + content list, then sync metadata once.
    unawaited(_refreshOverview());
    _store.ensureLiveLogsLoaded(widget.instanceId);
    _refreshFileLog();
    _ensureInstanceRoot();
    final initialLogs = _store.liveLogsFor(widget.instanceId);
    _lastLiveLogCount = initialLogs.length;
    _lastLiveLogTail = initialLogs.isEmpty ? null : initialLogs.last;
    _logScroll.addListener(() {
      if (!_logScroll.hasClients) return;
      final follow = _logScroll.position.extentAfter < 48;
      if (follow != _logFollowTail && mounted) {
        setState(() => _logFollowTail = follow);
      }
    });

    var wasRunning = _store.isRunning(widget.instanceId);
    _disposeRunningEffect = effect(() {
      final running = _store.isRunning(widget.instanceId);
      if (wasRunning && !running) {
        _refreshFileLog();
        if (_tab == _tabScreenshots || _tab == _tabOverview) {
          unawaited(_refreshOverview());
        }
      }
      wasRunning = running;
    });

    _disposeLogEffect = effect(() {
      final logs = _store.liveLogsFor(widget.instanceId);
      final count = logs.length;
      final tail = logs.isEmpty ? null : logs.last;
      final hasNewOutput =
          count > _lastLiveLogCount || tail != _lastLiveLogTail;
      if (hasNewOutput && _tab == _tabLogs && _logFollowTail) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted || !_logScroll.hasClients) return;
          _logScroll.jumpTo(_logScroll.position.maxScrollExtent);
        });
      }
      _lastLiveLogCount = count;
      _lastLiveLogTail = tail;
    });
  }

  Future<void> _ensureInstanceRoot() async {
    try {
      final root = await rust.openInstanceFolder(instanceId: widget.instanceId);
      if (!mounted) return;
      setState(() => _instanceRoot = root);
    } catch (_) {}
  }

  Future<void> _refreshPlayStats() async {
    setState(() => _playStatsLoading = true);
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final account = getIt<AccountStore>().activeAccount;
      final stats = await InstancePlayStats.load(
        root,
        preferUuid: account?.uuid,
      );
      if (!mounted) return;
      setState(() {
        _instanceRoot = root;
        _playStats = stats;
        _playStatsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _playStatsLoading = false;
      });
    }
  }

  Future<void> _refreshOverview() async {
    await Future.wait([
      _refreshScreenshots(),
      _refreshPlayStats(),
    ]);
  }

  Future<void> _refreshScreenshots() async {
    setState(() => _screenshotsLoading = true);
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final dir = Directory(p.join(root, 'screenshots'));
      final entries = <_ScreenshotEntry>[];
      if (await dir.exists()) {
        await for (final entity in dir.list(followLinks: false)) {
          if (entity is! File) continue;
          final name = p.basename(entity.path);
          if (!_screenshotExt.hasMatch(name)) continue;
          int size = 0;
          DateTime? modified;
          try {
            final stat = await entity.stat();
            size = stat.size;
            modified = stat.modified;
          } catch (_) {}
          entries.add(
            _ScreenshotEntry(
              name: name,
              path: entity.path,
              size: size,
              modified: modified,
            ),
          );
        }
      }
      entries.sort((a, b) {
        final am = a.modified?.millisecondsSinceEpoch ?? 0;
        final bm = b.modified?.millisecondsSinceEpoch ?? 0;
        if (am != bm) return bm.compareTo(am);
        return b.name.compareTo(a.name);
      });
      if (!mounted) return;
      setState(() {
        _instanceRoot = root;
        _screenshots = entries;
        _screenshotsLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _screenshotsLoading = false;
      });
    }
  }

  Future<void> _openScreenshotsFolder() async {
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final dir = Directory(p.join(root, 'screenshots'));
      if (!await dir.exists()) {
        await dir.create(recursive: true);
      }
      await _revealInExplorer(dir.path);
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    }
  }

  void _previewScreenshot(int index) {
    final paths = _screenshots.map((e) => e.path).toList();
    final titles = _screenshots.map((e) => e.name).toList();
    unawaited(
      showImageLightbox(
        context,
        urls: paths,
        initialIndex: index,
        titles: titles,
      ),
    );
  }

  String _formatScreenshotTime(DateTime? dt) {
    if (dt == null) return '';
    final y = dt.year.toString().padLeft(4, '0');
    final m = dt.month.toString().padLeft(2, '0');
    final d = dt.day.toString().padLeft(2, '0');
    final h = dt.hour.toString().padLeft(2, '0');
    final min = dt.minute.toString().padLeft(2, '0');
    return '$y-$m-$d $h:$min';
  }

  Future<void> _refreshFiles({String? rel}) async {
    final nextRel = rel ?? _filesRel;
    setState(() => _filesLoading = true);
    try {
      final root = _instanceRoot ??
          await rust.openInstanceFolder(instanceId: widget.instanceId);
      final dir = Directory(nextRel.isEmpty ? root : p.join(root, nextRel));
      if (!await dir.exists()) {
        if (!mounted) return;
        setState(() {
          _instanceRoot = root;
          _filesRel = nextRel;
          _fileEntries = [];
          _filesLoading = false;
        });
        return;
      }
      final entries = <_FsEntry>[];
      await for (final entity in dir.list(followLinks: false)) {
        final name = p.basename(entity.path);
        if (name == '.' || name == '..') continue;
        final isDir = entity is Directory;
        int size = 0;
        DateTime? modified;
        try {
          final stat = await entity.stat();
          size = isDir ? 0 : stat.size;
          modified = stat.modified;
        } catch (_) {}
        entries.add(
          _FsEntry(
            name: name,
            isDirectory: isDir,
            size: size,
            modified: modified,
            absolutePath: entity.path,
          ),
        );
      }
      entries.sort((a, b) {
        if (a.isDirectory != b.isDirectory) {
          return a.isDirectory ? -1 : 1;
        }
        return a.name.toLowerCase().compareTo(b.name.toLowerCase());
      });
      if (!mounted) return;
      setState(() {
        _instanceRoot = root;
        _filesRel = nextRel;
        _fileEntries = entries;
        _filesLoading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _filesLoading = false;
      });
    }
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
      _pingLog('[AML ping] refresh skipped: no servers');
      return;
    }

    _pingLog(
      '[AML ping] refresh start count=${servers.length} → $servers',
    );
    final gen = ++_serverPingGen;
    setState(() {
      for (final address in servers) {
        final prev = _serverPings[address];
        _serverPings[address] = _ServerPingState(
          refreshing: true,
          status: prev?.status,
          offline: prev?.offline ?? false,
        );
      }
    });

    await Future.wait(servers.map((address) async {
      final status = await _pingServerAddress(address);
      if (!mounted || gen != _serverPingGen) {
        _pingLog('[AML ping] stale result ignored for $address');
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
        _serverPings[address] = _ServerPingState(
          refreshing: false,
          status: status,
          offline: status == null,
        );
      });
    }));
    _pingLog('[AML ping] refresh done gen=$gen');
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
      _pingLog(
        '[AML ping] UI $address → OFFLINE (no status). '
        'storedIconLen=${storedIcon?.length}',
      );
      return;
    }

    final motdRaw = status.descriptionJson;
    if (motdRaw == null || motdRaw.trim().isEmpty) {
      _pingLog('[AML ping] UI $address MOTD: empty/null → default text');
    } else {
      final preview = motdRaw.length > 160
          ? '${motdRaw.substring(0, 160)}…'
          : motdRaw;
      final span = MinecraftMotd.toSpan(motdRaw);
      final plain = span.toPlainText();
      _pingLog(
        '[AML ping] UI $address MOTD: rawLen=${motdRaw.length} '
        'plain=${plain.length > 80 ? '${plain.substring(0, 80)}…' : plain} '
        'preview=$preview',
      );
    }

    final fav = status.favicon;
    if (fav == null || fav.isEmpty) {
      _pingLog(
        '[AML ping] UI $address favicon: none from ping; '
        'fallback storedIconLen=${storedIcon?.length} '
        'storedPrefix=${storedIcon == null ? null : (storedIcon.length > 40 ? storedIcon.substring(0, 40) : storedIcon)}',
      );
      if (storedIcon != null && storedIcon.isNotEmpty) {
        final ok = _tryDecodeDataUrl(storedIcon) != null;
        _pingLog(
          '[AML ping] UI $address storedIcon decode=${ok ? 'ok' : 'FAIL'}',
        );
      }
    } else {
      final decoded = _tryDecodeDataUrl(fav);
      _pingLog(
        '[AML ping] UI $address favicon: len=${fav.length} '
        'prefix=${fav.length > 48 ? fav.substring(0, 48) : fav} '
        'decode=${decoded == null ? 'FAIL' : 'ok bytes=${decoded.length}'}',
      );
    }

    _pingLog(
      '[AML ping] UI $address summary players=${status.playersOnline}/${status.playersMax} '
      'pingMs=${status.pingMs} version=${status.versionName} legacy=${status.legacy}',
    );
  }

  Uint8List? _tryDecodeDataUrl(String dataUrl) {
    var raw = dataUrl.trim();
    if (raw.isEmpty) return null;
    if (!raw.startsWith('data:')) {
      raw = 'data:image/png;base64,$raw';
    }
    if (!raw.startsWith('data:image')) {
      _pingLog(
        '[AML ping] icon reject: not data:image (startsWith=${raw.length > 24 ? raw.substring(0, 24) : raw})',
      );
      return null;
    }
    final comma = raw.indexOf(',');
    if (comma <= 0) {
      _pingLog('[AML ping] icon reject: no comma in data URL');
      return null;
    }
    try {
      final payload = raw.substring(comma + 1).replaceAll(RegExp(r'\s'), '');
      if (payload.isEmpty) {
        _pingLog('[AML ping] icon reject: empty base64 payload');
        return null;
      }
      final bytes = base64Decode(payload);
      if (bytes.isEmpty) {
        _pingLog('[AML ping] icon reject: decoded empty');
        return null;
      }
      return Uint8List.fromList(bytes);
    } catch (e) {
      _pingLog('[AML ping] icon decode error: $e');
      return null;
    }
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
        setState(() {
          _tab = _tabLogs;
        });
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
      setState(() {
        _tab = _tabLogs;
      });
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tokens = ctx.tokens;
        return AlertDialog(
          title: const Text('添加服务器'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '名称',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(
                    hintText: '可选，默认使用地址',
                    isDense: true,
                  ),
                ),
                const SizedBox(height: 14),
                Text(
                  '地址',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(
                    hintText: '例如 play.example.com 或 127.0.0.1:25565',
                    isDense: true,
                  ),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('添加'),
            ),
          ],
        );
      },
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tokens = ctx.tokens;
        return AlertDialog(
          title: const Text('编辑服务器'),
          content: SizedBox(
            width: 400,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '名称',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: nameController,
                  autofocus: true,
                  decoration: const InputDecoration(isDense: true),
                ),
                const SizedBox(height: 14),
                Text(
                  '地址',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: addressController,
                  decoration: const InputDecoration(isDense: true),
                  onSubmitted: (_) => Navigator.pop(ctx, true),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('保存'),
            ),
          ],
        );
      },
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

  Future<void> _revealInExplorer(String path) async {
    try {
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('$e', isError: true);
    }
  }

  @override
  void dispose() {
    _disposeRunningEffect?.call();
    _disposeLogEffect?.call();
    _logSearchDebounce?.cancel();
    _logScroll.dispose();
    super.dispose();
  }

  Future<void> _refreshFileLog() async {
    try {
      final file = await _store.readLauncherLogFile(widget.instanceId);
      if (!mounted) return;
      setState(() => _fileLog = file);
    } catch (e) {
      if (mounted) showAppSnackBar('$e', isError: true);
    }
  }

  Future<void> _refreshLogs({bool silent = false}) async {
    try {
      await _store.refreshLiveLogs(widget.instanceId);
      await _refreshFileLog();
    } catch (e) {
      if (!silent && mounted) {
        showAppSnackBar('$e', isError: true);
      }
    }
  }

  String _instanceSubtitle(rust.InstanceDto instance) {
    final loader = loaderLabel(instance.loader);
    final version = instance.gameVersion;
    final age = relativeAge(instance.lastPlayed ?? instance.createdAt);
    final parts = <String>['$loader $version'];
    if (age.isNotEmpty) parts.add(age);
    return parts.join(' · ');
  }

  Future<void> _pickInstanceIcon() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    try {
      await _store.editIcon(widget.instanceId, path: path);
      if (mounted) showAppSnackBar('实例图标已更新');
    } catch (e) {
      if (mounted) showAppSnackBar('更新图标失败: $e', isError: true);
    }
  }

  Future<void> _renameInstance(rust.InstanceDto instance) async {
    if (_store.isRunning(instance.id)) {
      showAppSnackBar('实例正在运行，请先停止后再重命名', isError: true);
      return;
    }
    final controller = TextEditingController(text: instance.name);
    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) {
        return AlertDialog(
          title: const Text('重命名实例'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLength: 80,
            decoration: const InputDecoration(
              labelText: '名称',
              helperText: '不可使用 \\ / : * ? " < > |',
            ),
            inputFormatters: [
              FilteringTextInputFormatter.deny(RegExp(r'[\\/:*?"<>|]')),
            ],
            onSubmitted: (value) => Navigator.pop(ctx, value.trim()),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text.trim()),
              child: const Text('确定'),
            ),
          ],
        );
      },
    );
    controller.dispose();
    if (newName == null || newName.isEmpty || newName == instance.name) return;
    try {
      final updated =
          await _store.updateSettings(id: instance.id, name: newName);
      if (mounted) showAppSnackBar('已重命名为「${updated.name}」');
    } catch (e) {
      if (mounted) showAppSnackBar('重命名失败: $e', isError: true);
    }
  }

  Future<void> _removeInstanceIcon() async {
    try {
      await _store.editIcon(widget.instanceId);
      if (mounted) showAppSnackBar('已移除实例图标');
    } catch (e) {
      if (mounted) showAppSnackBar('移除图标失败: $e', isError: true);
    }
  }

  Future<void> _openInstanceSettings() async {
    await showInstanceSettingsDialog(
      context: context,
      instanceId: widget.instanceId,
    );
  }

  void _showIconEditMenu() {
    showModalBottomSheet<void>(
      context: context,
      builder: (ctx) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.image_outlined),
              title: const Text('选择图标'),
              onTap: () {
                Navigator.pop(ctx);
                _pickInstanceIcon();
              },
            ),
            if (_instance?.icon != null && _instance!.icon!.isNotEmpty)
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('移除图标'),
                onTap: () {
                  Navigator.pop(ctx);
                  _removeInstanceIcon();
                },
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _playOrStop() async {
    setState(() {
      _busy = true;
    });
    try {
      final running = _store.runningIds.value.contains(widget.instanceId);
      if (running) {
        await _store.kill(widget.instanceId);
        if (mounted) showAppSnackBar('已停止');
      } else {
        if (!await ensureAccountForLaunch(context)) return;
        await _store.launch(widget.instanceId);
        setState(() {
          _tab = _tabLogs;
        });
        if (mounted) showAppSnackBar('已启动');
        await _store.ensureLiveLogsLoaded(widget.instanceId);
      }
    } catch (e) {
      if (mounted) showAppSnackBar('$e', isError: true);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    return Watch((context) {
      final instance = _instance;
      final running = _store.runningIds.value.contains(widget.instanceId);
      final liveLogs = _store.liveLogs.value[widget.instanceId] ?? const [];
      if (instance == null) {
        return Center(
          child: Text('实例不存在', style: TextStyle(color: tokens.colorContrast)),
        );
      }

      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              children: [
                CustomButton(
                  icon: Icons.arrow_back,
                  size: ButtonSize.medium,
                  onTap: () => getIt<NavigationState>().closeInstance(),
                ),
                const SizedBox(width: 12),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _showIconEditMenu,
                    borderRadius: BorderRadius.circular(10),
                    child: Padding(
                      padding: const EdgeInsets.all(2),
                      child: InstanceIcon(
                        instanceId: instance.id,
                        iconPath: instance.icon,
                        size: 48,
                        borderRadius: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              instance.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                color: tokens.colorContrast,
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          InkWell(
                            onTap: () => unawaited(_renameInstance(instance)),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.all(4),
                              child: Icon(
                                Icons.edit_outlined,
                                size: 18,
                                color: tokens.colorBase.withValues(alpha: 0.75),
                              ),
                            ),
                          ),
                        ],
                      ),
                      Text(
                        _instanceSubtitle(instance),
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
                NavRectButton(
                  isSelected: false,
                  icon: running ? Icons.stop : Icons.play_arrow,
                  text: _busy
                      ? '处理中'
                      : (running
                          ? '停止'
                          : (instance.installStage == 'installed'
                              ? '启动'
                              : '安装并启动')),
                  label: '启动',
                  defaultBackgroundColor: tokens.colorBrand,
                  defaultColor: tokens.colorOnBrand,
                  hoverTextColor: tokens.colorOnBrand,
                  onTap: _busy ? () {} : _playOrStop,
                ),
                const SizedBox(width: 8),
                CustomButton(
                  icon: Icons.settings_outlined,
                  size: ButtonSize.medium,
                  onTap: _openInstanceSettings,
                ),
                const SizedBox(width: 4),
                CustomButton(
                  icon: Icons.shortcut_outlined,
                  size: ButtonSize.medium,
                  onTap: () => unawaited(
                    createAmlDesktopShortcut(
                      displayName: instance.name,
                      instanceId: instance.id,
                      instanceIconPath: instance.icon,
                    ),
                  ),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: AnimatedTabBar(
              tabs: const ['概览', '内容', '文件', '世界', '日志', '截图'],
              selectedIndex: _tab,
              onTabChanged: (i) {
                setState(() => _tab = i);
                if (i == _tabOverview) {
                  unawaited(_refreshOverview());
                }
                if (i == _tabContent) {
                  // Tab switch: local list only. Full sync is first-open / 刷新.
                  final tab = _contentTabKey.currentState;
                  if (tab != null) {
                    unawaited(
                      tab.refresh(
                        syncMetadata: !tab.syncedOnce,
                        checkUpdates: false,
                      ),
                    );
                  }
                }
                if (i == _tabFiles) _refreshFiles();
                if (i == _tabWorlds) _refreshWorlds();
                if (i == _tabLogs) {
                  _store.ensureLiveLogsLoaded(widget.instanceId);
                  _refreshFileLog();
                }
                if (i == _tabScreenshots) _refreshScreenshots();
              },
              colorScheme: colorScheme,
            ),
          ),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
              // Keep content tab mounted so sync state / list survive tab switches.
              child: Stack(
                fit: StackFit.expand,
                children: [
                  Offstage(
                    offstage: _tab != _tabContent,
                    child: TickerMode(
                      enabled: _tab == _tabContent,
                      child: InstanceContentTab(
                        key: _contentTabKey,
                        instanceId: widget.instanceId,
                      ),
                    ),
                  ),
                  if (_tab != _tabContent)
                    switch (_tab) {
                      _tabOverview => InstanceOverviewTab(
                          tokens: tokens,
                          stats: _playStats,
                          statsLoading: _playStatsLoading,
                          screenshots: _screenshots
                              .map(
                                (e) => InstanceOverviewScreenshot(
                                  path: e.path,
                                  name: e.name,
                                  modified: e.modified,
                                ),
                              )
                              .toList(),
                          screenshotsLoading: _screenshotsLoading,
                          playerName:
                              getIt<AccountStore>().activeAccount?.username,
                          onRefresh: () => unawaited(_refreshOverview()),
                          onOpenScreenshot: _previewScreenshot,
                          onSeeAllScreenshots: () {
                            setState(() => _tab = _tabScreenshots);
                            unawaited(_refreshScreenshots());
                          },
                        ),
                      _tabFiles => _buildFiles(tokens),
                      _tabWorlds => _buildWorlds(tokens),
                      _tabLogs => _buildLogs(tokens, liveLogs),
                      _ => _buildScreenshots(tokens),
                    },
                ],
              ),
            ),
          ),
        ],
      );
    });
  }

  Widget _buildFiles(tokens) {
    final crumbs = _filesRel.isEmpty
        ? <String>[]
        : _filesRel
            .split(RegExp(r'[\\/]+'))
            .where((s) => s.isNotEmpty)
            .toList();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '文件',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () async {
                final root = _instanceRoot ??
                    await rust.openInstanceFolder(
                        instanceId: widget.instanceId);
                final path = _filesRel.isEmpty ? root : p.join(root, _filesRel);
                await _revealInExplorer(path);
              },
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('在资源管理器中打开'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
            TextButton.icon(
              onPressed: () => _refreshFiles(),
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              TextButton(
                onPressed:
                    _filesRel.isEmpty ? null : () => _refreshFiles(rel: ''),
                child: const Text('实例根目录'),
              ),
              for (var i = 0; i < crumbs.length; i++) ...[
                Icon(Icons.chevron_right, size: 16, color: tokens.colorBase),
                TextButton(
                  onPressed: () {
                    final rel = crumbs.sublist(0, i + 1).join('/');
                    _refreshFiles(rel: rel);
                  },
                  child: Text(crumbs[i]),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(
          child: _filesLoading
              ? const Center(child: CircularProgressIndicator())
              : _fileEntries.isEmpty
                  ? Center(
                      child: Text(
                        '此文件夹为空',
                        style: TextStyle(color: tokens.colorBase),
                      ),
                    )
                  : ListView.separated(
                      itemCount: _fileEntries.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 4),
                      itemBuilder: (context, index) {
                        final e = _fileEntries[index];
                        return Material(
                          color: tokens.colorRaisedBg,
                          borderRadius: BorderRadius.circular(10),
                          child: ListTile(
                            leading: Icon(
                              e.isDirectory
                                  ? Icons.folder
                                  : Icons.insert_drive_file_outlined,
                              color: e.isDirectory
                                  ? tokens.colorBrand
                                  : tokens.colorContrast,
                            ),
                            title: Text(
                              e.name,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            subtitle: Text(
                              e.isDirectory ? '文件夹' : _formatBytes(e.size),
                              style: TextStyle(
                                color: tokens.colorBase.withValues(alpha: 0.65),
                              ),
                            ),
                            onTap: () {
                              if (e.isDirectory) {
                                final next = _filesRel.isEmpty
                                    ? e.name
                                    : '$_filesRel/${e.name}';
                                _refreshFiles(rel: next);
                              } else {
                                _revealInExplorer(e.absolutePath);
                              }
                            },
                            trailing: IconButton(
                              tooltip: '打开位置',
                              icon: const Icon(Icons.open_in_new, size: 18),
                              onPressed: () =>
                                  _revealInExplorer(e.absolutePath),
                            ),
                          ),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildWorlds(tokens) {
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
                        final starting = _startingWorld == w.folder;
                        final backingUp = _backingUpWorld == w.folder;
                        return Material(
                          color: tokens.colorRaisedBg,
                          borderRadius: BorderRadius.circular(12),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(12),
                            onTap: isSp ? () => _openWorld(w) : null,
                            child: Padding(
                              padding:
                                  const EdgeInsets.fromLTRB(12, 10, 10, 10),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.center,
                                children: [
                                  _worldIcon(tokens, w),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: isSp
                                        ? _singleplayerWorldMeta(tokens, w)
                                        : _serverWorldMeta(tokens, w),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      if (isSp) ...[
                                        TextButton(
                                          onPressed: _busy || backingUp
                                              ? null
                                              : () => unawaited(
                                                    _backupWorldFromList(w),
                                                  ),
                                          child:
                                              Text(backingUp ? '备份中…' : '备份'),
                                        ),
                                        TextButton(
                                          onPressed: () =>
                                              _openWorld(w, initialTab: 1),
                                          child: const Text('管理'),
                                        ),
                                      ],
                                      ElevatedButton(
                                        onPressed: _busy || starting
                                            ? null
                                            : () => _startWorld(w),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: tokens.colorBrand,
                                          foregroundColor: tokens.colorOnBrand,
                                          disabledBackgroundColor: tokens
                                              .colorBrand
                                              .withValues(alpha: 0.4),
                                          elevation: 0,
                                        ),
                                        child: Text(
                                            starting ? '启动中…' : '开始游戏'),
                                      ),
                                      PopupMenuButton<String>(
                                        onSelected: (v) async {
                                          if (v == 'delete') {
                                            await _deleteWorld(w);
                                          } else if (v == 'edit' && !isSp) {
                                            await _editServer(w);
                                          } else if (v == 'folder' && isSp) {
                                            final root = _instanceRoot ??
                                                await rust.openInstanceFolder(
                                                  instanceId: widget.instanceId,
                                                );
                                            await _revealInExplorer(
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
                                              worldFolder:
                                                  isSp ? w.folder : null,
                                              instanceIconPath: _instance?.icon,
                                              iconDataUrl: pingFav ??
                                                  w.iconDataUrl,
                                              iconPath: w.iconPath,
                                              saveAs: v == 'shortcut_save_as',
                                            );
                                          }
                                        },
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
                      },
                    ),
        ),
      ],
    );
  }

  Widget _singleplayerWorldMeta(tokens, rust.WorldDto w) {
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

  Widget _serverWorldMeta(tokens, rust.WorldDto w) {
    final address = (w.serverAddress ?? w.folder).trim();
    final ping = _serverPings[address];
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
                color: _pingColor(status.pingMs?.toInt(), tokens),
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

  Color _pingColor(int? ms, tokens) {
    if (ms == null) return tokens.colorBase.withValues(alpha: 0.55);
    if (ms < 150) return const Color(0xFF55C057);
    if (ms < 300) return const Color(0xFFE0A100);
    return const Color(0xFFFF5555);
  }

  Widget _worldIcon(tokens, rust.WorldDto w) {
    if (w.kind == 'server') {
      final address = (w.serverAddress ?? w.folder).trim();
      final favicon = _serverPings[address]?.status?.favicon;
      if (favicon != null && favicon.isNotEmpty) {
        final painted = _dataUrlImage(favicon, tokens, w);
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
          errorBuilder: (_, __, ___) => _worldIconFallback(tokens, w),
        ),
      );
    }
    final dataUrl = w.iconDataUrl;
    final painted = dataUrl == null ? null : _dataUrlImage(dataUrl, tokens, w);
    if (painted != null) return painted;
    return _worldIconFallback(tokens, w);
  }

  Widget? _dataUrlImage(String dataUrl, tokens, rust.WorldDto w) {
    final bytes = _tryDecodeDataUrl(dataUrl);
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
          _pingLog(
            '[AML ping] Image.memory paint fail '
            '${w.serverAddress ?? w.folder}: $error',
          );
          return _worldIconFallback(tokens, w);
        },
      ),
    );
  }

  Widget _worldIconFallback(tokens, rust.WorldDto w) {
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

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  List<ParsedLogLine> _logsForDisplay(List<String> liveLogs) {
    final usingLiveLogs = liveLogs.isNotEmpty;
    final raw = usingLiveLogs
        ? liveLogs
        : (_fileLog.isEmpty
            ? const <String>['暂无日志。启动游戏后会显示在这里。']
            : _fileLog.split('\n'));
    var parseChanged = false;

    if (usingLiveLogs) {
      final canAppend = _parsedFromLiveLogs &&
          _parsedRawLogCount <= raw.length &&
          (_parsedRawLogCount == 0 ||
              (_parsedRawLogCount - 1 < raw.length &&
                  raw[_parsedRawLogCount - 1] == _parsedLastRawLine));
      if (canAppend) {
        if (raw.length > _parsedRawLogCount) {
          final appended = raw.sublist(_parsedRawLogCount);
          _liveLogParser.appendAll(appended, _parsedLogs);
          for (final text in appended) {
            final level = detectLogLevel(text);
            if (level != null) _presentLogLevels.add(level);
          }
          parseChanged = true;
        }
      } else {
        _liveLogParser.reset();
        _parsedLogs = [];
        _liveLogParser.appendAll(raw, _parsedLogs);
        _presentLogLevels = {
          for (final line in _parsedLogs)
            if (line.level != null) line.level!,
        };
        parseChanged = true;
      }
      _parsedFromLiveLogs = true;
      _parsedRawLogCount = raw.length;
      _parsedLastRawLine = raw.isEmpty ? null : raw.last;
    } else {
      final fileKey = '${_fileLog.length}:${_fileLog.hashCode}';
      if (_parsedFromLiveLogs || fileKey != _parsedFileLogKey) {
        _parsedFromLiveLogs = false;
        _parsedFileLogKey = fileKey;
        _parsedRawLogCount = raw.length;
        _parsedLastRawLine = raw.isEmpty ? null : raw.last;
        _parsedLogs = parseLogLines(raw);
        _presentLogLevels = {
          for (final line in _parsedLogs)
            if (line.level != null) line.level!,
        };
        parseChanged = true;
      }
    }

    if (parseChanged) _filteredLogsKey = '';
    final query = _logQuery.trim().toLowerCase();
    if (_logFilter == 'all' && query.isEmpty) {
      _filteredLogs = _parsedLogs;
      _filteredLogsKey = 'unfiltered:${_parsedLogs.length}';
      return _filteredLogs;
    }

    final sourceKey =
        '${_parsedLogs.length}:${_parsedLogs.isEmpty ? 0 : _parsedLogs.last.hashCode}';
    final filterKey = '$sourceKey|$_logFilter|$query';
    if (filterKey != _filteredLogsKey) {
      _filteredLogsKey = filterKey;
      _filteredLogs = _parsedLogs.where((line) {
        if (query.isNotEmpty && !line.text.toLowerCase().contains(query)) {
          return false;
        }
        if (_logFilter == 'all') return true;
        final level = line.level ?? LogLevel.info;
        return level.name == _logFilter;
      }).toList(growable: false);
    }
    return _filteredLogs;
  }

  Widget _buildLogs(tokens, List<String> liveLogs) {
    final filtered = _logsForDisplay(liveLogs);
    final present = _presentLogLevels;

    Color colorFor(LogLevel? level) {
      switch (level) {
        case LogLevel.error:
          return const Color(0xFFFF6B6B);
        case LogLevel.warn:
          return const Color(0xFFFFD166);
        case LogLevel.debug:
        case LogLevel.trace:
          return const Color(0xFF8B949E);
        case LogLevel.info:
        case null:
          return const Color(0xFFD7E0E8);
      }
    }

    Widget logChip(String id, String label) {
      final selected = _logFilter == id;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: FilterChip(
          label: Text(label),
          selected: selected,
          onSelected: (_) => setState(() => _logFilter = id),
          selectedColor: tokens.colorBrand.withValues(alpha: 0.28),
          checkmarkColor: tokens.colorBrand,
          labelStyle: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: selected ? tokens.colorContrast : tokens.colorBase,
          ),
          backgroundColor: tokens.colorRaisedBg,
          side: BorderSide(
            color: selected
                ? tokens.colorBrand.withValues(alpha: 0.55)
                : tokens.colorSecondary.withValues(alpha: 0.35),
          ),
          visualDensity: VisualDensity.compact,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              liveLogs.isNotEmpty ? '实时日志' : '启动器日志文件',
              style: TextStyle(
                fontWeight: FontWeight.w700,
                color: tokens.colorContrast,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(
                    text: filtered.map((e) => e.displayText).join('\n'),
                  ),
                );
                if (!mounted) return;
                showAppSnackBar('已复制日志');
              },
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
              child: const Text('复制'),
            ),
            IconButton(
              tooltip: _logFollowTail ? '停止自动滚动' : '跟随最新日志',
              onPressed: () {
                setState(() => _logFollowTail = !_logFollowTail);
                if (_logFollowTail && _logScroll.hasClients) {
                  _logScroll.animateTo(
                    _logScroll.position.maxScrollExtent,
                    duration: const Duration(milliseconds: 160),
                    curve: Curves.easeOut,
                  );
                }
              },
              icon: Icon(
                _logFollowTail
                    ? Icons.vertical_align_bottom
                    : Icons.vertical_align_center,
                color: _logFollowTail
                    ? tokens.colorBrand
                    : tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
            TextButton(
              onPressed: () => _refreshLogs(),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
              child: const Text('刷新'),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                onChanged: (value) {
                  _logSearchDebounce?.cancel();
                  _logSearchDebounce = Timer(
                    const Duration(milliseconds: 200),
                    () {
                      if (mounted) setState(() => _logQuery = value);
                    },
                  );
                },
                style: TextStyle(color: tokens.colorContrast, fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索日志…',
                  hintStyle: TextStyle(
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                  filled: true,
                  fillColor: tokens.colorRaisedBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: Row(
            children: [
              logChip('all', 'All'),
              logChip('error', 'Error'),
              logChip('warn', 'Warn'),
              logChip('info', 'Info'),
              if (present.contains(LogLevel.debug) || _logFilter == 'debug')
                logChip('debug', 'Debug'),
              if (present.contains(LogLevel.trace) || _logFilter == 'trace')
                logChip('trace', 'Trace'),
              const SizedBox(width: 8),
              Text(
                '${filtered.length} / ${_parsedLogs.length}',
                style: TextStyle(
                  fontSize: 12,
                  color: tokens.colorBase.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: const Color(0xFF0D1117),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: tokens.colorSecondary.withValues(alpha: 0.25),
              ),
            ),
            child: filtered.isEmpty
                ? Center(
                    child: Text(
                      '没有匹配的日志行',
                      style: TextStyle(
                        color: tokens.colorBase.withValues(alpha: 0.6),
                      ),
                    ),
                  )
                : SelectionArea(
                    child: ListView.builder(
                      controller: _logScroll,
                      itemCount: filtered.length,
                      // Fixed extent = true virtualization (skip layout measure).
                      itemExtent: _logLineExtent,
                      scrollCacheExtent: const ScrollCacheExtent.pixels(400),
                      addAutomaticKeepAlives: false,
                      addRepaintBoundaries: true,
                      itemBuilder: (context, index) {
                        final line = filtered[index];
                        final bg = switch (line.level) {
                          LogLevel.error => const Color(0x22FF6B6B),
                          LogLevel.warn => const Color(0x22FFD166),
                          _ => null,
                        };
                        return ColoredBox(
                          color: bg ?? Colors.transparent,
                          child: Text(
                            line.text.isEmpty ? ' ' : line.displayText,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.fade,
                            style: TextStyle(
                              fontFamily: 'Consolas',
                              fontSize: 12,
                              height: _logLineExtent / 12,
                              color: colorFor(line.level),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
          ),
        ),
      ],
    );
  }

  Widget _buildScreenshots(tokens) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text(
              '截图',
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(width: 8),
            Text(
              '${_screenshots.length} 张',
              style: TextStyle(
                fontSize: 13,
                color: tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: _openScreenshotsFolder,
              icon: const Icon(Icons.folder_open, size: 16),
              label: const Text('打开文件夹'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
            TextButton.icon(
              onPressed: _screenshotsLoading ? null : _refreshScreenshots,
              icon: const Icon(Icons.refresh, size: 16),
              label: const Text('刷新'),
              style:
                  TextButton.styleFrom(foregroundColor: tokens.colorContrast),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _screenshotsLoading && _screenshots.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : _screenshots.isEmpty
                  ? Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.photo_camera_outlined,
                            size: 40,
                            color: tokens.colorBase.withValues(alpha: 0.45),
                          ),
                          const SizedBox(height: 12),
                          Text(
                            '暂无截图',
                            style: TextStyle(
                              fontWeight: FontWeight.w700,
                              color: tokens.colorContrast,
                            ),
                          ),
                          const SizedBox(height: 6),
                          Text(
                            '在游戏中按 F2 截图后会显示在这里',
                            style: TextStyle(
                              fontSize: 13,
                              color: tokens.colorBase.withValues(alpha: 0.65),
                            ),
                          ),
                        ],
                      ),
                    )
                  : LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final columns = width >= 1100
                            ? 4
                            : width >= 760
                                ? 3
                                : 2;
                        return GridView.builder(
                          padding: EdgeInsets.zero,
                          gridDelegate:
                              SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: columns,
                            crossAxisSpacing: 10,
                            mainAxisSpacing: 10,
                            childAspectRatio: 16 / 9,
                          ),
                          itemCount: _screenshots.length,
                          itemBuilder: (context, index) {
                            final shot = _screenshots[index];
                            return Material(
                              color: tokens.colorRaisedBg,
                              borderRadius: BorderRadius.circular(10),
                              clipBehavior: Clip.antiAlias,
                              child: InkWell(
                                onTap: () => _previewScreenshot(index),
                                child: Stack(
                                  fit: StackFit.expand,
                                  children: [
                                    CachedRemoteImage(
                                      url: shot.path,
                                      fit: BoxFit.cover,
                                      placeholder: ColoredBox(
                                        color: tokens.colorSecondary
                                            .withValues(alpha: 0.12),
                                        child: const Center(
                                          child: SizedBox(
                                            width: 20,
                                            height: 20,
                                            child: CircularProgressIndicator(
                                              strokeWidth: 2,
                                            ),
                                          ),
                                        ),
                                      ),
                                      error: ColoredBox(
                                        color: tokens.colorSecondary
                                            .withValues(alpha: 0.12),
                                        child: Icon(
                                          Icons.broken_image_outlined,
                                          color: tokens.colorBase
                                              .withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ),
                                    Positioned(
                                      left: 0,
                                      right: 0,
                                      bottom: 0,
                                      child: DecoratedBox(
                                        decoration: BoxDecoration(
                                          gradient: LinearGradient(
                                            begin: Alignment.bottomCenter,
                                            end: Alignment.topCenter,
                                            colors: [
                                              Colors.black
                                                  .withValues(alpha: 0.72),
                                              Colors.transparent,
                                            ],
                                          ),
                                        ),
                                        child: Padding(
                                          padding: const EdgeInsets.fromLTRB(
                                            8,
                                            18,
                                            8,
                                            8,
                                          ),
                                          child: Column(
                                            crossAxisAlignment:
                                                CrossAxisAlignment.start,
                                            mainAxisSize: MainAxisSize.min,
                                            children: [
                                              Text(
                                                shot.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: const TextStyle(
                                                  color: Colors.white,
                                                  fontSize: 11,
                                                  fontWeight: FontWeight.w700,
                                                ),
                                              ),
                                              if (shot.modified != null)
                                                Text(
                                                  _formatScreenshotTime(
                                                    shot.modified,
                                                  ),
                                                  style: TextStyle(
                                                    color: Colors.white
                                                        .withValues(
                                                            alpha: 0.85),
                                                    fontSize: 10,
                                                  ),
                                                ),
                                            ],
                                          ),
                                        ),
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      },
                    ),
        ),
      ],
    );
  }
}

class _ServerPingState {
  const _ServerPingState({
    required this.refreshing,
    this.status,
    this.offline = false,
  });

  final bool refreshing;
  final rust.ServerStatusDto? status;
  final bool offline;
}

class _ScreenshotEntry {
  final String name;
  final String path;
  final int size;
  final DateTime? modified;

  const _ScreenshotEntry({
    required this.name,
    required this.path,
    required this.size,
    required this.modified,
  });
}

class _FsEntry {
  final String name;
  final bool isDirectory;
  final int size;
  final DateTime? modified;
  final String absolutePath;

  const _FsEntry({
    required this.name,
    required this.isDirectory,
    required this.size,
    required this.modified,
    required this.absolutePath,
  });
}
