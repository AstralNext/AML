import 'package:aml/src/app/launch_link.dart';

/// Pending launch from a desktop shortcut (`aml://…`).
///
/// Used for both cold start (args at process launch) and warm start
/// (second-instance args forwarded via single-instance IPC).
class PendingLaunchState {
  AmlLaunchLink? pending;

  /// Fired when [take] receives a link while the UI is already running.
  void Function(AmlLaunchLink link)? onPending;

  void take(AmlLaunchLink? link) {
    if (link == null) return;
    pending = link;
    onPending?.call(link);
  }

  AmlLaunchLink? consume() {
    final v = pending;
    pending = null;
    return v;
  }
}
