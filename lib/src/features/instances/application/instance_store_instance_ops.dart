part of 'instance_store.dart';

mixin _InstanceStoreInstanceOps on _InstanceStoreCore {
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

  Future<List<String>> listAllGroups() => rust.listAllInstanceGroups();

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
