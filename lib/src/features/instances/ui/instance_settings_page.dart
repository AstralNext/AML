import 'dart:async';
import 'dart:convert';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/export_pack_dialog.dart';
import 'package:aml/src/features/instances/ui/instance_settings_widgets.dart';
import 'package:aml/src/features/instances/ui/instance_settings_install_tab.dart';
import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/buttons/button_group_widget.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:aml/src/features/settings/ui/widgets/java_selector.dart';
import 'package:file_picker/file_picker.dart';
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

  final _store = getIt<InstanceStore>();
  final _nameController = TextEditingController();
  final _nameFocusNode = FocusNode();
  final _widthController = TextEditingController(text: '854');
  final _heightController = TextEditingController(text: '480');
  final _jvmArgsController = TextEditingController();
  final _envVarsController = TextEditingController();
  final _preLaunchController = TextEditingController();
  final _wrapperController = TextEditingController();
  final _postExitController = TextEditingController();

  final _groupController = TextEditingController();

  Timer? _saveDebounce;
  int _selectedTab = 0;
  int _requiredJavaMajor = 21;
  int _maxMemoryMb = 8192;
  double _memoryMb = 4096;
  String _javaPath = '';
  String _defaultJavaPath = '';
  int _defaultMemoryMb = 4096;
  String _defaultJvmArgs = '';
  String _defaultEnvVars = '';
  int _defaultWindowWidth = 854;
  int _defaultWindowHeight = 480;
  bool _defaultFullscreen = false;
  String _updateChannel = 'release';
  List<String> _groups = [];
  List<String> _availableGroups = [];
  bool _overrideWindow = false;
  bool _overrideJava = false;
  bool _overrideMemory = false;
  bool _overrideJvmArgs = false;
  bool _overrideEnvVars = false;
  bool _overrideHooks = false;
  bool _fullscreen = false;
  bool _saving = false;
  bool _busyAction = false;
  String? _error;
  String _lastCommittedName = '';

  @override
  void initState() {
    super.initState();
    _selectedTab = widget.initialTab.clamp(0, _tabs.length - 1);
    _motion = ModalMotion(this)..forward();
    unawaited(_loadMeta());
  }

  @override
  void dispose() {
    _saveDebounce?.cancel();
    _motion.dispose();
    _nameController.dispose();
    _nameFocusNode.dispose();
    _widthController.dispose();
    _heightController.dispose();
    _jvmArgsController.dispose();
    _envVarsController.dispose();
    _preLaunchController.dispose();
    _wrapperController.dispose();
    _postExitController.dispose();
    _groupController.dispose();
    super.dispose();
  }

  rust.InstanceDto? get _instance {
    for (final item in _store.instances.value) {
      if (item.id == widget.instanceId) return item;
    }
    return null;
  }

  Future<void> _loadMeta() async {
    try {
      final requiredMajor =
          await rust.getRequiredJavaVersion(id: widget.instanceId);
      final maxMemory = await getIt<JavaDownloadService>().getMaxMemory();
      final groups = await _store.listAllGroups();
      final defaults = await _store.getLaunchDefaults();
      final optimalJava = await _store.peekJavaForMajor(requiredMajor);
      if (!mounted) return;
      setState(() {
        _requiredJavaMajor = requiredMajor;
        _maxMemoryMb = maxMemory.clamp(512, 131072);
        _availableGroups = groups;
        _defaultMemoryMb = defaults.memoryMb.toInt().clamp(512, _maxMemoryMb);
        _defaultJvmArgs = defaults.extraJvmArgs ?? '';
        _defaultEnvVars = _envVarsToDisplay(defaults.environmentVars);
        _defaultWindowWidth = defaults.windowWidth.toInt();
        _defaultWindowHeight = defaults.windowHeight.toInt();
        _defaultFullscreen = defaults.fullscreen;
        _defaultJavaPath = optimalJava ?? '';
      });
    } catch (_) {}
    if (mounted) setState(() => _syncFromInstance(_instance));
  }

  void _syncFromInstance(rust.InstanceDto? instance) {
    if (instance == null) return;
    // Don't clobber in-progress edits while the name field is focused.
    if (!_nameFocusNode.hasFocus) {
      _nameController.text = instance.name;
      _lastCommittedName = instance.name;
    }
    _overrideJava = instance.javaPath != null && instance.javaPath!.isNotEmpty;
    _javaPath = _overrideJava ? (instance.javaPath ?? '') : _defaultJavaPath;
    _overrideMemory = instance.memoryMb != null;
    _memoryMb = (instance.memoryMb?.toInt() ?? _defaultMemoryMb)
        .clamp(512, _maxMemoryMb)
        .toDouble();
    _overrideWindow = instance.windowWidth != null ||
        instance.windowHeight != null ||
        instance.fullscreen != null;
    _widthController.text =
        '${instance.windowWidth?.toInt() ?? _defaultWindowWidth}';
    _heightController.text =
        '${instance.windowHeight?.toInt() ?? _defaultWindowHeight}';
    _fullscreen = instance.fullscreen ?? _defaultFullscreen;
    _overrideJvmArgs = instance.extraJvmArgs != null &&
        instance.extraJvmArgs!.trim().isNotEmpty;
    _jvmArgsController.text =
        _overrideJvmArgs ? (instance.extraJvmArgs ?? '') : _defaultJvmArgs;
    _overrideEnvVars = instance.environmentVars != null &&
        instance.environmentVars!.trim().isNotEmpty;
    _envVarsController.text = _overrideEnvVars
        ? _envVarsToDisplay(instance.environmentVars)
        : _defaultEnvVars;
    _preLaunchController.text = instance.preLaunchCommand ?? '';
    _wrapperController.text = instance.wrapperCommand ?? '';
    _postExitController.text = instance.postExitCommand ?? '';
    _updateChannel = instance.updateChannel;
    _groups = List<String>.from(instance.groups);
    _overrideHooks = _hasHook(instance.preLaunchCommand) ||
        _hasHook(instance.wrapperCommand) ||
        _hasHook(instance.postExitCommand);
  }

  bool _hasHook(String? value) => value != null && value.trim().isNotEmpty;

  String _envVarsToDisplay(String? json) {
    if (json == null || json.trim().isEmpty) return '';
    try {
      final map = jsonDecode(json) as Map<String, dynamic>;
      return map.entries
          .map((entry) => '${entry.key}=${entry.value}')
          .join('\n');
    } catch (_) {
      return json;
    }
  }

  String? _envVarsToJson(String text) {
    final trimmed = text.trim();
    if (trimmed.isEmpty) return null;
    final map = <String, String>{};
    for (final line in trimmed.split('\n')) {
      final item = line.trim();
      if (item.isEmpty) continue;
      final index = item.indexOf('=');
      if (index <= 0) continue;
      map[item.substring(0, index).trim()] = item.substring(index + 1).trim();
    }
    if (map.isEmpty) return null;
    return jsonEncode(map);
  }

  Future<void> _close() async {
    await _commitName();
    if (!mounted) return;
    _motion.reverse();
    Navigator.of(context).pop();
  }

  Future<void> _commitName() async {
    final raw = _nameController.text.trim();
    final name = raw.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_').trim();
    if (name.isEmpty || name == _lastCommittedName) {
      if (name != raw && mounted) {
        _nameController.text = name;
      }
      return;
    }
    if (name == (_instance?.name ?? '')) {
      _lastCommittedName = name;
      if (name != raw && mounted) {
        _nameController.value = TextEditingValue(
          text: name,
          selection: TextSelection.collapsed(offset: name.length),
        );
      }
      return;
    }
    await _save(name: name);
    if (mounted) {
      _lastCommittedName = name;
      if (name != raw) {
        _nameController.value = TextEditingValue(
          text: name,
          selection: TextSelection.collapsed(offset: name.length),
        );
      }
    }
  }

  void _scheduleSave(Future<void> Function() action) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 450), () {
      unawaited(action());
    });
  }

  Future<void> _save({
    String? name,
    String? javaPath,
    bool clearJavaPath = false,
    int? memoryMb,
    bool clearMemoryMb = false,
    String? extraJvmArgs,
    bool clearExtraJvmArgs = false,
    int? windowWidth,
    int? windowHeight,
    bool? fullscreen,
    bool clearWindowSettings = false,
    String? environmentVars,
    bool clearEnvironmentVars = false,
    String? preLaunchCommand,
    String? wrapperCommand,
    String? postExitCommand,
    bool clearHooks = false,
    String? updateChannel,
  }) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await _store.updateSettings(
        id: widget.instanceId,
        name: name,
        javaPath: javaPath,
        clearJavaPath: clearJavaPath,
        memoryMb: memoryMb,
        clearMemoryMb: clearMemoryMb,
        extraJvmArgs: extraJvmArgs,
        clearExtraJvmArgs: clearExtraJvmArgs,
        windowWidth: windowWidth,
        windowHeight: windowHeight,
        fullscreen: fullscreen,
        clearWindowSettings: clearWindowSettings,
        environmentVars: environmentVars,
        clearEnvironmentVars: clearEnvironmentVars,
        preLaunchCommand: preLaunchCommand,
        wrapperCommand: wrapperCommand,
        postExitCommand: postExitCommand,
        clearHooks: clearHooks,
        updateChannel: updateChannel,
      );
      _syncFromInstance(_instance);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _persistGroups(List<String> groups) async {
    setState(() {
      _groups = groups;
      _saving = true;
    });
    try {
      await _store.setGroups(widget.instanceId, groups);
      final all = await _store.listAllGroups();
      if (!mounted) return;
      setState(() => _availableGroups = all);
      _syncFromInstance(_instance);
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickIcon() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: const ['png', 'jpg', 'jpeg', 'webp', 'gif', 'svg'],
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    try {
      await _store.editIcon(widget.instanceId, path: path);
      if (mounted) showAppSnackBar('实例图标已更新');
    } catch (error) {
      if (mounted) showAppSnackBar('更新图标失败: $error', isError: true);
    }
  }

  Future<void> _duplicateInstance() async {
    if (_busyAction) return;
    setState(() => _busyAction = true);
    // Close settings first so the progress overlay / snackbar are visible
    // Close the dialog; progress continues in the status bar.
    _close();
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
        _close();
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
      _syncFromInstance(_instance);
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
      _syncFromInstance(_instance);
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
      _syncFromInstance(_instance);
    } finally {
      if (mounted) setState(() => _busyAction = false);
    }
  }

  Widget _buildGeneralTab(rust.InstanceDto instance) {
    final tokens = context.tokens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '名称',
                    style: TextStyle(
                      fontWeight: FontWeight.w700,
                      color: tokens.colorContrast,
                    ),
                  ),
                  const SizedBox(height: 8),
                  InputBarWidget(
                    colorScheme: Theme.of(context).colorScheme,
                    size: InputBarSize.medium,
                    controller: _nameController,
                    focusNode: _nameFocusNode,
                    onSubmitted: (_) => unawaited(_commitName()),
                    onFocusChange: (focused) {
                      if (!focused) unawaited(_commitName());
                    },
                  ),
                ],
              ),
            ),
            const SizedBox(width: 18),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '图标',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 8),
                Material(
                  color: Colors.transparent,
                  child: InkWell(
                    onTap: _saving ? null : _pickIcon,
                    borderRadius: BorderRadius.circular(12),
                    child: InstanceIcon(
                      instanceId: instance.id,
                      iconPath: instance.icon,
                      size: 72,
                      borderRadius: 12,
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '库分组',
          description: '库分组功能可以让你将实例整理到库中的不同部分。',
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final group in {..._availableGroups, ..._groups})
              FilterChip(
                label: Text(group),
                selected: _groups.contains(group),
                onSelected: _saving
                    ? null
                    : (selected) {
                        final next = List<String>.from(_groups);
                        if (selected) {
                          if (!next.contains(group)) next.add(group);
                        } else {
                          next.remove(group);
                        }
                        unawaited(_persistGroups(next));
                      },
              ),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            Expanded(
              child: InputBarWidget(
                colorScheme: Theme.of(context).colorScheme,
                size: InputBarSize.medium,
                hintText: '输入分组名称',
                controller: _groupController,
              ),
            ),
            const SizedBox(width: 8),
            NavRectButton(
              isSelected: false,
              icon: Icons.add,
              text: '创建新的分组',
              defaultBackgroundColor: tokens.colorButtonBg,
              defaultColor: tokens.colorContrast,
              hoverColor: tokens.colorButtonBgSelected,
              hoverTextColor: tokens.colorButtonTextSelected,
              onTap: _saving
                  ? () {}
                  : () {
                      final name = _groupController.text.trim();
                      if (name.isEmpty) return;
                      _groupController.clear();
                      final next = List<String>.from(_groups);
                      if (!next.contains(name)) next.add(name);
                      unawaited(_persistGroups(next));
                    },
            ),
          ],
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '更新渠道',
          description: switch (_updateChannel) {
            'alpha' => '正式版、Beta 与 Alpha 测试版都会显示为可用更新。',
            'beta' => '正式版与 Beta 测试版会显示为可用更新。',
            _ => '只有正式版会被显示为可用更新。',
          },
        ),
        const SizedBox(height: 10),
        IgnorePointer(
          ignoring: _saving,
          child: ButtonGroupWidget(
            fitContent: true,
            selectedValue: _updateChannel,
            selectedIcon: null,
            onChanged: (value) {
              setState(() => _updateChannel = value);
              unawaited(_save(updateChannel: value));
            },
            items: const [
              ButtonGroupItem(value: 'release', text: '正式版'),
              ButtonGroupItem(value: 'beta', text: 'Beta 测试版'),
              ButtonGroupItem(value: 'alpha', text: 'Alpha 测试版'),
            ],
          ),
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '存档备份',
          description: '退出游戏后自动完整备份本次游玩的世界（默认关闭）。计入资源管理。',
        ),
        const SizedBox(height: 10),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          title: Text(
            '退出时自动备份世界',
            style: TextStyle(
              fontWeight: FontWeight.w600,
              color: tokens.colorContrast,
            ),
          ),
          subtitle: Text(
            '优先备份 Quick Play 进入的世界；否则备份最近游玩且未占用的世界。',
            style: TextStyle(
              fontSize: 12,
              color: tokens.colorBase.withValues(alpha: 0.7),
            ),
          ),
          value: instance.autoBackupWorlds,
          onChanged: _saving
              ? null
              : (enabled) {
                  unawaited(() async {
                    try {
                      await _store.setAutoBackupWorlds(
                        widget.instanceId,
                        enabled,
                      );
                    } catch (error) {
                      if (mounted) {
                        showAppSnackBar('设置失败: $error', isError: true);
                      }
                    }
                  }());
                },
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '复制实例',
          description: '创建此实例的副本，包含世界、配置、模组等所有内容。',
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: NavRectButton(
            isSelected: false,
            icon: Icons.copy_all_outlined,
            text: _busyAction ? '复制中…' : '复制',
            defaultBackgroundColor: tokens.colorButtonBg,
            defaultColor: tokens.colorContrast,
            hoverColor: tokens.colorButtonBgSelected,
            hoverTextColor: tokens.colorButtonTextSelected,
            onTap: _busyAction ? () {} : _duplicateInstance,
          ),
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '导出整合包',
          description: '设置名称、版本与导出内容后，导出为 Modrinth / MultiMC / MCBBS。',
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: NavRectButton(
            isSelected: false,
            icon: Icons.upload_file_outlined,
            text: '导出整合包…',
            defaultBackgroundColor: tokens.colorButtonBg,
            defaultColor: tokens.colorContrast,
            hoverColor: tokens.colorButtonBgSelected,
            hoverTextColor: tokens.colorButtonTextSelected,
            onTap: _busyAction ? () {} : _openExportDialog,
          ),
        ),
        const SizedBox(height: 24),
        instanceSettingsSectionHeader(
          context,
          '删除实例',
          description: '此操作将永久删除实例及其所有数据，且无法恢复。',
        ),
        const SizedBox(height: 10),
        Align(
          alignment: Alignment.centerLeft,
          child: NavRectButton(
            isSelected: false,
            icon: Icons.delete_outline,
            text: '删除实例',
            defaultBackgroundColor: const Color(0x33FF6B6B),
            defaultColor: const Color(0xFFFF7B7B),
            hoverColor: const Color(0x55FF6B6B),
            hoverTextColor: const Color(0xFFFF8F8F),
            onTap: _busyAction ? () {} : _deleteInstance,
          ),
        ),
      ],
    );
  }

  Widget _buildWindowTab() {
    final tokens = context.tokens;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        instanceSettingsOverrideRow(
          context,
          saving: _saving,
          label: '自定义窗口设置',
          value: _overrideWindow,
          onChanged: (enabled) async {
            setState(() {
              _overrideWindow = enabled;
              if (!enabled) {
                _widthController.text = '$_defaultWindowWidth';
                _heightController.text = '$_defaultWindowHeight';
                _fullscreen = _defaultFullscreen;
              }
            });
            if (!enabled) {
              await _save(clearWindowSettings: true);
            } else {
              await _save(
                windowWidth:
                    int.tryParse(_widthController.text) ?? _defaultWindowWidth,
                windowHeight:
                    int.tryParse(_heightController.text) ?? _defaultWindowHeight,
                fullscreen: _fullscreen,
              );
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title:
                    Text('全屏', style: TextStyle(color: tokens.colorContrast)),
                subtitle: Text(
                  '以全屏模式启动游戏。',
                  style: TextStyle(
                      color: tokens.colorBase.withValues(alpha: 0.65)),
                ),
                value: _fullscreen,
                activeThumbColor: tokens.colorOnBrand,
                activeTrackColor: tokens.colorBrand,
                onChanged: (value) async {
                  setState(() => _fullscreen = value);
                  await _save(fullscreen: value);
                },
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(
                    child: IgnorePointer(
                      ignoring: _fullscreen,
                      child: Opacity(
                        opacity: _fullscreen ? 0.45 : 1,
                        child: _labeledNumberField(
                          label: '宽度',
                          controller: _widthController,
                          onChanged: (_) => _scheduleSave(
                            () => _save(
                              windowWidth: int.tryParse(_widthController.text),
                              windowHeight:
                                  int.tryParse(_heightController.text),
                              fullscreen: _fullscreen,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: IgnorePointer(
                      ignoring: _fullscreen,
                      child: Opacity(
                        opacity: _fullscreen ? 0.45 : 1,
                        child: _labeledNumberField(
                          label: '高度',
                          controller: _heightController,
                          onChanged: (_) => _scheduleSave(
                            () => _save(
                              windowWidth: int.tryParse(_widthController.text),
                              windowHeight:
                                  int.tryParse(_heightController.text),
                              fullscreen: _fullscreen,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _labeledNumberField({
    required String label,
    required TextEditingController controller,
    required ValueChanged<String> onChanged,
  }) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: TextStyle(color: tokens.colorContrast)),
        const SizedBox(height: 6),
        InputBarWidget(
          colorScheme: Theme.of(context).colorScheme,
          size: InputBarSize.medium,
          controller: controller,
          onChanged: onChanged,
        ),
      ],
    );
  }

  Widget _buildJavaTab() {
    final tokens = context.tokens;
    final resourceDir = getIt<ResourceSettingsState>().resourceDirectory.value;
    final activeJavaPath = _overrideJava ? _javaPath : _defaultJavaPath;
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        instanceSettingsOverrideRow(
          context,
          saving: _saving,
          label: '自定义 Java 安装',
          value: _overrideJava,
          onChanged: (enabled) async {
            setState(() {
              _overrideJava = enabled;
              if (enabled && _javaPath.isEmpty) {
                _javaPath = _defaultJavaPath;
              }
              if (!enabled) {
                _javaPath = _defaultJavaPath;
              }
            });
            if (!enabled) {
              await _save(clearJavaPath: true);
            } else if (_javaPath.isNotEmpty) {
              await _save(javaPath: _javaPath);
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Java $_requiredJavaMajor',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: tokens.colorContrast,
                ),
              ),
              const SizedBox(height: 8),
              JavaSelector(
                version: _requiredJavaMajor,
                path: activeJavaPath,
                appDataDir: resourceDir,
                javaDownloadService: getIt<JavaDownloadService>(),
                disabled: !_overrideJava || _saving,
                onPathChanged: (path) {
                  setState(() => _javaPath = path);
                  _scheduleSave(() => _save(javaPath: path));
                },
              ),
              if (!_overrideJava && _defaultJavaPath.isEmpty) ...[
                const SizedBox(height: 8),
                Text(
                  '启动时将自动选择或安装所需的 Java $_requiredJavaMajor。',
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.colorBase.withValues(alpha: 0.65),
                  ),
                ),
              ],
            ],
          ),
        ),
        const SizedBox(height: 22),
        instanceSettingsOverrideRow(
          context,
          saving: _saving,
          label: '自定义内存分配',
          value: _overrideMemory,
          onChanged: (enabled) async {
            setState(() {
              _overrideMemory = enabled;
              if (!enabled) {
                _memoryMb = _defaultMemoryMb.toDouble();
              }
            });
            if (!enabled) {
              await _save(clearMemoryMb: true);
            } else {
              await _save(memoryMb: _memoryMb.round());
            }
          },
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Slider(
                      value: _memoryMb.clamp(512, _maxMemoryMb.toDouble()),
                      min: 512,
                      max: _maxMemoryMb.toDouble(),
                      divisions: ((_maxMemoryMb - 512) ~/ 64).clamp(1, 512),
                      label: '${_memoryMb.round()} MB',
                      activeColor: tokens.colorBrand,
                      onChanged: (value) {
                        setState(() => _memoryMb = value);
                        _scheduleSave(() => _save(memoryMb: value.round()));
                      },
                    ),
                  ),
                  SizedBox(
                    width: 84,
                    child: Text(
                      '${_memoryMb.round()} MB',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                ],
              ),
              Text(
                '512 MB - $_maxMemoryMb MB',
                style: TextStyle(
                  fontSize: 12,
                  color: tokens.colorBase.withValues(alpha: 0.65),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 22),
        instanceSettingsOverrideRow(
          context,
          saving: _saving,
          label: '自定义 Java 参数',
          value: _overrideJvmArgs,
          onChanged: (enabled) async {
            setState(() {
              _overrideJvmArgs = enabled;
              if (enabled && _jvmArgsController.text.trim().isEmpty) {
                _jvmArgsController.text = _defaultJvmArgs;
              }
              if (!enabled) {
                _jvmArgsController.text = _defaultJvmArgs;
              }
            });
            if (!enabled) {
              await _save(clearExtraJvmArgs: true);
            } else {
              await _save(extraJvmArgs: _jvmArgsController.text);
            }
          },
          child: InputBarWidget(
            colorScheme: Theme.of(context).colorScheme,
            size: InputBarSize.medium,
            hintText: '输入 Java 参数…',
            controller: _jvmArgsController,
            onChanged: (value) =>
                _scheduleSave(() => _save(extraJvmArgs: value)),
          ),
        ),
        const SizedBox(height: 22),
        instanceSettingsOverrideRow(
          context,
          saving: _saving,
          label: '自定义环境变量',
          value: _overrideEnvVars,
          onChanged: (enabled) async {
            setState(() {
              _overrideEnvVars = enabled;
              if (enabled && _envVarsController.text.trim().isEmpty) {
                _envVarsController.text = _defaultEnvVars;
              }
              if (!enabled) {
                _envVarsController.text = _defaultEnvVars;
              }
            });
            if (!enabled) {
              await _save(clearEnvironmentVars: true);
            } else {
              await _save(
                environmentVars: _envVarsToJson(_envVarsController.text),
              );
            }
          },
          child: InputBarWidget(
            colorScheme: Theme.of(context).colorScheme,
            size: InputBarSize.medium,
            hintText: 'KEY=VALUE',
            controller: _envVarsController,
            onChanged: (value) => _scheduleSave(
              () => _save(environmentVars: _envVarsToJson(value)),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildHooksTab() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 24),
      children: [
        instanceSettingsSectionHeader(
          context,
          '游戏启动钩子',
          description: 'Hooks 允许高级用户在启动游戏前后运行特定的系统命令。',
        ),
        const SizedBox(height: 16),
        instanceSettingsOverrideRow(
          context,
          saving: _saving,
          label: '自定义启动 Hooks',
          value: _overrideHooks,
          onChanged: (enabled) async {
            setState(() => _overrideHooks = enabled);
            if (!enabled) {
              await _save(clearHooks: true);
            } else {
              await _save(
                preLaunchCommand: _preLaunchController.text,
                wrapperCommand: _wrapperController.text,
                postExitCommand: _postExitController.text,
              );
            }
          },
          child: Column(
            children: [
              _hookField(
                title: '启动前',
                hint: '输入启动前命令…',
                description: '在实例启动前运行。',
                controller: _preLaunchController,
              ),
              const SizedBox(height: 14),
              _hookField(
                title: '包装器命令',
                hint: '输入封装命令…',
                description: '用于启动 Minecraft 的包装器命令，Java 会追加在末尾。',
                controller: _wrapperController,
              ),
              const SizedBox(height: 14),
              _hookField(
                title: '退出后执行',
                hint: '输入退出后运行的命令…',
                description: '在游戏正常关闭后运行。',
                controller: _postExitController,
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _hookField({
    required String title,
    required String hint,
    required String description,
    required TextEditingController controller,
  }) {
    final tokens = context.tokens;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          title,
          style: TextStyle(
            fontWeight: FontWeight.w700,
            color: tokens.colorContrast,
          ),
        ),
        const SizedBox(height: 6),
        InputBarWidget(
          colorScheme: Theme.of(context).colorScheme,
          size: InputBarSize.medium,
          hintText: hint,
          controller: controller,
          onChanged: (_) => _scheduleSave(
            () => _save(
              preLaunchCommand: _preLaunchController.text,
              wrapperCommand: _wrapperController.text,
              postExitCommand: _postExitController.text,
            ),
          ),
        ),
        const SizedBox(height: 4),
        Text(
          description,
          style: TextStyle(
            fontSize: 12,
            color: tokens.colorBase.withValues(alpha: 0.65),
          ),
        ),
      ],
    );
  }

  Widget _buildContent(rust.InstanceDto instance) {
    switch (_tabs[_selectedTab].id) {
      case 'general':
        return _buildGeneralTab(instance);
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
        return _buildWindowTab();
      case 'java':
        return _buildJavaTab();
      case 'hooks':
        return _buildHooksTab();
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
                    if (_saving)
                      Padding(
                        padding: const EdgeInsets.only(right: 8),
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: tokens.colorBrand,
                          ),
                        ),
                      ),
                    IconButton(
                      tooltip: '关闭',
                      onPressed: _close,
                      icon: Icon(Icons.close, color: tokens.colorContrast),
                    ),
                  ],
                ),
              ),
              if (_error != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      _error!,
                      style:
                          TextStyle(color: Theme.of(context).colorScheme.error),
                    ),
                  ),
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
