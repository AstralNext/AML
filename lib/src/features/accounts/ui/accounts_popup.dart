import 'dart:typed_data';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/accounts/ui/account_avatar.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/wardrobe/ui/wardrobe_page.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:signals_flutter/signals_flutter.dart';

/// Opens the accounts popup (settings-style modal overlay).
Future<void> showAccountsPopup(BuildContext context) {
  return Navigator.of(context).push(
    PageRouteBuilder(
      opaque: false,
      pageBuilder: (_, __, ___) => const AccountsPopup(),
    ),
  );
}

/// Ensure an account exists before launching. Shows a dialog when empty.
Future<bool> ensureAccountForLaunch(BuildContext context) async {
  final store = getIt<AccountStore>();
  await store.refresh();
  if (store.activeAccount != null) return true;
  if (store.accounts.value.isNotEmpty) {
    await store.setActive(store.accounts.value.first.id);
    return true;
  }
  if (!context.mounted) return false;

  final choice = await showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要账号'),
      content: const Text(
        '启动游戏前请先添加账号。可以创建离线账号，或登录正版 / 外置账号。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'accounts'),
          child: const Text('打开账号'),
        ),
        TextButton(
          onPressed: () => Navigator.pop(ctx, 'offline'),
          child: const Text('创建离线账号'),
        ),
      ],
    ),
  );
  if (!context.mounted) return false;

  if (choice == 'accounts') {
    await showAccountsPopup(context);
    await store.refresh();
    return store.activeAccount != null || store.accounts.value.isNotEmpty;
  }
  if (choice == 'offline') {
    final nameController = TextEditingController(text: 'Player');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('创建离线账号'),
        content: TextField(
          controller: nameController,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: '玩家名',
            hintText: 'Player',
          ),
          onSubmitted: (v) => Navigator.pop(ctx, v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, nameController.text.trim()),
            child: const Text('创建'),
          ),
        ],
      ),
    );
    nameController.dispose();
    if (name == null || name.isEmpty) return false;
    await store.createOffline(name);
    return true;
  }
  return false;
}

class AccountsPopup extends StatefulWidget {
  const AccountsPopup({super.key});

  @override
  State<AccountsPopup> createState() => _AccountsPopupState();
}

class _AccountsPopupState extends State<AccountsPopup>
    with SingleTickerProviderStateMixin {
  late final ModalMotion _motion;

  final _offlineController = TextEditingController();
  final _yggdrasilUsernameController = TextEditingController();
  final _yggdrasilPasswordController = TextEditingController();
  bool _showAdd = false;
  String? _addAccountType;
  String? _status;
  String? _selectedYggdrasilServiceId;
  String? _pendingYggdrasilLoginId;
  String? _selectedYggdrasilProfileId;
  List<rust.YggdrasilProfileDto> _yggdrasilProfiles = const [];

  AccountStore get _store => getIt<AccountStore>();

  @override
  void initState() {
    super.initState();
    _motion = ModalMotion(this)..forward();
    _store.refresh();
  }

  @override
  void dispose() {
    _offlineController.dispose();
    _yggdrasilUsernameController.dispose();
    _yggdrasilPasswordController.dispose();
    _motion.dispose();
    super.dispose();
  }

  void _close() {
    _motion.reverse();
    Navigator.of(context).pop();
  }

  Future<void> _setActive(rust.AccountDto account) async {
    if (account.active) return;
    try {
      await _store.setActive(account.id);
    } catch (e) {
      setState(() => _status = '$e');
    }
  }

  Future<void> _remove(rust.AccountDto account) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除账号'),
        content: Text('确定删除「${account.username}」？此操作不可撤销。'),
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
      await _store.remove(account.id);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _editSkin(rust.AccountDto account) async {
    try {
      if (!account.active) {
        await _store.setActive(account.id);
      }
      if (!mounted) return;
      await showSkinEditorDialog(context, account: account);
    } catch (e) {
      if (mounted) setState(() => _status = '$e');
    }
  }

  Future<void> _beginYggdrasilLogin(String serviceId) async {
    final username = _yggdrasilUsernameController.text.trim();
    final password = _yggdrasilPasswordController.text;
    if (username.isEmpty || password.isEmpty) {
      setState(() => _status = '请输入外置登录账号和密码');
      return;
    }
    try {
      setState(() => _status = '正在登录外置验证服务器…');
      final login = await _store.beginYggdrasilLogin(
        serviceId: serviceId,
        username: username,
        password: password,
      );
      _yggdrasilPasswordController.clear();
      if (!mounted) return;
      setState(() {
        _pendingYggdrasilLoginId = login.loginId;
        _yggdrasilProfiles = login.profiles;
        _selectedYggdrasilProfileId = login.profiles.first.id;
        _status = '请选择要添加的游戏角色';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e');
    }
  }

  Future<void> _finishYggdrasilLogin() async {
    final loginId = _pendingYggdrasilLoginId;
    final profileId = _selectedYggdrasilProfileId;
    if (loginId == null || profileId == null) return;
    try {
      await _store.finishYggdrasilLogin(
        loginId: loginId,
        profileId: profileId,
      );
      if (!mounted) return;
      setState(() {
        _pendingYggdrasilLoginId = null;
        _yggdrasilProfiles = const [];
        _status = '外置账号登录成功';
        _showAdd = false;
        _addAccountType = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _status = '$e');
    }
  }

  String? _yggdrasilServiceName(String? id) {
    if (id == null) return null;
    for (final service in _store.yggdrasilServices.value) {
      if (service.id == id) return service.name;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    return AnimatedModalDialog.fromMotion(
      motion: _motion,
      onClose: _close,
      child: Material(
        color: Colors.transparent,
        child: Container(
          width: 420,
          constraints: const BoxConstraints(maxHeight: 560),
          decoration: BoxDecoration(
            color: tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: tokens.colorSecondary.withValues(alpha: 0.35),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 18, 12, 12),
                child: Row(
                  children: [
                    Icon(Icons.person_outline, color: tokens.colorContrast),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '账号',
                        style: TextStyle(
                          fontSize: 18,
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
                    ),
                    CustomButton(
                      icon: Icons.close,
                      size: ButtonSize.medium,
                      onTap: _close,
                    ),
                  ],
                ),
              ),
              Divider(
                height: 1,
                color: tokens.colorSecondary.withValues(alpha: 0.25),
              ),
              Flexible(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Watch((context) {
                        final accounts = _store.accounts.value;
                        if (accounts.isEmpty) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                Text(
                                  '暂无账号，添加离线、微软或外置账号后即可启动游戏。',
                                  style: TextStyle(
                                    color:
                                        tokens.colorBase.withValues(alpha: 0.7),
                                  ),
                                ),
                                const SizedBox(height: 12),
                                Watch((context) {
                                  final busy = _store.microsoftLoginBusy.value;
                                  return NavRectButton(
                                    isSelected: false,
                                    icon: busy
                                        ? Icons.hourglass_top
                                        : Icons.login,
                                    defaultBackgroundColor: tokens.colorBrand,
                                    defaultColor: tokens.colorOnBrand,
                                    text: busy ? '登录中…' : '登录 Microsoft 账号',
                                    label: busy ? '登录中' : '微软登录',
                                    onTap: busy
                                        ? () {}
                                        : () async {
                                            setState(
                                              () => _status = '请在弹出窗口完成登录',
                                            );
                                            try {
                                              final ok = await _store
                                                  .loginMicrosoft(context);
                                              if (!mounted) return;
                                              setState(() {
                                                _status =
                                                    ok ? '微软账号登录成功' : '已取消登录';
                                              });
                                            } catch (e) {
                                              if (!mounted) return;
                                              setState(() => _status = '$e');
                                            }
                                          },
                                  );
                                }),
                              ],
                            ),
                          );
                        }
                        return Column(
                          children: [
                            for (final a in accounts)
                              _AccountTile(
                                account: a,
                                serviceName:
                                    _yggdrasilServiceName(a.authServerId),
                                canRemove: !(accounts.length <= 1 && a.active),
                                onSelect: () => _setActive(a),
                                onEdit:
                                    a.kind == 'msa' ? () => _editSkin(a) : null,
                                onRemove: () => _remove(a),
                              ),
                          ],
                        );
                      }),
                      const SizedBox(height: 12),
                      if (!_showAdd)
                        NavRectButton(
                          isSelected: false,
                          icon: Icons.add,
                          defaultBackgroundColor: tokens.colorBrand,
                          defaultColor: tokens.colorOnBrand,
                          text: '添加账号',
                          label: '添加账号',
                          onTap: () => setState(() {
                            _showAdd = true;
                            _addAccountType = null;
                          }),
                        )
                      else ...[
                        Row(
                          children: [
                            Text(
                              '添加账号',
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => setState(() {
                                _showAdd = false;
                                _addAccountType = null;
                                _status = null;
                              }),
                              child: const Text('收起'),
                            ),
                          ],
                        ),
                        const SizedBox(height: 12),
                        if (_addAccountType == null) ...[
                          NavRectButton(
                            isSelected: false,
                            icon: Icons.person_outline,
                            defaultBackgroundColor: tokens.colorButtonBg,
                            text: '离线账号',
                            label: '选择离线账号',
                            onTap: () => setState(
                              () => _addAccountType = 'offline',
                            ),
                          ),
                          const SizedBox(height: 10),
                          NavRectButton(
                            isSelected: false,
                            icon: Icons.window,
                            defaultBackgroundColor: tokens.colorBrand,
                            defaultColor: tokens.colorOnBrand,
                            text: 'Microsoft 账号',
                            label: '选择 Microsoft 账号',
                            onTap: () => setState(
                              () => _addAccountType = 'msa',
                            ),
                          ),
                          const SizedBox(height: 10),
                          NavRectButton(
                            isSelected: false,
                            icon: Icons.admin_panel_settings_outlined,
                            defaultBackgroundColor: tokens.colorButtonBg,
                            text: 'Yggdrasil 外置账号',
                            label: '选择外置账号',
                            onTap: () => setState(
                              () => _addAccountType = 'yggdrasil',
                            ),
                          ),
                        ],
                        if (_addAccountType != null)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: TextButton.icon(
                              onPressed: () => setState(() {
                                _addAccountType = null;
                                _pendingYggdrasilLoginId = null;
                                _yggdrasilProfiles = const [];
                                _status = null;
                              }),
                              icon: const Icon(Icons.arrow_back, size: 18),
                              label: const Text('返回账号类型'),
                            ),
                          ),
                        if (_addAccountType == 'offline') ...[
                          Text(
                            '离线账号',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: tokens.colorBase.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: InputBarWidget(
                                  colorScheme: colorScheme,
                                  size: InputBarSize.medium,
                                  hintText: '用户名',
                                  controller: _offlineController,
                                ),
                              ),
                              const SizedBox(width: 8),
                              NavRectButton(
                                isSelected: false,
                                icon: Icons.add,
                                defaultBackgroundColor: tokens.colorButtonBg,
                                text: '添加',
                                label: '添加',
                                onTap: () async {
                                  final name = _offlineController.text.trim();
                                  if (name.isEmpty) return;
                                  try {
                                    await _store.createOffline(name);
                                    _offlineController.clear();
                                    setState(() {
                                      _status = '已添加 $name';
                                      _showAdd = false;
                                      _addAccountType = null;
                                    });
                                  } catch (e) {
                                    setState(() => _status = '$e');
                                  }
                                },
                              ),
                            ],
                          ),
                        ],
                        if (_addAccountType == 'msa') ...[
                          Text(
                            '微软账号',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: tokens.colorBase.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Watch((context) {
                            final busy = _store.microsoftLoginBusy.value;
                            return NavRectButton(
                              isSelected: false,
                              icon: busy ? Icons.hourglass_top : Icons.login,
                              defaultBackgroundColor: tokens.colorBrand,
                              defaultColor: tokens.colorOnBrand,
                              text: busy ? '登录中…' : '登录 Microsoft 账号',
                              label: busy ? '登录中' : '微软登录',
                              onTap: busy
                                  ? () {}
                                  : () async {
                                      setState(() => _status = '请在弹出窗口完成登录');
                                      try {
                                        final ok = await _store
                                            .loginMicrosoft(context);
                                        if (!mounted) return;
                                        setState(() {
                                          if (ok) {
                                            _status = '微软账号登录成功';
                                            _showAdd = false;
                                            _addAccountType = null;
                                          } else {
                                            _status = '已取消登录';
                                          }
                                        });
                                      } catch (e) {
                                        if (!mounted) return;
                                        setState(() => _status = '$e');
                                      }
                                    },
                            );
                          }),
                        ],
                        if (_addAccountType == 'yggdrasil') ...[
                          Text(
                            'Yggdrasil 外置登录',
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: tokens.colorBase.withValues(alpha: 0.8),
                            ),
                          ),
                          const SizedBox(height: 8),
                          Watch((context) {
                            final services = _store.yggdrasilServices.value;
                            final busy = _store.yggdrasilLoginBusy.value;
                            if (services.isEmpty) {
                              return Text(
                                '请先在设置中配置外置登录服务。',
                                style: TextStyle(
                                  color:
                                      tokens.colorBase.withValues(alpha: 0.65),
                                ),
                              );
                            }
                            if (_pendingYggdrasilLoginId != null) {
                              return Text(
                                '账号验证成功，请选择要添加的游戏角色。',
                                style: TextStyle(
                                  color:
                                      tokens.colorBase.withValues(alpha: 0.72),
                                ),
                              );
                            }
                            final selectedId = services.any((service) =>
                                    service.id == _selectedYggdrasilServiceId)
                                ? _selectedYggdrasilServiceId!
                                : services.first.id;
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                LayoutBuilder(
                                  builder: (context, constraints) {
                                    return DropdownButtonWidget(
                                      width: constraints.maxWidth,
                                      height: 38,
                                      dropdownMinWidth: constraints.maxWidth,
                                      colorScheme: colorScheme,
                                      selectedValue: selectedId,
                                      items: [
                                        for (final service in services)
                                          DropdownItem(
                                            display: service.name,
                                            value: service.id,
                                          ),
                                      ],
                                      onChanged: busy
                                          ? (_) {}
                                          : (value) => setState(() =>
                                              _selectedYggdrasilServiceId =
                                                  value),
                                    );
                                  },
                                ),
                                const SizedBox(height: 10),
                                InputBarWidget(
                                  colorScheme: colorScheme,
                                  size: InputBarSize.medium,
                                  hintText: '邮箱、账号或角色名',
                                  controller: _yggdrasilUsernameController,
                                ),
                                const SizedBox(height: 10),
                                InputBarWidget(
                                  colorScheme: colorScheme,
                                  size: InputBarSize.medium,
                                  hintText: '密码',
                                  obscureText: true,
                                  controller: _yggdrasilPasswordController,
                                ),
                                const SizedBox(height: 10),
                                NavRectButton(
                                  isSelected: false,
                                  icon:
                                      busy ? Icons.hourglass_top : Icons.login,
                                  defaultBackgroundColor: tokens.colorButtonBg,
                                  text: busy ? '登录中…' : '登录外置账号',
                                  label: busy ? '登录中' : '外置登录',
                                  onTap: busy
                                      ? () {}
                                      : () => _beginYggdrasilLogin(selectedId),
                                ),
                              ],
                            );
                          }),
                          if (_pendingYggdrasilLoginId != null) ...[
                            const SizedBox(height: 16),
                            Text(
                              '选择角色',
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w700,
                                color: tokens.colorContrast,
                              ),
                            ),
                            const SizedBox(height: 8),
                            for (final profile in _yggdrasilProfiles)
                              Padding(
                                padding: const EdgeInsets.only(bottom: 8),
                                child: _YggdrasilProfileOption(
                                  profile: profile,
                                  selected:
                                      profile.id == _selectedYggdrasilProfileId,
                                  onTap: () => setState(
                                    () => _selectedYggdrasilProfileId =
                                        profile.id,
                                  ),
                                ),
                              ),
                            const SizedBox(height: 10),
                            NavRectButton(
                              isSelected: false,
                              icon: Icons.person_add_alt_1,
                              defaultBackgroundColor: tokens.colorBrand,
                              defaultColor: tokens.colorOnBrand,
                              text: '添加所选角色',
                              label: '添加角色',
                              onTap: _finishYggdrasilLogin,
                            ),
                          ],
                        ],
                      ],
                      if (_status != null) ...[
                        const SizedBox(height: 12),
                        Text(
                          _status!,
                          style: TextStyle(
                            fontSize: 13,
                            color: tokens.colorBase.withValues(alpha: 0.85),
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _YggdrasilProfileOption extends StatefulWidget {
  const _YggdrasilProfileOption({
    required this.profile,
    required this.selected,
    required this.onTap,
  });

  final rust.YggdrasilProfileDto profile;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_YggdrasilProfileOption> createState() =>
      _YggdrasilProfileOptionState();
}

class _YggdrasilProfileOptionState extends State<_YggdrasilProfileOption> {
  Uint8List? _head;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadHead();
  }

  @override
  void didUpdateWidget(covariant _YggdrasilProfileOption oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.profile.id != widget.profile.id ||
        oldWidget.profile.skinUrl != widget.profile.skinUrl) {
      _head = null;
      _loadHead();
    }
  }

  Future<void> _loadHead() async {
    final skinUrl = widget.profile.skinUrl;
    if (skinUrl == null || skinUrl.isEmpty || _loading) return;
    _loading = true;
    try {
      final response = await http
          .get(Uri.parse(skinUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.bodyBytes.length > 4 * 1024 * 1024) {
        return;
      }
      final head = await getIt<AccountAvatarCache>().ensureFromSkinPng(
        widget.profile.id,
        response.bodyBytes,
        force: true,
      );
      if (mounted && head != null) {
        setState(() => _head = head);
      }
    } catch (_) {
      // A missing or unreachable skin uses the deterministic initials fallback.
    } finally {
      _loading = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final profile = widget.profile;
    final head = _head;
    return Material(
      color:
          widget.selected ? tokens.colorBrandHighlight : tokens.colorButtonBg,
      borderRadius: BorderRadius.circular(12),
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(12),
            border: Border.all(
              color: widget.selected
                  ? tokens.colorBrand
                  : tokens.colorSecondary.withValues(alpha: 0.22),
            ),
          ),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: head != null
                    ? Image.memory(
                        head,
                        width: 44,
                        height: 44,
                        fit: BoxFit.cover,
                        filterQuality: FilterQuality.none,
                        gaplessPlayback: true,
                      )
                    : Container(
                        width: 44,
                        height: 44,
                        alignment: Alignment.center,
                        color: AccountAvatar.accentFor(
                          profile.name,
                          Theme.of(context).colorScheme,
                        ),
                        child: Text(
                          AccountAvatar.initialFor(profile.name),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  profile.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: tokens.colorContrast,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
              Icon(
                widget.selected
                    ? Icons.radio_button_checked
                    : Icons.radio_button_off,
                color: widget.selected
                    ? tokens.colorBrand
                    : tokens.colorBase.withValues(alpha: 0.45),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _AccountTile extends StatefulWidget {
  final rust.AccountDto account;
  final String? serviceName;
  final bool canRemove;
  final VoidCallback onSelect;
  final VoidCallback? onEdit;
  final VoidCallback onRemove;

  const _AccountTile({
    required this.account,
    this.serviceName,
    required this.canRemove,
    required this.onSelect,
    this.onEdit,
    required this.onRemove,
  });

  @override
  State<_AccountTile> createState() => _AccountTileState();
}

class _AccountTileState extends State<_AccountTile> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final a = widget.account;
    final selected = a.active;

    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: Material(
          color: selected
              ? tokens.colorBrandHighlight
              : _hovered
                  ? tokens.colorSuperRaisedBg
                  : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            borderRadius: BorderRadius.circular(12),
            onTap: widget.onSelect,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Icon(
                    selected
                        ? Icons.radio_button_checked
                        : Icons.radio_button_off,
                    size: 20,
                    color: selected
                        ? tokens.colorBrand
                        : tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  const SizedBox(width: 10),
                  AccountAvatar(account: a, size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          a.username,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontWeight: FontWeight.w700,
                            color: tokens.colorContrast,
                          ),
                        ),
                        Text(
                          switch (a.kind) {
                            'msa' => '微软账号',
                            'yggdrasil' =>
                              '${widget.serviceName ?? '外置登录'} · 外置账号',
                            _ => '离线账号',
                          },
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.colorBase.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (widget.onEdit != null)
                    IconButton(
                      tooltip: '修改皮肤',
                      onPressed: widget.onEdit,
                      icon: Icon(
                        Icons.edit_outlined,
                        color: tokens.colorBrand,
                      ),
                    ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: widget.canRemove ? widget.onRemove : null,
                    icon: Icon(
                      Icons.delete_outline,
                      color: widget.canRemove
                          ? tokens.colorBase.withValues(alpha: 0.75)
                          : tokens.colorBase.withValues(alpha: 0.25),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
