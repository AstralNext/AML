import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/instance_content_tab.dart';
import 'package:aml/src/features/instances/ui/instance_files_tab.dart';
import 'package:aml/src/features/instances/ui/instance_logs_tab.dart';
import 'package:aml/src/features/instances/ui/instance_overview_tab.dart';
import 'package:aml/src/features/instances/ui/instance_screenshots_tab.dart';
import 'package:aml/src/features/instances/ui/instance_settings_page.dart';
import 'package:aml/src/features/instances/ui/instance_worlds_tab.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/utils/minecraft_labels.dart';
import 'package:aml/src/shared/utils/relative_time.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:aml/src/shared/widgets/components/tabs/animated_tab_bar.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:signals_flutter/signals_flutter.dart';

/// 实例详情页（薄壳）：页头 + 标签栏 + 各标签页装配。
/// 各标签页（概览/文件/世界/日志/截图）自持状态与刷新逻辑。
class InstanceDetailPage extends StatefulWidget {
  const InstanceDetailPage({super.key, required this.instanceId});

  final String instanceId;

  @override
  State<InstanceDetailPage> createState() => _InstanceDetailPageState();
}

class _InstanceDetailPageState extends State<InstanceDetailPage> {
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
    // 提前挂上实时日志流，切换到日志页即可看到（幂等）。
    _store.ensureLiveLogsLoaded(widget.instanceId);
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
                          instanceId: widget.instanceId,
                          onSeeAllScreenshots: () {
                            setState(() => _tab = _tabScreenshots);
                          },
                        ),
                      _tabFiles => InstanceFilesTab(
                          instanceId: widget.instanceId,
                        ),
                      _tabWorlds => InstanceWorldsTab(
                          instanceId: widget.instanceId,
                          onViewLogs: () => setState(() => _tab = _tabLogs),
                        ),
                      _tabLogs => InstanceLogsTab(
                          instanceId: widget.instanceId,
                        ),
                      _ => InstanceScreenshotsTab(
                          instanceId: widget.instanceId,
                        ),
                    },
                ],
              ),
            ),
          ),
        ],
      );
    });
  }
}
