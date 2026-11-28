import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/screens/pdf_reader_screen.dart';
import 'package:flutter_app/views/reader_toc_rows.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<void> _pump(WidgetTester t, PdfContentsLoader? contents) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await t.pumpWidget(
    MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: PdfReaderScreen(
        bookId: 'b',
        title: 'A PDF',
        filePath: '/tmp/x.pdf',
        prefs: prefs,
        loadDocument: () async {},
        loadContents: contents,
        viewerBuilder: (context, path, page, onPageChanged) => const SizedBox(),
      ),
    ),
  );
  await t.pumpAndSettle();
}

void main() {
  testWidgets('lists the automatic contents of a PDF', (t) async {
    await _pump(
      t,
      () async => const [
        PdfContentsRow(title: 'One', level: 0, page: 1),
        PdfContentsRow(title: 'Two', level: 1, page: 14),
      ],
    );
    await t.tap(find.byKey(const ValueKey('pdf-contents-button')));
    await t.pumpAndSettle();
    expect(find.text('One'), findsOneWidget);
    expect(find.text('Two'), findsOneWidget);
    await t.tap(find.byKey(const ValueKey('pdf-contents-14')));
    await t.pumpAndSettle();
    expect(find.text('Two'), findsNothing);
  });

  testWidgets('a PDF without a contents list has no Contents action', (
    t,
  ) async {
    await _pump(t, () async => const []);
    expect(find.byKey(const ValueKey('pdf-contents-button')), findsNothing);
  });
}
