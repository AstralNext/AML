import 'package:aml/src/rust/api/java_download.dart' as rust_java;
import 'package:aml/src/rust/api/jre_scan.dart' as rust_jre;

class RustJavaDownloadDataSource {
  Future<String?> autoInstallJava({
    required int javaVersion,
    required String appDataDir,
    required Future<void> Function(double progress, String message) onProgress,
    required Future<void> Function(bool success, String? result) onComplete,
  }) {
    return rust_java.autoInstallJava(
      javaVersion: javaVersion,
      appDataDir: appDataDir,
      onProgress: (double progress, String message) async {
        await onProgress(progress, message);
      },
      onComplete: (bool success, String? result) async {
        await onComplete(success, result);
      },
    );
  }

  Future<rust_java.JavaRuntimeVersion?> checkJre({required String javaPath}) {
    return rust_java.checkJre(javaPath: javaPath);
  }

  Future<bool> testJre({
    required String javaPath,
    required int expectedMajorVersion,
  }) {
    return rust_java.testJre(
      javaPath: javaPath,
      expectedMajorVersion: expectedMajorVersion,
    );
  }

  Future<rust_java.JavaRuntimeVersion?> checkJavaInstallation() {
    return rust_java.checkJavaInstallation();
  }

  Future<int> getMaxMemory() async {
    final result = await rust_java.getMaxMemory();
    return result.toInt();
  }

  Future<int> extractJavaVersion({required String version}) {
    return rust_java.extractJavaVersion(version: version);
  }

  Future<List<rust_java.JavaRuntimeVersion>> findFilteredJres({
    required int javaVersion,
    String? appDataDir,
  }) {
    return rust_jre.findFilteredJres(
      javaVersion: javaVersion,
      appDataDir: appDataDir,
    );
  }
}
