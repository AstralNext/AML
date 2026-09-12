import 'package:aml/src/features/instances/application/instance_play_stats.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

class InstanceOverviewScreenshot {
  const InstanceOverviewScreenshot({
    required this.path,
    required this.name,
    this.modified,
  });

  final String path;
  final String name;
  final DateTime? modified;
}

class _RecentScreenshotsCarousel extends StatefulWidget {
  const _RecentScreenshotsCarousel({
    required this.screenshots,
    required this.tokens,
    required this.onOpenScreenshot,
  });

  final List<InstanceOverviewScreenshot> screenshots;
  final AppThemeTokens tokens;
  final void Function(int index) onOpenScreenshot;

  @override
  State<_RecentScreenshotsCarousel> createState() =>
      _RecentScreenshotsCarouselState();
}

class _RecentScreenshotsCarouselState
    extends State<_RecentScreenshotsCarousel> {
  final CarouselController _controller = CarouselController();
  int _currentIndex = 0;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(covariant _RecentScreenshotsCarousel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_currentIndex >= widget.screenshots.length) {
      _currentIndex =
          widget.screenshots.isEmpty ? 0 : widget.screenshots.length - 1;
    }
  }

  void _move(int direction) {
    final target =
        (_currentIndex + direction).clamp(0, widget.screenshots.length - 1);
    if (target == _currentIndex) return;
    _controller.animateToItem(
      target,
      duration: const Duration(milliseconds: 240),
      curve: Curves.easeOutCubic,
    );
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent || !_controller.hasClients) return;
    final delta = event.scrollDelta.dx.abs() > event.scrollDelta.dy.abs()
        ? event.scrollDelta.dx
        : event.scrollDelta.dy;
    if (delta == 0) return;
    GestureBinding.instance.pointerSignalResolver.register(
      event,
      (_) => _move(delta > 0 ? 1 : -1),
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = widget.tokens;
    final canGoBack = _currentIndex > 0;
    final canGoForward = _currentIndex < widget.screenshots.length - 1;

    return SizedBox(
      height: 176,
      child: Listener(
        onPointerSignal: _handlePointerSignal,
        child: Stack(
          children: [
            Positioned.fill(
              child: ScrollConfiguration(
                behavior: ScrollConfiguration.of(context).copyWith(
                  dragDevices: const {
                    PointerDeviceKind.touch,
                    PointerDeviceKind.mouse,
                    PointerDeviceKind.trackpad,
                    PointerDeviceKind.stylus,
                    PointerDeviceKind.invertedStylus,
                  },
                ),
                child: CarouselView.weighted(
                  controller: _controller,
                  flexWeights: const [3, 2, 1],
                  itemSnapping: true,
                  consumeMaxWeight: false,
                  shrinkExtent: 72,
                  padding: const EdgeInsets.all(4),
                  backgroundColor: tokens.colorRaisedBg,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(18),
                  ),
                  overlayColor: WidgetStatePropertyAll(
                    tokens.colorBrand.withValues(alpha: 0.12),
                  ),
                  onIndexChanged: (index) {
                    if (_currentIndex != index) {
                      setState(() => _currentIndex = index);
                    }
                  },
                  onTap: widget.onOpenScreenshot,
                  children: [
                    for (final shot in widget.screenshots)
                      _ScreenshotCarouselItem(shot: shot, tokens: tokens),
                  ],
                ),
              ),
            ),
            Positioned(
              left: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _CarouselArrowButton(
                  icon: Icons.chevron_left,
                  enabled: canGoBack,
                  onPressed: () => _move(-1),
                ),
              ),
            ),
            Positioned(
              right: 10,
              top: 0,
              bottom: 0,
              child: Center(
                child: _CarouselArrowButton(
                  icon: Icons.chevron_right,
                  enabled: canGoForward,
                  onPressed: () => _move(1),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _ScreenshotCarouselItem extends StatelessWidget {
  const _ScreenshotCarouselItem({
    required this.shot,
    required this.tokens,
  });

  final InstanceOverviewScreenshot shot;
  final AppThemeTokens tokens;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        CachedRemoteImage(
          url: shot.path,
          fit: BoxFit.cover,
          placeholder: ColoredBox(
            color: tokens.colorSecondary.withValues(alpha: 0.12),
            child: const Center(
              child: SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
            ),
          ),
          error: ColoredBox(
            color: tokens.colorSecondary.withValues(alpha: 0.12),
            child: Icon(
              Icons.broken_image_outlined,
              color: tokens.colorBase.withValues(alpha: 0.5),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 22, 12, 9),
            decoration: const BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [Colors.transparent, Color(0xB3000000)],
              ),
            ),
            child: Text(
              shot.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _CarouselArrowButton extends StatelessWidget {
  const _CarouselArrowButton({
    required this.icon,
    required this.enabled,
    required this.onPressed,
  });

  final IconData icon;
  final bool enabled;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: enabled ? const Color(0xCC1B1B1B) : const Color(0x551B1B1B),
      shape: const CircleBorder(),
      elevation: enabled ? 3 : 0,
      child: IconButton(
        tooltip: icon == Icons.chevron_left ? '上一张' : '下一张',
        onPressed: enabled ? onPressed : null,
        icon: Icon(icon, color: enabled ? Colors.white : Colors.white38),
      ),
    );
  }
}

class InstanceOverviewTab extends StatelessWidget {
  const InstanceOverviewTab({
    super.key,
    required this.tokens,
    required this.stats,
    required this.statsLoading,
    required this.screenshots,
    required this.screenshotsLoading,
    required this.onRefresh,
    required this.onOpenScreenshot,
    required this.onSeeAllScreenshots,
    this.playerName,
  });

  final AppThemeTokens tokens;
  final InstancePlayStats? stats;
  final bool statsLoading;
  final List<InstanceOverviewScreenshot> screenshots;
  final bool screenshotsLoading;
  final VoidCallback onRefresh;
  final void Function(int index) onOpenScreenshot;
  final VoidCallback onSeeAllScreenshots;
  final String? playerName;

  @override
  Widget build(BuildContext context) {
    final recent = screenshots.take(8).toList();
    final hasStats = stats != null && !stats!.isEmpty;
    final aggregated = hasStats ? stats!.aggregated : null;

    return RefreshIndicator(
      onRefresh: () async => onRefresh(),
      child: ListView(
        padding: const EdgeInsets.only(bottom: 8),
        children: [
          Row(
            children: [
              Text(
                '概览',
                style: TextStyle(
                  fontWeight: FontWeight.w800,
                  color: tokens.colorContrast,
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: onRefresh,
                icon: const Icon(Icons.refresh, size: 16),
                label: const Text('刷新'),
                style: TextButton.styleFrom(
                  foregroundColor: tokens.colorContrast,
                ),
              ),
            ],
          ),
          const SizedBox(height: 4),
          _sectionTitle(tokens, '最近截图'),
          const SizedBox(height: 8),
          if (screenshotsLoading && recent.isEmpty)
            const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (recent.isEmpty)
            _emptyHint(
              tokens,
              icon: Icons.photo_camera_outlined,
              title: '还没有截图',
              subtitle: '在游戏中按 F2 截图后会出现在这里',
            )
          else ...[
            _RecentScreenshotsCarousel(
              screenshots: recent,
              tokens: tokens,
              onOpenScreenshot: onOpenScreenshot,
            ),
            if (screenshots.length > recent.length) ...[
              const SizedBox(height: 6),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onSeeAllScreenshots,
                  child: Text(
                    '查看全部 ${screenshots.length} 张',
                    style: TextStyle(color: tokens.colorBrand),
                  ),
                ),
              ),
            ],
          ],
          const SizedBox(height: 20),
          _sectionTitle(
            tokens,
            '游玩数据',
            trailing: playerName != null && playerName!.isNotEmpty
                ? Text(
                    playerName!,
                    style: TextStyle(
                      fontSize: 12,
                      color: tokens.colorBase.withValues(alpha: 0.65),
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 8),
          if (statsLoading && stats == null)
            const SizedBox(
              height: 120,
              child: Center(child: CircularProgressIndicator()),
            )
          else if (!hasStats || aggregated == null)
            _emptyHint(
              tokens,
              icon: Icons.insights_outlined,
              title: '暂无统计数据',
              subtitle: '进入单人世界游玩一段时间后，统计会自动出现',
            )
          else ...[
            Text(
              '共 ${aggregated.entryCount} 项数据，${aggregated.categories.length} 个分类（跨世界汇总）',
              style: TextStyle(
                fontSize: 12,
                color: tokens.colorBase.withValues(alpha: 0.65),
              ),
            ),
            const SizedBox(height: 8),
            ...aggregated.categories.map(
              (category) => _StatCategorySection(
                tokens: tokens,
                category: category,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '数据来自 stats JSON 文件${playerName != null && playerName!.isNotEmpty ? '（优先当前账号）' : ''}，跨所有单人世界汇总。',
              style: TextStyle(
                fontSize: 11,
                color: tokens.colorBase.withValues(alpha: 0.5),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _sectionTitle(AppThemeTokens tokens, String title,
      {Widget? trailing}) {
    return Row(
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 15,
            fontWeight: FontWeight.w800,
            color: tokens.colorContrast,
          ),
        ),
        if (trailing != null) ...[
          const SizedBox(width: 10),
          trailing,
        ],
      ],
    );
  }

  Widget _emptyHint(
    AppThemeTokens tokens, {
    required IconData icon,
    required String title,
    required String subtitle,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
      decoration: BoxDecoration(
        color: tokens.colorRaisedBg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: [
          Icon(icon, size: 32, color: tokens.colorBase.withValues(alpha: 0.45)),
          const SizedBox(height: 10),
          Text(
            title,
            style: TextStyle(
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              fontSize: 13,
              color: tokens.colorBase.withValues(alpha: 0.65),
            ),
          ),
        ],
      ),
    );
  }
}

class _StatCategorySection extends StatelessWidget {
  const _StatCategorySection({
    required this.tokens,
    required this.category,
  });

  final AppThemeTokens tokens;
  final StatCategory category;

  @override
  Widget build(BuildContext context) {
    final bg = tokens.colorRaisedBg;

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: bg,
        child: Theme(
          data: Theme.of(context).copyWith(
            dividerColor: Colors.transparent,
            splashColor: tokens.colorBrand.withValues(alpha: 0.08),
            highlightColor: tokens.colorBrand.withValues(alpha: 0.05),
          ),
          child: ExpansionTile(
            backgroundColor: bg,
            collapsedBackgroundColor: bg,
            iconColor: tokens.colorContrast,
            collapsedIconColor: tokens.colorBase.withValues(alpha: 0.7),
            initiallyExpanded: category.id == 'minecraft:custom',
            tilePadding:
                const EdgeInsets.symmetric(horizontal: 14, vertical: 2),
            childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 10),
            title: Text(
              category.label,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: tokens.colorContrast,
              ),
            ),
            subtitle: Text(
              '${category.entries.length} 项',
              style: TextStyle(
                fontSize: 12,
                color: tokens.colorBase.withValues(alpha: 0.6),
              ),
            ),
            children: [
              LayoutBuilder(
                builder: (context, constraints) {
                  return _StatsEntryGrid(
                    tokens: tokens,
                    entries: category.entries,
                    maxWidth: constraints.maxWidth,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatsEntryGrid extends StatelessWidget {
  const _StatsEntryGrid({
    required this.tokens,
    required this.entries,
    required this.maxWidth,
  });

  final AppThemeTokens tokens;
  final List<StatEntry> entries;
  final double maxWidth;

  int get _columns {
    if (maxWidth >= 880) return 3;
    if (maxWidth >= 520) return 2;
    return 1;
  }

  @override
  Widget build(BuildContext context) {
    const spacing = 12.0;
    final columns = _columns;
    final cellWidth = (maxWidth - spacing * (columns - 1)) / columns;

    return Wrap(
      spacing: spacing,
      runSpacing: 10,
      children: [
        for (final entry in entries)
          SizedBox(
            width: cellWidth,
            child: _StatEntryCell(tokens: tokens, entry: entry),
          ),
      ],
    );
  }
}

class _StatEntryCell extends StatelessWidget {
  const _StatEntryCell({required this.tokens, required this.entry});

  final AppThemeTokens tokens;
  final StatEntry entry;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: tokens.colorBg.withValues(alpha: 0.45),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            entry.displayName,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: tokens.colorBase.withValues(alpha: 0.75),
            ),
          ),
          const SizedBox(height: 4),
          Text(
            entry.displayValue,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: tokens.colorBrand,
            ),
          ),
        ],
      ),
    );
  }
}
