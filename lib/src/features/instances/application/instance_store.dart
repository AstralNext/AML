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

class InstanceStore {
  InstanceStore();

  static const _createdMarker = '__INSTANCE_CREATED__:';
  static const _skippedFilesMarker = '__SKIPPED_FILES__:';

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

  Future<rust.InstanceDto> create({
    required String name,
    required String gameVersion,
    required String loader,
    String? loaderVersion,
    String? icon,
  }) async {
    final created = await rust.createInstance(
      name: name,
      gameVersion: gameVersion,
      loader: loader,
      loaderVersion: loaderVersion,
      icon: icon,
    );
    await refresh();
    return created;
  }

  Future<void> remove(String id) async {
    await rust.removeInstance(id: id);
    _clearInstalling(id);
    await refresh();
  }

  Future<void> editIcon(String id, {String? path}) async {
    await rust.editInstanceIcon(id: id, iconPath: path);
    await refresh();
  }

  Future<rust.InstanceDto> duplicate(String id, {int retryAttempt = 0}) async {
    rust.InstanceDto? source;
    for (final item in instances.value) {
      if (item.id == id) {
        source = item;
        break;
      }
    }
    final progress = getIt<ProgressStore>().createProgressItem(
      source == null ? '复制实例' : '复制「${source.name}」',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    beginInstanceOperation(id, '复制中…');
    progress.setProgress(0.05, '正在复制实例文件…');
    var keepProgress = false;
    try {
      final created = await rust.duplicateInstance(id: id);
      progress.setProgress(1.0, '复制完成');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await refresh();
      showAppSnackBar('已创建副本「${created.name}」');
      return created;
    } catch (e, st) {
      _logInstallError('复制实例', e, st);
      progress.markFailed('复制失败: $e');
      progress.onRetry = () => duplicate(id, retryAttempt: retryAttempt + 1);
      keepProgress = true;
      showAppSnackBar('复制实例失败: $e', isError: true);
      rethrow;
    } finally {
      endInstanceOperation(id);
      if (!keepProgress) progress.dispose();
    }
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

  Future<rust.InstanceDto> updateSettings({
    required String id,
    String? name,
    String? javaPath,
    bool clearJavaPath = false,
    int? memoryMb,
    bool clearMemoryMb = false,
    String? extraJvmArgs,
    bool clearExtraJvmArgs = false,
    int? windowWidth,
    int? windowHeight,
    bool? fullscreen,
    bool clearWindowSettings = false,
    String? environmentVars,
    bool clearEnvironmentVars = false,
    String? preLaunchCommand,
    String? wrapperCommand,
    String? postExitCommand,
    bool clearHooks = false,
    String? updateChannel,
  }) async {
    final updated = await rust.updateInstance(
      id: id,
      name: name,
      javaPath: javaPath,
      clearJavaPath: clearJavaPath,
      memoryMb: memoryMb,
      clearMemoryMb: clearMemoryMb,
      extraJvmArgs: extraJvmArgs,
      clearExtraJvmArgs: clearExtraJvmArgs,
      windowWidth: windowWidth,
      windowHeight: windowHeight,
      fullscreen: fullscreen,
      clearWindowSettings: clearWindowSettings,
      environmentVars: environmentVars,
      clearEnvironmentVars: clearEnvironmentVars,
      preLaunchCommand: preLaunchCommand,
      wrapperCommand: wrapperCommand,
      postExitCommand: postExitCommand,
      clearHooks: clearHooks,
      updateChannel: updateChannel,
    );
    await refresh();
    return updated;
  }

  Future<rust.InstanceDto> setGroups(String id, List<String> groups) async {
    final updated = await rust.setInstanceGroups(id: id, groups: groups);
    await refresh();
    return updated;
  }

  Future<rust.InstanceDto> setAutoBackupWorlds(String id, bool enabled) async {
    final updated = await rust.setInstanceAutoBackupWorlds(
      id: id,
      enabled: enabled,
    );
    await refresh();
    return updated;
  }

  Future<rust.WorldBackupDto> backupWorld(
    String instanceId,
    String folder, {
    String kind = 'full',
    String compression = 'balanced',
  }) {
    return rust.backupInstanceWorld(
      instanceId: instanceId,
      folder: folder,
      kind: kind,
      compression: compression,
    );
  }

  Future<List<rust.WorldBackupDto>> listWorldBackups(
    String instanceId,
    String folder,
  ) {
    return rust.listWorldBackups(instanceId: instanceId, folder: folder);
  }

  Future<void> restoreWorldBackup(String instanceId, String backupPath) {
    return rust.restoreWorldBackup(
      instanceId: instanceId,
      backupPath: backupPath,
    );
  }

  Future<void> deleteWorldBackup(String instanceId, String backupPath) {
    return rust.deleteWorldBackup(
      instanceId: instanceId,
      backupPath: backupPath,
    );
  }

  Future<List<String>> listAllGroups() => rust.listAllInstanceGroups();

  Future<rust.InstanceDto> unlinkModpack(String id) async {
    final updated = await rust.unlinkModpack(id: id);
    await refresh();
    return updated;
  }

  Future<rust.InstanceDto> reinstallModpack(
    String id, {
    String? versionId,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '重装整合包',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    beginInstanceOperation(id, '重装整合包中…');
    var keepProgress = false;
    var skippedFiles = 0;
    try {
      rust.InstanceDto? current;
      for (final i in instances.value) {
        if (i.id == id) {
          current = i;
          break;
        }
      }
      current ??= await rust.getInstance(id: id);
      final source = current.modpackSource?.toLowerCase();
      if (source == 'curseforge') {
        final rawProject = current.modpackProjectId ?? '';
        final modId =
            parseCurseForgeModId(rawProject) ?? int.tryParse(rawProject);
        final fileId = int.tryParse(
          versionId ?? current.modpackVersionId ?? '',
        );
        if (modId == null || fileId == null) {
          throw StateError('CurseForge 整合包缺少项目/版本信息，无法重装');
        }
        endInstanceOperation(id);
        progress.dispose();
        return await createFromCurseforgeModpack(
          modId: modId,
          fileId: fileId,
          name: current.modpackTitle ?? current.name,
          resumeInstanceId: id,
          retryAttempt: retryAttempt,
        );
      }

      final requiredMajor = await rust.getRequiredJavaVersion(id: id);
      final java = await ensureJavaForMajor(requiredMajor);
      final updated = await rust.reinstallModpack(
        id: id,
        versionId: versionId,
        javaPath: java,
        onProgress: (p, msg) async {
          await _onInstallProgress(
            p,
            msg,
            progress.setProgress,
            onSkippedFiles: (n) => skippedFiles = n,
          );
        },
      );
      progress.setProgress(1.0, '重装完成');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      await refresh();
      showAppSnackBar(
        skippedFiles > 0
            ? '整合包重装完成（已跳过 $skippedFiles 个丢失文件）'
            : '整合包重装完成',
      );
      return updated;
    } catch (e, st) {
      _logInstallError('重装整合包', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('重装失败: $detail');
      progress.onRetry = () => reinstallModpack(
            id,
            versionId: versionId,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      showAppSnackBar('重装失败: $detail', isError: true);
      rethrow;
    } finally {
      endInstanceOperation(id);
      if (!keepProgress) progress.dispose();
    }
  }

  Future<rust.LaunchDefaultsDto> getLaunchDefaults() =>
      rust.getLaunchDefaults();

  Future<rust.LaunchDefaultsDto> setLaunchDefaults({
    required int memoryMb,
    String? extraJvmArgs,
    required int windowWidth,
    required int windowHeight,
    required bool fullscreen,
    String? environmentVars,
    String? preLaunchCommand,
    String? wrapperCommand,
    String? postExitCommand,
    String? gameLanguage,
  }) {
    return rust.setLaunchDefaults(
      memoryMb: memoryMb,
      extraJvmArgs: extraJvmArgs,
      windowWidth: windowWidth,
      windowHeight: windowHeight,
      fullscreen: fullscreen,
      environmentVars: environmentVars,
      preLaunchCommand: preLaunchCommand,
      wrapperCommand: wrapperCommand,
      postExitCommand: postExitCommand,
      gameLanguage: gameLanguage,
    );
  }

  Future<String> instanceFolderPath(String id) {
    return rust.openInstanceFolder(instanceId: id);
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

  Future<void> install(String id, {bool force = false, int retryAttempt = 0}) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装实例',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    _markInstalling(id);
    var keepProgress = false;
    try {
      final requiredMajor = await rust.getRequiredJavaVersion(id: id);
      final java = await ensureJavaForMajor(requiredMajor);
      await rust.installInstance(
        id: id,
        javaPath: java,
        force: force,
        onProgress: (p, msg) async {
          progress.setProgress(p, msg);
        },
      );
      progress.setProgress(1.0, '安装成功');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      showAppSnackBar('实例安装成功');
    } catch (e, st) {
      _logInstallError('实例安装', e, st);
      final detail = _installErrorDetail(e);
      error.value = detail;
      progress.markFailed('安装失败: $detail');
      progress.onRetry = () => install(
            id,
            force: force,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      showAppSnackBar('实例安装失败: $detail', isError: true);
      rethrow;
    } finally {
      _clearInstalling(id);
      if (!keepProgress) progress.dispose();
    }
  }

  Future<void> launch(
    String id, {
    String? quickPlaySingleplayer,
    String? quickPlayMultiplayer,
  }) async {
    final accounts = await rust.listAccounts();
    if (accounts.isEmpty) {
      throw Exception('请先添加账号后再启动游戏');
    }
    await getIt<AccountStore>().refresh();
    if (getIt<AccountStore>().activeAccount == null) {
      await getIt<AccountStore>().setActive(accounts.first.id);
    }

    final instance = instances.value.firstWhere((i) => i.id == id);
    if (instance.installStage == 'failed') {
      throw Exception('实例安装失败，请先重新安装');
    }
    if (instance.installStage != 'installed') {
      await install(id);
    }

    final requiredMajor = await rust.getRequiredJavaVersion(id: id);
    debugPrint('Instance $id requires Java $requiredMajor');

    final refreshed = await rust.getInstance(id: id);
    String java;
    if (refreshed.javaPath != null && refreshed.javaPath!.trim().isNotEmpty) {
      final override =
          JavaSettings.canonicalizeExecutablePath(refreshed.javaPath!);
      final info = await getIt<JavaDownloadService>().checkJRE(override);
      if (info == null || info.majorVersion < requiredMajor) {
        java = await ensureJavaForMajor(requiredMajor);
      } else {
        java = override;
      }
    } else {
      java = await ensureJavaForMajor(requiredMajor);
    }

    final memoryMb = refreshed.memoryMb != null && refreshed.memoryMb! > 0
        ? refreshed.memoryMb!.toInt()
        : null;

    debugPrint(
      'Launching $id with java=$java'
      '${memoryMb != null ? ' memory=${memoryMb}MB' : ''} '
      '(required=$requiredMajor; memory from DB/defaults)',
    );
    final world = quickPlaySingleplayer?.trim();
    final server = quickPlayMultiplayer?.trim();
    try {
      await rust.launchInstance(
        id: id,
        javaPath: java,
        quickPlaySingleplayer:
            (world == null || world.isEmpty) ? null : world,
        quickPlayMultiplayer:
            (server == null || server.isEmpty) ? null : server,
      );
      // Optimistic; `launched` event also updates runningIds.
      runningIds.value = {...runningIds.value, id};
    } catch (e, st) {
      debugPrint('launchInstance failed: $e\n$st');
      error.value = e.toString();
      rethrow;
    }
    await refresh();
  }

  Future<void> kill(String id) async {
    await rust.killInstance(id: id);
    // Optimistic UI update; `finished` also clears when the OS exit is observed.
    if (runningIds.value.contains(id)) {
      runningIds.value = {...runningIds.value}..remove(id);
    }
  }

  Future<String> installModrinthVersion({
    required String instanceId,
    required String versionId,
    String? projectType,
    bool installDeps = true,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装内容',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    var keepProgress = false;
    try {
      final path = await rust.installModrinthVersion(
        instanceId: instanceId,
        versionId: versionId,
        projectType: projectType,
        installDeps: installDeps,
        onProgress: (p, msg) async {
          progress.setProgress(p, msg);
        },
      );
      progress.setProgress(1.0, '安装成功');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      showAppSnackBar('内容安装成功');
      return path;
    } catch (e, st) {
      _logInstallError('内容安装', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('安装失败: $detail');
      progress.onRetry = () => installModrinthVersion(
            instanceId: instanceId,
            versionId: versionId,
            projectType: projectType,
            installDeps: installDeps,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      showAppSnackBar('内容安装失败: $detail', isError: true);
      rethrow;
    } finally {
      if (!keepProgress) progress.dispose();
    }
  }

  Future<String> installCurseforgeFile({
    required String instanceId,
    required int modId,
    required int fileId,
    String? projectType,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装内容',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    var keepProgress = false;
    try {
      final path = await rust.installCurseforgeFile(
        instanceId: instanceId,
        modId: BigInt.from(modId),
        fileId: BigInt.from(fileId),
        projectType: projectType,
        onProgress: (p, msg) async {
          progress.setProgress(p, msg);
        },
      );
      progress.setProgress(1.0, '安装成功');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      showAppSnackBar('内容安装成功');
      return path;
    } catch (e, st) {
      _logInstallError('CurseForge 内容安装', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('安装失败: $detail');
      progress.onRetry = () => installCurseforgeFile(
            instanceId: instanceId,
            modId: modId,
            fileId: fileId,
            projectType: projectType,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      showAppSnackBar('内容安装失败: $detail', isError: true);
      rethrow;
    } finally {
      if (!keepProgress) progress.dispose();
    }
  }

  Future<void> removeMod({
    required String instanceId,
    required String relativePath,
  }) async {
    await rust.removeInstanceMod(
      instanceId: instanceId,
      relativePath: relativePath,
    );
  }

  Future<void> installMrpack({
    required String instanceId,
    required String mrpackPath,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装整合包',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    _markInstalling(instanceId);
    var keepProgress = false;
    var skippedFiles = 0;
    try {
      final java = await ensureJavaForMajor(21);
      await rust.installMrpack(
        instanceId: instanceId,
        mrpackPath: mrpackPath,
        javaPath: java,
        onProgress: (p, msg) async {
          await _onInstallProgress(
            p,
            msg,
            progress.setProgress,
            onSkippedFiles: (n) => skippedFiles = n,
          );
        },
      );
      progress.setProgress(1.0, '整合包安装成功');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      showAppSnackBar(
        skippedFiles > 0
            ? '整合包安装成功（已跳过 $skippedFiles 个丢失文件）'
            : '整合包安装成功',
      );
    } catch (e, st) {
      _logInstallError('整合包安装', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('安装失败: $detail');
      progress.onRetry = () => installMrpack(
            instanceId: instanceId,
            mrpackPath: mrpackPath,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      showAppSnackBar('整合包安装失败: $detail', isError: true);
      rethrow;
    } finally {
      _clearInstalling(instanceId);
      if (!keepProgress) progress.dispose();
    }
  }

  /// Create a new instance from a Modrinth modpack version (`.mrpack`).
  /// Pass [resumeInstanceId] after a half-failed install to continue on the
  /// same instance (already-downloaded pack files are skipped).
  Future<rust.InstanceDto> createFromModrinthModpack({
    required String versionId,
    String? name,
    String? resumeInstanceId,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装整合包',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    String? createdId = resumeInstanceId;
    var keepProgress = false;
    var skippedFiles = 0;
    try {
      final java = await ensureJavaForMajor(21);
      final created = await rust.createInstanceFromModrinthModpack(
        versionId: versionId,
        name: name,
        javaPath: java,
        resumeInstanceId: resumeInstanceId,
        onProgress: (p, msg) async {
          await _onInstallProgress(
            p,
            msg,
            progress.setProgress,
            onSkippedFiles: (n) => skippedFiles = n,
          );
          if (msg.startsWith(_createdMarker)) {
            createdId = msg.substring(_createdMarker.length).trim();
          }
        },
      );
      createdId = created.id;
      progress.setProgress(1.0, '整合包安装成功');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      showAppSnackBar(
        skippedFiles > 0
            ? '整合包「${created.name}」安装成功（已跳过 $skippedFiles 个丢失文件）'
            : '整合包「${created.name}」安装成功',
      );
      return created;
    } catch (e, st) {
      _logInstallError('整合包创建安装', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('安装失败: $detail');
      final resumeId = createdId;
      progress.onRetry = () => createFromModrinthModpack(
            versionId: versionId,
            name: name,
            resumeInstanceId: resumeId,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      await refresh();
      showAppSnackBar('整合包安装失败: $detail', isError: true);
      rethrow;
    } finally {
      if (createdId != null) _clearInstalling(createdId!);
      if (!keepProgress) progress.dispose();
    }
  }

  Future<rust.InstanceDto> createFromCurseforgeModpack({
    required int modId,
    required int fileId,
    String? name,
    String? resumeInstanceId,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '安装整合包',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    String? createdId = resumeInstanceId;
    var keepProgress = false;
    var skippedFiles = 0;
    try {
      final java = await ensureJavaForMajor(21);
      final created = await rust.createInstanceFromCurseforgeModpack(
        modId: BigInt.from(modId),
        fileId: BigInt.from(fileId),
        name: name,
        javaPath: java,
        resumeInstanceId: resumeInstanceId,
        onProgress: (p, msg) async {
          await _onInstallProgress(
            p,
            msg,
            progress.setProgress,
            onSkippedFiles: (n) => skippedFiles = n,
          );
          if (msg.startsWith(_createdMarker)) {
            createdId = msg.substring(_createdMarker.length).trim();
          }
        },
      );
      createdId = created.id;
      progress.setProgress(1.0, '整合包安装成功');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      showAppSnackBar(
        skippedFiles > 0
            ? '整合包「${created.name}」安装成功（已跳过 $skippedFiles 个丢失文件）'
            : '整合包「${created.name}」安装成功',
      );
      return created;
    } catch (e, st) {
      _logInstallError('CurseForge 整合包安装', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('安装失败: $detail');
      final resumeId = createdId;
      progress.onRetry = () => createFromCurseforgeModpack(
            modId: modId,
            fileId: fileId,
            name: name,
            resumeInstanceId: resumeId,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      await refresh();
      showAppSnackBar('整合包安装失败: $detail', isError: true);
      rethrow;
    } finally {
      if (createdId != null) _clearInstalling(createdId!);
      if (!keepProgress) progress.dispose();
    }
  }

  /// Import local pack archive (.mrpack / CurseForge / MCBBS / MultiMC zip).
  Future<rust.InstanceDto> createFromPackFile({
    required String path,
    String? name,
    String? resumeInstanceId,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '导入整合包',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    String? createdId = resumeInstanceId;
    var keepProgress = false;
    var skippedFiles = 0;
    try {
      final java = await ensureJavaForMajor(21);
      final created = await rust.createInstanceFromPackFile(
        path: path,
        name: name,
        javaPath: java,
        resumeInstanceId: resumeInstanceId,
        onProgress: (p, msg) async {
          await _onInstallProgress(
            p,
            msg,
            progress.setProgress,
            onSkippedFiles: (n) => skippedFiles = n,
          );
          if (msg.startsWith(_createdMarker)) {
            createdId = msg.substring(_createdMarker.length).trim();
          }
        },
      );
      createdId = created.id;
      progress.setProgress(1.0, '整合包导入成功');
      await Future<void>.delayed(const Duration(milliseconds: 500));
      await refresh();
      showAppSnackBar(
        skippedFiles > 0
            ? '整合包「${created.name}」导入成功（已跳过 $skippedFiles 个丢失文件）'
            : '整合包「${created.name}」导入成功',
      );
      return created;
    } catch (e, st) {
      _logInstallError('整合包导入', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('导入失败: $detail');
      final resumeId = createdId;
      progress.onRetry = () => createFromPackFile(
            path: path,
            name: name,
            resumeInstanceId: resumeId,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      await refresh();
      showAppSnackBar('整合包导入失败: $detail', isError: true);
      rethrow;
    } finally {
      if (createdId != null) _clearInstalling(createdId!);
      if (!keepProgress) progress.dispose();
    }
  }

  /// Export instance pack. [format]: `mrpack` | `multimc` | `mcbbs`.
  Future<void> exportPack({
    required String instanceId,
    required String exportPath,
    required String format,
    String? packName,
    String? versionId,
    String? description,
    List<String>? includeIds,
    List<String>? includePaths,
    int retryAttempt = 0,
  }) async {
    final progress = getIt<ProgressStore>().createProgressItem(
      '导出整合包',
      retryAttempt: retryAttempt,
    );
    getIt<ProgressStore>().progressVisibility.value = true;
    var keepProgress = false;
    try {
      await rust.exportInstancePack(
        instanceId: instanceId,
        exportPath: exportPath,
        format: format,
        packName: packName,
        versionId: versionId,
        description: description,
        includeIds: includeIds,
        includePaths: includePaths,
        onProgress: (p, msg) async {
          progress.setProgress(p, msg);
        },
      );
      progress.setProgress(1.0, '导出完成');
      await Future<void>.delayed(const Duration(milliseconds: 400));
      showAppSnackBar('已导出整合包');
    } catch (e, st) {
      _logInstallError('整合包导出', e, st);
      final detail = _installErrorDetail(e);
      progress.markFailed('导出失败: $detail');
      progress.onRetry = () => exportPack(
            instanceId: instanceId,
            exportPath: exportPath,
            format: format,
            packName: packName,
            versionId: versionId,
            description: description,
            includeIds: includeIds,
            includePaths: includePaths,
            retryAttempt: retryAttempt + 1,
          );
      keepProgress = true;
      showAppSnackBar('导出失败: $detail', isError: true);
      rethrow;
    } finally {
      if (!keepProgress) progress.dispose();
    }
  }
}
