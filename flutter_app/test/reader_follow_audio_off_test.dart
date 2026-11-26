// The "follow audio" switch is the single iOS audio-tracking switch: off, the
// spoken-sentence highlight is not painted at all (not only the page following).
import 'package:flutter/material.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';
import 'package:flutter_app/l10n/app_localizations.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

Future<TextRange?> _shownHighlight(WidgetTester tester, bool follow) async {
  SharedPreferences.setMockInitialValues({
    'readerLayout': 'paginated',
    'readerAutoScroll': follow,
  });
  final prefs = await SharedPreferences.getInstance();
  await tester.pumpWidget(
    ProviderScope(
      overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: ReaderView(
            chapter: FulltextChapter(index: 0, text: 'Spoken sentence here.', html: '<p>Spoken sentence here.</p>'),
            spans: const [],
            measuredHighlight: const TextRange(start: 0, end: 6),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return tester.widget<RichReaderSurface>(find.byType(RichReaderSurface)).highlight;
}

void main() {
  testWidgets('follow audio on paints the narration highlight', (tester) async {
    expect(await _shownHighlight(tester, true), const TextRange(start: 0, end: 6));
  });

  testWidgets('follow audio off paints no narration highlight', (tester) async {
    expect(await _shownHighlight(tester, false), isNull);
  });
}
