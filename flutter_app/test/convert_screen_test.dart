import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  testWidgets('renders manual conversion controls', (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: const MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(),
        ),
      ),
    );

    expect(find.text('Choose EPUB or PDF'), findsOneWidget);
    expect(find.text('Engine'), findsOneWidget);
    expect(find.text('Voice'), findsOneWidget);
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Chapter range'), findsOneWidget);
    expect(find.text('Options'), findsOneWidget);
    expect(find.text('Start conversion'), findsOneWidget);
  });

  testWidgets('submits the selected file through the injected existing service',
      (tester) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    String? submittedPath;
    await tester.pumpWidget(
      ProviderScope(
        overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: ConvertScreen(
            initialFilePath: '/tmp/book.epub',
            startConversion: (request) async {
              submittedPath = request.filePath;
              return 'job-1';
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Start conversion'));
    await tester.pumpAndSettle();

    expect(submittedPath, '/tmp/book.epub');
    expect(find.text('job-1'), findsOneWidget);
  });
}