import 'package:flutter/material.dart';
import 'package:flutter_app/features/library/library_book_facts.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/book_entity.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/library_screen.dart' show LibraryBookTile;
import 'package:flutter_app/services/conversion/local_conversion_record.dart';
import 'package:flutter_test/flutter_test.dart';

BookEntity _book(String path) => BookEntity(
  id: 'b1',
  title: 'Livro',
  author: 'Autora',
  filePath: path,
  displayFilename: path,
  addedAt: DateTime(2026, 11, 1),
);

EbookFulltext _text(int chapters) => EbookFulltext(
  jobId: 'b1',
  chapters: [
    for (var i = 0; i < chapters; i++) FulltextChapter(index: i, text: 't$i'),
  ],
);

LocalConversionJob _job(int done, int total) => LocalConversionJob(
  bookId: 'b1',
  jobId: 'j1',
  status: LocalConversionJobStatus.running,
  createdAt: DateTime(2026, 11, 2),
  updatedAt: DateTime(2026, 11, 2),
  chapters: [
    for (var i = 0; i < total; i++)
      LocalConversionChapter(
        index: i,
        name: 'c$i',
        status: i < done ? 'completed' : 'pending',
      ),
  ],
);

Widget _tile(LibraryBookFacts facts, Locale locale) => MaterialApp(
  locale: locale,
  localizationsDelegates: AppLocalizations.localizationsDelegates,
  supportedLocales: AppLocalizations.supportedLocales,
  home: Scaffold(
    body: SizedBox(
      width: 200,
      height: 380,
      child: LibraryBookTile(
        book: _book('/x/livro.epub'),
        facts: facts,
        onTap: () {},
        onLongPress: () {},
      ),
    ),
  ),
);

void main() {
  test('facts combine the cached text, the job and the resume position', () {
    final f = LibraryBookFacts.of(
      _book('/x/livro.epub'),
      fulltext: _text(20),
      job: _job(12, 63),
      resume: (chapter: 6, seconds: 3),
    );
    expect(f.format, 'EPUB');
    expect(f.chapterCount, 20);
    expect(f.resumeChapter, 7);
    expect(f.progressPercent, 30);
    expect(f.audioState, LibraryAudioState.partial);
    expect((f.audioDone, f.audioTotal), (12, 63));
  });

  test('no job means not converted and a full job means complete', () {
    expect(
      LibraryBookFacts.of(_book('/x/a.pdf')).audioState,
      LibraryAudioState.notConverted,
    );
    expect(
      LibraryBookFacts.of(_book('/x/a.pdf'), job: _job(3, 3)).audioState,
      LibraryAudioState.complete,
    );
    expect(LibraryBookFacts.of(_book('/x/a.PDF')).format, 'PDF');
  });

  testWidgets('the card shows format, size, progress, audio and date in pt', (
    tester,
  ) async {
    final facts = LibraryBookFacts.of(
      _book('/x/livro.epub'),
      fulltext: _text(20),
      job: _job(12, 63),
      resume: (chapter: 6, seconds: 3),
    );
    await tester.pumpWidget(_tile(facts, const Locale('pt')));
    expect(find.text('EPUB · 20 capítulos'), findsOneWidget);
    expect(find.text('30% · cap. 7 de 20'), findsOneWidget);
    expect(find.textContaining('Áudio 12 de 63'), findsOneWidget);
    expect(find.textContaining('Adicionado'), findsOneWidget);
  });

  testWidgets('the card says not converted in en', (tester) async {
    await tester.pumpWidget(
      _tile(LibraryBookFacts.of(_book('/x/livro.epub')), const Locale('en')),
    );
    expect(find.textContaining('Not converted'), findsOneWidget);
  });
}
