enum ContentInstallModalAction {
  installToExisting,
  createAndInstall,
}

class ContentInstallModalResult {
  const ContentInstallModalResult.installToExisting({
    required this.instanceId,
    this.installDespiteIncompatibility = false,
  })  : action = ContentInstallModalAction.installToExisting,
        newInstance = null;

  const ContentInstallModalResult.createAndInstall({
    required this.newInstance,
  })  : action = ContentInstallModalAction.createAndInstall,
        instanceId = null,
        installDespiteIncompatibility = false;

  final ContentInstallModalAction action;
  final String? instanceId;
  final bool installDespiteIncompatibility;
  final ContentInstallNewInstance? newInstance;
}

class ContentInstallNewInstance {
  const ContentInstallNewInstance({
    required this.name,
    required this.loader,
    required this.gameVersion,
    this.icon,
  });

  final String name;
  final String loader;
  final String gameVersion;
  final String? icon;
}

class ContentInstallInstanceRow {
  const ContentInstallInstanceRow({
    required this.id,
    required this.name,
    this.iconPath,
    required this.compatible,
    required this.installed,
  });

  final String id;
  final String name;
  final String? iconPath;
  final bool compatible;
  final bool installed;
}

enum ContentInstallTab { existing, newInstance }
