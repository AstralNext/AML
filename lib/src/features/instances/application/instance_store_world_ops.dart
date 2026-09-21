part of 'instance_store.dart';

mixin _InstanceStoreWorldOps on _InstanceStoreCore {
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
}
