import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/application/content_install_helper.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/components/buttons/custom_button.dart';
import 'package:aml/src/shared/widgets/components/cached_remote_image.dart';
import 'package:aml/src/shared/widgets/components/cards/app_card.dart';
import 'package:aml/src/shared/widgets/components/common/image_lightbox.dart';
import 'package:aml/src/shared/widgets/components/common/skeleton.dart';
import 'package:flutter/material.dart';

class AuthorDetailPage extends StatefulWidget {
  const AuthorDetailPage({
    super.key,
    required this.authorId,
    required this.authorType,
    this.preview,
  });

  final String authorId;
  final String authorType;
  final AuthorPreview? preview;

  @override
  State<AuthorDetailPage> createState() => _AuthorDetailPageState();
}

class _AuthorDetailPageState extends State<AuthorDetailPage> {
  bool _loading = true;
  String? _error;
  ModrinthAuthor? _author;
  List<ModrinthAuthorProject> _projects = [];
  final Set<String> _installingIds = {};

  NavigationState get _nav => getIt<NavigationState>();

  AuthorPreview? get _preview {
    if (widget.preview != null) return widget.preview;
    final a = _author;
    if (a == null) return null;
    return AuthorPreview(
      id: a.id,
      type: a.type,
      displayName: a.displayName,
      avatarUrl: a.avatarUrl,
    );
  }

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(covariant AuthorDetailPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.authorId != widget.authorId ||
        oldWidget.authorType != widget.authorType) {
      setState(() {
        _author = null;
        _projects = [];
        _error = null;
        _loading = true;
      });
      _load();
    }
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final results = await Future.wait([
        ModrinthApiService.getAuthor(
          id: widget.authorId,
          type: widget.authorType,
        ),
        ModrinthApiService.getAuthorProjects(
          id: widget.authorId,
          type: widget.authorType,
        ),
      ]);
      if (!mounted) return;
      final author = results[0] as ModrinthAuthor;
      final projects = results[1] as List<ModrinthAuthorProject>;
      projects.sort((a, b) => b.downloads.compareTo(a.downloads));
      setState(() {
        _author = author;
        _projects = projects;
        _loading = false;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  Future<void> _install(ModrinthAuthorProject project) async {
    if (_installingIds.contains(project.id)) return;
    setState(() => _installingIds.add(project.id));
    try {
      await ContentInstallHelper.installProject(
        context: context,
        projectId: project.id,
        title: project.title,
        projectType: project.projectType,
        projectIconUrl: project.iconUrl,
        preferredInstanceId: _nav.browseInstallInstanceId.value ??
            _nav.selectedInstanceId.value,
      );
    } finally {
      if (mounted) {
        setState(() => _installingIds.remove(project.id));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final preview = _preview;
    final author = _author;
    final errColor = Theme.of(context).colorScheme.error;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _buildHeader(
          displayName: author?.displayName ?? preview?.displayName ?? '作者',
          bio: author?.bio ?? '',
          avatarUrl: author?.avatarUrl ?? preview?.avatarUrl,
          type: author?.type ?? widget.authorType,
          projectCount: _loading ? null : _projects.length,
          username: author?.username,
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    _error!,
                    style: TextStyle(color: errColor),
                  ),
                ),
                TextButton(onPressed: _load, child: const Text('重试')),
              ],
            ),
          ),
        Expanded(
          child: _loading && _projects.isEmpty
              ? ListView.separated(
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  itemCount: 6,
                  separatorBuilder: (_, __) => const SizedBox(height: 10),
                  itemBuilder: (_, __) => SkeletonBox(
                    tokens: tokens,
                    height: 96,
                    borderRadius: const BorderRadius.all(Radius.circular(12)),
                  ),
                )
              : _projects.isEmpty
                  ? Center(
                      child: Text(
                        _loading ? '加载中…' : '暂无公开项目',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                      itemCount: _projects.length,
                      separatorBuilder: (_, __) => const SizedBox(height: 10),
                      itemBuilder: (context, index) {
                        final p = _projects[index];
                        final authorName =
                            author?.displayName ?? preview?.displayName ?? '';
                        return AppCard(
                          title: p.title,
                          description: p.description,
                          author: authorName,
                          downloads: p.downloads,
                          followers: p.followers,
                          iconUrl: p.iconUrl ?? '',
                          categories: p.categories,
                          dateCreated: p.published,
                          dateModified: p.updated,
                          installing: _installingIds.contains(p.id),
                          onTap: () => _nav.openProject(
                            p.id,
                            preview: p.toPreview(),
                          ),
                          onInstall: () => _install(p),
                        );
                      },
                    ),
        ),
      ],
    );
  }

  Widget _buildHeader({
    required String displayName,
    required String bio,
    required String? avatarUrl,
    required String type,
    required int? projectCount,
    String? username,
  }) {
    final tokens = context.tokens;
    final isOrg = type.toLowerCase() == 'organization';
    final typeLabel = isOrg ? '组织' : '作者';

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          CustomButton(
            icon: Icons.arrow_back,
            size: ButtonSize.medium,
            onTap: () => _nav.closeAuthor(),
          ),
          const SizedBox(width: 14),
          avatarUrl != null && avatarUrl.isNotEmpty
              ? MouseRegion(
                  cursor: SystemMouseCursors.click,
                  child: GestureDetector(
                    onTap: () => showImageLightbox(
                      context,
                      urls: [avatarUrl],
                    ),
                    child: CachedRemoteImage(
                      url: avatarUrl,
                      width: 84,
                      height: 84,
                      borderRadius: BorderRadius.circular(42),
                      placeholder: _avatarFallback(tokens, isOrg),
                      error: _avatarFallback(tokens, isOrg),
                    ),
                  ),
                )
              : _avatarFallback(tokens, isOrg),
          const SizedBox(width: 16),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 12,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    _chip(tokens, typeLabel),
                    if (username != null &&
                        username.isNotEmpty &&
                        username != displayName)
                      Text(
                        '@$username',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.75),
                        ),
                      ),
                    if (projectCount != null)
                      Text(
                        '$projectCount 个项目',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.75),
                        ),
                      ),
                  ],
                ),
                if (bio.trim().isNotEmpty) ...[
                  const SizedBox(height: 10),
                  Text(
                    bio,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      height: 1.35,
                      color: tokens.colorBase.withValues(alpha: 0.85),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _chip(tokens, String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: tokens.colorContrast,
        ),
      ),
    );
  }

  Widget _avatarFallback(tokens, bool isOrg) {
    return Container(
      width: 84,
      height: 84,
      decoration: BoxDecoration(
        color: tokens.colorSuperRaisedBg,
        borderRadius: BorderRadius.circular(42),
      ),
      child: Icon(
        isOrg ? Icons.groups_outlined : Icons.person_outline,
        color: tokens.colorContrast,
        size: 36,
      ),
    );
  }
}
