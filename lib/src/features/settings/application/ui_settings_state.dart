import 'package:aml/src/features/settings/data/repositories/ui_settings_repository.dart';
import 'package:aml/src/features/settings/domain/models/ui_settings.dart';
import 'package:aml/src/features/settings/application/cdn_runtime.dart';
import 'package:aml/src/features/settings/application/proxy_runtime.dart';
import 'package:aml/src/shared/theme/color_schemes.dart';
import 'package:flutter/foundation.dart';
import 'package:signals_flutter/signals_flutter.dart';
import 'dart:async';

class UiSettingsState {
  UiSettingsState(this._repository);

  final themePresetId = signal<String>(defaultThemePresetId);
  final onboardingDismissed = signal(false);
  final closeToTray = signal(true);
  final checkUpdatesOnStartup = signal(true);
  final dismissedUpdateTag = signal('');
  final translateDiscoverContent = signal(true);
  final useMcdbSearch = signal(true);
  final librarySortBy = signal('name');
  final libraryGroupBy = signal('none');
  final libraryTab = signal('all');
  final libraryCollapsedGroups = signal<List<String>>(const []);
  final cdnOfficialFirst = signal(false);
  final cdnMcim = signal(true);
  final cdnPysio = signal(true);
  final cdnBmclapi = signal(true);
  final proxyMode = signal('off');
  final proxyUrl = signal('');

  final UiSettingsRepository _repository;
  bool _initialized = false;
  bool _hydrating = false;
  Timer? _saveDebounce;
  VoidCallback? _disposeEffect;

  /// Notified when [closeToTray] changes so the window controller can sync.
  final List<void Function(bool)> _closeToTrayListeners = [];

  Future<void> initialize() async {
    if (_initialized) return;
    _hydrating = true;

    final settings = await _repository.load();
    _applySettings(settings);

    _hydrating = false;
    _initialized = true;
    unawaited(CdnRuntime.syncToResourceDir(settings));
    unawaited(ProxyRuntime.syncToResourceDir(settings));

    _disposeEffect = effect(() {
      if (_hydrating) return;
      final _ = (
        themePresetId.value,
        onboardingDismissed.value,
        closeToTray.value,
        checkUpdatesOnStartup.value,
        dismissedUpdateTag.value,
        translateDiscoverContent.value,
        useMcdbSearch.value,
        librarySortBy.value,
        libraryGroupBy.value,
        libraryTab.value,
        libraryCollapsedGroups.value,
        cdnOfficialFirst.value,
        cdnMcim.value,
        cdnPysio.value,
        cdnBmclapi.value,
        proxyMode.value,
        proxyUrl.value,
      );
      final settings = _snapshotSettings();
      CdnRuntime.apply(settings);
      ProxyRuntime.apply(settings);
      _scheduleSave(settings);
    });
  }

  void _applySettings(UiSettings settings) {
    themePresetId.value = settings.themePresetId;
    onboardingDismissed.value = settings.onboardingDismissed;
    closeToTray.value = settings.closeToTray;
    checkUpdatesOnStartup.value = settings.checkUpdatesOnStartup;
    dismissedUpdateTag.value = settings.dismissedUpdateTag;
    translateDiscoverContent.value = settings.translateDiscoverContent;
    useMcdbSearch.value = settings.useMcdbSearch;
    librarySortBy.value = settings.librarySortBy;
    libraryGroupBy.value = settings.libraryGroupBy;
    libraryTab.value = settings.libraryTab;
    libraryCollapsedGroups.value =
        List<String>.from(settings.libraryCollapsedGroups);
    cdnOfficialFirst.value = settings.cdnOfficialFirst;
    cdnMcim.value = settings.cdnMcim;
    cdnPysio.value = settings.cdnPysio;
    cdnBmclapi.value = settings.cdnBmclapi;
    proxyMode.value = settings.proxyMode;
    proxyUrl.value = settings.proxyUrl;
    CdnRuntime.apply(settings);
    ProxyRuntime.apply(settings);
  }

  UiSettings _snapshotSettings() {
    return UiSettings(
      themePresetId: themePresetId.value,
      onboardingDismissed: onboardingDismissed.value,
      closeToTray: closeToTray.value,
      checkUpdatesOnStartup: checkUpdatesOnStartup.value,
      dismissedUpdateTag: dismissedUpdateTag.value,
      translateDiscoverContent: translateDiscoverContent.value,
      useMcdbSearch: useMcdbSearch.value,
      librarySortBy: librarySortBy.value,
      libraryGroupBy: libraryGroupBy.value,
      libraryTab: libraryTab.value,
      libraryCollapsedGroups: List<String>.from(libraryCollapsedGroups.value),
      cdnOfficialFirst: cdnOfficialFirst.value,
      cdnMcim: cdnMcim.value,
      cdnPysio: cdnPysio.value,
      cdnBmclapi: cdnBmclapi.value,
      proxyMode: proxyMode.value,
      proxyUrl: proxyUrl.value,
    );
  }

  void dismissOnboarding() {
    onboardingDismissed.value = true;
  }

  void setCloseToTray(bool value) {
    if (closeToTray.value == value) return;
    closeToTray.value = value;
    for (final listener in List.of(_closeToTrayListeners)) {
      listener(value);
    }
  }

  void setCheckUpdatesOnStartup(bool value) {
    if (checkUpdatesOnStartup.value == value) return;
    checkUpdatesOnStartup.value = value;
  }

  void setDismissedUpdateTag(String value) {
    if (dismissedUpdateTag.value == value) return;
    dismissedUpdateTag.value = value;
  }

  void setTranslateDiscoverContent(bool value) {
    if (translateDiscoverContent.value == value) return;
    translateDiscoverContent.value = value;
  }

  void setUseMcdbSearch(bool value) {
    if (useMcdbSearch.value == value) return;
    useMcdbSearch.value = value;
  }

  void setLibrarySortBy(String value) {
    if (librarySortBy.value == value) return;
    librarySortBy.value = value;
  }

  void setLibraryGroupBy(String value) {
    if (libraryGroupBy.value == value) return;
    libraryGroupBy.value = value;
  }

  void setLibraryTab(String value) {
    if (libraryTab.value == value) return;
    libraryTab.value = value;
  }

  void setLibraryCollapsedGroups(Iterable<String> groups) {
    final next = groups.toList()..sort();
    final prev = libraryCollapsedGroups.value;
    if (prev.length == next.length) {
      var same = true;
      for (var i = 0; i < next.length; i++) {
        if (prev[i] != next[i]) {
          same = false;
          break;
        }
      }
      if (same) return;
    }
    libraryCollapsedGroups.value = next;
  }

  void setCdnOfficialFirst(bool value) {
    if (cdnOfficialFirst.value == value) return;
    cdnOfficialFirst.value = value;
  }

  void setCdnMcim(bool value) {
    if (cdnMcim.value == value) return;
    cdnMcim.value = value;
  }

  void setCdnPysio(bool value) {
    if (cdnPysio.value == value) return;
    cdnPysio.value = value;
  }

  void setCdnBmclapi(bool value) {
    if (cdnBmclapi.value == value) return;
    cdnBmclapi.value = value;
  }

  void setProxyMode(String value) {
    final next = switch (value) {
      'off' || 'manual' || 'system' => value,
      _ => 'off',
    };
    if (proxyMode.value == next) return;
    proxyMode.value = next;
  }

  void setProxyUrl(String value) {
    if (proxyUrl.value == value) return;
    proxyUrl.value = value;
  }

  void addCloseToTrayListener(void Function(bool) listener) {
    _closeToTrayListeners.add(listener);
  }

  void removeCloseToTrayListener(void Function(bool) listener) {
    _closeToTrayListeners.remove(listener);
  }

  void _scheduleSave(UiSettings settings) {
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () async {
      try {
        await _repository.save(settings);
        CdnRuntime.apply(settings);
        ProxyRuntime.apply(settings);
        await CdnRuntime.syncToResourceDir(settings);
        await ProxyRuntime.syncToResourceDir(settings);
      } catch (e) {
        debugPrint('保存 UI 设置失败: $e');
      }
    });
  }

  Future<void> dispose() async {
    _disposeEffect?.call();
    _saveDebounce?.cancel();
    _closeToTrayListeners.clear();
  }
}
