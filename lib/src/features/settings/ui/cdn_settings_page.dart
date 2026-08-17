import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/settings/application/proxy_runtime.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/features/settings/ui/settings_switch_row.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class CdnSettingsPage extends StatefulWidget {
  const CdnSettingsPage({super.key});

  @override
  State<CdnSettingsPage> createState() => _CdnSettingsPageState();
}

class _CdnSettingsPageState extends State<CdnSettingsPage> {
  late final TextEditingController _proxyUrlController;

  @override
  void initState() {
    super.initState();
    _proxyUrlController = TextEditingController(
      text: getIt<UiSettingsState>().proxyUrl.value,
    );
  }

  @override
  void dispose() {
    _proxyUrlController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ui = getIt<UiSettingsState>();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Watch((context) {
        final officialFirst = ui.cdnOfficialFirst.watch(context);
        final proxyMode = ui.proxyMode.watch(context);
        final proxyUrl = ui.proxyUrl.watch(context);
        final parsed = ProxyRuntime.parseProxyUrl(proxyUrl);
        return ListView(
          children: [
            Text(
              '网络',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '代理只作用于启动器自己的下载、登录、发现页和更新检查，不会改游戏进程的网络。',
              style: TextStyle(
                fontSize: 14,
                color: tokens.colorBase.withValues(alpha: 0.7),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            _card(
              tokens: tokens,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 10),
                    child: Text(
                      '网络代理',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                  SegmentedButton<String>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return tokens.colorOnBrand;
                        }
                        return tokens.colorContrast;
                      }),
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return tokens.colorBrand;
                        }
                        return tokens.colorButtonBg;
                      }),
                    ),
                    segments: const [
                      ButtonSegment(value: 'off', label: Text('直连')),
                      ButtonSegment(value: 'system', label: Text('系统代理')),
                      ButtonSegment(value: 'manual', label: Text('手动')),
                    ],
                    selected: {proxyMode},
                    onSelectionChanged: (selected) {
                      if (selected.isEmpty) return;
                      ui.setProxyMode(selected.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    switch (proxyMode) {
                      'off' => '启动器所有请求不走代理，忽略系统代理和环境变量。',
                      'manual' =>
                        '填写 HTTP / SOCKS5 代理地址。常见写法：http://127.0.0.1:7890',
                      _ =>
                        '跟随 Windows 系统代理，或环境变量 HTTP_PROXY / HTTPS_PROXY。',
                    },
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                  if (proxyMode == 'manual') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: _proxyUrlController,
                      decoration: InputDecoration(
                        labelText: '代理地址',
                        hintText: 'http://127.0.0.1:7890',
                        border: const OutlineInputBorder(),
                        errorText: proxyUrl.trim().isNotEmpty && parsed == null
                            ? '格式无效，例如 http://127.0.0.1:7890 或 socks5://127.0.0.1:7890'
                            : null,
                      ),
                      onChanged: ui.setProxyUrl,
                    ),
                  ],
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Text(
              '下载加速',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w700,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '官方失败后再走镜像。',
              style: TextStyle(
                fontSize: 14,
                color: tokens.colorBase.withValues(alpha: 0.7),
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            _card(
              tokens: tokens,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Padding(
                    padding: const EdgeInsets.only(top: 8, bottom: 10),
                    child: Text(
                      '下载顺序',
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: tokens.colorContrast,
                      ),
                    ),
                  ),
                  SegmentedButton<bool>(
                    showSelectedIcon: false,
                    style: ButtonStyle(
                      foregroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return tokens.colorOnBrand;
                        }
                        return tokens.colorContrast;
                      }),
                      backgroundColor: WidgetStateProperty.resolveWith((states) {
                        if (states.contains(WidgetState.selected)) {
                          return tokens.colorBrand;
                        }
                        return tokens.colorButtonBg;
                      }),
                    ),
                    segments: const [
                      ButtonSegment(value: true, label: Text('官方优先')),
                      ButtonSegment(value: false, label: Text('镜像优先')),
                    ],
                    selected: {officialFirst},
                    onSelectionChanged: (selected) {
                      if (selected.isEmpty) return;
                      ui.setCdnOfficialFirst(selected.first);
                    },
                  ),
                  const SizedBox(height: 8),
                  Text(
                    officialFirst
                        ? '先连 CurseForge / Modrinth / Mojang，失败再镜像'
                        : '先走加速源，失败再回官方（国内网络通常更快）',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              tokens: tokens,
              child: Column(
                children: [
                  SettingsSwitchRow(
                    tokens: tokens,
                    title: 'MCIM',
                    subtitle:
                        'mod.mcimirror.top · CurseForge / Modrinth 的 API 与文件镜像',
                    value: ui.cdnMcim.watch(context),
                    onChanged: ui.setCdnMcim,
                  ),
                  Divider(
                    height: 1,
                    color: tokens.colorSecondary.withValues(alpha: 0.2),
                  ),
                  SettingsSwitchRow(
                    tokens: tokens,
                    title: 'Pysio CDN',
                    subtitle:
                        'mcim-files.pysio.online · 可避开回源官方 CDN 被掐',
                    value: ui.cdnPysio.watch(context),
                    onChanged: ui.setCdnPysio,
                  ),
                ],
              ),
            ),
            const SizedBox(height: 12),
            _card(
              tokens: tokens,
              child: SettingsSwitchRow(
                tokens: tokens,
                title: 'BMCLAPI',
                subtitle:
                    'bmclapi2.bangbang93.com · Minecraft 客户端、libraries、assets、Forge/Fabric Maven、authlib-injector。不加速模组文件。',
                value: ui.cdnBmclapi.watch(context),
                onChanged: ui.setCdnBmclapi,
              ),
            ),
          ],
        );
      }),
    );
  }

  Widget _card({required AppThemeTokens tokens, required Widget child}) {
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
