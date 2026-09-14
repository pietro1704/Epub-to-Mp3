/// A bounded LRU policy for data that can be rebuilt from the source book.
///
/// Protected audio is intentionally not represented by this type. Keeping the
/// policies separate makes it impossible for full-text maintenance to delete a
/// completed listening artifact.
class RebuildableCacheEntry {
  const RebuildableCacheEntry({
    required this.key,
    required this.bytes,
    required this.lastAccessedAt,
  });

  final String key;
  final int bytes;
  final DateTime lastAccessedAt;
}

class RebuildableCachePolicy {
  const RebuildableCachePolicy({required this.maxBytes});

  final int maxBytes;

  /// Returns the oldest rebuildable keys that must be removed before adding
  /// [additionalBytes]. The input list is never mutated.
  List<String> evictionPlan(
    Iterable<RebuildableCacheEntry> entries, {
    int additionalBytes = 0,
  }) {
    final ordered = entries.toList()
      ..sort((a, b) => a.lastAccessedAt.compareTo(b.lastAccessedAt));
    var total = ordered.fold<int>(0, (sum, entry) => sum + entry.bytes);
    final plan = <String>[];
    for (final entry in ordered) {
      if (total + additionalBytes <= maxBytes) break;
      plan.add(entry.key);
      total -= entry.bytes;
    }
    return plan;
  }
}
