// Pietro: the "x of y" page indicator needs a legible background: contrast >= 4.5:1
// in the light, dark and sepia themes. Both readers (plain and rich HTML) are checked.
import 'package:flutter/material.dart';
import 'package:flutter_app/features/reader/rich_reader_surface.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_theme_colors.dart';
import 'package:flutter_app/views/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

double _luminance(Color c) => c.computeLuminance();

double _contrast(Color a, Color b) {
  final la = _luminance(a), lb = _luminance(b);
  final hi = la > lb ? la : lb, lo = la > lb ? lb : la;
  return (hi + 0.05) / (lo + 0.05);
}

Color _over(Color top, Color under) => Color.alphaBlend(top, under);

final _indicator = find.byWidgetPredicate(
  (w) => w is Text && RegExp(r'^\d+ / \d+$').hasMatch(w.data ?? ''),
);

/// Effective text and pill colors of the indicator, composited over [readerBackground].
(Color text, Color pill) _colors(WidgetTester tester, Color readerBackground) {
  final text = tester.widget<Text>(_indicator);
  var pill = readerBackground;
  final box = find
      .ancestor(of: _indicator, matching: find.byType(Container))
      .evaluate()
      .map((e) => (e.widget as Container).decoration)
      .whereType<BoxDecoration>()
      .where((d) => d.color != null)
      .firstOrNull;
  if (box != null) pill = _over(box.color!, readerBackground);
  return (_over(text.style!.color!, pill), pill);
}

final _paragraphs = List.generate(30, (i) => 'Esta é a frase número ${i + 1} do capítulo de teste, com texto para várias páginas.');

void main() {
  for (final theme in [ReaderTheme.light, ReaderTheme.sepia, ReaderTheme.dark]) {
    testWidgets('plain reader: page indicator contrast >= 4.5 in ${theme.name}', (tester) async {
      SharedPreferences.setMockInitialValues({'readerLayout': 'paginated', 'readerTheme': theme.rawValue});
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(360, 640);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final chapter = FulltextChapter(index: 0, name: 'C', text: _paragraphs.join(' '));
      await tester.pumpWidget(
        ProviderScope(
          overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
          child: MaterialApp(
            home: Scaffold(body: ReaderView(chapter: chapter, spans: chapter.splitSentences())),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final bg = ReaderThemeColors.background(theme);
      final (text, pill) = _colors(tester, bg);
      expect(_contrast(text, pill), greaterThanOrEqualTo(4.5));
    });

    testWidgets('rich reader: page indicator contrast >= 4.5 in ${theme.name}', (tester) async {
      SharedPreferences.setMockInitialValues({'readerLayout': 'paginated', 'readerTheme': theme.rawValue});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      final bg = ReaderThemeColors.background(theme);
      final fg = ReaderThemeColors.foreground(theme);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            backgroundColor: bg,
            body: Align(
              alignment: Alignment.topCenter,
              child: SizedBox(
                width: 400,
                height: 360,
                child: RichReaderSurface(
                  chapter: FulltextChapter(
                    index: 0,
                    text: _paragraphs.join('\n'),
                    html: _paragraphs.map((p) => '<p>$p</p>').join(),
                  ),
                  settings: settings,
                  background: bg,
                  foreground: fg,
                  bodyStyle: TextStyle(fontSize: 20, height: 1.6, color: fg),
                  headingStyle: const TextStyle(fontSize: 24),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final (text, pill) = _colors(tester, bg);
      expect(_contrast(text, pill), greaterThanOrEqualTo(4.5));
    });
  }
}
