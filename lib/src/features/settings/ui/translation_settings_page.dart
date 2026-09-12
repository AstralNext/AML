import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/discover/data/translation_cache_hub.dart';
import 'package:aml/src/features/settings/application/storage_usage_service.dart';
import 'package:aml/src/features/settings/application/ui_settings_state.dart';
import 'package:aml/src/features/settings/ui/settings_screen.dart';
import 'package:aml/src/features/settings/ui/settings_switch_row.dart';
import 'package:aml/src/rust/api/project_i18n.dart' as i18n;
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:aml/src/shared/widgets/components/navigation/nav_rect_button.dart';
import 'package:flutter/material.dart';
import 'package:signals_flutter/signals_flutter.dart';

class TranslationSettingsPage extends StatefulWidget {
  const TranslationSettingsPage({super.key});

  @override
  State<TranslationSettingsPage> createState() =>
      _TranslationSettingsPageState();
}

class _TranslationSettingsPageState extends State<TranslationSettingsPage> {
  i18n.TranslationCacheStatsDto? _dbStats;
  bool _loadingStats = false;
  bool _hasLoadedStats = false;
  String? _busyAction;

  Future<void> _refreshStats({bool silent = false}) async {
    if (_loadingStats) return;
    setState(() => _loadingStats = true);
    try {
      final stats = await TranslationCacheHub.persistentStats();
      if (!mounted) return;
      setState(() {
        _dbStats = stats;
        _hasLoadedStats = true;
        _loadingStats = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadingStats = false);
      if (!silent) {
        showAppSnackBar('读取翻译缓存失败: $e', isError: true);
      }
    }
  }

  Future<void> _runClear({
    required String actionId,
    required String title,
    required String body,
    required Future<int> Function() clear,
  }) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final tokens = ctx.tokens;
        return AlertDialog(
          backgroundColor: tokens.colorRaisedBg,
          title: Text(title, style: TextStyle(color: tokens.colorContrast)),
          content: Text(body, style: TextStyle(color: tokens.colorBase)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('清理'),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    setState(() => _busyAction = actionId);
    try {
      final n = await clear();
      getIt<StorageUsageService>().invalidate();
      if (_hasLoadedStats) {
        await _refreshStats(silent: true);
      }
      if (!mounted) return;
      showAppSnackBar('已清理 $n 项');
      setState(() {});
    } catch (e) {
      if (!mounted) return;
      showAppSnackBar('清理失败: $e', isError: true);
    } finally {
      if (mounted) setState(() => _busyAction = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final ui = getIt<UiSettingsState>();

    return Padding(
      padding: const EdgeInsets.all(20),
      child: Watch((context) {
        final translateBody = ui.translateDiscoverContent.watch(context);
        final mcdbSearch = ui.useMcdbSearch.watch(context);
        final db = _dbStats;

        return ListView(
          children: [
            Text(
              '翻译',
              style: TextStyle(
                fontSize: 24,
                fontWeight: FontWeight.bold,
                color: tokens.colorContrast,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Modrinth 译名走 MCDB 在线 API；详情正文可选云翻译。',
              style: TextStyle(
                fontSize: 14,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 24),
            _sectionTitle(tokens, 'MCDB 在线译名'),
            const SizedBox(height: 8),
            Text(
              'Modrinth 列表与详情页的标题、简介来自 mcdb.astral.fan。',
              style: TextStyle(
                fontSize: 12,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 10),
            _card(
              tokens,
              child: SettingsSwitchRow(
                tokens: tokens,
                title: '中文搜索改写',
                subtitle: mcdbSearch
                    ? '中文关键词先经 MCDB 标题匹配，再用英文标题搜 Modrinth'
                    : '搜索框原文直接提交 Modrinth / CurseForge',
                value: mcdbSearch,
                onChanged: ui.setUseMcdbSearch,
              ),
            ),
            const SizedBox(height: 24),
            _sectionTitle(tokens, '详情页正文'),
            const SizedBox(height: 8),
            Text(
              '仅影响项目详情页的 HTML / Markdown 概述；列表标题不受此项控制。',
              style: TextStyle(
                fontSize: 12,
                color: tokens.colorBase.withValues(alpha: 0.7),
              ),
            ),
            const SizedBox(height: 10),
            _card(
              tokens,
              child: SettingsSwitchRow(
                tokens: tokens,
                title: '云翻译正文',
                subtitle: translateBody
                    ? '详情概述使用微软 Edge 公共翻译'
                    : '详情正文保持英文原文',
                value: translateBody,
                onChanged: ui.setTranslateDiscoverContent,
              ),
            ),
            if (translateBody) ...[
              const SizedBox(height: 12),
              _card(
                tokens,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '翻译引擎',
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        '微软 Edge 公共翻译',
                        style: TextStyle(
                          fontSize: 12,
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 24),
            _sectionTitle(tokens, '正文缓存'),
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Text(
                    '云翻译结果缓存在本地，避免重复请求。',
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.7),
                    ),
                  ),
                ),
                TextButton(
                  onPressed: _loadingStats || _busyAction != null
                      ? null
                      : () => unawaited(_refreshStats()),
                  child: Text(
                    _loadingStats
                        ? '加载中…'
                        : (_hasLoadedStats ? '刷新' : '加载'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (_hasLoadedStats)
              _card(
                tokens,
                child: Column(
                  children: [
                    _statRow(
                      tokens,
                      '磁盘正文缓存',
                      '${db?.textEntries.toInt() ?? 0} 条 · '
                          '${StorageUsageService.formatBytes(db?.textBytes.toInt() ?? 0)}',
                    ),
                    _statRow(
                      tokens,
                      '会话内存',
                      '${TranslationCacheHub.memoryEntries} 条',
                      isLast: true,
                    ),
                  ],
                ),
              ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                NavRectButton(
                  isSelected: false,
                  icon: Icons.article_outlined,
                  text: _busyAction == 'text' ? '清理中…' : '清理磁盘缓存',
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  onTap: _busyAction != null
                      ? () {}
                      : () => unawaited(
                            _runClear(
                              actionId: 'text',
                              title: '清理详情正文缓存？',
                              body: '删除已保存的正文译文。再次打开详情会重新翻译。',
                              clear: TranslationCacheHub.clearBodies,
                            ),
                          ),
                ),
                NavRectButton(
                  isSelected: false,
                  icon: Icons.memory,
                  text: _busyAction == 'memory' ? '清理中…' : '清理会话缓存',
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  onTap: _busyAction != null
                      ? () {}
                      : () => unawaited(
                            _runClear(
                              actionId: 'memory',
                              title: '清理会话缓存？',
                              body: '清空进程内的翻译内存缓存。',
                              clear: () async {
                                final n = TranslationCacheHub.memoryEntries;
                                TranslationCacheHub.clearMemory();
                                return n;
                              },
                            ),
                          ),
                ),
                NavRectButton(
                  isSelected: false,
                  icon: Icons.folder_open_outlined,
                  text: '资源管理',
                  defaultBackgroundColor: tokens.colorButtonBg,
                  defaultColor: tokens.colorContrast,
                  hoverColor: tokens.colorButtonBgSelected,
                  hoverTextColor: tokens.colorButtonTextSelected,
                  onTap: () => SettingsNavigator.go(context, 'resource'),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  Widget _sectionTitle(AppThemeTokens tokens, String title) {
    return Text(
      title,
      style: TextStyle(
        fontSize: 16,
        fontWeight: FontWeight.w800,
        color: tokens.colorContrast,
      ),
    );
  }

  Widget _card(AppThemeTokens tokens, {required Widget child}) {
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

  Widget _statRow(
    AppThemeTokens tokens,
    String label,
    String value, {
    bool isLast = false,
  }) {
    return Padding(
      padding: EdgeInsets.fromLTRB(0, 10, 0, isLast ? 10 : 0),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: tokens.colorBase.withValues(alpha: 0.75),
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
        ],
      ),
    );
  }
}
