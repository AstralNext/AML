import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/discover/ui/content_install_modal.dart';
import 'package:aml/src/features/discover/ui/modpack_version_picker.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/material.dart';

/// Shared install flow:
/// - **modpack** → pick version → create a new instance from pack
/// - **mod / other** → pick instance → compatible version → install (+ deps on Modrinth)
class ContentInstallHelper {
  ContentInstallHelper._();

  static Future<void> installProject({
    required BuildContext context,
    required String projectId,
    required String title,
    String? projectType,
    String? preferredInstanceId,
    String? latestVersionHint,
    String? projectIconUrl,
    bool asUpdate = false,
    String? currentVersionId,
    String? versionId,
    List<ModrinthVersionInfo>? versions,
  }) async {
    if (projectType == 'modpack') {
      await _installModpack(
        context: context,
        projectId: projectId,
        title: title,
        projectIconUrl: projectIconUrl,
        versionId: versionId,
        versions: versions,
      );
      return;
    }

    await _installContentToInstance(
      context: context,
      projectId: projectId,
      title: title,
      projectType: projectType,
      preferredInstanceId: preferredInstanceId,
      latestVersionHint: latestVersionHint,
      projectIconUrl: projectIconUrl,
      asUpdate: asUpdate,
      currentVersionId: currentVersionId,
      versionId: versionId,
    );
  }

  /// Switch an existing linked modpack instance to another version (MR or CF).
  static Future<void> switchModpackVersion({
    required BuildContext context,
    required String instanceId,
    required String projectId,
    required String title,
    String? projectIconUrl,
    String? currentVersionId,
    String? modpackSource,
    List<ModrinthVersionInfo>? versions,
  }) async {
    final isCf = isCurseForgeProjectId(projectId) ||
        modpackSource?.toLowerCase() == 'curseforge';
    final pick = await ModpackVersionPicker.show(
      context,
      projectId: isCf && !isCurseForgeProjectId(projectId)
          ? curseForgeProjectId(int.tryParse(projectId) ?? 0)
          : projectId,
      projectTitle: title,
      projectIconUrl: projectIconUrl,
      currentVersionId: currentVersionId,
      versions: versions,
      switchMode: true,
    );
    if (pick == null) return;
    try {
      if (isCf) {
        final modId = parseCurseForgeModId(
              isCurseForgeProjectId(projectId)
                  ? projectId
                  : curseForgeProjectId(int.tryParse(projectId) ?? 0),
            ) ??
            int.tryParse(projectId);
        final fileId = int.tryParse(pick.version.id);
        if (modId == null || fileId == null) {
          _snack(context, '无效的 CurseForge 整合包版本', isError: true);
          return;
        }
        await getIt<InstanceStore>().createFromCurseforgeModpack(
          modId: modId,
          fileId: fileId,
          name: title,
          resumeInstanceId: instanceId,
        );
      } else {
        await getIt<InstanceStore>().reinstallModpack(
          instanceId,
          versionId: pick.version.id,
        );
      }
    } catch (_) {
      // InstanceStore already surfaces errors.
    }
  }

  /// Install modpack = pick version, then create new instance from pack version.
  static Future<void> _installModpack({
    required BuildContext context,
    required String projectId,
    required String title,
    String? projectIconUrl,
    String? versionId,
    List<ModrinthVersionInfo>? versions,
  }) async {
    final isCf = isCurseForgeProjectId(projectId);
    String? packVersionId = versionId;
    ModrinthVersionInfo? picked;

    if (packVersionId == null) {
      List<ModrinthVersionInfo>? pickerVersions = versions;
      if (isCf && (pickerVersions == null || pickerVersions.isEmpty)) {
        final modId = parseCurseForgeModId(projectId);
        if (modId == null) {
          _snack(context, '无效的 CurseForge 项目', isError: true);
          return;
        }
        try {
          pickerVersions =
              await CurseForgeApiService.getProjectVersionsAsModrinth(modId);
        } catch (_) {
          pickerVersions = null;
        }
      }
      final pick = await ModpackVersionPicker.show(
        context,
        projectId: projectId,
        projectTitle: title,
        projectIconUrl: projectIconUrl,
        versions: pickerVersions,
      );
      if (pick == null) return;
      picked = pick.version;
      packVersionId = pick.version.id;
    }

    if (!context.mounted) return;
    final versionLabel = picked?.versionNumber.isNotEmpty == true
        ? picked!.versionNumber
        : (picked?.name ?? packVersionId);
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('安装整合包'),
        content: Text('将创建新实例并安装「$title」\n版本：$versionLabel'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('创建并安装'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    try {
      final rust.InstanceDto created;
      if (isCf) {
        final modId = parseCurseForgeModId(projectId);
        final fileId = int.tryParse(packVersionId);
        if (modId == null || fileId == null) {
          if (context.mounted) {
            _snack(context, '无效的 CurseForge 整合包版本', isError: true);
          }
          return;
        }
        created = await getIt<InstanceStore>().createFromCurseforgeModpack(
          modId: modId,
          fileId: fileId,
          name: title,
        );
      } else {
        created = await getIt<InstanceStore>().createFromModrinthModpack(
          versionId: packVersionId,
          name: title,
        );
      }
      if (!context.mounted) return;
      getIt<NavigationState>().openInstance(
        created.id,
        returnToProject: true,
      );
    } catch (_) {
      // InstanceStore already shows success/failure toasts.
    }
  }

  static Future<void> _installContentToInstance({
    required BuildContext context,
    required String projectId,
    required String title,
    String? projectType,
    String? preferredInstanceId,
    String? latestVersionHint,
    String? projectIconUrl,
    bool asUpdate = false,
    String? currentVersionId,
    String? versionId,
  }) async {
    final store = getIt<InstanceStore>();
    final instances = store.instances.value;
    if (instances.isEmpty) {
      _snack(context, '请先创建一个实例', isError: true);
      return;
    }

    final isCf = isCurseForgeProjectId(projectId);
    final modId = parseCurseForgeModId(projectId);

    rust.InstanceDto? target;
    var forceIncompatible = false;

    if (preferredInstanceId != null) {
      for (final i in instances) {
        if (i.id == preferredInstanceId) {
          target = i;
          break;
        }
      }
    }

    if (target == null) {
      if (!context.mounted) return;
      final result = await ContentInstallModal.show(
        context,
        projectId: projectId,
        projectType: projectType ?? 'mod',
        projectTitle: title,
        projectIconUrl: projectIconUrl,
      );
      if (result == null) return;

      switch (result.action) {
        case ContentInstallModalAction.installToExisting:
          final id = result.instanceId;
          if (id == null) return;
          target = instances.firstWhere((i) => i.id == id);
          forceIncompatible = result.installDespiteIncompatibility;
        case ContentInstallModalAction.createAndInstall:
          final params = result.newInstance;
          if (params == null) return;
          try {
            final created = await store.create(
              name: params.name,
              gameVersion: params.gameVersion,
              loader: params.loader,
              icon: params.icon,
            );
            target = created;
          } catch (_) {
            return;
          }
      }
    }

    String? resolvedVersionId = versionId;
    if (resolvedVersionId == null) {
      if (isCf && modId != null) {
        resolvedVersionId = await CurseForgeApiService.getCompatibleFileId(
          modId: modId,
          gameVersion: target.gameVersion,
          loader: _loaderForProjectType(projectType, target.loader),
        );
      } else {
        resolvedVersionId = await ModrinthApiService.getCompatibleVersionId(
          projectId: projectId,
          gameVersion: target.gameVersion,
          loader: _loaderForProjectType(projectType, target.loader),
        );
      }
    }

    var installDeps = !isCf;
    if (resolvedVersionId == null || forceIncompatible) {
      if (!context.mounted) return;
      final anyway = await showDialog<bool>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('没有兼容版本'),
          content: Text(
            '没有匹配 ${target!.loader} ${target.gameVersion} 的版本。'
            '仍要安装最新版本吗？${isCf ? '' : '（不会自动安装依赖）'}',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('仍然安装'),
            ),
          ],
        ),
      );
      if (anyway != true) return;
      if (isCf && modId != null) {
        resolvedVersionId = latestVersionHint ??
            await CurseForgeApiService.getLatestFileId(modId);
      } else {
        resolvedVersionId = latestVersionHint ??
            await ModrinthApiService.getLatestVersionId(projectId);
      }
      installDeps = false;
      if (resolvedVersionId == null) {
        if (context.mounted) _snack(context, '找不到可安装版本', isError: true);
        return;
      }
    }

    if (currentVersionId != null && currentVersionId == resolvedVersionId) {
      if (context.mounted) {
        _snack(context, '$title 已安装（当前版本），已跳过');
      }
      return;
    }

    try {
      if (isCf && modId != null) {
        final fileId = int.tryParse(resolvedVersionId);
        if (fileId == null) {
          if (context.mounted) {
            _snack(context, '无效的 CurseForge 文件', isError: true);
          }
          return;
        }
        await store.installCurseforgeFile(
          instanceId: target.id,
          modId: modId,
          fileId: fileId,
          projectType: projectType,
        );
      } else {
        await store.installModrinthVersion(
          instanceId: target.id,
          versionId: resolvedVersionId,
          projectType: projectType,
          installDeps: installDeps,
        );
      }
      // InstanceStore shows install result toast.
    } catch (_) {
      // InstanceStore already shows failure toast.
    }
  }

  /// Target loader preferences by content type.
  static String? _loaderForProjectType(
    String? projectType,
    String instanceLoader,
  ) {
    switch (projectType) {
      case 'datapack':
        return 'datapack';
      case 'resourcepack':
        return 'minecraft';
      case 'shader':
        return 'iris';
      case 'mod':
        return instanceLoader == 'vanilla' ? null : instanceLoader;
      default:
        return instanceLoader == 'vanilla' ? null : instanceLoader;
    }
  }

  static void _snack(
    BuildContext context,
    String message, {
    bool isError = false,
  }) {
    showAppSnackBar(message, isError: isError);
  }
}
