import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/accounts/ui/accounts_popup.dart';
import 'package:aml/src/features/home/ui/home_helpers.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class HomeOnboarding extends StatelessWidget {
  const HomeOnboarding({super.key});

  @override
  Widget build(BuildContext context) {
    return Watch((context) => _buildOnboarding(context));
  }

  Widget _buildOnboarding(BuildContext context) {
    final tokens = context.tokens;
    final ui = getIt<UiSettingsState>();
    final dismissed = ui.onboardingDismissed.watch(context);
    if (dismissed) return const SizedBox.shrink();

    final accounts = getIt<AccountStore>().accounts.watch(context);
    final instances = getIt<InstanceStore>().instances.watch(context);
    final hasAccount = accounts.isNotEmpty;
    final hasInstance = instances.isNotEmpty;
    final hasPlayed = instances.any(
      (i) => i.lastPlayed != null && i.lastPlayed!.isNotEmpty,
    );

    // Auto-dismiss once the user has gone through the core loop.
    if (hasAccount && hasInstance && hasPlayed) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (ui.onboardingDismissed.value) return;
        ui.dismissOnboarding();
      });
      return const SizedBox.shrink();
    }

    // Only show for truly new users (no account or no instance).
    if (hasAccount && hasInstance) return const SizedBox.shrink();

    Widget step({
      required int index,
      required String title,
      required String subtitle,
      required bool done,
      required VoidCallback? onTap,
    }) {
      return InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: done ? null : onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
          child: Row(
            children: [
              Container(
                width: 28,
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: done
                      ? tokens.colorBrand.withValues(alpha: 0.2)
                      : tokens.colorButtonBg,
                ),
                child: done
                    ? Icon(Icons.check, size: 16, color: tokens.colorBrand)
                    : Text(
                        '$index',
                        style: TextStyle(
                          fontWeight: FontWeight.w800,
                          color: tokens.colorContrast,
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                        decoration:
                            done ? TextDecoration.lineThrough : null,
                      ),
                    ),
                    Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 12,
                        color: tokens.colorBase.withValues(alpha: 0.65),
                      ),
                    ),
                  ],
                ),
              ),
              if (!done)
                Icon(
                  Icons.chevron_right,
                  color: tokens.colorBase.withValues(alpha: 0.45),
                ),
            ],
          ),
        ),
      );
    }

    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 16),
      padding: const EdgeInsets.fromLTRB(16, 14, 12, 12),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: tokens.colorBrand.withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '开始你的第一次冒险',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              TextButton(
                onPressed: ui.dismissOnboarding,
                child: const Text('跳过'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          step(
            index: 1,
            title: '添加账号',
            subtitle: hasAccount ? '已完成' : '登录正版、外置，或创建离线账号',
            done: hasAccount,
            onTap: () => showAccountsPopup(context),
          ),
          step(
            index: 2,
            title: '创建实例',
            subtitle: hasInstance ? '已完成' : '自定义安装，或去发现整合包',
            done: hasInstance,
            onTap: () {
              if (!hasAccount) {
                showAccountsPopup(context);
                return;
              }
              openCreateInstance(context);
            },
          ),
          step(
            index: 3,
            title: '启动游戏',
            subtitle: hasPlayed
                ? '已完成'
                : hasInstance
                    ? '打开库或首页「继续游玩」启动'
                    : '创建实例后再启动',
            done: hasPlayed,
            onTap: hasInstance
                ? () => getIt<NavigationState>().goToPage('library')
                : null,
          ),
        ],
      ),
    );
  }
}
