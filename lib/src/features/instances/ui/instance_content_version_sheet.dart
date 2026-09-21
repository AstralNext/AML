import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';

Future<ModrinthVersionInfo?> pickInstanceContentVersion({
  required BuildContext context,
  required rust.ModFileDto mod,
  required rust.InstanceDto instance,
}) async {
  final projectId = mod.projectId;
  if (projectId == null || projectId.isEmpty) return null;
  final isCf = isCurseForgeProjectId(projectId);
  final cfModId = parseCurseForgeModId(projectId);

  showDialog<void>(
    context: context,
    barrierDismissible: false,
    builder: (_) => const Center(child: CircularProgressIndicator()),
  );
  List<ModrinthVersionInfo> versions;
  try {
    if (isCf && cfModId != null) {
      versions = await CurseForgeApiService.getProjectVersionsAsModrinth(
        cfModId,
        gameVersion: instance.gameVersion,
        loader: instance.loader.toLowerCase() == 'vanilla'
            ? null
            : instance.loader,
      );
    } else {
      versions = await ModrinthApiService.getProjectVersions(
        projectId,
        gameVersion: instance.gameVersion,
        loader: instance.loader.toLowerCase() == 'vanilla'
            ? null
            : instance.loader,
      );
    }
  } catch (e) {
    if (context.mounted) Navigator.of(context, rootNavigator: true).pop();
    if (context.mounted) showAppSnackBar('加载版本失败: $e', isError: true);
    return null;
  }
  if (!context.mounted) return null;
  Navigator.of(context, rootNavigator: true).pop();

  if (versions.isEmpty) {
    showAppSnackBar('没有兼容的版本', isError: true);
    return null;
  }

  return showModalBottomSheet<ModrinthVersionInfo>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.tokens.colorRaisedBg,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (ctx) {
      final tokens = ctx.tokens;
      final source = sourceLabel(contentSourceOf(projectId: projectId));
      return SafeArea(
        child: SizedBox(
          height: MediaQuery.of(ctx).size.height * 0.6,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  '切换版本 · $source · ${mod.projectTitle ?? mod.name}',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: tokens.colorContrast,
                  ),
                ),
              ),
              Expanded(
                child: ListView.separated(
                  itemCount: versions.length,
                  separatorBuilder: (_, __) => Divider(
                    height: 1,
                    color: tokens.colorSecondary.withValues(alpha: 0.25),
                  ),
                  itemBuilder: (context, index) {
                    final v = versions[index];
                    final current = v.id == mod.versionId;
                    return ListTile(
                      selected: current,
                      title: Text(
                        v.versionNumber.isNotEmpty ? v.versionNumber : v.name,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: tokens.colorContrast,
                        ),
                      ),
                      subtitle: Text(
                        '${v.versionType} · ${v.loaders.join(", ")}'
                        '${current ? " · 当前" : ""}',
                        style: TextStyle(
                          color: tokens.colorBase.withValues(alpha: 0.7),
                        ),
                      ),
                      trailing: current
                          ? Icon(Icons.check, color: tokens.colorBrand)
                          : null,
                      onTap: current ? null : () => Navigator.pop(ctx, v),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      );
    },
  );
}
