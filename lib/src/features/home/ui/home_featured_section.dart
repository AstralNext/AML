import 'dart:async';
import 'dart:math';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/data/discover_translation.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/cards/discover_box.dart';
import 'package:aml/src/shared/widgets/components/common/hover_text_with_arrow.dart';
import 'package:flutter/material.dart';

class HomeFeaturedSection extends StatefulWidget {
  const HomeFeaturedSection({super.key});

  @override
  State<HomeFeaturedSection> createState() => _HomeFeaturedSectionState();
}

class _HomeFeaturedSectionState extends State<HomeFeaturedSection> {
  ModrinthSearchResult? _modResult;
  ModrinthSearchResult? _modpackResult;
  bool _isLoadingFeatured = true;
  String? _featuredError;

  @override
  void initState() {
    super.initState();
    // Local jump-back-in is cheap; defer Modrinth featured until after first frame
    // so cold start does not compete with shell paint / other tabs.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      unawaited(_fetchFeatured());
    });
  }

  Future<void> _fetchFeatured() async {
    try {
      final results = await Future.wait([
        _fetchWeeklyHotFeatured('modpack'),
        _fetchWeeklyHotFeatured('mod'),
      ]);
      if (!mounted) return;
      setState(() {
        _modpackResult = results[0];
        _modResult = results[1];
        _isLoadingFeatured = false;
        _featuredError = null;
      });
      unawaited(_localizeFeaturedInBackground(results[0], results[1]));
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _isLoadingFeatured = false;
        _featuredError = '$e';
      });
    }
  }

  Future<void> _localizeFeaturedInBackground(
    ModrinthSearchResult packs,
    ModrinthSearchResult mods,
  ) async {
    Future<ModrinthSearchResult> localizeOne(ModrinthSearchResult src) async {
      try {
        final map = await DiscoverTranslation.localizeModrinth(
          projects: [
            for (final p in src.hits)
              (
                id: p.projectId,
                slug: p.slug,
                title: p.title,
                description: p.description,
              ),
          ],
        );
        return ModrinthSearchResult(
          hits: [
            for (final p in src.hits)
              p.copyWith(
                title: map[p.projectId]?.title ?? p.title,
                description: map[p.projectId]?.description ?? p.description,
              ),
          ],
          offset: src.offset,
          limit: src.limit,
          totalHits: src.totalHits,
        );
      } catch (_) {
        return src;
      }
    }

    final localized = await Future.wait([
      localizeOne(packs),
      localizeOne(mods),
    ]);
    if (!mounted) return;
    setState(() {
      _modpackResult = localized[0];
      _modResult = localized[1];
    });
  }

  /// Recently updated (7 days) + popular pool, then random pick 3.
  Future<ModrinthSearchResult> _fetchWeeklyHotFeatured(
    String projectType,
  ) async {
    const poolSize = 20;
    const pickCount = 3;
    final weekAgo = DateTime.now().toUtc().subtract(const Duration(days: 7));

    final updated = await ModrinthApiService.searchProjects(
      query: '',
      facets: [
        ['project_type:$projectType'],
      ],
      index: 'updated',
      limit: poolSize,
      cacheDuration: const Duration(minutes: 10),
    );

    List<ModrinthProject> inWeek(List<ModrinthProject> hits) {
      return hits.where((p) {
        final modified = DateTime.tryParse(p.dateModified)?.toUtc();
        return modified != null && !modified.isBefore(weekAgo);
      }).toList();
    }

    var candidates = inWeek(updated.hits);
    if (candidates.length < pickCount) {
      final popular = await ModrinthApiService.searchProjects(
        query: '',
        facets: [
          ['project_type:$projectType'],
        ],
        index: 'downloads',
        limit: poolSize,
        cacheDuration: const Duration(minutes: 10),
      );
      final merged = <String, ModrinthProject>{
        for (final p in [...candidates, ...inWeek(popular.hits)]) p.projectId: p,
      };
      candidates = merged.values.toList();
    }
    if (candidates.isEmpty) {
      candidates = List<ModrinthProject>.from(updated.hits);
    }

    candidates.sort((a, b) => b.downloads.compareTo(a.downloads));
    final top = candidates.take(16).toList()..shuffle(Random());
    final picks = top.take(pickCount).toList();

    return ModrinthSearchResult(
      hits: picks,
      offset: 0,
      limit: picks.length,
      totalHits: picks.length,
    );
  }

  Widget _buildFeaturedSection({
    required String title,
    required VoidCallback onMore,
    required ModrinthSearchResult? result,
  }) {
    final hits = result?.hits ?? const <ModrinthProject>[];
    if (hits.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        HoverTextWithArrow(text: title, onTap: onMore),
        const SizedBox(height: 12),
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
            maxCrossAxisExtent: 420,
            childAspectRatio: 0.92,
            crossAxisSpacing: 12,
            mainAxisSpacing: 12,
          ),
          itemCount: hits.length,
          itemBuilder: (context, index) {
            return DiscoverBox(result: hits[index]);
          },
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final nav = getIt<NavigationState>();

    if (_isLoadingFeatured) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 24),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_featuredError != null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: tokens.colorRaisedBg,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            Icon(
              Icons.cloud_off_outlined,
              color: tokens.colorBase.withValues(alpha: 0.65),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '推荐内容暂时无法加载',
                style: TextStyle(
                  color: tokens.colorContrast,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: () {
                setState(() {
                  _isLoadingFeatured = true;
                  _featuredError = null;
                });
                _fetchFeatured();
              },
              child: const Text('重试'),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _buildFeaturedSection(
          title: '本周热门整合包',
          onMore: nav.browseModpacks,
          result: _modpackResult,
        ),
        const SizedBox(height: 18),
        _buildFeaturedSection(
          title: '本周热门模组',
          onMore: nav.browseMods,
          result: _modResult,
        ),
      ],
    );
  }
}
