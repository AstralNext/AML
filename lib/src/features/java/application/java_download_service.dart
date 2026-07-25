import 'package:aml/src/app/state/progress_state.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/features/java/data/rust_java_download.dart';

class JavaDownloadService {
  JavaDownloadService({
    required RustJavaDownloadDataSource dataSource,
    required RuntimeState runtimeState,
    required ProgressStore progressStore,
  }) : _dataSource = dataSource,
       _runtimeState = runtimeState,
       _progressStore = progressStore;

  final RustJavaDownloadDataSource _dataSource;
  final RuntimeState _runtimeState;
  final ProgressStore _progressStore;

  /// 自动安装 Java（使用 Rust 实现），成功时返回安装路径。
  Future<String?> autoInstallJava(
    int javaVersion, {
    Function(double progress, String message)? onProgress,
    Function(bool success, String? result)? onComplete,
  }) async {
    final progressItem = _progressStore.createProgressItem(
      'Java $javaVersion 安装',
    );

    try {
      final appDataDir = _runtimeState.appDataDirectory.value ?? "";

      if (appDataDir.isEmpty) {
        progressItem.dispose();
        throw Exception('应用数据目录未设置');
      }

      final result = await _dataSource.autoInstallJava(
        javaVersion: javaVersion,
        appDataDir: appDataDir,
        onProgress: (double progress, String message) async {
          progressItem.setProgress(progress, message);
          onProgress?.call(progress, message);
        },
        onComplete: (bool success, String? result) async {
          progressItem.dispose();
          onComplete?.call(success, result);
        },
      );

      return result;
    } catch (e) {
      progressItem.dispose();
      onComplete?.call(false, null);
      return null;
    }
  }

  Future<JavaRuntimeVersion?> checkJRE(String javaPath) async {
    try {
      final result = await _dataSource.checkJre(javaPath: javaPath);
      if (result != null) {
        return JavaRuntimeVersion(
          version: result.version,
          path: result.path,
          majorVersion: result.majorVersion,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> testJRE(String javaPath, int expectedMajorVersion) async {
    try {
      return await _dataSource.testJre(
        javaPath: javaPath,
        expectedMajorVersion: expectedMajorVersion,
      );
    } catch (e) {
      return false;
    }
  }

  Future<JavaRuntimeVersion?> checkJavaInstallation() async {
    try {
      final result = await _dataSource.checkJavaInstallation();
      if (result != null) {
        return JavaRuntimeVersion(
          version: result.version,
          path: result.path,
          majorVersion: result.majorVersion,
        );
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<int> getMaxMemory() async {
    try {
      return await _dataSource.getMaxMemory();
    } catch (e) {
      return 8 * 1024 * 1024; // 默认返回 8GB
    }
  }

  Future<int> extractJavaVersion(String version) async {
    try {
      return await _dataSource.extractJavaVersion(version: version);
    } catch (e) {
      throw FormatException('无法解析 Java 版本: $version');
    }
  }

  Future<List<JavaRuntimeVersion>> findFilteredJres(
    int javaVersion, {
    String? appDataDir,
  }) async {
    try {
      final results = await _dataSource.findFilteredJres(
        javaVersion: javaVersion,
        appDataDir: appDataDir,
      );
      return results
          .map(
            (result) => JavaRuntimeVersion(
              version: result.version,
              path: result.path,
              majorVersion: result.majorVersion,
            ),
          )
          .toList();
    } catch (e) {
      return [];
    }
  }
}

class JavaRuntimeVersion {
  final String version;
  final String path;
  final int majorVersion;

  JavaRuntimeVersion({
    required this.version,
    required this.path,
    required this.majorVersion,
  });

  Map<String, dynamic> toJson() => {
        'version': version,
        'path': path,
        'majorVersion': majorVersion,
      };

  factory JavaRuntimeVersion.fromJson(Map<String, dynamic> json) =>
      JavaRuntimeVersion(
        version: json['version'],
        path: json['path'],
        majorVersion: json['majorVersion'],
      );
}
