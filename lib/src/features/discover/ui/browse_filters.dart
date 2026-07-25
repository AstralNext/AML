/// Browse filters (loaders / categories by project type).
library;

const modLoaders = ['fabric', 'forge', 'neoforge', 'quilt'];
const modpackLoaders = ['fabric', 'forge', 'neoforge', 'quilt'];
const shaderLoaders = ['iris', 'optifine', 'canvas', 'vanilla'];

const modCategories = [
  'adventure',
  'cursed',
  'decoration',
  'economy',
  'equipment',
  'food',
  'game-mechanics',
  'library',
  'magic',
  'management',
  'minigame',
  'mobs',
  'optimization',
  'social',
  'storage',
  'technology',
  'transportation',
  'utility',
  'worldgen',
];

const modpackCategories = [
  'adventure',
  'challenging',
  'combat',
  'kitchen-sink',
  'lightweight',
  'magic',
  'multiplayer',
  'optimization',
  'quests',
  'technology',
];

const resourcePackCategories = [
  'combat',
  'cursed',
  'decoration',
  'modded',
  'realistic',
  'simplistic',
  'themed',
  'tweaks',
  'utility',
  'vanilla-like',
];

const datapackCategories = [
  'adventure',
  'cursed',
  'decoration',
  'economy',
  'equipment',
  'food',
  'game-mechanics',
  'library',
  'magic',
  'management',
  'minigame',
  'mobs',
  'optimization',
  'social',
  'storage',
  'technology',
  'transportation',
  'utility',
  'worldgen',
];

const shaderCategories = [
  'cartoon',
  'cursed',
  'fantasy',
  'realistic',
  'semi-realistic',
  'vanilla-like',
];

List<String> loadersForProjectType(String projectType) {
  switch (projectType) {
    case 'mod':
      return modLoaders;
    case 'modpack':
      return modpackLoaders;
    case 'shader':
      return shaderLoaders;
    default:
      return const [];
  }
}

List<String> categoriesForProjectType(String projectType) {
  switch (projectType) {
    case 'mod':
      return modCategories;
    case 'modpack':
      return modpackCategories;
    case 'resourcepack':
      return resourcePackCategories;
    case 'datapack':
      return datapackCategories;
    case 'shader':
      return shaderCategories;
    default:
      return const [];
  }
}

/// Release-like Minecraft versions: `1.21.1`, `26.1.2`. Snapshots/pre/rc excluded.
bool isReleaseGameVersion(String version) {
  return RegExp(r'^\d+(\.\d+)+$').hasMatch(version);
}

/// Newest-first labels for outer cards (modpack supported MC versions).
///
/// Prefers release versions when any exist; appends `+N` when truncated.
List<String> summarizeGameVersions(
  List<String> versions, {
  int maxVisible = 3,
}) {
  if (versions.isEmpty) return const [];
  final release = versions.where(isReleaseGameVersion).toList();
  final source = release.isNotEmpty ? release : versions;
  // Modrinth usually lists oldest→newest; reverse for "latest first".
  final newestFirst = source.reversed.toList();
  final unique = <String>[];
  final seen = <String>{};
  for (final v in newestFirst) {
    final t = v.trim();
    if (t.isEmpty || !seen.add(t)) continue;
    unique.add(t);
  }
  if (unique.length <= maxVisible) return unique;
  return [
    ...unique.take(maxVisible),
    '+${unique.length - maxVisible}',
  ];
}

String displayLoader(String id) {
  switch (id) {
    case 'neoforge':
      return 'NeoForge';
    case 'fabric':
      return 'Fabric';
    case 'forge':
      return 'Forge';
    case 'quilt':
      return 'Quilt';
    case 'liteloader':
      return 'LiteLoader';
    case 'rift':
      return 'Rift';
    case 'iris':
      return 'Iris';
    case 'optifine':
      return 'OptiFine';
    case 'canvas':
      return 'Canvas';
    case 'vanilla':
      return 'Vanilla';
    default:
      return id;
  }
}

String displayCategory(String id) {
  const zh = {
    'adventure': '冒险',
    'cursed': '怪异',
    'decoration': '装饰',
    'economy': '经济',
    'equipment': '装备',
    'food': '食物',
    'game-mechanics': '游戏机制',
    'library': '支持库',
    'magic': '魔法',
    'management': '管理',
    'minigame': '小游戏',
    'mobs': '生物',
    'optimization': '优化',
    'social': '社交',
    'storage': '存储',
    'technology': '科技',
    'transportation': '交通',
    'utility': '实用',
    'worldgen': '世界生成',
    'combat': '战斗',
    'challenging': '挑战',
    'kitchen-sink': '大杂烩',
    'lightweight': '轻量',
    'multiplayer': '多人',
    'quests': '任务',
    'modded': '模组向',
    'realistic': '写实',
    'simplistic': '简约',
    'themed': '主题',
    'tweaks': '微调',
    'vanilla-like': '原版风',
    'cartoon': '卡通',
    'fantasy': '奇幻',
    'semi-realistic': '半写实',
  };
  return zh[id] ??
      id
          .split('-')
          .map((p) => p.isEmpty ? p : '${p[0].toUpperCase()}${p.substring(1)}')
          .join(' ');
}
