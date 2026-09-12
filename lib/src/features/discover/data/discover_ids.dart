/// Helpers for Modrinth vs CurseForge project ids in Discover.
/// CurseForge projects use the prefix `cf:` so they never collide with Modrinth ids.
const kCurseForgeIdPrefix = 'cf:';

bool isCurseForgeProjectId(String id) => id.startsWith(kCurseForgeIdPrefix);

/// Returns the numeric CurseForge mod id, or null if [id] is not a CF id.
int? parseCurseForgeModId(String id) {
  if (!isCurseForgeProjectId(id)) return null;
  return int.tryParse(id.substring(kCurseForgeIdPrefix.length));
}

String curseForgeProjectId(int modId) => '$kCurseForgeIdPrefix$modId';

/// Normalize CF/MR project ids for equality (handles `cf:123` vs `123`).
bool sameProjectId(String? a, String? b) {
  if (a == null || b == null || a.isEmpty || b.isEmpty) return false;
  if (a == b) return true;
  final ca = parseCurseForgeModId(a) ?? int.tryParse(a);
  final cb = parseCurseForgeModId(b) ?? int.tryParse(b);
  return ca != null && ca == cb;
}

/// `modrinth` | `curseforge` | null when unknown / local-only.
String? contentSourceOf({String? projectId, String? explicitSource}) {
  final src = explicitSource?.trim().toLowerCase();
  if (src == 'modrinth' || src == 'curseforge' || src == 'file') return src;
  if (projectId == null || projectId.isEmpty) return null;
  if (isCurseForgeProjectId(projectId)) return 'curseforge';
  return 'modrinth';
}

String sourceLabel(String? source) {
  switch (source) {
    case 'curseforge':
      return 'CurseForge';
    case 'modrinth':
      return 'Modrinth';
    case 'file':
      return '本地';
    default:
      return '未知';
  }
}
