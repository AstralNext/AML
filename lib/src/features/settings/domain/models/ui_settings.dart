import 'package:aml/src/shared/theme/color_schemes.dart';

class UiSettings {
  final String themePresetId;
  final bool onboardingDismissed;

  /// When true, the window close button hides to the system tray instead of quitting.
  final bool closeToTray;

  /// When true, silently check GitHub releases after startup.
  final bool checkUpdatesOnStartup;

  /// Last update tag the user chose to skip (e.g. `v0.0.2-beta`).
  final String dismissedUpdateTag;

  /// When true, project detail HTML/Markdown body is cloud-translated.
  final bool translateDiscoverContent;

  /// When true, Chinese search queries are rewritten via MCDB online title search.
  final bool useMcdbSearch;

  /// Library page: name | gameVersion | lastPlayed | created
  final String librarySortBy;

  /// Library page: none | loader | gameVersion | libraryGroup
  final String libraryGroupBy;

  /// Library page tab: all | modpacks | servers | custom
  final String libraryTab;

  /// Collapsed group header titles on the library page.
  final List<String> libraryCollapsedGroups;

  const UiSettings({
    required this.themePresetId,
    this.onboardingDismissed = false,
    this.closeToTray = true,
    this.checkUpdatesOnStartup = true,
    this.dismissedUpdateTag = '',
    this.translateDiscoverContent = true,
    this.useMcdbSearch = true,
    this.librarySortBy = 'name',
    this.libraryGroupBy = 'none',
    this.libraryTab = 'all',
    this.libraryCollapsedGroups = const [],
  });

  factory UiSettings.defaults() => const UiSettings(
        themePresetId: defaultThemePresetId,
        onboardingDismissed: false,
        closeToTray: true,
        checkUpdatesOnStartup: true,
        dismissedUpdateTag: '',
        translateDiscoverContent: true,
        useMcdbSearch: true,
        librarySortBy: 'name',
        libraryGroupBy: 'none',
        libraryTab: 'all',
        libraryCollapsedGroups: [],
      );

  UiSettings copyWith({
    String? themePresetId,
    bool? onboardingDismissed,
    bool? closeToTray,
    bool? checkUpdatesOnStartup,
    String? dismissedUpdateTag,
    bool? translateDiscoverContent,
    bool? useMcdbSearch,
    String? librarySortBy,
    String? libraryGroupBy,
    String? libraryTab,
    List<String>? libraryCollapsedGroups,
  }) {
    return UiSettings(
      themePresetId: themePresetId ?? this.themePresetId,
      onboardingDismissed: onboardingDismissed ?? this.onboardingDismissed,
      closeToTray: closeToTray ?? this.closeToTray,
      checkUpdatesOnStartup:
          checkUpdatesOnStartup ?? this.checkUpdatesOnStartup,
      dismissedUpdateTag: dismissedUpdateTag ?? this.dismissedUpdateTag,
      translateDiscoverContent:
          translateDiscoverContent ?? this.translateDiscoverContent,
      useMcdbSearch: useMcdbSearch ?? this.useMcdbSearch,
      librarySortBy: librarySortBy ?? this.librarySortBy,
      libraryGroupBy: libraryGroupBy ?? this.libraryGroupBy,
      libraryTab: libraryTab ?? this.libraryTab,
      libraryCollapsedGroups:
          libraryCollapsedGroups ?? this.libraryCollapsedGroups,
    );
  }

  Map<String, dynamic> toJson() => {
        'themePresetId': themePresetId,
        'onboardingDismissed': onboardingDismissed,
        'closeToTray': closeToTray,
        'checkUpdatesOnStartup': checkUpdatesOnStartup,
        'dismissedUpdateTag': dismissedUpdateTag,
        'translateDiscoverContent': translateDiscoverContent,
        'useMcdbSearch': useMcdbSearch,
        'librarySortBy': librarySortBy,
        'libraryGroupBy': libraryGroupBy,
        'libraryTab': libraryTab,
        'libraryCollapsedGroups': libraryCollapsedGroups,
      };

  factory UiSettings.fromJson(Map<String, dynamic> json) {
    final collapsedRaw = json['libraryCollapsedGroups'];
    final collapsed = collapsedRaw is List
        ? collapsedRaw.map((e) => '$e').where((e) => e.isNotEmpty).toList()
        : const <String>[];
    return UiSettings(
      themePresetId: json['themePresetId'] as String? ?? defaultThemePresetId,
      onboardingDismissed: json['onboardingDismissed'] as bool? ?? false,
      closeToTray: json['closeToTray'] as bool? ?? true,
      checkUpdatesOnStartup: json['checkUpdatesOnStartup'] as bool? ?? true,
      dismissedUpdateTag: json['dismissedUpdateTag'] as String? ?? '',
      translateDiscoverContent:
          json['translateDiscoverContent'] as bool? ?? true,
      useMcdbSearch: json['useMcdbSearch'] as bool? ?? true,
      librarySortBy: json['librarySortBy'] as String? ?? 'name',
      libraryGroupBy: json['libraryGroupBy'] as String? ?? 'none',
      libraryTab: json['libraryTab'] as String? ?? 'all',
      libraryCollapsedGroups: collapsed,
    );
  }
}
