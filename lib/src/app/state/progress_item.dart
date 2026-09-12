import 'dart:convert';

import 'package:signals_flutter/signals_flutter.dart';

class ProgressItem {
  final name = signal<String>('');
  final progress = signal<double>(0.0);
  final progressText = signal<String>('');
  final failed = signal(false);

  /// Sub-task bar 0..=1, or null when there is no nested work.
  final subProgress = signal<double?>(null);
  final subText = signal<String>('');

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
    progress.value = value.clamp(0.0, 1.0);
    if (text == null) return;
    final task = parseTaskProgress(text);
    if (task != null) {
      progressText.value = task.stage;
      subProgress.value = task.bar;
      subText.value = task.detail;
    } else {
      progressText.value = text;
      subProgress.value = null;
      subText.value = '';
    }
  }

  void markFailed(String message) {
    failed.value = true;
    progressText.value = message;
    subProgress.value = null;
    subText.value = '';
  }

  void setName(String value) => name.value = value;
  void setProgressText(String value) => progressText.value = value;

  void dispose() {
    onDispose(this);
  }
}

class TaskProgressInfo {
  final String stage;
  final double? bar;
  final String detail;

  const TaskProgressInfo({
    required this.stage,
    this.bar,
    this.detail = '',
  });
}

const _taskPrefix = '__TASK__';

TaskProgressInfo? parseTaskProgress(String raw) {
  final text = raw.trim();
  if (!text.startsWith(_taskPrefix)) return null;
  final json = text.substring(_taskPrefix.length);
  try {
    final decoded = jsonDecode(json);
    if (decoded is! Map) return null;
    final map = Map<String, dynamic>.from(decoded);
    final stage = '${map['stage'] ?? ''}'.trim();
    final name = '${map['name'] ?? ''}'.trim();
    final current = _asInt(map['current']);
    final total = _asInt(map['total']);
    final downloaded = _asInt(map['downloaded']);
    final size = _asInt(map['size']);
    final speed = _asInt(map['speed']);
    final active = _asInt(map['active']);
    final sub = _asDouble(map['sub']);

    double? bar = sub;
    if (bar == null && size != null && size > 0 && downloaded != null) {
      bar = (downloaded / size).clamp(0.0, 1.0);
    }
    if (bar == null && total != null && total > 0 && current != null) {
      bar = (current / total).clamp(0.0, 1.0);
    }

    final parts = <String>[];
    if (current != null && total != null && total > 0) {
      parts.add('$current/$total');
    }
    if (active != null && active > 1) {
      parts.add('$active 个并行');
    }
    if (name.isNotEmpty) {
      parts.add(name);
    }
    if (downloaded != null && downloaded > 0) {
      if (size != null && size > 0) {
        parts.add('${formatBytes(downloaded)} / ${formatBytes(size)}');
      } else {
        parts.add(formatBytes(downloaded));
      }
    }
    if (speed != null && speed > 0) {
      parts.add('${formatBytes(speed)}/s');
    }

    return TaskProgressInfo(
      stage: stage.isEmpty ? name : stage,
      bar: bar,
      detail: parts.join(' · '),
    );
  } catch (_) {
    return null;
  }
}

double? _asDouble(Object? value) {
  if (value is double) return value;
  if (value is int) return value.toDouble();
  if (value is num) return value.toDouble();
  return double.tryParse('$value');
}

int? _asInt(Object? value) {
  if (value == null) return null;
  if (value is int) return value;
  if (value is double) return value.round();
  if (value is num) return value.toInt();
  return int.tryParse('$value');
}

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}
