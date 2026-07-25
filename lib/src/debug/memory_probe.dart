import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/discover/data/mcdb_client.dart';
import 'package:aml/src/features/wardrobe/application/skin_store.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:vm_service/vm_service.dart';
import 'package:vm_service/vm_service_io.dart';

/// Profile / debug 下通过 VM Service 抓取 Dart 堆分配，定位大对象来源。
///
/// 运行：`flutter run -d windows --profile --dart-define=AML_MEMORY_PROBE=1`
class MemoryProbe {
  MemoryProbe._();

  static bool get _enabled {
    const flag = String.fromEnvironment('AML_MEMORY_PROBE');
    return flag == 'true' || flag == '1';
  }

  static Future<void> runIfEnabled() async {
    if (!_enabled) return;
    if (!(kProfileMode || kDebugMode)) {
      debugPrint('[MemoryProbe] 需要 --profile 或 --debug 模式');
      return;
    }

    debugPrint('[MemoryProbe] 开始分阶段采样…');
    await _sample('01_after_bootstrap', resetProfile: true);
    await Future<void>.delayed(const Duration(seconds: 3));
    await _sample('02_idle_3s');
    await Future<void>.delayed(const Duration(seconds: 5));
    await _sample('03_idle_8s_total');
    await _sample('04_mcdb_search', action: _runMcdbSearch);
    await _sample('05_mcdb_lookup', action: _runMcdbLookup);
    debugPrint('[MemoryProbe] 完成。Native/Rust ≈ RSS − Dart heap − external');
  }

  static Future<void> _runMcdbSearch() async {
    final hits = await McdbClient.search('机械动力', limit: 10);
    debugPrint('[MemoryProbe] online search hits=${hits.length}');
  }

  static Future<void> _runMcdbLookup() async {
    final rows = await McdbClient.lookupByIds({
      'LNytGWDc',
      'AANobbMI',
      'Vebnzrzj',
      'ohrV1SdS',
      'HZEeSf2H',
    });
    debugPrint('[MemoryProbe] online lookup rows=${rows.length}');
  }

  static Future<void> _sample(
    String label, {
    bool resetProfile = false,
    Future<void> Function()? action,
  }) async {
    if (action != null) await action();
    await Future<void>.delayed(const Duration(milliseconds: 400));

    final rssMb = _rssMb();
    final imageCache = PaintingBinding.instance.imageCache;
    final skinStats = getIt<SkinStore>().pngCacheStats();
    final avatarStats = getIt<AccountAvatarCache>().memoryStats();

    debugPrint('');
    debugPrint('========== MemoryProbe: $label ==========');
    debugPrint(
      '进程 RSS ≈ ${rssMb?.toStringAsFixed(1) ?? "?"} MB | '
      'ImageCache ${imageCache.currentSize}/${imageCache.maximumSize} '
      '(${imageCache.currentSizeBytes ~/ 1024} KB)',
    );
    debugPrint(
      'SkinStore PNG 缓存: ${skinStats.$1} 个 / ${skinStats.$2 ~/ 1024} KB',
    );
    debugPrint(
      'AccountAvatar 内存: ${avatarStats.$1} 个 / ${avatarStats.$2 ~/ 1024} KB',
    );
    await _logMcdbCache();

    await _dumpDartHeap(label, resetProfile: resetProfile);
  }

  static Future<void> _logMcdbCache() async {
    debugPrint('MCDB 在线模式：无本地索引');
  }

  static double? _rssMb() {
    try {
      return ProcessInfo.currentRss / (1024 * 1024);
    } catch (_) {
      return null;
    }
  }

  static Future<void> _dumpDartHeap(
    String label, {
    required bool resetProfile,
  }) async {
    VmService? service;
    try {
      final info = await developer.Service.getInfo();
      final serverUri = info.serverUri;
      if (serverUri == null) {
        debugPrint('[MemoryProbe] VM Service URI 不可用');
        return;
      }

      final wsUri = serverUri.replace(scheme: 'ws').toString();
      service = await vmServiceConnectUri(wsUri);
      final vm = await service.getVM();
      final isolates = vm.isolates ?? const [];
      if (isolates.isEmpty) {
        debugPrint('[MemoryProbe] 无可用 isolate');
        return;
      }
      final isolateId = isolates.first.id!;
      final usage = await service.getMemoryUsage(isolateId);
      final profile = await service.getAllocationProfile(
        isolateId,
        reset: resetProfile,
      );

      final heap = usage.heapUsage ?? 0;
      final external = usage.externalUsage ?? 0;
      final capacity = usage.heapCapacity ?? 0;
      debugPrint(
        'Dart VM: heap ${heap ~/ 1024} KB / cap ${capacity ~/ 1024} KB '
        '| external ${external ~/ 1024} KB',
      );

      final members = profile.members ?? [];
      final sorted = [...members]
        ..sort(
          (a, b) => (b.bytesCurrent ?? 0).compareTo(a.bytesCurrent ?? 0),
        );

      debugPrint('--- Top Dart 分配 (class ← 当前 bytes) ---');
      var shown = 0;
      for (final m in sorted) {
        final bytes = m.bytesCurrent ?? 0;
        if (bytes < 8192) continue;
        final className = m.classRef?.name ?? '(unknown)';
        debugPrint(
          '  $className: ${bytes ~/ 1024} KB '
          '(instances ${m.instancesCurrent})',
        );
        shown++;
        if (shown >= 25) break;
      }
      if (shown == 0) {
        debugPrint('  (无 >8KB 的当前分配项)');
      }
    } catch (e, st) {
      debugPrint('[MemoryProbe] VM heap dump failed ($label): $e\n$st');
    } finally {
      await service?.dispose();
    }
  }
}
