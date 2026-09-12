/// Shared Minecraft loader / content-type display labels.
String loaderLabel(String loader) {
  switch (loader.toLowerCase()) {
    case 'fabric':
      return 'Fabric';
    case 'forge':
      return 'Forge';
    case 'quilt':
      return 'Quilt';
    case 'neoforge':
      return 'NeoForge';
    case 'vanilla':
      return 'Vanilla';
    default:
      return loader;
  }
}

String contentTypeLabel(String type) {
  switch (type) {
    case 'mod':
      return '模组';
    case 'resourcepack':
      return '资源包';
    case 'shader':
      return '着色器';
    case 'datapack':
      return '数据包';
    case 'modpack':
      return '整合包';
    default:
      return type;
  }
}

/// Human-readable game mode for a singleplayer world.
String worldGameModeLabel({
  required String gameMode,
  bool hardcore = false,
  bool emptyIfNotSingleplayer = false,
  String? kind,
}) {
  if (emptyIfNotSingleplayer && kind != null && kind != 'singleplayer') {
    return '';
  }
  if (hardcore) return '极限模式';
  switch (gameMode) {
    case 'creative':
      return '创造模式';
    case 'adventure':
      return '冒险模式';
    case 'spectator':
      return '旁观模式';
    default:
      return '生存模式';
  }
}

/// Human-readable instance install stage.
String installStageLabel(String stage) {
  switch (stage) {
    case 'installed':
      return '已安装';
    case 'installing':
      return '安装中';
    case 'failed':
      return '安装失败';
    default:
      return '未安装';
  }
}

