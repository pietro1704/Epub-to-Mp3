import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('history warning retains completed job identity without inviting synthesis retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ManualConversionProgress(
            submitting: false,
            jobId: 'rust-complete-7',
            historyError: 'storage unavailable',
            error: null,
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    expect(find.text('rust-complete-7'), findsOneWidget);
    expect(find.textContaining('storage unavailable'), findsOneWidget);
    expect(find.text('Retry'), findsNothing);
    expect(find.byType(LinearProgressIndicator), findsNothing);
    expect(retries, 0);
  });

  testWidgets('conversion failure exposes exactly one explicit retry', (tester) async {
    var retries = 0;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ManualConversionProgress(
            submitting: false,
            jobId: null,
            historyError: null,
            error: 'engine unavailable',
            onRetry: () => retries++,
          ),
        ),
      ),
    );
    expect(find.text('engine unavailable'), findsOneWidget);
    await tester.tap(find.text('Retry'));
    expect(retries, 1);
    expect(find.byKey(const Key('conversion-job-id')), findsNothing);
  });
}
