import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/app_update_service.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/features/settings/ui/settings_switch_row.dart';
import 'package:aml/src/features/settings/ui/update_available_dialog.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:signals_flutter/signals_flutter.dart';

class GeneralSettingsPage extends StatefulWidget {
  const GeneralSettingsPage({super.key});

  @override
  State<GeneralSettingsPage> createState() => _GeneralSettingsPageState();
}

class _GeneralSettingsPageState extends State<GeneralSettingsPage> {
  bool _checking = false;
  String? _currentVersion;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _currentVersion = info.version);
    });
  }

  Future<void> _checkUpdate({bool quietUpToDate = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      final result = await getIt<AppUpdateService>().check();
      if (!mounted) return;

      switch (result.status) {
        case AppUpdateStatus.available:
          final update = result.update!;
          final action = await showUpdateAvailableDialog(
            context,
            update: update,
          );
          if (action == UpdateDialogAction.skip) {
            getIt<UiSettingsState>().setDismissedUpdateTag(update.latestVersion);
            showAppSnackBar('已跳过 ${update.latestVersion}');
          }
        case AppUpdateStatus.upToDate:
          if (!quietUpToDate) {
            showAppSnackBar('已是最新版本（${result.currentVersion}）');
          }
        case AppUpdateStatus.noRelease:
          showAppSnackBar('暂无可用发布，当前 ${result.currentVersion}');
        case AppUpdateStatus.failed:
          showAppSnackBar(
            '检查更新失败: ${result.error ?? '未知错误'}',
            isError: true,
          );
      }
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ui = getIt<UiSettingsState>();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Watch((context) {
        final closeToTray = ui.closeToTray.watch(context);
        final checkOnStartup = ui.checkUpdatesOnStartup.watch(context);
        return ListView(
          children: [
            Text(
              '通用',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '窗口行为与应用更新。翻译相关请到「翻译」页。',
              style: TextStyle(
                fontSize: 14,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 20),
            _settingCard(
              tokens: tokens,
              child: SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  '关闭时最小化到托盘',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: tokens.colorContrast,
                  ),
                ),
                subtitle: Text(
                  closeToTray
                      ? '点击关闭会隐藏到系统托盘，可从托盘恢复或退出'
                      : '点击关闭会直接退出 AML',
                  style: TextStyle(
                    fontSize: 12,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                ),
                value: closeToTray,
                activeThumbColor: tokens.colorOnBrand,
                activeTrackColor: tokens.colorBrand,
                onChanged: ui.setCloseToTray,
              ),
            ),
            const SizedBox(height: 12),
            _settingCard(
              tokens: tokens,
              child: Column(
                children: [
                  SettingsSwitchRow(
                    tokens: tokens,
                    title: '启动时检查更新',
                    subtitle: '启动后静默查询 GitHub Releases，有新版本时提示',
                    value: checkOnStartup,
                    onChanged: ui.setCheckUpdatesOnStartup,
                  ),
                  Divider(
                    height: 1,
                    color: tokens.colorSecondary.withValues(alpha: 0.2),
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '检查更新',
                                style: TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: tokens.colorContrast,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                _currentVersion == null
                                    ? '从 GitHub 获取最新发布'
                                    : '当前版本 $_currentVersion · GitHub Releases',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: tokens.colorBase.withValues(alpha: 0.7),
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 12),
                        NavRectButton(
                          isSelected: !_checking,
                          icon: _checking
                              ? Icons.hourglass_top
                              : Icons.system_update_alt,
                          text: _checking ? '检查中…' : '检查更新',
                          selectedBackgroundColor: tokens.colorBrand,
                          selectedColor: tokens.colorOnBrand,
                          defaultBackgroundColor: tokens.colorButtonBg,
                          defaultColor: tokens.colorContrast,
                          onTap: _checking ? () {} : () => _checkUpdate(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _settingCard({
    required AppThemeTokens tokens,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      decoration: BoxDecoration(
        color: tokens.colorBg.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: tokens.colorSecondary.withValues(alpha: 0.25),
        ),
      ),
      child: child,
    );
  }
}
