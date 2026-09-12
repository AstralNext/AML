import 'dart:io';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/app/state/progress_state.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/app_colors.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_shared.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'package:window_manager/window_manager.dart';

/// 状态栏组件
/// 实现了PreferredSizeWidget接口以指定首选高度
class StatusBar extends StatefulWidget implements PreferredSizeWidget {
  const StatusBar({super.key});

  // 统一的状态栏高度常量
  static const double kStatusBarHeight = 48;

  /// 指定状态栏的首选高度
  @override
  Size get preferredSize => const Size.fromHeight(kStatusBarHeight);

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  @override
  Widget build(BuildContext context) {
    return Container(
      height: StatusBar.kStatusBarHeight,
      color: Colors.transparent,
      child: Row(
        children: [
          Expanded(
            child: GestureDetector(
              // 设置behavior确保即使在透明区域也能捕获手势事件
              behavior: HitTestBehavior.opaque,
              onPanStart: (details) {
                if (Platform.isWindows ||
                    Platform.isMacOS ||
                    Platform.isLinux) {
                  windowManager.startDragging();
                }
              },
              // 使用Container代替SizedBox，并设置behavior确保整个区域可点击
              child: Container(
                width: double.infinity,
                height: double.infinity,
                color: Colors.transparent, // 透明背景但可以接收事件
                // 使用Stack代替Align，确保整个区域都能响应手势
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: Container(
                        color: Colors.transparent, // 确保整个区域都能接收事件
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Padding(
                        padding: const EdgeInsets.only(left: 14.0),
                        child: Image.asset(
                          'assets/logo.png',
                          height: 56,
                          fit: BoxFit.contain,
                          filterQuality: FilterQuality.high,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const _DownloaderStatusButton(),
          // 占位 15宽度
          const SizedBox(width: 15),
          // 游戏状态显示
          const _GameStatus(),
          // 占位 15宽度
          const SizedBox(width: 15),
          // 最小化按钮
          CustomButton(
            icon: Icons.horizontal_rule,
            label: '最小化',
            onTap: () {
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
                windowManager.minimize();
              }
            },
          ),
          // 最大化/还原按钮
          const _MaximizeButton(),
          // 关闭按钮
          CustomButton(
            icon: Icons.close,
            label: '关闭',
            hoverBackgroundColor: AppColors.dangerHover,
            hoverIconColor: AppColors.dangerOnHover,
            onTap: () {
              if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
                windowManager.close();
              }
            },
          ),
        ],
      ),
    );
  }
}

// _GameStatus — process indicator for running instances
class _GameStatus extends StatefulWidget {
  const _GameStatus();

  @override
  State<_GameStatus> createState() => _GameStatusState();
}

class _GameStatusState extends State<_GameStatus>
    with SingleTickerProviderStateMixin {
  late final AnchoredDropdownController _dropdown;

  @override
  void initState() {
    super.initState();
    _dropdown = AnchoredDropdownController(
      vsync: this,
      onOpenChanged: () {
        if (mounted) setState(() {});
      },
    );
  }

  @override
  void dispose() {
    _dropdown.dispose();
    super.dispose();
  }

  List<({String id, String name, rust.InstanceDto? instance})> _runningEntries(
    InstanceStore store,
  ) {
    final running = store.runningIds.value;
    final byId = {for (final i in store.instances.value) i.id: i};
    final entries = <({String id, String name, rust.InstanceDto? instance})>[];
    for (final id in running) {
      final instance = byId[id];
      entries.add((
        id: id,
        name: instance?.name ?? '实例',
        instance: instance,
      ));
    }
    // Prefer known instances order when available.
    entries.sort((a, b) {
      if (a.instance != null && b.instance == null) return -1;
      if (a.instance == null && b.instance != null) return 1;
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  void _toggleOrOpen(InstanceStore store) {
    final entries = _runningEntries(store);
    if (entries.isEmpty) return;

    if (entries.length == 1) {
      getIt<NavigationState>().openInstance(entries.first.id);
      return;
    }

    _dropdown.toggle(
      context: context,
      createEntry: () => _dropdown.buildEntry(
        context: context,
        minWidth: 240,
        openUpThreshold: 180,
        panelBuilder: (overlayContext, openUp) {
          final tokens = context.tokens;
          final live = _runningEntries(store);
          return Container(
            constraints: const BoxConstraints(maxHeight: 280),
            decoration: dropdownPanelDecoration(tokens, openUp: openUp),
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 6),
              shrinkWrap: true,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
                  child: Text(
                    '运行中的实例',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: tokens.colorBase.withValues(alpha: 0.75),
                    ),
                  ),
                ),
                for (final entry in live)
                  DropdownHoverSurface(
                    tokens: tokens,
                    borderRadius: BorderRadius.circular(8),
                    margin: const EdgeInsets.symmetric(horizontal: 6),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    baseColor: Colors.transparent,
                    onTap: () {
                      _dropdown.close();
                      getIt<NavigationState>().openInstance(entry.id);
                    },
                    child: Row(
                      children: [
                        if (entry.instance != null)
                          InstanceIcon(
                            instanceId: entry.instance!.id,
                            iconPath: entry.instance!.icon,
                            size: 28,
                            borderRadius: 6,
                          )
                        else
                          Container(
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              color: tokens.colorRaisedBg,
                              borderRadius: BorderRadius.circular(6),
                            ),
                            child: const Icon(Icons.videogame_asset, size: 16),
                          ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                entry.name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: tokens.colorContrast,
                                  fontWeight: FontWeight.w600,
                                  fontSize: 13,
                                ),
                              ),
                              Text(
                                '运行中',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: const Color(0xFF3BA55D)
                                      .withValues(alpha: 0.9),
                                ),
                              ),
                            ],
                          ),
                        ),
                        IconButton(
                          tooltip: '停止',
                          iconSize: 18,
                          visualDensity: VisualDensity.compact,
                          onPressed: () async {
                            await store.kill(entry.id);
                            if (!mounted) return;
                            if (store.runningIds.value.length <= 1) {
                              _dropdown.close();
                            } else {
                              _dropdown.scheduleRebuild();
                            }
                          },
                          icon: Icon(
                            Icons.stop_circle_outlined,
                            color: tokens.colorBase.withValues(alpha: 0.7),
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final store = getIt<InstanceStore>();
    return Watch((context) {
      final running = store.runningIds.value;
      final name = store.primaryRunningName;
      final isRunning = running.isNotEmpty;
      final multi = running.length > 1;
      final label = isRunning
          ? (multi
              ? '运行中 · ${running.length} 个实例'
              : '运行中 · ${name ?? '游戏'}')
          : '未运行';

      // Auto-close if nothing left to show.
      if ((!isRunning || !multi) && _dropdown.isOpen) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_dropdown.isOpen) _dropdown.close();
        });
      } else if (_dropdown.isOpen) {
        _dropdown.scheduleRebuild();
      }

      return CompositedTransformTarget(
        link: _dropdown.layerLink,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: !isRunning ? null : () => _toggleOrOpen(store),
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 2),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
              decoration: BoxDecoration(
                color: _dropdown.isOpen
                    ? tokens.colorBrand.withValues(alpha: 0.12)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isRunning
                      ? tokens.colorBrand.withAlpha(160)
                      : tokens.colorBase.withAlpha(100),
                  width: 1,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    isRunning ? Icons.circle : Icons.videogame_asset_outlined,
                    size: isRunning ? 10 : 20,
                    color: isRunning
                        ? const Color(0xFF3BA55D)
                        : tokens.colorBase.withAlpha(100),
                  ),
                  const SizedBox(width: 8),
                  Text(
                    label,
                    style: TextStyle(
                      color: tokens.colorContrast,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  if (isRunning) ...[
                    const SizedBox(width: 4),
                    AnimatedRotation(
                      turns: multi && _dropdown.isOpen ? 0.5 : 0,
                      duration: const Duration(milliseconds: 150),
                      child: Icon(
                        multi ? Icons.expand_more : Icons.open_in_new,
                        size: 16,
                        color: tokens.colorBase.withValues(alpha: 0.55),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      );
    });
  }
}

// 下载器状态按钮 — 反映真实进度列表，而非假态
class _DownloaderStatusButton extends StatelessWidget {
  const _DownloaderStatusButton();

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final progressStore = getIt<ProgressStore>();
    return Watch((context) {
      final items = progressStore.progressList.value;
      // Subscribe to failed flags so badge updates when a task fails.
      var failedCount = 0;
      for (final item in items) {
        if (item.failed.value) failedCount++;
      }
      final busy = items.isNotEmpty;
      final badgeCount = items.length;
      final hasFailed = failedCount > 0;

      return Stack(
        clipBehavior: Clip.none,
        children: [
          CustomButton(
            icon: hasFailed
                ? Icons.error_outline
                : busy
                    ? Icons.downloading
                    : Icons.download,
            label: hasFailed
                ? '下载出错'
                : busy
                    ? '查看下载进度'
                    : '下载',
            size: ButtonSize.medium,
            hoverIconColor: hasFailed
                ? const Color(0xFFFF7B7B)
                : busy
                    ? tokens.colorBrand
                    : tokens.colorButtonTextSelected.withAlpha(200),
            iconColor: hasFailed
                ? const Color(0xFFFF7B7B)
                : busy
                    ? tokens.colorBrand
                    : tokens.colorButtonTextSelected.withAlpha(200),
            onTap: () {
              progressStore.progressVisibility.value =
                  !progressStore.progressVisibility.value;
            },
          ),
          if (badgeCount > 0)
            Positioned(
              right: 2,
              top: 2,
              child: Container(
                constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
                padding: const EdgeInsets.symmetric(horizontal: 4),
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: hasFailed
                      ? const Color(0xFFB3261E)
                      : tokens.colorBrand,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  badgeCount > 9 ? '9+' : '$badgeCount',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: hasFailed ? Colors.white : tokens.colorOnBrand,
                  ),
                ),
              ),
            ),
        ],
      );
    });
  }
}

/// 最大化/还原按钮组件
/// 根据窗口是否最大化显示不同的图标
class _MaximizeButton extends StatefulWidget {
  const _MaximizeButton();

  @override
  State<_MaximizeButton> createState() => _MaximizeButtonState();
}

class _MaximizeButtonState extends State<_MaximizeButton> with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    _checkWindowState();
    // 注册窗口事件监听器
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    // 移除窗口事件监听器
    windowManager.removeListener(this);
    super.dispose();
  }

  // 窗口最大化事件回调
  @override
  void onWindowMaximize() {
    setState(() {
      _isMaximized = true;
    });
  }

  // 窗口还原事件回调
  @override
  void onWindowUnmaximize() {
    setState(() {
      _isMaximized = false;
    });
  }

  // 检查窗口状态并更新图标
  Future<void> _checkWindowState() async {
    if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
      final maximized = await windowManager.isMaximized();
      if (maximized != _isMaximized) {
        setState(() {
          _isMaximized = maximized;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return CustomButton(
      icon: _isMaximized ? Icons.filter_none : Icons.crop_square_outlined,
      label: _isMaximized ? '还原' : '最大化',
      onTap: () async {
        if (Platform.isWindows || Platform.isMacOS || Platform.isLinux) {
          if (_isMaximized) {
            await windowManager.unmaximize();
          } else {
            await windowManager.maximize();
          }
          // 操作后更新状态
          _checkWindowState();
        }
      },
    );
  }
}
