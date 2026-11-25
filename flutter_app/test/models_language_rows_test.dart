import 'package:flutter_app/screens/models_language_screen.dart';
import 'package:flutter_test/flutter_test.dart';

// Linux run 2026-11-25: "Português · 5 modelos" opened a page with 6 Piper rows, one of them
// the "piper-default" alias. Like the iPhone, the alias is a catalog placeholder, not a voice.
void main() {
  test('a language page lists its voices without the piper-default alias', () {
    final rows = languageModelRows([
      {'id': 'piper-default', 'engine': 'piper', 'languages': ['pt-BR']},
      {'id': 'pt_BR-faber-medium', 'engine': 'piper', 'languages': ['pt-BR']},
      {'id': 'en_US-amy-medium', 'engine': 'piper', 'languages': ['en-US']},
    ], 'pt');
    expect(rows.map((m) => m['id']), ['pt_BR-faber-medium']);
  });
}
