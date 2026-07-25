import 'package:aml/src/shared/widgets/components/dialogs/modal_animated_dialog.dart';
import 'package:aml/src/shared/widgets/components/dialogs/modal_motion.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/settings/settings_navigation_panel.dart';
import 'package:aml/src/features/settings/ui/settings_pages.dart';
import 'package:flutter/material.dart';

/// Allows nested settings pages to switch the sidebar selection.
class SettingsNavigator extends InheritedWidget {
  const SettingsNavigator({
    super.key,
    required this.selectPage,
    required super.child,
  });

  final void Function(String pageId) selectPage;

  static SettingsNavigator? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<SettingsNavigator>();

  static void go(BuildContext context, String pageId) {
    maybeOf(context)?.selectPage(pageId);
  }

  @override
  bool updateShouldNotify(SettingsNavigator oldWidget) =>
      selectPage != oldWidget.selectPage;
}

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, this.initialPageId});

  /// 打开设置时默认选中的页面（如 `translation`）。
  final String? initialPageId;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen>
    with SingleTickerProviderStateMixin {
  late final ModalMotion _motion;

  String _selectedPageId = SettingsPages.pages.first.id;

  @override
  void initState() {
    super.initState();
    final initial = widget.initialPageId;
    if (initial != null &&
        SettingsPages.pages.any((page) => page.id == initial)) {
      _selectedPageId = initial;
    }
    _motion = ModalMotion(this)..forward();
  }

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  void _closeSettings() {
    _motion.reverse();
    Navigator.of(context).pop();
  }

  void _selectPage(String pageId) {
    setState(() => _selectedPageId = pageId);
  }

  Widget _getCurrentPage() {
    final currentConfig = SettingsPages.pages.firstWhere(
      (config) => config.id == _selectedPageId,
      orElse: () => SettingsPages.pages.first,
    );
    return currentConfig.page;
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;

    return AnimatedModalDialog.fromMotion(
      motion: _motion,
      onClose: _closeSettings,
      child: SettingsNavigator(
        selectPage: _selectPage,
        child: Container(
          width: 900,
          height: 630,
          decoration: BoxDecoration(
            color: tokens.colorRaisedBg,
            borderRadius: BorderRadius.circular(20),
          ),
          padding: EdgeInsets.zero,
          child: Column(
            children: [
              SizedBox(
                height: 84,
                width: double.infinity,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 18),
                  child: Row(
                    children: [
                      const SizedBox(width: 12),
                      Icon(Icons.settings, size: 25, color: tokens.colorContrast),
                      const SizedBox(width: 8),
                      Text(
                        '设置',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                      const Spacer(),
                      IconButton(
                        tooltip: '关闭',
                        onPressed: _closeSettings,
                        icon: Icon(Icons.close, color: tokens.colorContrast),
                      ),
                    ],
                  ),
                ),
              ),
              Divider(
                height: 1,
                thickness: 1,
                color: tokens.colorSecondary.withAlpha(35),
              ),
              const SizedBox(height: 20),
              Expanded(
                child: Row(
                  children: [
                    SizedBox(
                      width: 285,
                      child: SettingsNavigationPanel(
                        selectedPageId: _selectedPageId,
                        onPageSelected: _selectPage,
                      ),
                    ),
                    SizedBox(
                      height: double.infinity,
                      child: FractionallySizedBox(
                        heightFactor: 1,
                        child: VerticalDivider(
                          thickness: 1,
                          color: tokens.colorSecondary.withAlpha(35),
                        ),
                      ),
                    ),
                    Expanded(
                      child: KeyedSubtree(
                        key: ValueKey(_selectedPageId),
                        child: _getCurrentPage(),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 20),
            ],
          ),
        ),
      ),
    );
  }
}
