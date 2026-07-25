import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// One numeric stat entry from a Minecraft stats JSON file.
class StatEntry {
  const StatEntry({required this.key, required this.value});

  final String key;
  final int value;

  String get displayName => formatStatKey(key);
  String get displayValue => formatStatValue(key, value);
}

/// A group of stats under one category, e.g. `minecraft:mined`.
class StatCategory {
  const StatCategory({required this.id, required this.entries});

  final String id;
  final List<StatEntry> entries;

  String get label => categoryLabel(id);

  bool get isEmpty => entries.isEmpty;
}

/// Stats for a single world save.
class WorldPlayStats {
  const WorldPlayStats({required this.worldName, required this.categories});

  final String worldName;
  final List<StatCategory> categories;

  bool get isEmpty => categories.every((c) => c.isEmpty);

  int get entryCount =>
      categories.fold<int>(0, (sum, c) => sum + c.entries.length);
}

/// All player statistics loaded from an instance directory.
class InstancePlayStats {
  const InstancePlayStats({
    required this.worlds,
    required this.aggregated,
    required this.playerFiles,
  });

  final List<WorldPlayStats> worlds;
  final WorldPlayStats aggregated;
  final int playerFiles;

  static const empty = InstancePlayStats(
    worlds: [],
    aggregated: WorldPlayStats(worldName: '全部世界', categories: []),
    playerFiles: 0,
  );

  bool get isEmpty => worlds.isEmpty && aggregated.isEmpty;

  int get worldsWithStats => worlds.where((w) => !w.isEmpty).length;

  /// Load stats across all singleplayer worlds under [instanceRoot].
  static Future<InstancePlayStats> load(
    String instanceRoot, {
    String? preferUuid,
  }) async {
    final saves = Directory(p.join(instanceRoot, 'saves'));
    if (!await saves.exists()) return empty;

    final preferred = <_StatFile>[];
    final all = <_StatFile>[];
    final seen = <String>{};

    await for (final world in saves.list(followLinks: false)) {
      if (world is! Directory) continue;
      final worldName = p.basename(world.path);

      for (final statsDir in <Directory>[
        Directory(p.join(world.path, 'players', 'stats')),
        Directory(p.join(world.path, 'stats')),
      ]) {
        if (!await statsDir.exists()) continue;

        await for (final file in statsDir.list(followLinks: false)) {
          if (file is! File) continue;
          if (!file.path.toLowerCase().endsWith('.json')) continue;
          final stem = p.basenameWithoutExtension(file.path).toLowerCase();
          final key = '$worldName|$stem';
          if (seen.contains(key)) continue;
          seen.add(key);

          final entry = _StatFile(
            path: file.path,
            uuidStem: stem,
            worldName: worldName,
          );
          all.add(entry);
          if (preferUuid != null &&
              preferUuid.isNotEmpty &&
              _uuidEquals(stem, preferUuid)) {
            preferred.add(entry);
          }
        }
      }
    }

    final selected = preferred.isNotEmpty ? preferred : all;
    if (selected.isEmpty) return empty;

    final perWorld = <String, Map<String, Map<String, int>>>{};

    for (final entry in selected) {
      try {
        final raw = await File(entry.path).readAsString();
        final decoded = jsonDecode(raw);
        if (decoded is! Map) continue;
        final stats = decoded['stats'];
        if (stats is! Map) continue;

        final bucket = perWorld.putIfAbsent(entry.worldName, () => {});
        _mergeStatsMap(bucket, stats);
      } catch (_) {
        // Skip corrupt / unreadable stats files.
      }
    }

    final worlds = perWorld.entries
        .map(
          (e) => WorldPlayStats(
            worldName: e.key,
            categories: _buildCategories(e.value),
          ),
        )
        .where((w) => !w.isEmpty)
        .toList()
      ..sort((a, b) => a.worldName.compareTo(b.worldName));

    final merged = <String, Map<String, int>>{};
    for (final worldMap in perWorld.values) {
      _mergeCategoryMaps(merged, worldMap);
    }

    return InstancePlayStats(
      worlds: worlds,
      aggregated: WorldPlayStats(
        worldName: '全部世界',
        categories: _buildCategories(merged),
      ),
      playerFiles: selected.length,
    );
  }

  static void _mergeStatsMap(
    Map<String, Map<String, int>> target,
    Map statsRoot,
  ) {
    for (final categoryEntry in statsRoot.entries) {
      final categoryId = categoryEntry.key.toString();
      final categoryValue = categoryEntry.value;
      if (categoryValue is! Map) continue;

      final bucket = target.putIfAbsent(categoryId, () => {});
      for (final statEntry in categoryValue.entries) {
        final key = statEntry.key.toString();
        final value = _asInt(statEntry.value);
        if (value == 0) continue;
        bucket[key] = (bucket[key] ?? 0) + value;
      }
    }
  }

  static void _mergeCategoryMaps(
    Map<String, Map<String, int>> target,
    Map<String, Map<String, int>> source,
  ) {
    for (final category in source.entries) {
      final bucket = target.putIfAbsent(category.key, () => {});
      for (final stat in category.value.entries) {
        bucket[stat.key] = (bucket[stat.key] ?? 0) + stat.value;
      }
    }
  }

  static List<StatCategory> _buildCategories(Map<String, Map<String, int>> raw) {
    final categories = <StatCategory>[];
    final ids = raw.keys.toList()..sort(_compareCategoryId);

    for (final id in ids) {
      final stats = raw[id];
      if (stats == null || stats.isEmpty) continue;

      final entries = stats.entries
          .map((e) => StatEntry(key: e.key, value: e.value))
          .toList()
        ..sort((a, b) => b.value.compareTo(a.value));

      categories.add(StatCategory(id: id, entries: entries));
    }
    return categories;
  }

  static int _compareCategoryId(String a, String b) {
    const order = [
      'minecraft:custom',
      'minecraft:mined',
      'minecraft:used',
      'minecraft:crafted',
      'minecraft:picked_up',
      'minecraft:dropped',
      'minecraft:killed',
      'minecraft:killed_by',
      'minecraft:broken',
    ];
    final ai = order.indexOf(a);
    final bi = order.indexOf(b);
    if (ai != -1 || bi != -1) {
      return (ai == -1 ? 999 : ai).compareTo(bi == -1 ? 999 : bi);
    }
    return a.compareTo(b);
  }

  static int _asInt(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return 0;
  }

  static bool _uuidEquals(String a, String b) {
    final na = a.replaceAll('-', '').toLowerCase();
    final nb = b.replaceAll('-', '').toLowerCase();
    return na == nb;
  }
}

class _StatFile {
  const _StatFile({
    required this.path,
    required this.uuidStem,
    required this.worldName,
  });
  final String path;
  final String uuidStem;
  final String worldName;
}

String categoryLabel(String id) {
  return switch (id) {
    'minecraft:custom' => '通用',
    'minecraft:mined' => '挖掘方块',
    'minecraft:used' => '使用物品',
    'minecraft:crafted' => '合成物品',
    'minecraft:picked_up' => '拾取物品',
    'minecraft:dropped' => '丢弃物品',
    'minecraft:killed' => '击杀生物',
    'minecraft:killed_by' => '被谁击杀',
    'minecraft:broken' => '损坏工具',
    _ => id.contains(':') ? id.split(':').last : id,
  };
}

String formatStatKey(String key) {
  final known = _knownStatLabels[key];
  if (known != null) return known;

  var label = key;
  if (label.contains(':')) {
    label = label.split(':').last;
  }
  return label
      .replaceAll('_', ' ')
      .replaceAllMapped(RegExp(r'\b\w'), (m) => m.group(0)!.toUpperCase());
}

String formatStatValue(String key, int value) {
  if (value == 0) return '0';
  if (key.endsWith('_one_cm')) return formatDistanceBlocks(value);
  if (_isTickStat(key)) return formatPlayDuration(value);
  if (key.contains('damage')) return '$value';
  return formatCount(value);
}

bool _isTickStat(String key) {
  const tickKeys = {
    'minecraft:play_time',
    'minecraft:play_one_minute',
    'minecraft:total_world_time',
    'minecraft:sneak_time',
    'minecraft:time_since_rest',
    'minecraft:time_since_death',
  };
  if (tickKeys.contains(key)) return true;
  return key.endsWith('_time');
}

const _knownStatLabels = <String, String>{
  'minecraft:play_time': '游戏时长',
  'minecraft:play_one_minute': '游戏时长',
  'minecraft:total_world_time': '世界打开时长',
  'minecraft:walk_one_cm': '行走距离',
  'minecraft:sprint_one_cm': '冲刺距离',
  'minecraft:fly_one_cm': '飞行距离',
  'minecraft:swim_one_cm': '游泳距离',
  'minecraft:boat_one_cm': '乘船距离',
  'minecraft:horse_one_cm': '骑马距离',
  'minecraft:aviate_one_cm': '鞘翅飞行距离',
  'minecraft:climb_one_cm': '攀爬距离',
  'minecraft:fall_one_cm': '坠落距离',
  'minecraft:jump': '跳跃次数',
  'minecraft:deaths': '死亡次数',
  'minecraft:mob_kills': '击杀生物',
  'minecraft:player_kills': '击杀玩家',
  'minecraft:leave_game': '退出游戏次数',
  'minecraft:damage_dealt': '造成伤害',
  'minecraft:damage_taken': '受到伤害',
  'minecraft:damage_blocked_by_shield': '盾牌格挡伤害',
  'minecraft:damage_absorbed': '吸收伤害',
  'minecraft:damage_resisted': '抵抗伤害',
  'minecraft:open_chest': '打开箱子',
  'minecraft:open_barrel': '打开木桶',
  'minecraft:interact_with_crafting_table': '使用工作台',
  'minecraft:interact_with_furnace': '使用熔炉',
  'minecraft:sleep_in_bed': '睡觉次数',
  'minecraft:time_since_death': '距上次死亡',
  'minecraft:time_since_rest': '距上次休息',
  'minecraft:sneak_time': '潜行时长',
};

String formatPlayDuration(int ticks) {
  if (ticks <= 0) return '0 分钟';
  final totalSeconds = ticks ~/ 20;
  final hours = totalSeconds ~/ 3600;
  final minutes = (totalSeconds % 3600) ~/ 60;
  if (hours <= 0) return '$minutes 分钟';
  if (hours < 100) return '$hours 小时 $minutes 分钟';
  return '$hours 小时';
}

String formatDistanceBlocks(int cm) {
  if (cm <= 0) return '0 格';
  final blocks = cm / 100.0;
  if (blocks < 1000) {
    return blocks < 10
        ? '${blocks.toStringAsFixed(1)} 格'
        : '${blocks.round()} 格';
  }
  final km = blocks / 1000.0;
  return '${km.toStringAsFixed(km < 10 ? 2 : 1)} km';
}

String formatCount(int n) {
  if (n < 10000) return '$n';
  if (n < 1000000) {
    final k = n / 1000.0;
    return '${k.toStringAsFixed(k < 10 ? 1 : 0)}k';
  }
  final m = n / 1000000.0;
  return '${m.toStringAsFixed(m < 10 ? 1 : 0)}M';
}
