/// Parses `aml://launch/instance/{id}[?server=…|&world=…]` cold-start deep links.
class AmlLaunchLink {
  const AmlLaunchLink({
    required this.instanceId,
    this.serverAddress,
    this.worldFolder,
  });

  final String instanceId;
  final String? serverAddress;
  final String? worldFolder;

  /// Find and parse the first `aml://launch/…` argument in [args].
  static AmlLaunchLink? fromArgs(List<String> args) {
    for (final raw in args) {
      final parsed = tryParse(raw.trim());
      if (parsed != null) return parsed;
    }
    return null;
  }

  static AmlLaunchLink? tryParse(String raw) {
    if (raw.isEmpty) return null;
    final uri = Uri.tryParse(raw);
    if (uri == null) return null;
    if (uri.scheme.toLowerCase() != 'aml') return null;

    // aml://launch/instance/{id}  → host=launch, path=/instance/{id}
    // aml:///launch/instance/{id} → path=/launch/instance/{id}
    final segments = <String>[
      if (uri.host.isNotEmpty) uri.host,
      ...uri.pathSegments.where((s) => s.isNotEmpty),
    ];
    if (segments.length < 3) return null;
    if (segments[0] != 'launch' || segments[1] != 'instance') return null;

    final instanceId = Uri.decodeComponent(segments.sublist(2).join('/'));
    if (instanceId.isEmpty) return null;

    final server = uri.queryParameters['server']?.trim();
    final world = (uri.queryParameters['world'] ??
            uri.queryParameters['singleplayer_world'])
        ?.trim();
    if (server != null &&
        server.isNotEmpty &&
        world != null &&
        world.isNotEmpty) {
      return null;
    }

    return AmlLaunchLink(
      instanceId: instanceId,
      serverAddress: (server != null && server.isNotEmpty) ? server : null,
      worldFolder: (world != null && world.isNotEmpty) ? world : null,
    );
  }
}
