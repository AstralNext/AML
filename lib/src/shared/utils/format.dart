// Shared display formatters (bytes, counts, download counts).
//
// Keep these pure top-level functions; do not add new copies elsewhere.

/// Human-readable byte size, e.g. `512 B` / `1.5 MB` / `2.35 GB`.
String formatBytes(num bytes) {
  if (bytes < 1024) return '${bytes.toInt()} B';
  final kb = bytes / 1024;
  if (kb < 1024) return '${kb.toStringAsFixed(kb < 10 ? 1 : 0)} KB';
  final mb = kb / 1024;
  if (mb < 1024) return '${mb.toStringAsFixed(mb < 10 ? 1 : 0)} MB';
  final gb = mb / 1024;
  return '${gb.toStringAsFixed(2)} GB';
}

/// Compact integer count, e.g. `9804` / `12.3k` / `1.2M`.
String formatCount(int n) {
  if (n < 10000) return '$n';
  if (n < 1000000) {
    final k = n / 1000.0;
    return '${k.toStringAsFixed(k < 10 ? 1 : 0)}k';
  }
  final m = n / 1000000.0;
  return '${m.toStringAsFixed(m < 10 ? 1 : 0)}M';
}

/// Chinese-style download count, e.g. `1.2万` / `3.45亿` / `890K`.
String formatDownloadCount(int downloads) {
  if (downloads >= 100000000) {
    final v = downloads / 100000000;
    final s = v >= 10 ? v.toStringAsFixed(1) : v.toStringAsFixed(2);
    return '${_trimTrailingZeros(s)}亿';
  }
  if (downloads >= 10000) {
    final v = downloads / 10000;
    final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
    return '${_trimTrailingZeros(s)}万';
  }
  if (downloads >= 1000) {
    return '${_trimTrailingZeros((downloads / 1000).toStringAsFixed(1))}K';
  }
  return downloads.toString();
}

String _trimTrailingZeros(String s) {
  if (!s.contains('.')) return s;
  return s.replaceFirst(RegExp(r'\.?0+$'), '');
}
