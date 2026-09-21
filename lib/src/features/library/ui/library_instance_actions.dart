import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/instance_settings_page.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/utils/desktop_shortcut.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

mixin LibraryInstanceActions<T extends StatefulWidget> on State<T> {
  InstanceStore get _store => getIt<InstanceStore>();

  Future<void> playOrStop(rust.InstanceDto instance) async {
    final store = _store;
    try {
      if (store.isRunning(instance.id)) {
        await store.kill(instance.id);
      } else {
        if (!await ensureAccountForLaunch(context)) return;
        await store.launch(instance.id);
      }
    } catch (e) {
      showAppSnackBar('操作失败: $e', isError: true);
    }
  }

  Future<void> openInstanceFolder(rust.InstanceDto instance) async {
    try {
      final path = await _store.instanceFolderPath(instance.id);
      if (Platform.isWindows) {
        await Process.run('explorer', [path]);
      } else if (Platform.isMacOS) {
        await Process.run('open', [path]);
      } else {
        await Process.run('xdg-open', [path]);
      }
    } catch (e) {
      showAppSnackBar('打开文件夹失败: $e', isError: true);
    }
  }

  Future<void> copyInstancePath(rust.InstanceDto instance) async {
    try {
      final path = await _store.instanceFolderPath(instance.id);
      await Clipboard.setData(ClipboardData(text: path));
      showAppSnackBar('实例路径已复制');
    } catch (e) {
      showAppSnackBar('复制路径失败: $e', isError: true);
    }
  }

  Future<void> duplicateInstance(rust.InstanceDto instance) async {
    try {
      await _store.duplicate(instance.id);
    } catch (_) {
      // Errors are already surfaced by InstanceStore.duplicate.
    }
  }

  Future<void> renameInstance(rust.InstanceDto instance) async {
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
      showAppSnackBar('已重命名为「${updated.name}」');
    } catch (e) {
      showAppSnackBar('重命名失败: $e', isError: true);
    }
  }

  Future<void> confirmDeleteInstance(rust.InstanceDto instance) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除实例'),
        content: Text('确定删除「${instance.name}」？\n此操作不可撤销。'),
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
      showAppSnackBar('已删除「${instance.name}」');
    } catch (e) {
      showAppSnackBar('删除失败: $e', isError: true);
    }
  }

  Future<void> showInstanceContextMenu(
    Offset globalPosition,
    rust.InstanceDto instance,
  ) async {
    final running = _store.isRunning(instance.id);
    final action = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(
        globalPosition.dx,
        globalPosition.dy,
        globalPosition.dx,
        globalPosition.dy,
      ),
      items: [
        PopupMenuItem(
          value: 'play',
          child: _contextMenuRow(
            icon: running ? Icons.stop_rounded : Icons.play_arrow_rounded,
            label: running ? '停止' : '启动',
          ),
        ),
        if (_store.isInstallFailed(instance.id))
          PopupMenuItem(
            value: 'retry_install',
            child: _contextMenuRow(
              icon: Icons.refresh,
              label: '重试安装',
            ),
          ),
        PopupMenuItem(
          value: 'add_content',
          child: _contextMenuRow(
            icon: Icons.add,
            label: '添加内容',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'view',
          child: _contextMenuRow(
            icon: Icons.visibility_outlined,
            label: '查看实例',
          ),
        ),
        PopupMenuItem(
          value: 'settings',
          child: _contextMenuRow(
            icon: Icons.settings_outlined,
            label: '设置',
          ),
        ),
        PopupMenuItem(
          value: 'rename',
          child: _contextMenuRow(
            icon: Icons.edit_outlined,
            label: '重命名',
          ),
        ),
        PopupMenuItem(
          value: 'duplicate',
          child: _contextMenuRow(
            icon: Icons.copy_all_outlined,
            label: '复制实例',
          ),
        ),
        PopupMenuItem(
          value: 'open_folder',
          child: _contextMenuRow(
            icon: Icons.folder_outlined,
            label: '打开文件夹',
          ),
        ),
        PopupMenuItem(
          value: 'shortcut',
          child: _contextMenuRow(
            icon: Icons.shortcut_outlined,
            label: '创建桌面快捷方式',
          ),
        ),
        PopupMenuItem(
          value: 'shortcut_save_as',
          child: _contextMenuRow(
            icon: Icons.save_as_outlined,
            label: '另存为快捷方式…',
          ),
        ),
        PopupMenuItem(
          value: 'copy_path',
          child: _contextMenuRow(
            icon: Icons.content_copy_outlined,
            label: '复制路径',
          ),
        ),
        const PopupMenuDivider(),
        PopupMenuItem(
          value: 'delete',
          child: _contextMenuRow(
            icon: Icons.delete_outline,
            label: '删除',
            destructive: true,
          ),
        ),
      ],
    );
    if (!mounted || action == null) return;
    switch (action) {
      case 'play':
        await playOrStop(instance);
      case 'retry_install':
        try {
          await _store.install(instance.id, force: true);
        } catch (e) {
          showAppSnackBar('重试安装失败: $e', isError: true);
        }
      case 'add_content':
        getIt<NavigationState>().browseContentForInstance(instance.id);
      case 'view':
        getIt<NavigationState>().openInstance(instance.id);
      case 'settings':
        await showInstanceSettingsDialog(
          context: context,
          instanceId: instance.id,
        );
      case 'rename':
        await renameInstance(instance);
      case 'duplicate':
        await duplicateInstance(instance);
      case 'open_folder':
        await openInstanceFolder(instance);
      case 'shortcut':
        await createAmlDesktopShortcut(
          displayName: instance.name,
          instanceId: instance.id,
          instanceIconPath: instance.icon,
        );
      case 'shortcut_save_as':
        await createAmlDesktopShortcut(
          displayName: instance.name,
          instanceId: instance.id,
          instanceIconPath: instance.icon,
          saveAs: true,
        );
      case 'copy_path':
        await copyInstancePath(instance);
      case 'delete':
        await confirmDeleteInstance(instance);
    }
  }

  Widget _contextMenuRow({
    required IconData icon,
    required String label,
    bool destructive = false,
  }) {
    final color = destructive ? const Color(0xFFB3261E) : null;
    return Row(
      children: [
        Icon(icon, size: 20, color: color),
        const SizedBox(width: 10),
        Text(label, style: TextStyle(color: color)),
      ],
    );
  }
}
