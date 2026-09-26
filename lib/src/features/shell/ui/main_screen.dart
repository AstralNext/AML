import 'dart:async';

import 'package:aml/src/app/app_store.dart';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/app/state/pending_launch_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/settings/application/app_update_service.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/features/settings/ui/update_available_dialog.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/app_bar/status_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/side_navigation.dart';
import 'package:aml/src/shared/widgets/components/overlays/progress_box.dart';
import 'package:aml/src/features/discover/ui/author_detail_page.dart';
import 'package:aml/src/features/discover/ui/project_detail_page.dart';
import 'package:aml/src/features/instances/ui/instance_detail_page.dart';
import 'package:aml/src/features/instances/ui/world_detail_page.dart';
import 'package:aml/src/features/shell/main_navigation.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart' hide BoxDecoration, BoxShadow;
import 'package:flutter_inset_shadow/flutter_inset_shadow.dart';
import 'package:signals_flutter/signals_flutter.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen>
    with AutomaticKeepAliveClientMixin {
  late final AppStore _appStore = getIt<AppStore>();
  late final NavigationState _navigation = getIt<NavigationState>();

  /// Built on first visit so Discover/Wardrobe initState do not run at cold start.
  final Map<String, Widget> _tabWidgets = {};

  @override
  bool get wantKeepAlive => true;

  Widget _ensureTab(String id) {
    return _tabWidgets.putIfAbsent(id, () {
      final config = MainNavigationConfig.pages.firstWhere((p) => p.id == id);
      return config.pageBuilder();
    });
  }

  @override
  void initState() {
    super.initState();
    _ensureTab('home');
    effect(() {
      final page = _appStore.navigation.currentPage.value;
      if (page != 'discover') {
        // 离开发现页时丢掉解码图，避免图标长期占 ImageCache。
        PaintingBinding.instance.imageCache.clear();
        PaintingBinding.instance.imageCache.clearLiveImages();
      }
    });
    final pending = getIt<PendingLaunchState>();
    pending.onPending = (_) {
      unawaited(_consumePendingLaunch());
    };
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_consumePendingLaunch());
      unawaited(_maybeCheckAppUpdates());
    });
  }

  Future<void> _maybeCheckAppUpdates() async {
    final ui = getIt<UiSettingsState>();
    if (!ui.checkUpdatesOnStartup.value) return;

    // Let the first frame settle before network + dialog.
    await Future<void>.delayed(const Duration(milliseconds: 800));
    if (!mounted) return;

    try {
      final result = await getIt<AppUpdateService>().check();
      if (!mounted || !result.hasUpdate) return;
      final update = result.update!;
      if (update.latestVersion == ui.dismissedUpdateTag.value) return;

      final action = await showUpdateAvailableDialog(
        context,
        update: update,
      );
      if (!mounted) return;
      if (action == UpdateDialogAction.skip) {
        ui.setDismissedUpdateTag(update.latestVersion);
      }
    } catch (e) {
      debugPrint('startup update check failed: $e');
    }
  }

  @override
  void dispose() {
    final pending = getIt<PendingLaunchState>();
    if (pending.onPending != null) {
      pending.onPending = null;
    }
    super.dispose();
  }

  Future<void> _consumePendingLaunch() async {
    final link = getIt<PendingLaunchState>().consume();
    if (link == null || !mounted) return;

    if (!await ensureAccountForLaunch(context)) {
      showAppSnackBar('需要账号才能通过快捷方式启动', isError: true);
      return;
    }
    if (!mounted) return;

    final store = getIt<InstanceStore>();
    try {
      showAppSnackBar('正在通过快捷方式启动…');
      getIt<NavigationState>().openInstance(link.instanceId);
      await store.launch(
        link.instanceId,
        quickPlaySingleplayer: link.worldFolder,
        quickPlayMultiplayer: link.serverAddress,
      );
      if (!mounted) return;
      final label = link.serverAddress != null
          ? '服务器'
          : (link.worldFolder != null ? '世界' : '实例');
      showAppSnackBar('已启动$label');
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('快捷方式启动失败: $e', isError: true);
    }
  }

  Widget _getCurrentPage() {
    final projectId = _navigation.selectedProjectId.watch(context);
    final authorId = _navigation.selectedAuthorId.watch(context);
    final instanceId = _navigation.selectedInstanceId.watch(context);
    final currentPage = _appStore.navigation.currentPage.watch(context);
    final selectedIndex =
        MainNavigationConfig.pages.indexWhere((page) => page.id == currentPage);
    final activeId =
        selectedIndex != -1 ? currentPage : MainNavigationConfig.pages.first.id;
    _ensureTab(activeId);

    // Keep visited tabs mounted under overlays so library filters / scroll survive
    // opening an instance / project and coming back. Unvisited tabs stay empty.
    final base = IndexedStack(
      index: selectedIndex != -1 ? selectedIndex : 0,
      children: MainNavigationConfig.pages.map((pageConfig) {
        final child = _tabWidgets[pageConfig.id];
        return Offstage(
          offstage: pageConfig.id != activeId,
          child: child ?? const SizedBox.shrink(),
        );
      }).toList(),
    );

    // 层级堆叠：项目详情 > 作者详情 > 世界/实例详情 > 主标签页。
    // 下层 overlay 保持挂载（Offstage），这样从项目详情返回实例详情时，
    // 实例详情的标签页、滚动位置、列表状态都不会丢失。
    final showBase = projectId == null && authorId == null && instanceId == null;
    final showInstance = instanceId != null && projectId == null && authorId == null;
    final showAuthor = authorId != null && projectId == null;

    Widget? instanceOverlay;
    if (instanceId != null) {
      final world = _navigation.selectedWorld.watch(context);
      if (world != null) {
        instanceOverlay = WorldDetailPage(
          key: ValueKey('world:$instanceId:${world.folder}'),
          instanceId: instanceId,
          world: world,
        );
      } else {
        instanceOverlay = InstanceDetailPage(
          key: ValueKey('instance:$instanceId'),
          instanceId: instanceId,
        );
      }
    }

    Widget? authorOverlay;
    if (authorId != null) {
      final authorType = _navigation.selectedAuthorType.value;
      authorOverlay = AuthorDetailPage(
        key: ValueKey('author:$authorType:$authorId'),
        authorId: authorId,
        authorType: authorType,
        preview: _navigation.selectedAuthorPreview.value,
      );
    }

    Widget? projectOverlay;
    if (projectId != null) {
      projectOverlay = ProjectDetailPage(
        key: ValueKey('project:$projectId'),
        projectId: projectId,
        preview: _navigation.selectedProjectPreview.value,
      );
    }

    // Always keep the same Stack → Offstage → IndexedStack shape. Switching
    // between `return base` and `return Stack(base)` used to dispose Discover
    // (and other tab) State, so closing a modpack landed on the default Mods tab.
    return Stack(
      fit: StackFit.expand,
      children: [
        Offstage(
          offstage: !showBase,
          child: TickerMode(
            enabled: showBase,
            child: base,
          ),
        ),
        if (instanceOverlay != null)
          Offstage(
            offstage: !showInstance,
            child: TickerMode(
              enabled: showInstance,
              child: instanceOverlay,
            ),
          ),
        if (authorOverlay != null)
          Offstage(
            offstage: !showAuthor,
            child: TickerMode(
              enabled: showAuthor,
              child: authorOverlay,
            ),
          ),
        if (projectOverlay != null) projectOverlay,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final tokens = context.tokens;

    return Scaffold(
      backgroundColor: tokens.colorRaisedBg,
      appBar: const StatusBar(),
      body: Stack(
        children: [
          Row(
            children: [
              const SideNavigation(),
              Expanded(
                child: Container(
                  clipBehavior: Clip.antiAlias,
                  decoration: BoxDecoration(
                    color: tokens.colorBg,
                    // Match app-contents::before: soft inset + surface-5 border.
                    boxShadow: const [
                      BoxShadow(
                        offset: Offset(1, 1),
                        blurRadius: 15,
                        color: Color(0x1A000000),
                        inset: true,
                      ),
                    ],
                    border: Border(
                      left: BorderSide(
                        color: tokens.colorDivider,
                        width: 1,
                      ),
                      top: BorderSide(
                        color: tokens.colorDivider,
                        width: 1,
                      ),
                    ),
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(20),
                    ),
                  ),
                  child: _getCurrentPage(),
                ),
              ),
            ],
          ),
          // 常驻挂载，由 ProgressBox 内部根据 progressVisibility 播放进/退场动画。
          const ProgressBox(),
        ],
      ),
    );
  }
}
