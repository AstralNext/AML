import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/browse_filters.dart';
import 'package:aml/src/shared/theme/app_theme_tokens.dart';
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

/// 从实例「浏览内容」进入项目详情时，点击「安装到实例」弹出的版本选择框。
/// 列表按发布时间降序（调用方保证），默认选中最新版本（或当前已装版本）。
class ContentVersionPicker extends StatefulWidget {
  const ContentVersionPicker({
    super.key,
    required this.versions,
    required this.projectTitle,
    this.currentVersionId,
  });

  final List<ModrinthVersionInfo> versions;
  final String projectTitle;
  final String? currentVersionId;

  static Future<ModrinthVersionInfo?> show(
    BuildContext context, {
    required List<ModrinthVersionInfo> versions,
    required String projectTitle,
    String? currentVersionId,
  }) {
    return showDialog<ModrinthVersionInfo>(
      context: context,
      builder: (_) => ContentVersionPicker(
        versions: versions,
        projectTitle: projectTitle,
        currentVersionId: currentVersionId,
      ),
    );
  }

  @override
  State<ContentVersionPicker> createState() => _ContentVersionPickerState();
}

class _ContentVersionPickerState extends State<ContentVersionPicker> {
  late ModrinthVersionInfo? _selected;
  String _query = '';

  @override
  void initState() {
    super.initState();
    ModrinthVersionInfo? current;
    final currentId = widget.currentVersionId;
    if (currentId != null && currentId.isNotEmpty) {
      for (final v in widget.versions) {
        if (v.id == currentId) {
          current = v;
          break;
        }
      }
    }
    // 已安装 → 默认当前版本；未安装 → 最新正式版，其次 Beta / Alpha。
    _selected = current ?? pickPreferredVersion(widget.versions);
  }

  Color _channelColor(String type) {
    return switch (type.toLowerCase()) {
      'beta' => const Color(0xFFE67E22),
      'alpha' => const Color(0xFFE74C3C),
      _ => const Color(0xFF2ECC71),
    };
  }

  String _channelLabel(String type) {
    return switch (type.toLowerCase()) {
      'beta' => 'Beta',
      'alpha' => 'Alpha',
      _ => '正式版',
    };
  }

  String _shortDate(String iso) {
    final dt = DateTime.tryParse(iso)?.toLocal();
    if (dt == null) return iso;
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    final q = _query.trim().toLowerCase();
    final filtered = q.isEmpty
        ? widget.versions
        : widget.versions.where((v) {
            return v.versionNumber.toLowerCase().contains(q) ||
                v.name.toLowerCase().contains(q) ||
                v.gameVersions.any((g) => g.toLowerCase().contains(q)) ||
                v.loaders.any((l) => l.toLowerCase().contains(q));
          }).toList();

    return Dialog(
      backgroundColor: tokens.colorRaisedBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: MediaQuery.sizeOf(context).height * 0.78,
        ),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 20, 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  Icon(Icons.download_outlined, color: tokens.colorBrand),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          '选择版本安装',
                          style: TextStyle(
                            fontSize: 17,
                            fontWeight: FontWeight.w800,
                            color: tokens.colorContrast,
                          ),
                        ),
                        Text(
                          widget.projectTitle,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 12,
                            color: tokens.colorBase.withValues(alpha: 0.65),
                          ),
                        ),
                      ],
                    ),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    icon: const Icon(Icons.close, size: 20),
                    color: tokens.colorBase,
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                onChanged: (v) => setState(() => _query = v),
                style: TextStyle(color: tokens.colorContrast),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: '搜索版本…',
                  hintStyle: TextStyle(
                    color: tokens.colorBase.withValues(alpha: 0.55),
                  ),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 18,
                    color: tokens.colorBase.withValues(alpha: 0.7),
                  ),
                  filled: true,
                  fillColor: tokens.colorSuperRaisedBg.withValues(alpha: 0.5),
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
              const SizedBox(height: 10),
              Flexible(
                child: filtered.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(20),
                          child: Text(
                            '没有匹配的版本',
                            style: TextStyle(color: tokens.colorBase),
                          ),
                        ),
                      )
                    : ListView.separated(
                        shrinkWrap: true,
                        itemCount: filtered.length,
                        separatorBuilder: (_, __) => Divider(
                          height: 1,
                          color: tokens.colorSecondary.withValues(alpha: 0.18),
                        ),
                        itemBuilder: (context, index) {
                          final v = filtered[index];
                          final isLatest = v.id == widget.versions.first.id;
                          final isRecommended =
                              v.id == pickPreferredVersion(widget.versions)?.id;
                          final isCurrent = v.id == widget.currentVersionId;
                          final gameLabel = v.gameVersions.isEmpty
                              ? null
                              : v.gameVersions.first;
                          final loaderLabel = v.loaders.isEmpty
                              ? null
                              : displayLoader(v.loaders.first);
                          return InkWell(
                            borderRadius: BorderRadius.circular(10),
                            onTap: () => setState(() => _selected = v),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 8,
                                vertical: 10,
                              ),
                              child: Row(
                                children: [
                                  Container(
                                    width: 9,
                                    height: 9,
                                    decoration: BoxDecoration(
                                      color: _channelColor(v.versionType),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  _selectionDot(
                                    tokens,
                                    _selected?.id == v.id,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          children: [
                                            Flexible(
                                              child: Text(
                                                v.versionNumber.isNotEmpty
                                                    ? v.versionNumber
                                                    : v.name,
                                                maxLines: 1,
                                                overflow: TextOverflow.ellipsis,
                                                style: TextStyle(
                                                  fontWeight: FontWeight.w700,
                                                  color: tokens.colorContrast,
                                                ),
                                              ),
                                            ),
                                            if (isLatest) ...[
                                              const SizedBox(width: 6),
                                              _badge(
                                                tokens,
                                                '最新',
                                                tokens.colorBrand,
                                              ),
                                            ],
                                            if (isRecommended && !isLatest) ...[
                                              const SizedBox(width: 6),
                                              _badge(
                                                tokens,
                                                '推荐',
                                                tokens.colorBrand,
                                              ),
                                            ],
                                            if (isCurrent) ...[
                                              const SizedBox(width: 6),
                                              _badge(
                                                tokens,
                                                '当前',
                                                tokens.colorBase
                                                    .withValues(alpha: 0.7),
                                              ),
                                            ],
                                          ],
                                        ),
                                        const SizedBox(height: 2),
                                        Text(
                                          [
                                            _channelLabel(v.versionType),
                                            if (gameLabel != null) gameLabel,
                                            if (loaderLabel != null)
                                              loaderLabel,
                                            if (v.datePublished.isNotEmpty)
                                              _shortDate(v.datePublished),
                                          ].join(' · '),
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 12,
                                            color: tokens.colorBase
                                                .withValues(alpha: 0.65),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
              const SizedBox(height: 14),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.pop(context),
                    child: Text(
                      '取消',
                      style: TextStyle(color: tokens.colorBase),
                    ),
                  ),
                  const SizedBox(width: 8),
                  FilledButton.icon(
                    onPressed: _selected == null
                        ? null
                        : () => Navigator.pop(context, _selected),
                    icon: const Icon(Icons.download_outlined, size: 18),
                    label: Text(
                      _selected?.id == widget.currentVersionId
                          ? '重新安装此版本'
                          : '安装此版本',
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: tokens.colorBrand,
                      foregroundColor: tokens.colorOnBrand,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _selectionDot(AppThemeTokens tokens, bool selected) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 120),
      width: 18,
      height: 18,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: selected ? tokens.colorBrand : Colors.transparent,
        border: Border.all(
          color: selected
              ? tokens.colorBrand
              : tokens.colorBase.withValues(alpha: 0.4),
          width: 2,
        ),
      ),
      child: selected
          ? Icon(Icons.check, size: 12, color: tokens.colorOnBrand)
          : null,
    );
  }

  Widget _badge(AppThemeTokens tokens, String text, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}
