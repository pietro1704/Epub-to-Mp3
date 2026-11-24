import 'dart:convert';

import 'package:flutter_app/models/book_language_corrections.dart';
import 'package:flutter_app/services/conversion/embedded_conversion_contract.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Apple BookLanguageCorrections: a user's language choice belongs to one book,
/// is applied to every conversion of that book, and is removed with "Automatic".
Future<BookLanguageCorrections> _store() async {
  SharedPreferences.setMockInitialValues({});
  return BookLanguageCorrections(await SharedPreferences.getInstance());
}

void main() {
  test('a book language is remembered per book and cleared by automatic', () async {
    final store = await _store();
    expect(store.decision('a').bookLanguage, isNull);
    await store.set('pt-BR', bookId: 'a');
    expect(store.decision('a').bookLanguage, 'pt-BR');
    expect(store.decision('b').bookLanguage, isNull, reason: 'other books untouched');
    await store.set('', bookId: 'a');
    expect(store.decision('a').bookLanguage, isNull);
  });

  test('a passage correction splits the overlapping ones it replaces', () async {
    final store = await _store();
    await store.set('en', bookId: 'a',
        passage: const PassageLanguageCorrection(chapterIndex: 2, start: 0, end: 100, language: 'en'));
    await store.set('fr', bookId: 'a',
        passage: const PassageLanguageCorrection(chapterIndex: 2, start: 40, end: 60, language: 'fr'));
    final spans = store.decision('a').passages
        .map((p) => '${p.chapterIndex}:${p.start}-${p.end}:${p.language}')
        .toList()
      ..sort();
    expect(spans, ['2:0-40:en', '2:40-60:fr', '2:60-100:en']);
  });

  test('corrections reach the Rust options as language and language_overrides', () async {
    final store = await _store();
    await store.set('pt-PT', bookId: 'a');
    await store.set('en', bookId: 'a',
        passage: const PassageLanguageCorrection(chapterIndex: 1, start: 5, end: 9, language: 'en'));
    final applied = jsonDecode(store.applying('{"models_root":"/m"}', bookId: 'a')) as Map;
    expect(applied['models_root'], '/m');
    expect(applied['language'], 'pt-PT');
    expect(applied['language_overrides'], [
      {'chapter_index': 1, 'start': 5, 'end': 9, 'language': 'en'},
    ]);
    expect(jsonDecode(store.applying('{"language":"es"}', bookId: 'a'))['language'], 'es',
        reason: 'an explicit per-job language stays authoritative');
    expect(store.applying('{"x":1}', bookId: 'none'), '{"x":1}', reason: 'no decision, no change');
  });

  test('the uncertain-language failure names the passage to correct', () {
    final error = EmbeddedConversionFailure(
      'RUST_FAILED',
      '[[book_language_uncertain_v1]]{"chapter_index":3,"start":10,"end":50}'
      '[[/book_language_uncertain_v1]]',
    );
    final uncertain = BookLanguageUncertain.decode(error)!;
    final passage = uncertain.passage('pt-BR')!;
    expect((passage.chapterIndex, passage.start, passage.end, passage.language), (3, 10, 50, 'pt-BR'));
    expect(BookLanguageUncertain.decode(EmbeddedConversionFailure('NO_MODEL', 'x')), isNull);
    final whole = BookLanguageUncertain.decode(EmbeddedConversionFailure('RUST_FAILED',
        '[[book_language_uncertain_v1]]{"confirmed":null}[[/book_language_uncertain_v1]]'))!;
    expect(whole.passage('pt-BR'), isNull, reason: 'no range: the choice applies to the whole book');
  });
}
