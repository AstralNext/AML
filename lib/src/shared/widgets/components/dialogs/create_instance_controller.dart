import 'dart:async';

import 'package:aml/src/app/di/service_locator.dart';
import 'package:aml/src/app/state/navigation_state.dart';
import 'package:aml/src/features/instances/application/instance_store.dart';
import 'package:aml/src/rust/api/launcher.dart' as rust;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show TextEditingController;

enum CreateInstanceStage { type, custom, modpack, importPreview }

class CreateInstanceController extends ChangeNotifier {
  CreateInstanceController({this.onCreated, required this.onClose});

  final Future<void> Function()? onCreated;
  final VoidCallback onClose;

  final _store = getIt<InstanceStore>();

  final nameController = TextEditingController(text: '新实例');
  final importNameController = TextEditingController();

  List<rust.GameVersionDto> allVersions = [];
  List<rust.LoaderVersionDto> loaderVersions = [];
  String loader = 'fabric';
  String? gameVersion;
  String? loaderVersion;
  String loaderChannel = 'stable'; // stable | latest | other
  bool showSnapshots = false;
  bool loadingVersions = true;
  bool creating = false;
  String? error;
  String? iconPath;
  CreateInstanceStage stage = CreateInstanceStage.type;
  String? importPath;
  rust.PackImportPreviewDto? importPreview;
  final Set<String> importExpanded = {};

  bool _disposed = false;

  bool get hasNonReleaseVersions => allVersions.any((v) => v.type != 'release');

  List<rust.GameVersionDto> get displayVersions {
    if (showSnapshots || !hasNonReleaseVersions) {
      return allVersions;
    }
    final releases = allVersions.where((v) => v.type == 'release').toList();
    return releases.isEmpty ? allVersions : releases;
  }

  String versionLabel(rust.GameVersionDto version) {
    if (version.type == 'release') return version.id;
    return switch (version.type) {
      'snapshot' => '${version.id}（快照）',
      'old_beta' => '${version.id}（旧测试版）',
      'old_alpha' => '${version.id}（旧预览版）',
      _ => version.id,
    };
  }

  void _ensureValidGameVersion() {
    final visible = displayVersions;
    if (visible.isEmpty) {
      gameVersion = null;
      return;
    }
    if (gameVersion == null || !visible.any((v) => v.id == gameVersion)) {
      gameVersion = visible.first.id;
    }
  }

  void _applyLoaderChannel() {
    if (loaderVersions.isEmpty) {
      loaderVersion = null;
      return;
    }
    switch (loaderChannel) {
      case 'stable':
        loaderVersion = loaderVersions
            .firstWhere((e) => e.stable, orElse: () => loaderVersions.first)
            .id;
      case 'latest':
        loaderVersion = loaderVersions.first.id;
      default:
        loaderVersion ??= loaderVersions.first.id;
    }
  }

  void _syncDefaultName() {
    final loaderLabel = switch (loader) {
      'vanilla' => 'Vanilla',
      'fabric' => 'Fabric',
      'forge' => 'Forge',
      'quilt' => 'Quilt',
      'neoforge' => 'NeoForge',
      _ => loader,
    };
    final gv = gameVersion ?? '';
    nameController.text = gv.isEmpty ? loaderLabel : '$loaderLabel $gv';
  }

  @override
  void dispose() {
    _disposed = true;
    nameController.dispose();
    importNameController.dispose();
    super.dispose();
  }

  Future<void> loadVersions() async {
    loadingVersions = true;
    error = null;
    notifyListeners();
    try {
      final versions = await _store.listMinecraftVersions();
      if (!_disposed) {
        allVersions = versions;
        showSnapshots = false;
        _ensureValidGameVersion();
        if (gameVersion != null) {
          nameController.text = 'Fabric $gameVersion';
        }
        loadingVersions = false;
        notifyListeners();
      }
      if (gameVersion != null && loader != 'vanilla') {
        await loadLoaderVersions();
      }
    } catch (e) {
      if (!_disposed) {
        loadingVersions = false;
        error = e.toString();
        notifyListeners();
      }
    }
  }

  Future<void> loadLoaderVersions() async {
    if (gameVersion == null || loader == 'vanilla') {
      loaderVersions = [];
      loaderVersion = null;
      notifyListeners();
      return;
    }
    try {
      final list = await _store.listLoaderVersions(
        loader: loader,
        gameVersion: gameVersion!,
      );
      if (!_disposed) {
        loaderVersions = list;
        _applyLoaderChannel();
        notifyListeners();
      }
    } catch (e) {
      if (!_disposed) {
        error = e.toString();
        loaderVersions = [];
        loaderVersion = null;
        notifyListeners();
      }
    }
  }

  void setShowSnapshots(bool value) {
    showSnapshots = value;
    _ensureValidGameVersion();
    _syncDefaultName();
    notifyListeners();
    if (gameVersion != null && loader != 'vanilla') {
      unawaited(loadLoaderVersions());
    }
  }

  Future<void> setLoader(String value) async {
    loader = value;
    _syncDefaultName();
    notifyListeners();
    await loadLoaderVersions();
  }

  Future<void> setGameVersion(String value) async {
    gameVersion = value;
    _syncDefaultName();
    notifyListeners();
    await loadLoaderVersions();
  }

  void setLoaderChannelWithPick(String value) {
    loaderChannel = value;
    _applyLoaderChannel();
    notifyListeners();
  }

  void setLoaderChannel(String value) {
    loaderChannel = value;
    notifyListeners();
  }

  void setLoaderVersion(String value) {
    loaderVersion = value;
    notifyListeners();
  }

  Future<void> pickIcon() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      allowMultiple: false,
    );
    if (result == null || result.files.isEmpty) return;
    final path = result.files.first.path;
    if (path == null || path.isEmpty) return;
    if (_disposed) return;
    iconPath = path;
    notifyListeners();
  }

  void clearIcon() {
    iconPath = null;
    notifyListeners();
  }

  void selectCustomType() {
    stage = CreateInstanceStage.custom;
    notifyListeners();
  }

  void selectModpackType() {
    stage = CreateInstanceStage.modpack;
    notifyListeners();
  }

  void backFromModpackStage() {
    error = null;
    stage = CreateInstanceStage.type;
    notifyListeners();
  }

  void backFromCustomStage() {
    stage = CreateInstanceStage.type;
    notifyListeners();
  }

  void backFromImportPreviewStage() {
    error = null;
    importPath = null;
    importPreview = null;
    stage = CreateInstanceStage.modpack;
    notifyListeners();
  }

  void toggleImportCategory(String id) {
    if (importExpanded.contains(id)) {
      importExpanded.remove(id);
    } else {
      importExpanded.add(id);
    }
    notifyListeners();
  }

  Future<void> submitCustom() async {
    final name = nameController.text.trim();
    if (name.isEmpty || gameVersion == null) return;
    creating = true;
    error = null;
    notifyListeners();
    try {
      final created = await _store.create(
        name: name,
        gameVersion: gameVersion!,
        loader: loader,
        loaderVersion: loader == 'vanilla' ? null : loaderVersion,
        icon: iconPath,
      );
      if (_disposed) return;
      await onCreated?.call();
      // Close immediately — don't keep the dialog open for the full install.
      onClose();
      getIt<NavigationState>().openInstance(created.id);
      unawaited(_store.install(created.id));
    } catch (e) {
      if (!_disposed) {
        error = e.toString();
        creating = false;
        notifyListeners();
      }
    }
  }

  Future<void> pickImportPack() async {
    creating = true;
    error = null;
    notifyListeners();
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['mrpack', 'zip'],
      );
      if (result == null ||
          result.files.isEmpty ||
          result.files.first.path == null) {
        if (!_disposed) {
          creating = false;
          notifyListeners();
        }
        return;
      }
      final path = result.files.first.path!;
      final fallbackName = result.files.first.name
          .replaceAll(RegExp(r'\.(mrpack|zip)$', caseSensitive: false), '');
      rust.PackImportPreviewDto preview;
      try {
        preview = await rust.previewPackFile(path: path);
      } catch (e) {
        if (!_disposed) {
          error = '无法预览整合包: $e';
          creating = false;
          notifyListeners();
        }
        return;
      }
      if (_disposed) return;
      importNameController.text =
          preview.name.trim().isEmpty ? fallbackName : preview.name;
      importPath = path;
      importPreview = preview;
      importExpanded.clear();
      creating = false;
      stage = CreateInstanceStage.importPreview;
      notifyListeners();
    } catch (e) {
      if (!_disposed) {
        error = e.toString();
        creating = false;
        notifyListeners();
      }
    }
  }

  Future<void> confirmImportPack() async {
    final path = importPath;
    if (path == null || creating) return;
    final name = importNameController.text.trim();
    if (name.isEmpty) {
      error = '请填写实例名称';
      notifyListeners();
      return;
    }
    creating = true;
    error = null;
    notifyListeners();
    try {
      final created = await _store.createFromPackFile(
        path: path,
        name: name,
      );
      if (_disposed) return;
      await onCreated?.call();
      onClose();
      getIt<NavigationState>().openInstance(created.id);
    } catch (e) {
      if (!_disposed) {
        error = e.toString();
        creating = false;
        notifyListeners();
      }
    }
  }

  void browseModpacksOnModrinth() {
    onClose();
    getIt<NavigationState>().browseModpacks();
  }
}
