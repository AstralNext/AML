import 'package:aml/src/app/state/progress_item.dart';
import 'package:signals_flutter/signals_flutter.dart';

class ProgressStore {
  ProgressStore();

  final progressList = signal<List<ProgressItem>>([]);
  final progressVisibility = signal<bool>(false);

  int get itemCount => progressList.value.length;

  int get failedCount =>
      progressList.value.where((item) => item.failed.value).length;

  bool get hasFailed => failedCount > 0;

  ProgressItem createProgressItem(String name, {int retryAttempt = 0}) {
    final displayName =
        retryAttempt > 0 ? '$name（第 ${retryAttempt + 1} 次）' : name;
    final item = ProgressItem(
      name: displayName,
      retryAttempt: retryAttempt,
      onDispose: (item) {
        progressList.value = List.from(progressList.value)..remove(item);
        if (progressList.value.isEmpty) {
          progressVisibility.value = false;
        }
      },
    );
    progressList.value = List.from(progressList.value)..add(item);
    return item;
  }
}
