import 'dart:async';
import 'dart:io';

import 'package:aml/src/app/app_store.dart';
import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/launch_link.dart';
import 'package:aml/src/app/state/pending_launch_state.dart';
import 'package:aml/src/app/state/runtime_state.dart';
import 'package:aml/src/app/window_tray_controller.dart';
import 'package:aml/core/window_manager.dart';
import 'package:aml/src/features/accounts/application/account_avatar_cache.dart';
import 'package:aml/src/features/instances/application/account_store.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/debug/memory_probe.dart';
import 'package:aml/src/rust/frb_generated.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

Future<void> bootstrap({List<String> args = const []}) async {
  WidgetsFlutterBinding.ensureInitialized();
  // 限制解码图缓存，避免 Discover/首页图标把 RSS 顶高。
  PaintingBinding.instance.imageCache.maximumSize = 80;
  PaintingBinding.instance.imageCache.maximumSizeBytes = 24 << 20; // 24 MB

  final directory = await getApplicationSupportDirectory();
  setupServiceLocator(appDataDir: directory.path);

  await RustLib.init();
  getIt<RuntimeState>().appDataDirectory.value = directory.path;
  await getIt<AppStore>().initialize();
  await getIt<InstanceStore>().initialize();
  await getIt<AccountStore>().refresh();

  final link = AmlLaunchLink.fromArgs(args);
  if (link != null) {
    debugPrint(
      '[AML launch] pending shortcut '
      'instance=${link.instanceId} server=${link.serverAddress} '
      'world=${link.worldFolder}',
    );
    getIt<PendingLaunchState>().take(link);
  }

  // 仅预热头像缩略图；皮肤列表等进入皮肤库再加载。
  unawaited(_prefetchSkins());

  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    await WindowManagerUtils.initializeWindow();
    await getIt<WindowTrayController>().initialize();
  }

  unawaited(MemoryProbe.runIfEnabled());
}

Future<void> _prefetchSkins() async {
  try {
    final accounts = getIt<AccountStore>();
    final heads = getIt<AccountAvatarCache>();
    for (final account in accounts.accounts.value) {
      heads.peek(account.uuid);
    }
  } catch (e, st) {
    debugPrint('skin prefetch failed: $e\n$st');
  }
}
