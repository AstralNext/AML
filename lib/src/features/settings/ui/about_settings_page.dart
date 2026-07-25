import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:url_launcher/url_launcher.dart';

class AboutSettingsPage extends StatefulWidget {
  const AboutSettingsPage({super.key});

  @override
  State<AboutSettingsPage> createState() => _AboutSettingsPageState();
}

class _AboutSettingsPageState extends State<AboutSettingsPage> {
  PackageInfo? _info;

  @override
  void initState() {
    super.initState();
    PackageInfo.fromPlatform().then((info) {
      if (!mounted) return;
      setState(() => _info = info);
    });
  }

  Future<void> _open(String url) async {
    final uri = Uri.tryParse(url);
    if (uri == null) return;
    await launchUrl(uri, mode: LaunchMode.externalApplication);
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final version = _info?.version;
    final build = _info?.buildNumber;

    return Padding(
      padding: const EdgeInsets.all(20),
      child: ListView(
        children: [
          Text(
            '关于',
            style: TextStyle(
              fontSize: 24,
              fontWeight: FontWeight.bold,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Astral Minecraft Launcher（AML）',
            style: TextStyle(
              fontSize: 14,
              color: tokens.colorBase.withValues(alpha: 0.7),
            ),
          ),
          const SizedBox(height: 20),
          _card(
            tokens: tokens,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  version == null
                      ? 'AML'
                      : 'AML $version${build == null || build.isEmpty ? '' : ' ($build)'}',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  '开源 Minecraft 启动器。',
                  style: TextStyle(
                    fontSize: 13,
                    color: tokens.colorBase.withValues(alpha: 0.75),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            tokens: tokens,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '致谢',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  '感谢 Modrinth、MCIM、authlib-injector、CurseForge / Overwolf、'
                  '小米 MiSans。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: tokens.colorBase.withValues(alpha: 0.85),
                  ),
                ),
                const SizedBox(height: 14),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    NavRectButton(
                      isSelected: true,
                      icon: Icons.public,
                      text: 'Modrinth',
                      selectedBackgroundColor: tokens.colorBrand,
                      selectedColor: tokens.colorOnBrand,
                      onTap: () => _open('https://modrinth.com'),
                    ),
                    NavRectButton(
                      isSelected: false,
                      icon: Icons.cloud_outlined,
                      text: 'MCIM',
                      defaultBackgroundColor: tokens.colorButtonBg,
                      defaultColor: tokens.colorContrast,
                      onTap: () => _open('https://mcimirror.top'),
                    ),
                    NavRectButton(
                      isSelected: false,
                      icon: Icons.lock_outline,
                      text: 'authlib-injector',
                      defaultBackgroundColor: tokens.colorButtonBg,
                      defaultColor: tokens.colorContrast,
                      onTap: () => _open(
                        'https://github.com/yushijinhun/authlib-injector',
                      ),
                    ),
                    NavRectButton(
                      isSelected: false,
                      icon: Icons.extension_outlined,
                      text: 'CurseForge',
                      defaultBackgroundColor: tokens.colorButtonBg,
                      defaultColor: tokens.colorContrast,
                      onTap: () => _open('https://www.curseforge.com'),
                    ),
                    NavRectButton(
                      isSelected: false,
                      icon: Icons.font_download_outlined,
                      text: 'MiSans',
                      defaultBackgroundColor: tokens.colorButtonBg,
                      defaultColor: tokens.colorContrast,
                      onTap: () => _open('https://hyperos.mi.com/font'),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          _card(
            tokens: tokens,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '免责声明',
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 10),
                Text(
                  'NOT AN OFFICIAL MINECRAFT PRODUCT. NOT APPROVED BY OR '
                  'ASSOCIATED WITH MOJANG OR MICROSOFT.\n\n'
                  '本软件并非 Minecraft 官方产品，亦未获得 Mojang 或 Microsoft '
                  '的批准或关联。Minecraft 及相关商标归 Mojang Studios 与 '
                  'Microsoft 所有。',
                  style: TextStyle(
                    fontSize: 13,
                    height: 1.45,
                    color: tokens.colorBase.withValues(alpha: 0.85),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _card({
    required AppThemeTokens tokens,
    required Widget child,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
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
