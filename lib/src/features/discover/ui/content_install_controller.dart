import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/discover/data/curseforge_api.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/discover/data/modrinth_api.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;

import 'content_install_models.dart';

class ContentInstallData {
  const ContentInstallData({
    required this.instances,
    required this.compatibleLoaders,
    required this.gameVersions,
    required this.totalInstanceCount,
    required this.initialTab,
  });

  final List<ContentInstallInstanceRow> instances;
  final List<String> compatibleLoaders;
  final List<String> gameVersions;
  final int totalInstanceCount;
  final ContentInstallTab initialTab;
}

class ContentInstallController {
  ContentInstallController({
    required this.projectId,
    required this.projectType,
  });

  final String projectId;
  final String projectType;

  static const _supportedLoaders = {
    'vanilla',
    'forge',
    'fabric',
    'quilt',
    'neoforge',
  };
  static const _vanillaCompatibleLoaders = {'minecraft', 'datapack'};
  static const _loaderOrder = ['vanilla', 'fabric', 'quilt', 'neoforge', 'forge'];

  String? loaderForProjectType(String? projectType, String instanceLoader) {
    switch (projectType) {
      case 'datapack':
        return 'datapack';
      case 'resourcepack':
        return 'minecraft';
      case 'shader':
        return 'iris';
      case 'mod':
      case 'modpack':
        if (instanceLoader.isEmpty || instanceLoader == 'vanilla') {
          return null;
        }
        return instanceLoader;
      default:
        return instanceLoader == 'vanilla' ? null : instanceLoader;
    }
  }

  List<String> _sortLoaders(Iterable<String> loaders) {
    return loaders.toList()
      ..sort((a, b) {
        final aIdx = _loaderOrder.indexOf(a);
        final bIdx = _loaderOrder.indexOf(b);
        if (aIdx == -1 && bIdx == -1) return a.compareTo(b);
        if (aIdx == -1) return 1;
        if (bIdx == -1) return -1;
        return aIdx.compareTo(bIdx);
      });
  }

  int _compareGameVersions(String a, String b) {
    final ap = a.split('.').map(int.tryParse).toList();
    final bp = b.split('.').map(int.tryParse).toList();
    for (var i = 0; i < ap.length || i < bp.length; i++) {
      final av = i < ap.length ? (ap[i] ?? 0) : 0;
      final bv = i < bp.length ? (bp[i] ?? 0) : 0;
      if (av != bv) return av.compareTo(bv);
    }
    return 0;
  }

  Future<ContentInstallData> loadData() async {
    final store = getIt<InstanceStore>();
    final rawInstances = store.instances.value;
    final isCf = isCurseForgeProjectId(projectId);
    final cfModId = parseCurseForgeModId(projectId);

    List<ModrinthVersionInfo> versions = const [];
    try {
      if (isCf && cfModId != null) {
        versions =
            await CurseForgeApiService.getProjectVersionsAsModrinth(cfModId);
      } else {
        versions = await ModrinthApiService.getProjectVersions(projectId);
      }
    } catch (_) {}

    final loaderSet = <String>{};
    final gameVersionSet = <String>{};
    for (final version in versions) {
      for (final loader in version.loaders) {
        if (_supportedLoaders.contains(loader)) {
          loaderSet.add(loader);
        } else if (_vanillaCompatibleLoaders.contains(loader)) {
          loaderSet.add('vanilla');
        }
      }
      gameVersionSet.addAll(version.gameVersions);
    }

    final rows = <ContentInstallInstanceRow>[];
    await Future.wait(
      rawInstances.map((instance) async {
        final loader = loaderForProjectType(projectType, instance.loader);
        String? compatibleId;
        if (isCf && cfModId != null) {
          compatibleId = await CurseForgeApiService.getCompatibleFileId(
            modId: cfModId,
            gameVersion: instance.gameVersion,
            loader: loader,
          );
        } else {
          compatibleId = await ModrinthApiService.getCompatibleVersionId(
            projectId: projectId,
            gameVersion: instance.gameVersion,
            loader: loader,
          );
        }
        var installed = false;
        try {
          final mods = await rust.listInstanceMods(instanceId: instance.id);
          installed = mods.any((m) => m.projectId == projectId);
        } catch (_) {}
        rows.add(
          ContentInstallInstanceRow(
            id: instance.id,
            name: instance.name,
            iconPath: instance.icon,
            compatible: compatibleId != null,
            installed: installed,
          ),
        );
      }),
    );

    final compatibleLoaders = _sortLoaders(loaderSet);
    final gameVersions = gameVersionSet.toList()
      ..sort((a, b) => _compareGameVersions(b, a));

    final defaultTab = rows.any((r) => r.compatible && !r.installed)
        ? ContentInstallTab.existing
        : compatibleLoaders.isNotEmpty
            ? ContentInstallTab.newInstance
            : ContentInstallTab.existing;

    return ContentInstallData(
      instances: rows,
      compatibleLoaders: compatibleLoaders,
      gameVersions: gameVersions,
      totalInstanceCount: rawInstances.length,
      initialTab: compatibleLoaders.isEmpty
          ? ContentInstallTab.existing
          : defaultTab,
    );
  }
}
