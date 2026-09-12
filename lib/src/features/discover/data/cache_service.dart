import 'dart:collection';

class CacheEntry {
  final dynamic data;
  final DateTime timestamp;

  CacheEntry(this.data, this.timestamp);

  bool isValid(Duration cacheDuration) {
    return DateTime.now().difference(timestamp) < cacheDuration;
  }
}

/// In-memory TTL cache with LRU eviction when [maxEntries] is exceeded.
class CacheService {
  CacheService({this.maxEntries = 256});

  /// Soft cap on entries; oldest (least recently used) are dropped first.
  final int maxEntries;

  final LinkedHashMap<String, CacheEntry> _cache = LinkedHashMap();
  int hits = 0;
  int misses = 0;

  int get entryCount => _cache.length;

  dynamic get(String key, Duration cacheDuration) {
    final entry = _cache.remove(key);
    if (entry != null && entry.isValid(cacheDuration)) {
      hits++;
      _cache[key] = entry;
      return entry.data;
    }
    misses++;
    return null;
  }

  void put(String key, dynamic data) {
    _cache.remove(key);
    _cache[key] = CacheEntry(data, DateTime.now());
    _evictIfNeeded();
  }

  void clear() {
    _cache.clear();
    hits = 0;
    misses = 0;
  }

  int countByPrefix(String prefix) =>
      _cache.keys.where((k) => k.startsWith(prefix)).length;

  void clearByPrefix(String prefix) {
    _cache.removeWhere((k, _) => k.startsWith(prefix));
  }

  void _evictIfNeeded() {
    while (_cache.length > maxEntries && _cache.isNotEmpty) {
      _cache.remove(_cache.keys.first);
    }
  }
}
