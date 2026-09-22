import 'package:aml/src/app/state/progress_item.dart';
import 'package:signals_flutter/signals_flutter.dart';

class ProgressStore {
  ProgressStore();

  final progressList = signal<List<ProgressItem>>([]);
  final progressVisibility = signal<bool>(false);

  /// 最近一次由“点击弹窗外区域”关闭弹窗的时间戳。
  /// 用于让触发按钮忽略同一次点击后续的 tap，避免“关了又开”。
  int _outsideDismissAtMs = 0;

  /// 由穿透遮罩在 pointer down 时调用：关闭弹窗且不吞掉这次点击。
  void dismissByOutsideTap() {
    _outsideDismissAtMs = DateTime.now().millisecondsSinceEpoch;
    progressVisibility.value = false;
  }

  /// 触发按钮在 tap 时调用：若本次点击刚被遮罩用于关闭，则返回 true。
  bool consumeJustDismissedByOutsideTap() {
    if (_outsideDismissAtMs == 0) return false;
    final delta = DateTime.now().millisecondsSinceEpoch - _outsideDismissAtMs;
    if (delta >= 0 && delta < 500) {
      _outsideDismissAtMs = 0;
      return true;
    }
    return false;
  }

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
