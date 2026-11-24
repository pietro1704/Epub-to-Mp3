import 'package:flutter/widgets.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/models/fallback_chapter_name.dart';
import 'package:flutter_app/models/job_snapshot.dart';
import 'package:flutter_test/flutter_test.dart';

// Apple #1428: chapters without a title are named in the app language ("Capítulo N"), not in
// English. Rust names an untitled chapter "Chapter N"; the Dart fallbacks do the same.
Future<void> _use(String language) async => FallbackChapterName.use(
  await AppLocalizations.delegate.load(Locale(language)),
);

void main() {
  tearDown(() => _use('en'));

  for (final (language, word) in [
    ('pt', 'Capítulo'),
    ('es', 'Capítulo'),
    ('en', 'Chapter'),
  ]) {
    test('untitled chapters are named in $language', () async {
      await _use(language);
      expect(
        const FulltextChapter(index: 3, text: 'x').displayTitle,
        '$word 3',
      );
      expect(
        const FulltextChapter(index: 5, name: '', text: 'x').displayTitle,
        '$word 5',
      );
      expect(const ChapterProgress(index: 2).displayTitle, '$word 3');
      // The name Rust gives an untitled chapter.
      expect(
        const FulltextChapter(
          index: 6,
          name: 'Chapter 7',
          text: 'x',
        ).displayTitle,
        '$word 7',
      );
      expect(
        const ChapterProgress(index: 6, name: 'Chapter 7').displayTitle,
        '$word 7',
      );
    });
  }

  test('a real title that merely starts with Chapter is left alone', () async {
    await _use('pt');
    expect(
      const FulltextChapter(
        index: 1,
        name: 'Chapter 1: The Beginning',
        text: 'x',
      ).displayTitle,
      'Chapter 1: The Beginning',
    );
    expect(
      const FulltextChapter(index: 1, name: 'Prologue', text: 'x').displayTitle,
      'Prologue',
    );
  });
}
