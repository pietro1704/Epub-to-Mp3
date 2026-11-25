import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

// Linux run 2026-11-25: in Portuguese the Converter tab still showed English labels.
void main() {
  testWidgets('the Converter screen is fully translated in Portuguese', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(500, 1400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          locale: Locale('pt'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(),
        ),
      ),
    );
    await tester.pumpAndSettle();
    for (final english in [
      'Choose EPUB or PDF',
      'Engine',
      'Language',
      'Chapter range',
      'From',
      'To',
      'Options',
      'Start conversion',
      'Cover and audio processing options are managed by the local converter.',
      'Include cover',
      'Normalize audio',
      'Portuguese',
      'English',
      'Spanish',
    ]) {
      expect(find.text(english), findsNothing, reason: english);
    }
  });
}
