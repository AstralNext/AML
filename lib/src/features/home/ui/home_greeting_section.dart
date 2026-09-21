import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/ui/account_avatar.dart';
import 'package:aml/src/features/home/ui/home_helpers.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class HomeGreetingSection extends StatelessWidget {
  const HomeGreetingSection({
    super.key,
    required this.jumpLoading,
    this.firstJump,
  });

  final bool jumpLoading;
  final HomeJumpItem? firstJump;

  @override
  Widget build(BuildContext context) {
    return Watch((context) => _buildGreeting(context));
  }

  Widget _buildGreeting(BuildContext context) {
    final tokens = context.tokens;
    final accounts = getIt<AccountStore>().accounts.watch(context);
    rust.AccountDto? active;
    for (final a in accounts) {
      if (a.active) {
        active = a;
        break;
      }
    }
    final store = getIt<InstanceStore>();
    final hasInstances = store.instances.watch(context).isNotEmpty;

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        if (active != null) ...[
          AccountAvatar(account: active, size: 52),
          const SizedBox(width: 14),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                _greetingTitle(active?.username),
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w800,
                  color: tokens.colorContrast,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                _greetingSubtitle(
                  hasInstances: hasInstances,
                  jumpLoading: jumpLoading,
                ),
                style: TextStyle(
                  fontSize: 14,
                  height: 1.35,
                  color: tokens.colorBase.withValues(alpha: 0.72),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _greetingTitle(String? username) {
    final hour = DateTime.now().hour;
    final period = hour < 6
        ? '夜深了'
        : hour < 12
            ? '早上好'
            : hour < 18
                ? '下午好'
                : '晚上好';
    final name = username?.trim();
    if (name != null && name.isNotEmpty) {
      return '$period，$name';
    }
    final hasPlayed = getIt<InstanceStore>().instances.value.any(
          (i) => i.lastPlayed != null && i.lastPlayed!.isNotEmpty,
        );
    return hasPlayed ? '欢迎回来' : '欢迎来到 AML';
  }

  String _greetingSubtitle({
    required bool hasInstances,
    required bool jumpLoading,
  }) {
    if (!hasInstances) {
      return '新世界在等你——创建一个实例，或先去发现整合包。';
    }
    if (jumpLoading) return '正在看看你最近在玩什么…';
    final item = firstJump;
    if (item != null) {
      final when = relativeTime(item.lastPlayed);
      if (item.world != null) {
        final kind = item.world!.kind == 'server' ? '服务器' : '世界';
        return '上次玩$kind「${item.world!.name}」是 $when';
      }
      return '上次打开「${item.instance.name}」是 $when';
    }
    return '选一个实例，开始今天的冒险吧。';
  }
}
