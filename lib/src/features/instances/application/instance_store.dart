import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/progress_state.dart';
import 'package:aml/src/features/discover/data/discover_ids.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/java/application/java_download_service.dart';
import 'package:aml/src/features/settings/application/java_settings_state.dart';
import 'package:aml/src/features/settings/application/resource_settings_state.dart';
import 'package:aml/src/features/settings/domain/models/java_settings.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:aml/src/shared/widgets/app_messenger.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';

part 'instance_store_instance_ops.dart';
part 'instance_store_modpack_ops.dart';
part 'instance_store_world_ops.dart';

const _createdMarker = '__INSTANCE_CREATED__:';
const _skippedFilesMarker = '__SKIPPED_FILES__:';

class InstanceStore extends _InstanceStoreCore
    with
        _InstanceStoreInstanceOps,
        _InstanceStoreModpackOps,
        _InstanceStoreWorldOps {
  InstanceStore();
}

class _InstanceStoreCore {
  final instances = signal<List<rust.InstanceDto>>([]);
  final runningIds = signal<Set<String>>({});

  /// Live stdout/stderr lines per instance (event-driven, no polling).
  final liveLogs = signal<Map<String, List<String>>>({});

  /// Instance IDs currently installing (modpack / MC install). Library shows spinner.
  final installingIds = signal<Set<String>>({});

  /// Cross-page operation labels, e.g. installing or updating instance content.
  final instanceOperations = signal<Map<String, String>>({});
  final loading = signal(false);
  final error = signal<String?>(null);

  bool isInstalling(String id) =>
      installingIds.value.contains(id) ||
      instances.value.any(
        (i) => i.id == id && i.installStage == 'installing',
      );

  bool isInstallFailed(String id) => instances.value.any(
        (i) => i.id == id && i.installStage == 'failed',
      );

  String? operationFor(String id) => instanceOperations.value[id];

  void beginInstanceOperation(String id, String label) {
    instanceOperations.value = {...instanceOperations.value, id: label};
  }

  void endInstanceOperation(String id) {
    if (!instanceOperations.value.containsKey(id)) return;
    instanceOperations.value = {...instanceOperations.value}..remove(id);
  }

  void _markInstalling(String id) {
    installingIds.value = {...installingIds.value, id};
    beginInstanceOperation(id, '安装中…');
  }

  void _clearInstalling(String id) {
    if (installingIds.value.contains(id)) {
      installingIds.value = {...installingIds.value}..remove(id);
    }
    endInstanceOperation(id);
  }

  void _logInstallError(String label, Object error, [StackTrace? stack]) {
    debugPrint('[AML] $label failed: $error');
    if (stack != null) debugPrint(stack.toString());
  }

  String _installErrorDetail(Object error) => error.toString();

  Future<void> _onInstallProgress(
    double p,
    String msg,
    void Function(double, [String?]) setProgress, {
    void Function(int count)? onSkippedFiles,
  }) async {
    if (msg.startsWith(_createdMarker)) {
      final id = msg.substring(_createdMarker.length).trim();
      if (id.isNotEmpty) {
        _markInstalling(id);
        await refresh();
      }
      return;
    }
    if (msg.startsWith(_skippedFilesMarker)) {
      final n = int.tryParse(msg.substring(_skippedFilesMarker.length).trim());
      if (n != null && n > 0) {
        onSkippedFiles?.call(n);
      }
      return;
    }
    setProgress(p, msg);
  }

  static const _liveLogCap = 50000;

  Future<void> initialize() async {
    final resourceDir = getIt<ResourceSettingsState>().resourceDirectory.value;
    await rust.initLauncher(resourceDir: resourceDir);
    await refresh();
    await _listenProcessEvents();
    await _listenLiveLogEvents();
    await refreshRunning();
    await _hydrateLiveLogsForRunning();
  }

  Future<void> _hydrateLiveLogsForRunning() async {
    for (final id in runningIds.value) {
      await ensureLiveLogsLoaded(id);
    }
  }

  bool _listeningProcessEvents = false;
  bool _listeningLiveLogEvents = false;

  /// Process events → update [runningIds] without UI polling.
  Future<void> _listenProcessEvents() async {
    if (_listeningProcessEvents) return;
    _listeningProcessEvents = true;
    await rust.watchProcessEvents(
      onEvent: (ev) async {
        final id = ev.instanceId;
        if (ev.event == 'launched') {
          runningIds.value = {...runningIds.value, id};
        } else if (ev.event == 'finished') {
          if (!runningIds.value.contains(id)) return;
          runningIds.value = {...runningIds.value}..remove(id);
        }
      },
    );
  }

  /// Push live log lines from Rust stdout/stderr without Dart polling.
  Future<void> _listenLiveLogEvents() async {
    if (_listeningLiveLogEvents) return;
    _listeningLiveLogEvents = true;
    await rust.watchLiveLogEvents(
      onEvent: (ev) async {
        final id = ev.instanceId;
        if (ev.cleared) {
          liveLogs.value = {...liveLogs.value, id: []};
          return;
        }
        final current = List<String>.from(liveLogs.value[id] ?? const []);
        current.addAll(ev.line.split('\n'));
        if (current.length > _liveLogCap) {
          current.removeRange(0, current.length - _liveLogCap);
        }
        liveLogs.value = {...liveLogs.value, id: current};
      },
    );
  }

  List<String> liveLogsFor(String instanceId) =>
      liveLogs.value[instanceId] ?? const [];

  /// One-time sync when opening logs or after app start for running games.
  Future<void> ensureLiveLogsLoaded(String instanceId) async {
    if ((liveLogs.value[instanceId] ?? const []).isNotEmpty) return;
    try {
      final lines = await rust.getLiveLogs(instanceId: instanceId);
      if (lines.isEmpty) return;
      liveLogs.value = {...liveLogs.value, instanceId: lines};
    } catch (e) {
      debugPrint('getLiveLogs failed: $e');
    }
  }

  /// Force-sync live buffer from Rust (manual refresh).
  Future<void> refreshLiveLogs(String instanceId) async {
    try {
      final lines = await rust.getLiveLogs(instanceId: instanceId);
      liveLogs.value = {...liveLogs.value, instanceId: lines};
    } catch (e) {
      debugPrint('refreshLiveLogs failed: $e');
    }
  }

  Future<String> readLauncherLogFile(String instanceId) async {
    try {
      return await rust.getLauncherLog(instanceId: instanceId);
    } catch (e) {
      debugPrint('getLauncherLog failed: $e');
      return '';
    }
  }

  bool isRunning(String id) => runningIds.value.contains(id);

  /// Primary running instance id for status bar navigation.
  String? get primaryRunningId {
    final ids = runningIds.value;
    if (ids.isEmpty) return null;
    for (final i in instances.value) {
      if (ids.contains(i.id)) return i.id;
    }
    return ids.first;
  }

  /// Primary running instance name for status bar (first match).
  String? get primaryRunningName {
    final ids = runningIds.value;
    if (ids.isEmpty) return null;
    for (final i in instances.value) {
      if (ids.contains(i.id)) return i.name;
    }
    return '游戏';
  }

  Future<void> refresh() async {
    loading.value = true;
    error.value = null;
    try {
      instances.value = await rust.listInstances();
    } catch (e) {
      error.value = e.toString();
      debugPrint('listInstances failed: $e');
    } finally {
      loading.value = false;
    }
  }

  Future<void> refreshRunning() async {
    try {
      final procs = await rust.listRunningProcesses();
      runningIds.value = procs.map((p) => p.instanceId).toSet();
    } catch (e) {
      debugPrint('listRunningProcesses failed: $e');
    }
  }

  Future<List<rust.GameVersionDto>> listMinecraftVersions() {
    return rust.listMinecraftVersions();
  }

  Future<List<rust.LoaderVersionDto>> listLoaderVersions({
    required String loader,
    required String gameVersion,
  }) {
    return rust.listLoaderVersions(loader: loader, gameVersion: gameVersion);
  }

  /// Resolve a configured Java path for [requiredMajor] without auto-install.
  /// Used by settings UI to show the effective default JRE.
  Future<String?> peekJavaForMajor(int requiredMajor) async {
    final javaSettings = getIt<JavaSettingsState>();
    final download = getIt<JavaDownloadService>();

    Future<String?> tryPath(String path) async {
      final canonical = JavaSettings.canonicalizeExecutablePath(path);
      if (canonical.isEmpty) return null;
      final info = await download.checkJRE(canonical);
      if (info == null) return null;
      if (info.majorVersion >= requiredMajor) return canonical;
      return null;
    }

    final configured = await tryPath(javaSettings.pathForMajor(requiredMajor));
    if (configured != null) return configured;

    for (final candidateMajor in [25, 21, 17, 8]) {
      if (candidateMajor < requiredMajor) continue;
      final path = await tryPath(javaSettings.pathForMajor(candidateMajor));
      if (path != null) return path;
    }
    return null;
  }

  /// Resolve a Java executable suitable for [requiredMajor]
  /// (from version metadata `javaVersion.majorVersion`).
  Future<String> ensureJavaForMajor(int requiredMajor) async {
    final javaSettings = getIt<JavaSettingsState>();
    final download = getIt<JavaDownloadService>();
    final slot = JavaSettings.settingsSlotForMajor(requiredMajor);

    Future<String?> tryPath(String path) async {
      final canonical = JavaSettings.canonicalizeExecutablePath(path);
      if (canonical.isEmpty) return null;
      final info = await download.checkJRE(canonical);
      if (info == null) return null;
      if (info.majorVersion >= requiredMajor) return canonical;
      return null;
    }

    final configured = await tryPath(javaSettings.pathForMajor(requiredMajor));
    if (configured != null) return configured;

    // Prefer higher slots that still satisfy the requirement.
    for (final candidateMajor in [25, 21, 17, 8]) {
      if (candidateMajor < requiredMajor) continue;
      final path = await tryPath(javaSettings.pathForMajor(candidateMajor));
      if (path != null) return path;
    }

    debugPrint('Auto-installing Java $slot for required major $requiredMajor');
    final installed = await download.autoInstallJava(slot);
    if (installed == null || installed.isEmpty) {
      throw Exception(
        '此版本需要 Java $requiredMajor，自动安装失败。请到设置中安装 Java $slot。',
      );
    }
    final canonical = JavaSettings.canonicalizeExecutablePath(installed);
    javaSettings.setPathForMajor(slot, canonical);
    final verified = await tryPath(canonical);
    if (verified == null) {
      throw Exception('已安装 Java $slot，但版本校验失败（路径: $canonical）');
    }
    return verified;
  }
}
