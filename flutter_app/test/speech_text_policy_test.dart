import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_app/services/speech_text_policy.dart';

void main() {
  test('detects English Lord of the Rings text', () {
    final locale = SpeechTextPolicy.detectLocale([
      'The Fellowship of the Ring was formed in Rivendell.',
      'They travelled through the land with their companions.',
    ]);
    expect(locale, 'en-US');
  });

  test('detects Brazilian Portuguese text', () {
    final locale = SpeechTextPolicy.detectLocale([
      'O grupo foi para a cidade com seus companheiros.',
      'A jornada foi longa e difícil.',
    ]);
    expect(locale, 'pt-BR');
  });

  test('splits long text at sentence boundaries', () {
    final chunks = SpeechTextPolicy.splitForAndroidTts(
      'First sentence. Second sentence. Third sentence.',
      maxChars: 25,
    );
    expect(chunks, ['First sentence.', 'Second sentence.', 'Third sentence.']);
    expect(chunks.every((chunk) => chunk.length <= 25), isTrue);
  });

  test('splits long text without punctuation at word boundaries', () {
    final chunks = SpeechTextPolicy.splitForAndroidTts(
      List.filled(30, 'word').join(' '),
      maxChars: 20,
    );
    expect(chunks, isNotEmpty);
    expect(chunks.every((chunk) => chunk.length <= 20), isTrue);
    expect(chunks.join(' '), List.filled(30, 'word').join(' '));
  });

  test('ignores empty text', () {
    expect(SpeechTextPolicy.splitForAndroidTts('  \n\t '), isEmpty);
  });
}
