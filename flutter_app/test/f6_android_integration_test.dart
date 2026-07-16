import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/services/app_deep_link.dart';
import 'package:flutter_app/services/widget_playback_snapshot.dart';

void main() {
  group('AppDeepLink', () {
    test('parses open and player links with bookId', () {
      expect(
        AppDeepLink.parse(Uri.parse('epubtomp3://open?bookId=book-1')),
        const AppDeepLink.open('book-1'),
      );
      expect(
        AppDeepLink.parse(Uri.parse('epubtomp3://player?bookId=book-2')),
        const AppDeepLink.player('book-2'),
      );
    });

    test('rejects unsupported, malformed, and bookless links', () {
      expect(AppDeepLink.parse(Uri.parse('https://example.test')), isNull);
      expect(AppDeepLink.parse(Uri.parse('epubtomp3://open')), isNull);
      expect(
        AppDeepLink.parse(Uri.parse('epubtomp3://unknown?bookId=x')),
        isNull,
      );
    });

    test('service consumes injected cold and warm URI events', () async {
      final controller = StreamController<Uri>();
      final service = AppDeepLinkService(controller.stream);
      final received = <AppDeepLink>[];
      final sub = service.links.listen(received.add);

      controller.add(Uri.parse('epubtomp3://open?bookId=cold'));
      controller.add(Uri.parse('epubtomp3://player?bookId=warm'));
      await Future<void>.delayed(Duration.zero);

      expect(received, [
        const AppDeepLink.open('cold'),
        const AppDeepLink.player('warm'),
      ]);
      await sub.cancel();
      await service.dispose();
    });
  });

  group('WidgetPlaybackSnapshot', () {
    const snapshot = WidgetPlaybackSnapshot(
      bookId: 'book-1',
      title: 'Book',
      chapter: 'Chapter 2',
      position: 12.5,
      duration: 100,
      isPlaying: true,
      progress: 0.125,
    );

    test('serializes and restores all fields', () {
      expect(WidgetPlaybackSnapshot.fromJson(snapshot.toJson()), snapshot);
    });

    test('returns a safe default for absent or invalid data', () async {
      SharedPreferences.setMockInitialValues({});
      final store = WidgetPlaybackSnapshotStore(
        await SharedPreferences.getInstance(),
      );
      expect(await store.load(), const WidgetPlaybackSnapshot.empty());

      await store.rawWrite('{"bookId":"x","position":"bad"}');
      expect(await store.load(), const WidgetPlaybackSnapshot.empty());
    });

    test('uses empty fallback for stale snapshots', () async {
      SharedPreferences.setMockInitialValues({});
      final store = WidgetPlaybackSnapshotStore(
        await SharedPreferences.getInstance(),
        now: () => DateTime.utc(2026, 1, 2),
      );
      await store.save(snapshot, savedAt: DateTime.utc(2025, 12, 1));
      expect(
        await store.load(maxAge: const Duration(days: 7)),
        const WidgetPlaybackSnapshot.empty(),
      );
    });
  });
}
