import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/export_pack_dialog.dart';
import 'package:aml/src/features/instances/ui/instance_settings_controller.dart';
import 'package:aml/src/features/instances/ui/instance_settings_general_tab.dart';
import 'package:aml/src/features/instances/ui/instance_settings_hooks_tab.dart';
import 'package:aml/src/features/instances/ui/instance_settings_install_tab.dart';
import 'package:aml/src/features/instances/ui/instance_settings_java_tab.dart';
import 'package:aml/src/features/instances/ui/instance_settings_window_tab.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

Future<void> showInstanceSettingsDialog({
  required BuildContext context,
  required String instanceId,
  int initialTab = 0,
}) {
  return showDialog<void>(
    context: context,
    barrierDismissible: true,
    barrierColor: Colors.transparent,
    builder: (_) => InstanceSettingsDialog(
      instanceId: instanceId,
      initialTab: initialTab,
    ),
  );
}

class _SettingsTab {
  const _SettingsTab({
    required this.id,
    required this.label,
    required this.icon,
  });

  final String id;
  final String label;
  final IconData icon;
}

const _tabs = [
  _SettingsTab(id: 'general', label: '通用', icon: Icons.schedule_outlined),
  _SettingsTab(id: 'install', label: '安装', icon: Icons.build_outlined),
  _SettingsTab(
    id: 'window',
    label: '游戏窗口',
    icon: Icons.desktop_windows_outlined,
  ),
  _SettingsTab(
    id: 'java',
    label: 'Java 及内存',
    icon: Icons.coffee_outlined,
  ),
  _SettingsTab(id: 'hooks', label: '启动 Hooks', icon: Icons.code_outlined),
];

/// 实例设置对话框：左栏 tab 导航，右栏为各设置标签页。
/// 表单状态与保存编排在 [InstanceSettingsController]，
/// 各标签页 UI 在 instance_settings_*_tab.dart 文件中。
class InstanceSettingsDialog extends StatefulWidget {
  const InstanceSettingsDialog({
    super.key,
    required this.instanceId,
    this.initialTab = 0,
  });

  final String instanceId;
  final int initialTab;

  @override
  State<InstanceSettingsDialog> createState() => _InstanceSettingsDialogState();
}

class _InstanceSettingsDialogState extends State<InstanceSettingsDialog>
    with SingleTickerProviderStateMixin {
  late final ModalMotion _motion;
  late final InstanceSettingsController _controller;

  final _store = getIt<InstanceStore>();
  int _selectedTab = 0;
  bool _busyAction = false;

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab.clamp(0, _tabs.length - 1);
    _motion = ModalMotion(this)..forward();
    _controller = InstanceSettingsController(instanceId: widget.instanceId);
    unawaited(_controller.loadMeta());
  }

  @override
  void dispose() {
    _controller.dispose();
    _motion.dispose();
    super.dispose();
  }

  rust.InstanceDto? get _instance {
    for (final item in _store.instances.value) {
      if (item.id == widget.instanceId) return item;
    }
    return null;
  }

  Future<void> _close() async {
    await _controller.commitName();
    if (!mounted) return;
    _motion.reverse();
    Navigator.of(context).pop();
  }

  Future<void> _duplicateInstance() async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    // Close the dialog; progress continues in the status bar.
    unawaited(_close());
    try {
      final created = await _store.duplicate(widget.instanceId);
      getIt<NavigationState>().openInstance(created.id);
    } catch (_) {
      // Errors are already surfaced by InstanceStore.duplicate.
    }
  }

  Future<void> _openExportDialog() async {
    if (_busyAction) return;
    await showExportPackDialog(
      context: context,
      instanceId: widget.instanceId,
    );
  }

  Future<void> _deleteInstance() async {
    final instance = _instance;
    if (instance == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除实例'),
        content: Text('确定删除「${instance.name}」？此操作不可撤销。'),
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
      if (getIt<NavigationState>().selectedInstanceId.value == instance.id) {
        getIt<NavigationState>().closeInstance();
      }
      await _store.remove(instance.id);
      if (mounted) {
        showAppSnackBar('已删除「${instance.name}」');
        unawaited(_close());
      }
    } catch (error) {
      if (mounted) showAppSnackBar('删除失败: $error', isError: true);
    }
  }

  Future<void> _repairInstance({required bool force}) async {
    setState(() => _busyAction = true);
    try {
      await _store.install(widget.instanceId, force: force);
      if (mounted) {
        showAppSnackBar(force ? '已重新安装实例' : '实例修复完成');
      }
    } catch (error) {
      if (mounted) showAppSnackBar('操作失败: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _unlinkModpack() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('解除整合包关联'),
        content: const Text(
          '解除后可自由更改加载器与版本，但将失去自动更新。已安装内容不会被删除。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('解除关联'),
          ),
        ],
      ),
    );
    if (ok != true) return;
    setState(() => _busyAction = true);
    try {
      await _store.unlinkModpack(widget.instanceId);
      if (mounted) showAppSnackBar('已解除整合包关联');
      _controller.syncFromInstance(_instance);
    } catch (error) {
      if (mounted) showAppSnackBar('解除失败: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _reinstallModpack() async {
    setState(() => _busyAction = true);
    try {
      await _store.reinstallModpack(widget.instanceId);
      if (mounted) showAppSnackBar('整合包已重新安装');
      _controller.syncFromInstance(_instance);
    } catch (error) {
      if (mounted) showAppSnackBar('重装失败: $error', isError: true);
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Future<void> _switchModpackVersion() async {
    final instance = _instance;
    final projectId = instance?.modpackProjectId;
    if (instance == null || projectId == null || projectId.isEmpty) return;
    setState(() => _busyAction = true);
    try {
      await ContentInstallHelper.switchModpackVersion(
        context: context,
        instanceId: instance.id,
        projectId: projectId,
        title: instance.modpackTitle ?? instance.name,
        currentVersionId: instance.modpackVersionId,
      );
      _controller.syncFromInstance(_instance);
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Widget _buildContent(rust.InstanceDto instance) {
    switch (_tabs[_selectedTab].id) {
      case 'general':
        return InstanceSettingsGeneralTab(
          controller: _controller,
          instance: instance,
          busy: _busyAction,
          onDuplicate: _duplicateInstance,
          onExport: _openExportDialog,
          onDelete: _deleteInstance,
        );
      case 'install':
        return InstanceSettingsInstallTab(
          instance: instance,
          busy: _busyAction,
          onSwitchModpackVersion: _switchModpackVersion,
          onReinstallModpack: _reinstallModpack,
          onUnlinkModpack: _unlinkModpack,
          onRepair: () => _repairInstance(force: false),
          onReinstall: () => _repairInstance(force: true),
        );
      case 'window':
        return InstanceSettingsWindowTab(controller: _controller);
      case 'java':
        return InstanceSettingsJavaTab(controller: _controller);
      case 'hooks':
        return InstanceSettingsHooksTab(controller: _controller);
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Watch((context) {
      final instance = _instance;
      if (instance == null) {
        return AnimatedModalDialog.fromMotion(
          motion: _motion,
          onClose: _close,
          child: Container(
            width: 928,
            height: 640,
            decoration: BoxDecoration(
              color: tokens.colorRaisedBg,
              borderRadius: BorderRadius.circular(20),
            ),
            child: const Center(child: CircularProgressIndicator()),
          ),
        );
      }

      return AnimatedModalDialog.fromMotion(
        motion: _motion,
        onClose: _close,
        child: Container(
          width: 928,
          height: 640,
          decoration: BoxDecoration(
            color: tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
          ),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 18, 18, 12),
                child: Row(
                  children: [
                    InstanceIcon(
                      instanceId: instance.id,
                      iconPath: instance.icon,
                      size: 28,
                      borderRadius: 8,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        '${instance.name} > 设置',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ),
                    ListenableBuilder(
                      listenable: _controller,
                      builder: (context, _) {
                        if (!_controller.saving) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: tokens.colorBrand,
                            ),
                          ),
                        );
                      },
                    ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: _close,
                      icon: Icon(Icons.close, color: tokens.colorContrast),
                    ),
                  ],
                ),
              ),
              ListenableBuilder(
                listenable: _controller,
                builder: (context, _) {
                  final error = _controller.error;
                  if (error == null) return const SizedBox.shrink();
                  return Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Text(
                        error,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                    ),
                  );
                },
              ),
              Divider(
                height: 1,
                color: tokens.colorSecondary.withValues(alpha: 0.2),
              ),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 220,
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(16, 16, 8, 16),
                        children: [
                          for (var i = 0; i < _tabs.length; i++)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 6),
                              child: NavRectButton(
                                icon: _tabs[i].icon,
                                text: _tabs[i].label,
                                isSelected: _selectedTab == i,
                                width: double.infinity,
                                onTap: () => setState(() => _selectedTab = i),
                              ),
                            ),
                        ],
                      ),
                    ),
                    VerticalDivider(
                      width: 1,
                      color: tokens.colorSecondary.withValues(alpha: 0.2),
                    ),
                    Expanded(child: _buildContent(instance)),
                  ],
                ),
              ),
            ],
          ),
        ),
      );
    });
  }
}
