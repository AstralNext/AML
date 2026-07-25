import 'package:aml/src/shared/theme/theme_token_access.dart';
import 'package:flutter/material.dart';

/// Project environment badge from v2 client_side / server_side.
class ProjectEnvironmentBadge {
  final IconData icon;
  final String label;

  const ProjectEnvironmentBadge(this.icon, this.label);

  /// Only meaningful for mod / modpack.
  static ProjectEnvironmentBadge? fromSides({
    required String clientSide,
    required String serverSide,
    required String projectType,
  }) {
    if (projectType != 'mod' && projectType != 'modpack') {
      return null;
    }
    final client = clientSide.toLowerCase();
    final server = serverSide.toLowerCase();

    if (client == 'optional' && server == 'optional') {
      return const ProjectEnvironmentBadge(Icons.public, '客户端或服务端');
    }
    if (client == 'required' && server == 'required') {
      return const ProjectEnvironmentBadge(Icons.public, '客户端与服务端');
    }
    if ((client == 'optional' || client == 'required') &&
        (server == 'optional' || server == 'unsupported')) {
      return const ProjectEnvironmentBadge(Icons.desktop_windows, '客户端');
    }
    if ((server == 'optional' || server == 'required') &&
        (client == 'optional' || client == 'unsupported')) {
      return const ProjectEnvironmentBadge(Icons.dns_outlined, '服务端');
    }
    return null;
  }
}

class EnvironmentBadgeChip extends StatelessWidget {
  const EnvironmentBadgeChip({super.key, required this.badge});

  final ProjectEnvironmentBadge badge;

  @override
  Widget build(BuildContext context) {
    final tokens = context.tokens;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tokens.colorButtonBg.withValues(alpha: 0.55),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(badge.icon, size: 13, color: tokens.colorContrast),
          const SizedBox(width: 4),
          Text(
            badge.label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: tokens.colorContrast,
            ),
          ),
        ],
      ),
    );
  }
}

/// Browse Environment filter: Client / Server (v2 facet approximation).
List<List<String>> environmentFacets({
  required bool client,
  required bool server,
}) {
  if (!client && !server) return const [];
  if (client && server) {
    return [
      ['client_side:required', 'client_side:optional'],
      ['server_side:required', 'server_side:optional'],
    ];
  }
  if (client) {
    return [
      ['client_side:required', 'client_side:optional'],
      ['server_side:optional', 'server_side:unsupported'],
    ];
  }
  return [
    ['server_side:required', 'server_side:optional'],
    ['client_side:optional', 'client_side:unsupported'],
  ];
}
