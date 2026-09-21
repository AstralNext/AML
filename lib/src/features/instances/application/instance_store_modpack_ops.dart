part of 'instance_store.dart';

mixin _InstanceStoreModpackOps on _InstanceStoreCore {
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
}
