import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/aml_app.dart';
import 'package:aml/src/app/bootstrap.dart';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/launch_link.dart';
import 'package:aml/src/app/state/pending_launch_state.dart';
import 'package:aml/src/app/window_tray_controller.dart';
import 'package:aml/src/features/settings/application/proxy_runtime.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:windows_single_instance/windows_single_instance.dart';

Future<void> main(List<String> args) async {
  WidgetsFlutterBinding.ensureInitialized();
  ProxyRuntime.installHttpOverrides();

  // Single-instance: second process forwards argv to the running app and exits.
  if (Platform.isWindows) {
    await WindowsSingleInstance.ensureSingleInstance(
      args,
      'aml_launcher',
      onSecondWindow: _onSecondInstanceArgs,
    );
  }

  await bootstrap(args: args);
  runApp(const AmlApp());
}

/// Called on the *first* instance when another process starts with new args
/// (e.g. desktop shortcut `aml://launch/...`).
void _onSecondInstanceArgs(List<String> args) {
  debugPrint('[AML launch] second-instance args: $args');
  final link = AmlLaunchLink.fromArgs(args);
  if (link != null && getIt.isRegistered<PendingLaunchState>()) {
    getIt<PendingLaunchState>().take(link);
  }
  if (getIt.isRegistered<WindowTrayController>()) {
    unawaited(getIt<WindowTrayController>().showMainWindow());
  }
}
