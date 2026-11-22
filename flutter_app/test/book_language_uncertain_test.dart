import 'package:flutter_app/services/conversion/book_language_uncertain.dart';
import 'package:flutter_app/services/conversion/embedded_conversion_contract.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('recognizes the shared Rust inconclusive-language failure', () {
    final error = EmbeddedConversionFailure(
      'RUST_FAILED',
      'Book language remains inconclusive after expanded sampling '
      '[[book_language_uncertain_v1]]{"confirmed":null,"languages":["en"]}'
      '[[/book_language_uncertain_v1]]',
    );
    expect(isBookLanguageUncertain(error), isTrue);
  });

  test('leaves other conversion failures untouched', () {
    expect(
      isBookLanguageUncertain(
        EmbeddedConversionFailure('NO_MODEL', 'Piper model is missing'),
      ),
      isFalse,
    );
  });
}
