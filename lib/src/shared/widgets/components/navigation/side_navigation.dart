import 'package:aml/src/app/app_store.dart';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/account_avatar.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/instances/ui/create_new_instance.dart';
import 'package:aml/src/features/settings/ui/settings_screen.dart';
import 'package:aml/src/features/shell/main_navigation.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/instance_icon.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class SideNavigation extends StatelessWidget {
  const SideNavigation({super.key});

  AppStore get _appStore => getIt<AppStore>();
  NavigationState get _nav => getIt<NavigationState>();
  InstanceStore get _instances => getIt<InstanceStore>();

  List<rust.InstanceDto> _recentInstances() {
    final list = List<rust.InstanceDto>.from(_instances.instances.value);
    list.sort((a, b) {
      final aKey = a.lastPlayed ?? a.createdAt;
      final bKey = b.lastPlayed ?? b.createdAt;
      return bKey.compareTo(aKey);
    });
    return list.take(3).toList();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      width: 64,
      color: tokens.colorRaisedBg,
      child: Column(
        children: [
          ...MainNavigationConfig.pages.asMap().entries.map((entry) {
            final pageConfig = entry.value;
            return NavButton(
              icon: pageConfig.icon,
              label: pageConfig.label,
              isSelected:
                  _nav.selectedInstanceId.watch(context) == null &&
                  _appStore.navigation.currentPage.watch(context) ==
                      pageConfig.id,
              onTap: () => _nav.goToPage(pageConfig.id),
            );
          }),
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Divider(
              height: 1,
              thickness: 1,
              indent: 19,
              endIndent: 19,
              color: tokens.colorDivider,
            ),
          ),
          Watch((context) {
            // Depend on instances list so recent section refreshes.
            final _ = _instances.instances.value;
            final recent = _recentInstances();
            final selectedId = _nav.selectedInstanceId.value;
            if (recent.isEmpty) {
              return const SizedBox.shrink();
            }
            return Column(
              children: [
                ...recent.map(
                  (instance) => NavButton(
                    avatar: InstanceIcon(
                      instanceId: instance.id,
                      iconPath: instance.icon,
                      size: 28,
                      borderRadius: 5,
                    ),
                    label: instance.name,
                    isSelected: selectedId == instance.id,
                    onTap: () => _nav.openInstance(instance.id),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 10),
                  child: Divider(
                    height: 1,
                    thickness: 1,
                    indent: 19,
                    endIndent: 19,
                    color: tokens.colorDivider,
                  ),
                ),
              ],
            );
          }),
          CustomButton(
            icon: Icons.add_outlined,
            label: '创建实例',
            onTap: () {
              Navigator.of(context).push(
                PageRouteBuilder(
                  opaque: false,
                  pageBuilder: (_, __, ___) => const CreateNewInstance(),
                ),
              );
            },
          ),
          const Spacer(),
          const _AccountNavButton(),
          CustomButton(
            icon: Icons.tune_outlined,
            label: '设置',
            onTap: () {
              Navigator.of(context).push(
                PageRouteBuilder(
                  opaque: false,
                  pageBuilder: (_, __, ___) => const SettingsScreen(),
                ),
              );
            },
          ),
          const SizedBox(height: 10),
        ],
      ),
    );
  }
}

class _AccountNavButton extends StatelessWidget {
  const _AccountNavButton();

  @override
  Widget build(BuildContext context) {
    final store = getIt<AccountStore>();
    return Watch((context) {
      final active = store.activeAccount;
      // Depend on accounts list so avatar refreshes after login/switch.
      final _ = store.accounts.value;
      return NavButton(
        avatar: active != null
            ? AccountAvatar(account: active, size: 28)
            : Icon(
                Icons.person_outline,
                size: 24,
                color: context.tokens.colorBase,
              ),
        label: active?.username ?? '账号',
        isSelected: false,
        onTap: () => showAccountsPopup(context),
      );
    });
  }
}
