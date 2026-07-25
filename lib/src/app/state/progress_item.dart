import 'package:signals_flutter/signals_flutter.dart';

class ProgressItem {
  final name = signal<String>('');
  final progress = signal<double>(0.0);
  final progressText = signal<String>('');
  final failed = signal(false);

  /// How many times this task has already been retried (0 = first attempt).
  final retryAttempt = signal(0);

  /// Optional retry for failed tasks (e.g. re-run install).
  Future<void> Function()? onRetry;

  final void Function(ProgressItem) onDispose;

  ProgressItem({
    required String name,
    required this.onDispose,
    int retryAttempt = 0,
  }) {
    this.name.value = name;
    this.retryAttempt.value = retryAttempt;
  }

  void setProgress(double value, [String? text]) {
    if (!failed.value) {
      progress.value = value;
    } else {
      progress.value = value;
    }
    if (text != null) progressText.value = text;
  }

  void markFailed(String message) {
    failed.value = true;
    progressText.value = message;
  }

  void setName(String value) => name.value = value;
  void setProgressText(String value) => progressText.value = value;

  void dispose() {
    onDispose(this);
  }
}
