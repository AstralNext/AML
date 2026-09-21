import 'package:aml/src/features/accounts/ui/accounts_yggdrasil_profile_option.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/inputs/dropdown_button_widget.dart';
import 'package:aml/src/shared/widgets/components/inputs/input_bar.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class AccountsAddSection extends StatefulWidget {
  const AccountsAddSection({
    super.key,
    required this.store,
    required this.onStatus,
  });

  final AccountStore store;
  final ValueChanged<String?> onStatus;

  @override
  State<AccountsAddSection> createState() => _AccountsAddSectionState();
}

class _AccountsAddSectionState extends State<AccountsAddSection> {
  final _offlineController = TextEditingController();
  final _yggdrasilUsernameController = TextEditingController();
  final _yggdrasilPasswordController = TextEditingController();
  bool _showAdd = false;
  String? _addAccountType;
  String? _selectedYggdrasilServiceId;
  String? _pendingYggdrasilLoginId;
  String? _selectedYggdrasilProfileId;
  List<rust.YggdrasilProfileDto> _yggdrasilProfiles = const [];

  AccountStore get _store => widget.store;

  @override
  void dispose() {
    _offlineController.dispose();
    _yggdrasilUsernameController.dispose();
    _yggdrasilPasswordController.dispose();
    super.dispose();
  }

  Future<void> _beginYggdrasilLogin(String serviceId) async {
    final username = _yggdrasilUsernameController.text.trim();
    final password = _yggdrasilPasswordController.text;
    if (username.isEmpty || password.isEmpty) {
      widget.onStatus('请输入外置登录账号和密码');
      return;
    }
    try {
      widget.onStatus('正在登录外置验证服务器…');
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
      });
      widget.onStatus('请选择要添加的游戏角色');
    } catch (e) {
      if (!mounted) return;
      widget.onStatus('$e');
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
        _showAdd = false;
        _addAccountType = null;
      });
      widget.onStatus('外置账号登录成功');
    } catch (e) {
      if (!mounted) return;
      widget.onStatus('$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final colorScheme = Theme.of(context).colorScheme;

    if (!_showAdd) {
      return NavRectButton(
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
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
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
                widget.onStatus(null);
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
                widget.onStatus(null);
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
                      _showAdd = false;
                      _addAccountType = null;
                    });
                    widget.onStatus('已添加 $name');
                  } catch (e) {
                    widget.onStatus('$e');
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
                      widget.onStatus('请在弹出窗口完成登录');
                      try {
                        final ok = await _store.loginMicrosoft(context);
                        if (!mounted) return;
                        if (ok) {
                          setState(() {
                            _showAdd = false;
                            _addAccountType = null;
                          });
                          widget.onStatus('微软账号登录成功');
                        } else {
                          widget.onStatus('已取消登录');
                        }
                      } catch (e) {
                        if (!mounted) return;
                        widget.onStatus('$e');
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
                  color: tokens.colorBase.withValues(alpha: 0.65),
                ),
              );
            }
            if (_pendingYggdrasilLoginId != null) {
              return Text(
                '账号验证成功，请选择要添加的游戏角色。',
                style: TextStyle(
                  color: tokens.colorBase.withValues(alpha: 0.72),
                ),
              );
            }
            final selectedId = services
                    .any((service) => service.id == _selectedYggdrasilServiceId)
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
                          : (value) => setState(
                              () => _selectedYggdrasilServiceId = value),
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
                  icon: busy ? Icons.hourglass_top : Icons.login,
                  defaultBackgroundColor: tokens.colorButtonBg,
                  text: busy ? '登录中…' : '登录外置账号',
                  label: busy ? '登录中' : '外置登录',
                  onTap: busy ? () {} : () => _beginYggdrasilLogin(selectedId),
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
                child: YggdrasilProfileOption(
                  profile: profile,
                  selected: profile.id == _selectedYggdrasilProfileId,
                  onTap: () => setState(
                    () => _selectedYggdrasilProfileId = profile.id,
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
    );
  }
}
