/// Relative time helpers for RFC3339 / DateTime display.
String relativeAge(
  String? rfc3339, {
  String empty = '',
}) {
  if (rfc3339 == null || rfc3339.isEmpty) return empty;
  final dt = DateTime.tryParse(rfc3339);
  if (dt == null) return empty;
  return relativeFromDateTime(dt);
}

String relativeFromDateTime(DateTime dt) {
  final diff = DateTime.now().toUtc().difference(dt.toUtc());
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inMinutes < 60) return '${diff.inMinutes} 分钟前';
  if (diff.inHours < 24) return '${diff.inHours} 小时前';
  if (diff.inDays < 30) return '${diff.inDays} 天前';
  return '${diff.inDays ~/ 30} 个月前';
}
