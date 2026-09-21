import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/ui/accounts_account_tile.dart';
import 'package:aml/src/features/accounts/ui/accounts_add_section.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/wardrobe/ui/skin_editor_dialog.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_dialog_actions.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
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
  String? _status;

  AccountStore get _store => getIt<AccountStore>();

  @override
  void initState() {
    super.initState();
    _motion = ModalMotion(this)..forward();
    _store.refresh();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _close() {
    _motion.reverse();
    Navigator.of(context).pop();
  }

  void _setStatus(String? status) {
    setState(() => _status = status);
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
                              AccountTile(
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
                      AccountsAddSection(
                        store: _store,
                        onStatus: _setStatus,
                      ),
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
