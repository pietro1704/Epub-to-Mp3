// Flutter mirror of Apple #1501 (CONTRAST-AUDIT area 1): reader links meet WCAG AA 4.5:1
// on every reader background, including mid-grey custom backgrounds.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_app/models/app_settings.dart';
import 'package:flutter_app/views/reader_chapter_content.dart';
import 'package:flutter_app/views/reader_theme_colors.dart';

import 'support/contrast_audit.dart';

Color? _linkColor(WidgetTester tester) {
  Color? found;
  for (final rich in tester.widgetList<RichText>(find.byType(RichText))) {
    rich.text.visitChildren((span) {
      if (span is TextSpan && span.text == 'Link') found = span.style?.color;
      return found == null;
    });
  }
  return found;
}

void main() {
  final backgrounds = <String, Color>{
    for (final theme in ReaderTheme.values.where((t) => t != ReaderTheme.custom))
      for (final b in Brightness.values)
        '${theme.name}/${b.name}': ReaderThemeColors.background(theme, platformBrightness: b),
    'custom grey 0x80': const Color(0xff808080),
    'custom grey 0x60': const Color(0xff606060),
    'custom grey 0xa0': const Color(0xffa0a0a0),
    'custom blue': const Color(0xff2060c0),
  };
  for (final entry in backgrounds.entries) {
    testWidgets('reader link meets 4.5:1 on ${entry.key}', (tester) async {
      SharedPreferences.setMockInitialValues({});
      final settings = MirrorAppSettings(await SharedPreferences.getInstance());
      final bg = entry.value;
      final fg = bg.computeLuminance() > 0.18 ? Colors.black : Colors.white;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ReaderHtmlChapterContent(
            html: '<p>Text <a href="#n1">Link</a></p>',
            settings: settings,
            bg: bg,
            fg: fg,
            bodyStyle: const TextStyle(fontSize: 18),
            headingStyle: const TextStyle(fontSize: 24),
          ),
        ),
      ));
      final link = _linkColor(tester);
      expect(link, isNotNull);
      expect(contrastRatio(link!, bg), greaterThanOrEqualTo(4.5),
          reason: 'link $link on $bg');
    });
  }
}
