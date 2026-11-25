// The full player's "back to the reading" button uses the Apple wording
// (player.goToReading in en/pt-BR/es Localizable.strings).
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_app/l10n/app_localizations.dart';

void main() {
  test('Go to reading label matches Apple in every app language', () {
    expect(lookupAppLocalizations(const Locale('en')).goToNarratedPage, 'Go to reading');
    expect(lookupAppLocalizations(const Locale('pt')).goToNarratedPage, 'Ir para a leitura');
    expect(lookupAppLocalizations(const Locale('es')).goToNarratedPage, 'Ir a la lectura');
  });
}
