import 'package:flutter/material.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/screens/convert_screen.dart';
import 'package:flutter_app/services/conversion/embedded_converter.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

final class _ParsingConverter extends UnavailableEmbeddedConverter {
  _ParsingConverter(this.skipped);
  final int skipped;
  final parsed = <String>[];

  @override
  Future<EbookFulltext> parse({required String inputPath, String jobId = ''}) async {
    parsed.add(inputPath);
    return EbookFulltext.fromJson({
      'jobId': jobId,
      'chapters': <Object>[],
      if (skipped > 0) 'skipped_pages': skipped,
    });
  }
}

Future<void> _pump(WidgetTester tester, String path, _ParsingConverter converter) async {
  SharedPreferences.setMockInitialValues({});
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        sharedPrefsProvider.overrideWithValue(prefs),
        embeddedConverterProvider.overrideWithValue(converter),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: ConvertScreen(initialFilePath: path),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('a PDF with text-less pages shows how many were skipped', (tester) async {
    await _pump(tester, '/tmp/book.pdf', _ParsingConverter(3));
    expect(
      find.text('We skipped 3 PDF pages without selectable text (cover, images, or blank pages). We narrate the rest of the book.'),
      findsOneWidget,
    );
  });

  testWidgets('one skipped page uses the singular text', (tester) async {
    await _pump(tester, '/tmp/book.pdf', _ParsingConverter(1));
    expect(
      find.text('We skipped 1 PDF page without selectable text (cover, image, or blank page). We narrate the rest of the book.'),
      findsOneWidget,
    );
  });

  testWidgets('a PDF with no skipped page shows no notice', (tester) async {
    await _pump(tester, '/tmp/book.pdf', _ParsingConverter(0));
    expect(find.textContaining('We skipped'), findsNothing);
  });

  testWidgets('an EPUB is never parsed for the notice', (tester) async {
    final converter = _ParsingConverter(5);
    await _pump(tester, '/tmp/book.epub', converter);
    expect(converter.parsed, isEmpty);
    expect(find.textContaining('We skipped'), findsNothing);
  });
}
