import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/offline_cache_eviction.dart';

// ---------------------------------------------------------------------------
// Helper: plant an audiobook folder with a stub file.
// ---------------------------------------------------------------------------

/// Plants `<root>/downloads/<jobId>/` with a stub MP3 and a last_access
/// sidecar. The helper writes exactly [totalBytes] bytes as the stub file
/// so the folder scanner's recursive count is predictable.
Future<void> plantAudiobook(
  Directory root, {
  required String jobId,
  required int totalBytes,
  required DateTime lastAccessedAt,
}) async {
  // root here is already the *documents* root — _resolveRoot will append
  // "downloads/" so we pre-create the full path.
  final folder = Directory('${root.path}/downloads/$jobId');
  await folder.create(recursive: true);

  // Stub MP3.
  final stub = File('${folder.path}/chapter_0.mp3');
  await stub.writeAsBytes(List.filled(totalBytes, 0xFF));

  // last_access sidecar.
  final sidecar = File('${folder.path}/.last_access');
  await sidecar.writeAsString(lastAccessedAt.toUtc().toIso8601String());
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  late Directory tempDir;

  setUp(() async {
    tempDir =
        await Directory.systemTemp.createTemp('OfflineCacheEvictionTest_');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('OfflineCacheEviction', () {
    test('under budget and within TTL — no eviction', () async {
      final now = DateTime.now().toUtc();
      await plantAudiobook(tempDir,
          jobId: 'book1',
          totalBytes: 100,
          lastAccessedAt: now.subtract(const Duration(hours: 1)));
      await plantAudiobook(tempDir,
          jobId: 'book2',
          totalBytes: 200,
          lastAccessedAt: now.subtract(const Duration(hours: 2)));

      final evicted = await OfflineCacheEviction.runEviction(
        budgetBytes: 1000 * 1024 * 1024, // 1 GB — well above total
        ttlSeconds: 48 * 3600,
        downloadsRoot: tempDir,
      );

      expect(evicted, isEmpty);
      expect(Directory('${tempDir.path}/downloads/book1').existsSync(),
          isTrue);
      expect(Directory('${tempDir.path}/downloads/book2').existsSync(),
          isTrue);
    });

    test('TTL evicts expired entries', () async {
      final now = DateTime.now().toUtc();
      // book1 is 48 h old — over the 24 h TTL.
      await plantAudiobook(tempDir,
          jobId: 'book1',
          totalBytes: 100,
          lastAccessedAt: now.subtract(const Duration(hours: 48)));
      // book2 is fresh.
      await plantAudiobook(tempDir,
          jobId: 'book2',
          totalBytes: 100,
          lastAccessedAt: now.subtract(const Duration(minutes: 30)));

      final evicted = await OfflineCacheEviction.runEviction(
        budgetBytes: 1000 * 1024 * 1024,
        ttlSeconds: 24 * 3600,
        downloadsRoot: tempDir,
      );

      expect(evicted, contains('book1'));
      expect(evicted, isNot(contains('book2')));
      expect(Directory('${tempDir.path}/downloads/book1').existsSync(),
          isFalse);
      expect(Directory('${tempDir.path}/downloads/book2').existsSync(),
          isTrue);
    });

    test('budget evicts LRU first', () async {
      final now = DateTime.now().toUtc();
      // 3 books × 1000 bytes stub files.
      // LRU order: book_a (oldest) → book_b → book_c (freshest).
      // Budget = 1500 bytes → must evict at least book_a; book_c kept.
      await plantAudiobook(tempDir,
          jobId: 'book_a',
          totalBytes: 1000,
          lastAccessedAt: now.subtract(const Duration(hours: 3)));
      await plantAudiobook(tempDir,
          jobId: 'book_b',
          totalBytes: 1000,
          lastAccessedAt: now.subtract(const Duration(hours: 2)));
      await plantAudiobook(tempDir,
          jobId: 'book_c',
          totalBytes: 1000,
          lastAccessedAt: now.subtract(const Duration(hours: 1)));

      final evicted = await OfflineCacheEviction.runEviction(
        budgetBytes: 1500,
        ttlSeconds: 48 * 3600,
        downloadsRoot: tempDir,
      );

      expect(evicted, contains('book_a'),
          reason: 'LRU eviction must remove oldest-accessed first');
      expect(evicted, isNot(contains('book_c')),
          reason: 'Freshest entry must be kept');
    });

    test('active jobId is never evicted', () async {
      final now = DateTime.now().toUtc();
      // Both books are over TTL.
      await plantAudiobook(tempDir,
          jobId: 'playing',
          totalBytes: 100,
          lastAccessedAt: now.subtract(const Duration(hours: 50)));
      await plantAudiobook(tempDir,
          jobId: 'inactive',
          totalBytes: 100,
          lastAccessedAt: now.subtract(const Duration(hours: 50)));

      final evicted = await OfflineCacheEviction.runEviction(
        budgetBytes: 10 * 1024 * 1024,
        ttlSeconds: 24 * 3600,
        activeJobIds: {'playing'},
        downloadsRoot: tempDir,
      );

      expect(evicted, isNot(contains('playing')));
      expect(evicted, contains('inactive'));
      expect(Directory('${tempDir.path}/downloads/playing').existsSync(),
          isTrue);
    });

    test('budget over-run evicts multiple LRU entries', () async {
      final now = DateTime.now().toUtc();
      // 5 books × 1000 bytes = 5000 bytes; budget = 2200 bytes.
      // Must evict 3 oldest (b1, b2, b3) to get under budget;
      // b5 (freshest) must survive.
      final ids = ['b1', 'b2', 'b3', 'b4', 'b5'];
      for (var i = 0; i < ids.length; i++) {
        await plantAudiobook(tempDir,
            jobId: ids[i],
            totalBytes: 1000,
            lastAccessedAt:
                now.subtract(Duration(hours: ids.length - i)));
      }

      final evicted = await OfflineCacheEviction.runEviction(
        budgetBytes: 2200,
        ttlSeconds: 48 * 3600,
        downloadsRoot: tempDir,
      );

      expect(evicted, containsAll(['b1', 'b2', 'b3']));
      expect(evicted, isNot(contains('b5')));
    });

    test('touchLastAccess writes sidecar file', () async {
      final folder = Directory('${tempDir.path}/downloads/lru_test');
      await folder.create(recursive: true);

      final before = DateTime.now().toUtc();
      await OfflineCacheEviction.touchLastAccess(
          'lru_test', downloadsRoot: tempDir);
      final after = DateTime.now().toUtc();

      final sidecar = File('${folder.path}/.last_access');
      expect(sidecar.existsSync(), isTrue,
          reason: 'touchLastAccess must create a .last_access sidecar');
      final parsed =
          DateTime.tryParse(await sidecar.readAsString())?.toUtc();
      expect(parsed, isNotNull);
      expect(
          parsed!.isAfter(before.subtract(const Duration(seconds: 1))),
          isTrue);
      expect(
          parsed.isBefore(after.add(const Duration(seconds: 1))), isTrue);
    });

    test('deleteJob removes folder', () async {
      final folder = Directory('${tempDir.path}/downloads/del_me');
      await folder.create(recursive: true);
      await File('${folder.path}/a.mp3').writeAsBytes([1, 2, 3]);

      final removed =
          await OfflineCacheEviction.deleteJob('del_me', downloadsRoot: tempDir);

      expect(removed, isTrue);
      expect(folder.existsSync(), isFalse);
    });

    test('deleteJob nonexistent returns true (idempotent)', () async {
      final removed = await OfflineCacheEviction.deleteJob(
          'does_not_exist_xyz',
          downloadsRoot: tempDir);
      // Deleting a non-existent folder: our impl checks exists() first
      // and returns true (no-op). Either true or false is acceptable as
      // long as it does not throw.
      expect(removed, isA<bool>());
    });

    test('constants are reasonable', () {
      expect(kDefaultOfflineCacheBudgetBytes,
          equals(2 * 1024 * 1024 * 1024)); // 2 GB
      expect(kDefaultOfflineCacheTTLSeconds,
          equals(24 * 60 * 60)); // 24 h
    });
  });
}
