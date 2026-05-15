import 'package:flutter/material.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_app/screens/toc_drawer.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _wrap(TocDrawer drawer) {
  return MaterialApp(
    home: Scaffold(
      drawer: drawer,
      body: Builder(
        builder: (ctx) => IconButton(
          icon: const Icon(Icons.menu),
          onPressed: () => Scaffold.of(ctx).openDrawer(),
        ),
      ),
    ),
  );
}

final _fulltext = EbookFulltext(
  jobId: 'j1',
  bookTitle: 'Test Book',
  bookAuthor: 'Author',
  chapters: [
    FulltextChapter(index: 0, name: 'Intro', text: 'Short intro text.'),
    FulltextChapter(
        index: 1, name: 'Chapter 1', text: 'A' * 2500),
    FulltextChapter(index: 2, name: 'Chapter 2', text: 'B' * 500),
  ],
);

final _snapshot = JobSnapshot(
  jobId: 'j1',
  state: 'processing',
  chapterProgress: [
    const ChapterProgress(
      index: 0,
      name: 'Intro',
      status: 'completed',
      downloadUrl: 'http://test/ch0.mp3',
    ),
    const ChapterProgress(
      index: 1,
      name: 'Chapter 1',
      status: 'converting',
    ),
    const ChapterProgress(
      index: 2,
      name: 'Chapter 2',
      status: 'pending',
    ),
  ],
);

void main() {
  group('TocDrawer', () {
    testWidgets('shows chapter titles and char counts', (t) async {
      await t.pumpWidget(_wrap(TocDrawer(
        fulltext: _fulltext,
        snapshot: null,
        currentIndex: 0,
        onJump: (_) {},
      )));
      await t.tap(find.byIcon(Icons.menu));
      await t.pumpAndSettle();

      expect(find.text('Chapters'), findsOneWidget);
      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);
      expect(find.text('Chapter 2'), findsOneWidget);
      expect(find.text('2.5k chars'), findsOneWidget);
      expect(find.text('500 chars'), findsOneWidget);
    });

    testWidgets('shows check icon for completed chapters', (t) async {
      await t.pumpWidget(_wrap(TocDrawer(
        fulltext: _fulltext,
        snapshot: _snapshot,
        currentIndex: 1,
        onJump: (_) {},
      )));
      await t.tap(find.byIcon(Icons.menu));
      await t.pumpAndSettle();

      expect(find.byIcon(Icons.check_circle), findsOneWidget);
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
    });

    testWidgets('tapping a chapter calls onJump', (t) async {
      int? jumped;
      await t.pumpWidget(_wrap(TocDrawer(
        fulltext: _fulltext,
        snapshot: null,
        currentIndex: 0,
        onJump: (i) => jumped = i,
      )));
      await t.tap(find.byIcon(Icons.menu));
      await t.pumpAndSettle();
      await t.tap(find.text('Chapter 2'));
      expect(jumped, 2);
    });

    testWidgets('falls back to snapshot when no fulltext', (t) async {
      await t.pumpWidget(_wrap(TocDrawer(
        fulltext: null,
        snapshot: _snapshot,
        currentIndex: 0,
        onJump: (_) {},
      )));
      await t.tap(find.byIcon(Icons.menu));
      await t.pump();
      await t.pump(const Duration(seconds: 1));

      expect(find.text('Intro'), findsOneWidget);
      expect(find.text('Chapter 1'), findsOneWidget);
    });
  });
}
