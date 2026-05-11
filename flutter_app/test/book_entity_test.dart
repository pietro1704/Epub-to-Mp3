// Parity test for BookEntity (mirror of Models/BookEntity.swift).
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('BookEntity', () {
    test('status: textOnly when no jobId and not offline', () {
      final b = BookEntity(
        id: 'h1',
        title: 'T',
        filePath: '/x',
        displayFilename: 'x.epub',
        addedAt: DateTime(2026, 1, 1),
      );
      expect(b.status, LibraryStatus.textOnly);
    });

    test('status: caching when jobId set but not cached', () {
      final b = BookEntity(
        id: 'h1',
        title: 'T',
        filePath: '/x',
        displayFilename: 'x.epub',
        addedAt: DateTime(2026, 1, 1),
        lastJobId: 'job-1',
      );
      expect(b.status, LibraryStatus.caching);
    });

    test('status: offlineReady wins over caching', () {
      final b = BookEntity(
        id: 'h1',
        title: 'T',
        filePath: '/x',
        displayFilename: 'x.epub',
        addedAt: DateTime(2026, 1, 1),
        lastJobId: 'job-1',
        cachedOffline: true,
      );
      expect(b.status, LibraryStatus.offlineReady);
    });

    test('resolvedTitle falls back to filename when title blank', () {
      final b = BookEntity(
        id: 'h1',
        title: '   ',
        filePath: '/x',
        displayFilename: 'fallback.epub',
        addedAt: DateTime(2026, 1, 1),
      );
      expect(b.resolvedTitle, 'fallback.epub');
    });

    test('roundtrips through json', () {
      final b = BookEntity(
        id: 'h1',
        title: 'Hello',
        author: 'Author',
        filePath: '/x.epub',
        displayFilename: 'x.epub',
        addedAt: DateTime.utc(2026, 1, 1),
        lastChapterIndex: 3,
        lastPositionSeconds: 12.5,
        cachedOffline: true,
      );
      final round = BookEntity.decode(b.encode());
      expect(round.id, 'h1');
      expect(round.author, 'Author');
      expect(round.lastChapterIndex, 3);
      expect(round.lastPositionSeconds, 12.5);
      expect(round.cachedOffline, isTrue);
    });
  });
}
