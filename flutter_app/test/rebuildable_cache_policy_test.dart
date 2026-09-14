import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/services/rebuildable_cache_policy.dart';

void main() {
  test('evicts only oldest rebuildable entries to fit the bounded budget', () {
    final now = DateTime.utc(2026, 9, 14);
    const policy = RebuildableCachePolicy(maxBytes: 100);
    final plan = policy.evictionPlan([
      RebuildableCacheEntry(key: 'warm-old', bytes: 60, lastAccessedAt: now),
      RebuildableCacheEntry(
        key: 'warm-new',
        bytes: 60,
        lastAccessedAt: now.add(const Duration(hours: 1)),
      ),
    ]);

    expect(plan, ['warm-old']);
  });

  test('protected audio is outside the rebuildable policy boundary', () {
    const policy = RebuildableCachePolicy(maxBytes: 100);
    final plan = policy.evictionPlan([
      RebuildableCacheEntry(
        key: 'fulltext-only',
        bytes: 80,
        lastAccessedAt: DateTime.utc(2026, 9, 14),
      ),
    ], additionalBytes: 40);

    expect(plan, ['fulltext-only']);
    expect(plan, isNot(contains('chapter.mp3')));
  });
}
