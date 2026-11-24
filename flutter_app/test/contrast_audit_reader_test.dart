// CONTRAST-AUDIT, area 2: the reader (its themes, the spoken-sentence highlight and the chapter
// header). Pairs are computed from the real palette; the pixel audit measures the rendered reader.
import 'package:flutter/material.dart';
import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/models/ebook_fulltext.dart';
import 'package:flutter_app/state/providers.dart';
import 'package:flutter_app/views/reader_theme_colors.dart';
import 'package:flutter_app/views/reader_view.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/contrast_audit.dart';

const _themes = [
  ReaderTheme.light,
  ReaderTheme.sepia,
  ReaderTheme.parchment,
  ReaderTheme.paper,
  ReaderTheme.dark,
  ReaderTheme.black,
];

// The spoken sentence is painted with this tint over the page (reader_chapter_content.dart).
final _highlight = Colors.yellow.withValues(alpha: 0.35);

void main() {
  for (final theme in _themes) {
    test(
      '${theme.name}: text on the page and on the spoken-sentence highlight is >= 4.5:1',
      () {
        final background = ReaderThemeColors.background(theme);
        final foreground = ReaderThemeColors.foreground(theme);
        expect(
          contrastRatio(foreground, background),
          greaterThanOrEqualTo(4.5),
        );
        expect(
          contrastRatio(foreground, Color.alphaBlend(_highlight, background)),
          greaterThanOrEqualTo(4.5),
          reason: 'the highlighted sentence stays readable',
        );
      },
    );

    testWidgets('${theme.name}: every text of the reader meets WCAG AA', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        'readerLayout': 'scroll',
        'readerTheme': theme.rawValue,
      });
      final prefs = await SharedPreferences.getInstance();
      tester.view.physicalSize = const Size(400, 700);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final key = GlobalKey();
      final chapter = FulltextChapter(
        index: 0,
        name: 'Chapter 1',
        text: List.generate(
          12,
          (i) =>
              'Sentence number ${i + 1} of the test chapter, with some text.',
        ).join(' '),
        charCount: 1234,
      );
      await tester.pumpWidget(
        AuditHost(
          boundaryKey: key,
          child: ProviderScope(
            overrides: [sharedPrefsProvider.overrideWithValue(prefs)],
            child: MaterialApp(
              home: Scaffold(
                backgroundColor: ReaderThemeColors.background(theme),
                body: ReaderView(
                  chapter: chapter,
                  spans: chapter.splitSentences(),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final findings = await auditContrast(tester, key);
      expect(findings, isEmpty, reason: findings.join('\n'));
    });
  }
}
