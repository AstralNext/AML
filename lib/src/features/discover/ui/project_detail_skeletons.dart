import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/common/skeleton.dart';
import 'package:flutter/material.dart';

/// 项目详情页「介绍」正文区域的骨架占位。
class ProjectDetailBodySkeleton extends StatelessWidget {
  const ProjectDetailBodySkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (var i = 0; i < 6; i++) ...[
            if (i > 0) const SizedBox(height: 10),
            SkeletonBox(
              tokens: tokens,
              width: i == 5 ? 180 : double.infinity,
              height: 14,
            ),
          ],
          const SizedBox(height: 20),
          SkeletonBox(
            tokens: tokens,
            width: double.infinity,
            height: 160,
            borderRadius: BorderRadius.circular(12),
          ),
        ],
      ),
    );
  }
}

/// 项目详情页整页骨架：头部 + 标签栏 + 正文。
class ProjectDetailSkeleton extends StatelessWidget {
  const ProjectDetailSkeleton({super.key, required this.onBack});

  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                CustomButton(
                  icon: Icons.arrow_back,
                  size: ButtonSize.medium,
                  onTap: onBack,
                ),
                const SizedBox(width: 14),
                SkeletonBox(
                  tokens: tokens,
                  width: 84,
                  height: 84,
                  borderRadius: BorderRadius.circular(14),
                ),
                const SizedBox(width: 16),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SkeletonBox(tokens: tokens, width: 220, height: 28),
                      const SizedBox(height: 10),
                      SkeletonBox(
                        tokens: tokens,
                        width: double.infinity,
                        height: 14,
                      ),
                      const SizedBox(height: 6),
                      SkeletonBox(tokens: tokens, width: 280, height: 14),
                      const SizedBox(height: 12),
                      Row(
                        children: [
                          SkeletonBox(tokens: tokens, width: 72, height: 16),
                          const SizedBox(width: 16),
                          SkeletonBox(tokens: tokens, width: 56, height: 16),
                          const SizedBox(width: 16),
                          SkeletonBox(tokens: tokens, width: 64, height: 16),
                        ],
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                SkeletonBox(
                  tokens: tokens,
                  width: 96,
                  height: 44,
                  borderRadius: BorderRadius.circular(12),
                ),
              ],
            ),
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                SkeletonBox(
                  tokens: tokens,
                  width: 72,
                  height: 34,
                  borderRadius: BorderRadius.circular(20),
                ),
                const SizedBox(width: 8),
                SkeletonBox(
                  tokens: tokens,
                  width: 72,
                  height: 34,
                  borderRadius: BorderRadius.circular(20),
                ),
              ],
            ),
          ),
        ),
        const SliverToBoxAdapter(child: SizedBox(height: 16)),
        const SliverToBoxAdapter(child: ProjectDetailBodySkeleton()),
        const SliverFillRemaining(
          hasScrollBody: false,
          child: SizedBox.shrink(),
        ),
      ],
    );
  }
}
